//! malt — info command integration tests
//!
//! Integration coverage that needs real side effects: the `openDb`
//! filesystem behaviour (a prefix with/without a `db/` dir) and the
//! DB-backed dependency read. The pure encoder unit tests live inline in
//! `src/cli/info.zig`.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");
const info = malt.cli_info;
const sqlite = malt.sqlite;
const schema = malt.schema;

test "openDb returns null when the prefix has no db/ directory" {
    // Fresh prefix with no db/ subdir at all — SQLite's OPEN_CREATE
    // cannot create intermediate dirs, so the open must fail and
    // the helper must turn that into a null instead of an error.
    const prefix = "/tmp/malt_info_test_missing_db";
    test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try test_io.makeDirAbsolute(std.Options.debug_io, prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try testing.expect(info.openDb(prefix) == null);
}

test "openDb succeeds and returns a usable handle when db/ exists" {
    const prefix = "/tmp/malt_info_test_ok_db";
    test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try test_io.makeDirAbsolute(std.Options.debug_io, prefix);
    var db_buf: [512]u8 = undefined;
    const db_dir = try std.fmt.bufPrint(&db_buf, "{s}/db", .{prefix});
    try test_io.makeDirAbsolute(std.Options.debug_io, db_dir);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var db = info.openDb(prefix) orelse return error.ExpectedDatabase;
    defer db.close();
}

test "openDb returns null when the prefix itself does not exist" {
    // A completely absent prefix path — typical when MALT_PREFIX is
    // pointed at a freshly-minted directory that hasn't been
    // populated by any malt command yet.
    const prefix = "/tmp/malt_info_test_no_prefix_at_all";
    test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try testing.expect(info.openDb(prefix) == null);
}

// --- collectInstalledDeps: DB-backed dependency read --------------------
//
// The detail pane must read an installed keg's deps from the recorded
// `dependencies` table — offline, no network re-resolve. These tests
// build a tiny kegs+dependencies fixture and pin the caller-observable
// list, including the empty-deps and not-installed edges.

fn makeDepsDb(tag: []const u8) !sqlite.Database {
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "/tmp/malt_info_deps_test_{s}.db", .{tag}, 0);
    test_io.deleteFileAbsolute(std.Options.debug_io, path) catch {};
    var db = try sqlite.Database.open(path);
    try schema.initSchema(&db);
    return db;
}

fn insertKegRow(db: *sqlite.Database, name: []const u8) !i64 {
    var stmt = try db.prepare(
        "INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path)" ++
            " VALUES (?1, ?1, '1.0', ?1, '/tmp/cellar') RETURNING id;",
    );
    defer stmt.finalize();
    try stmt.bindText(1, name);
    _ = try stmt.step();
    return stmt.columnInt(0);
}

fn addDepRow(db: *sqlite.Database, keg_id: i64, dep_name: []const u8) !void {
    var stmt = try db.prepare(
        "INSERT INTO dependencies (keg_id, dep_name) VALUES (?1, ?2);",
    );
    defer stmt.finalize();
    try stmt.bindInt(1, keg_id);
    try stmt.bindText(2, dep_name);
    _ = try stmt.step();
}

fn freeDepsSlice(deps: []const []const u8) void {
    for (deps) |d| testing.allocator.free(d);
    testing.allocator.free(deps);
}

test "collectInstalledDeps reads a fixture keg's recorded deps, alphabetised" {
    var db = try makeDepsDb("populated");
    defer db.close();

    // Insert deps out of order to prove the reader sorts rather than
    // leaking insertion order to consumers.
    const wget_id = try insertKegRow(&db, "wget");
    try addDepRow(&db, wget_id, "openssl@3");
    try addDepRow(&db, wget_id, "libidn2");

    const deps = info.collectInstalledDeps(testing.allocator, &db, "wget");
    defer freeDepsSlice(deps);

    try testing.expectEqual(@as(usize, 2), deps.len);
    try testing.expectEqualStrings("libidn2", deps[0]);
    try testing.expectEqualStrings("openssl@3", deps[1]);
}

test "collectInstalledDeps returns an empty slice for an installed leaf" {
    var db = try makeDepsDb("leaf");
    defer db.close();

    _ = try insertKegRow(&db, "tree");

    const deps = info.collectInstalledDeps(testing.allocator, &db, "tree");
    defer freeDepsSlice(deps);

    try testing.expectEqual(@as(usize, 0), deps.len);
}

test "collectInstalledDeps returns an empty slice when the keg is not installed" {
    var db = try makeDepsDb("absent");
    defer db.close();

    const deps = info.collectInstalledDeps(testing.allocator, &db, "ghost");
    defer freeDepsSlice(deps);

    try testing.expectEqual(@as(usize, 0), deps.len);
}
