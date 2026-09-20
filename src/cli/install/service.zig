//! Bridge from a formula's `service` block to the launchd `ServiceSpec`
//! the supervisor registers. Shared by install and upgrade so both paths
//! render the plist from the same definition.

const std = @import("std");

const formula_mod = @import("../../core/formula.zig");
const plist_mod = @import("../../core/services/plist.zig");
const supervisor_mod = @import("../../core/services/supervisor.zig");
const sqlite = @import("../../db/sqlite.zig");
const sink_mod = @import("sink.zig");

const testing = std.testing;

/// Pure def -> spec mapping. Every string the spec points at is owned by
/// `aa`, so callers scope it to an arena that outlives `register`.
pub fn specFromDef(
    aa: std.mem.Allocator,
    def: formula_mod.ServiceDef,
    name: []const u8,
    prefix: []const u8,
) !plist_mod.ServiceSpec {
    // The Homebrew API renders service paths as `$HOMEBREW_PREFIX/...`;
    // launchd does not expand the token and the validator rejects it.
    const run = try aa.alloc([]const u8, def.run.len);
    for (def.run, 0..) |arg, i| run[i] = try plist_mod.expandPrefix(aa, arg, prefix);

    return .{
        .label = try std.fmt.allocPrint(aa, "com.malt.{s}", .{name}),
        .program_args = run,
        .working_dir = if (def.working_dir) |wd| try plist_mod.expandPrefix(aa, wd, prefix) else null,
        .stdout_path = if (def.log_path) |lp|
            try plist_mod.expandPrefix(aa, lp, prefix)
        else
            try std.fmt.allocPrint(aa, "{s}/var/log/{s}.out", .{ prefix, name }),
        .stderr_path = if (def.error_log_path) |elp|
            try plist_mod.expandPrefix(aa, elp, prefix)
        else
            try std.fmt.allocPrint(aa, "{s}/var/log/{s}.err", .{ prefix, name }),
        .schedule = def.schedule,
        .keep_alive = def.keep_alive,
        .stop_timeout = def.stop_timeout,
    };
}

/// Register (or re-register) the launchd service a formula's `service:`
/// block declares. No-op without one. Best-effort: failures warn but never
/// fail the install or upgrade that called it.
pub fn register(
    io: std.Io,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    formula: *const formula_mod.Formula,
    prefix: []const u8,
    sink: sink_mod.OutputSink,
) void {
    const def = formula.service orelse return;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const spec = specFromDef(aa, def, formula.name, prefix) catch return;

    // launchd creates the log files on first run; a missing dir surfaces there.
    const log_dir = std.fmt.allocPrint(aa, "{s}/var/log", .{prefix}) catch return;
    std.Io.Dir.cwd().createDirPath(io, log_dir) catch {};

    const cellar_path = std.fmt.allocPrint(aa, "{s}/Cellar/{s}/{s}", .{ prefix, formula.name, formula.pkg_version }) catch return;

    supervisor_mod.register(.{ .allocator = allocator, .io = io, .db = db }, spec, formula.name, false, cellar_path, prefix) catch |err| {
        sink.warn("could not register service for {s}: {s}", .{ formula.name, @errorName(err) });
        return;
    };

    // launchd keeps a loaded job's configuration until bootout, so a
    // rewritten plist only takes effect on restart. Never restart here: an
    // upgrade must not kill a daemon the user did not ask to stop.
    switch (supervisor_mod.queryRuntime(io, allocator, spec.label)) {
        .loaded, .running, .errored => sink.warn("{s} service re-registered; run 'mt services restart {s}' to apply it", .{ formula.name, formula.name }),
        .not_loaded => {},
    }
}

test "specFromDef expands the Homebrew prefix token in every path field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const def: formula_mod.ServiceDef = .{
        .run = &.{ "$HOMEBREW_PREFIX/opt/redis/bin/redis-server", "--daemonize", "no" },
        .working_dir = "$HOMEBREW_PREFIX/var",
        .log_path = "$HOMEBREW_PREFIX/var/log/redis.log",
        .error_log_path = "$HOMEBREW_PREFIX/var/log/redis.err",
    };
    const spec = try specFromDef(arena.allocator(), def, "redis", "/opt/malt");
    try testing.expectEqualStrings("com.malt.redis", spec.label);
    try testing.expectEqual(@as(usize, 3), spec.program_args.len);
    try testing.expectEqualStrings("/opt/malt/opt/redis/bin/redis-server", spec.program_args[0]);
    try testing.expectEqualStrings("no", spec.program_args[2]);
    try testing.expectEqualStrings("/opt/malt/var", spec.working_dir.?);
    try testing.expectEqualStrings("/opt/malt/var/log/redis.log", spec.stdout_path);
    try testing.expectEqualStrings("/opt/malt/var/log/redis.err", spec.stderr_path);
}

test "specFromDef defaults the log paths under var/log and leaves working_dir unset" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const def: formula_mod.ServiceDef = .{ .run = &.{"/bin/true"} };
    const spec = try specFromDef(arena.allocator(), def, "dnsmasq", "/opt/malt");
    try testing.expectEqualStrings("/opt/malt/var/log/dnsmasq.out", spec.stdout_path);
    try testing.expectEqualStrings("/opt/malt/var/log/dnsmasq.err", spec.stderr_path);
    try testing.expect(spec.working_dir == null);
}

test "specFromDef copies keep_alive, schedule and stop_timeout through unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const def: formula_mod.ServiceDef = .{
        .run = &.{"/bin/true"},
        .keep_alive = false,
        .schedule = .{ .interval = 300 },
        .stop_timeout = 45,
    };
    const spec = try specFromDef(arena.allocator(), def, "x", "/opt/malt");
    try testing.expect(!spec.keep_alive);
    try testing.expectEqual(@as(u32, 300), spec.schedule.interval);
    try testing.expectEqual(@as(?u32, 45), spec.stop_timeout);

    const plain: formula_mod.ServiceDef = .{ .run = &.{"/bin/true"} };
    const plain_spec = try specFromDef(arena.allocator(), plain, "x", "/opt/malt");
    try testing.expect(plain_spec.keep_alive);
    try testing.expect(plain_spec.schedule == .immediate);
    try testing.expect(plain_spec.stop_timeout == null);
}
