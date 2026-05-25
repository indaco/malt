//! malt — GHCR client
//! Token management and blob fetching for GitHub Container Registry.

const std = @import("std");

const client_mod = @import("client.zig");
const mirror_mod = @import("mirror.zig");

pub const GhcrError = error{
    TokenFetchFailed,
    DownloadFailed,
    DownloadTimeout,
    DownloadConnectionReset,
    DownloadHttpClientError,
    DownloadHttpServerError,
    DownloadRateLimited,
    Unauthorized,
    InvalidResponse,
    OutOfMemory,
};

pub const GhcrClient = struct {
    io: std.Io,
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
    /// Bottle/registry base URL (no trailing slash). Mutable post-init
    /// so cli/ call sites can drop in `ctx.mirrors.bottle_base`;
    /// mirror precedence + HTTPS validation are enforced upstream by
    /// `mirror.resolve`.
    base_url: []const u8 = mirror_mod.default_bottle_base_url,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, http: *client_mod.HttpClient) GhcrClient {
        return .{
            .io = io,
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
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        if (self.cached_token == null) return false;
        if (now >= self.token_expiry) return false;
        return self.cached_scopes.contains(repo);
    }

    /// Build the registry token URL covering every repo in `repos`. One
    /// `scope=repository:{repo}:pull` query param per repo; the registry
    /// returns a token valid for all of them. `base` lets corporate
    /// mirrors point at their own `/token` endpoint. Caller owns the
    /// result.
    pub fn buildTokenUrl(allocator: std.mem.Allocator, base: []const u8, repos: []const []const u8) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        try aw.writer.print("{s}/token?", .{base});
        for (repos, 0..) |repo, i| {
            if (i != 0) try aw.writer.writeByte('&');
            try aw.writer.print("scope=repository:{s}:pull", .{repo});
        }
        return aw.toOwnedSlice();
    }

    /// Build the registry blob URL for `(repo, digest)`. Pure, `pub`
    /// so tests can pin the override-honouring shape.
    pub fn buildBlobUrl(buf: []u8, base: []const u8, repo: []const u8, digest: []const u8) GhcrError![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/v2/{s}/blobs/{s}", .{ base, repo, digest }) catch
            GhcrError.OutOfMemory;
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

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.clearCache();

        const url = buildTokenUrl(self.allocator, self.base_url, repos) catch return GhcrError.OutOfMemory;
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
        self.token_expiry = std.Io.Clock.real.now(self.io).toSeconds() + 270; // 4.5 min of the 5 min TTL
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
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const now = std.Io.Clock.real.now(self.io).toSeconds();
        if (self.cached_token) |t| {
            if (now < self.token_expiry and self.cached_scopes.contains(repo)) {
                return self.allocator.dupe(u8, t) catch GhcrError.OutOfMemory;
            }
            self.clearCache();
        }

        const repos = [_][]const u8{repo};
        const url = buildTokenUrl(self.allocator, self.base_url, &repos) catch
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
        const token = self.fetchToken(http, repo) catch return GhcrError.TokenFetchFailed;
        defer self.allocator.free(token);

        var url_buf: [512]u8 = undefined;
        const url = try buildBlobUrl(&url_buf, self.base_url, repo, digest);

        var auth_buf: [2048]u8 = undefined;
        const auth_value = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch
            return GhcrError.OutOfMemory;

        const headers = [_]std.http.Header{
            .{ .name = "Authorization", .value = auth_value },
        };

        var resp = http.getWithHeaders(url, &headers, progress) catch
            return GhcrError.DownloadFailed;
        defer resp.deinit();

        if (resp.status == 401) return GhcrError.Unauthorized;
        if (resp.status != 200) {
            return classifyGhcrStatus(resp.status);
        }

        body_out.appendSlice(allocator, resp.body) catch return GhcrError.OutOfMemory;
    }

    pub fn classifyGhcrStatus(status: u16) GhcrError {
        if (client_mod.classifyStatus(status)) |dl_err| {
            return switch (dl_err) {
                error.RateLimited => GhcrError.DownloadRateLimited,
                error.HttpClientError => GhcrError.DownloadHttpClientError,
                error.HttpServerError => GhcrError.DownloadHttpServerError,
                error.Timeout => GhcrError.DownloadTimeout,
                error.ConnectionReset => GhcrError.DownloadConnectionReset,
                else => GhcrError.DownloadFailed,
            };
        }
        return GhcrError.DownloadFailed;
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

// ── inline tests: base_url default + URL builders honour overrides ──

const testing = std.testing;

test "GhcrClient.init defaults base_url to the upstream GHCR host" {
    var pool = try client_mod.HttpClientPool.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator, 1);
    defer pool.deinit();
    const http = pool.acquire();
    defer pool.release(http);

    var g = GhcrClient.init(std.Options.debug_io, testing.allocator, http);
    defer g.deinit();

    try testing.expectEqualStrings(mirror_mod.default_bottle_base_url, g.base_url);
}

test "buildTokenUrl emits scope params against a mirror base URL" {
    const repos = [_][]const u8{ "homebrew/core/wget", "homebrew/core/tree" };
    const url = try GhcrClient.buildTokenUrl(testing.allocator, "https://reg.example.com", &repos);
    defer testing.allocator.free(url);
    try testing.expectEqualStrings(
        "https://reg.example.com/token?" ++
            "scope=repository:homebrew/core/wget:pull&" ++
            "scope=repository:homebrew/core/tree:pull",
        url,
    );
}

test "buildBlobUrl threads the override base into the blob path" {
    var buf: [256]u8 = undefined;
    const url = try GhcrClient.buildBlobUrl(&buf, "https://reg.example.com", "homebrew/core/wget", "sha256:abc");
    try testing.expectEqualStrings("https://reg.example.com/v2/homebrew/core/wget/blobs/sha256:abc", url);
}

test "buildBlobUrl returns OutOfMemory when the buffer can't hold the URL" {
    var tiny: [8]u8 = undefined;
    try testing.expectError(GhcrError.OutOfMemory, GhcrClient.buildBlobUrl(&tiny, "https://reg.example.com", "homebrew/core/wget", "sha256:abc"));
}
