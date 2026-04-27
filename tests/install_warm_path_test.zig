//! malt — warm-install path integration test.
//!
//! Exercises the install → uninstall → reinstall sequence at the cellar
//! level: the first materialize runs the full extract → patch → codesign
//! pipeline and snapshots the result; the second materialize must take
//! the relocated-cache short-circuit. We assert the short-circuit by
//! deleting the `store/<sha>/` source between the two calls, so the
//! pipeline path has nothing to work with — the only way the second
//! materialize can succeed is via the cache.

const std = @import("std");
const malt = @import("malt");
const testing = std.testing;
const cellar_mod = @import("malt").cellar;
const relocated = @import("malt").relocated_store;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

fn setMaltPrefix(prefix: [:0]const u8) [:0]const u8 {
    const old = malt.fs_compat.getenv("MALT_PREFIX") orelse "";
    _ = c.setenv("MALT_PREFIX", prefix.ptr, 1);
    return old;
}

fn restoreMaltPrefix(old: [:0]const u8) void {
    if (old.len == 0) {
        _ = c.unsetenv("MALT_PREFIX");
    } else {
        _ = c.setenv("MALT_PREFIX", old.ptr, 1);
    }
}

fn createTestDir(allocator: std.mem.Allocator) ![:0]const u8 {
    const path = try std.fmt.allocPrint(
        allocator,
        "/tmp/malt_warm_path_test_{x}",
        .{malt.fs_compat.randomInt(u64)},
    );
    defer allocator.free(path);
    const z = try allocator.allocSentinel(u8, path.len, 0);
    @memcpy(z, path);
    try malt.fs_compat.makeDirAbsolute(z);
    return z;
}

fn setupMaltDirs(allocator: std.mem.Allocator, prefix: []const u8) !void {
    const dirs = [_][]const u8{ "store", "Cellar", "opt", "bin", "lib" };
    for (dirs) |d| {
        const p = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, d });
        defer allocator.free(p);
        malt.fs_compat.cwd().makePath(p) catch {};
    }
}

fn createBottleFixture(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    sha: []const u8,
    name: []const u8,
    ver: []const u8,
) !void {
    const keg = try std.fmt.allocPrint(
        allocator,
        "{s}/store/{s}/{s}/{s}",
        .{ prefix, sha, name, ver },
    );
    defer allocator.free(keg);
    try malt.fs_compat.cwd().makePath(keg);

    const bin_dir = try std.fmt.allocPrint(allocator, "{s}/bin", .{keg});
    defer allocator.free(bin_dir);
    try malt.fs_compat.makeDirAbsolute(bin_dir);

    const script = try std.fmt.allocPrint(allocator, "{s}/bin/hello", .{keg});
    defer allocator.free(script);
    const f = try malt.fs_compat.createFileAbsolute(script, .{});
    defer f.close();
    try f.writeAll("#!/bin/sh\nprefix=@@HOMEBREW_PREFIX@@\n");
}

fn pathExists(path: []const u8) bool {
    malt.fs_compat.accessAbsolute(path, .{}) catch return false;
    return true;
}

const test_sha = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210";

test "install → uninstall → reinstall takes the relocated cache short-circuit" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
        testing.allocator.free(prefix);
    }
    try setupMaltDirs(testing.allocator, prefix);
    try createBottleFixture(testing.allocator, prefix, test_sha, "warmpkg", "1.0");

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    // First install: full pipeline runs; snapshot lands in the cache.
    {
        const keg = try cellar_mod.materializeWithCellar(
            testing.allocator,
            prefix,
            test_sha,
            "warmpkg",
            "1.0",
            ":any",
        );
        defer testing.allocator.free(keg.path);
    }
    try testing.expect(relocated.has(prefix, test_sha));

    // Uninstall: drop the Cellar tree so the next materialize has to rebuild.
    const cellar_keg = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/warmpkg/1.0", .{prefix});
    defer testing.allocator.free(cellar_keg);
    try malt.fs_compat.deleteTreeAbsolute(cellar_keg);
    try testing.expect(!pathExists(cellar_keg));

    // Now wipe the bottle store too. With both the Cellar entry and the
    // store/<sha> source gone, only a cache hit can satisfy a reinstall.
    const store_path = try std.fmt.allocPrint(testing.allocator, "{s}/store/{s}", .{ prefix, test_sha });
    defer testing.allocator.free(store_path);
    try malt.fs_compat.deleteTreeAbsolute(store_path);
    try testing.expect(!pathExists(store_path));

    // Reinstall: must succeed via the cache short-circuit alone.
    const keg = try cellar_mod.materializeWithCellar(
        testing.allocator,
        prefix,
        test_sha,
        "warmpkg",
        "1.0",
        ":any",
    );
    defer testing.allocator.free(keg.path);
    try testing.expect(pathExists(keg.path));

    var bin_buf: [512]u8 = undefined;
    const bin_path = try std.fmt.bufPrint(&bin_buf, "{s}/bin/hello", .{keg.path});
    try malt.fs_compat.accessAbsolute(bin_path, .{});
}

test "non-APFS-style cache miss still allows a successful pipeline reinstall" {
    // Simulate a cache that does not exist (e.g. ENOTSUP filesystem path
    // skipped the snapshot): both materializes run the full pipeline and
    // both must succeed end-to-end. This is the safety property — a flaky
    // cache must never break the install.
    const prefix = try createTestDir(testing.allocator);
    defer {
        malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
        testing.allocator.free(prefix);
    }
    try setupMaltDirs(testing.allocator, prefix);
    try createBottleFixture(testing.allocator, prefix, test_sha, "nocache", "0.1");

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    // First materialize.
    {
        const keg = try cellar_mod.materializeWithCellar(
            testing.allocator,
            prefix,
            test_sha,
            "nocache",
            "0.1",
            ":any",
        );
        defer testing.allocator.free(keg.path);
    }

    // Tamper with the cache so it cannot be hit on the second pass: drop
    // the relocated entry. The second materialize must still succeed via
    // the regular pipeline, and rebuild the cache afterwards.
    try relocated.remove(prefix, test_sha);
    try testing.expect(!relocated.has(prefix, test_sha));

    const cellar_keg = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/nocache/0.1", .{prefix});
    defer testing.allocator.free(cellar_keg);
    try malt.fs_compat.deleteTreeAbsolute(cellar_keg);

    const keg = try cellar_mod.materializeWithCellar(
        testing.allocator,
        prefix,
        test_sha,
        "nocache",
        "0.1",
        ":any",
    );
    defer testing.allocator.free(keg.path);
    // Pipeline rebuilt the keg AND restored the cache — warm reinstalls
    // are fast again.
    try testing.expect(relocated.has(prefix, test_sha));
}
