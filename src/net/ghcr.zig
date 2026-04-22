//! malt — GHCR client
//! Token management and blob fetching for GitHub Container Registry.

const std = @import("std");
const fs_compat = @import("../fs/compat.zig");

const client_mod = @import("client.zig");
const io_mod = @import("../ui/io.zig");

pub const GhcrError = error{
    TokenFetchFailed,
    DownloadFailed,
    Unauthorized,
    InvalidResponse,
    OutOfMemory,
};

pub const GhcrClient = struct {
    allocator: std.mem.Allocator,
    http: *client_mod.HttpClient,
    cached_token: ?[]const u8,
    /// Set of repository scopes the cached token is valid for. GHCR's
    /// `/token` endpoint accepts multiple `scope=…` query params and
    /// returns a single token valid for every requested scope, so a
    /// batch install can amortize N token fetches into one. On a single
    /// `fetchToken` miss this set holds exactly the one scope; after
    /// `prefetchTokens` it holds every repo in the batch.
    cached_scopes: std.StringHashMapUnmanaged(void),
    token_expiry: i64,
    mutex: std.Io.Mutex,

    pub fn init(allocator: std.mem.Allocator, http: *client_mod.HttpClient) GhcrClient {
        return .{
            .allocator = allocator,
            .http = http,
            .cached_token = null,
            .cached_scopes = .empty,
            .token_expiry = 0,
            .mutex = .init,
        };
    }

    pub fn deinit(self: *GhcrClient) void {
        self.clearCache();
        self.cached_scopes.deinit(self.allocator);
    }

    /// Drop any cached token + the owned scope keys. Caller holds
    /// `self.mutex` where concurrent access is possible.
    fn clearCache(self: *GhcrClient) void {
        if (self.cached_token) |t| {
            self.allocator.free(t);
            self.cached_token = null;
        }
        var it = self.cached_scopes.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.cached_scopes.clearRetainingCapacity();
        self.token_expiry = 0;
    }

    /// Pure cache probe: returns true iff `repo` is covered by an
    /// unexpired cached token. Used by tests and by `fetchToken` to
    /// short-circuit before building a URL.
    pub fn hasTokenFor(self: *GhcrClient, repo: []const u8) bool {
        const now = fs_compat.timestamp();
        if (self.cached_token == null) return false;
        if (now >= self.token_expiry) return false;
        return self.cached_scopes.contains(repo);
    }

    /// Build the GHCR token URL covering every repo in `repos`. One
    /// `scope=repository:{repo}:pull` query param per repo; GHCR
    /// returns a token valid for all of them. Caller owns the result.
    pub fn buildTokenUrl(allocator: std.mem.Allocator, repos: []const []const u8) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        try aw.writer.writeAll("https://ghcr.io/token?");
        for (repos, 0..) |repo, i| {
            if (i != 0) try aw.writer.writeByte('&');
            try aw.writer.print("scope=repository:{s}:pull", .{repo});
        }
        return aw.toOwnedSlice();
    }

    /// Fetch one token covering every repo in `repos` with a single
    /// round-trip and seed the cache with the full scope set. Callers
    /// (`install.zig`) use this before spawning download workers so
    /// every worker lands in the cache instead of racing their own
    /// per-repo token fetches. Safe to call with zero or one repo —
    /// degenerate cases fall through to the same code path.
    ///
    /// On any failure the cache is left empty; workers fall back to
    /// per-repo `fetchToken` at a modest cost (one round-trip per
    /// miss, same as before).
    pub fn prefetchTokens(
        self: *GhcrClient,
        http: *client_mod.HttpClient,
        repos: []const []const u8,
    ) GhcrError!void {
        if (repos.len == 0) return;

        const io = io_mod.ctx();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        self.clearCache();

        const url = buildTokenUrl(self.allocator, repos) catch return GhcrError.OutOfMemory;
        defer self.allocator.free(url);

        var resp = http.get(url) catch return GhcrError.TokenFetchFailed;
        defer resp.deinit();
        if (resp.status != 200) return GhcrError.TokenFetchFailed;

        const token = extractTokenField(self.allocator, resp.body) catch
            return GhcrError.InvalidResponse;
        errdefer self.allocator.free(token);

        // Seed the scope set. Any put failure here is fatal to the
        // prefetch (we'd otherwise leave a cached token that claims to
        // cover repos it can't serve), so we tear everything down and
        // surface OutOfMemory to the caller.
        for (repos) |repo| {
            if (self.cached_scopes.contains(repo)) continue;
            const owned = self.allocator.dupe(u8, repo) catch {
                self.clearCache();
                return GhcrError.OutOfMemory;
            };
            self.cached_scopes.put(self.allocator, owned, {}) catch {
                self.allocator.free(owned);
                self.clearCache();
                return GhcrError.OutOfMemory;
            };
        }

        self.cached_token = token;
        self.token_expiry = fs_compat.timestamp() + 270; // 4.5 min of the 5 min TTL
    }

    /// Fetch an anonymous GHCR token for a single repository. Hits the
    /// cache first, so after `prefetchTokens` has seeded the scope set
    /// every in-batch worker returns immediately without a round-trip.
    /// A miss falls through to a single-scope fetch that *replaces* the
    /// cache — the old behaviour — so out-of-batch calls keep working.
    ///
    /// repo format: "homebrew/core/wget" → scope=repository:homebrew/core/wget:pull
    ///
    /// `http` is a caller-owned client — typically borrowed from a
    /// `HttpClientPool` so the TLS context is reused across requests.
    ///
    /// **Ownership.** The returned slice is an owned dupe allocated
    /// from `self.allocator`; the caller must `defer self.allocator.free(token)`.
    /// A borrowed return would race `clearCache` between mutex release
    /// and the caller's use.
    pub fn fetchToken(
        self: *GhcrClient,
        http: *client_mod.HttpClient,
        repo: []const u8,
    ) GhcrError![]const u8 {
        const io = io_mod.ctx();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const now = fs_compat.timestamp();
        if (self.cached_token) |t| {
            if (now < self.token_expiry and self.cached_scopes.contains(repo)) {
                return self.allocator.dupe(u8, t) catch GhcrError.OutOfMemory;
            }
            self.clearCache();
        }

        const repos = [_][]const u8{repo};
        const url = buildTokenUrl(self.allocator, &repos) catch
            return GhcrError.OutOfMemory;
        defer self.allocator.free(url);

        var resp = http.get(url) catch return GhcrError.TokenFetchFailed;
        defer resp.deinit();

        if (resp.status != 200) return GhcrError.TokenFetchFailed;

        const token = extractTokenField(self.allocator, resp.body) catch
            return GhcrError.InvalidResponse;
        errdefer self.allocator.free(token);

        // Keep the caller's copy independent from the cache so a later
        // `clearCache` can't free memory still in flight.
        const cached_copy = self.allocator.dupe(u8, token) catch return GhcrError.OutOfMemory;
        errdefer self.allocator.free(cached_copy);

        const repo_dup = self.allocator.dupe(u8, repo) catch return GhcrError.OutOfMemory;
        errdefer self.allocator.free(repo_dup);
        try self.cached_scopes.put(self.allocator, repo_dup, {});

        self.cached_token = cached_copy;
        self.token_expiry = now + 270; // 4.5 min buffer before 5 min expiry
        return token;
    }

    /// Download a blob from GHCR, handling 401 -> token -> retry.
    /// `http` is a caller-owned client (typically borrowed from a
    /// `HttpClientPool`) — the caller is responsible for ensuring no
    /// other thread is using the same client concurrently. The token
    /// cache inside this struct remains mutex-protected.
    pub fn downloadBlob(
        self: *GhcrClient,
        allocator: std.mem.Allocator,
        http: *client_mod.HttpClient,
        repo: []const u8,
        digest: []const u8,
        body_out: *std.ArrayList(u8),
        progress: ?client_mod.ProgressCallback,
    ) GhcrError!void {
        // Get token through the mutex-protected cache (avoids redundant fetches).
        // `fetchToken` returns an owned dupe — free before leaving.
        const token = self.fetchToken(http, repo) catch return GhcrError.TokenFetchFailed;
        defer self.allocator.free(token);

        // Build URL: https://ghcr.io/v2/{repo}/blobs/{digest}
        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://ghcr.io/v2/{s}/blobs/{s}", .{ repo, digest }) catch
            return GhcrError.OutOfMemory;

        // Download with cached token
        var auth_buf: [2048]u8 = undefined;
        const auth_value = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch
            return GhcrError.OutOfMemory;

        const headers = [_]std.http.Header{
            .{ .name = "Authorization", .value = auth_value },
        };

        var resp = http.getWithHeaders(url, &headers, progress) catch
            return GhcrError.DownloadFailed;
        defer resp.deinit();

        if (resp.status != 200) return GhcrError.DownloadFailed;

        body_out.appendSlice(allocator, resp.body) catch return GhcrError.OutOfMemory;
    }
};

/// Extract the "token" field from a JSON response like {"token":"..."}
pub fn extractTokenField(allocator: std.mem.Allocator, json_bytes: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    const token_val = obj.get("token") orelse return error.InvalidResponse;
    const token_str = switch (token_val) {
        .string => |s| s,
        else => return error.InvalidResponse,
    };

    return allocator.dupe(u8, token_str);
}
