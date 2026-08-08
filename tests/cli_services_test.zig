//! malt — cli/services dispatch tests
//! Drives the `mt services` subcommand router with MALT_PREFIX pointed at
//! a scratch directory. Covers describeError, printHelp, the unknown-subcommand
//! path, list/ls, status, and logs (missing-file fallback).

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");
const services_cli = malt.cli_services;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

fn setupPrefix(suffix: []const u8) ![:0]u8 {
    const base = try test_io.uniqueTempPath(testing.allocator, "cli_services", suffix);
    defer testing.allocator.free(base);
    const path = try testing.allocator.dupeZ(u8, base);
    test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, path);
    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{path});
    defer testing.allocator.free(db_dir);
    try test_io.makeDirAbsolute(std.Options.debug_io, db_dir);
    _ = c.setenv("MALT_PREFIX", path.ptr, 1);
    return path;
}

test "describeError returns a distinct message for every ServicesError tag" {
    const a = services_cli.describeError(error.InvalidArgs);
    const b = services_cli.describeError(error.DatabaseError);
    const d = services_cli.describeError(error.SupervisorError);
    try testing.expect(a.len > 0 and b.len > 0 and d.len > 0);
    try testing.expect(!std.mem.eql(u8, a, b));
    try testing.expect(!std.mem.eql(u8, b, d));
}

test "execute with no args prints help" {
    defer _ = c.unsetenv("MALT_PREFIX");
    _ = c.setenv("MALT_PREFIX", "/tmp/malt_cli_services_help_noargs", 1);
    try services_cli.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{});
}

test "execute with -h / --help prints help" {
    defer _ = c.unsetenv("MALT_PREFIX");
    _ = c.setenv("MALT_PREFIX", "/tmp/malt_cli_services_help_flag", 1);
    try services_cli.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"-h"});
    try services_cli.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--help"});
}

test "execute list on an empty prefix reports no services" {
    const prefix = try setupPrefix("list_empty");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try services_cli.execute(&ctx, testing.allocator, &.{"list"});
    try services_cli.execute(&ctx, testing.allocator, &.{"ls"});
    // status with no name falls back to the list path.
    try services_cli.execute(&ctx, testing.allocator, &.{"status"});
}

test "execute with an unknown subcommand returns InvalidArgs" {
    const prefix = try setupPrefix("unknown");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try testing.expectError(
        error.InvalidArgs,
        services_cli.execute(&ctx, testing.allocator, &.{"flarble"}),
    );
}

test "execute status with a non-existent service returns SupervisorError" {
    const prefix = try setupPrefix("status_missing");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try testing.expectError(
        error.SupervisorError,
        services_cli.execute(&ctx, testing.allocator, &.{ "status", "nope" }),
    );
}

test "execute start/stop/restart with wrong arity returns InvalidArgs" {
    const prefix = try setupPrefix("lifecycle_argv");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    for ([_][]const u8{ "start", "stop", "restart" }) |op| {
        try testing.expectError(
            error.InvalidArgs,
            services_cli.execute(&ctx, testing.allocator, &.{op}),
        );
    }
}

test "execute list --json on a prefix with no db/ directory emits `[]`" {
    // `openDb` auto-creates `db/` and the sqlite file. CI consumers piping
    // through `jq` need a parseable empty array on first run.
    const base = try test_io.uniqueTempPath(testing.allocator, "cli_services", "fresh_no_db");
    defer testing.allocator.free(base);
    const path = try testing.allocator.dupeZ(u8, base);
    defer testing.allocator.free(path);
    test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    _ = c.setenv("MALT_PREFIX", path, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    const prior_json = malt.output.isJson();
    malt.output.setMode(.json);
    defer malt.output.setMode(if (prior_json) .json else .human);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    malt.output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer malt.output.endStdoutCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try services_cli.execute(&ctx, testing.allocator, &.{"list"});
    try testing.expectEqualStrings("{\"schema_version\":1,\"services\":[]}\n", stdout_buf.items);
}

test "execute list --json on an empty DB emits `[]`" {
    const prefix = try setupPrefix("list_empty_json");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    const prior_json = malt.output.isJson();
    malt.output.setMode(.json);
    defer malt.output.setMode(if (prior_json) .json else .human);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    malt.output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer malt.output.endStdoutCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try services_cli.execute(&ctx, testing.allocator, &.{"list"});
    try testing.expectEqualStrings("{\"schema_version\":1,\"services\":[]}\n", stdout_buf.items);

    // `status` with no name routes through cmdList; under --json it must
    // emit the same empty array so consumers can rely on a single shape.
    stdout_buf.clearRetainingCapacity();
    try services_cli.execute(&ctx, testing.allocator, &.{"status"});
    try testing.expectEqualStrings("{\"schema_version\":1,\"services\":[]}\n", stdout_buf.items);
}

fn seedService(prefix: []const u8, name: []const u8, keg: []const u8, auto_start: bool) !void {
    var path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try malt.sqlite.Database.open(db_path);
    defer db.close();
    try malt.schema.initSchema(&db);

    var stmt = try db.prepare(
        \\INSERT INTO services(name, keg_name, plist_path, auto_start, last_status)
        \\VALUES (?, ?, '/dev/null', ?, 'registered');
    );
    defer stmt.finalize();
    try stmt.bindText(1, name);
    try stmt.bindText(2, keg);
    try stmt.bindInt(3, if (auto_start) 1 else 0);
    _ = try stmt.step();
}

fn seedScheduledService(prefix: []const u8, name: []const u8, keg: []const u8, schedule: []const u8) !void {
    var path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try malt.sqlite.Database.open(db_path);
    defer db.close();
    try malt.schema.initSchema(&db);

    var stmt = try db.prepare(
        \\INSERT INTO services(name, keg_name, plist_path, auto_start, last_status, schedule)
        \\VALUES (?, ?, '/dev/null', 0, 'registered', ?);
    );
    defer stmt.finalize();
    try stmt.bindText(1, name);
    try stmt.bindText(2, keg);
    try stmt.bindText(3, schedule);
    _ = try stmt.step();
}

test "execute list (human) shows the schedule label" {
    const prefix = try setupPrefix("list_schedule_human");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");
    try seedScheduledService(prefix, "backup", "backup", "interval 60s");

    const prior_json = malt.output.isJson();
    malt.output.setMode(.human);
    defer malt.output.setMode(if (prior_json) .json else .human);

    // The human table prints to stderr; stdout is reserved for --json.
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &stderr_buf);
    defer malt.output.endStderrCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try services_cli.execute(&ctx, testing.allocator, &.{"list"});

    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "interval 60s") != null);
}

test "execute list --json surfaces the schedule label end-to-end" {
    const prefix = try setupPrefix("list_schedule_json");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");
    try seedScheduledService(prefix, "backup", "backup", "interval 60s");

    const prior_json = malt.output.isJson();
    malt.output.setMode(.json);
    defer malt.output.setMode(if (prior_json) .json else .human);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    malt.output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer malt.output.endStdoutCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try services_cli.execute(&ctx, testing.allocator, &.{"list"});

    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"schedule\":\"interval 60s\"") != null);
}

test "execute list --json on a populated DB emits one object per row" {
    const prefix = try setupPrefix("list_populated_json");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");
    try seedService(prefix, "redis", "redis", true);
    try seedService(prefix, "postgres", "postgresql@16", false);

    const prior_json = malt.output.isJson();
    malt.output.setMode(.json);
    defer malt.output.setMode(if (prior_json) .json else .human);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    malt.output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer malt.output.endStdoutCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try services_cli.execute(&ctx, testing.allocator, &.{"list"});

    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"name\":\"redis\"") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"keg_name\":\"redis\"") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"auto_start\":true") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"name\":\"postgres\"") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"keg_name\":\"postgresql@16\"") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"auto_start\":false") != null);
    // Runtime probe is best-effort on non-macOS / when launchctl misses;
    // it still must surface a textual state, never a numeric code.
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"state\":\"") != null);
    try testing.expect(std.mem.startsWith(u8, stdout_buf.items, "{\"schema_version\":1,\"services\":["));
    try testing.expect(std.mem.endsWith(u8, stdout_buf.items, "]}\n"));
}

test "execute list --json output is a parseable versioned JSON object" {
    const prefix = try setupPrefix("list_json_parse");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");
    try seedService(prefix, "redis", "redis", true);

    const prior_json = malt.output.isJson();
    malt.output.setMode(.json);
    defer malt.output.setMode(if (prior_json) .json else .human);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    malt.output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer malt.output.endStdoutCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try services_cli.execute(&ctx, testing.allocator, &.{"list"});

    const trimmed = std.mem.trim(u8, stdout_buf.items, " \t\r\n");
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, trimmed, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("schema_version").?.integer);
    const services = parsed.value.object.get("services").?.array;
    try testing.expectEqual(@as(usize, 1), services.items.len);
    const row = services.items[0].object;
    try testing.expectEqualStrings("redis", row.get("name").?.string);
    try testing.expectEqualStrings("redis", row.get("keg_name").?.string);
    try testing.expectEqual(true, row.get("auto_start").?.bool);
    // `state` is whatever launchctl reports — must be a string, not int.
    try testing.expect(row.get("state").? == .string);
}

test "execute status <name> --json emits a single-element array" {
    const prefix = try setupPrefix("status_populated_json");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");
    try seedService(prefix, "redis", "redis", true);

    const prior_json = malt.output.isJson();
    malt.output.setMode(.json);
    defer malt.output.setMode(if (prior_json) .json else .human);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    malt.output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer malt.output.endStdoutCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try services_cli.execute(&ctx, testing.allocator, &.{ "status", "redis" });

    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"name\":\"redis\"") != null);
    // Only one row in the array — pin the bracketing so `postgres` (not
    // seeded here) can't sneak in via a typo in the filter SQL.
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "postgres") == null);
    try testing.expect(std.mem.startsWith(u8, stdout_buf.items, "{\"schema_version\":1,\"services\":[{"));
    try testing.expect(std.mem.endsWith(u8, stdout_buf.items, "}]}\n"));
}

test "execute status <missing> --json still surfaces SupervisorError" {
    const prefix = try setupPrefix("status_missing_json");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    const prior_json = malt.output.isJson();
    malt.output.setMode(.json);
    defer malt.output.setMode(if (prior_json) .json else .human);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try testing.expectError(
        error.SupervisorError,
        services_cli.execute(&ctx, testing.allocator, &.{ "status", "nope" }),
    );
}

test "execute logs with no args returns InvalidArgs" {
    const prefix = try setupPrefix("logs_noargs");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try testing.expectError(
        error.InvalidArgs,
        services_cli.execute(&ctx, testing.allocator, &.{"logs"}),
    );
}

// NOTE: cmdLogs writes to stdout, which deadlocks the zig-test-runner listen
// protocol. The happy path (finding and tailing the log file) is covered by
// the supervisor_pure_test suite via a direct tailLog call; here we limit the
// CLI-level coverage to the error branches that never reach stdout.

test "writeServicesJson: an errored row serialises as state \"errored\" without a schema bump" {
    // Contract pin: `errored` reaches the JSON surface as a plain state value,
    // not a new field, so `schema_version` stays 1. State is sourced from the
    // enum so the byte contract tracks any rename of the variant.
    const errored = malt.services_supervisor.runtimeStateName(.errored);
    const rows = [_]services_cli.JsonRow{
        .{ .name = "redis", .state = errored, .auto_start = true, .keg_name = "redis", .schedule = "" },
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try services_cli.writeServicesJson(&aw.writer, &rows);
    try testing.expectEqualStrings(
        "{\"schema_version\":1,\"services\":[" ++
            "{\"name\":\"redis\",\"state\":\"errored\",\"auto_start\":true,\"keg_name\":\"redis\",\"schedule\":\"\"}" ++
            "]}\n",
        aw.written(),
    );
}

test "execute status by keg name emits the row registered under its launchd label" {
    // Every other verb takes the formula name, so `services status mosquitto`
    // must find `com.malt.mosquitto`. `hasService` already accepted the keg
    // name, so this used to pass that gate and then filter the row back out.
    const prefix = try setupPrefix("status_by_keg");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");
    try seedService(prefix, "com.malt.mosquitto", "mosquitto", false);

    const prior_json = malt.output.isJson();
    malt.output.setMode(.json);
    defer malt.output.setMode(if (prior_json) .json else .human);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    malt.output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer malt.output.endStdoutCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try services_cli.execute(&ctx, testing.allocator, &.{ "status", "mosquitto" });

    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"name\":\"com.malt.mosquitto\"") != null);
    try testing.expect(std.mem.endsWith(u8, stdout_buf.items, "}]}\n"));
}

test "execute logs by keg name reads the log under the launchd label" {
    // Log dirs are named by the label, so an unresolved keg name pointed at a
    // path nothing ever creates.
    const prefix = try setupPrefix("logs_by_keg");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");
    try seedService(prefix, "com.malt.mosquitto", "mosquitto", false);

    var dir_buf: [512]u8 = undefined;
    const log_dir = try std.fmt.bufPrintSentinel(&dir_buf, "{s}/var/malt/services/com.malt.mosquitto", .{prefix}, 0);
    try test_io.cwd().createDirPath(std.Options.debug_io, log_dir);
    var log_buf: [512]u8 = undefined;
    const log_path = try std.fmt.bufPrintSentinel(&log_buf, "{s}/stdout.log", .{log_dir}, 0);
    {
        const f = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, log_path, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "MOSQUITTO-LOG-LINE\n");
    }

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // `cmdLogs` writes straight to `ctx.stdout`, which defaults to a closed
    // handle so a test cannot reach the runner's fd 1.
    var out_buf: [512]u8 = undefined;
    const out_path = try std.fmt.bufPrintSentinel(&out_buf, "{s}/captured.out", .{prefix}, 0);
    const out_file = try std.Io.Dir.createFileAbsolute(io, out_path, .{ .truncate = true });
    const ctx: malt.app_ctx.AppCtx = .{ .io = io, .environ = .empty, .stdout = out_file };
    try services_cli.execute(&ctx, testing.allocator, &.{ "logs", "mosquitto" });
    out_file.close(io);

    const f = try std.Io.Dir.openFileAbsolute(io, out_path, .{});
    defer f.close(io);
    var read_buf: [512]u8 = undefined;
    const n = try f.readPositionalAll(io, &read_buf, 0);
    try testing.expect(std.mem.indexOf(u8, read_buf[0..n], "MOSQUITTO-LOG-LINE") != null);
}

test "execute status refuses to guess when one formula registers two services" {
    // Resolution happens after `hasService`, so the ambiguity has to surface
    // rather than the first row winning silently.
    const prefix = try setupPrefix("status_ambiguous");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");
    try seedService(prefix, "com.malt.pg.main", "postgresql@16", false);
    try seedService(prefix, "com.malt.pg.repl", "postgresql@16", false);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try testing.expectError(
        error.AmbiguousService,
        services_cli.execute(&ctx, testing.allocator, &.{ "status", "postgresql@16" }),
    );
}
