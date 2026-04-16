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

/// Stdout for user-visible output. Under the test runner the `--listen=-`
/// IPC owns fd 1, so redirect to stderr to keep the pipe pristine.
pub fn stdoutFile() std.Io.File {
    if (builtin.is_test) return std.Io.File.stderr();
    return std.Io.File.stdout();
}

pub fn stderrWriteAll(bytes: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(ctx(), bytes) catch return;
}

pub fn stdoutWriteAll(bytes: []const u8) void {
    stdoutFile().writeStreamingAll(ctx(), bytes) catch return;
}
