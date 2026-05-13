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

/// Spawn `argv` with stdout + stderr piped, wait, and return the
/// captured output alongside the exit code. Caller frees the buffers
/// via `RunReport.deinit`. Reads stdout then stderr; both pipes are
/// drained before `wait` so the child can't block on a full pipe.
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

    const stdout_bytes = drainPipe(io, allocator, child.stdout) catch |e| {
        // Best-effort cleanup — kill the child so wait doesn't hang on
        // a half-drained pipe, then surface the read failure.
        child.kill(io);
        return e;
    };
    errdefer allocator.free(stdout_bytes);

    const stderr_bytes = drainPipe(io, allocator, child.stderr) catch |e| {
        child.kill(io);
        return e;
    };
    errdefer allocator.free(stderr_bytes);

    const term = child.wait(io) catch return error.WaitFailed;
    const code: u8 = switch (term) {
        .exited => |c| c,
        .signal, .stopped, .unknown => 255,
    };

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

fn drainPipe(
    io: std.Io,
    allocator: std.mem.Allocator,
    pipe: ?std.Io.File,
) ChildError![]u8 {
    const file = pipe orelse return allocator.alloc(u8, 0) catch error.OutOfMemory;
    var read_buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buf);
    return reader.interface.allocRemaining(allocator, std.Io.Limit.limited(max_capture_bytes)) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.IoError,
    };
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

// Capture-content tests (dual-stream, non-zero exit) live in
// `tests/child_test.zig`. They need a shell to drive stdout+stderr in
// one command, which the argv-only spawn invariant forbids under
// `src/**` — the invariant only scans src/, so the integration file
// is exempt.
