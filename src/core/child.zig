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

/// Per-stream cap on captured bytes. Sized to fit a typical
/// `hdiutil attach` verbose dump (a few KB) plus headroom; the pure
/// failure-path information density does not justify holding more.
const max_capture_bytes: usize = 256 * 1024;

/// Captured outcome of a child process. `stdout` / `stderr` are owned
/// by the caller via `deinit`.
pub const RunReport = struct {
    /// Exit code on `.exited`; `255` sentinel for signal/stopped/unknown.
    code: u8,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: RunReport, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Collapse a wait `Term` to an exit code: the real code on a clean exit, a
/// `255` sentinel for signal/stopped/unknown terminations.
pub fn termToCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |c| c,
        .signal, .stopped, .unknown => 255,
    };
}

/// Carries one stream's drain result across the worker-thread boundary.
const DrainCtx = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    pipe: ?std.Io.File,
    result: ChildError![]u8 = undefined,
};

fn drainWorker(ctx: *DrainCtx) void {
    ctx.result = drainPipe(ctx.io, ctx.allocator, ctx.pipe);
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
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return error.SpawnFailed;

    // Drain stderr on a worker thread while the calling thread drains
    // stdout — sequential drains deadlock when the not-yet-read stream
    // fills its pipe buffer and the child blocks in write before exit.
    var err_ctx: DrainCtx = .{ .io = io, .allocator = allocator, .pipe = child.stderr };
    const err_thread = std.Thread.spawn(.{}, drainWorker, .{&err_ctx}) catch {
        child.kill(io);
        return error.IoError;
    };

    const stdout_res = drainPipe(io, allocator, child.stdout);

    // Either drain failing means the child may still hold a pipe open;
    // kill it so the worker's read returns EOF before we join.
    if (stdout_res) |_| {} else |_| child.kill(io);
    err_thread.join();
    const stderr_res = err_ctx.result;

    const stdout_bytes = stdout_res catch |e| {
        // Child already killed above; free whatever the worker collected.
        if (stderr_res) |b| allocator.free(b) else |_| {}
        return e;
    };
    errdefer allocator.free(stdout_bytes);

    const stderr_bytes = stderr_res catch |e| {
        child.kill(io);
        return e;
    };
    errdefer allocator.free(stderr_bytes);

    const term = child.wait(io) catch return error.WaitFailed;
    const code = termToCode(term);

    return .{ .code = code, .stdout = stdout_bytes, .stderr = stderr_bytes };
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
) ChildError![]u8 {
    const file = pipe orelse return allocator.alloc(u8, 0) catch error.OutOfMemory;
    var read_buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buf);
    const r = &reader.interface;

    var captured: std.Io.Writer.Allocating = .init(allocator);
    errdefer captured.deinit();

    // Capture up to the cap. The allocating writer only fails on OOM.
    var room: usize = max_capture_bytes;
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
    _ = r.discardRemaining() catch return error.IoError;

    return captured.toOwnedSlice() catch error.OutOfMemory;
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

test "termToCode forwards the real exit code and sentinels abnormal terminations" {
    // The forwarded code is what `mt run`/brew-fallback surface to the shell.
    try std.testing.expectEqual(@as(u8, 0), termToCode(.{ .exited = 0 }));
    try std.testing.expectEqual(@as(u8, 1), termToCode(.{ .exited = 1 }));
    try std.testing.expectEqual(@as(u8, 42), termToCode(.{ .exited = 42 }));
    // A real exit code of 255 is forwarded verbatim — indistinguishable from
    // the abnormal-termination sentinel below, an inherent shell ambiguity.
    try std.testing.expectEqual(@as(u8, 255), termToCode(.{ .exited = 255 }));
    try std.testing.expectEqual(@as(u8, 255), termToCode(.{ .signal = .KILL }));
    try std.testing.expectEqual(@as(u8, 255), termToCode(.{ .stopped = .STOP }));
    try std.testing.expectEqual(@as(u8, 255), termToCode(.{ .unknown = 0 }));
}

// Capture-content tests (dual-stream, non-zero exit) live in
// `tests/child_test.zig`. They need a shell to drive stdout+stderr in
// one command, which the argv-only spawn invariant forbids under
// `src/**` — the invariant only scans src/, so the integration file
// is exempt.
