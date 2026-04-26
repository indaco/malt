//! malt — run command integration tests
//!
//! Pure parsing and path-formatting tests live inline in `src/cli/run.zig`.
//! This file covers the `--keep` cache lookup against a real on-disk layout.

const std = @import("std");
const malt = @import("malt");
const testing = std.testing;
const cli_run = malt.cli_run;

test "findCachedBinary returns the path when the cached binary exists" {
    const base = "/tmp/malt_run_keep_hit";
    malt.fs_compat.deleteTreeAbsolute(base) catch {};
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};

    const sha = "abc123";
    const pkg = "jq";
    const ver = "1.7.1";

    const bin_dir = try std.fmt.allocPrint(testing.allocator, "{s}/run/{s}/{s}/{s}/bin", .{ base, sha, pkg, ver });
    defer testing.allocator.free(bin_dir);
    try malt.fs_compat.cwd().makePath(bin_dir);

    const expected_bin = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ bin_dir, pkg });
    defer testing.allocator.free(expected_bin);
    const f = try malt.fs_compat.createFileAbsolute(expected_bin, .{});
    f.close();

    var probe_buf: [512]u8 = undefined;
    const cached = try cli_run.findCachedBinary(&probe_buf, base, sha, pkg, ver);
    try testing.expect(cached != null);
    try testing.expectEqualStrings(expected_bin, cached.?);
}

test "findCachedBinary reports miss when the cache is empty" {
    const base = "/tmp/malt_run_keep_miss";
    malt.fs_compat.deleteTreeAbsolute(base) catch {};
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};

    var probe_buf: [512]u8 = undefined;
    const cached = try cli_run.findCachedBinary(&probe_buf, base, "abc", "jq", "1.0");
    try testing.expect(cached == null);
}

// Locks down the property that a cached bottle for one SHA does NOT satisfy
// a probe for another SHA — guards against accidental cross-version reuse
// when an upstream rebuilds with the same `version` string.
test "findCachedBinary keys cache slot on sha256, not just pkg+version" {
    const base = "/tmp/malt_run_keep_sha_isolation";
    malt.fs_compat.deleteTreeAbsolute(base) catch {};
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};

    const sha_a = "aaa111";
    const sha_b = "bbb222";
    const pkg = "jq";
    const ver = "1.7.1";

    const bin_dir = try std.fmt.allocPrint(testing.allocator, "{s}/run/{s}/{s}/{s}/bin", .{ base, sha_a, pkg, ver });
    defer testing.allocator.free(bin_dir);
    try malt.fs_compat.cwd().makePath(bin_dir);
    const bin_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ bin_dir, pkg });
    defer testing.allocator.free(bin_path);
    const f = try malt.fs_compat.createFileAbsolute(bin_path, .{});
    f.close();

    var probe_buf: [512]u8 = undefined;
    const same_sha = try cli_run.findCachedBinary(&probe_buf, base, sha_a, pkg, ver);
    try testing.expect(same_sha != null);

    const other_sha = try cli_run.findCachedBinary(&probe_buf, base, sha_b, pkg, ver);
    try testing.expect(other_sha == null);
}

test "findCachedBinary requires the version directory to match" {
    const base = "/tmp/malt_run_keep_ver_isolation";
    malt.fs_compat.deleteTreeAbsolute(base) catch {};
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};

    const sha = "abc";
    const pkg = "jq";

    const bin_dir = try std.fmt.allocPrint(testing.allocator, "{s}/run/{s}/{s}/1.7.1/bin", .{ base, sha, pkg });
    defer testing.allocator.free(bin_dir);
    try malt.fs_compat.cwd().makePath(bin_dir);
    const bin_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ bin_dir, pkg });
    defer testing.allocator.free(bin_path);
    const f = try malt.fs_compat.createFileAbsolute(bin_path, .{});
    f.close();

    var probe_buf: [512]u8 = undefined;
    const wrong_ver = try cli_run.findCachedBinary(&probe_buf, base, sha, pkg, "2.0");
    try testing.expect(wrong_ver == null);
}

// Acquiring the same lock from a second handle within one process must
// time out (flock is per-process on the SAME fd path here, but separate
// LockFile.acquire calls open new fds, which on macOS/Linux contend).
test "LockFile blocks a second acquire on the same path" {
    const lock_path = "/tmp/malt_run_keep_lock_test.lock";
    malt.fs_compat.deleteFileAbsolute(lock_path) catch {};
    defer malt.fs_compat.deleteFileAbsolute(lock_path) catch {};

    var first = try malt.lock.LockFile.acquire(lock_path, 1_000);
    defer first.release();

    // Second acquire must time out within 200 ms while the first is held.
    try testing.expectError(
        error.Timeout,
        malt.lock.LockFile.acquire(lock_path, 200),
    );
}
