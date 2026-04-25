//! malt — upgrade.execute behaviour tests
//! Locks in the exit-code contract: an upgrade that touches a package we
//! cannot upgrade (not installed, or batch item failure) must surface a
//! non-zero exit instead of silently reporting success. Uses a scratch
//! MALT_PREFIX so no real DB or network is hit.

const std = @import("std");
const malt = @import("malt");
const testing = std.testing;
const upgrade = malt.upgrade;
const sqlite = malt.sqlite;
const schema = malt.schema;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

fn setupPrefix(suffix: []const u8) ![:0]u8 {
    const path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "/tmp/malt_upgrade_exec_{d}_{s}",
        .{ malt.fs_compat.nanoTimestamp(), suffix },
        0,
    );
    malt.fs_compat.deleteTreeAbsolute(path) catch {};
    try malt.fs_compat.cwd().makePath(path);
    _ = c.setenv("MALT_PREFIX", path.ptr, 1);
    return path;
}

test "mt upgrade <nonexistent> surfaces a non-zero exit" {
    const path = try setupPrefix("nonexistent_pkg");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    // Seed an empty DB so the `db/` dir exists (lock acquire doesn't
    // short-circuit to silent-return) but no packages are installed.
    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{path});
    defer testing.allocator.free(db_dir);
    try malt.fs_compat.cwd().makePath(db_dir);

    try testing.expectError(
        error.Aborted,
        upgrade.execute(testing.allocator, &.{"definitely-not-installed"}),
    );
}

fn openSeededDb(prefix: [:0]const u8) !sqlite.Database {
    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{prefix});
    defer testing.allocator.free(db_dir);
    try malt.fs_compat.cwd().makePath(db_dir);

    var buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    errdefer db.close();
    try schema.initSchema(&db);
    return db;
}

fn insertPinnedKeg(db: *sqlite.Database, name: []const u8) !void {
    var buf: [512]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(
        &buf,
        "INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, pinned) VALUES ('{s}', '{s}', '1.0', 'deadbeef', '/cellar/{s}/1.0', 1);",
        .{ name, name, name },
    );
    try db.exec(sql);
}

test "mt upgrade <pinned> is a quiet no-op (no API call)" {
    const path = try setupPrefix("pinned_skip_named");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openSeededDb(path);
        defer db.close();
        try insertPinnedKeg(&db, "alpha-pinned");
    }

    // Pinned name short-circuits before fetchFormula — must NOT error.
    try upgrade.execute(testing.allocator, &.{"alpha-pinned"});
}

test "mt upgrade (no args) skips pinned kegs without aggregating failures" {
    const path = try setupPrefix("pinned_skip_bulk");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openSeededDb(path);
        defer db.close();
        try insertPinnedKeg(&db, "first-pinned");
        try insertPinnedKeg(&db, "second-pinned");
    }

    // All-pinned bulk run: every keg is skipped, no failures aggregate.
    try upgrade.execute(testing.allocator, &.{});
}

test "pinSkip honours --force: pinned + force = false (no skip)" {
    const path = try setupPrefix("pinskip_helper");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try insertPinnedKeg(&db, "forced");
    try db.exec("INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path) VALUES ('loose', 'loose', '1.0', 'sha', '/cellar/loose/1.0');");

    // pinned + !force = skip
    try testing.expect(upgrade.pinSkip(&db, "forced", false));
    // pinned + force = no skip (the whole point of --force)
    try testing.expect(!upgrade.pinSkip(&db, "forced", true));
    // unpinned: never skipped, force or not
    try testing.expect(!upgrade.pinSkip(&db, "loose", false));
    try testing.expect(!upgrade.pinSkip(&db, "loose", true));
    // unknown name: not pinned, not skipped
    try testing.expect(!upgrade.pinSkip(&db, "ghost", false));
}
