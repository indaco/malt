//! malt — fs/atomic module tests
//! Covers MALT_PREFIX env handling, temp dir creation, and helper path builders.

const std = @import("std");
const testing = std.testing;
const atomic = @import("malt").atomic;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

fn setPrefix(v: [:0]const u8) void {
    _ = c.setenv("MALT_PREFIX", v.ptr, 1);
}
fn unsetPrefix() void {
    _ = c.unsetenv("MALT_PREFIX");
}
fn setCache(v: [:0]const u8) void {
    _ = c.setenv("MALT_CACHE", v.ptr, 1);
}
fn unsetCache() void {
    _ = c.unsetenv("MALT_CACHE");
}

test "maltPrefix returns default when env unset" {
    unsetPrefix();
    const got = atomic.maltPrefix();
    try testing.expectEqualStrings("/opt/malt", got);
}

test "maltPrefix honours MALT_PREFIX env var" {
    setPrefix("/tmp/malt_atomic_prefix_env");
    defer unsetPrefix();
    const got = atomic.maltPrefix();
    try testing.expectEqualStrings("/tmp/malt_atomic_prefix_env", got);
}

test "maltTmpDir composes {prefix}/tmp" {
    setPrefix("/tmp/malt_atomic_tmp_env");
    defer unsetPrefix();
    const path = try atomic.maltTmpDir(testing.allocator);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/tmp/malt_atomic_tmp_env/tmp", path);
}

test "maltDbDir composes {prefix}/db" {
    setPrefix("/tmp/malt_atomic_db_env");
    defer unsetPrefix();
    const path = try atomic.maltDbDir(testing.allocator);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/tmp/malt_atomic_db_env/db", path);
}

test "maltCacheDir falls back to {prefix}/cache when MALT_CACHE unset" {
    unsetCache();
    setPrefix("/tmp/malt_atomic_cache_fallback");
    defer unsetPrefix();
    const path = try atomic.maltCacheDir(testing.allocator);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/tmp/malt_atomic_cache_fallback/cache", path);
}

test "maltCacheDir honours MALT_CACHE env var" {
    setCache("/tmp/malt_atomic_cache_override");
    defer unsetCache();
    const path = try atomic.maltCacheDir(testing.allocator);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/tmp/malt_atomic_cache_override", path);
}

test "createTempDir creates a unique directory under the prefix and cleanup removes it" {
    const base = "/tmp/malt_atomic_ctmp";
    std.fs.deleteTreeAbsolute(base) catch {};
    std.fs.makeDirAbsolute(base) catch {};
    defer std.fs.deleteTreeAbsolute(base) catch {};
    setPrefix("/tmp/malt_atomic_ctmp");
    defer unsetPrefix();

    const dir = try atomic.createTempDir(testing.allocator, "label");
    defer testing.allocator.free(dir);

    // Must exist as an absolute dir under {prefix}/tmp/
    try testing.expect(std.mem.startsWith(u8, dir, "/tmp/malt_atomic_ctmp/tmp/label_"));
    var open_dir = try std.fs.openDirAbsolute(dir, .{});
    open_dir.close();

    atomic.cleanupTempDir(dir);
    try testing.expectError(error.FileNotFound, std.fs.openDirAbsolute(dir, .{}));
}

test "atomicRename moves a file within the same filesystem" {
    const base = "/tmp/malt_atomic_rename";
    std.fs.deleteTreeAbsolute(base) catch {};
    std.fs.makeDirAbsolute(base) catch {};
    defer std.fs.deleteTreeAbsolute(base) catch {};

    const src = "/tmp/malt_atomic_rename/src.txt";
    const dst = "/tmp/malt_atomic_rename/dst.txt";
    const f = try std.fs.createFileAbsolute(src, .{});
    try f.writeAll("payload");
    f.close();

    try atomic.atomicRename(src, dst);
    try testing.expectError(error.FileNotFound, std.fs.openFileAbsolute(src, .{}));

    const moved = try std.fs.openFileAbsolute(dst, .{});
    defer moved.close();
    var buf: [16]u8 = undefined;
    const n = try moved.readAll(&buf);
    try testing.expectEqualStrings("payload", buf[0..n]);
}

test "cleanupTempDir is a no-op on a non-existent path" {
    atomic.cleanupTempDir("/tmp/malt_atomic_nonexistent_12345");
}
