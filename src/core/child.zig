//! malt — shared spawn+wait helper for one-shot external commands.
//! Consolidates the Child.init/spawn/wait/switch shape that every
//! cask-install step used to duplicate, so the caller's allocator is
//! the single source of memory for every spawn.

const std = @import("std");
const fs_compat = @import("../fs/compat.zig");

pub const ChildError = error{
    SpawnFailed,
    WaitFailed,
    /// Child did not exit cleanly with code 0 — covers non-zero exits,
    /// signal kills, stops, and the "unknown" termination path.
    NonZeroExit,
};

/// Spawn `argv`, wait for it, and collapse the outcome into a narrow
/// error set. `allocator` backs argv/env dup and any pipe reads.
pub fn runOrFail(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) ChildError!void {
    var child = fs_compat.Child.init(argv, allocator);
    child.spawn() catch return error.SpawnFailed;
    const term = child.wait() catch return error.WaitFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.NonZeroExit,
        .signal, .stopped, .unknown => return error.NonZeroExit,
    }
}
