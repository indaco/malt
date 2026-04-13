//! malt — schema v2 migration tests

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const sqlite = malt.sqlite;
const schema = malt.schema;

const TempDb = struct {
    dir: []const u8,
    db: sqlite.Database,

    fn init(comptime tag: []const u8) !TempDb {
        const dir = "/tmp/malt_schema_v2_test_" ++ tag;
        std.fs.deleteTreeAbsolute(dir) catch {};
        try std.fs.makeDirAbsolute(dir);
        var db_path_buf: [256]u8 = undefined;
        const db_path = try std.fmt.bufPrint(&db_path_buf, "{s}/test.db", .{dir});
        var db = try sqlite.Database.open(db_path);
        errdefer db.close();
        return .{ .dir = dir, .db = db };
    }

    fn deinit(self: *TempDb) void {
        self.db.close();
        std.fs.deleteTreeAbsolute(self.dir) catch {};
    }
};

fn tableExists(db: *sqlite.Database, name: [:0]const u8) !bool {
    var buf: [256]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(
        &buf,
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='{s}';",
        .{name},
    );
    var stmt = try db.prepare(sql);
    defer stmt.finalize();
    _ = try stmt.step();
    return stmt.columnInt(0) == 1;
}

test "initSchema runs v1 then migrates to v2" {
    var tdb = try TempDb.init("init");
    defer tdb.deinit();

    try schema.initSchema(&tdb.db);

    try testing.expect(try tableExists(&tdb.db, "kegs"));
    try testing.expect(try tableExists(&tdb.db, "services"));
    try testing.expect(try tableExists(&tdb.db, "bundles"));
    try testing.expect(try tableExists(&tdb.db, "bundle_members"));

    const ver = try schema.currentVersion(&tdb.db);
    try testing.expectEqual(@as(i64, 2), ver);
}

test "migrate is idempotent on re-run" {
    var tdb = try TempDb.init("idempotent");
    defer tdb.deinit();

    try schema.initSchema(&tdb.db);
    try schema.migrate(&tdb.db);
    try schema.migrate(&tdb.db);

    const ver = try schema.currentVersion(&tdb.db);
    try testing.expectEqual(@as(i64, 2), ver);
}

test "services table accepts inserts and enforces PK" {
    var tdb = try TempDb.init("services_pk");
    defer tdb.deinit();

    try schema.initSchema(&tdb.db);

    try tdb.db.exec(
        \\INSERT INTO services(name, keg_name, plist_path, auto_start)
        \\VALUES ('postgresql@16', 'postgresql@16', '/tmp/p.plist', 1);
    );

    const dup_result = tdb.db.exec(
        \\INSERT INTO services(name, keg_name, plist_path, auto_start)
        \\VALUES ('postgresql@16', 'postgresql@16', '/tmp/p.plist', 1);
    );
    try testing.expectError(sqlite.SqliteError.ConstraintViolation, dup_result);
}

test "bundle_members cascade-deletes with bundle" {
    var tdb = try TempDb.init("cascade");
    defer tdb.deinit();

    try schema.initSchema(&tdb.db);

    try tdb.db.exec(
        \\INSERT INTO bundles(name, manifest_path, created_at, version)
        \\VALUES ('devtools', '/tmp/Brewfile', 1700000000, 1);
    );
    try tdb.db.exec(
        \\INSERT INTO bundle_members(bundle_name, kind, ref, spec)
        \\VALUES ('devtools', 'formula', 'wget', NULL);
    );

    try tdb.db.exec("DELETE FROM bundles WHERE name='devtools';");

    var stmt = try tdb.db.prepare("SELECT COUNT(*) FROM bundle_members;");
    defer stmt.finalize();
    _ = try stmt.step();
    try testing.expectEqual(@as(i64, 0), stmt.columnInt(0));
}
