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

pub fn stderrWriteAll(bytes: []const u8) void {
    stderrFile().writeStreamingAll(ctx(), bytes) catch return;
}

pub fn stdoutWriteAll(bytes: []const u8) void {
    stdoutFile().writeStreamingAll(ctx(), bytes) catch return;
}
