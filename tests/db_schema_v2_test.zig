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
        malt.fs_compat.deleteTreeAbsolute(dir) catch {};
        try malt.fs_compat.makeDirAbsolute(dir);
        var db_path_buf: [256]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/test.db", .{dir}, 0);
        var db = try sqlite.Database.open(db_path);
        errdefer db.close();
        return .{ .dir = dir, .db = db };
    }

    fn deinit(self: *TempDb) void {
        self.db.close();
        malt.fs_compat.deleteTreeAbsolute(self.dir) catch {};
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

test "initSchema runs v1 then migrates to v3" {
    var tdb = try TempDb.init("init");
    defer tdb.deinit();

    try schema.initSchema(&tdb.db);

    try testing.expect(try tableExists(&tdb.db, "kegs"));
    try testing.expect(try tableExists(&tdb.db, "services"));
    try testing.expect(try tableExists(&tdb.db, "bundles"));
    try testing.expect(try tableExists(&tdb.db, "bundle_members"));

    const ver = try schema.currentVersion(&tdb.db);
    try testing.expectEqual(@as(i64, 3), ver);
}

test "migrate is idempotent on re-run" {
    var tdb = try TempDb.init("idempotent");
    defer tdb.deinit();

    try schema.initSchema(&tdb.db);
    try schema.migrate(&tdb.db);
    try schema.migrate(&tdb.db);

    const ver = try schema.currentVersion(&tdb.db);
    try testing.expectEqual(@as(i64, 3), ver);
}

test "v3 migration adds commit_sha column to taps" {
    var tdb = try TempDb.init("v3_column");
    defer tdb.deinit();

    try schema.initSchema(&tdb.db);

    // INSERT should accept a value in commit_sha without blowing up.
    try tdb.db.exec(
        \\INSERT INTO taps(name, url, commit_sha)
        \\VALUES ('user/repo', 'https://github.com/user/repo',
        \\        '0123456789abcdef0123456789abcdef01234567');
    );

    var stmt = try tdb.db.prepare("SELECT commit_sha FROM taps WHERE name='user/repo';");
    defer stmt.finalize();
    _ = try stmt.step();
    const raw = stmt.columnText(0) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef01234567",
        std.mem.sliceTo(raw, 0),
    );
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

test "Database.exec accepts 12 KB SQL" {
    var tdb = try TempDb.init("exec_12kb");
    defer tdb.deinit();

    try tdb.db.exec("CREATE TABLE big(v TEXT);");

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try list.appendSlice(testing.allocator, "INSERT INTO big(v) VALUES");
    const row = "('xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'),";
    while (list.items.len < 12 * 1024) {
        try list.appendSlice(testing.allocator, row);
    }
    list.items[list.items.len - 1] = ';';
    try testing.expect(list.items.len >= 12 * 1024);

    try list.append(testing.allocator, 0);
    const sql: [:0]const u8 = list.items[0 .. list.items.len - 1 :0];
    try tdb.db.exec(sql);
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
