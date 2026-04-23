//! malt — services CLI / supervisor smoke tests
//!
//! Tests exercise the DB-backed pieces: list/status/registration. The actual
//! launchctl bootstrap path is not exercised here because it needs a
//! per-user launchd domain that is unsafe to touch from CI.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const sqlite = malt.sqlite;
const schema = malt.schema;
const supervisor = malt.services_supervisor;

const TempDb = struct {
    dir: []const u8,
    db: sqlite.Database,

    fn init(comptime tag: []const u8) !TempDb {
        const dir = "/tmp/malt_services_test_" ++ tag;
        malt.fs_compat.deleteTreeAbsolute(dir) catch {};
        try malt.fs_compat.makeDirAbsolute(dir);
        var db_path_buf: [256]u8 = undefined;
        const db_path = try std.fmt.bufPrint(&db_path_buf, "{s}/test.db", .{dir});
        var db = try sqlite.Database.open(db_path);
        errdefer db.close();
        try schema.initSchema(&db);
        return .{ .dir = dir, .db = db };
    }

    fn deinit(self: *TempDb) void {
        self.db.close();
        malt.fs_compat.deleteTreeAbsolute(self.dir) catch {};
    }
};

test "list returns empty initially" {
    var t = try TempDb.init("empty");
    defer t.deinit();

    const items = try supervisor.list(.{ .allocator = testing.allocator, .db = &t.db });
    defer supervisor.freeServiceInfos(testing.allocator, items);
    try testing.expectEqual(@as(usize, 0), items.len);
}

test "raw services row insert is reflected by list and hasService" {
    var t = try TempDb.init("insert");
    defer t.deinit();

    try t.db.exec(
        \\INSERT INTO services(name, keg_name, plist_path, auto_start, last_status)
        \\VALUES ('redis', 'redis', '/tmp/redis.plist', 1, 'registered');
    );

    try testing.expect(supervisor.hasService(&t.db, "redis"));
    try testing.expect(!supervisor.hasService(&t.db, "missing"));

    const items = try supervisor.list(.{ .allocator = testing.allocator, .db = &t.db });
    defer supervisor.freeServiceInfos(testing.allocator, items);
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("redis", items[0].name);
    try testing.expect(items[0].auto_start);
}

fn listAndFree(alloc: std.mem.Allocator, db: *sqlite.Database) !void {
    const items = try supervisor.list(.{ .allocator = alloc, .db = db });
    supervisor.freeServiceInfos(alloc, items);
}

test "list: partial-dupe failure on any allocation leaves zero leaks" {
    // BUG-010 regression guard: earlier row dupes used to leak when a later
    // dupe or append failed, and already-populated rows were never walked.
    var t = try TempDb.init("partial_dupe");
    defer t.deinit();

    // Two rows so the errdefer has to walk both completed and partial state.
    try t.db.exec(
        \\INSERT INTO services(name, keg_name, plist_path, auto_start, last_status)
        \\VALUES ('alpha', 'alpha-keg', '/tmp/a.plist', 1, 'registered');
    );
    try t.db.exec(
        \\INSERT INTO services(name, keg_name, plist_path, auto_start, last_status)
        \\VALUES ('beta', 'beta-keg', '/tmp/b.plist', 0, 'stopped');
    );

    try testing.checkAllAllocationFailures(testing.allocator, listAndFree, .{&t.db});
}

test "tailLog returns last N lines of a small file" {
    var t = try TempDb.init("tail");
    defer t.deinit();

    const log_path = "/tmp/malt_services_test_tail/sample.log";
    {
        var f = try malt.fs_compat.createFileAbsolute(log_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("alpha\nbeta\ngamma\ndelta\nepsilon\n");
    }

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try supervisor.tailLog(testing.allocator, log_path, 2, &aw.writer);

    try testing.expectEqualStrings("delta\nepsilon\n", aw.written());
}
