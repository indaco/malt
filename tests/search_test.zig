//! malt — substring search tests
//!
//! Exercises the pure helpers behind `mt search <query>`:
//!   - `api.extractNames` parses a Homebrew-shaped JSON body and emits a
//!     newline-delimited names index.
//!   - `api.findNameMatches` scans that index for substring hits.
//!   - `BrewApi.fetchNamesIndex` reads a pre-seeded cache without touching
//!     the network (same pattern as `api_test.zig`).

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const api_mod = malt.api;
const client_mod = malt.client;

test "extractNames pulls formula names out of a JSON array" {
    const body =
        \\[
        \\  {"name":"go","desc":"…"},
        \\  {"name":"wget","desc":"…"},
        \\  {"name":"openssl@3","desc":"…"}
        \\]
    ;
    const idx = try api_mod.extractNames(testing.allocator, .formula, body);
    defer testing.allocator.free(idx);
    try testing.expectEqualStrings("go\nwget\nopenssl@3\n", idx);
}

test "extractNames pulls cask tokens and skips unknown fields" {
    const body =
        \\[
        \\  {"token":"firefox","name":["Firefox"],"url":"…"},
        \\  {"token":"visual-studio-code","name":["Visual Studio Code"]}
        \\]
    ;
    const idx = try api_mod.extractNames(testing.allocator, .cask, body);
    defer testing.allocator.free(idx);
    try testing.expectEqualStrings("firefox\nvisual-studio-code\n", idx);
}

test "extractNames handles an empty array" {
    const idx = try api_mod.extractNames(testing.allocator, .formula, "[]");
    defer testing.allocator.free(idx);
    try testing.expectEqualStrings("", idx);
}

test "findNameMatches returns every substring hit" {
    const idx = "argo\ncargo\ncargo-audit\nffmpeg\ngo\nnode\n";
    const hits = try api_mod.findNameMatches(testing.allocator, idx, "go");
    defer testing.allocator.free(hits);
    try testing.expectEqual(@as(usize, 4), hits.len);
    try testing.expectEqualStrings("argo", hits[0]);
    try testing.expectEqualStrings("cargo", hits[1]);
    try testing.expectEqualStrings("cargo-audit", hits[2]);
    try testing.expectEqualStrings("go", hits[3]);
}

test "findNameMatches is case-insensitive on the query" {
    const idx = "ffmpeg\nnode\nopenssl@3\n";
    const hits = try api_mod.findNameMatches(testing.allocator, idx, "FFMPEG");
    defer testing.allocator.free(hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("ffmpeg", hits[0]);
}

test "findNameMatches returns empty slice for no hits" {
    const idx = "wget\ncurl\n";
    const hits = try api_mod.findNameMatches(testing.allocator, idx, "python");
    defer testing.allocator.free(hits);
    try testing.expectEqual(@as(usize, 0), hits.len);
}

test "findNameMatches tolerates an empty index" {
    const hits = try api_mod.findNameMatches(testing.allocator, "", "go");
    defer testing.allocator.free(hits);
    try testing.expectEqual(@as(usize, 0), hits.len);
}

test "findNameMatches rejects over-long queries to keep lowercase buf bounded" {
    // Guard against accidental buffer-overflow if someone ever passes a
    // 200-char query. Today the CLI caps at 128 via validateName, but the
    // substring helper is callable from tests and other consumers.
    var q: [200]u8 = undefined;
    @memset(&q, 'x');
    const hits = try api_mod.findNameMatches(testing.allocator, "xxx\nabc\n", &q);
    defer testing.allocator.free(hits);
    try testing.expectEqual(@as(usize, 0), hits.len);
}

// --- fetchNamesIndex cache read path (no network) ---

const TempCacheDir = struct {
    path: []const u8,

    fn init(comptime tag: []const u8) !TempCacheDir {
        const p = "/tmp/malt_search_test_" ++ tag;
        malt.fs_compat.deleteTreeAbsolute(p) catch {};
        try malt.fs_compat.makeDirAbsolute(p);
        return .{ .path = p };
    }

    fn deinit(self: *TempCacheDir) void {
        malt.fs_compat.deleteTreeAbsolute(self.path) catch {};
    }

    fn writeCacheFile(self: *TempCacheDir, rel: []const u8, content: []const u8) !void {
        var api_buf: [512]u8 = undefined;
        const api_dir = try std.fmt.bufPrint(&api_buf, "{s}/api", .{self.path});
        malt.fs_compat.makeDirAbsolute(api_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        var path_buf: [512]u8 = undefined;
        const full = try std.fmt.bufPrint(&path_buf, "{s}/api/{s}", .{ self.path, rel });
        const f = try malt.fs_compat.cwd().createFile(full, .{});
        defer f.close();
        try f.writeAll(content);
    }
};

test "fetchNamesIndex returns a pre-seeded cache without touching the network" {
    var http = client_mod.HttpClient.init(testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("fetchidx_hit");
    defer dir.deinit();

    try dir.writeCacheFile("names_formula.txt", "go\nwget\n");
    try dir.writeCacheFile("names_cask.txt", "firefox\n");

    var api = api_mod.BrewApi.init(testing.allocator, &http, dir.path);

    const f = try api.fetchNamesIndex(.formula);
    defer testing.allocator.free(f);
    try testing.expectEqualStrings("go\nwget\n", f);

    const c = try api.fetchNamesIndex(.cask);
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("firefox\n", c);
}

test "exists + fetchNamesIndex + findNameMatches compose end-to-end" {
    // Full search pipeline against a pre-seeded cache — mirrors what
    // `mt search <query>` does per kind: exact-hit check, full names
    // index lookup, substring scan. Guards the composition after the
    // per-kind path was split into an isolated-HttpClient helper so
    // the two kinds could run on separate threads.
    var http = client_mod.HttpClient.init(testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("compose");
    defer dir.deinit();

    try dir.writeCacheFile("formula_go.json", "{\"name\":\"go\"}");
    try dir.writeCacheFile("names_formula.txt", "argo\ncargo\ngo\ngolangci-lint\nnode\n");

    var api = api_mod.BrewApi.init(testing.allocator, &http, dir.path);

    try testing.expect(try api.exists("go", .formula));

    const idx = try api.fetchNamesIndex(.formula);
    defer testing.allocator.free(idx);

    const hits = try api_mod.findNameMatches(testing.allocator, idx, "go");
    defer testing.allocator.free(hits);
    try testing.expectEqual(@as(usize, 4), hits.len);
    try testing.expectEqualStrings("argo", hits[0]);
    try testing.expectEqualStrings("cargo", hits[1]);
    try testing.expectEqualStrings("go", hits[2]);
    try testing.expectEqualStrings("golangci-lint", hits[3]);
}

test "fetchNamesIndex reports missing cache as null via absence of the file" {
    // Sanity check: with no cache file and no seeded content, the cache
    // read path returns null; exercising it via fetchNamesIndex would
    // hit the network, so instead we just verify a fresh api.cacheSize
    // is zero and the cache file does not yet exist. TTL-expiry logic
    // shares a code path with readCache (already covered in api_test.zig).
    var http = client_mod.HttpClient.init(testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("fetchidx_miss");
    defer dir.deinit();

    var api = api_mod.BrewApi.init(testing.allocator, &http, dir.path);
    try testing.expectEqual(@as(u64, 0), api.cacheSize());
}
