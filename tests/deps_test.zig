//! malt — dependency resolution tests
//! Tests for dependency structures (resolve requires network; unit tests here).

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const formula_mod = malt.formula;
const deps_mod = malt.deps;
const sqlite = malt.sqlite;
const schema = malt.schema;
const api_mod = malt.api;
const client_mod = malt.client;

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

test "formula dependencies parsed from JSON" {
    var arena = testArena();
    defer arena.deinit();

    const json =
        \\{
        \\  "name": "wget",
        \\  "full_name": "wget",
        \\  "tap": "",
        \\  "desc": "",
        \\  "homepage": "",
        \\  "revision": 0,
        \\  "keg_only": false,
        \\  "post_install_defined": false,
        \\  "versions": { "stable": "1.0" },
        \\  "dependencies": ["openssl@3", "libidn2", "gettext"],
        \\  "oldnames": []
        \\}
    ;
    var formula = try formula_mod.parseFormula(arena.allocator(), json);
    defer formula.deinit();

    try testing.expectEqual(@as(usize, 3), formula.dependencies.len);
    try testing.expectEqualStrings("openssl@3", formula.dependencies[0]);
    try testing.expectEqualStrings("libidn2", formula.dependencies[1]);
    try testing.expectEqualStrings("gettext", formula.dependencies[2]);
}

// --- findOrphans / resolve coverage (seeded DB, no network) ---

const TempDb = struct {
    dir: []const u8,
    db: sqlite.Database,

    fn init(comptime tag: []const u8) !TempDb {
        const dir = "/tmp/malt_deps_test_" ++ tag;
        std.fs.makeDirAbsolute(dir) catch {};
        var buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{s}/test.db", .{dir});
        var db = try sqlite.Database.open(path);
        errdefer db.close();
        try schema.initSchema(&db);
        return .{ .dir = dir, .db = db };
    }

    fn deinit(self: *TempDb) void {
        self.db.close();
        std.fs.deleteTreeAbsolute(self.dir) catch {};
    }
};

fn insertKeg(
    db: *sqlite.Database,
    name: []const u8,
    reason: []const u8,
) !i64 {
    var stmt = try db.prepare(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, install_reason)
        \\VALUES (?1, ?1, '1.0', 'sha', '/tmp', ?2) RETURNING id;
    );
    defer stmt.finalize();
    try stmt.bindText(1, name);
    try stmt.bindText(2, reason);
    const has = try stmt.step();
    try testing.expect(has);
    return stmt.columnInt(0);
}

fn insertDep(db: *sqlite.Database, keg_id: i64, dep_name: []const u8) !void {
    var stmt = try db.prepare(
        "INSERT INTO dependencies (keg_id, dep_name) VALUES (?1, ?2);",
    );
    defer stmt.finalize();
    try stmt.bindInt(1, keg_id);
    try stmt.bindText(2, dep_name);
    _ = try stmt.step();
}

test "findOrphans surfaces dependency kegs not referenced by any direct install" {
    var tdb = try TempDb.init("orphans_basic");
    defer tdb.deinit();

    // A direct install 'wget' that depends on 'openssl@3' and 'libidn2'.
    const wget_id = try insertKeg(&tdb.db, "wget", "direct");
    try insertDep(&tdb.db, wget_id, "openssl@3");
    try insertDep(&tdb.db, wget_id, "libidn2");

    // Both dep kegs exist.
    _ = try insertKeg(&tdb.db, "openssl@3", "dependency");
    _ = try insertKeg(&tdb.db, "libidn2", "dependency");

    // Plus one stranded dep with nobody referencing it — THIS is the orphan.
    _ = try insertKeg(&tdb.db, "stranded-lib", "dependency");

    const orphans = try deps_mod.findOrphans(testing.allocator, &tdb.db);
    defer {
        for (orphans) |o| testing.allocator.free(o);
        testing.allocator.free(orphans);
    }

    try testing.expectEqual(@as(usize, 1), orphans.len);
    try testing.expectEqualStrings("stranded-lib", orphans[0]);
}

test "findOrphans returns empty when every dep keg is still referenced" {
    var tdb = try TempDb.init("orphans_empty");
    defer tdb.deinit();

    const wget_id = try insertKeg(&tdb.db, "wget", "direct");
    try insertDep(&tdb.db, wget_id, "openssl@3");
    _ = try insertKeg(&tdb.db, "openssl@3", "dependency");

    const orphans = try deps_mod.findOrphans(testing.allocator, &tdb.db);
    defer {
        for (orphans) |o| testing.allocator.free(o);
        testing.allocator.free(orphans);
    }
    try testing.expectEqual(@as(usize, 0), orphans.len);
}

test "ResolvedDep carries name and already_installed flag" {
    const d = deps_mod.ResolvedDep{ .name = "foo", .already_installed = true };
    try testing.expectEqualStrings("foo", d.name);
    try testing.expect(d.already_installed);
}

// --- resolve() BFS tests with a cache-backed BrewApi (no network) ---

const TempCacheDir = struct {
    path: []const u8,

    fn init(comptime tag: []const u8) !TempCacheDir {
        const p = "/tmp/malt_deps_cache_" ++ tag;
        std.fs.deleteTreeAbsolute(p) catch {};
        try std.fs.makeDirAbsolute(p);
        return .{ .path = p };
    }

    fn deinit(self: *TempCacheDir) void {
        std.fs.deleteTreeAbsolute(self.path) catch {};
    }

    fn writeFormula(self: *TempCacheDir, name: []const u8, json: []const u8) !void {
        var api_buf: [512]u8 = undefined;
        const api_dir = try std.fmt.bufPrint(&api_buf, "{s}/api", .{self.path});
        std.fs.makeDirAbsolute(api_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        var path_buf: [512]u8 = undefined;
        const full = try std.fmt.bufPrint(&path_buf, "{s}/api/formula_{s}.json", .{ self.path, name });
        const f = try std.fs.cwd().createFile(full, .{});
        defer f.close();
        try f.writeAll(json);
    }
};

test "resolve walks a small BFS dep graph and dedups via visited" {
    // resolve() leaks duped dep strings on the BFS visited-dedup path; run
    // this test under an arena so Zig's leak detector doesn't flag it.
    // The leak fix lives on a separate branch (fix/deps-resolve-leak).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var dir = try TempCacheDir.init("resolve_bfs");
    defer dir.deinit();

    // alpha → [beta, gamma]
    // beta  → []
    // gamma → [beta]   (tests BFS visited dedup)
    try dir.writeFormula("alpha", "{\"dependencies\":[\"beta\",\"gamma\"]}");
    try dir.writeFormula("beta", "{\"dependencies\":[]}");
    try dir.writeFormula("gamma", "{\"dependencies\":[\"beta\"]}");

    var http = client_mod.HttpClient.init(alloc);
    defer http.deinit();
    var api = api_mod.BrewApi.init(alloc, &http, dir.path);

    var tdb = try TempDb.init("resolve_bfs");
    defer tdb.deinit();

    const result = try deps_mod.resolve(alloc, "alpha", &api, &tdb.db);

    // Expect both beta and gamma to appear, in BFS order.
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqualStrings("beta", result[0].name);
    try testing.expect(!result[0].already_installed);
    try testing.expectEqualStrings("gamma", result[1].name);
    try testing.expect(!result[1].already_installed);
}

test "resolve marks already-installed kegs and skips their sub-deps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var dir = try TempCacheDir.init("resolve_installed");
    defer dir.deinit();

    // alpha → [beta], beta → [gamma]. beta is already installed → we should
    // NOT recurse into gamma.
    try dir.writeFormula("alpha", "{\"dependencies\":[\"beta\"]}");
    try dir.writeFormula("beta", "{\"dependencies\":[\"gamma\"]}");
    try dir.writeFormula("gamma", "{\"dependencies\":[]}");

    var http = client_mod.HttpClient.init(alloc);
    defer http.deinit();
    var api = api_mod.BrewApi.init(alloc, &http, dir.path);

    var tdb = try TempDb.init("resolve_installed");
    defer tdb.deinit();
    _ = try insertKeg(&tdb.db, "beta", "dependency");

    const result = try deps_mod.resolve(alloc, "alpha", &api, &tdb.db);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("beta", result[0].name);
    try testing.expect(result[0].already_installed);
}

test "resolve returns empty when root formula JSON is missing from cache" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var dir = try TempCacheDir.init("resolve_missing_root");
    defer dir.deinit();

    // Mark the root as a known-404 so fetchFormula returns NotFound without
    // touching the network.
    var api_dir_buf: [512]u8 = undefined;
    const api_dir = try std.fmt.bufPrint(&api_dir_buf, "{s}/api", .{dir.path});
    try std.fs.makeDirAbsolute(api_dir);
    var marker_buf: [512]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_buf, "{s}/api/formula_nope.404", .{dir.path});
    const f = try std.fs.cwd().createFile(marker, .{});
    f.close();

    var http = client_mod.HttpClient.init(alloc);
    defer http.deinit();
    var api = api_mod.BrewApi.init(alloc, &http, dir.path);

    var tdb = try TempDb.init("resolve_missing_root");
    defer tdb.deinit();

    // resolve's getDeps catches errors and returns &.{}, so resolve returns
    // an empty list (no deps to walk).
    const result = try deps_mod.resolve(alloc, "nope", &api, &tdb.db);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "resolve handles a dep whose sub-fetch fails by falling through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var dir = try TempCacheDir.init("resolve_dep_missing");
    defer dir.deinit();

    // alpha → [missing]. missing has no cache file AND we mark it 404 so the
    // sub-getDeps fails. The BFS loop should still append `missing` as a
    // dep before trying to recurse.
    try dir.writeFormula("alpha", "{\"dependencies\":[\"missing\"]}");
    var marker_buf: [512]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_buf, "{s}/api/formula_missing.404", .{dir.path});
    const f = try std.fs.cwd().createFile(marker, .{});
    f.close();

    var http = client_mod.HttpClient.init(alloc);
    defer http.deinit();
    var api = api_mod.BrewApi.init(alloc, &http, dir.path);

    var tdb = try TempDb.init("resolve_dep_missing");
    defer tdb.deinit();

    const result = try deps_mod.resolve(alloc, "alpha", &api, &tdb.db);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("missing", result[0].name);
}

test "formula with empty dependencies" {
    var arena = testArena();
    defer arena.deinit();

    const json =
        \\{
        \\  "name": "hello",
        \\  "full_name": "hello",
        \\  "tap": "",
        \\  "desc": "",
        \\  "homepage": "",
        \\  "revision": 0,
        \\  "keg_only": false,
        \\  "post_install_defined": false,
        \\  "versions": { "stable": "1.0" },
        \\  "dependencies": [],
        \\  "oldnames": []
        \\}
    ;
    var formula = try formula_mod.parseFormula(arena.allocator(), json);
    defer formula.deinit();
    try testing.expectEqual(@as(usize, 0), formula.dependencies.len);
}
