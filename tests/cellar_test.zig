//! malt — cellar module tests
//! Tests for keg materialization and directory flattening.

const std = @import("std");
const testing = std.testing;
const cellar_mod = @import("malt").cellar;

// libc setenv/unsetenv — available because tests link with libc
const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn setMaltPrefix(prefix: [:0]const u8) [:0]const u8 {
    const old = std.posix.getenv("MALT_PREFIX") orelse "";
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
    const path = try std.fmt.allocPrint(allocator, "/tmp/malt_cellar_test_{x}", .{std.crypto.random.int(u64)});
    defer allocator.free(path);
    const z = try allocator.allocSentinel(u8, path.len, 0);
    @memcpy(z, path);
    try std.fs.makeDirAbsolute(z);
    return z;
}

fn createBottleFixture(allocator: std.mem.Allocator, prefix: []const u8, sha: []const u8, name: []const u8, ver_dir: []const u8) !void {
    const keg = try std.fmt.allocPrint(allocator, "{s}/store/{s}/{s}/{s}", .{ prefix, sha, name, ver_dir });
    defer allocator.free(keg);
    try std.fs.cwd().makePath(keg);

    const bin_dir = try std.fmt.allocPrint(allocator, "{s}/bin", .{keg});
    defer allocator.free(bin_dir);
    try std.fs.makeDirAbsolute(bin_dir);

    const script_path = try std.fmt.allocPrint(allocator, "{s}/bin/hello", .{keg});
    defer allocator.free(script_path);
    {
        const f = try std.fs.createFileAbsolute(script_path, .{});
        try f.writeAll("#!/bin/sh\necho hello\n");
        f.close();
    }

    const lib_dir = try std.fmt.allocPrint(allocator, "{s}/lib", .{keg});
    defer allocator.free(lib_dir);
    try std.fs.makeDirAbsolute(lib_dir);
}

fn setupMaltDirs(allocator: std.mem.Allocator, prefix: []const u8) !void {
    const dirs = [_][]const u8{ "store", "Cellar", "opt", "bin", "lib" };
    for (dirs) |d| {
        const p = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, d });
        defer allocator.free(p);
        std.fs.cwd().makePath(p) catch {};
    }
}

// ---------------------------------------------------------------------------
// Bug-2 tests: keg directory flattening (revision suffix handling)
// ---------------------------------------------------------------------------

test "materialize handles version with revision suffix" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        std.fs.deleteTreeAbsolute(prefix) catch {};
        testing.allocator.free(prefix);
    }

    try setupMaltDirs(testing.allocator, prefix);
    try createBottleFixture(testing.allocator, prefix, "abc123", "pcre2", "10.47_1");

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    const keg = try cellar_mod.materializeWithCellar(
        testing.allocator,
        prefix,
        "abc123",
        "pcre2",
        "10.47",
        ":any",
    );
    defer testing.allocator.free(keg.path);

    // Verify flat structure: Cellar/pcre2/10.47/bin/hello should exist
    var bin_buf: [512]u8 = undefined;
    const bin_path = try std.fmt.bufPrint(&bin_buf, "{s}/bin/hello", .{keg.path});
    try std.fs.accessAbsolute(bin_path, .{});

    // Verify no extra nesting: Cellar/pcre2/10.47/pcre2/ should NOT exist
    var nested_buf: [512]u8 = undefined;
    const nested_path = try std.fmt.bufPrint(&nested_buf, "{s}/pcre2", .{keg.path});
    const nested_exists = blk: {
        std.fs.accessAbsolute(nested_path, .{}) catch break :blk false;
        break :blk true;
    };
    try testing.expect(!nested_exists);
}

test "materialize handles exact version match (no revision)" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        std.fs.deleteTreeAbsolute(prefix) catch {};
        testing.allocator.free(prefix);
    }

    try setupMaltDirs(testing.allocator, prefix);
    try createBottleFixture(testing.allocator, prefix, "def456", "jq", "1.7.1");

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    const keg = try cellar_mod.materializeWithCellar(
        testing.allocator,
        prefix,
        "def456",
        "jq",
        "1.7.1",
        ":any",
    );
    defer testing.allocator.free(keg.path);

    var buf: [512]u8 = undefined;
    const bin_path = try std.fmt.bufPrint(&buf, "{s}/bin/hello", .{keg.path});
    try std.fs.accessAbsolute(bin_path, .{});
}
