//! malt — regression test for the deps.resolve() memory leak
//!
//! Runs exclusively under `testing.allocator` so Zig's leak detector
//! catches any regression of the bug that used to orphan duped dep
//! strings on the BFS visited-dedup path.
//!
//! Before the fix: every time a sub-dep was already present in the
//! `visited` set, its heap-duped slice was silently dropped on the
//! floor (no `allocator.free`). `getDeps` also leaked individual
//! duped strings whenever its internal `ArrayList.append` failed.
//!
//! The graph below has a diamond dep (`d` reached via both `b` and
//! `c`) and a back-edge (`d → b` after `b` is already visited), so
//! every path through the BFS dedup branch is exercised at least
//! once.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const deps_mod = malt.deps;
const sqlite = malt.sqlite;
const schema = malt.schema;
const api_mod = malt.api;
const client_mod = malt.client;

/// Minimal on-disk SQLite DB wrapper: just enough to let
/// `deps.resolve()` run `isInstalled` lookups.
const TempDb = struct {
    dir: []const u8,
    db: sqlite.Database,

    fn init(comptime tag: []const u8) !TempDb {
        const dir = "/tmp/malt_deps_leak_test_" ++ tag;
        malt.fs_compat.makeDirAbsolute(dir) catch {};
        var buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&buf, "{s}/test.db", .{dir}, 0);
        var db = try sqlite.Database.open(path);
        errdefer db.close();
        try schema.initSchema(&db);
        return .{ .dir = dir, .db = db };
    }

    fn deinit(self: *TempDb) void {
        self.db.close();
        malt.fs_compat.deleteTreeAbsolute(self.dir) catch {};
    }
};

/// Cache directory wrapper used to pre-seed `BrewApi` with fake
/// formula JSON files, short-circuiting the network.
const TempCacheDir = struct {
    path: []const u8,

    fn init(comptime tag: []const u8) !TempCacheDir {
        const p = "/tmp/malt_deps_leak_cache_" ++ tag;
        malt.fs_compat.deleteTreeAbsolute(p) catch {};
        try malt.fs_compat.makeDirAbsolute(p);
        return .{ .path = p };
    }

    fn deinit(self: *TempCacheDir) void {
        malt.fs_compat.deleteTreeAbsolute(self.path) catch {};
    }

    fn writeFormula(self: *TempCacheDir, name: []const u8, json: []const u8) !void {
        var api_buf: [512]u8 = undefined;
        const api_dir = try std.fmt.bufPrint(&api_buf, "{s}/api", .{self.path});
        malt.fs_compat.makeDirAbsolute(api_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        var path_buf: [512]u8 = undefined;
        const full = try std.fmt.bufPrint(&path_buf, "{s}/api/formula_{s}.json", .{ self.path, name });
        const f = try malt.fs_compat.cwd().createFile(full, .{});
        defer f.close();
        try f.writeAll(json);
    }
};

/// Free the slice returned by `deps.resolve()`. Each `ResolvedDep.name`
/// is heap-allocated by resolve, and so is the outer slice.
fn freeResolved(alloc: std.mem.Allocator, r: []deps_mod.ResolvedDep) void {
    for (r) |d| alloc.free(d.name);
    alloc.free(r);
}

test "resolve frees duped dep strings on the BFS visited-dedup path" {
    // Graph:
    //   a → [b, c]
    //   b → [d]
    //   c → [d]          (d appears via both b and c → diamond dedup)
    //   d → [b]          (b appears again after b is visited → back-edge dedup)
    //
    // With the fix, every string returned by getDeps is either placed
    // in `result` or freed explicitly — the Zig testing allocator would
    // otherwise flag the leak.
    const alloc = testing.allocator;

    var dir = try TempCacheDir.init("dedup");
    defer dir.deinit();

    try dir.writeFormula("a", "{\"dependencies\":[\"b\",\"c\"]}");
    try dir.writeFormula("b", "{\"dependencies\":[\"d\"]}");
    try dir.writeFormula("c", "{\"dependencies\":[\"d\"]}");
    try dir.writeFormula("d", "{\"dependencies\":[\"b\"]}");

    var http = client_mod.HttpClient.init(alloc);
    defer http.deinit();
    var api = api_mod.BrewApi.init(alloc, &http, dir.path);

    var tdb = try TempDb.init("dedup");
    defer tdb.deinit();

    const result = try deps_mod.resolve(alloc, "a", &api, &tdb.db);
    defer freeResolved(alloc, result);

    // Each distinct dep appears exactly once.
    try testing.expectEqual(@as(usize, 3), result.len);
    var seen_b = false;
    var seen_c = false;
    var seen_d = false;
    for (result) |r| {
        if (std.mem.eql(u8, r.name, "b")) seen_b = true;
        if (std.mem.eql(u8, r.name, "c")) seen_c = true;
        if (std.mem.eql(u8, r.name, "d")) seen_d = true;
    }
    try testing.expect(seen_b);
    try testing.expect(seen_c);
    try testing.expect(seen_d);
}

test "resolve empty dep graph still returns a freeable slice" {
    // An already-installed root with no queued deps still goes through
    // the final `toOwnedSlice` path. `testing.allocator` will flag any
    // missed free.
    const alloc = testing.allocator;

    var dir = try TempCacheDir.init("empty");
    defer dir.deinit();

    try dir.writeFormula("solo", "{\"dependencies\":[]}");

    var http = client_mod.HttpClient.init(alloc);
    defer http.deinit();
    var api = api_mod.BrewApi.init(alloc, &http, dir.path);

    var tdb = try TempDb.init("empty");
    defer tdb.deinit();

    const result = try deps_mod.resolve(alloc, "solo", &api, &tdb.db);
    defer freeResolved(alloc, result);

    try testing.expectEqual(@as(usize, 0), result.len);
}
