//! Shared, exhaustive messaging for lock-acquisition failures.
//!
//! `DirMissing` is deliberately not handled here: a fresh prefix means
//! different things to different commands (upgrade: "nothing to upgrade";
//! uninstall: "package not installed"), so each caller handles it before
//! falling through to this common reporter.

const std = @import("std");
const output = @import("../ui/output.zig");
const lock = @import("../db/lock.zig");

/// Emit a clear, actionable message for every lock failure other than
/// `DirMissing`. `prefix` is the install prefix, used to point the user at
/// the exact `db/` directory involved.
pub fn reportAcquireFailure(e: lock.LockError, prefix: []const u8) void {
    switch (e) {
        // Callers must handle the fresh-prefix case themselves.
        error.DirMissing => unreachable,
        error.AccessDenied => output.err(
            "Cannot write the malt lock under {s}/db — the directory exists but isn't writable. Fix ownership with: sudo chown -R \"$USER\" {s}",
            .{ prefix, prefix },
        ),
        error.Timeout => output.err(
            "Timed out waiting for the malt lock under {s}/db — another malt process is still running. Wait for it to finish, or run `mt doctor` to clear a stale lock.",
            .{prefix},
        ),
        error.OpenFailed => output.err(
            "Could not open the malt lock under {s}/db.",
            .{prefix},
        ),
        error.WriteFailed => output.err(
            "Took the malt lock under {s}/db but failed to record the process id.",
            .{prefix},
        ),
    }
}
