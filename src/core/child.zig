//! malt — shared spawn+wait helper for one-shot external commands.
//! Consolidates the Child.init/spawn/wait/switch shape that every
//! cask-install step used to duplicate, so the caller's allocator is
//! the single source of memory for every spawn.

const std = @import("std");

pub const ChildError = error{
    SpawnFailed,
    WaitFailed,
    /// Child did not exit cleanly with code 0 — covers non-zero exits,
    /// signal kills, stops, and the "unknown" termination path.
    NonZeroExit,
};

/// Spawn `argv`, wait for it, and collapse the outcome into a narrow
/// error set. `io` carries the parent `Environ` so PATH lookups for
/// programs like `hdiutil` resolve.
pub fn runOrFail(
    io: std.Io,
    argv: []const []const u8,
) ChildError!void {
    var child = std.process.spawn(io, .{ .argv = argv }) catch return error.SpawnFailed;
    const term = child.wait(io) catch return error.WaitFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.NonZeroExit,
        .signal, .stopped, .unknown => return error.NonZeroExit,
    }
}

test "runOrFail returns void on exit code 0" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const argv = [_][]const u8{"/usr/bin/true"};
    try runOrFail(threaded.io(), &argv);
}

test "runOrFail returns NonZeroExit on a non-zero exit" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const argv = [_][]const u8{"/usr/bin/false"};
    try std.testing.expectError(ChildError.NonZeroExit, runOrFail(threaded.io(), &argv));
}

test "runOrFail returns SpawnFailed when program does not exist" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const argv = [_][]const u8{"/nonexistent/binary/malt_child_test"};
    try std.testing.expectError(ChildError.SpawnFailed, runOrFail(threaded.io(), &argv));
}
