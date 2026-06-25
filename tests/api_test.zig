//! malt — Homebrew API client tests
//!
//! Exercises the pure validation logic and the on-disk cache read/write
//! paths. fetchFormula / fetchCask can be tested without hitting the
//! network by pre-seeding the cache file before the call — readCache
//! short-circuits fetchCached before any HTTP traffic.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");
const api_mod = malt.api;
const client_mod = malt.client;
const net = std.Io.net;

test "validateName accepts a simple formula" {
    try api_mod.validateName("wget");
}

test "validateName accepts version suffixes with @" {
    try api_mod.validateName("openssl@3");
    try api_mod.validateName("python@3.12");
}

test "validateName accepts +/-/_/. chars" {
    try api_mod.validateName("foo-bar_baz.2+x");
}

test "validateName rejects the empty string" {
    try testing.expectError(api_mod.ApiError.InvalidName, api_mod.validateName(""));
}

test "validateName rejects names longer than 128 bytes" {
    const long_name = "a" ** 129;
    try testing.expectError(api_mod.ApiError.InvalidName, api_mod.validateName(long_name));
}

test "validateName rejects parent-dir traversal" {
    try testing.expectError(api_mod.ApiError.InvalidName, api_mod.validateName(".."));
    try testing.expectError(api_mod.ApiError.InvalidName, api_mod.validateName("foo..bar"));
}

test "validateName rejects slashes and spaces" {
    try testing.expectError(api_mod.ApiError.InvalidName, api_mod.validateName("foo/bar"));
    try testing.expectError(api_mod.ApiError.InvalidName, api_mod.validateName("foo bar"));
    try testing.expectError(api_mod.ApiError.InvalidName, api_mod.validateName("FOO"));
}

// --- BrewApi cache tests (no network) ---

const TempCacheDir = struct {
    path: []const u8,

    fn init(comptime tag: []const u8) !TempCacheDir {
        const p = "/tmp/malt_api_test_" ++ tag;
        test_io.deleteTreeAbsolute(std.Options.debug_io, p) catch {};
        try test_io.makeDirAbsolute(std.Options.debug_io, p);
        return .{ .path = p };
    }

    fn deinit(self: *TempCacheDir) void {
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.path) catch {};
    }

    fn writeCacheFile(self: *TempCacheDir, rel: []const u8, content: []const u8) !void {
        // Make cache_dir/api first
        var api_buf: [512]u8 = undefined;
        const api_dir = try std.fmt.bufPrint(&api_buf, "{s}/api", .{self.path});
        test_io.makeDirAbsolute(std.Options.debug_io, api_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        var path_buf: [512]u8 = undefined;
        const full = try std.fmt.bufPrint(&path_buf, "{s}/api/{s}", .{ self.path, rel });
        const f = try test_io.cwd().createFile(std.Options.debug_io, full, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, content);
    }
};

test "BrewApi.init captures the caller's fields" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("init");
    defer dir.deinit();

    const api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    try testing.expectEqualStrings(dir.path, api.cache_dir);
}

test "fetchFormula returns a pre-seeded cache without touching the network" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("fetchformula_hit");
    defer dir.deinit();

    const json =
        \\{"name":"fake","versions":{"stable":"1.0"}}
    ;
    try dir.writeCacheFile("formula_fake.json", json);

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    const out = try api.fetchFormula("fake");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(json, out);
}

test "BrewApi honours a base_url override and threads it through fetchFormula's URL" {
    // We can't easily intercept the live HTTP call inside fetchFormula
    // without a fake client, so split the assertion: pin the override
    // on the struct, then exercise the pure URL builder against the
    // same value to prove the path malt would request matches the
    // mirror.
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("fetchformula_override");
    defer dir.deinit();

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    api.base_url = "https://mirror.example.com/api";
    try testing.expectEqualStrings("https://mirror.example.com/api", api.base_url);

    var url_buf: [256]u8 = undefined;
    const url = try api_mod.BrewApi.buildFormulaUrl(&url_buf, api.base_url, "wget");
    try testing.expectEqualStrings("https://mirror.example.com/api/formula/wget.json", url);
}

test "BrewApi cache lookup is shared between the default and the override" {
    // Pre-seeded cache hits short-circuit before the URL is built, so a
    // warm cache works regardless of which base_url is active. Pins the
    // contract that flipping the env knob doesn't invalidate prior cache
    // bytes for the same formula name.
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("fetchformula_shared_cache");
    defer dir.deinit();

    const json =
        \\{"name":"wget","versions":{"stable":"1.0"}}
    ;
    try dir.writeCacheFile("formula_wget.json", json);

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    api.base_url = "https://mirror.example.com/api";
    const out = try api.fetchFormula("wget");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(json, out);
}

test "fetchCask returns a pre-seeded cache without touching the network" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("fetchcask_hit");
    defer dir.deinit();

    const json =
        \\{"token":"gimp","version":"2.10"}
    ;
    try dir.writeCacheFile("cask_gimp.json", json);

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    const out = try api.fetchCask("gimp");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(json, out);
}

test "fetchFormula honors a fresh NotFound marker without hitting the network" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("notfound_marker");
    defer dir.deinit();

    // Writing an empty .404 sentinel file is exactly what writeNotFoundCache
    // does after a real 404. readNotFoundCache only cares about the mtime
    // being fresh, so a freshly-created file always counts.
    try dir.writeCacheFile("formula_ghost.404", "");

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    try testing.expectError(api_mod.ApiError.NotFound, api.fetchFormula("ghost"));
}

test "fetchFormula surfaces InvalidName before any cache lookup" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("invalid_name");
    defer dir.deinit();

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    try testing.expectError(api_mod.ApiError.InvalidName, api.fetchFormula(""));
    try testing.expectError(api_mod.ApiError.InvalidName, api.fetchCask("bad name"));
}

test "invalidateCache removes the cached api directory" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("invalidate");
    defer dir.deinit();

    try dir.writeCacheFile("formula_x.json", "{}");

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    api.invalidateCache();

    // After invalidation, the api/ subdir should be gone → next cache probe
    // falls through. We re-seed and re-read to verify the cache write path
    // continues to work after invalidation.
    try dir.writeCacheFile("formula_x.json", "{\"v\":2}");
    const out = try api.fetchFormula("x");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"v\":2}", out);
}

test "cacheSize is zero for an empty cache and non-zero after writes" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("cachesize");
    defer dir.deinit();

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    // api/ dir doesn't exist yet → openDirAbsolute fails → 0.
    try testing.expectEqual(@as(u64, 0), api.cacheSize());

    try dir.writeCacheFile("formula_a.json", "hello world");
    try testing.expect(api.cacheSize() >= "hello world".len);
}

test "evictCache is a no-op while total size is under the cap" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("evict_noop");
    defer dir.deinit();

    try dir.writeCacheFile("formula_a.json", "small");
    try dir.writeCacheFile("formula_b.json", "also small");

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    try testing.expectEqual(@as(u32, 0), api.evictCache());
}

test "writeCache then readCache round-trips a value" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("writecache");
    defer dir.deinit();

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);

    // writeCache creates api/ and the file; best-effort, no return.
    api.writeCache("kotlin", "formula_", "{\"name\":\"kotlin\"}");

    const got = api.readCache("kotlin", "formula_") orelse return error.ExpectedCacheHit;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("{\"name\":\"kotlin\"}", got);
}

test "writeNotFoundCache then readNotFoundCache returns true" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("writenotfound");
    defer dir.deinit();

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);

    api.writeNotFoundCache("missing", "formula_");
    try testing.expect(api.readNotFoundCache("missing", "formula_"));
}

test "readCache returns null when no cache entry exists" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("readcache_miss");
    defer dir.deinit();

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    try testing.expect(api.readCache("nope", "formula_") == null);
}

test "exists returns true when a fresh success cache entry is present" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("exists_hit");
    defer dir.deinit();

    try dir.writeCacheFile("formula_node.json", "{\"name\":\"node\"}");
    try dir.writeCacheFile("cask_firefox.json", "{\"token\":\"firefox\"}");

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    try testing.expect(try api.exists("node", .formula));
    try testing.expect(try api.exists("firefox", .cask));
}

test "exists returns false when a fresh 404 marker is present" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("exists_404");
    defer dir.deinit();

    try dir.writeCacheFile("formula_ghost.404", "");
    try dir.writeCacheFile("cask_phantom.404", "");

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    try testing.expect(!(try api.exists("ghost", .formula)));
    try testing.expect(!(try api.exists("phantom", .cask)));
}

test "exists rejects invalid names before any cache lookup" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("exists_invalid");
    defer dir.deinit();

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    try testing.expectError(api_mod.ApiError.InvalidName, api.exists("", .formula));
    try testing.expectError(api_mod.ApiError.InvalidName, api.exists("bad name", .cask));
    try testing.expectError(api_mod.ApiError.InvalidName, api.exists("..", .formula));
}

test "cachedExists returns true when a cask cache file is present" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("cached_exists_hit");
    defer dir.deinit();

    try dir.writeCacheFile("cask_firefox.json", "{\"token\":\"firefox\"}");

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    try testing.expect(api.cachedExists("firefox", .cask));
}

test "cachedExists returns false when no cache file is present" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("cached_exists_miss");
    defer dir.deinit();

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    try testing.expect(!api.cachedExists("ghost", .cask));
}

test "cachedExists ignores stale mtime — existence is the only check" {
    // Skipping the parse runs once the file is gone; for a present file
    // we hand off to fetchCask, which owns freshness. cachedExists must
    // not duplicate the TTL gate.
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("cached_exists_stale");
    defer dir.deinit();

    try dir.writeCacheFile("cask_old.json", "{}");
    var path_buf: [512]u8 = undefined;
    const full = try std.fmt.bufPrint(&path_buf, "{s}/api/cask_old.json", .{dir.path});
    const file = try test_io.cwd().openFile(std.Options.debug_io, full, .{ .mode = .write_only });
    defer file.close(std.Options.debug_io);
    try file.setTimestamps(std.Options.debug_io, .{
        .access_timestamp = .{ .new = .{ .nanoseconds = 0 } },
        .modify_timestamp = .{ .new = .{ .nanoseconds = 0 } },
    });

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    try testing.expect(api.cachedExists("old", .cask));
}

test "cachedExists discriminates formula vs cask cache files" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("cached_exists_kind");
    defer dir.deinit();

    try dir.writeCacheFile("formula_node.json", "{\"name\":\"node\"}");

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    try testing.expect(api.cachedExists("node", .formula));
    try testing.expect(!api.cachedExists("node", .cask));
}

test "fetchFormula under offline returns OfflineRequired on cache miss" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("offline_formula_miss");
    defer dir.deinit();

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    api.offline = true;
    try testing.expectError(api_mod.ApiError.OfflineRequired, api.fetchFormula("ghost"));
}

test "fetchCask under offline returns OfflineRequired on cache miss" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("offline_cask_miss");
    defer dir.deinit();

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    api.offline = true;
    try testing.expectError(api_mod.ApiError.OfflineRequired, api.fetchCask("ghost"));
}

test "fetchFormula under offline serves a fresh cache hit" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("offline_formula_fresh");
    defer dir.deinit();

    const json =
        \\{"name":"wget","versions":{"stable":"1.0"}}
    ;
    try dir.writeCacheFile("formula_wget.json", json);

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    api.offline = true;
    const out = try api.fetchFormula("wget");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(json, out);
}

test "fetchFormula under offline serves a stale cache hit (no TTL gate)" {
    // The whole point of offline is "use the snapshot, no matter how old".
    // The default 5-minute TTL gate is bypassed when `offline` is true so
    // a user on a plane still gets bytes from disk.
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("offline_formula_stale");
    defer dir.deinit();

    const json =
        \\{"name":"jq","versions":{"stable":"1.7"}}
    ;
    try dir.writeCacheFile("formula_jq.json", json);

    // Backdate mtime so the regular TTL would reject it.
    var path_buf: [512]u8 = undefined;
    const full = try std.fmt.bufPrint(&path_buf, "{s}/api/formula_jq.json", .{dir.path});
    const file = try test_io.cwd().openFile(std.Options.debug_io, full, .{ .mode = .write_only });
    defer file.close(std.Options.debug_io);
    try file.setTimestamps(std.Options.debug_io, .{
        .access_timestamp = .{ .new = .{ .nanoseconds = 0 } },
        .modify_timestamp = .{ .new = .{ .nanoseconds = 0 } },
    });

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    api.offline = true;
    const out = try api.fetchFormula("jq");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(json, out);
}

test "fetchFormula under offline still honours a fresh NotFound marker" {
    // 404 markers stay authoritative — the snapshot already learned this
    // name doesn't exist upstream, so OfflineRequired would be misleading.
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("offline_notfound");
    defer dir.deinit();

    try dir.writeCacheFile("formula_ghost.404", "");

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    api.offline = true;
    try testing.expectError(api_mod.ApiError.NotFound, api.fetchFormula("ghost"));
}

test "fetchNamesIndex under offline returns OfflineRequired on miss" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("offline_names_miss");
    defer dir.deinit();

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    api.offline = true;
    try testing.expectError(api_mod.ApiError.OfflineRequired, api.fetchNamesIndex(.formula));
}

test "BrewApi.offline defaults to false" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("offline_default_off");
    defer dir.deinit();

    const api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    try testing.expect(!api.offline);
}

// --- versions index (the outdated-check side-car) ---

// Serves its fixture body to every request and counts how many it answered.
// The loop exits when the listener is closed from the test thread, which
// unblocks the pending `accept`.
const CountingServer = struct {
    io: std.Io,
    listener: *net.Server,
    body: []const u8,
    count: std.atomic.Value(u32),

    fn serve(self: *CountingServer) void {
        while (true) {
            const stream = self.listener.accept(self.io) catch return;
            defer stream.close(self.io);
            var rbuf: [16 * 1024]u8 = undefined;
            var wbuf: [16 * 1024]u8 = undefined;
            var reader = stream.reader(self.io, &rbuf);
            var writer = stream.writer(self.io, &wbuf);
            var srv = std.http.Server.init(&reader.interface, &writer.interface);
            var req = srv.receiveHead() catch return;
            req.respond(self.body, .{}) catch return;
            _ = self.count.fetchAdd(1, .monotonic);
        }
    }
};

test "fetchVersionsIndex returns a fresh pre-seeded side-car without touching the network" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("versions_fresh_hit");
    defer dir.deinit();

    const seeded = "wget\t1.21.4\t0\njq\t1.7\t0\n";
    try dir.writeCacheFile("versions_formula.txt", seeded);

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    const out = try api.fetchVersionsIndex(.formula);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(seeded, out);
}

test "fetchVersionsIndex under offline serves a stale side-car (no TTL gate)" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("versions_offline_stale");
    defer dir.deinit();

    const seeded = "wget\t1.21.4\t0\n";
    try dir.writeCacheFile("versions_formula.txt", seeded);

    // Backdate mtime so the freshness gate would reject it.
    var path_buf: [512]u8 = undefined;
    const full = try std.fmt.bufPrint(&path_buf, "{s}/api/versions_formula.txt", .{dir.path});
    const file = try test_io.cwd().openFile(std.Options.debug_io, full, .{ .mode = .write_only });
    defer file.close(std.Options.debug_io);
    try file.setTimestamps(std.Options.debug_io, .{
        .access_timestamp = .{ .new = .{ .nanoseconds = 0 } },
        .modify_timestamp = .{ .new = .{ .nanoseconds = 0 } },
    });

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    api.offline = true;
    const out = try api.fetchVersionsIndex(.formula);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(seeded, out);
}

test "fetchVersionsIndex under offline returns OfflineRequired on miss" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("versions_offline_miss");
    defer dir.deinit();

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    api.offline = true;
    try testing.expectError(api_mod.ApiError.OfflineRequired, api.fetchVersionsIndex(.formula));
}

test "a cold names+versions cycle downloads the bulk dump exactly once" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const fixture =
        \\[{"name":"wget","versions":{"stable":"1.21.4"},"revision":0},
        \\ {"name":"openssl@3","versions":{"stable":"3.2.1"},"revision":2},
        \\ {"name":"nostable","revision":0}]
    ;

    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var srv = CountingServer{
        .io = io,
        .listener = &listener,
        .body = fixture,
        .count = std.atomic.Value(u32).init(0),
    };
    const thread = try std.Thread.spawn(.{}, CountingServer.serve, .{&srv});

    var dir = try TempCacheDir.init("versions_consolidate");
    defer dir.deinit();

    var inner: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    var http = client_mod.HttpClient.initWith(&inner, io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();

    var api = api_mod.BrewApi.init(io, testing.allocator, &http, dir.path);
    var base_buf: [64]u8 = undefined;
    api.base_url = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});

    // Names first (search's path), then versions. The second call must
    // read the side-car the first download already wrote — no re-fetch.
    const names = try api.fetchNamesIndex(.formula);
    defer testing.allocator.free(names);
    const versions = try api.fetchVersionsIndex(.formula);
    defer testing.allocator.free(versions);

    // Stop the server before asserting so a hung join can't mask a result.
    listener.deinit(io);
    thread.join();

    try testing.expectEqual(@as(u32, 1), srv.count.load(.monotonic));

    const want_versions = try api_mod.extractVersions(testing.allocator, .formula, fixture);
    defer testing.allocator.free(want_versions);
    try testing.expectEqualStrings(want_versions, versions);

    // The search path stays byte-for-byte what extractNames produced.
    const want_names = try api_mod.extractNames(testing.allocator, .formula, fixture);
    defer testing.allocator.free(want_names);
    try testing.expectEqualStrings(want_names, names);

    // invalidateCache wipes api/ wholesale → the versions side-car too.
    var vpath_buf: [512]u8 = undefined;
    const vpath = try std.fmt.bufPrint(&vpath_buf, "{s}/api/versions_formula.txt", .{dir.path});
    try test_io.accessAbsolute(io, vpath, .{});
    api.invalidateCache();
    try testing.expectError(error.FileNotFound, test_io.accessAbsolute(io, vpath, .{}));
}

test "readNotFoundCache returns false for stale marker" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("notfound_stale");
    defer dir.deinit();

    // Create a 404 marker with an ancient mtime (1970).
    try dir.writeCacheFile("formula_old.404", "");
    var path_buf: [512]u8 = undefined;
    const full = try std.fmt.bufPrint(&path_buf, "{s}/api/formula_old.404", .{dir.path});
    // Reopen and set mtime back via posix.utimensat-like helper.
    const file = try test_io.cwd().openFile(std.Options.debug_io, full, .{ .mode = .write_only });
    defer file.close(std.Options.debug_io);
    // Zig File.updateTimes signature: (atime, mtime) in ns.
    try file.setTimestamps(std.Options.debug_io, .{
        .access_timestamp = .{ .new = .{ .nanoseconds = 0 } },
        .modify_timestamp = .{ .new = .{ .nanoseconds = 0 } },
    });

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    try testing.expect(!api.readNotFoundCache("old", "formula_"));
}
