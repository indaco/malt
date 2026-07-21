//! malt — outdated parallelisation tests
//!
//! Cache-seeded integration tests for `collectOutdatedFormulas` /
//! `collectOutdatedCasks`. Pure helper assertions live next to their
//! definitions in `src/cli/outdated.zig` as inline `test` blocks.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");
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
    allocator: std.mem.Allocator,
    path: []const u8,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !TempCacheDir {
        // A shared tree let one init's deleteTree wipe another's seeded cache.
        const p = try test_io.uniqueTempPath(allocator, "outdated_test", tag);
        errdefer allocator.free(p);
        test_io.deleteTreeAbsolute(std.Options.debug_io, p) catch {};
        try test_io.makeDirAbsolute(std.Options.debug_io, p);
        return .{ .allocator = allocator, .path = p };
    }

    fn deinit(self: *TempCacheDir) void {
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.path) catch {};
        self.allocator.free(self.path);
    }

    // Two instances sharing a tag model two concurrent test processes opening
    // their cache dir. The second's setup must not wipe the first's seeded
    // files — that clobber is what makes the suite flaky under overlapping runs.
    test "a second cache dir with the same tag does not clobber the first" {
        var a = try TempCacheDir.init(testing.allocator, "clobber_guard");
        defer a.deinit();
        try a.writeCacheFile("formula_x.json", "{}");

        var b = try TempCacheDir.init(testing.allocator, "clobber_guard");
        defer b.deinit();

        var buf: [512]u8 = undefined;
        const seeded = try std.fmt.bufPrint(&buf, "{s}/api/formula_x.json", .{a.path});
        try test_io.accessAbsolute(std.Options.debug_io, seeded, .{});
    }

    fn writeCacheFile(self: *TempCacheDir, rel: []const u8, content: []const u8) !void {
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

fn freeEntries(allocator: std.mem.Allocator, entries: []outdated_mod.OutdatedEntry) void {
    for (entries) |e| {
        allocator.free(e.name);
        allocator.free(e.installed);
        allocator.free(e.latest);
    }
    allocator.free(entries);
}

/// In-memory DB primed with the malt schema. Tests that don't exercise
/// the tap-cask branch still need a live DB pointer for the etag-cache
/// lookup that `tap_mod.getCommitSha` / `getHeadEtag` perform — they
/// no-op against an empty taps table and the rest of the test runs
/// untouched.
fn openTestDb() !sqlite.Database {
    var db = try sqlite.Database.open(":memory:");
    errdefer db.close();
    try schema.initSchema(&db);
    return db;
}

/// Append one `<name>\t<stable>\t0` record to a version side-car so the
/// map path resolves the row. Read-modify-write keeps it simple for tests.
fn appendVersionsLine(dir: *TempCacheDir, rel: []const u8, name: []const u8, stable: []const u8) !void {
    var path_buf: [512]u8 = undefined;
    const full = try std.fmt.bufPrint(&path_buf, "{s}/api/{s}", .{ dir.path, rel });
    const prev = test_io.readFileAbsoluteAlloc(std.Options.debug_io, dir.allocator, full, 1 << 20) catch
        try dir.allocator.dupe(u8, "");
    defer dir.allocator.free(prev);
    const combined = try std.fmt.allocPrint(dir.allocator, "{s}{s}\t{s}\t0\n", .{ prev, name, stable });
    defer dir.allocator.free(combined);
    try dir.writeCacheFile(rel, combined);
}

fn seedFormula(dir: *TempCacheDir, name: []const u8, latest: []const u8) !void {
    var key_buf: [128]u8 = undefined;
    const file = try std.fmt.bufPrint(&key_buf, "formula_{s}.json", .{name});
    var body_buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "{{\"name\":\"{s}\",\"versions\":{{\"stable\":\"{s}\"}}}}", .{ name, latest });
    try dir.writeCacheFile(file, body);
    // Version side-car drives the map path; the JSON above stays as the
    // per-keg fallback so both routes are exercised by the suite.
    try appendVersionsLine(dir, "versions_formula.txt", name, latest);
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
    try appendVersionsLine(dir, "versions_cask.txt", token, latest);
}

test "collectOutdatedFormulas (small-N, single-client path) returns sorted outdated rows only" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init(testing.allocator, "formulas_small");
    defer dir.deinit();

    try seedFormula(&dir, "alpha", "2.0");
    try seedFormula(&dir, "bravo", "1.0");
    try seedFormula(&dir, "charlie", "3.5");

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);

    const kegs = [_]outdated_mod.KegRow{
        .{ .name = "alpha", .version = "1.0" }, // outdated
        .{ .name = "bravo", .version = "1.0" }, // up-to-date
        .{ .name = "charlie", .version = "3.0" }, // outdated
    };

    var db = try openTestDb();
    defer db.close();
    const out = try outdated_mod.collectOutdatedFormulas(&malt.app_ctx.debug_ctx, testing.allocator, &db, &api, dir.path, &kegs, null);
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
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init(testing.allocator, "formulas_large");
    defer dir.deinit();

    // 10 fake formulas, all outdated (installed=1.0, latest=2.0).
    // 10 > outdated_default_workers so the pool path runs.
    const names = [_][]const u8{
        "f00", "f01", "f02", "f03", "f04",
        "f05", "f06", "f07", "f08", "f09",
    };
    for (names) |n| try seedFormula(&dir, n, "2.0");

    var rows_buf: [names.len]outdated_mod.KegRow = undefined;
    for (names, 0..) |n, i| rows_buf[i] = .{ .name = n, .version = "1.0" };

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    var db = try openTestDb();
    defer db.close();
    const out = try outdated_mod.collectOutdatedFormulas(&malt.app_ctx.debug_ctx, testing.allocator, &db, &api, dir.path, &rows_buf, null);
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
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init(testing.allocator, "formulas_partial");
    defer dir.deinit();

    try seedFormula(&dir, "alpha", "2.0");
    // 'ghost' is intentionally not seeded; with no network it yields null.
    try seedFormula(&dir, "zulu", "9.9");

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);

    const kegs = [_]outdated_mod.KegRow{
        .{ .name = "alpha", .version = "1.0" },
        .{ .name = "ghost", .version = "0.1" },
        .{ .name = "zulu", .version = "1.0" },
    };

    var db = try openTestDb();
    defer db.close();
    const out = try outdated_mod.collectOutdatedFormulas(&malt.app_ctx.debug_ctx, testing.allocator, &db, &api, dir.path, &kegs, null);
    defer freeEntries(testing.allocator, out);

    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("alpha", out[0].name);
    try testing.expectEqualStrings("zulu", out[1].name);
}

test "collectOutdatedCasks (small-N) returns sorted outdated rows only" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init(testing.allocator, "casks_small");
    defer dir.deinit();

    try seedCask(&dir, "appone", "5.0");
    try seedCask(&dir, "appthree", "1.1");
    try seedCask(&dir, "apptwo", "2.0");

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);

    const kegs = [_]outdated_mod.KegRow{
        .{ .name = "appone", .version = "5.0" }, // up-to-date
        .{ .name = "appthree", .version = "1.0" }, // outdated
        .{ .name = "apptwo", .version = "1.0" }, // outdated
    };

    var db = try openTestDb();
    defer db.close();
    const out = try outdated_mod.collectOutdatedCasks(&malt.app_ctx.debug_ctx, testing.allocator, &db, &api, dir.path, &kegs, null);
    defer freeEntries(testing.allocator, out);

    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("appthree", out[0].name);
    try testing.expectEqualStrings("apptwo", out[1].name);
}

test "collectOutdatedCasks (large-N, pool path) preserves sorted order" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init(testing.allocator, "casks_large");
    defer dir.deinit();

    const tokens = [_][]const u8{
        "c00", "c01", "c02", "c03", "c04",
        "c05", "c06", "c07", "c08", "c09",
    };
    for (tokens) |t| try seedCask(&dir, t, "2.0");

    var rows_buf: [tokens.len]outdated_mod.KegRow = undefined;
    for (tokens, 0..) |t, i| rows_buf[i] = .{ .name = t, .version = "1.0" };

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    var db = try openTestDb();
    defer db.close();
    const out = try outdated_mod.collectOutdatedCasks(&malt.app_ctx.debug_ctx, testing.allocator, &db, &api, dir.path, &rows_buf, null);
    defer freeEntries(testing.allocator, out);

    try testing.expectEqual(@as(usize, tokens.len), out.len);
    for (out, 0..) |entry, i| {
        try testing.expectEqualStrings(tokens[i], entry.name);
        try testing.expectEqualStrings("1.0", entry.installed);
        try testing.expectEqualStrings("2.0", entry.latest);
    }
}

// --- version-map path: routing, revision bumps, fail-loud ---

test "collectOutdated resolves core rows from the version map with no per-keg cache" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init(testing.allocator, "map_only");
    defer dir.deinit();

    // Side-car only — no formula_*.json. Under offline the per-keg path
    // can't reach the network, so a resolved row proves the map was used.
    try dir.writeCacheFile("versions_formula.txt", "alpha\t2.0\t0\nbravo\t1.0\t0\n");

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    api.offline = true;

    const kegs = [_]outdated_mod.KegRow{
        .{ .name = "alpha", .version = "1.0" }, // outdated via map
        .{ .name = "bravo", .version = "1.0" }, // up to date via map
    };
    var db = try openTestDb();
    defer db.close();
    const out = try outdated_mod.collectOutdatedFormulas(&malt.app_ctx.debug_ctx, testing.allocator, &db, &api, dir.path, &kegs, null);
    defer freeEntries(testing.allocator, out);

    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("alpha", out[0].name);
    try testing.expectEqualStrings("1.0", out[0].installed);
    try testing.expectEqualStrings("2.0", out[0].latest);
}

test "collectOutdated detects an upstream revision bump" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init(testing.allocator, "rev_bump");
    defer dir.deinit();

    // Upstream is 1.2 revision 2 for both packages.
    try dir.writeCacheFile("versions_formula.txt", "behind\t1.2\t2\ncurrent\t1.2\t2\n");

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    api.offline = true;

    const kegs = [_]outdated_mod.KegRow{
        .{ .name = "behind", .version = "1.2", .revision = 1 }, // 1.2_1 < 1.2_2
        .{ .name = "current", .version = "1.2", .revision = 2 }, // 1.2_2 == 1.2_2
    };
    var db = try openTestDb();
    defer db.close();
    const out = try outdated_mod.collectOutdatedFormulas(&malt.app_ctx.debug_ctx, testing.allocator, &db, &api, dir.path, &kegs, null);
    defer freeEntries(testing.allocator, out);

    // Only the revision-behind keg is outdated; `latest` carries the full
    // <stable>_<rev>, `installed` shows the keg's own revision.
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("behind", out[0].name);
    try testing.expectEqualStrings("1.2_1", out[0].installed);
    try testing.expectEqualStrings("1.2_2", out[0].latest);
}

test "collectOutdated warns and falls back to per-keg on an empty version map" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init(testing.allocator, "fail_loud");
    defer dir.deinit();

    // Empty side-car (schema shift) but a healthy per-keg cache. The audit
    // must warn and fall back, never report the install as all up to date.
    try dir.writeCacheFile("versions_formula.txt", "");
    try dir.writeCacheFile("formula_alpha.json", "{\"name\":\"alpha\",\"versions\":{\"stable\":\"2.0\"}}");

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    api.offline = true;

    var warn_buf: std.ArrayList(u8) = .empty;
    defer warn_buf.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &warn_buf);
    defer malt.output.endStderrCapture();

    const kegs = [_]outdated_mod.KegRow{
        .{ .name = "alpha", .version = "1.0" },
    };
    var db = try openTestDb();
    defer db.close();
    const out = try outdated_mod.collectOutdatedFormulas(&malt.app_ctx.debug_ctx, testing.allocator, &db, &api, dir.path, &kegs, null);
    defer freeEntries(testing.allocator, out);

    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("alpha", out[0].name);
    try testing.expectEqualStrings("2.0", out[0].latest);
    try testing.expect(std.mem.indexOf(u8, warn_buf.items, "falling back") != null);
}

test "collectOutdated fetch fallback detects an upstream revision-only bump" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init(testing.allocator, "rev_bump_fetch");
    defer dir.deinit();

    // Empty side-car forces the per-keg fetch fallback. Upstream JSON keeps the
    // same stable but bumps revision to 1; the installed keg is the bare 1.2.3.
    try dir.writeCacheFile("versions_formula.txt", "");
    try dir.writeCacheFile("formula_foo.json", "{\"name\":\"foo\",\"versions\":{\"stable\":\"1.2.3\"},\"revision\":1}");

    var api = api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, &http, dir.path);
    api.offline = true;

    // Swallow the expected "version map degraded" warning the empty side-car emits.
    var warn_buf: std.ArrayList(u8) = .empty;
    defer warn_buf.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &warn_buf);
    defer malt.output.endStderrCapture();

    const kegs = [_]outdated_mod.KegRow{
        .{ .name = "foo", .version = "1.2.3", .revision = 0 }, // 1.2.3 < 1.2.3_1
    };
    var db = try openTestDb();
    defer db.close();
    const out = try outdated_mod.collectOutdatedFormulas(&malt.app_ctx.debug_ctx, testing.allocator, &db, &api, dir.path, &kegs, null);
    defer freeEntries(testing.allocator, out);

    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("foo", out[0].name);
    try testing.expectEqualStrings("1.2.3", out[0].installed);
    try testing.expectEqualStrings("1.2.3_1", out[0].latest);
}

// --- --pinned-only filter ---

fn setupPinnedPrefix(suffix: []const u8) ![:0]u8 {
    const path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "/tmp/malt_outdated_pinned_{d}_{s}",
        .{ test_io.nanoTimestamp(
            std.Options.debug_io,
        ), suffix },
        0,
    );
    test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, path);
    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{path});
    defer testing.allocator.free(db_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);
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

fn insertKegWithTap(db: *sqlite.Database, name: []const u8, tap: []const u8) !void {
    var buf: [512]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(
        &buf,
        "INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, tap) VALUES ('{s}', '{s}', '1.0', 'deadbeef', '/cellar/{s}/1.0', '{s}');",
        .{ name, name, name, tap },
    );
    try db.exec(sql);
}

fn insertCaskWithTap(db: *sqlite.Database, token: []const u8, tap: []const u8) !void {
    var buf: [512]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(
        &buf,
        "INSERT INTO casks (token, name, version, url, tap) VALUES ('{s}', '{s}', '120.0', 'https://example.invalid', '{s}');",
        .{ token, token, tap },
    );
    try db.exec(sql);
}

fn insertTap(db: *sqlite.Database, name: []const u8) !void {
    var buf: [512]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(
        &buf,
        "INSERT INTO taps (name, url) VALUES ('{s}', 'https://github.com/{s}.git');",
        .{ name, name },
    );
    try db.exec(sql);
}

test "loadCaskRows .pinned_only returns only pinned casks" {
    const path = try setupPinnedPrefix("filter_pinned_casks");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
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
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
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

// Pre-routing in `mt outdated` mirrors the upgrade path: a row whose
// `casks.tap` is non-null gets its latest version resolved against the
// owning tap's `.rb`, so a tap-cask version bump shows up in the audit
// instead of being silently dropped by the core-API 404 path.
test "loadCaskRows surfaces the owning tap when set" {
    const path = try setupPinnedPrefix("cask_tap_column");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try db.exec(
        \\INSERT INTO casks(token, name, version, url, tap)
        \\VALUES ('flux-markdown', 'flux-markdown', '0.1.0',
        \\        'https://example.invalid/flux.dmg', 'xykong/tap');
    );
    try db.exec(
        \\INSERT INTO casks(token, name, version, url)
        \\VALUES ('legacy-cask', 'legacy-cask', '1.0',
        \\        'https://example.invalid/legacy.dmg');
    );

    const rows = try outdated_mod.loadCaskRows(testing.allocator, &db, .all);
    defer outdated_mod.freeKegRows(testing.allocator, rows);

    try testing.expectEqual(@as(usize, 2), rows.len);
    // ORDER BY token: 'flux-markdown' < 'legacy-cask' alphabetically.
    try testing.expectEqualStrings("flux-markdown", rows[0].name);
    try testing.expect(rows[0].tap != null);
    try testing.expectEqualStrings("xykong/tap", rows[0].tap.?);

    try testing.expectEqualStrings("legacy-cask", rows[1].name);
    try testing.expect(rows[1].tap == null);
}

test "loadFormulaRows surfaces the keg revision; casks report 0" {
    // The revision feeds the pkgVersion comparison; casks have no such
    // column, so the query's `0 AS revision` must come back as 0.
    var db = try openTestDb();
    defer db.close();
    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
        \\VALUES ('rev', 'rev', '1.2', 3, 'sha', '/c/rev/1.2_3');
    );
    try db.exec(
        \\INSERT INTO casks (token, name, version, url)
        \\VALUES ('app', 'app', '4.0', 'https://example.invalid');
    );

    const frows = try outdated_mod.loadFormulaRows(testing.allocator, &db, .all);
    defer outdated_mod.freeKegRows(testing.allocator, frows);
    try testing.expectEqual(@as(usize, 1), frows.len);
    try testing.expectEqual(@as(i64, 3), frows[0].revision);

    const crows = try outdated_mod.loadCaskRows(testing.allocator, &db, .all);
    defer outdated_mod.freeKegRows(testing.allocator, crows);
    try testing.expectEqual(@as(usize, 1), crows.len);
    try testing.expectEqual(@as(i64, 0), crows[0].revision);
}

test "loadFormulaRows .all surfaces the pinned flag and tap attribution" {
    // `mt outdated --json` reads pinned + tap off the keg row so a held
    // package stays visible with `pinned:true` and rows can name their tap.
    const path = try setupPinnedPrefix("formula_pinned_tap");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try insertKeg(&db, "held", true);
    try insertKegWithTap(&db, "scoped", "user/repo");

    const rows = try outdated_mod.loadFormulaRows(testing.allocator, &db, .all);
    defer outdated_mod.freeKegRows(testing.allocator, rows);

    try testing.expectEqual(@as(usize, 2), rows.len);
    // ORDER BY name: 'held' < 'scoped'.
    try testing.expectEqualStrings("held", rows[0].name);
    try testing.expect(rows[0].pinned);
    try testing.expect(rows[0].tap == null);

    try testing.expectEqualStrings("scoped", rows[1].name);
    try testing.expect(!rows[1].pinned);
    try testing.expect(rows[1].tap != null);
    try testing.expectEqualStrings("user/repo", rows[1].tap.?);
}

test "loadCaskRows .all surfaces the pinned flag" {
    const path = try setupPinnedPrefix("cask_pinned_flag");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try insertCask(&db, "free-cask", false);
    try insertCask(&db, "held-cask", true);

    const rows = try outdated_mod.loadCaskRows(testing.allocator, &db, .all);
    defer outdated_mod.freeKegRows(testing.allocator, rows);

    try testing.expectEqual(@as(usize, 2), rows.len);
    // ORDER BY token: 'free-cask' < 'held-cask'.
    try testing.expectEqualStrings("free-cask", rows[0].name);
    try testing.expect(!rows[0].pinned);
    try testing.expectEqualStrings("held-cask", rows[1].name);
    try testing.expect(rows[1].pinned);
}

test "outdated execute --pinned-only walks pinned casks alongside formulas" {
    const path = try setupPinnedPrefix("exec_pinned_mixed");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openSeededDb(path);
        defer db.close();
        try insertKeg(&db, "loose", false);
        try insertCask(&db, "free-cask", false);
        try insertCask(&db, "held-cask", true);
    }

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    // Cask-side row exists and is pinned: the audit must visit it instead of
    // short-circuiting to formula-only scope. With no API cache the row drops
    // out of the result silently — the success contract is "no error, no
    // formula-only override".
    try outdated_mod.execute(&ctx, testing.allocator, &.{"--pinned-only"});
}

test "loadFormulaRows .pinned_only returns only pinned rows" {
    const path = try setupPinnedPrefix("filter_pinned");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
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
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
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
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try insertKeg(&db, "alpha", false);
    try insertKeg(&db, "bravo", false);

    const rows = try outdated_mod.loadFormulaRows(testing.allocator, &db, .pinned_only);
    defer outdated_mod.freeKegRows(testing.allocator, rows);

    try testing.expectEqual(@as(usize, 0), rows.len);
}

// --- --tap filter ----------------------------------------------------

test "loadFormulaRows .by_tap returns only kegs from that tap" {
    const path = try setupPinnedPrefix("filter_by_tap_formula");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try insertKegWithTap(&db, "mine-a", "user/repo");
    try insertKegWithTap(&db, "other", "third/party");
    try insertKegWithTap(&db, "mine-b", "user/repo");
    try insertKeg(&db, "unattributed", false); // NULL tap

    const rows = try outdated_mod.loadFormulaRows(testing.allocator, &db, .{ .by_tap = "user/repo" });
    defer outdated_mod.freeKegRows(testing.allocator, rows);

    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("mine-a", rows[0].name);
    try testing.expectEqualStrings("mine-b", rows[1].name);
}

test "loadCaskRows .by_tap returns only casks from that tap" {
    const path = try setupPinnedPrefix("filter_by_tap_cask");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try insertCaskWithTap(&db, "alpha-cask", "user/repo");
    try insertCaskWithTap(&db, "other-cask", "third/party");
    try insertCaskWithTap(&db, "beta-cask", "user/repo");
    try insertCask(&db, "legacy-cask", false); // NULL tap

    const rows = try outdated_mod.loadCaskRows(testing.allocator, &db, .{ .by_tap = "user/repo" });
    defer outdated_mod.freeKegRows(testing.allocator, rows);

    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("alpha-cask", rows[0].name);
    try testing.expectEqualStrings("beta-cask", rows[1].name);
    // tap column propagates so the live-audit pre-route still resolves.
    try testing.expectEqualStrings("user/repo", rows[0].tap.?);
}

test "tapExists is true for a registered tap and false otherwise" {
    const path = try setupPinnedPrefix("tap_exists_lookup");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try insertTap(&db, "user/repo");

    try testing.expect(try outdated_mod.tapExists(&db, "user/repo"));
    try testing.expect(!try outdated_mod.tapExists(&db, "missing/tap"));
}

test "tapExists accepts a label still referenced by an installed keg after untap" {
    // Real-world: `mt untap user/repo` drops the taps row but leaves
    // installed kegs/casks tagged with that label. The audit must
    // still scope to those rows; rejecting would surface as a typo
    // error for a tap the user clearly still has packages from.
    const path = try setupPinnedPrefix("tap_exists_after_untap_keg");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    // No taps row — the user untapped but kept the install.
    try insertKegWithTap(&db, "leftover", "user/repo");

    try testing.expect(try outdated_mod.tapExists(&db, "user/repo"));
}

test "tapExists accepts a label still referenced by an installed cask after untap" {
    const path = try setupPinnedPrefix("tap_exists_after_untap_cask");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try insertCaskWithTap(&db, "leftover-cask", "user/repo");

    try testing.expect(try outdated_mod.tapExists(&db, "user/repo"));
}

test "tapExists matches case-insensitively across every source table" {
    // Tap labels are conventionally lowercase, but the column type is
    // plain TEXT — a user typing `--tap User/Repo` against a row stored
    // as `user/repo` must still resolve. Strict equality is a UX trap
    // we explicitly reject.
    const path = try setupPinnedPrefix("tap_exists_case_insensitive");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try insertTap(&db, "user/repo");

    try testing.expect(try outdated_mod.tapExists(&db, "User/Repo"));
    try testing.expect(try outdated_mod.tapExists(&db, "USER/REPO"));
}

test "loadFormulaRows .by_tap matches case-insensitively" {
    const path = try setupPinnedPrefix("by_tap_formula_case");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try insertKegWithTap(&db, "kegA", "user/repo");

    const rows = try outdated_mod.loadFormulaRows(testing.allocator, &db, .{ .by_tap = "User/Repo" });
    defer outdated_mod.freeKegRows(testing.allocator, rows);

    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("kegA", rows[0].name);
}

test "loadCaskRows .by_tap matches case-insensitively" {
    const path = try setupPinnedPrefix("by_tap_cask_case");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try insertCaskWithTap(&db, "caskA", "user/repo");

    const rows = try outdated_mod.loadCaskRows(testing.allocator, &db, .{ .by_tap = "USER/repo" });
    defer outdated_mod.freeKegRows(testing.allocator, rows);

    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("caskA", rows[0].name);
}

test "tapExists surfaces a SqliteError when the source tables are missing" {
    // Open the DB without ever running initSchema; the UNION ALL has
    // nothing to prepare against and the error must propagate so
    // `execute` can distinguish "broken schema" from "unknown tap".
    var db = try sqlite.Database.open(":memory:");
    defer db.close();

    const res = outdated_mod.tapExists(&db, "user/repo");
    try testing.expectError(error.PrepareFailed, res);
}

test "outdated execute --tap with an empty label fails clearly" {
    const path = try setupPinnedPrefix("exec_tap_empty");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openSeededDb(path);
        defer db.close();
        try insertTap(&db, "user/repo");
    }

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try testing.expectError(
        error.Aborted,
        outdated_mod.execute(&ctx, testing.allocator, &.{ "--tap", "" }),
    );
    try testing.expectError(
        error.Aborted,
        outdated_mod.execute(&ctx, testing.allocator, &.{ "--tap", "   " }),
    );
}

test "tapExists rejects a label with no row in taps, kegs, or casks" {
    // Typo guard — the audit still has to fail clearly when the
    // label simply doesn't exist anywhere in the local DB.
    const path = try setupPinnedPrefix("tap_exists_typo_guard");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try insertTap(&db, "user/repo");
    try insertKegWithTap(&db, "from-known", "user/repo");
    try insertCaskWithTap(&db, "known-cask", "user/repo");

    try testing.expect(!try outdated_mod.tapExists(&db, "typo/tap"));
}

test "outdated execute --tap accepts a label kept alive only by installed rows" {
    // End-to-end: post-untap, the user runs `mt outdated --tap user/repo`
    // expecting the audit to still scope to their lingering installs.
    const path = try setupPinnedPrefix("exec_tap_after_untap");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openSeededDb(path);
        defer db.close();
        try insertKegWithTap(&db, "leftover", "user/repo");
    }

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try outdated_mod.execute(&ctx, testing.allocator, &.{ "--tap", "user/repo" });
}

test "outdated execute --tap rejects an unknown tap before any cache write" {
    const path = try setupPinnedPrefix("exec_tap_unknown");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openSeededDb(path);
        defer db.close();
        // Only a third-party tap is registered. The user typos.
        try insertTap(&db, "user/repo");
        try insertKegWithTap(&db, "mine", "user/repo");
    }

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    const res = outdated_mod.execute(&ctx, testing.allocator, &.{ "--tap", "unknown/tap" });
    try testing.expectError(error.Aborted, res);
}

test "outdated execute --tap with no following label fails clearly" {
    const path = try setupPinnedPrefix("exec_tap_missing_label");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openSeededDb(path);
        defer db.close();
        try insertTap(&db, "user/repo");
    }

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    const res = outdated_mod.execute(&ctx, testing.allocator, &.{"--tap"});
    try testing.expectError(error.Aborted, res);
}

test "outdated execute --tap=label accepts the equals form" {
    // Twin of the space-form test: the parser has two branches and the
    // happy path must work the same either way. The audit drops kegs
    // with no API cache silently, so success here is "no error" — the
    // filter is exercised by loadFormulaRows/loadCaskRows tests above.
    const path = try setupPinnedPrefix("exec_tap_equals_form");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openSeededDb(path);
        defer db.close();
        try insertTap(&db, "user/repo");
        try insertKegWithTap(&db, "mine", "user/repo");
    }

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try outdated_mod.execute(&ctx, testing.allocator, &.{"--tap=user/repo"});
}

test "outdated execute --tap --json on a known tap succeeds and skips the snapshot refresh" {
    // Acceptance: --json honours the filter. The filter is applied at
    // the row-loader layer (already covered by loadFormulaRows .by_tap
    // / loadCaskRows .by_tap), and json_mode flows independently into
    // the render call — so the combination works by construction. We
    // still exercise the full execute() to catch wiring regressions
    // and to assert the cache stays untouched.
    const path = try setupPinnedPrefix("exec_tap_json");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openSeededDb(path);
        defer db.close();
        try insertTap(&db, "user/repo");
        try insertKegWithTap(&db, "scoped", "user/repo");
    }

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try outdated_mod.execute(&ctx, testing.allocator, &.{ "--tap", "user/repo", "--json" });
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
            .{ test_io.nanoTimestamp(
                std.Options.debug_io,
            ), suffix },
            0,
        );
        const cache = try std.fmt.allocPrintSentinel(
            testing.allocator,
            "{s}/cache",
            .{prefix},
            0,
        );
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        try test_io.cwd().createDirPath(std.Options.debug_io, prefix);
        try test_io.cwd().createDirPath(std.Options.debug_io, cache);
        const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{prefix});
        defer testing.allocator.free(db_dir);
        try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);

        _ = c.setenv("MALT_PREFIX", prefix.ptr, 1);
        _ = c.setenv("MALT_CACHE", cache.ptr, 1);
        return .{ .prefix_path = prefix, .cache_path = cache };
    }

    fn deinit(self: *UpdateEnv) void {
        _ = c.unsetenv("MALT_PREFIX");
        _ = c.unsetenv("MALT_CACHE");
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.prefix_path) catch {};
        testing.allocator.free(self.prefix_path);
        testing.allocator.free(self.cache_path);
    }

    fn writeApiFile(self: UpdateEnv, rel: []const u8, body: []const u8) !void {
        var dir_buf: [512]u8 = undefined;
        const api_dir = try std.fmt.bufPrint(&dir_buf, "{s}/api", .{self.cache_path});
        try test_io.cwd().createDirPath(std.Options.debug_io, api_dir);
        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ api_dir, rel });
        const f = try test_io.cwd().createFile(std.Options.debug_io, path, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, body);
    }

    fn apiFileExists(self: UpdateEnv, rel: []const u8) bool {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/api/{s}", .{ self.cache_path, rel }) catch return false;
        test_io.accessAbsolute(std.Options.debug_io, path, .{}) catch return false;
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

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try update_mod.execute(&ctx, testing.allocator, &.{"--check"});

    // Snapshot was written.
    const snap_opt = outdated_mod.readSnapshot(std.Options.debug_io, testing.allocator, env.cache_path);
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

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try update_mod.execute(&ctx, testing.allocator, &.{});

    // Cache wipe still happens.
    try testing.expect(!env.apiFileExists("formula_alpha.json"));
    // No snapshot is written: keeping `mt update` cheap is the contract.
    try testing.expectEqual(
        @as(?outdated_mod.OwnedSnapshot, null),
        outdated_mod.readSnapshot(std.Options.debug_io, testing.allocator, env.cache_path),
    );
}

test "update without --check deletes a stale snapshot to force fresh recompute next run" {
    var env = try UpdateEnv.init("default_deletes_snapshot");
    defer env.deinit();

    // Pre-existing snapshot from a prior run: the cache wipe just
    // dropped its data source, so the snapshot has no business surviving.
    try outdated_mod.writeSnapshot(std.Options.debug_io, testing.allocator, env.cache_path, .{
        .generated_at_ms = test_io.milliTimestamp(
            std.Options.debug_io,
        ),
        .formulas = &[_]outdated_mod.OutdatedEntry{},
        .casks = &[_]outdated_mod.OutdatedEntry{},
    });
    try testing.expect(outdated_mod.readSnapshot(std.Options.debug_io, testing.allocator, env.cache_path) != null);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try update_mod.execute(&ctx, testing.allocator, &.{});

    try testing.expectEqual(
        @as(?outdated_mod.OwnedSnapshot, null),
        outdated_mod.readSnapshot(std.Options.debug_io, testing.allocator, env.cache_path),
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
    const marker_ts: i64 = test_io.milliTimestamp(
        std.Options.debug_io,
    ) - 1000;
    const formulas = [_]outdated_mod.OutdatedEntry{
        .{ .name = @constCast("alpha"), .installed = @constCast("1.0"), .latest = @constCast("9.9") },
    };
    try outdated_mod.writeSnapshot(std.Options.debug_io, testing.allocator, env.cache_path, .{
        .generated_at_ms = marker_ts,
        .formulas = &formulas,
        .casks = &[_]outdated_mod.OutdatedEntry{},
    });

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try outdated_mod.execute(&ctx, testing.allocator, &.{});

    // The marker timestamp survives — proof the snapshot was read and
    // not regenerated by the recompute path.
    const after_opt = outdated_mod.readSnapshot(std.Options.debug_io, testing.allocator, env.cache_path);
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

    const marker_ts: i64 = test_io.milliTimestamp(
        std.Options.debug_io,
    ) - 1000;
    const formulas = [_]outdated_mod.OutdatedEntry{
        .{ .name = @constCast("alpha"), .installed = @constCast("1.0"), .latest = @constCast("2.0") },
        .{ .name = @constCast("ghost"), .installed = @constCast("0.5"), .latest = @constCast("1.0") },
    };
    try outdated_mod.writeSnapshot(std.Options.debug_io, testing.allocator, env.cache_path, .{
        .generated_at_ms = marker_ts,
        .formulas = &formulas,
        .casks = &[_]outdated_mod.OutdatedEntry{},
    });

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try outdated_mod.execute(&ctx, testing.allocator, &.{});

    // Marker timestamp survives -> execute() took the snapshot path
    // (recompute would have rewritten it with a fresh timestamp).
    const after_opt = outdated_mod.readSnapshot(std.Options.debug_io, testing.allocator, env.cache_path);
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

test "intersectWithDb keeps a revisioned keg loaded from the DB" {
    // End-to-end: a revisioned keg loads as bare version + revision, while the
    // snapshot stores the revision-qualified installed. The intersect must
    // rebuild the qualified string from the row so the keg stays listed.
    var env = try UpdateEnv.init("outdated_revision_intersect");
    defer env.deinit();

    {
        var db = try openUpdateDb(env.prefix_path);
        defer db.close();
        try db.exec(
            "INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path) " ++
                "VALUES ('alpha', 'alpha', '1.2.3', 1, 'deadbeef', '/cellar/alpha/1.2.3_1');",
        );
    }

    const formulas = [_]outdated_mod.OutdatedEntry{
        .{ .name = @constCast("alpha"), .installed = @constCast("1.2.3_1"), .latest = @constCast("1.3.0") },
    };

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
    try testing.expectEqualStrings("1.2.3_1", filtered[0].installed);
}

test "outdated execute serves a stale snapshot offline rather than recomputing" {
    var env = try UpdateEnv.init("outdated_stale_uses_cache");
    defer env.deinit();

    {
        var db = try openUpdateDb(env.prefix_path);
        defer db.close();
        try insertKegV1(&db, "alpha");
    }

    // 30-day-old snapshot — well past the default threshold. Online this would
    // recompute; offline we can't refresh, so the cached read is served and the
    // snapshot is left intact (a complete stale read beats under-reporting).
    const month_ms: i64 = 30 * 24 * 60 * 60 * 1000;
    const formulas = [_]outdated_mod.OutdatedEntry{
        .{ .name = @constCast("alpha"), .installed = @constCast("1.0"), .latest = @constCast("3.0") },
    };
    try outdated_mod.writeSnapshot(std.Options.debug_io, testing.allocator, env.cache_path, .{
        .generated_at_ms = test_io.milliTimestamp(
            std.Options.debug_io,
        ) - month_ms,
        .formulas = &formulas,
        .casks = &[_]outdated_mod.OutdatedEntry{},
    });

    // Offline + stale: emits entries with a staleness warning on stderr, and
    // must NOT overwrite the snapshot. We verify the post-execute snapshot
    // still contains "alpha->3.0" rather than a fresh empty recompute.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty, .offline = true };
    try outdated_mod.execute(&ctx, testing.allocator, &.{});

    const after_opt = outdated_mod.readSnapshot(std.Options.debug_io, testing.allocator, env.cache_path);
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
    try outdated_mod.writeSnapshot(std.Options.debug_io, testing.allocator, env.cache_path, .{
        .generated_at_ms = test_io.milliTimestamp(
            std.Options.debug_io,
        ),
        .formulas = &formulas,
        .casks = &[_]outdated_mod.OutdatedEntry{},
    });

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try outdated_mod.execute(&ctx, testing.allocator, &.{"--refresh"});

    // After --refresh, the snapshot is regenerated to reflect actual state.
    const fresh_opt = outdated_mod.readSnapshot(std.Options.debug_io, testing.allocator, env.cache_path);
    try testing.expect(fresh_opt != null);
    const fresh = fresh_opt.?;
    defer outdated_mod.freeSnapshot(testing.allocator, fresh);
    try testing.expectEqual(@as(usize, 0), fresh.formulas.len);
    try testing.expectEqual(@as(usize, 0), fresh.casks.len);
}

test "writeSnapshot then readSnapshot round-trips entries through the cache file" {
    var dir = try TempCacheDir.init(testing.allocator, "snapshot_round_trip");
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
    try outdated_mod.writeSnapshot(std.Options.debug_io, testing.allocator, dir.path, snap);

    const read_opt = outdated_mod.readSnapshot(std.Options.debug_io, testing.allocator, dir.path);
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
    var dir = try TempCacheDir.init(testing.allocator, "snapshot_missing");
    defer dir.deinit();
    try testing.expectEqual(@as(?outdated_mod.OwnedSnapshot, null), outdated_mod.readSnapshot(std.Options.debug_io, testing.allocator, dir.path));
}

test "readSnapshot returns null on garbage contents" {
    var dir = try TempCacheDir.init(testing.allocator, "snapshot_garbage");
    defer dir.deinit();
    const path = try outdated_mod.snapshotPath(testing.allocator, dir.path);
    defer testing.allocator.free(path);
    const f = try test_io.cwd().createFile(std.Options.debug_io, path, .{});
    defer f.close(std.Options.debug_io);
    try f.writeStreamingAll(std.Options.debug_io, "not-json-at-all");
    try testing.expectEqual(@as(?outdated_mod.OwnedSnapshot, null), outdated_mod.readSnapshot(std.Options.debug_io, testing.allocator, dir.path));
}

test "writeSnapshot creates the cache directory if missing" {
    // Unique per process+init so overlapping runs don't share this dir; it must
    // not exist yet, so writeSnapshot is the one that creates it.
    const path = try test_io.uniqueTempPath(testing.allocator, "outdated_test", "snapshot_mkdir");
    defer testing.allocator.free(path);
    test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};

    const snap: outdated_mod.Snapshot = .{
        .generated_at_ms = 0,
        .formulas = &[_]outdated_mod.OutdatedEntry{},
        .casks = &[_]outdated_mod.OutdatedEntry{},
    };
    try outdated_mod.writeSnapshot(std.Options.debug_io, testing.allocator, path, snap);

    const read_opt = outdated_mod.readSnapshot(std.Options.debug_io, testing.allocator, path);
    try testing.expect(read_opt != null);
    const read = read_opt.?;
    defer outdated_mod.freeSnapshot(testing.allocator, read);
    try testing.expectEqual(@as(usize, 0), read.formulas.len);
    try testing.expectEqual(@as(usize, 0), read.casks.len);
}

test "outdated execute --pinned-only is a quiet no-op when no kegs are pinned" {
    const path = try setupPinnedPrefix("exec_no_pins");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openSeededDb(path);
        defer db.close();
        try insertKeg(&db, "alpha", false);
    }

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    // No pinned kegs => no API calls => quiet success even with no cache.
    try outdated_mod.execute(&ctx, testing.allocator, &.{"--pinned-only"});
}
