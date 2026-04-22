//! malt — db/lock module tests
//! Covers acquire/release/holderPid and the timeout path.

const std = @import("std");
const malt = @import("malt");
const testing = std.testing;
const lock = @import("malt").lock;

fn uniquePath(suffix: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        testing.allocator,
        "/tmp/malt_lock_test_{d}_{s}",
        .{ malt.fs_compat.nanoTimestamp(), suffix },
    );
}

test "acquire writes pid, release clears the file, holderPid parses back" {
    const path = try uniquePath("basic");
    defer testing.allocator.free(path);
    defer malt.fs_compat.cwd().deleteFile(path) catch {};

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
    defer malt.fs_compat.cwd().deleteFile(path) catch {};

    var held = try lock.LockFile.acquire(path, 500);
    defer held.release();

    // Second acquire should hit the Timeout branch quickly.
    const res = lock.LockFile.acquire(path, 150);
    try testing.expectError(error.Timeout, res);
}

test "holderPid returns null on an empty file (vacated after release)" {
    const path = try uniquePath("empty");
    defer testing.allocator.free(path);
    defer malt.fs_compat.cwd().deleteFile(path) catch {};

    const f = try malt.fs_compat.createFileAbsolute(path, .{});
    f.close();

    try testing.expect(lock.LockFile.holderPid(path) == null);
}

test "classifyFlockErrno: EAGAIN retries later" {
    try testing.expectEqual(lock.FlockOutcome.retry_later, lock.classifyFlockErrno(.AGAIN));
}

test "classifyFlockErrno: EINTR signals interruption" {
    try testing.expectEqual(lock.FlockOutcome.interrupted, lock.classifyFlockErrno(.INTR));
}

test "classifyFlockErrno: ENOLCK is a distinct resource-exhausted outcome" {
    try testing.expectEqual(lock.FlockOutcome.resource_exhausted, lock.classifyFlockErrno(.NOLCK));
}

test "classifyFlockErrno: unrelated errno falls through to open_failed" {
    try testing.expectEqual(lock.FlockOutcome.open_failed, lock.classifyFlockErrno(.BADF));
    try testing.expectEqual(lock.FlockOutcome.open_failed, lock.classifyFlockErrno(.INVAL));
}

test "LockError exposes a distinct LockResourceExhausted tag" {
    const err: lock.LockError = error.LockResourceExhausted;
    try testing.expect(err == error.LockResourceExhausted);
}

test "MAX_EINTR_RETRIES is bounded" {
    try testing.expect(lock.MAX_EINTR_RETRIES > 0);
    try testing.expect(lock.MAX_EINTR_RETRIES <= 16);
}

test "nextAcquireStep: rc == 0 means acquired regardless of other state" {
    try testing.expectEqual(lock.AcquireStep.acquired, lock.nextAcquireStep(.{
        .rc = 0,
        .errno = .SUCCESS,
        .elapsed_ns = 0,
        .deadline_ns = 1_000,
        .eintr_retries = 0,
    }));
}

test "nextAcquireStep: EAGAIN within the deadline sleeps and retries" {
    try testing.expectEqual(lock.AcquireStep.sleep_and_retry, lock.nextAcquireStep(.{
        .rc = -1,
        .errno = .AGAIN,
        .elapsed_ns = 100,
        .deadline_ns = 1_000,
        .eintr_retries = 0,
    }));
}

test "nextAcquireStep: EAGAIN past the deadline is a Timeout" {
    try testing.expectEqual(lock.AcquireStep.timeout, lock.nextAcquireStep(.{
        .rc = -1,
        .errno = .AGAIN,
        .elapsed_ns = 1_000,
        .deadline_ns = 1_000,
        .eintr_retries = 0,
    }));
}

test "nextAcquireStep: EINTR under the cap retries immediately" {
    try testing.expectEqual(lock.AcquireStep.retry_interrupted, lock.nextAcquireStep(.{
        .rc = -1,
        .errno = .INTR,
        .elapsed_ns = 0,
        .deadline_ns = 1_000,
        .eintr_retries = lock.MAX_EINTR_RETRIES - 1,
    }));
}

test "nextAcquireStep: EINTR at the cap gives up" {
    try testing.expectEqual(lock.AcquireStep.interrupted_exhausted, lock.nextAcquireStep(.{
        .rc = -1,
        .errno = .INTR,
        .elapsed_ns = 0,
        .deadline_ns = 1_000,
        .eintr_retries = lock.MAX_EINTR_RETRIES,
    }));
}

test "nextAcquireStep: ENOLCK surfaces resource exhaustion" {
    try testing.expectEqual(lock.AcquireStep.resource_exhausted, lock.nextAcquireStep(.{
        .rc = -1,
        .errno = .NOLCK,
        .elapsed_ns = 0,
        .deadline_ns = 1_000,
        .eintr_retries = 0,
    }));
}

test "nextAcquireStep: unclassified errno is a hard open failure" {
    try testing.expectEqual(lock.AcquireStep.open_failed, lock.nextAcquireStep(.{
        .rc = -1,
        .errno = .BADF,
        .elapsed_ns = 0,
        .deadline_ns = 1_000,
        .eintr_retries = 0,
    }));
}
