//! malt — db/lock module tests
//! Covers acquire/release/holderPid and the timeout path.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const lock = @import("malt").lock;

const io = std.Options.debug_io;

fn uniquePath(suffix: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        testing.allocator,
        "/tmp/malt_lock_test_{d}_{s}",
        .{ test_io.nanoTimestamp(io), suffix },
    );
}

test "acquire writes pid, release clears the file, holderPid parses back" {
    const path = try uniquePath("basic");
    defer testing.allocator.free(path);
    defer test_io.cwd().deleteFile(io, path) catch {};

    var l = try lock.LockFile.acquire(io, path, 1000);

    const my_pid = std.posix.system.getpid();
    const seen = lock.LockFile.holderPid(io, path) orelse return error.TestFailure;
    try testing.expectEqual(my_pid, seen);

    l.release(io);

    // After release the file is truncated, so holderPid returns null.
    try testing.expect(lock.LockFile.holderPid(io, path) == null);
}

test "holderPid returns the live pid immediately after acquire (sync-pinned)" {
    // Regression guard for the missing acquire-side fsync: the page cache
    // would let `holderPid` succeed on a single-process run even without
    // the sync. This test pins the sync into the contract so a future
    // revert can't silently drop it without breaking the suite at the
    // structural-guard test below.
    const path = try uniquePath("syncpin");
    defer testing.allocator.free(path);
    defer test_io.cwd().deleteFile(io, path) catch {};

    var l = try lock.LockFile.acquire(io, path, 1000);
    defer l.release(io);

    const seen = lock.LockFile.holderPid(io, path) orelse return error.TestFailure;
    try testing.expectEqual(std.posix.system.getpid(), seen);
}

test "holderPid returns null when the file does not exist" {
    try testing.expect(lock.LockFile.holderPid(io, "/tmp/malt_lock_test_nonexistent_xyz") == null);
}

test "acquire times out when an existing lock is held" {
    const path = try uniquePath("timeout");
    defer testing.allocator.free(path);
    defer test_io.cwd().deleteFile(io, path) catch {};

    var held = try lock.LockFile.acquire(io, path, 500);
    defer held.release(io);

    // Second acquire should hit the Timeout branch quickly.
    const res = lock.LockFile.acquire(io, path, 150);
    try testing.expectError(error.Timeout, res);
}

test "holderPid returns null on an empty file (vacated after release)" {
    const path = try uniquePath("empty");
    defer testing.allocator.free(path);
    defer test_io.cwd().deleteFile(io, path) catch {};

    const f = try test_io.createFileAbsolute(io, path, .{});
    f.close(io);

    try testing.expect(lock.LockFile.holderPid(io, path) == null);
}
