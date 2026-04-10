//! malt — GHCR client
//! Token management and blob fetching for GitHub Container Registry.

const std = @import("std");

const client_mod = @import("client.zig");

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
    cached_repo: ?[]const u8,
    token_expiry: i64,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, http: *client_mod.HttpClient) GhcrClient {
        return .{
            .allocator = allocator,
            .http = http,
            .cached_token = null,
            .cached_repo = null,
            .token_expiry = 0,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *GhcrClient) void {
        if (self.cached_token) |t| self.allocator.free(t);
        if (self.cached_repo) |r| self.allocator.free(r);
    }

    /// Fetch an anonymous GHCR token for a repository.
    /// repo format: "homebrew/core/wget" -> scope=repository:homebrew/core/wget:pull
    pub fn fetchToken(self: *GhcrClient, repo: []const u8) GhcrError![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Double-checked: if token still valid AND for the same repo, return cached
        const now = std.time.timestamp();
        if (self.cached_token) |t| {
            const same_repo = if (self.cached_repo) |cr| std.mem.eql(u8, cr, repo) else false;
            if (now < self.token_expiry and same_repo) return t;
            self.allocator.free(t);
            self.cached_token = null;
            if (self.cached_repo) |cr| {
                self.allocator.free(cr);
                self.cached_repo = null;
            }
        }

        // Build URL: https://ghcr.io/token?scope=repository:{repo}:pull
        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://ghcr.io/token?scope=repository:{s}:pull", .{repo}) catch
            return GhcrError.OutOfMemory;

        // Use a short-lived HTTP client to avoid sharing the parent's
        // std.http.Client across threads (it is not thread-safe).
        var local_http = client_mod.HttpClient.init(self.allocator);
        defer local_http.deinit();

        var resp = local_http.get(url) catch return GhcrError.TokenFetchFailed;
        defer resp.deinit();

        if (resp.status != 200) return GhcrError.TokenFetchFailed;

        // Parse JSON to extract "token" field
        const token = extractTokenField(self.allocator, resp.body) catch
            return GhcrError.InvalidResponse;

        self.cached_token = token;
        self.cached_repo = self.allocator.dupe(u8, repo) catch null;
        self.token_expiry = now + 270; // 4.5 min buffer before 5 min expiry
        return token;
    }

    /// Download a blob from GHCR, handling 401 -> token -> retry.
    /// Thread-safe: uses mutex-protected token cache and per-thread HTTP client.
    pub fn downloadBlob(
        self: *GhcrClient,
        allocator: std.mem.Allocator,
        repo: []const u8,
        digest: []const u8,
        body_out: *std.ArrayList(u8),
        progress: ?client_mod.ProgressCallback,
    ) GhcrError!void {
        // Get token through the mutex-protected cache (avoids redundant fetches)
        const token = self.fetchToken(repo) catch return GhcrError.TokenFetchFailed;

        // Each download gets its own HTTP client (thread-safe)
        var http = client_mod.HttpClient.init(allocator);
        defer http.deinit();

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
fn extractTokenField(allocator: std.mem.Allocator, json_bytes: []const u8) ![]const u8 {
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
