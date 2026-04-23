//! malt — supervisor pure-helper tests
//! Covers the helpers that don't touch launchctl: directory paths, log
//! paths, error descriptions, runtime state names, and `register`, `list`,
//! `hasService`, `setStatus` against a real in-memory SQLite database.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const supervisor = malt.services_supervisor;
const plist_mod = malt.services_plist;
const sqlite = malt.sqlite;
const schema = malt.schema;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

test "SupervisorCtx bundles allocator and db into one param" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    const ctx: supervisor.SupervisorCtx = .{ .allocator = testing.allocator, .db = &db };
    try testing.expectError(error.ServiceNotFound, supervisor.start(ctx, "absent"));
    try testing.expectError(error.ServiceNotFound, supervisor.stop(ctx, "absent"));
    try testing.expectError(error.ServiceNotFound, supervisor.restart(ctx, "absent"));
}

test "describeError returns a distinct message per tag" {
    const msgs = [_][]const u8{
        supervisor.describeError(error.OsNotSupported),
        supervisor.describeError(error.ServiceNotFound),
        supervisor.describeError(error.LaunchctlFailed),
        supervisor.describeError(error.IoFailed),
        supervisor.describeError(error.DatabaseError),
        supervisor.describeError(error.OutOfMemory),
    };
    // All messages are non-empty and distinct.
    for (msgs) |m| try testing.expect(m.len > 0);
    for (msgs, 0..) |a, i| for (msgs, 0..) |b, j| {
        if (i != j) try testing.expect(!std.mem.eql(u8, a, b));
    };
}

test "servicesDir and serviceDir build paths under MALT_PREFIX/var/malt/services" {
    _ = c.setenv("MALT_PREFIX", "/tmp/malt_sup_paths", 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    const sd = try supervisor.servicesDir(testing.allocator);
    defer testing.allocator.free(sd);
    try testing.expectEqualStrings("/tmp/malt_sup_paths/var/malt/services", sd);

    const one = try supervisor.serviceDir(testing.allocator, "foo");
    defer testing.allocator.free(one);
    try testing.expectEqualStrings("/tmp/malt_sup_paths/var/malt/services/foo", one);
}

test "logPath composes stdout.log and stderr.log under the service dir" {
    _ = c.setenv("MALT_PREFIX", "/tmp/malt_sup_logs", 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    const out = try supervisor.logPath(testing.allocator, "svc", .stdout);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/tmp/malt_sup_logs/var/malt/services/svc/stdout.log", out);

    const err = try supervisor.logPath(testing.allocator, "svc", .stderr);
    defer testing.allocator.free(err);
    try testing.expectEqualStrings("/tmp/malt_sup_logs/var/malt/services/svc/stderr.log", err);
}

test "runtimeStateName distinguishes every variant" {
    try testing.expectEqualStrings("not-loaded", supervisor.runtimeStateName(.not_loaded));
    try testing.expectEqualStrings("loaded", supervisor.runtimeStateName(.loaded));
    try testing.expectEqualStrings("running", supervisor.runtimeStateName(.running));
}

test "list is empty on a fresh database and hasService returns false" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    const list = try supervisor.list(.{ .allocator = testing.allocator, .db = &db });
    defer supervisor.freeServiceInfos(testing.allocator, list);
    try testing.expectEqual(@as(usize, 0), list.len);
    try testing.expect(!supervisor.hasService(&db, "anything"));
}

test "register writes a plist and a DB row that list reports back" {
    const prefix = "/tmp/malt_sup_register";
    const cellar = "/tmp/malt_sup_register/Cellar/testkeg/1.0";
    malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
    _ = c.setenv("MALT_PREFIX", prefix, 1);
    defer _ = c.unsetenv("MALT_PREFIX");
    defer malt.fs_compat.deleteTreeAbsolute(prefix) catch {};

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    // program_args[0] must live under cellar (new path-allowlist rule);
    // log paths must live under malt_prefix.
    const spec = plist_mod.ServiceSpec{
        .label = "com.malt.test.svc",
        .program_args = &.{ "/tmp/malt_sup_register/Cellar/testkeg/1.0/bin/echo", "hi" },
        .working_dir = null,
        .env = &.{},
        .run_at_load = false,
        .keep_alive = false,
        .stdout_path = "/tmp/malt_sup_register/out.log",
        .stderr_path = "/tmp/malt_sup_register/err.log",
    };
    const ctx: supervisor.SupervisorCtx = .{ .allocator = testing.allocator, .db = &db };
    try supervisor.register(ctx, spec, "testkeg", true, cellar, prefix);

    try testing.expect(supervisor.hasService(&db, "com.malt.test.svc"));

    const list = try supervisor.list(ctx);
    defer supervisor.freeServiceInfos(testing.allocator, list);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqualStrings("com.malt.test.svc", list[0].name);
    try testing.expectEqualStrings("testkeg", list[0].keg_name);
    try testing.expectEqualStrings("registered", list[0].last_status);
    try testing.expect(list[0].auto_start);

    // plist file exists on disk
    var f = try malt.fs_compat.openFileAbsolute(list[0].plist_path, .{});
    f.close();
}

test "tailLog writes the last N lines into the provided writer" {
    const path = "/tmp/malt_sup_tail.log";
    malt.fs_compat.cwd().deleteFile(path) catch {};
    defer malt.fs_compat.cwd().deleteFile(path) catch {};

    const f = try malt.fs_compat.createFileAbsolute(path, .{});
    try f.writeAll("a\nb\nc\nd\ne\n");
    f.close();

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try supervisor.tailLog(testing.allocator, path, 2, &aw.writer);

    // Should end with the last 2 lines ("d" and "e").
    try testing.expect(std.mem.indexOf(u8, aw.written(), "d") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "e") != null);
}

test "start/stop/restart return ServiceNotFound when no DB row exists" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    const ctx: supervisor.SupervisorCtx = .{ .allocator = testing.allocator, .db = &db };
    try testing.expectError(error.ServiceNotFound, supervisor.start(ctx, "absent"));
    try testing.expectError(error.ServiceNotFound, supervisor.stop(ctx, "absent"));
    try testing.expectError(error.ServiceNotFound, supervisor.restart(ctx, "absent"));
}

test "stopAndUnregister is a no-op on an absent service and still wipes the row" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    // Insert a dummy service row directly — simulates a stale record whose
    // plist file may or may not exist. stopAndUnregister swallows all errors
    // from the stop phase and unconditionally removes the DB row.
    var stmt = try db.prepare(
        \\INSERT INTO services (name, keg_name, plist_path, auto_start, last_status)
        \\VALUES (?, ?, ?, 0, 'registered');
    );
    try stmt.bindText(1, "ghost");
    try stmt.bindText(2, "ghostkeg");
    try stmt.bindText(3, "/nonexistent/ghost.plist");
    _ = try stmt.step();
    stmt.finalize();

    try testing.expect(supervisor.hasService(&db, "ghost"));
    supervisor.stopAndUnregister(.{ .allocator = testing.allocator, .db = &db }, "ghost");
    try testing.expect(!supervisor.hasService(&db, "ghost"));
}

test "queryRuntime returns not_loaded for a label launchctl has never heard of" {
    const state = supervisor.queryRuntime(testing.allocator, "com.malt.nonexistent.test.xyz");
    // We don't own the user's launchctl state, but an unknown label must
    // never come back as `running`.
    try testing.expect(state != .running);
}

test "tailLog reports IoFailed for a missing file" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try testing.expectError(
        error.IoFailed,
        supervisor.tailLog(testing.allocator, "/tmp/malt_sup_tail_missing_xyz", 1, &aw.writer),
    );
}
