//! malt — `mt pin` / `mt unpin` behaviour tests
//! Locks in the pin/unpin contract: setting the column on an installed
//! keg, idempotent re-pin, error handling for missing-name and
//! not-installed cases. Uses a scratch MALT_PREFIX so no real DB is hit.

const std = @import("std");
const malt = @import("malt");
const testing = std.testing;
const cli_pin = malt.cli_pin;
const sqlite = malt.sqlite;
const schema = malt.schema;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

fn setupPrefix(suffix: []const u8) ![:0]u8 {
    const path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "/tmp/malt_pin_test_{d}_{s}",
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

fn openDb(prefix: [:0]const u8) !sqlite.Database {
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

fn readPinned(db: *sqlite.Database, name: []const u8) !bool {
    var stmt = try db.prepare("SELECT pinned FROM kegs WHERE name = ?1 LIMIT 1;");
    defer stmt.finalize();
    try stmt.bindText(1, name);
    const has = try stmt.step();
    if (!has) return error.NotFound;
    return stmt.columnBool(0);
}

test "mt pin <name> sets pinned=1 on installed keg" {
    const path = try setupPrefix("pin_set");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openDb(path);
        defer db.close();
        try insertKeg(&db, "alpha", false);
    }

    try cli_pin.execute(testing.allocator, &.{"alpha"});

    var db = try openDb(path);
    defer db.close();
    try testing.expectEqual(true, try readPinned(&db, "alpha"));
}

test "mt unpin <name> clears pinned" {
    const path = try setupPrefix("unpin_clear");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openDb(path);
        defer db.close();
        try insertKeg(&db, "bravo", true);
    }

    try cli_pin.executeUnpin(testing.allocator, &.{"bravo"});

    var db = try openDb(path);
    defer db.close();
    try testing.expectEqual(false, try readPinned(&db, "bravo"));
}

test "mt pin with no args returns Aborted (usage)" {
    const path = try setupPrefix("pin_noargs");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    try testing.expectError(error.Aborted, cli_pin.execute(testing.allocator, &.{}));
}

test "mt unpin with no args returns Aborted (usage)" {
    const path = try setupPrefix("unpin_noargs");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    try testing.expectError(error.Aborted, cli_pin.executeUnpin(testing.allocator, &.{}));
}

test "mt pin <not-installed> returns Aborted" {
    const path = try setupPrefix("pin_notinst");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openDb(path);
        defer db.close();
    }

    try testing.expectError(
        error.Aborted,
        cli_pin.execute(testing.allocator, &.{"definitely-not-installed"}),
    );
}

test "mt unpin <not-installed> returns Aborted" {
    const path = try setupPrefix("unpin_notinst");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openDb(path);
        defer db.close();
    }

    try testing.expectError(
        error.Aborted,
        cli_pin.executeUnpin(testing.allocator, &.{"definitely-not-installed"}),
    );
}

test "isPinned reflects DB column" {
    const path = try setupPrefix("ispinned");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openDb(path);
    defer db.close();
    try insertKeg(&db, "uno", false);
    try insertKeg(&db, "due", true);

    try testing.expect(!cli_pin.isPinned(&db, "uno"));
    try testing.expect(cli_pin.isPinned(&db, "due"));
    try testing.expect(!cli_pin.isPinned(&db, "missing"));
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

fn readCaskPinned(db: *sqlite.Database, token: []const u8) !bool {
    var stmt = try db.prepare("SELECT pinned FROM casks WHERE token = ?1 LIMIT 1;");
    defer stmt.finalize();
    try stmt.bindText(1, token);
    const has = try stmt.step();
    if (!has) return error.NotFound;
    return stmt.columnBool(0);
}

test "mt pin <cask-token> falls through kegs and sets casks.pinned" {
    const path = try setupPrefix("pin_cask_set");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openDb(path);
        defer db.close();
        try insertCask(&db, "firefox", false);
    }

    try cli_pin.execute(testing.allocator, &.{"firefox"});

    var db = try openDb(path);
    defer db.close();
    try testing.expectEqual(true, try readCaskPinned(&db, "firefox"));
}

test "mt unpin <cask-token> clears casks.pinned" {
    const path = try setupPrefix("unpin_cask_clear");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openDb(path);
        defer db.close();
        try insertCask(&db, "slack", true);
    }

    try cli_pin.executeUnpin(testing.allocator, &.{"slack"});

    var db = try openDb(path);
    defer db.close();
    try testing.expectEqual(false, try readCaskPinned(&db, "slack"));
}

test "mt pin <cask> is idempotent — re-pinning a cask still succeeds" {
    const path = try setupPrefix("pin_cask_idempotent");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openDb(path);
        defer db.close();
        try insertCask(&db, "obsidian", true);
    }

    try cli_pin.execute(testing.allocator, &.{"obsidian"});

    var db = try openDb(path);
    defer db.close();
    try testing.expectEqual(true, try readCaskPinned(&db, "obsidian"));
}

test "isPinned reflects casks.pinned via fall-through" {
    const path = try setupPrefix("ispinned_cask");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openDb(path);
    defer db.close();
    try insertCask(&db, "loose-cask", false);
    try insertCask(&db, "held-cask", true);

    try testing.expect(!cli_pin.isPinned(&db, "loose-cask"));
    try testing.expect(cli_pin.isPinned(&db, "held-cask"));
}

test "mt pin is idempotent — re-pinning is a no-op success" {
    const path = try setupPrefix("pin_idempotent");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openDb(path);
        defer db.close();
        try insertKeg(&db, "tre", true);
    }

    try cli_pin.execute(testing.allocator, &.{"tre"});

    var db = try openDb(path);
    defer db.close();
    try testing.expectEqual(true, try readPinned(&db, "tre"));
}
