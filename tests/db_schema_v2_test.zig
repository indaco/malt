//! malt — schema v2 migration tests

const std = @import("std");
const testing = std.testing;

const malt = @import("malt");
const sqlite = malt.sqlite;
const schema = malt.schema;
const test_io = @import("test_io");

/// Scratch DB under a process-unique dir, so overlapping test runs cannot
/// wipe each other's fixtures.
const TempDb = struct {
    arena: std.heap.ArenaAllocator,
    dir: []const u8,
    db: sqlite.Database,

    fn init(tag: []const u8) !TempDb {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const dir = try test_io.uniqueTempPath(arena.allocator(), "schema_v2", tag);
        test_io.deleteTreeAbsolute(std.Options.debug_io, dir) catch {};
        try test_io.makeDirAbsolute(std.Options.debug_io, dir);
        var db_path_buf: [256]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/test.db", .{dir}, 0);
        var db = try sqlite.Database.open(db_path);
        errdefer db.close();
        return .{ .arena = arena, .dir = dir, .db = db };
    }

    fn deinit(self: *TempDb) void {
        self.db.close();
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.dir) catch {};
        self.arena.deinit();
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

test "initSchema runs v1 then migrates to the current known version" {
    var tdb = try TempDb.init("init");
    defer tdb.deinit();

    try schema.initSchema(&tdb.db);

    try testing.expect(try tableExists(&tdb.db, "kegs"));
    try testing.expect(try tableExists(&tdb.db, "services"));
    try testing.expect(try tableExists(&tdb.db, "bundles"));
    try testing.expect(try tableExists(&tdb.db, "bundle_members"));

    const ver = try schema.currentVersion(&tdb.db);
    try testing.expectEqual(schema.known_schema_version, ver);
}

test "migrate is idempotent on re-run" {
    var tdb = try TempDb.init("idempotent");
    defer tdb.deinit();

    try schema.initSchema(&tdb.db);
    try schema.migrate(&tdb.db);
    try schema.migrate(&tdb.db);

    const ver = try schema.currentVersion(&tdb.db);
    try testing.expectEqual(schema.known_schema_version, ver);
}

test "v4 migration adds pinned column to casks" {
    var tdb = try TempDb.init("v4_casks_pinned");
    defer tdb.deinit();

    try schema.initSchema(&tdb.db);

    // INSERT exercising the new column proves the ALTER landed.
    try tdb.db.exec(
        \\INSERT INTO casks(token, name, version, url, pinned)
        \\VALUES ('firefox', 'firefox', '120.0', 'https://example.invalid', 1);
    );

    var stmt = try tdb.db.prepare("SELECT pinned FROM casks WHERE token='firefox';");
    defer stmt.finalize();
    _ = try stmt.step();
    try testing.expectEqual(@as(i64, 1), stmt.columnInt(0));
}

test "v4 migration is idempotent on re-run" {
    var tdb = try TempDb.init("v4_idempotent");
    defer tdb.deinit();

    try schema.initSchema(&tdb.db);
    try schema.migrate(&tdb.db);
    try schema.migrate(&tdb.db);

    const ver = try schema.currentVersion(&tdb.db);
    try testing.expectEqual(schema.known_schema_version, ver);
}

test "v6 migration adds tap column to casks" {
    var tdb = try TempDb.init("v6_casks_tap");
    defer tdb.deinit();

    try schema.initSchema(&tdb.db);

    // INSERT exercising the new column proves the ALTER landed.
    try tdb.db.exec(
        \\INSERT INTO casks(token, name, version, url, tap)
        \\VALUES ('flux-markdown', 'flux-markdown', '0.1.0',
        \\        'https://example.invalid/flux.dmg', 'xykong/tap');
    );

    var stmt = try tdb.db.prepare("SELECT tap FROM casks WHERE token='flux-markdown';");
    defer stmt.finalize();
    _ = try stmt.step();
    const raw = stmt.columnText(0) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("xykong/tap", std.mem.sliceTo(raw, 0));
}

test "v6 migration leaves legacy casks with tap NULL" {
    var tdb = try TempDb.init("v6_legacy_null");
    defer tdb.deinit();

    // Apply schema then reset version + drop column to simulate a v5 DB.
    try schema.initSchema(&tdb.db);
    try tdb.db.exec("DELETE FROM schema_version WHERE version >= 6;");

    // Seed a row in v5-shape (no tap column awareness).
    try tdb.db.exec(
        \\INSERT INTO casks(token, name, version, url)
        \\VALUES ('firefox', 'firefox', '123.0', 'https://example.invalid');
    );

    // Re-run migrate — should detect "still need v6" and re-apply
    // idempotently without breaking the row.
    try schema.migrate(&tdb.db);

    var stmt = try tdb.db.prepare("SELECT tap FROM casks WHERE token='firefox';");
    defer stmt.finalize();
    _ = try stmt.step();
    try testing.expect(stmt.columnText(0) == null);
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

test "v14 leaves one identity per tap across taps, kegs and casks" {
    // Whole-registry view the per-table unit tests cannot give: three
    // spellings of one tap, spread over three tables, must join again
    // after the repair.
    var t = try TempDb.init("v14_identity");
    defer t.deinit();
    try schema.initSchema(&t.db);

    try t.db.exec(
        \\INSERT INTO taps (name, url, commit_sha, github_owner, github_repo) VALUES
        \\  ('Indaco/Homebrew-Tap', 'https://github.com/Indaco/homebrew-Homebrew-Tap', NULL,
        \\   'Indaco', 'homebrew-Homebrew-Tap'),
        \\  ('indaco/tap', 'https://github.com/indaco/homebrew-tap', 'abc123', 'indaco', 'homebrew-tap');
    );
    try t.db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, tap) VALUES
        \\  ('a', 'Indaco/Homebrew-Tap/a', '1.0', 'sha-a', '/c/a/1.0', 'Indaco/Homebrew-Tap'),
        \\  ('b', 'indaco/tap/b',          '2.0', 'sha-b', '/c/b/2.0', 'indaco/tap');
    );
    try t.db.exec(
        \\INSERT INTO casks (token, name, version, url, tap)
        \\VALUES ('c', 'C', '3.0', 'https://x/c.zip', 'INDACO/linuxbrew-tap');
    );

    try t.db.exec("DELETE FROM schema_version WHERE version >= 14;");
    try schema.migrate(&t.db);

    // One surviving tap row, and it is the one carrying the real pin.
    var taps = try t.db.prepare("SELECT name, commit_sha FROM taps;");
    defer taps.finalize();
    try testing.expect(try taps.step());
    try testing.expectEqualStrings("indaco/tap", std.mem.sliceTo(taps.columnText(0).?, 0));
    try testing.expectEqualStrings("abc123", std.mem.sliceTo(taps.columnText(1).?, 0));
    try testing.expect(!try taps.step());

    // Every keg and cask now points at that one row.
    var joined = try t.db.prepare(
        \\SELECT COUNT(*) FROM (
        \\  SELECT tap FROM kegs UNION ALL SELECT tap FROM casks
        \\) WHERE tap = 'indaco/tap';
    );
    defer joined.finalize();
    try testing.expect(try joined.step());
    try testing.expectEqual(@as(i64, 3), joined.columnInt(0));

    var full = try t.db.prepare("SELECT full_name FROM kegs WHERE name='a';");
    defer full.finalize();
    try testing.expect(try full.step());
    try testing.expectEqualStrings("indaco/tap/a", std.mem.sliceTo(full.columnText(0).?, 0));
}
