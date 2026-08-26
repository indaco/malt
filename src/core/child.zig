//! malt — shared spawn+wait helper for one-shot external commands.
//! Captures stdout+stderr so successful runs stay silent and failures
//! surface the child's own diagnostics. Replaces the
//! inherited-stdio shape that let hdiutil/ditto verbose output bleed
//! onto the user's progress bar.

const std = @import("std");

pub const ChildError = error{
    SpawnFailed,
    WaitFailed,
    /// Child did not exit cleanly with code 0 — covers non-zero exits,
    /// signal kills, stops, and the "unknown" termination path.
    NonZeroExit,
    OutOfMemory,
    IoError,
};

/// Per-stream cap for diagnostic captures. Sized to fit a typical
/// `hdiutil attach` verbose dump (a few KB) plus headroom; the pure
/// failure-path information density does not justify holding more.
pub const default_capture_bytes: usize = 256 * 1024;

/// Captured outcome of a child process. `stdout` / `stderr` are owned
/// by the caller via `deinit`.
pub const RunReport = struct {
    /// Exit code on `.exited`; `128+signum` for signal/stopped, `255` sentinel
    /// for unknown terminations.
    code: u8,
    stdout: []u8,
    stderr: []u8,
    /// A stream hit the cap and the rest was discarded. Diagnostic callers
    /// ignore this; a caller reading the output as *data* must not.
    truncated: bool = false,

    pub fn deinit(self: RunReport, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Collapse a wait `Term` to an exit code: the real code on a clean exit, the
/// shell's `128+signum` convention on signal/stopped (so callers see which
/// signal killed the child), and a `255` sentinel for unknown terminations.
pub fn termToCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |c| c,
        // WTERMSIG masks the signum to 7 bits, so 128+signum always fits u8.
        .signal, .stopped => |s| 128 +| @as(u8, @intCast(@intFromEnum(s))),
        .unknown => 255,
    };
}

/// Carries one stream's drain result across the worker-thread boundary.
const DrainCtx = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    pipe: ?std.Io.File,
    cap: usize,
    result: ChildError!Drained = undefined,
};

/// Captured bytes plus whether the cap cut them short.
const Drained = struct {
    bytes: []u8,
    truncated: bool,
};

fn drainWorker(ctx: *DrainCtx) void {
    ctx.result = drainPipe(ctx.io, ctx.allocator, ctx.pipe, ctx.cap);
}

/// Spawn `argv` with stdout + stderr piped, wait, and return the
/// captured output alongside the exit code. Caller frees the buffers
/// via `RunReport.deinit`. Both pipes are drained concurrently (a worker
/// thread per stream) so a child that overflows one pipe buffer can't
/// block the drain of the other.
pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) ChildError!RunReport {
    return runCapped(io, allocator, argv, default_capture_bytes);
}

/// `run` with an explicit per-stream cap, for callers whose stdout is data
/// rather than diagnostics and who must know when it did not all fit.
pub fn runCapped(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cap: usize,
) ChildError!RunReport {
    return runCappedInDir(io, allocator, argv, cap, .inherit);
}

fn runCappedInDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cap: usize,
    cwd: std.process.Child.Cwd,
) ChildError!RunReport {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return error.SpawnFailed;

    // Drain stderr on a worker thread while the calling thread drains
    // stdout — sequential drains deadlock when the not-yet-read stream
    // fills its pipe buffer and the child blocks in write before exit.
    var err_ctx: DrainCtx = .{ .io = io, .allocator = allocator, .pipe = child.stderr, .cap = cap };
    const err_thread = std.Thread.spawn(.{}, drainWorker, .{&err_ctx}) catch {
        child.kill(io);
        return error.IoError;
    };

    const stdout_res = drainPipe(io, allocator, child.stdout, cap);

    // Either drain failing means the child may still hold a pipe open;
    // kill it so the worker's read returns EOF before we join.
    if (stdout_res) |_| {} else |_| child.kill(io);
    err_thread.join();
    const stderr_res = err_ctx.result;

    const out_drain = stdout_res catch |e| {
        // Child already killed above; free whatever the worker collected.
        if (stderr_res) |d| allocator.free(d.bytes) else |_| {}
        return e;
    };
    errdefer allocator.free(out_drain.bytes);

    const err_drain = stderr_res catch |e| {
        child.kill(io);
        return e;
    };
    errdefer allocator.free(err_drain.bytes);

    const term = child.wait(io) catch return error.WaitFailed;
    const code = termToCode(term);

    return .{
        .code = code,
        .stdout = out_drain.bytes,
        .stderr = err_drain.bytes,
        .truncated = out_drain.truncated or err_drain.truncated,
    };
}

/// Spawn and wait. Silent on success; on non-zero exit, replays the
/// child's captured stderr (then stdout) to the parent's stderr so the
/// user sees the underlying tool's diagnostics, then returns
/// `error.NonZeroExit`.
pub fn runOrFail(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) ChildError!void {
    const report = try run(io, allocator, argv);
    defer report.deinit(allocator);
    if (report.code == 0) return;

    const stderr_file = std.Io.File.stderr();
    if (report.stderr.len > 0) stderr_file.writeStreamingAll(io, report.stderr) catch {};
    if (report.stdout.len > 0) stderr_file.writeStreamingAll(io, report.stdout) catch {};
    return error.NonZeroExit;
}

/// Run a command with its working directory anchored to an already-open
/// directory handle. On POSIX, spawn uses `fchdir`, so a pathname swap cannot
/// redirect a child that writes relative to `.`.
pub fn runOrFailInDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: std.Io.Dir,
) ChildError!void {
    const report = try runCappedInDir(io, allocator, argv, default_capture_bytes, .{ .dir = cwd });
    defer report.deinit(allocator);
    if (report.code == 0) return;

    const stderr_file = std.Io.File.stderr();
    if (report.stderr.len > 0) stderr_file.writeStreamingAll(io, report.stderr) catch {};
    if (report.stdout.len > 0) stderr_file.writeStreamingAll(io, report.stdout) catch {};
    return error.NonZeroExit;
}

/// Spawn `argv` with the parent's stdin/stdout/stderr inherited, wait, and
/// map a non-zero exit to `error.NonZeroExit`. Unlike `run`, nothing is
/// captured — use this for a child that must talk to the terminal live, e.g.
/// `sudo installer`, whose password prompt and progress must reach the user
/// as they happen instead of being buffered and replayed only on failure.
pub fn runOrFailInherit(io: std.Io, argv: []const []const u8) ChildError!void {
    // Stdio defaults to `.inherit`; unlike `run`, we deliberately do not pipe.
    var child = std.process.spawn(io, .{ .argv = argv }) catch return error.SpawnFailed;
    const term = child.wait(io) catch return error.WaitFailed;
    if (termToCode(term) != 0) return error.NonZeroExit;
}

fn drainPipe(
    io: std.Io,
    allocator: std.mem.Allocator,
    pipe: ?std.Io.File,
    cap: usize,
) ChildError!Drained {
    const file = pipe orelse return .{
        .bytes = allocator.alloc(u8, 0) catch return error.OutOfMemory,
        .truncated = false,
    };
    var read_buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buf);
    const r = &reader.interface;

    var captured: std.Io.Writer.Allocating = .init(allocator);
    errdefer captured.deinit();

    // Capture up to the cap. The allocating writer only fails on OOM.
    var room: usize = cap;
    while (room > 0) {
        const n = r.stream(&captured.writer, std.Io.Limit.limited(room)) catch |e| switch (e) {
            error.EndOfStream => break,
            error.WriteFailed => return error.OutOfMemory,
            error.ReadFailed => return error.IoError,
        };
        room -= n;
    }
    // Drain the overflow to EOF so the child can't block in write on a full
    // pipe once the cap is reached — that is the deadlock this guards.
    const dropped = r.discardRemaining() catch return error.IoError;

    return .{
        .bytes = captured.toOwnedSlice() catch return error.OutOfMemory,
        .truncated = dropped > 0,
    };
}

test "output that fits the cap is not flagged truncated" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var report = try run(threaded.io(), std.testing.allocator, &.{ "/bin/echo", "short" });
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(!report.truncated);
    try std.testing.expectEqualStrings("short\n", report.stdout);
}

// A silently short read is the dangerous failure for a caller reading stdout
// as data - it looks like a complete answer.
test "output past the cap is flagged, not quietly shortened" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const payload = "0123456789" ** 32;
    var report = try runCapped(threaded.io(), std.testing.allocator, &.{ "/bin/echo", payload }, 16);
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.truncated);
    try std.testing.expectEqual(@as(usize, 16), report.stdout.len);
}

test "runOrFail returns void on exit code 0" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const argv = [_][]const u8{"/usr/bin/true"};
    try runOrFail(threaded.io(), std.testing.allocator, &argv);
}

test "runOrFail returns NonZeroExit on a non-zero exit" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const argv = [_][]const u8{"/usr/bin/false"};
    try std.testing.expectError(ChildError.NonZeroExit, runOrFail(threaded.io(), std.testing.allocator, &argv));
}

test "runOrFail returns SpawnFailed when program does not exist" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const argv = [_][]const u8{"/nonexistent/binary/malt_child_test"};
    try std.testing.expectError(ChildError.SpawnFailed, runOrFail(threaded.io(), std.testing.allocator, &argv));
}

test "runOrFailInDir anchors relative writes to the open directory" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const a = std.testing.allocator;
    const base = try std.fmt.allocPrintSentinel(a, "/tmp/malt_child_cwd_{d}", .{std.c.getpid()}, 0);
    defer a.free(base);
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};

    const work = try std.fmt.allocPrint(a, "{s}/work", .{base});
    defer a.free(work);
    const held = try std.fmt.allocPrint(a, "{s}/held", .{base});
    defer a.free(held);
    const outside = try std.fmt.allocPrint(a, "{s}/outside", .{base});
    defer a.free(outside);
    const held_marker = try std.fmt.allocPrint(a, "{s}/marker", .{held});
    defer a.free(held_marker);
    const outside_marker = try std.fmt.allocPrint(a, "{s}/marker", .{outside});
    defer a.free(outside_marker);

    try std.Io.Dir.cwd().createDirPath(io, work);
    try std.Io.Dir.cwd().createDirPath(io, outside);
    const work_handle = try std.Io.Dir.openDirAbsolute(io, work, .{ .follow_symlinks = false });
    defer work_handle.close(io);
    try std.Io.Dir.renameAbsolute(work, held, io);
    try std.Io.Dir.symLinkAbsolute(io, outside, work, .{});

    const argv = [_][]const u8{ "/usr/bin/touch", "marker" };
    try runOrFailInDir(io, a, &argv, work_handle);

    try std.Io.Dir.accessAbsolute(io, held_marker, .{});
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(io, outside_marker, .{}),
    );
}

test "runOrFailInherit returns void on exit code 0" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const argv = [_][]const u8{"/usr/bin/true"};
    try runOrFailInherit(threaded.io(), &argv);
}

test "runOrFailInherit returns NonZeroExit on a non-zero exit" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const argv = [_][]const u8{"/usr/bin/false"};
    try std.testing.expectError(ChildError.NonZeroExit, runOrFailInherit(threaded.io(), &argv));
}

test "runOrFailInherit returns SpawnFailed when program does not exist" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const argv = [_][]const u8{"/nonexistent/binary/malt_child_test"};
    try std.testing.expectError(ChildError.SpawnFailed, runOrFailInherit(threaded.io(), &argv));
}

test "termToCode forwards the real exit code and maps signals to 128+signum" {
    // The forwarded code is what `mt run`/brew-fallback surface to the shell.
    try std.testing.expectEqual(@as(u8, 0), termToCode(.{ .exited = 0 }));
    try std.testing.expectEqual(@as(u8, 1), termToCode(.{ .exited = 1 }));
    try std.testing.expectEqual(@as(u8, 42), termToCode(.{ .exited = 42 }));
    try std.testing.expectEqual(@as(u8, 255), termToCode(.{ .exited = 255 }));
    // SIGINT=2, SIGKILL=9 are POSIX-stable across macOS/Linux → 130, 137.
    try std.testing.expectEqual(@as(u8, 130), termToCode(.{ .signal = .INT }));
    try std.testing.expectEqual(@as(u8, 137), termToCode(.{ .signal = .KILL }));
    // stopped follows the same formula; SIGSTOP differs by platform, so derive.
    try std.testing.expectEqual(@as(u8, 128 + @intFromEnum(std.posix.SIG.STOP)), termToCode(.{ .stopped = .STOP }));
    // unknown has no signum — keeps the opaque sentinel.
    try std.testing.expectEqual(@as(u8, 255), termToCode(.{ .unknown = 0 }));
}

// Capture-content tests (dual-stream, non-zero exit) live in
// `tests/child_test.zig`. They need a shell to drive stdout+stderr in
// one command, which the argv-only spawn invariant forbids under
// `src/**` — the invariant only scans src/, so the integration file
// is exempt.
