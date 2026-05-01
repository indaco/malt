//! malt — services command

const std = @import("std");
const AppCtx = @import("../app_ctx.zig").AppCtx;
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const supervisor = @import("../core/services/supervisor.zig");

pub const ServicesError = error{
    InvalidArgs,
    DatabaseError,
    SupervisorError,
};

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
    if (args.len == 0 or
        std.mem.eql(u8, args[0], "-h") or
        std.mem.eql(u8, args[0], "--help"))
    {
        try printHelp(ctx);
        return;
    }

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
    if (items.len == 0) {
        output.info("no services registered", .{});
        return;
    }
    for (items) |s| {
        const runtime = supervisor.queryRuntime(io, allocator, s.name);
        const as: []const u8 = if (s.auto_start) "auto" else "manual";
        output.plain("{s}\t{s}\t{s}\t{s}", .{
            s.name,
            supervisor.runtimeStateName(runtime),
            as,
            s.keg_name,
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
    const runtime = supervisor.queryRuntime(io, allocator, name);
    output.info("service {s}: {s}", .{ name, supervisor.runtimeStateName(runtime) });
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
    const path = try supervisor.logPath(allocator, name, if (stream == .stdout) .stdout else .stderr);
    defer allocator.free(path);
    const stdout = ctx.stdout;
    var write_buf: [4096]u8 = undefined;
    var stdout_writer = stdout.writer(ctx.io, &write_buf);
    const w = &stdout_writer.interface;
    if (follow) {
        const main_mod = @import("../main.zig");
        try supervisor.followLog(ctx.io, allocator, path, tail_n, w, main_mod.isInterrupted);
    } else {
        try supervisor.tailLog(ctx.io, allocator, path, tail_n, w);
    }
    try w.flush();
}

fn openDb(ctx: *const AppCtx) !sqlite.Database {
    const prefix = atomic.maltPrefix();
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

fn printHelp(ctx: *const AppCtx) !void {
    const msg =
        \\Usage: malt services <subcommand> [args]
        \\
        \\Subcommands:
        \\  list              Show registered services.
        \\  start <name>      Bootstrap the service under launchd.
        \\  stop <name>       Boot the service out of launchd.
        \\  restart <name>    stop then start.
        \\  status [name]     Show registered state (falls back to list).
        \\  logs <name> [--tail N] [--stderr] [--follow|-f]
        \\                    Print the last N lines of the service log.
        \\                    --follow / -f tails appended bytes until SIGINT.
        \\
    ;
    ctx.stderr.writeStreamingAll(ctx.io, msg) catch {};
}
