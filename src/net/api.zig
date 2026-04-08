//! malt — Homebrew API client
//! Fetches formula and cask metadata from formulae.brew.sh with caching.

const std = @import("std");
const client_mod = @import("client.zig");

const BASE_URL = "https://formulae.brew.sh/api";
const CACHE_TTL_SECS: i64 = 300; // 5 minutes

pub const ApiError = error{
    NotFound,
    ApiUnreachable,
    InvalidResponse,
    CacheError,
    OutOfMemory,
};

pub const BrewApi = struct {
    allocator: std.mem.Allocator,
    http: *client_mod.HttpClient,
    cache_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, http: *client_mod.HttpClient, cache_dir: []const u8) BrewApi {
        return .{
            .allocator = allocator,
            .http = http,
            .cache_dir = cache_dir,
        };
    }

    /// Fetch formula JSON. Returns caller-owned bytes.
    pub fn fetchFormula(self: *BrewApi, name: []const u8) ApiError![]const u8 {
        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, BASE_URL ++ "/formula/{s}.json", .{name}) catch
            return ApiError.OutOfMemory;
        return self.fetchCached(name, url, "formula_");
    }

    /// Fetch cask JSON. Returns caller-owned bytes.
    pub fn fetchCask(self: *BrewApi, token: []const u8) ApiError![]const u8 {
        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, BASE_URL ++ "/cask/{s}.json", .{token}) catch
            return ApiError.OutOfMemory;
        return self.fetchCached(token, url, "cask_");
    }

    /// Invalidate all cached API responses.
    pub fn invalidateCache(self: *BrewApi) void {
        var api_path_buf: [512]u8 = undefined;
        const api_path = std.fmt.bufPrint(&api_path_buf, "{s}/api", .{self.cache_dir}) catch return;
        std.fs.deleteTreeAbsolute(api_path) catch {};
    }

    // --- internal ---

    fn fetchCached(self: *BrewApi, key: []const u8, url: []const u8, prefix: []const u8) ApiError![]const u8 {
        // Try to read from cache
        if (self.readCache(key, prefix)) |cached| return cached;

        // Cache miss or expired — fetch from API
        var resp = self.http.get(url) catch return ApiError.ApiUnreachable;
        defer resp.deinit();

        if (resp.status == 404) return ApiError.NotFound;
        if (resp.status != 200) return ApiError.ApiUnreachable;

        // Save to cache (best effort)
        self.writeCache(key, prefix, resp.body);

        // Return owned copy
        return self.allocator.dupe(u8, resp.body) catch return ApiError.OutOfMemory;
    }

    fn readCache(self: *BrewApi, key: []const u8, prefix: []const u8) ?[]const u8 {
        var path_buf: [512]u8 = undefined;
        const cache_path = std.fmt.bufPrint(&path_buf, "{s}/api/{s}{s}.json", .{ self.cache_dir, prefix, key }) catch return null;

        // Check freshness
        const stat = std.fs.cwd().statFile(cache_path) catch return null;
        const now = std.time.timestamp();
        const mtime_secs: i64 = @intCast(@divTrunc(stat.mtime, std.time.ns_per_s));
        if (now - mtime_secs > CACHE_TTL_SECS) return null;

        // Read file
        const file = std.fs.cwd().openFile(cache_path, .{}) catch return null;
        defer file.close();
        const file_stat = file.stat() catch return null;
        const content = self.allocator.alloc(u8, file_stat.size) catch return null;
        const bytes_read = file.readAll(content) catch {
            self.allocator.free(content);
            return null;
        };
        if (bytes_read < content.len) {
            self.allocator.free(content);
            return null;
        }
        return content;
    }

    fn writeCache(self: *const BrewApi, key: []const u8, prefix: []const u8, data: []const u8) void {
        var dir_buf: [512]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/api", .{self.cache_dir}) catch return;
        std.fs.makeDirAbsolute(dir_path) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return,
        };

        var path_buf: [512]u8 = undefined;
        const cache_path = std.fmt.bufPrint(&path_buf, "{s}/api/{s}{s}.json", .{ self.cache_dir, prefix, key }) catch return;

        const file = std.fs.cwd().createFile(cache_path, .{}) catch return;
        defer file.close();
        file.writeAll(data) catch {};
    }
};
