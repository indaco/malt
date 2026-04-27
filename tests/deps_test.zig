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

fn insertKeg(
    db: *sqlite.Database,
    name: []const u8,
    reason: []const u8,
) !i64 {
    return insertKegWithCellar(db, name, reason, "/tmp");
}

fn insertKegWithCellar(
    db: *sqlite.Database,
    name: []const u8,
    reason: []const u8,
    cellar_path: []const u8,
) !i64 {
    var stmt = try db.prepare(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, install_reason)
        \\VALUES (?1, ?1, '1.0', 'sha', ?3, ?2) RETURNING id;
    );
    defer stmt.finalize();
    try stmt.bindText(1, name);
    try stmt.bindText(2, reason);
    try stmt.bindText(3, cellar_path);
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

test "findOrphans walks the transitive closure of direct kegs" {
    // Real-world shape: `node` (direct) → `openssl@3` → `ca-certificates`.
    // The dependencies table only carries direct edges, so a one-level
    // query would have classed `ca-certificates` as orphan even though
    // `openssl@3` (retained by node) still pulls it in. Plus a stranded
    // dep nobody references — the only thing that should actually purge.
    var tdb = try TempDb.init("orphans_transitive");
    defer tdb.deinit();

    const node_id = try insertKeg(&tdb.db, "node", "direct");
    try insertDep(&tdb.db, node_id, "openssl@3");

    const openssl_id = try insertKeg(&tdb.db, "openssl@3", "dependency");
    try insertDep(&tdb.db, openssl_id, "ca-certificates");

    _ = try insertKeg(&tdb.db, "ca-certificates", "dependency");
    _ = try insertKeg(&tdb.db, "stranded-lib", "dependency");

    const orphans = try deps_mod.findOrphans(testing.allocator, &tdb.db);
    defer {
        for (orphans) |o| testing.allocator.free(o);
        testing.allocator.free(orphans);
    }

    try testing.expectEqual(@as(usize, 1), orphans.len);
    try testing.expectEqualStrings("stranded-lib", orphans[0]);
}

test "findOrphans tolerates dependency cycles without looping forever" {
    // Defensive: a malformed graph where two dep kegs reference each
    // other (a → b, b → a) under no direct retainer should still
    // classify both as orphans. The recursive CTE's UNION (not UNION
    // ALL) collapses repeats so the walk terminates.
    var tdb = try TempDb.init("orphans_cycle");
    defer tdb.deinit();

    const a_id = try insertKeg(&tdb.db, "a-lib", "dependency");
    const b_id = try insertKeg(&tdb.db, "b-lib", "dependency");
    try insertDep(&tdb.db, a_id, "b-lib");
    try insertDep(&tdb.db, b_id, "a-lib");

    const orphans = try deps_mod.findOrphans(testing.allocator, &tdb.db);
    defer {
        for (orphans) |o| testing.allocator.free(o);
        testing.allocator.free(orphans);
    }
    try testing.expectEqual(@as(usize, 2), orphans.len);
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

/// Free the slice returned by `deps_mod.resolve()`. Each `ResolvedDep.name`
/// is heap-allocated by resolve(), and so is the outer slice.
fn freeResolved(alloc: std.mem.Allocator, r: []deps_mod.ResolvedDep) void {
    for (r) |d| alloc.free(d.name);
    alloc.free(r);
}

test "resolve walks a small BFS dep graph and dedups via visited" {
    const alloc = testing.allocator;

    var dir = try TempCacheDir.init("resolve_bfs");
    defer dir.deinit();

    // alpha → [beta, gamma]
    // beta  → []
    // gamma → [beta]   (tests BFS visited dedup)
    try dir.writeFormula("alpha", "{\"name\":\"alpha\",\"dependencies\":[\"beta\",\"gamma\"]}");
    try dir.writeFormula("beta", "{\"name\":\"beta\",\"dependencies\":[]}");
    try dir.writeFormula("gamma", "{\"name\":\"gamma\",\"dependencies\":[\"beta\"]}");

    var http = client_mod.HttpClient.init(alloc);
    defer http.deinit();
    var api = api_mod.BrewApi.init(alloc, &http, dir.path);

    var tdb = try TempDb.init("resolve_bfs");
    defer tdb.deinit();

    var cache = deps_mod.FormulaCache.init(alloc);
    defer cache.deinit();

    const result = try deps_mod.resolve(alloc, "alpha", &api, &tdb.db, &cache);
    defer freeResolved(alloc, result);

    // Expect both beta and gamma to appear, in BFS order.
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqualStrings("beta", result[0].name);
    try testing.expect(!result[0].already_installed);
    try testing.expectEqualStrings("gamma", result[1].name);
    try testing.expect(!result[1].already_installed);
}

test "resolve marks already-installed kegs and skips their sub-deps" {
    const alloc = testing.allocator;

    var dir = try TempCacheDir.init("resolve_installed");
    defer dir.deinit();

    // alpha → [beta], beta → [gamma]. beta is already installed → we should
    // NOT recurse into gamma.
    try dir.writeFormula("alpha", "{\"name\":\"alpha\",\"dependencies\":[\"beta\"]}");
    try dir.writeFormula("beta", "{\"name\":\"beta\",\"dependencies\":[\"gamma\"]}");
    try dir.writeFormula("gamma", "{\"name\":\"gamma\",\"dependencies\":[]}");

    var http = client_mod.HttpClient.init(alloc);
    defer http.deinit();
    var api = api_mod.BrewApi.init(alloc, &http, dir.path);

    var tdb = try TempDb.init("resolve_installed");
    defer tdb.deinit();
    _ = try insertKeg(&tdb.db, "beta", "dependency");

    var cache = deps_mod.FormulaCache.init(alloc);
    defer cache.deinit();

    const result = try deps_mod.resolve(alloc, "alpha", &api, &tdb.db, &cache);
    defer freeResolved(alloc, result);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("beta", result[0].name);
    try testing.expect(result[0].already_installed);
}

test "resolve returns empty when root formula JSON is missing from cache" {
    const alloc = testing.allocator;

    var dir = try TempCacheDir.init("resolve_missing_root");
    defer dir.deinit();

    // Mark the root as a known-404 so fetchFormula returns NotFound without
    // touching the network.
    var api_dir_buf: [512]u8 = undefined;
    const api_dir = try std.fmt.bufPrint(&api_dir_buf, "{s}/api", .{dir.path});
    try malt.fs_compat.makeDirAbsolute(api_dir);
    var marker_buf: [512]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_buf, "{s}/api/formula_nope.404", .{dir.path});
    const f = try malt.fs_compat.cwd().createFile(marker, .{});
    f.close();

    var http = client_mod.HttpClient.init(alloc);
    defer http.deinit();
    var api = api_mod.BrewApi.init(alloc, &http, dir.path);

    var tdb = try TempDb.init("resolve_missing_root");
    defer tdb.deinit();

    // resolve's getDeps catches errors and returns &.{}, so resolve returns
    // an empty list (no deps to walk).
    var cache = deps_mod.FormulaCache.init(alloc);
    defer cache.deinit();

    const result = try deps_mod.resolve(alloc, "nope", &api, &tdb.db, &cache);
    defer freeResolved(alloc, result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "resolve handles a dep whose sub-fetch fails by falling through" {
    const alloc = testing.allocator;

    var dir = try TempCacheDir.init("resolve_dep_missing");
    defer dir.deinit();

    // alpha → [missing]. missing has no cache file AND we mark it 404 so the
    // sub-getDeps fails. The BFS loop should still append `missing` as a
    // dep before trying to recurse.
    try dir.writeFormula("alpha", "{\"name\":\"alpha\",\"dependencies\":[\"missing\"]}");
    var marker_buf: [512]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_buf, "{s}/api/formula_missing.404", .{dir.path});
    const f = try malt.fs_compat.cwd().createFile(marker, .{});
    f.close();

    var http = client_mod.HttpClient.init(alloc);
    defer http.deinit();
    var api = api_mod.BrewApi.init(alloc, &http, dir.path);

    var tdb = try TempDb.init("resolve_dep_missing");
    defer tdb.deinit();

    var cache = deps_mod.FormulaCache.init(alloc);
    defer cache.deinit();

    const result = try deps_mod.resolve(alloc, "alpha", &api, &tdb.db, &cache);
    defer freeResolved(alloc, result);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("missing", result[0].name);
}

// --- ensureOptLink / stale-cellar heal coverage ---------------------------

test "resolve treats a DB keg with a vanished cellar_path as not-installed" {
    // Reproduces the zig→zstd bug: DB still holds the row after the Cellar
    // dir was removed (manual cleanup, interrupted uninstall, prefix move).
    // Without the fs check, BFS would skip the dep and the install would
    // succeed while leaving dylib consumers pointing at a dead symlink.
    const alloc = testing.allocator;

    var dir = try TempCacheDir.init("resolve_missing_cellar");
    defer dir.deinit();

    try dir.writeFormula("alpha", "{\"name\":\"alpha\",\"dependencies\":[\"beta\"]}");
    try dir.writeFormula("beta", "{\"name\":\"beta\",\"dependencies\":[]}");

    var http = client_mod.HttpClient.init(alloc);
    defer http.deinit();
    var api = api_mod.BrewApi.init(alloc, &http, dir.path);

    var tdb = try TempDb.init("resolve_missing_cellar");
    defer tdb.deinit();
    // Point beta's cellar_path at a directory that definitely doesn't exist.
    _ = try insertKegWithCellar(&tdb.db, "beta", "dependency", "/tmp/malt_missing_xyz_9273");

    var cache = deps_mod.FormulaCache.init(alloc);
    defer cache.deinit();

    const result = try deps_mod.resolve(alloc, "alpha", &api, &tdb.db, &cache);
    defer freeResolved(alloc, result);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("beta", result[0].name);
    // Filesystem says no — fall back to reinstall, never skip.
    try testing.expect(!result[0].already_installed);
}

const TempPrefix = struct {
    root: []const u8,
    db: sqlite.Database,

    fn init(comptime tag: []const u8) !TempPrefix {
        const root = "/tmp/malt_opt_link_" ++ tag;
        malt.fs_compat.deleteTreeAbsolute(root) catch {};
        try malt.fs_compat.makeDirAbsolute(root);
        errdefer malt.fs_compat.deleteTreeAbsolute(root) catch {};

        var db_buf: [256]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_buf, "{s}/malt.db", .{root}, 0);
        var db = try sqlite.Database.open(db_path);
        errdefer db.close();
        try schema.initSchema(&db);
        return .{ .root = root, .db = db };
    }

    fn deinit(self: *TempPrefix) void {
        self.db.close();
        malt.fs_compat.deleteTreeAbsolute(self.root) catch {};
    }

    fn cellarFor(self: *const TempPrefix, name: []const u8, version: []const u8) ![]const u8 {
        var cellar_root_buf: [512]u8 = undefined;
        const cellar_root = try std.fmt.bufPrint(&cellar_root_buf, "{s}/Cellar", .{self.root});
        malt.fs_compat.makeDirAbsolute(cellar_root) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        var name_buf: [512]u8 = undefined;
        const name_dir = try std.fmt.bufPrint(&name_buf, "{s}/{s}", .{ cellar_root, name });
        malt.fs_compat.makeDirAbsolute(name_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ name_dir, version });
        malt.fs_compat.makeDirAbsolute(path) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        return try testing.allocator.dupe(u8, path);
    }

    fn readOptLink(self: *const TempPrefix, name: []const u8, buf: []u8) ![]u8 {
        var path_buf: [512]u8 = undefined;
        const opt_path = try std.fmt.bufPrint(&path_buf, "{s}/opt/{s}", .{ self.root, name });
        return malt.fs_compat.readLinkAbsolute(opt_path, buf);
    }
};

test "ensureOptLink recreates a missing opt/<name> symlink" {
    var p = try TempPrefix.init("missing");
    defer p.deinit();

    const cellar = try p.cellarFor("zstd", "1.5.7");
    defer testing.allocator.free(cellar);
    _ = try insertKegWithCellar(&p.db, "zstd", "dependency", cellar);

    // Precondition: no opt/ symlink yet.
    var miss_buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectError(error.FileNotFound, p.readOptLink("zstd", &miss_buf));

    deps_mod.ensureOptLink(&p.db, p.root, "zstd");

    var got_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = try p.readOptLink("zstd", &got_buf);
    try testing.expectEqualStrings(cellar, target);
}

test "ensureOptLink is idempotent when the symlink is already correct" {
    var p = try TempPrefix.init("idempotent");
    defer p.deinit();

    const cellar = try p.cellarFor("zstd", "1.5.7");
    defer testing.allocator.free(cellar);
    _ = try insertKegWithCellar(&p.db, "zstd", "dependency", cellar);

    deps_mod.ensureOptLink(&p.db, p.root, "zstd"); // first call creates
    deps_mod.ensureOptLink(&p.db, p.root, "zstd"); // second call must be a no-op

    var got_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = try p.readOptLink("zstd", &got_buf);
    try testing.expectEqualStrings(cellar, target);
}

test "ensureOptLink replaces a stale symlink pointing at an old cellar" {
    var p = try TempPrefix.init("stale");
    defer p.deinit();

    // Pre-create a symlink to an OLD cellar path that the DB no longer knows.
    var opt_parent_buf: [512]u8 = undefined;
    const opt_parent = try std.fmt.bufPrint(&opt_parent_buf, "{s}/opt", .{p.root});
    try malt.fs_compat.makeDirAbsolute(opt_parent);
    var dir = try malt.fs_compat.openDirAbsolute(opt_parent, .{});
    defer dir.close();
    try dir.symLink("/tmp/malt_stale_old_zstd", "zstd", .{});

    // DB points at the CURRENT cellar path.
    const cellar = try p.cellarFor("zstd", "1.5.7");
    defer testing.allocator.free(cellar);
    _ = try insertKegWithCellar(&p.db, "zstd", "dependency", cellar);

    deps_mod.ensureOptLink(&p.db, p.root, "zstd");

    var got_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = try p.readOptLink("zstd", &got_buf);
    try testing.expectEqualStrings(cellar, target);
}

test "ensureOptLink silently skips names the DB does not know" {
    var p = try TempPrefix.init("unknown");
    defer p.deinit();

    // No DB row for 'ghost' → ensureOptLink must be a no-op, not panic.
    deps_mod.ensureOptLink(&p.db, p.root, "ghost");

    var miss_buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectError(error.FileNotFound, p.readOptLink("ghost", &miss_buf));
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
