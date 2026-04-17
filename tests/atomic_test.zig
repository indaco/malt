//! malt — fs/atomic module tests
//! Covers MALT_PREFIX env handling, temp dir creation, and helper path builders.

const std = @import("std");
const malt = @import("malt");
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

// ────────────────────────────────────────────────────────────────────
// validatePrefix — pure-function tests, exhaustive over the error set.
// maltPrefixChecked() is exercised via these + the env-based tests
// above, which establish the happy path through the same validator.
// ────────────────────────────────────────────────────────────────────

test "validatePrefix: default path is accepted" {
    try atomic.validatePrefix("/opt/malt");
}

test "validatePrefix: tmp sandbox prefix is accepted" {
    try atomic.validatePrefix("/tmp/malt_test_prefix");
}

test "validatePrefix: root '/' is accepted" {
    // Root alone is technically absolute and has no bad components; we
    // don't get to veto unusual-but-syntactically-valid prefixes.
    try atomic.validatePrefix("/");
}

test "validatePrefix: trailing slash is tolerated" {
    try atomic.validatePrefix("/opt/malt/");
}

test "validatePrefix: empty string rejected" {
    try testing.expectError(error.Empty, atomic.validatePrefix(""));
}

test "validatePrefix: relative path rejected" {
    try testing.expectError(error.NotAbsolute, atomic.validatePrefix("opt/malt"));
    try testing.expectError(error.NotAbsolute, atomic.validatePrefix("./malt"));
    try testing.expectError(error.NotAbsolute, atomic.validatePrefix("malt"));
}

test "validatePrefix: .. component rejected" {
    try testing.expectError(error.DotDotComponent, atomic.validatePrefix("/opt/../etc"));
    try testing.expectError(error.DotDotComponent, atomic.validatePrefix("/.."));
    try testing.expectError(error.DotDotComponent, atomic.validatePrefix("/opt/malt/.."));
}

test "validatePrefix: NUL byte rejected" {
    try testing.expectError(error.EmbeddedNul, atomic.validatePrefix("/opt/\x00malt"));
    try testing.expectError(error.EmbeddedNul, atomic.validatePrefix("/opt/malt\x00"));
}

test "validatePrefix: length > MAX_PREFIX_LEN rejected" {
    var buf: [atomic.MAX_PREFIX_LEN + 1]u8 = undefined;
    @memset(&buf, 'a');
    buf[0] = '/';
    try testing.expectError(error.TooLong, atomic.validatePrefix(&buf));
}

test "validatePrefix: length == MAX_PREFIX_LEN accepted" {
    var buf: [atomic.MAX_PREFIX_LEN]u8 = undefined;
    @memset(&buf, 'a');
    buf[0] = '/';
    try atomic.validatePrefix(&buf);
}

test "validatePrefix: '//' inside rejected" {
    try testing.expectError(error.EmptyComponent, atomic.validatePrefix("/opt//malt"));
    try testing.expectError(error.EmptyComponent, atomic.validatePrefix("//opt/malt"));
}

test "validatePrefix: single dot component is permitted (not our job to canonicalise)" {
    // A lone `.` is a valid filesystem path component; we only reject
    // the traversal primitive `..`. Keeping this permissive avoids
    // surprising users on paths like /opt/./malt.
    try atomic.validatePrefix("/opt/./malt");
}

test "validatePrefix: dotdot-like-but-not-exact component accepted" {
    // Make sure we don't over-match on .. — names like `foo..bar` are
    // not path traversal.
    try atomic.validatePrefix("/opt/foo..bar");
    try atomic.validatePrefix("/opt/..malt");
    try atomic.validatePrefix("/opt/malt..");
}

test "maltPrefixChecked: empty MALT_PREFIX returns Empty error" {
    setPrefix("");
    defer unsetPrefix();
    try testing.expectError(error.Empty, atomic.maltPrefixChecked());
}

test "maltPrefixChecked: traversal MALT_PREFIX returns DotDotComponent" {
    setPrefix("/tmp/malt/../etc");
    defer unsetPrefix();
    try testing.expectError(error.DotDotComponent, atomic.maltPrefixChecked());
}

test "maltPrefixChecked: relative MALT_PREFIX returns NotAbsolute" {
    setPrefix("relative/path");
    defer unsetPrefix();
    try testing.expectError(error.NotAbsolute, atomic.maltPrefixChecked());
}

test "maltPrefixChecked: unset returns default" {
    unsetPrefix();
    const got = try atomic.maltPrefixChecked();
    try testing.expectEqualStrings("/opt/malt", got);
}

test "describePrefixError: every error has a descriptive string" {
    // Compile-time-ish coverage: every arm of the switch must return
    // something non-empty so error output is useful.
    const cases = [_]atomic.PrefixError{
        error.Empty,
        error.NotAbsolute,
        error.DotDotComponent,
        error.EmbeddedNul,
        error.TooLong,
        error.EmptyComponent,
    };
    for (cases) |e| {
        const desc = atomic.describePrefixError(e);
        try testing.expect(desc.len > 0);
    }
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
    malt.fs_compat.deleteTreeAbsolute(base) catch {};
    malt.fs_compat.makeDirAbsolute(base) catch {};
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};
    setPrefix("/tmp/malt_atomic_ctmp");
    defer unsetPrefix();

    const dir = try atomic.createTempDir(testing.allocator, "label");
    defer testing.allocator.free(dir);

    // Must exist as an absolute dir under {prefix}/tmp/
    try testing.expect(std.mem.startsWith(u8, dir, "/tmp/malt_atomic_ctmp/tmp/label_"));
    var open_dir = try malt.fs_compat.openDirAbsolute(dir, .{});
    open_dir.close();

    atomic.cleanupTempDir(dir);
    try testing.expectError(error.FileNotFound, malt.fs_compat.openDirAbsolute(dir, .{}));
}

test "atomicRename moves a file within the same filesystem" {
    const base = "/tmp/malt_atomic_rename";
    malt.fs_compat.deleteTreeAbsolute(base) catch {};
    malt.fs_compat.makeDirAbsolute(base) catch {};
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};

    const src = "/tmp/malt_atomic_rename/src.txt";
    const dst = "/tmp/malt_atomic_rename/dst.txt";
    const f = try malt.fs_compat.createFileAbsolute(src, .{});
    try f.writeAll("payload");
    f.close();

    try atomic.atomicRename(src, dst);
    try testing.expectError(error.FileNotFound, malt.fs_compat.openFileAbsolute(src, .{}));

    const moved = try malt.fs_compat.openFileAbsolute(dst, .{});
    defer moved.close();
    var buf: [16]u8 = undefined;
    const n = try moved.readAll(&buf);
    try testing.expectEqualStrings("payload", buf[0..n]);
}

test "cleanupTempDir is a no-op on a non-existent path" {
    atomic.cleanupTempDir("/tmp/malt_atomic_nonexistent_12345");
}

// atomicWriteFile: readers see either the old file or the full new
// file, never a partial write. These tests cover the observable
// contract — fresh path, overwrite, no stale tempfile, missing parent.
test "atomicWriteFile writes full payload to a fresh path" {
    const base = "/tmp/malt_atomic_write_fresh";
    malt.fs_compat.deleteTreeAbsolute(base) catch {};
    try malt.fs_compat.makeDirAbsolute(base);
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};

    const dst = base ++ "/cache.json";
    try atomic.atomicWriteFile(dst, "{\"formulae\":[]}");

    const f = try malt.fs_compat.openFileAbsolute(dst, .{});
    defer f.close();
    var buf: [64]u8 = undefined;
    const n = try f.readAll(&buf);
    try testing.expectEqualStrings("{\"formulae\":[]}", buf[0..n]);
}

test "atomicWriteFile replaces an existing file's contents in one step" {
    const base = "/tmp/malt_atomic_write_replace";
    malt.fs_compat.deleteTreeAbsolute(base) catch {};
    try malt.fs_compat.makeDirAbsolute(base);
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};

    const dst = base ++ "/cache.json";
    // Seed with old bytes so we can prove the replacement lands whole.
    {
        const f = try malt.fs_compat.createFileAbsolute(dst, .{});
        defer f.close();
        try f.writeAll("OLD_PAYLOAD_THAT_SHOULD_VANISH");
    }

    try atomic.atomicWriteFile(dst, "NEW");

    const f = try malt.fs_compat.openFileAbsolute(dst, .{});
    defer f.close();
    var buf: [64]u8 = undefined;
    const n = try f.readAll(&buf);
    try testing.expectEqualStrings("NEW", buf[0..n]);
}

test "atomicWriteFile leaves no sibling .tmp files behind on success" {
    const base = "/tmp/malt_atomic_write_no_tmp";
    malt.fs_compat.deleteTreeAbsolute(base) catch {};
    try malt.fs_compat.makeDirAbsolute(base);
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};

    const dst = base ++ "/cache.json";
    try atomic.atomicWriteFile(dst, "payload");

    // Only `cache.json` must remain — a stale tempfile would accumulate
    // across calls and eventually blow up a user's cache dir.
    var dir = try malt.fs_compat.openDirAbsolute(base, .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();
    var count: usize = 0;
    while (try iter.next()) |entry| {
        try testing.expectEqualStrings("cache.json", entry.name);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "atomicWriteFile surfaces FileNotFound when the parent dir is missing" {
    // Callers (`api.writeCache`) rely on this error to decide
    // whether their preceding makeDirAbsolute actually succeeded.
    const err = atomic.atomicWriteFile(
        "/tmp/malt_atomic_write_nodir_xxxxxx/cache.json",
        "payload",
    );
    try testing.expectError(error.FileNotFound, err);
}

test "atomicRename moves a directory tree within the same filesystem" {
    const base = "/tmp/malt_atomic_rename_dir";
    malt.fs_compat.deleteTreeAbsolute(base) catch {};
    malt.fs_compat.makeDirAbsolute(base) catch {};
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};

    const src = "/tmp/malt_atomic_rename_dir/src";
    const dst = "/tmp/malt_atomic_rename_dir/dst";
    try malt.fs_compat.makeDirAbsolute(src);

    // Put a file inside so an accidental copy+delete fallback would be
    // observable — a plain `rename(2)` on a same-FS directory must not
    // drop child entries.
    const child = "/tmp/malt_atomic_rename_dir/src/inner.txt";
    {
        const f = try malt.fs_compat.createFileAbsolute(child, .{});
        defer f.close();
        try f.writeAll("payload");
    }

    try atomic.atomicRename(src, dst);
    try testing.expectError(error.FileNotFound, malt.fs_compat.openDirAbsolute(src, .{}));

    var moved = try malt.fs_compat.openDirAbsolute(dst, .{});
    defer moved.close();
    const inner = try moved.openFile("inner.txt", .{});
    defer inner.close();
    var buf: [16]u8 = undefined;
    const n = try inner.readAll(&buf);
    try testing.expectEqualStrings("payload", buf[0..n]);
}
