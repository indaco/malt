//! Shared, exhaustive messaging for lock-acquisition failures.
//!
//! `DirMissing` is deliberately not handled here: a fresh prefix means
//! different things to different commands (upgrade: "nothing to upgrade";
//! uninstall: "package not installed"), so each caller handles it before
//! falling through to this common reporter.

const std = @import("std");
const output = @import("../ui/output.zig");
const lock = @import("../db/lock.zig");

/// Build the clear, actionable message for every lock failure other than
/// `DirMissing` into `buf` and return the written slice. `prefix` is the
/// install prefix, used to point the user at the exact `db/` directory
/// involved. Split from emission so callers on an injected output sink
/// (the install pipeline) report the same text as the global `output`.
pub fn acquireFailureMessage(buf: []u8, e: lock.LockError, prefix: []const u8) []const u8 {
    return switch (e) {
        // Callers must handle the fresh-prefix case themselves.
        error.DirMissing => unreachable,
        error.AccessDenied => std.fmt.bufPrint(
            buf,
            "Cannot write the malt lock under {s}/db — the directory exists but isn't writable. Fix ownership with: sudo chown -R \"$USER\" {s}",
            .{ prefix, prefix },
        ) catch "Cannot acquire the malt lock.",
        error.Timeout => std.fmt.bufPrint(
            buf,
            "Timed out waiting for the malt lock under {s}/db — another malt process is still running. Wait for it to finish, or run `mt doctor` to clear a stale lock.",
            .{prefix},
        ) catch "Cannot acquire the malt lock.",
        error.OpenFailed => std.fmt.bufPrint(
            buf,
            "Could not open the malt lock under {s}/db.",
            .{prefix},
        ) catch "Cannot acquire the malt lock.",
        error.WriteFailed => std.fmt.bufPrint(
            buf,
            "Took the malt lock under {s}/db but failed to record the process id.",
            .{prefix},
        ) catch "Cannot acquire the malt lock.",
    };
}

/// Emit a clear, actionable message for every lock failure other than
/// `DirMissing` on the global `output` channel.
pub fn reportAcquireFailure(e: lock.LockError, prefix: []const u8) void {
    var buf: [512]u8 = undefined;
    output.err("{s}", .{acquireFailureMessage(&buf, e, prefix)});
}

test "acquireFailureMessage distinguishes each non-DirMissing failure" {
    var buf: [512]u8 = undefined;
    const prefix = "/opt/malt";

    // AccessDenied points at the writability fix; the others name their cause.
    const denied = acquireFailureMessage(&buf, error.AccessDenied, prefix);
    try std.testing.expect(std.mem.indexOf(u8, denied, "isn't writable") != null);
    try std.testing.expect(std.mem.indexOf(u8, denied, prefix) != null);

    const timeout = acquireFailureMessage(&buf, error.Timeout, prefix);
    try std.testing.expect(std.mem.indexOf(u8, timeout, "another malt process") != null);

    const open = acquireFailureMessage(&buf, error.OpenFailed, prefix);
    try std.testing.expect(std.mem.indexOf(u8, open, "Could not open") != null);

    const write = acquireFailureMessage(&buf, error.WriteFailed, prefix);
    try std.testing.expect(std.mem.indexOf(u8, write, "process id") != null);
}

test "acquireFailureMessage degrades to a generic line when buf is too small" {
    // Each arm's `catch` fallback keeps the reporter total even on an
    // undersized buffer rather than dropping the diagnostic entirely.
    var tiny: [8]u8 = undefined;
    const msg = acquireFailureMessage(&tiny, error.Timeout, "/opt/malt");
    try std.testing.expectEqualStrings("Cannot acquire the malt lock.", msg);
}
