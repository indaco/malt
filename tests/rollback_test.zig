//! malt — rollback command tests
//! Integration tests for rollback require a full install cycle.
//! Unit tests here cover the DB query logic and the error-exit-code contract
//! (every user-facing failure must return `error.Aborted`, not a silent `void`).

const std = @import("std");
const testing = std.testing;
const sqlite = @import("malt").sqlite;
const schema = @import("malt").schema;
const rollback = @import("malt").cli_rollback;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

fn setPrefix(v: [:0]const u8) void {
    _ = c.setenv("MALT_PREFIX", v.ptr, 1);
}
fn unsetPrefix() void {
    _ = c.unsetenv("MALT_PREFIX");
}

/// Create a sandboxed malt prefix with an initialized empty DB. Caller must
/// `deleteTreeAbsolute` on the returned path.
fn makeSandbox(path: [:0]const u8) !void {
    std.fs.deleteTreeAbsolute(path) catch {};
    try std.fs.makeDirAbsolute(path);

    var db_sub_buf: [512]u8 = undefined;
    const db_sub = try std.fmt.bufPrint(&db_sub_buf, "{s}/db", .{path});
    try std.fs.makeDirAbsolute(db_sub);

    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/db/malt.db", .{path});
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);
}

test "schema creates kegs table with expected columns" {
    const prefix = "/tmp/malt_rb_test";
    std.fs.makeDirAbsolute(prefix) catch {};
    defer std.fs.deleteTreeAbsolute(prefix) catch {};

    var db = try sqlite.Database.open("/tmp/malt_rb_test/rb.db");
    defer db.close();
    try schema.initSchema(&db);

    // Insert a keg and verify it can be queried
    try db.exec("INSERT INTO kegs (name, full_name, version, revision, tap, store_sha256, cellar_path, install_reason) VALUES ('wget', 'wget', '1.24', 0, 'homebrew/core', 'abc', '/tmp/cellar', 'direct');");

    var stmt = try db.prepare("SELECT name, version FROM kegs WHERE name = 'wget';");
    defer stmt.finalize();
    const has_row = try stmt.step();
    try testing.expect(has_row);

    const name = stmt.columnText(0) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("wget", std.mem.sliceTo(name, 0));
}

test "rollback returns error.Aborted when no package name given" {
    // Even without a prefix, the usage check fires first and must error.
    const err = rollback.execute(testing.allocator, &.{});
    try testing.expectError(error.Aborted, err);
}

test "rollback returns error.Aborted for package not installed" {
    const prefix: [:0]const u8 = "/tmp/malt_rb_notinstalled";
    try makeSandbox(prefix);
    defer std.fs.deleteTreeAbsolute(prefix) catch {};

    setPrefix(prefix);
    defer unsetPrefix();

    const args = [_][]const u8{"nonexistent-pkg"};
    const err = rollback.execute(testing.allocator, &args);
    try testing.expectError(error.Aborted, err);
}

test "rollback returns error.Aborted when no previous version exists in store" {
    const prefix: [:0]const u8 = "/tmp/malt_rb_nostore";
    try makeSandbox(prefix);
    defer std.fs.deleteTreeAbsolute(prefix) catch {};

    // Record an installed keg but deliberately omit the store/ directory so
    // the store-scan path fails with "Cannot read store directory".
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/db/malt.db", .{prefix});
    var db = try sqlite.Database.open(db_path);
    try db.exec("INSERT INTO kegs (name, full_name, version, revision, tap, store_sha256, cellar_path, install_reason) VALUES ('wget', 'wget', '1.24', 0, 'homebrew/core', 'deadbeef', '/tmp/none', 'direct');");
    db.close();

    setPrefix(prefix);
    defer unsetPrefix();

    const args = [_][]const u8{"wget"};
    const err = rollback.execute(testing.allocator, &args);
    try testing.expectError(error.Aborted, err);
}

test "schema version table exists" {
    const prefix = "/tmp/malt_sv_test";
    std.fs.makeDirAbsolute(prefix) catch {};
    defer std.fs.deleteTreeAbsolute(prefix) catch {};

    var db = try sqlite.Database.open("/tmp/malt_sv_test/sv.db");
    defer db.close();
    try schema.initSchema(&db);

    var stmt = try db.prepare("SELECT version FROM schema_version LIMIT 1;");
    defer stmt.finalize();
    const has_row = try stmt.step();
    try testing.expect(has_row);
}
