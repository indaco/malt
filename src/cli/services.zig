//! malt — services command

const std = @import("std");
const AppCtx = @import("../app_ctx.zig").AppCtx;
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const help_mod = @import("help.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const signals = @import("../core/signals.zig");
const supervisor = @import("../core/services/supervisor.zig");

pub const ServicesError = error{
    InvalidArgs,
    DatabaseError,
    SupervisorError,
};

/// One row in the `--json` listing; mirrors what the human path already
/// renders (`name`, runtime state, auto-start hint, owning keg). Kept
/// `pub` so tests can pin the exact bytes without staging a DB.
pub const JsonRow = struct {
    name: []const u8,
    state: []const u8,
    auto_start: bool,
    keg_name: []const u8,
    /// Schedule label ("interval 300s", "cron 30 4 * * 6"); "" for run-at-load.
    schedule: []const u8,
};

/// Emit `{"schema_version":1,"services":[{name,state,auto_start,keg_name},...]}\n`
/// for `mt services list --json` and `mt services status <name> --json`. The
/// object wrap gives the row array a root that can carry `schema_version`.
pub fn writeServicesJson(w: *std.Io.Writer, rows: []const JsonRow) !void {
    try output.writeSchemaVersionPrefix(w);
    try w.writeAll("\"services\":[");
    for (rows, 0..) |row, i| {
        if (i != 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try output.jsonStr(w, row.name);
        try w.writeAll(",\"state\":");
        try output.jsonStr(w, row.state);
        try w.writeAll(",\"auto_start\":");
        try w.writeAll(if (row.auto_start) "true" else "false");
        try w.writeAll(",\"keg_name\":");
        try output.jsonStr(w, row.keg_name);
        try w.writeAll(",\"schedule\":");
        try output.jsonStr(w, row.schedule);
        try w.writeAll("}");
    }
    try w.writeAll("]}\n");
}

pub fn describeError(err: ServicesError) []const u8 {
    return switch (err) {
        ServicesError.InvalidArgs => "invalid argument to `services`",
        ServicesError.DatabaseError => "database error",
        ServicesError.SupervisorError => "service supervisor error",
    };
}

/// Primitive entry point for core/bundle's dispatcher: start a single
/// service. Argv parsing stays in `execute`; this is the non-argv seam.
pub fn servicesStart(ctx: *const AppCtx, allocator: std.mem.Allocator, name: []const u8) !void {
    const argv = [_][]const u8{ "start", name };
    return execute(ctx, allocator, &argv);
}

pub fn execute(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        printHelp(ctx);
        return;
    }
    if (help_mod.showIfRequested(ctx, args[0..1], "services")) return;

    const sub = args[0];
    const rest = args[1..];

    var db = try openDb(ctx);
    defer db.close();
    // Schema is idempotent; subcommand queries surface the real error if the DB is broken.
    schema.initSchema(&db) catch {};

    if (std.mem.eql(u8, sub, "list") or std.mem.eql(u8, sub, "ls")) {
        return cmdList(ctx.io, allocator, &db);
    } else if (std.mem.eql(u8, sub, "start")) {
        return cmdOne(ctx.io, allocator, &db, rest, .start);
    } else if (std.mem.eql(u8, sub, "stop")) {
        return cmdOne(ctx.io, allocator, &db, rest, .stop);
    } else if (std.mem.eql(u8, sub, "restart")) {
        return cmdOne(ctx.io, allocator, &db, rest, .restart);
    } else if (std.mem.eql(u8, sub, "status")) {
        return cmdStatus(ctx.io, allocator, &db, rest);
    } else if (std.mem.eql(u8, sub, "logs")) {
        return cmdLogs(ctx, allocator, rest);
    }

    output.err("Unknown services subcommand: {s}", .{sub});
    return ServicesError.InvalidArgs;
}

const Lifecycle = enum { start, stop, restart };

fn cmdOne(io: std.Io, allocator: std.mem.Allocator, db: *sqlite.Database, rest: []const []const u8, op: Lifecycle) !void {
    if (rest.len != 1) {
        output.err("services {s}: expected a single service name", .{@tagName(op)});
        return ServicesError.InvalidArgs;
    }
    const name = rest[0];
    const ctx: supervisor.SupervisorCtx = .{ .allocator = allocator, .io = io, .db = db };
    switch (op) {
        .start => try supervisor.start(ctx, name),
        .stop => try supervisor.stop(ctx, name),
        .restart => try supervisor.restart(ctx, name),
    }
    output.success("services {s}: {s}", .{ @tagName(op), name });
}

fn cmdList(io: std.Io, allocator: std.mem.Allocator, db: *sqlite.Database) !void {
    const items = try supervisor.list(.{ .allocator = allocator, .io = io, .db = db });
    defer supervisor.freeServiceInfos(allocator, items);

    if (output.isJson()) return emitJson(io, allocator, items);

    if (items.len == 0) {
        output.info("no services registered", .{});
        return;
    }
    for (items) |s| {
        const runtime = supervisor.queryRuntime(io, allocator, s.name);
        const as: []const u8 = if (s.auto_start) "auto" else "manual";
        // Trailing schedule column; empty for run-at-load services.
        output.plain("{s}\t{s}\t{s}\t{s}\t{s}", .{
            s.name,
            supervisor.runtimeStateName(runtime),
            as,
            s.keg_name,
            s.schedule,
        });
    }
}

fn cmdStatus(io: std.Io, allocator: std.mem.Allocator, db: *sqlite.Database, rest: []const []const u8) !void {
    if (rest.len == 0) return cmdList(io, allocator, db);
    const name = rest[0];
    if (!supervisor.hasService(db, name)) {
        output.err("no such service: {s}", .{name});
        return ServicesError.SupervisorError;
    }
    // Rows and launchd are both keyed by the label; the user may have typed the
    // keg name, which every other verb accepts.
    const label = try supervisor.resolveLabel(allocator, db, name);
    defer allocator.free(label);
    if (output.isJson()) {
        // Reuse `supervisor.list` filtered down to `name`, so the JSON shape
        // matches `list --json` (single-element array, identical fields).
        const items = try supervisor.list(.{ .allocator = allocator, .io = io, .db = db });
        defer supervisor.freeServiceInfos(allocator, items);
        var picked: std.ArrayList(supervisor.ServiceInfo) = .empty;
        defer picked.deinit(allocator);
        for (items) |s| if (std.mem.eql(u8, s.name, label)) try picked.append(allocator, s);
        return emitJson(io, allocator, picked.items);
    }
    const runtime = supervisor.queryRuntime(io, allocator, label);
    output.info("service {s}: {s}", .{ label, supervisor.runtimeStateName(runtime) });
}

/// Render the supervisor's list of services as `--json`. Runtime state
/// is probed per row; `queryRuntime` returns `.not_loaded` on launchctl
/// errors so the field is always a textual tag, never a numeric code.
fn emitJson(io: std.Io, allocator: std.mem.Allocator, items: []const supervisor.ServiceInfo) !void {
    var rows: std.ArrayList(JsonRow) = .empty;
    defer rows.deinit(allocator);
    try rows.ensureTotalCapacityPrecise(allocator, items.len);
    for (items) |s| {
        const state = supervisor.runtimeStateName(supervisor.queryRuntime(io, allocator, s.name));
        rows.appendAssumeCapacity(.{
            .name = s.name,
            .state = state,
            .auto_start = s.auto_start,
            .keg_name = s.keg_name,
            .schedule = s.schedule,
        });
    }
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try writeServicesJson(&aw.writer, rows.items);
    output.writeStdoutAll(aw.written());
}

fn cmdLogs(ctx: *const AppCtx, allocator: std.mem.Allocator, rest: []const []const u8) !void {
    if (rest.len < 1) {
        output.err("services logs: expected service name", .{});
        return ServicesError.InvalidArgs;
    }
    const name = rest[0];
    var tail_n: usize = 50;
    var stream: enum { stdout, stderr } = .stdout;
    var follow = false;
    var i: usize = 1;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--tail") and i + 1 < rest.len) {
            i += 1;
            tail_n = std.fmt.parseInt(usize, rest[i], 10) catch 50;
        } else if (std.mem.eql(u8, a, "--stderr")) {
            stream = .stderr;
        } else if (std.mem.eql(u8, a, "--follow") or std.mem.eql(u8, a, "-f")) {
            follow = true;
        }
    }
    // Log dirs are named by the label, so resolve what the user typed first.
    var db = try openDb(ctx);
    defer db.close();
    const label = try supervisor.resolveLabel(allocator, &db, name);
    defer allocator.free(label);
    const path = try supervisor.logPath(allocator, label, if (stream == .stdout) .stdout else .stderr);
    defer allocator.free(path);
    const stdout = ctx.stdout;
    var write_buf: [4096]u8 = undefined;
    var stdout_writer = stdout.writer(ctx.io, &write_buf);
    const w = &stdout_writer.interface;
    if (follow) {
        try supervisor.followLog(ctx.io, allocator, path, tail_n, w, signals.isInterrupted);
    } else {
        try supervisor.tailLog(ctx.io, allocator, path, tail_n, w);
    }
    try w.flush();
}

fn openDb(ctx: *const AppCtx) !sqlite.Database {
    const prefix = atomic.maltPrefixOrAbort();
    var db_dir_buf: [512]u8 = undefined;
    const db_dir = std.fmt.bufPrint(&db_dir_buf, "{s}/db", .{prefix}) catch
        return ServicesError.DatabaseError;
    // db/ may already exist; sqlite.open below surfaces real path errors.
    std.Io.Dir.cwd().createDirPath(ctx.io, db_dir) catch {};
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/malt.db", .{db_dir}, 0) catch
        return ServicesError.DatabaseError;
    return sqlite.Database.open(path);
}

test "writeServicesJson: empty input still emits the versioned root with an empty array" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeServicesJson(&aw.writer, &.{});
    try std.testing.expectEqualStrings("{\"schema_version\":1,\"services\":[]}\n", aw.written());
}

test "writeServicesJson: emits name, state, auto_start, keg_name per row under the versioned root" {
    const rows = [_]JsonRow{
        .{ .name = "redis", .state = "running", .auto_start = true, .keg_name = "redis", .schedule = "" },
        .{ .name = "postgres", .state = "not-loaded", .auto_start = false, .keg_name = "postgresql@16", .schedule = "" },
    };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeServicesJson(&aw.writer, &rows);
    try std.testing.expectEqualStrings(
        "{\"schema_version\":1,\"services\":[" ++
            "{\"name\":\"redis\",\"state\":\"running\",\"auto_start\":true,\"keg_name\":\"redis\",\"schedule\":\"\"}," ++
            "{\"name\":\"postgres\",\"state\":\"not-loaded\",\"auto_start\":false,\"keg_name\":\"postgresql@16\",\"schedule\":\"\"}" ++
            "]}\n",
        aw.written(),
    );
}

test "writeServicesJson: emits the schedule label as a trailing field per row" {
    const rows = [_]JsonRow{
        .{ .name = "redis", .state = "running", .auto_start = true, .keg_name = "redis", .schedule = "interval 300s" },
        .{ .name = "postgres", .state = "not-loaded", .auto_start = false, .keg_name = "postgresql@16", .schedule = "" },
    };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeServicesJson(&aw.writer, &rows);
    try std.testing.expectEqualStrings(
        "{\"schema_version\":1,\"services\":[" ++
            "{\"name\":\"redis\",\"state\":\"running\",\"auto_start\":true,\"keg_name\":\"redis\",\"schedule\":\"interval 300s\"}," ++
            "{\"name\":\"postgres\",\"state\":\"not-loaded\",\"auto_start\":false,\"keg_name\":\"postgresql@16\",\"schedule\":\"\"}" ++
            "]}\n",
        aw.written(),
    );
}

/// Bare `malt services` is a usage error, so the text goes to stderr. An
/// explicit `--help` is a successful request and goes to stdout via
/// `showIfRequested`. Both read the same text from `help.zig`.
fn printHelp(ctx: *const AppCtx) void {
    ctx.stderr.writeStreamingAll(ctx.io, help_mod.helpFor("services")) catch {};
}
