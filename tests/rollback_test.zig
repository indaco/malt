//! malt — rollback command tests
//! Integration tests for rollback require a full install cycle.
//! Unit tests here cover the DB query logic.

const std = @import("std");
const testing = std.testing;
const sqlite = @import("malt").sqlite;
const schema = @import("malt").schema;

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
