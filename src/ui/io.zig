//! Thin shim over `std.Options.debug_io` so call sites don't have to thread
//! an `Io` instance through every function signature during the 0.16
//! migration. Long-term the app should accept `std.process.Init` and pass
//! a real `Io` through the call graph.

const std = @import("std");
const builtin = @import("builtin");

/// Default process-wide Io used for stdout/stderr writes.
pub fn ctx() std.Io {
    return std.Options.debug_io;
}

/// Lazy `/dev/null` handle used to sink writes under the test runner. The
/// runner owns fd 1 for its IPC protocol, and dumps any captured stderr
/// next to a "failed command:" trailer — both swamp the summary with noise
/// when tests pass. Funneling user-visible writes here keeps runs quiet.
var test_sink_fd: std.atomic.Value(std.c.fd_t) = .init(-1);

fn testSink() std.Io.File {
    var current = test_sink_fd.load(.acquire);
    if (current < 0) {
        const fd = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) return std.Io.File.stderr();
        if (test_sink_fd.cmpxchgStrong(-1, fd, .release, .acquire)) |winner| {
            _ = std.c.close(fd);
            current = winner;
        } else {
            current = fd;
        }
    }
    return .{ .handle = current, .flags = .{ .nonblocking = false } };
}

/// Stdout for user-visible output. Non-test builds write to fd 1; tests
/// funnel to `/dev/null` — see `testSink`.
pub fn stdoutFile() std.Io.File {
    if (builtin.is_test) return testSink();
    return std.Io.File.stdout();
}

/// Stderr for log/diagnostic output. Non-test builds write to fd 2; tests
/// funnel to `/dev/null` — see `testSink`.
pub fn stderrFile() std.Io.File {
    if (builtin.is_test) return testSink();
    return std.Io.File.stderr();
}

/// Test-only stderr / stdout capture. Tests run sequentially in a binary,
/// so no lock; elided from release via `builtin.is_test` guards.
var capture_list: ?*std.ArrayList(u8) = null;
var capture_allocator: std.mem.Allocator = undefined;
var stdout_capture_list: ?*std.ArrayList(u8) = null;
var stdout_capture_allocator: std.mem.Allocator = undefined;

/// Test-only: redirect `stderrWriteAll` into `buf`. Pair with `endStderrCapture`.
pub fn beginStderrCapture(allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) void {
    if (!builtin.is_test) return;
    capture_list = buf;
    capture_allocator = allocator;
}

/// Test-only: stop redirecting `stderrWriteAll`.
pub fn endStderrCapture() void {
    if (!builtin.is_test) return;
    capture_list = null;
}

/// Test-only: redirect `stdoutWriteAll` into `buf`. Pair with `endStdoutCapture`.
/// Needed for asserting JSON-mode payloads that land on stdout.
pub fn beginStdoutCapture(allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) void {
    if (!builtin.is_test) return;
    stdout_capture_list = buf;
    stdout_capture_allocator = allocator;
}

pub fn endStdoutCapture() void {
    if (!builtin.is_test) return;
    stdout_capture_list = null;
}

pub fn stderrWriteAll(bytes: []const u8) void {
    if (builtin.is_test) {
        if (capture_list) |list| {
            // Test-only capture; OOM inside a test is a bug the test will surface elsewhere.
            list.appendSlice(capture_allocator, bytes) catch {};
            return;
        }
    }
    stderrFile().writeStreamingAll(ctx(), bytes) catch return;
}

pub fn stdoutWriteAll(bytes: []const u8) void {
    if (builtin.is_test) {
        if (stdout_capture_list) |list| {
            // Test-only capture; OOM inside a test is a bug the test will surface elsewhere.
            list.appendSlice(stdout_capture_allocator, bytes) catch {};
            return;
        }
    }
    stdoutFile().writeStreamingAll(ctx(), bytes) catch return;
}
