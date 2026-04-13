//! malt — db/lock module tests
//! Covers acquire/release/holderPid and the timeout path.

const std = @import("std");
const testing = std.testing;
const lock = @import("malt").lock;

fn uniquePath(suffix: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        testing.allocator,
        "/tmp/malt_lock_test_{d}_{s}",
        .{ std.time.nanoTimestamp(), suffix },
    );
}

test "acquire writes pid, release clears the file, holderPid parses back" {
    const path = try uniquePath("basic");
    defer testing.allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    var l = try lock.LockFile.acquire(path, 1000);

    const my_pid = std.c.getpid();
    const seen = lock.LockFile.holderPid(path) orelse return error.TestFailure;
    try testing.expectEqual(my_pid, seen);

    l.release();

    // After release the file is truncated, so holderPid returns null.
    try testing.expect(lock.LockFile.holderPid(path) == null);
}

test "holderPid returns null when the file does not exist" {
    try testing.expect(lock.LockFile.holderPid("/tmp/malt_lock_test_nonexistent_xyz") == null);
}

test "acquire times out when an existing lock is held" {
    const path = try uniquePath("timeout");
    defer testing.allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    var held = try lock.LockFile.acquire(path, 500);
    defer held.release();

    // Second acquire should hit the Timeout branch quickly.
    const res = lock.LockFile.acquire(path, 150);
    try testing.expectError(error.Timeout, res);
}

test "holderPid returns null on an empty file (vacated after release)" {
    const path = try uniquePath("empty");
    defer testing.allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    const f = try std.fs.createFileAbsolute(path, .{});
    f.close();

    try testing.expect(lock.LockFile.holderPid(path) == null);
}
