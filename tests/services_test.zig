//! malt — services CLI / supervisor smoke tests
//!
//! Tests exercise the DB-backed pieces: list/status/registration. The actual
//! launchctl bootstrap path is not exercised here because it needs a
//! per-user launchd domain that is unsafe to touch from CI.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");
const sqlite = malt.sqlite;
const schema = malt.schema;
const supervisor = malt.services_supervisor;

/// Scratch DB under a process-unique base, so overlapping test runs cannot
/// wipe each other's fixtures.
const TempDb = struct {
    arena: std.heap.ArenaAllocator,
    dir: [:0]const u8,
    db: sqlite.Database,

    fn init(tag: []const u8) !TempDb {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const base = try test_io.uniqueTempPath(arena.allocator(), "services", tag);
        const dir = try arena.allocator().dupeZ(u8, base);
        test_io.deleteTreeAbsolute(std.Options.debug_io, dir) catch {};
        try test_io.makeDirAbsolute(std.Options.debug_io, dir);
        var db_path_buf: [256]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/test.db", .{dir}, 0);
        var db = try sqlite.Database.open(db_path);
        errdefer db.close();
        try schema.initSchema(&db);
        return .{ .arena = arena, .dir = dir, .db = db };
    }

    /// Absolute path to `sub` inside the scratch dir; valid until `deinit`.
    fn p(self: *TempDb, sub: []const u8) [:0]const u8 {
        return std.fmt.allocPrintSentinel(
            self.arena.allocator(),
            "{s}/{s}",
            .{ self.dir, sub },
            0,
        ) catch @panic("OOM");
    }

    fn deinit(self: *TempDb) void {
        self.db.close();
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.dir) catch {};
        self.arena.deinit();
    }
};

test "list returns empty initially" {
    var t = try TempDb.init("empty");
    defer t.deinit();

    const items = try supervisor.list(.{ .allocator = testing.allocator, .io = std.Options.debug_io, .db = &t.db });
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

    const items = try supervisor.list(.{ .allocator = testing.allocator, .io = std.Options.debug_io, .db = &t.db });
    defer supervisor.freeServiceInfos(testing.allocator, items);
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("redis", items[0].name);
    try testing.expect(items[0].auto_start);
}

fn listAndFree(alloc: std.mem.Allocator, db: *sqlite.Database) !void {
    const items = try supervisor.list(.{ .allocator = alloc, .io = std.Options.debug_io, .db = db });
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

    const log_path = t.p("sample.log");
    {
        var f = try test_io.createFileAbsolute(std.Options.debug_io, log_path, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "alpha\nbeta\ngamma\ndelta\nepsilon\n");
    }

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try supervisor.tailLog(std.Options.debug_io, testing.allocator, log_path, 2, &aw.writer);

    try testing.expectEqualStrings("delta\nepsilon\n", aw.written());
}

test "resolveLabel accepts the keg name a user would actually type" {
    // Services are registered under their launchd label while `keg_name` holds
    // the formula, so `services start mosquitto` used to fail with
    // ServiceNotFound on a service that `services list` was showing. Every
    // other verb takes the formula name.
    var t = try TempDb.init("resolve_keg");
    defer t.deinit();

    try t.db.exec(
        \\INSERT INTO services(name, keg_name, plist_path, auto_start, last_status)
        \\VALUES ('com.malt.mosquitto', 'mosquitto', '/tmp/m.plist', 0, 'registered');
    );

    const by_keg = try supervisor.resolveLabel(testing.allocator, &t.db, "mosquitto");
    defer testing.allocator.free(by_keg);
    try testing.expectEqualStrings("com.malt.mosquitto", by_keg);

    // The label itself keeps working, and still wins outright.
    const by_label = try supervisor.resolveLabel(testing.allocator, &t.db, "com.malt.mosquitto");
    defer testing.allocator.free(by_label);
    try testing.expectEqualStrings("com.malt.mosquitto", by_label);

    // `status` and `start` must agree on what exists.
    try testing.expect(supervisor.hasService(&t.db, "mosquitto"));
    try testing.expect(supervisor.hasService(&t.db, "com.malt.mosquitto"));

    try testing.expectError(
        error.ServiceNotFound,
        supervisor.resolveLabel(testing.allocator, &t.db, "nope"),
    );
}

test "resolveLabel prefers an exact label over a keg name that collides with it" {
    // Pathological but cheap to be correct about: if one service's label is
    // another's keg name, an exact request must not be reinterpreted.
    var t = try TempDb.init("resolve_collide");
    defer t.deinit();

    try t.db.exec(
        \\INSERT INTO services(name, keg_name, plist_path, auto_start, last_status)
        \\VALUES ('alpha', 'beta', '/tmp/a.plist', 0, 'registered'),
        \\       ('gamma', 'alpha', '/tmp/g.plist', 0, 'registered');
    );

    const got = try supervisor.resolveLabel(testing.allocator, &t.db, "alpha");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("alpha", got);
}

test "resolveLabel refuses to guess when one formula registers two services" {
    var t = try TempDb.init("resolve_ambiguous");
    defer t.deinit();

    try t.db.exec(
        \\INSERT INTO services(name, keg_name, plist_path, auto_start, last_status)
        \\VALUES ('com.malt.pg.main', 'postgresql@16', '/tmp/1.plist', 0, 'registered'),
        \\       ('com.malt.pg.repl', 'postgresql@16', '/tmp/2.plist', 0, 'registered');
    );

    try testing.expectError(
        error.AmbiguousService,
        supervisor.resolveLabel(testing.allocator, &t.db, "postgresql@16"),
    );
    // Naming one of them exactly still works.
    const exact = try supervisor.resolveLabel(testing.allocator, &t.db, "com.malt.pg.repl");
    defer testing.allocator.free(exact);
    try testing.expectEqualStrings("com.malt.pg.repl", exact);
}
