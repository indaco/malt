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
    InvalidName,
    CacheError,
    OutOfMemory,
};

/// Validate a formula/cask name to prevent path traversal and URL injection.
/// Allowed characters: [a-z0-9@._+-]
pub fn validateName(name: []const u8) ApiError!void {
    if (name.len == 0 or name.len > 128) return ApiError.InvalidName;
    if (std.mem.indexOf(u8, name, "..") != null) return ApiError.InvalidName;
    for (name) |ch| {
        switch (ch) {
            'a'...'z', '0'...'9', '@', '.', '_', '+', '-' => {},
            else => return ApiError.InvalidName,
        }
    }
}

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
        try validateName(name);
        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, BASE_URL ++ "/formula/{s}.json", .{name}) catch
            return ApiError.OutOfMemory;
        return self.fetchCached(name, url, "formula_");
    }

    /// Fetch cask JSON. Returns caller-owned bytes.
    pub fn fetchCask(self: *BrewApi, token: []const u8) ApiError![]const u8 {
        try validateName(token);
        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, BASE_URL ++ "/cask/{s}.json", .{token}) catch
            return ApiError.OutOfMemory;
        return self.fetchCached(token, url, "cask_");
    }

    pub const Kind = enum { formula, cask };

    /// Existence probe that reuses the same cache layout as `fetchFormula` /
    /// `fetchCask` without ever reading the cached body. On a warm 5-minute
    /// cache this is a single `statFile` call; on a miss it falls through to
    /// the regular fetch path so the caller's subsequent install still finds
    /// the body on disk. Returns `false` for names that 404; `InvalidName` /
    /// `ApiUnreachable` are propagated.
    pub fn exists(self: *BrewApi, name: []const u8, kind: Kind) ApiError!bool {
        try validateName(name);
        const prefix: []const u8 = switch (kind) {
            .formula => "formula_",
            .cask => "cask_",
        };

        if (self.readNotFoundCache(name, prefix)) return false;
        if (self.cachedFresh(name, prefix)) return true;

        // Cache miss — do a real fetch so the body is cached for any
        // follow-up `install`. We own the result but don't need it.
        const body = (switch (kind) {
            .formula => self.fetchFormula(name),
            .cask => self.fetchCask(name),
        }) catch |e| switch (e) {
            ApiError.NotFound => return false,
            else => return e,
        };
        self.allocator.free(body);
        return true;
    }

    /// Return true iff a fresh 200 cache entry exists for `key` — same
    /// TTL rule as `readCache`, but without reading the body.
    fn cachedFresh(self: *BrewApi, key: []const u8, prefix: []const u8) bool {
        var path_buf: [512]u8 = undefined;
        const cache_path = std.fmt.bufPrint(&path_buf, "{s}/api/{s}{s}.json", .{ self.cache_dir, prefix, key }) catch return false;
        const stat = std.fs.cwd().statFile(cache_path) catch return false;
        const now = std.time.timestamp();
        const mtime_secs: i64 = @intCast(@divTrunc(stat.mtime, std.time.ns_per_s));
        return now - mtime_secs <= CACHE_TTL_SECS;
    }

    /// Invalidate all cached API responses.
    pub fn invalidateCache(self: *BrewApi) void {
        var api_path_buf: [512]u8 = undefined;
        const api_path = std.fmt.bufPrint(&api_path_buf, "{s}/api", .{self.cache_dir}) catch return;
        std.fs.deleteTreeAbsolute(api_path) catch {};
    }

    // --- internal ---

    fn fetchCached(self: *BrewApi, key: []const u8, url: []const u8, prefix: []const u8) ApiError![]const u8 {
        // Fast path: if a prior lookup already learned this name is a 404
        // (e.g. cask-ambiguity probe for a formula), bail before we hit
        // the network. Without this, `malt install <formula>` did one
        // real HTTP round-trip on every single run because 404s were
        // never cached.
        if (self.readNotFoundCache(key, prefix)) return ApiError.NotFound;

        // Try the normal success cache.
        if (self.readCache(key, prefix)) |cached| return cached;

        // Cache miss or expired — fetch from API
        var resp = self.http.get(url) catch return ApiError.ApiUnreachable;
        defer resp.deinit();

        if (resp.status == 404) {
            self.writeNotFoundCache(key, prefix);
            return ApiError.NotFound;
        }
        if (resp.status != 200) return ApiError.ApiUnreachable;

        // Save to cache (best effort)
        self.writeCache(key, prefix, resp.body);

        // Return owned copy
        return self.allocator.dupe(u8, resp.body) catch return ApiError.OutOfMemory;
    }

    pub fn readCache(self: *BrewApi, key: []const u8, prefix: []const u8) ?[]const u8 {
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

    pub fn writeCache(self: *const BrewApi, key: []const u8, prefix: []const u8, data: []const u8) void {
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

    /// Check for a cached 404 marker. Returns true if a fresh marker
    /// exists for this key — callers should treat that as `NotFound`
    /// and skip the network. Uses the same TTL as success responses
    /// so the cache auto-refreshes if the upstream ever starts
    /// returning 200.
    pub fn readNotFoundCache(self: *BrewApi, key: []const u8, prefix: []const u8) bool {
        var path_buf: [512]u8 = undefined;
        const cache_path = std.fmt.bufPrint(&path_buf, "{s}/api/{s}{s}.404", .{ self.cache_dir, prefix, key }) catch return false;

        const stat = std.fs.cwd().statFile(cache_path) catch return false;
        const now = std.time.timestamp();
        const mtime_secs: i64 = @intCast(@divTrunc(stat.mtime, std.time.ns_per_s));
        if (now - mtime_secs > CACHE_TTL_SECS) return false;
        return true;
    }

    /// Write a zero-byte marker file to record that this key 404s. The
    /// file's mtime is the TTL anchor — `readNotFoundCache` checks it
    /// against `CACHE_TTL_SECS`. Best-effort; failures are silent so a
    /// missing cache dir never breaks an install.
    pub fn writeNotFoundCache(self: *const BrewApi, key: []const u8, prefix: []const u8) void {
        var dir_buf: [512]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/api", .{self.cache_dir}) catch return;
        std.fs.makeDirAbsolute(dir_path) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return,
        };

        var path_buf: [512]u8 = undefined;
        const cache_path = std.fmt.bufPrint(&path_buf, "{s}/api/{s}{s}.404", .{ self.cache_dir, prefix, key }) catch return;

        const file = std.fs.cwd().createFile(cache_path, .{}) catch return;
        file.close();
    }

    /// Maximum cache size (200 MB). Entries are evicted by age (oldest first).
    const MAX_CACHE_BYTES: u64 = 200 * 1024 * 1024;

    /// Evict oldest cache entries until total size is under MAX_CACHE_BYTES.
    /// Called by `malt cleanup` and `malt doctor`.
    pub fn evictCache(self: *BrewApi) u32 {
        var dir_buf: [512]u8 = undefined;
        const api_path = std.fmt.bufPrint(&dir_buf, "{s}/api", .{self.cache_dir}) catch return 0;

        var dir = std.fs.openDirAbsolute(api_path, .{ .iterate = true }) catch return 0;
        defer dir.close();

        // Collect entries with size + mtime
        const Entry = struct { name_buf: [256]u8, name_len: usize, size: u64, mtime: i128 };
        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(self.allocator);
        var total_size: u64 = 0;

        var iter = dir.iterate();
        while (iter.next() catch null) |e| {
            if (e.kind != .file) continue;
            const stat = dir.statFile(e.name) catch continue;
            var entry: Entry = .{ .name_buf = undefined, .name_len = e.name.len, .size = stat.size, .mtime = stat.mtime };
            if (e.name.len > entry.name_buf.len) continue;
            @memcpy(entry.name_buf[0..e.name.len], e.name);
            entries.append(self.allocator, entry) catch continue;
            total_size += stat.size;
        }

        if (total_size <= MAX_CACHE_BYTES) return 0;

        // Sort by mtime ascending (oldest first)
        std.mem.sort(Entry, entries.items, {}, struct {
            fn cmp(_: void, a: Entry, b: Entry) bool {
                return a.mtime < b.mtime;
            }
        }.cmp);

        var evicted: u32 = 0;
        for (entries.items) |entry| {
            if (total_size <= MAX_CACHE_BYTES) break;
            const name = entry.name_buf[0..entry.name_len];
            dir.deleteFile(name) catch continue;
            total_size -|= entry.size;
            evicted += 1;
        }
        return evicted;
    }

    /// Return total cache size in bytes. Used by `malt doctor` for warnings.
    pub fn cacheSize(self: *BrewApi) u64 {
        var dir_buf: [512]u8 = undefined;
        const api_path = std.fmt.bufPrint(&dir_buf, "{s}/api", .{self.cache_dir}) catch return 0;

        var dir = std.fs.openDirAbsolute(api_path, .{ .iterate = true }) catch return 0;
        defer dir.close();

        var total: u64 = 0;
        var iter = dir.iterate();
        while (iter.next() catch null) |e| {
            if (e.kind != .file) continue;
            const stat = dir.statFile(e.name) catch continue;
            total += stat.size;
        }
        return total;
    }
};
