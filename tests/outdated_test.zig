//! malt — outdated parallelisation tests
//!
//! Cache-seeded integration tests for `collectOutdatedFormulas` /
//! `collectOutdatedCasks`. Pure helper assertions live next to their
//! definitions in `src/cli/outdated.zig` as inline `test` blocks.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const outdated_mod = malt.cli_outdated;
const update_mod = malt.cli_update;
const api_mod = malt.api;
const client_mod = malt.client;
const sqlite = malt.sqlite;
const schema = malt.schema;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

// --- Integration: collectOutdatedFormulas / collectOutdatedCasks ---

const TempCacheDir = struct {
    path: []const u8,

    fn init(comptime tag: []const u8) !TempCacheDir {
        const p = "/tmp/malt_outdated_test_" ++ tag;
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

fn freeEntries(allocator: std.mem.Allocator, entries: []outdated_mod.OutdatedEntry) void {
    for (entries) |e| {
        allocator.free(e.name);
        allocator.free(e.installed);
        allocator.free(e.latest);
    }
    allocator.free(entries);
}

fn seedFormula(dir: *TempCacheDir, name: []const u8, latest: []const u8) !void {
    var key_buf: [128]u8 = undefined;
    const file = try std.fmt.bufPrint(&key_buf, "formula_{s}.json", .{name});
    var body_buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "{{\"name\":\"{s}\",\"versions\":{{\"stable\":\"{s}\"}}}}", .{ name, latest });
    try dir.writeCacheFile(file, body);
}

fn seedCask(dir: *TempCacheDir, token: []const u8, latest: []const u8) !void {
    var key_buf: [128]u8 = undefined;
    const file = try std.fmt.bufPrint(&key_buf, "cask_{s}.json", .{token});
    var body_buf: [512]u8 = undefined;
    // parseCask needs `url` too — minimal shape so it returns ok.
    const body = try std.fmt.bufPrint(
        &body_buf,
        "{{\"token\":\"{s}\",\"name\":[\"{s}\"],\"version\":\"{s}\",\"url\":\"https://example.invalid/{s}.dmg\"}}",
        .{ token, token, latest, token },
    );
    try dir.writeCacheFile(file, body);
}

test "collectOutdatedFormulas (small-N, single-client path) returns sorted outdated rows only" {
    var http = client_mod.HttpClient.init(testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("formulas_small");
    defer dir.deinit();

    try seedFormula(&dir, "alpha", "2.0");
    try seedFormula(&dir, "bravo", "1.0");
    try seedFormula(&dir, "charlie", "3.5");

    var api = api_mod.BrewApi.init(testing.allocator, &http, dir.path);

    const kegs = [_]outdated_mod.KegRow{
        .{ .name = "alpha", .version = "1.0" }, // outdated
        .{ .name = "bravo", .version = "1.0" }, // up-to-date
        .{ .name = "charlie", .version = "3.0" }, // outdated
    };

    const out = try outdated_mod.collectOutdatedFormulas(testing.allocator, &api, dir.path, &kegs, null);
    defer freeEntries(testing.allocator, out);

    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("alpha", out[0].name);
    try testing.expectEqualStrings("1.0", out[0].installed);
    try testing.expectEqualStrings("2.0", out[0].latest);
    try testing.expectEqualStrings("charlie", out[1].name);
    try testing.expectEqualStrings("3.0", out[1].installed);
    try testing.expectEqualStrings("3.5", out[1].latest);
}

test "collectOutdatedFormulas (large-N, pool path) preserves sorted order" {
    var http = client_mod.HttpClient.init(testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("formulas_large");
    defer dir.deinit();

    // 10 fake formulas, all outdated (installed=1.0, latest=2.0).
    // 10 > OUTDATED_DEFAULT_WORKERS so the pool path runs.
    const names = [_][]const u8{
        "f00", "f01", "f02", "f03", "f04",
        "f05", "f06", "f07", "f08", "f09",
    };
    for (names) |n| try seedFormula(&dir, n, "2.0");

    var rows_buf: [names.len]outdated_mod.KegRow = undefined;
    for (names, 0..) |n, i| rows_buf[i] = .{ .name = n, .version = "1.0" };

    var api = api_mod.BrewApi.init(testing.allocator, &http, dir.path);
    const out = try outdated_mod.collectOutdatedFormulas(testing.allocator, &api, dir.path, &rows_buf, null);
    defer freeEntries(testing.allocator, out);

    try testing.expectEqual(@as(usize, names.len), out.len);
    for (out, 0..) |entry, i| {
        try testing.expectEqualStrings(names[i], entry.name);
        try testing.expectEqualStrings("1.0", entry.installed);
        try testing.expectEqualStrings("2.0", entry.latest);
    }
}

test "collectOutdatedFormulas tolerates a missing/404 entry without aborting" {
    // One name has no cache entry — the worker treats it as "no remote
    // info" and the row drops out of the result rather than failing the
    // whole command.
    var http = client_mod.HttpClient.init(testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("formulas_partial");
    defer dir.deinit();

    try seedFormula(&dir, "alpha", "2.0");
    // 'ghost' is intentionally not seeded; with no network it yields null.
    try seedFormula(&dir, "zulu", "9.9");

    var api = api_mod.BrewApi.init(testing.allocator, &http, dir.path);

    const kegs = [_]outdated_mod.KegRow{
        .{ .name = "alpha", .version = "1.0" },
        .{ .name = "ghost", .version = "0.1" },
        .{ .name = "zulu", .version = "1.0" },
    };

    const out = try outdated_mod.collectOutdatedFormulas(testing.allocator, &api, dir.path, &kegs, null);
    defer freeEntries(testing.allocator, out);

    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("alpha", out[0].name);
    try testing.expectEqualStrings("zulu", out[1].name);
}

test "collectOutdatedCasks (small-N) returns sorted outdated rows only" {
    var http = client_mod.HttpClient.init(testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("casks_small");
    defer dir.deinit();

    try seedCask(&dir, "appone", "5.0");
    try seedCask(&dir, "appthree", "1.1");
    try seedCask(&dir, "apptwo", "2.0");

    var api = api_mod.BrewApi.init(testing.allocator, &http, dir.path);

    const kegs = [_]outdated_mod.KegRow{
        .{ .name = "appone", .version = "5.0" }, // up-to-date
        .{ .name = "appthree", .version = "1.0" }, // outdated
        .{ .name = "apptwo", .version = "1.0" }, // outdated
    };

    const out = try outdated_mod.collectOutdatedCasks(testing.allocator, &api, dir.path, &kegs, null);
    defer freeEntries(testing.allocator, out);

    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("appthree", out[0].name);
    try testing.expectEqualStrings("apptwo", out[1].name);
}

test "collectOutdatedCasks (large-N, pool path) preserves sorted order" {
    var http = client_mod.HttpClient.init(testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("casks_large");
    defer dir.deinit();

    const tokens = [_][]const u8{
        "c00", "c01", "c02", "c03", "c04",
        "c05", "c06", "c07", "c08", "c09",
    };
    for (tokens) |t| try seedCask(&dir, t, "2.0");

    var rows_buf: [tokens.len]outdated_mod.KegRow = undefined;
    for (tokens, 0..) |t, i| rows_buf[i] = .{ .name = t, .version = "1.0" };

    var api = api_mod.BrewApi.init(testing.allocator, &http, dir.path);
    const out = try outdated_mod.collectOutdatedCasks(testing.allocator, &api, dir.path, &rows_buf, null);
    defer freeEntries(testing.allocator, out);

    try testing.expectEqual(@as(usize, tokens.len), out.len);
    for (out, 0..) |entry, i| {
        try testing.expectEqualStrings(tokens[i], entry.name);
        try testing.expectEqualStrings("1.0", entry.installed);
        try testing.expectEqualStrings("2.0", entry.latest);
    }
}

// --- --pinned-only filter ---

fn setupPinnedPrefix(suffix: []const u8) ![:0]u8 {
    const path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "/tmp/malt_outdated_pinned_{d}_{s}",
        .{ malt.fs_compat.nanoTimestamp(), suffix },
        0,
    );
    malt.fs_compat.deleteTreeAbsolute(path) catch {};
    try malt.fs_compat.cwd().makePath(path);
    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{path});
    defer testing.allocator.free(db_dir);
    try malt.fs_compat.cwd().makePath(db_dir);
    _ = c.setenv("MALT_PREFIX", path.ptr, 1);
    return path;
}

fn openSeededDb(prefix: [:0]const u8) !sqlite.Database {
    var buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    errdefer db.close();
    try schema.initSchema(&db);
    return db;
}

fn insertKeg(db: *sqlite.Database, name: []const u8, pinned: bool) !void {
    var buf: [512]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(
        &buf,
        "INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, pinned) VALUES ('{s}', '{s}', '1.0', 'deadbeef', '/cellar/{s}/1.0', {d});",
        .{ name, name, name, @intFromBool(pinned) },
    );
    try db.exec(sql);
}

fn insertCask(db: *sqlite.Database, token: []const u8, pinned: bool) !void {
    var buf: [512]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(
        &buf,
        "INSERT INTO casks (token, name, version, url, pinned) VALUES ('{s}', '{s}', '120.0', 'https://example.invalid', {d});",
        .{ token, token, @intFromBool(pinned) },
    );
    try db.exec(sql);
}

test "loadCaskRows .pinned_only returns only pinned casks" {
    const path = try setupPinnedPrefix("filter_pinned_casks");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try insertCask(&db, "loose-cask", false);
    try insertCask(&db, "held-one", true);
    try insertCask(&db, "held-two", true);

    const rows = try outdated_mod.loadCaskRows(testing.allocator, &db, .pinned_only);
    defer outdated_mod.freeKegRows(testing.allocator, rows);

    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("held-one", rows[0].name);
    try testing.expectEqualStrings("held-two", rows[1].name);
}

test "loadCaskRows .all returns every installed cask" {
    const path = try setupPinnedPrefix("filter_all_casks");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try insertCask(&db, "loose-cask", false);
    try insertCask(&db, "held-cask", true);

    const rows = try outdated_mod.loadCaskRows(testing.allocator, &db, .all);
    defer outdated_mod.freeKegRows(testing.allocator, rows);

    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("held-cask", rows[0].name);
    try testing.expectEqualStrings("loose-cask", rows[1].name);
}

test "outdated execute --pinned-only walks pinned casks alongside formulas" {
    const path = try setupPinnedPrefix("exec_pinned_mixed");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openSeededDb(path);
        defer db.close();
        try insertKeg(&db, "loose", false);
        try insertCask(&db, "free-cask", false);
        try insertCask(&db, "held-cask", true);
    }

    // Cask-side row exists and is pinned: the audit must visit it instead of
    // short-circuiting to formula-only scope. With no API cache the row drops
    // out of the result silently — the success contract is "no error, no
    // formula-only override".
    try outdated_mod.execute(testing.allocator, &.{"--pinned-only"});
}

test "loadFormulaRows .pinned_only returns only pinned rows" {
    const path = try setupPinnedPrefix("filter_pinned");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try insertKeg(&db, "alpha", false);
    try insertKeg(&db, "bravo", true);
    try insertKeg(&db, "charlie", true);

    const rows = try outdated_mod.loadFormulaRows(testing.allocator, &db, .pinned_only);
    defer outdated_mod.freeKegRows(testing.allocator, rows);

    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("bravo", rows[0].name);
    try testing.expectEqualStrings("charlie", rows[1].name);
}

test "loadFormulaRows .all returns every installed row" {
    const path = try setupPinnedPrefix("filter_all");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try insertKeg(&db, "alpha", false);
    try insertKeg(&db, "bravo", true);

    const rows = try outdated_mod.loadFormulaRows(testing.allocator, &db, .all);
    defer outdated_mod.freeKegRows(testing.allocator, rows);

    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("alpha", rows[0].name);
    try testing.expectEqualStrings("bravo", rows[1].name);
}

test "loadFormulaRows .pinned_only on an empty DB is a no-op" {
    const path = try setupPinnedPrefix("filter_empty");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try insertKeg(&db, "alpha", false);
    try insertKeg(&db, "bravo", false);

    const rows = try outdated_mod.loadFormulaRows(testing.allocator, &db, .pinned_only);
    defer outdated_mod.freeKegRows(testing.allocator, rows);

    try testing.expectEqual(@as(usize, 0), rows.len);
}

// --- Cached snapshot (write/read round-trip) ---

// --- update + --check integration ---

const UpdateEnv = struct {
    prefix_path: [:0]u8,
    cache_path: [:0]u8,

    fn init(suffix: []const u8) !UpdateEnv {
        const prefix = try std.fmt.allocPrintSentinel(
            testing.allocator,
            "/tmp/malt_update_test_{d}_{s}",
            .{ malt.fs_compat.nanoTimestamp(), suffix },
            0,
        );
        const cache = try std.fmt.allocPrintSentinel(
            testing.allocator,
            "{s}/cache",
            .{prefix},
            0,
        );
        malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
        try malt.fs_compat.cwd().makePath(prefix);
        try malt.fs_compat.cwd().makePath(cache);
        const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{prefix});
        defer testing.allocator.free(db_dir);
        try malt.fs_compat.cwd().makePath(db_dir);

        _ = c.setenv("MALT_PREFIX", prefix.ptr, 1);
        _ = c.setenv("MALT_CACHE", cache.ptr, 1);
        return .{ .prefix_path = prefix, .cache_path = cache };
    }

    fn deinit(self: *UpdateEnv) void {
        _ = c.unsetenv("MALT_PREFIX");
        _ = c.unsetenv("MALT_CACHE");
        malt.fs_compat.deleteTreeAbsolute(self.prefix_path) catch {};
        testing.allocator.free(self.prefix_path);
        testing.allocator.free(self.cache_path);
    }

    fn writeApiFile(self: UpdateEnv, rel: []const u8, body: []const u8) !void {
        var dir_buf: [512]u8 = undefined;
        const api_dir = try std.fmt.bufPrint(&dir_buf, "{s}/api", .{self.cache_path});
        try malt.fs_compat.cwd().makePath(api_dir);
        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ api_dir, rel });
        const f = try malt.fs_compat.cwd().createFile(path, .{});
        defer f.close();
        try f.writeAll(body);
    }

    fn apiFileExists(self: UpdateEnv, rel: []const u8) bool {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/api/{s}", .{ self.cache_path, rel }) catch return false;
        malt.fs_compat.accessAbsolute(path, .{}) catch return false;
        return true;
    }
};

fn openUpdateDb(prefix: [:0]const u8) !sqlite.Database {
    var buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    errdefer db.close();
    try schema.initSchema(&db);
    return db;
}

fn insertKegV1(db: *sqlite.Database, name: []const u8) !void {
    var buf: [512]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(
        &buf,
        "INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, pinned) VALUES ('{s}', '{s}', '1.0', 'deadbeef', '/cellar/{s}/1.0', 0);",
        .{ name, name, name },
    );
    try db.exec(sql);
}

test "update --check writes the snapshot and leaves the API cache intact" {
    var env = try UpdateEnv.init("check_keeps_cache");
    defer env.deinit();

    try env.writeApiFile(
        "formula_alpha.json",
        "{\"name\":\"alpha\",\"versions\":{\"stable\":\"2.0\"}}",
    );
    {
        var db = try openUpdateDb(env.prefix_path);
        defer db.close();
        try insertKegV1(&db, "alpha");
    }

    try update_mod.execute(testing.allocator, &.{"--check"});

    // Snapshot was written.
    const snap_opt = outdated_mod.readSnapshot(testing.allocator, env.cache_path);
    try testing.expect(snap_opt != null);
    const snap = snap_opt.?;
    defer outdated_mod.freeSnapshot(testing.allocator, snap);
    try testing.expectEqual(@as(usize, 1), snap.formulas.len);
    try testing.expectEqualStrings("alpha", snap.formulas[0].name);
    try testing.expectEqualStrings("1.0", snap.formulas[0].installed);
    try testing.expectEqualStrings("2.0", snap.formulas[0].latest);

    // API cache survives.
    try testing.expect(env.apiFileExists("formula_alpha.json"));
}

test "update without --check wipes the API cache and skips the slow snapshot write" {
    var env = try UpdateEnv.init("default_wipes_cache");
    defer env.deinit();

    try env.writeApiFile("formula_alpha.json", "{\"name\":\"alpha\"}");

    try update_mod.execute(testing.allocator, &.{});

    // Cache wipe still happens.
    try testing.expect(!env.apiFileExists("formula_alpha.json"));
    // No snapshot is written: keeping `mt update` cheap is the contract.
    try testing.expectEqual(
        @as(?outdated_mod.OwnedSnapshot, null),
        outdated_mod.readSnapshot(testing.allocator, env.cache_path),
    );
}

test "update without --check deletes a stale snapshot to force fresh recompute next run" {
    var env = try UpdateEnv.init("default_deletes_snapshot");
    defer env.deinit();

    // Pre-existing snapshot from a prior run: the cache wipe just
    // dropped its data source, so the snapshot has no business surviving.
    try outdated_mod.writeSnapshot(testing.allocator, env.cache_path, .{
        .generated_at_ms = malt.fs_compat.milliTimestamp(),
        .formulas = &[_]outdated_mod.OutdatedEntry{},
        .casks = &[_]outdated_mod.OutdatedEntry{},
    });
    try testing.expect(outdated_mod.readSnapshot(testing.allocator, env.cache_path) != null);

    try update_mod.execute(testing.allocator, &.{});

    try testing.expectEqual(
        @as(?outdated_mod.OwnedSnapshot, null),
        outdated_mod.readSnapshot(testing.allocator, env.cache_path),
    );
}

test "outdated execute reads a fresh snapshot and never overwrites it" {
    var env = try UpdateEnv.init("outdated_uses_snapshot");
    defer env.deinit();

    {
        var db = try openUpdateDb(env.prefix_path);
        defer db.close();
        try insertKegV1(&db, "alpha");
    }

    // Use a fixed marker timestamp on a fresh snapshot. The snapshot
    // path must NOT rewrite the file (recompute would update the
    // timestamp), so the marker survives across execute().
    const marker_ts: i64 = malt.fs_compat.milliTimestamp() - 1000;
    const formulas = [_]outdated_mod.OutdatedEntry{
        .{ .name = @constCast("alpha"), .installed = @constCast("1.0"), .latest = @constCast("9.9") },
    };
    try outdated_mod.writeSnapshot(testing.allocator, env.cache_path, .{
        .generated_at_ms = marker_ts,
        .formulas = &formulas,
        .casks = &[_]outdated_mod.OutdatedEntry{},
    });

    try outdated_mod.execute(testing.allocator, &.{});

    // The marker timestamp survives — proof the snapshot was read and
    // not regenerated by the recompute path.
    const after_opt = outdated_mod.readSnapshot(testing.allocator, env.cache_path);
    try testing.expect(after_opt != null);
    const after = after_opt.?;
    defer outdated_mod.freeSnapshot(testing.allocator, after);
    try testing.expectEqual(marker_ts, after.generated_at_ms);
    try testing.expectEqual(@as(usize, 1), after.formulas.len);
    try testing.expectEqualStrings("alpha", after.formulas[0].name);
    try testing.expectEqualStrings("9.9", after.formulas[0].latest);
}

test "outdated execute drops snapshot entries whose keg was uninstalled" {
    var env = try UpdateEnv.init("outdated_filters_uninstalled");
    defer env.deinit();

    {
        var db = try openUpdateDb(env.prefix_path);
        defer db.close();
        // alpha is installed; ghost was uninstalled since the snapshot.
        try insertKegV1(&db, "alpha");
    }

    const marker_ts: i64 = malt.fs_compat.milliTimestamp() - 1000;
    const formulas = [_]outdated_mod.OutdatedEntry{
        .{ .name = @constCast("alpha"), .installed = @constCast("1.0"), .latest = @constCast("2.0") },
        .{ .name = @constCast("ghost"), .installed = @constCast("0.5"), .latest = @constCast("1.0") },
    };
    try outdated_mod.writeSnapshot(testing.allocator, env.cache_path, .{
        .generated_at_ms = marker_ts,
        .formulas = &formulas,
        .casks = &[_]outdated_mod.OutdatedEntry{},
    });

    try outdated_mod.execute(testing.allocator, &.{});

    // Marker timestamp survives -> execute() took the snapshot path
    // (recompute would have rewritten it with a fresh timestamp).
    const after_opt = outdated_mod.readSnapshot(testing.allocator, env.cache_path);
    try testing.expect(after_opt != null);
    const after = after_opt.?;
    defer outdated_mod.freeSnapshot(testing.allocator, after);
    try testing.expectEqual(marker_ts, after.generated_at_ms);

    // Filter correctness: same DB + snapshot inputs that execute() saw,
    // run through the same helper, must yield only `alpha`.
    var db = try openUpdateDb(env.prefix_path);
    defer db.close();
    const rows = try outdated_mod.loadFormulaRows(testing.allocator, &db, .all);
    defer outdated_mod.freeKegRows(testing.allocator, rows);
    const filtered = try outdated_mod.intersectWithDb(testing.allocator, rows, &formulas);
    defer {
        for (filtered) |e| {
            testing.allocator.free(e.name);
            testing.allocator.free(e.installed);
            testing.allocator.free(e.latest);
        }
        testing.allocator.free(filtered);
    }
    try testing.expectEqual(@as(usize, 1), filtered.len);
    try testing.expectEqualStrings("alpha", filtered[0].name);
}

test "outdated execute on a stale snapshot emits the cached entries (used as proof of read)" {
    var env = try UpdateEnv.init("outdated_stale_uses_cache");
    defer env.deinit();

    {
        var db = try openUpdateDb(env.prefix_path);
        defer db.close();
        try insertKegV1(&db, "alpha");
    }

    // 30-day-old snapshot — well past the 24h default threshold.
    const month_ms: i64 = 30 * 24 * 60 * 60 * 1000;
    const formulas = [_]outdated_mod.OutdatedEntry{
        .{ .name = @constCast("alpha"), .installed = @constCast("1.0"), .latest = @constCast("3.0") },
    };
    try outdated_mod.writeSnapshot(testing.allocator, env.cache_path, .{
        .generated_at_ms = malt.fs_compat.milliTimestamp() - month_ms,
        .formulas = &formulas,
        .casks = &[_]outdated_mod.OutdatedEntry{},
    });

    // Stale snapshot: emits entries (so shell prompts stay instant), warning
    // on stderr — but should NOT overwrite the snapshot. We verify the
    // post-execute snapshot still contains "alpha->3.0" rather than a fresh
    // empty recompute.
    try outdated_mod.execute(testing.allocator, &.{});

    const after_opt = outdated_mod.readSnapshot(testing.allocator, env.cache_path);
    try testing.expect(after_opt != null);
    const after = after_opt.?;
    defer outdated_mod.freeSnapshot(testing.allocator, after);
    try testing.expectEqual(@as(usize, 1), after.formulas.len);
    try testing.expectEqualStrings("alpha", after.formulas[0].name);
    try testing.expectEqualStrings("3.0", after.formulas[0].latest);
}

test "outdated execute --refresh skips the snapshot and recomputes" {
    var env = try UpdateEnv.init("outdated_refresh_recomputes");
    defer env.deinit();

    {
        var db = try openUpdateDb(env.prefix_path);
        defer db.close();
        // No kegs => no API calls => --refresh path stays offline.
    }

    // Stamp a snapshot with a bogus latest; --refresh must not surface it.
    const formulas = [_]outdated_mod.OutdatedEntry{
        .{ .name = @constCast("alpha"), .installed = @constCast("1.0"), .latest = @constCast("bogus") },
    };
    try outdated_mod.writeSnapshot(testing.allocator, env.cache_path, .{
        .generated_at_ms = malt.fs_compat.milliTimestamp(),
        .formulas = &formulas,
        .casks = &[_]outdated_mod.OutdatedEntry{},
    });

    try outdated_mod.execute(testing.allocator, &.{"--refresh"});

    // After --refresh, the snapshot is regenerated to reflect actual state.
    const fresh_opt = outdated_mod.readSnapshot(testing.allocator, env.cache_path);
    try testing.expect(fresh_opt != null);
    const fresh = fresh_opt.?;
    defer outdated_mod.freeSnapshot(testing.allocator, fresh);
    try testing.expectEqual(@as(usize, 0), fresh.formulas.len);
    try testing.expectEqual(@as(usize, 0), fresh.casks.len);
}

test "writeSnapshot then readSnapshot round-trips entries through the cache file" {
    var dir = try TempCacheDir.init("snapshot_round_trip");
    defer dir.deinit();

    const formulas = [_]outdated_mod.OutdatedEntry{
        .{ .name = @constCast("alpha"), .installed = @constCast("1.0"), .latest = @constCast("2.0") },
    };
    const casks = [_]outdated_mod.OutdatedEntry{
        .{ .name = @constCast("beta"), .installed = @constCast("3.0"), .latest = @constCast("3.5") },
    };
    const snap: outdated_mod.Snapshot = .{
        .generated_at_ms = 1_700_000_000_000,
        .formulas = &formulas,
        .casks = &casks,
    };
    try outdated_mod.writeSnapshot(testing.allocator, dir.path, snap);

    const read_opt = outdated_mod.readSnapshot(testing.allocator, dir.path);
    try testing.expect(read_opt != null);
    const read = read_opt.?;
    defer outdated_mod.freeSnapshot(testing.allocator, read);

    try testing.expectEqual(@as(i64, 1_700_000_000_000), read.generated_at_ms);
    try testing.expectEqual(@as(usize, 1), read.formulas.len);
    try testing.expectEqualStrings("alpha", read.formulas[0].name);
    try testing.expectEqualStrings("2.0", read.formulas[0].latest);
    try testing.expectEqual(@as(usize, 1), read.casks.len);
    try testing.expectEqualStrings("beta", read.casks[0].name);
}

test "readSnapshot returns null when the file is missing" {
    var dir = try TempCacheDir.init("snapshot_missing");
    defer dir.deinit();
    try testing.expectEqual(@as(?outdated_mod.OwnedSnapshot, null), outdated_mod.readSnapshot(testing.allocator, dir.path));
}

test "readSnapshot returns null on garbage contents" {
    var dir = try TempCacheDir.init("snapshot_garbage");
    defer dir.deinit();
    const path = try outdated_mod.snapshotPath(testing.allocator, dir.path);
    defer testing.allocator.free(path);
    const f = try malt.fs_compat.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll("not-json-at-all");
    try testing.expectEqual(@as(?outdated_mod.OwnedSnapshot, null), outdated_mod.readSnapshot(testing.allocator, dir.path));
}

test "writeSnapshot creates the cache directory if missing" {
    const tag = "snapshot_mkdir";
    const path = "/tmp/malt_outdated_test_" ++ tag;
    malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};

    const snap: outdated_mod.Snapshot = .{
        .generated_at_ms = 0,
        .formulas = &[_]outdated_mod.OutdatedEntry{},
        .casks = &[_]outdated_mod.OutdatedEntry{},
    };
    try outdated_mod.writeSnapshot(testing.allocator, path, snap);

    const read_opt = outdated_mod.readSnapshot(testing.allocator, path);
    try testing.expect(read_opt != null);
    const read = read_opt.?;
    defer outdated_mod.freeSnapshot(testing.allocator, read);
    try testing.expectEqual(@as(usize, 0), read.formulas.len);
    try testing.expectEqual(@as(usize, 0), read.casks.len);
}

test "outdated execute --pinned-only is a quiet no-op when no kegs are pinned" {
    const path = try setupPinnedPrefix("exec_no_pins");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openSeededDb(path);
        defer db.close();
        try insertKeg(&db, "alpha", false);
    }

    // No pinned kegs => no API calls => quiet success even with no cache.
    try outdated_mod.execute(testing.allocator, &.{"--pinned-only"});
}
