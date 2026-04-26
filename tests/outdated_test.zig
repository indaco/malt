//! malt — outdated parallelisation tests
//!
//! Cache-seeded integration tests for `collectOutdatedFormulas` /
//! `collectOutdatedCasks`. Pure helper assertions live next to their
//! definitions in `src/cli/outdated.zig` as inline `test` blocks.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const outdated_mod = malt.cli_outdated;
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
