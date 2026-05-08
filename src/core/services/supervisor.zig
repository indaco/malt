//! malt — services supervisor
//!
//! Thin wrapper over launchd (macOS) that drives service lifecycle through
//! `launchctl bootstrap`/`bootout`. The DB (schema v2 `services` table) is the
//! source of truth for registered services; launchctl owns their runtime
//! state.
//!
//! Assumptions and constraints:
//!
//! - **Domain**: services are loaded into the per-user `gui/<uid>` domain.
//!   This works without sudo and survives logout, but plists run as the
//!   logged-in user. A `--system` flag (PID 1 domain, requires root) is
//!   intentionally not yet supported.
//! - **Plist path**: must be absolute (launchctl rejects relative paths).
//!   `register` always writes to `{prefix}/var/malt/services/{label}/service.plist`,
//!   which is absolute by construction since `MALT_PREFIX` is normalized
//!   upstream.
//! - **Label uniqueness**: launchd uses the plist `Label` as the unique key.
//!   We use the service `name` directly as the label; callers should
//!   namespace via the formula name (e.g. `postgresql@16`) to avoid clashes.
//! - **OS gate**: `register`/`start`/`stop`/`restart` return `OsNotSupported`
//!   on non-macOS. `list`/`status`/`logs`/`tailLog` work everywhere because
//!   they only touch the DB and the local filesystem.
//! - **Formula integration**: registering a service when a formula carries a
//!   `service:` field happens in `cli/install.zig` after a successful keg
//!   write. `cli/uninstall.zig` calls `stopAndUnregister` before deleting
//!   files.

const std = @import("std");
const builtin = @import("builtin");
const sqlite = @import("../../db/sqlite.zig");
const plist_mod = @import("plist.zig");
const atomic = @import("../../fs/atomic.zig");

pub const SupervisorError = error{
    OsNotSupported,
    ServiceNotFound,
    LaunchctlFailed,
    IoFailed,
    DatabaseError,
    OutOfMemory,
    /// Service definition violated the validation rules in
    /// `plist_mod.validate` — interpreter bait, path escape, or
    /// oversize/NUL-bearing argv. See the render path for specifics.
    InvalidService,
};

pub fn describeError(err: SupervisorError) []const u8 {
    return switch (err) {
        SupervisorError.OsNotSupported => "services are only supported on macOS for now",
        SupervisorError.ServiceNotFound => "service not registered",
        SupervisorError.LaunchctlFailed => "launchctl command failed",
        SupervisorError.IoFailed => "filesystem error while managing service",
        SupervisorError.DatabaseError => "database error while managing service",
        SupervisorError.OutOfMemory => "out of memory",
        SupervisorError.InvalidService => "service definition rejected by malt validator",
    };
}

/// Named-field bundle for supervisor entrypoints that would otherwise
/// thread `(allocator, db)` through every call. Opens a DI seam for
/// tests to swap in fakes by replacing fields. `io` carries the parent
/// `Environ` (built once at the cli call site) so launchctl spawns
/// resolve via PATH.
pub const SupervisorCtx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.Database,
};

pub const ServiceInfo = struct {
    name: []const u8,
    keg_name: []const u8,
    plist_path: []const u8,
    auto_start: bool,
    last_status: []const u8,
};

/// Returns the services directory: `{prefix}/var/malt/services`.
pub fn servicesDir(allocator: std.mem.Allocator) SupervisorError![]const u8 {
    const prefix = atomic.maltPrefixOrAbort();
    return std.fmt.allocPrint(allocator, "{s}/var/malt/services", .{prefix}) catch
        return SupervisorError.OutOfMemory;
}

pub fn serviceDir(allocator: std.mem.Allocator, name: []const u8) SupervisorError![]const u8 {
    const prefix = atomic.maltPrefixOrAbort();
    return std.fmt.allocPrint(allocator, "{s}/var/malt/services/{s}", .{ prefix, name }) catch
        return SupervisorError.OutOfMemory;
}

pub fn logPath(allocator: std.mem.Allocator, name: []const u8, stream: enum { stdout, stderr }) SupervisorError![]const u8 {
    const dir = try serviceDir(allocator, name);
    defer allocator.free(dir);
    const file = switch (stream) {
        .stdout => "stdout.log",
        .stderr => "stderr.log",
    };
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, file }) catch
        return SupervisorError.OutOfMemory;
}

/// List services from the `services` table.
pub fn list(ctx: SupervisorCtx) SupervisorError![]ServiceInfo {
    const allocator = ctx.allocator;
    var stmt = ctx.db.prepare("SELECT name, keg_name, plist_path, auto_start, last_status FROM services ORDER BY name;") catch
        return SupervisorError.DatabaseError;
    defer stmt.finalize();

    var buf: std.ArrayList(ServiceInfo) = .empty;
    // ArrayList.deinit doesn't reach row sub-allocations; walk them too.
    errdefer {
        for (buf.items) |s| freeServiceInfoFields(allocator, s);
        buf.deinit(allocator);
    }

    while (stmt.step() catch return SupervisorError.DatabaseError) {
        const name_p = stmt.columnText(0) orelse continue;
        const keg_p = stmt.columnText(1) orelse continue;
        const plist_p = stmt.columnText(2) orelse continue;
        const status_p = stmt.columnText(4);

        // Build the row in locals so a later dupe failure can't strand an earlier one.
        const name_owned = allocator.dupe(u8, std.mem.sliceTo(name_p, 0)) catch
            return SupervisorError.OutOfMemory;
        errdefer allocator.free(name_owned);
        const keg_owned = allocator.dupe(u8, std.mem.sliceTo(keg_p, 0)) catch
            return SupervisorError.OutOfMemory;
        errdefer allocator.free(keg_owned);
        const plist_owned = allocator.dupe(u8, std.mem.sliceTo(plist_p, 0)) catch
            return SupervisorError.OutOfMemory;
        errdefer allocator.free(plist_owned);
        const status_owned = if (status_p) |p|
            allocator.dupe(u8, std.mem.sliceTo(p, 0)) catch
                return SupervisorError.OutOfMemory
        else
            allocator.dupe(u8, "unknown") catch
                return SupervisorError.OutOfMemory;
        errdefer allocator.free(status_owned);

        buf.append(allocator, .{
            .name = name_owned,
            .keg_name = keg_owned,
            .plist_path = plist_owned,
            .auto_start = stmt.columnBool(3),
            .last_status = status_owned,
        }) catch return SupervisorError.OutOfMemory;
    }

    return buf.toOwnedSlice(allocator) catch return SupervisorError.OutOfMemory;
}

fn freeServiceInfoFields(allocator: std.mem.Allocator, info: ServiceInfo) void {
    allocator.free(info.name);
    allocator.free(info.keg_name);
    allocator.free(info.plist_path);
    allocator.free(info.last_status);
}

pub fn freeServiceInfos(allocator: std.mem.Allocator, services: []ServiceInfo) void {
    for (services) |s| freeServiceInfoFields(allocator, s);
    allocator.free(services);
}

/// Register a new service row. The plist file is written to disk; the
/// launchctl bootstrap happens on `start`.
///
/// `cellar_path` / `malt_prefix` are the allowlist roots used to reject
/// interpreter bait, path escapes, and pathologically large argvs
/// before the plist lands on disk or launchctl sees it. See
/// `plist_mod.validate`.
pub fn register(
    ctx: SupervisorCtx,
    spec: plist_mod.ServiceSpec,
    keg_name: []const u8,
    auto_start: bool,
    cellar_path: []const u8,
    malt_prefix: []const u8,
) SupervisorError!void {
    if (builtin.os.tag != .macos) return SupervisorError.OsNotSupported;

    const allocator = ctx.allocator;
    plist_mod.validate(spec, cellar_path, malt_prefix) catch return SupervisorError.InvalidService;

    const dir = try serviceDir(allocator, spec.label);
    defer allocator.free(dir);
    std.Io.Dir.createDirAbsolute(ctx.io, dir, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        error.FileNotFound => {
            // Create the full parent path.
            std.Io.Dir.cwd().createDirPath(ctx.io, dir) catch return SupervisorError.IoFailed;
        },
        else => return SupervisorError.IoFailed,
    };

    const plist_path = std.fmt.allocPrint(allocator, "{s}/service.plist", .{dir}) catch
        return SupervisorError.OutOfMemory;
    defer allocator.free(plist_path);

    var file = std.Io.Dir.createFileAbsolute(ctx.io, plist_path, .{ .truncate = true }) catch
        return SupervisorError.IoFailed;
    defer file.close(ctx.io);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    plist_mod.render(spec, &aw.writer) catch return SupervisorError.IoFailed;
    file.writeStreamingAll(ctx.io, aw.written()) catch return SupervisorError.IoFailed;

    var stmt = ctx.db.prepare(
        \\INSERT OR REPLACE INTO services(name, keg_name, plist_path, auto_start, last_status)
        \\VALUES (?, ?, ?, ?, 'registered');
    ) catch return SupervisorError.DatabaseError;
    defer stmt.finalize();
    stmt.bindText(1, spec.label) catch return SupervisorError.DatabaseError;
    stmt.bindText(2, keg_name) catch return SupervisorError.DatabaseError;
    stmt.bindText(3, plist_path) catch return SupervisorError.DatabaseError;
    stmt.bindInt(4, if (auto_start) 1 else 0) catch return SupervisorError.DatabaseError;
    _ = stmt.step() catch return SupervisorError.DatabaseError;
}

fn runLaunchctl(io: std.Io, argv: []const []const u8) SupervisorError!void {
    if (builtin.os.tag != .macos) return SupervisorError.OsNotSupported;

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return SupervisorError.LaunchctlFailed;
    const term = child.wait(io) catch return SupervisorError.LaunchctlFailed;
    switch (term) {
        .exited => |code| if (code != 0) return SupervisorError.LaunchctlFailed,
        else => return SupervisorError.LaunchctlFailed,
    }
}

fn userDomain(allocator: std.mem.Allocator) ![]const u8 {
    const uid = std.c.getuid();
    return std.fmt.allocPrint(allocator, "gui/{d}", .{uid});
}

fn lookupPlistPath(allocator: std.mem.Allocator, db: *sqlite.Database, name: []const u8) SupervisorError![]const u8 {
    var stmt = db.prepare("SELECT plist_path FROM services WHERE name = ?;") catch
        return SupervisorError.DatabaseError;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return SupervisorError.DatabaseError;
    if (!(stmt.step() catch return SupervisorError.DatabaseError)) return SupervisorError.ServiceNotFound;
    const p = stmt.columnText(0) orelse return SupervisorError.ServiceNotFound;
    return allocator.dupe(u8, std.mem.sliceTo(p, 0)) catch return SupervisorError.OutOfMemory;
}

pub fn start(ctx: SupervisorCtx, name: []const u8) SupervisorError!void {
    if (builtin.os.tag != .macos) return SupervisorError.OsNotSupported;
    const allocator = ctx.allocator;
    const plist_path = try lookupPlistPath(allocator, ctx.db, name);
    defer allocator.free(plist_path);
    const domain = userDomain(allocator) catch return SupervisorError.OutOfMemory;
    defer allocator.free(domain);

    try runLaunchctl(ctx.io, &.{ "launchctl", "bootstrap", domain, plist_path });
    // Status is a UI hint; launchctl is the source of truth for liveness.
    setStatus(ctx.db, name, "running") catch {};
}

pub fn stop(ctx: SupervisorCtx, name: []const u8) SupervisorError!void {
    if (builtin.os.tag != .macos) return SupervisorError.OsNotSupported;
    const allocator = ctx.allocator;
    const plist_path = try lookupPlistPath(allocator, ctx.db, name);
    defer allocator.free(plist_path);
    const domain = userDomain(allocator) catch return SupervisorError.OutOfMemory;
    defer allocator.free(domain);

    try runLaunchctl(ctx.io, &.{ "launchctl", "bootout", domain, plist_path });
    // Status is a UI hint; launchctl is the source of truth for liveness.
    setStatus(ctx.db, name, "stopped") catch {};
}

pub fn restart(ctx: SupervisorCtx, name: []const u8) SupervisorError!void {
    // Stop may fail if already stopped; start is the required half.
    stop(ctx, name) catch {};
    try start(ctx, name);
}

pub fn stopAndUnregister(ctx: SupervisorCtx, name: []const u8) void {
    // Unregister must remove the DB row even if the service is already down.
    stop(ctx, name) catch {};
    var stmt = ctx.db.prepare("DELETE FROM services WHERE name = ?;") catch return;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return;
    // Row may not exist; DELETE is idempotent either way.
    _ = stmt.step() catch {};
}

fn setStatus(db: *sqlite.Database, name: []const u8, status: []const u8) SupervisorError!void {
    var stmt = db.prepare("UPDATE services SET last_status = ? WHERE name = ?;") catch
        return SupervisorError.DatabaseError;
    defer stmt.finalize();
    stmt.bindText(1, status) catch return SupervisorError.DatabaseError;
    stmt.bindText(2, name) catch return SupervisorError.DatabaseError;
    _ = stmt.step() catch return SupervisorError.DatabaseError;
}

pub const RuntimeState = enum { not_loaded, loaded, running };

pub fn runtimeStateName(s: RuntimeState) []const u8 {
    return switch (s) {
        .not_loaded => "not-loaded",
        .loaded => "loaded",
        .running => "running",
    };
}

/// Query launchctl for the runtime state of `label`. Returns `.not_loaded`
/// on any failure (missing label, non-macOS, launchctl error) so callers can
/// degrade to the DB-recorded status without aborting.
pub fn queryRuntime(io: std.Io, allocator: std.mem.Allocator, label: []const u8) RuntimeState {
    if (builtin.os.tag != .macos) return .not_loaded;

    // `launchctl list` output is at most a few hundred lines (one per
    // registered service); on a typical Mac it's well under 50 KiB. Cap
    // at 4 MiB so a runaway launchd state can't push us into multi-MB
    // allocations. Streaming line-by-line via std.Io.Reader would shave
    // a sub-millisecond parse cost but the codebase doesn't otherwise
    // use that API, so the complexity isn't worth it for this cold path.
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "launchctl", "list" },
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
    }) catch return .not_loaded;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    // Skip header (PID Status Label).
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const pid_field = fields.next() orelse continue;
        _ = fields.next() orelse continue; // status code
        const lbl = fields.next() orelse continue;
        if (!std.mem.eql(u8, lbl, label)) continue;
        if (pid_field.len == 1 and pid_field[0] == '-') return .loaded;
        return .running;
    }
    return .not_loaded;
}

pub fn hasService(db: *sqlite.Database, name: []const u8) bool {
    var stmt = db.prepare("SELECT 1 FROM services WHERE name = ?;") catch return false;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return false;
    return stmt.step() catch false;
}

pub fn tailLog(io: std.Io, allocator: std.mem.Allocator, path: []const u8, n: usize, writer: *std.Io.Writer) SupervisorError!void {
    const f = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return SupervisorError.IoFailed;
    defer f.close(io);
    const stat = f.stat(io) catch return SupervisorError.IoFailed;

    // Read whole file if small; otherwise last 64 KiB.
    const read_size: usize = @min(stat.size, 64 * 1024);
    const buf = allocator.alloc(u8, read_size) catch return SupervisorError.OutOfMemory;
    defer allocator.free(buf);
    const seek_from: u64 = if (stat.size > read_size) stat.size - read_size else 0;
    const read = f.readPositionalAll(io, buf, seek_from) catch return SupervisorError.IoFailed;
    const slice = buf[0..read];

    // Walk backwards, counting newlines.
    var newlines: usize = 0;
    var start_at: usize = slice.len;
    var i: usize = slice.len;
    while (i > 0) : (i -= 1) {
        if (slice[i - 1] == '\n') {
            newlines += 1;
            if (newlines > n) {
                start_at = i;
                break;
            }
        }
    } else {
        start_at = 0;
    }
    writer.writeAll(slice[start_at..]) catch return SupervisorError.IoFailed;
}

/// Tail `path` and stream appended bytes until `interrupted()` returns true.
/// `interrupted` is the caller's seam onto SIGINT (or any other stop signal);
/// keeping it as a callback keeps this module free of CLI/main coupling.
pub fn followLog(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    tail_n: usize,
    writer: *std.Io.Writer,
    interrupted: *const fn () bool,
) SupervisorError!void {
    try tailLog(io, allocator, path, tail_n, writer);
    writer.flush() catch return SupervisorError.IoFailed;

    const f = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return SupervisorError.IoFailed;
    defer f.close(io);
    var offset: u64 = (f.stat(io) catch return SupervisorError.IoFailed).size;

    var buf: [4096]u8 = undefined;
    // 200 ms cadence is plenty for human-scale tails.
    const poll_ns: u64 = 200 * std.time.ns_per_ms;
    while (!interrupted()) {
        const n = f.readPositionalAll(io, &buf, offset) catch return SupervisorError.IoFailed;
        if (n == 0) {
            // Cancelled sleep means SIGINT (or another stop signal) reached
            // the io subsystem before `interrupted()` flipped; bail rather
            // than busy-spin until the flag catches up.
            std.Io.sleep(io, std.Io.Duration.fromNanoseconds(@intCast(poll_ns)), .awake) catch |e| switch (e) {
                error.Canceled => break,
            };
            continue;
        }
        writer.writeAll(buf[0..n]) catch return SupervisorError.IoFailed;
        writer.flush() catch return SupervisorError.IoFailed;
        offset += n;
    }
}

const testing = std.testing;

// Static state lets the interrupt callback drive a deterministic follow-loop
// scenario in tests without spawning a real thread or signal.
const FollowProbe = struct {
    var calls: usize = 0;
    var stop_at: usize = 1;
    var append_at: usize = 0;
    var append_path: []const u8 = "";
    var append_bytes: []const u8 = "";

    fn reset() void {
        calls = 0;
        stop_at = 1;
        append_at = 0;
        append_path = "";
        append_bytes = "";
    }

    fn cb() bool {
        calls += 1;
        if (append_at != 0 and calls == append_at) {
            const f = std.Io.Dir.openFileAbsolute(test_io, append_path, .{ .mode = .read_write }) catch return true;
            defer f.close(test_io);
            const st = f.stat(test_io) catch return true;
            f.writePositionalAll(test_io, append_bytes, st.size) catch {};
        }
        return calls >= stop_at;
    }
};

/// Per-test Threaded io shared by FollowProbe.cb. Tests sequence-execute,
/// so a static handle is sufficient.
var test_threaded: std.Io.Threaded = undefined;
var test_io: std.Io = undefined;

fn testIoInit() void {
    test_threaded = .init(testing.allocator, .{});
    test_io = test_threaded.io();
}

fn testIoDeinit() void {
    test_threaded.deinit();
}

test "followLog prints initial tail and exits when interrupt is set before first poll" {
    testIoInit();
    defer testIoDeinit();

    const dir = "/tmp/malt_supervisor_follow_interrupt";
    std.Io.Dir.cwd().deleteTree(test_io, dir) catch {};
    try std.Io.Dir.createDirAbsolute(test_io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(test_io, dir) catch {};

    const log_path = dir ++ "/sample.log";
    {
        const f = try std.Io.Dir.createFileAbsolute(test_io, log_path, .{ .truncate = true });
        defer f.close(test_io);
        try f.writeStreamingAll(test_io, "first\nsecond\n");
    }

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    FollowProbe.reset();
    FollowProbe.stop_at = 1;
    try followLog(test_io, testing.allocator, log_path, 2, &aw.writer, FollowProbe.cb);

    try testing.expectEqualStrings("first\nsecond\n", aw.written());
    try testing.expectEqual(@as(usize, 1), FollowProbe.calls);
}

test "followLog flushes appended bytes between polls" {
    testIoInit();
    defer testIoDeinit();

    const dir = "/tmp/malt_supervisor_follow_poll";
    std.Io.Dir.cwd().deleteTree(test_io, dir) catch {};
    try std.Io.Dir.createDirAbsolute(test_io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(test_io, dir) catch {};

    const log_path = dir ++ "/sample.log";
    {
        const f = try std.Io.Dir.createFileAbsolute(test_io, log_path, .{ .truncate = true });
        defer f.close(test_io);
        try f.writeStreamingAll(test_io, "seed\n");
    }

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    FollowProbe.reset();
    FollowProbe.append_path = log_path;
    FollowProbe.append_bytes = "appended\n";
    FollowProbe.append_at = 1;
    FollowProbe.stop_at = 3;

    try followLog(test_io, testing.allocator, log_path, 0, &aw.writer, FollowProbe.cb);

    try testing.expect(std.mem.indexOf(u8, aw.written(), "appended\n") != null);
    try testing.expectEqual(@as(usize, 3), FollowProbe.calls);
}

// Patches an inner Io's vtable so `sleep` reports cancellation on the
// configured call index; non-canceled sleeps return immediately so the
// 200 ms poll cadence doesn't pad the test runtime.
const CancelSleepProbe = struct {
    var vtable: std.Io.VTable = undefined;
    var sleep_calls: usize = 0;
    var cancel_at: usize = 1;

    fn wrap(inner: std.Io, cancel_at_call: usize) std.Io {
        vtable = inner.vtable.*;
        vtable.sleep = sleepMaybeCanceled;
        sleep_calls = 0;
        cancel_at = cancel_at_call;
        return .{ .userdata = inner.userdata, .vtable = &vtable };
    }

    fn sleepMaybeCanceled(_: ?*anyopaque, _: std.Io.Timeout) std.Io.Cancelable!void {
        sleep_calls += 1;
        if (sleep_calls >= cancel_at) return error.Canceled;
    }
};

test "followLog breaks when sleep reports cancellation on the first poll" {
    testIoInit();
    defer testIoDeinit();

    const dir = "/tmp/malt_supervisor_follow_cancel";
    std.Io.Dir.cwd().deleteTree(test_io, dir) catch {};
    try std.Io.Dir.createDirAbsolute(test_io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(test_io, dir) catch {};

    const log_path = dir ++ "/sample.log";
    {
        const f = try std.Io.Dir.createFileAbsolute(test_io, log_path, .{ .truncate = true });
        defer f.close(test_io);
        try f.writeStreamingAll(test_io, "seed\n");
    }

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const cancel_io = CancelSleepProbe.wrap(test_io, 1);

    FollowProbe.reset();
    // High stop_at: only sleep cancellation should end the loop. If the loop
    // ever spins past Canceled, FollowProbe.calls will exceed 1.
    FollowProbe.stop_at = 16;

    try followLog(cancel_io, testing.allocator, log_path, 0, &aw.writer, FollowProbe.cb);

    try testing.expectEqual(@as(usize, 1), CancelSleepProbe.sleep_calls);
    try testing.expectEqual(@as(usize, 1), FollowProbe.calls);
}

test "followLog breaks when sleep reports cancellation after several idle polls" {
    testIoInit();
    defer testIoDeinit();

    const dir = "/tmp/malt_supervisor_follow_cancel_late";
    std.Io.Dir.cwd().deleteTree(test_io, dir) catch {};
    try std.Io.Dir.createDirAbsolute(test_io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(test_io, dir) catch {};

    const log_path = dir ++ "/sample.log";
    {
        const f = try std.Io.Dir.createFileAbsolute(test_io, log_path, .{ .truncate = true });
        defer f.close(test_io);
        try f.writeStreamingAll(test_io, "seed\n");
    }

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    // Cancel the fourth sleep — three idle polls happen first, pinning that
    // the catch arm fires regardless of how many normal sleeps preceded it
    // and that the loop doesn't latch on the prior non-cancelled returns.
    const cancel_io = CancelSleepProbe.wrap(test_io, 4);

    FollowProbe.reset();
    FollowProbe.stop_at = 16;

    try followLog(cancel_io, testing.allocator, log_path, 0, &aw.writer, FollowProbe.cb);

    try testing.expectEqual(@as(usize, 4), CancelSleepProbe.sleep_calls);
    try testing.expectEqual(@as(usize, 4), FollowProbe.calls);
}

test "followLog flushes data appended before sleep cancellation lands" {
    testIoInit();
    defer testIoDeinit();

    const dir = "/tmp/malt_supervisor_follow_cancel_flush";
    std.Io.Dir.cwd().deleteTree(test_io, dir) catch {};
    try std.Io.Dir.createDirAbsolute(test_io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(test_io, dir) catch {};

    const log_path = dir ++ "/sample.log";
    {
        const f = try std.Io.Dir.createFileAbsolute(test_io, log_path, .{ .truncate = true });
        defer f.close(test_io);
        try f.writeStreamingAll(test_io, "seed\n");
    }

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    // Append data on the first interrupt-check, then cancel the second
    // sleep so the flushed bytes must already be in the writer when the
    // loop bails.
    FollowProbe.reset();
    FollowProbe.append_path = log_path;
    FollowProbe.append_bytes = "tail-bytes\n";
    FollowProbe.append_at = 1;
    FollowProbe.stop_at = 16;

    const cancel_io = CancelSleepProbe.wrap(test_io, 2);

    try followLog(cancel_io, testing.allocator, log_path, 0, &aw.writer, FollowProbe.cb);

    try testing.expect(std.mem.indexOf(u8, aw.written(), "tail-bytes\n") != null);
    try testing.expectEqual(@as(usize, 2), CancelSleepProbe.sleep_calls);
}
