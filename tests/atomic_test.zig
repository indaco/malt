//! malt — fs/atomic module tests
//! Covers MALT_PREFIX env handling, temp dir creation, and helper path builders.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
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

/// Scratch tree under a process-unique base, so overlapping test runs cannot
/// wipe each other's fixtures.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    base: [:0]const u8,

    fn init(tag: []const u8) !Fixture {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const base = try test_io.uniqueTempPath(arena.allocator(), "atomic", tag);
        const base_z = try arena.allocator().dupeZ(u8, base);
        test_io.deleteTreeAbsolute(std.Options.debug_io, base_z) catch {};
        try test_io.cwd().createDirPath(std.Options.debug_io, base_z);
        return .{ .arena = arena, .base = base_z };
    }

    /// Absolute path to `sub` inside the fixture; valid until `deinit`.
    fn p(self: *Fixture, sub: []const u8) [:0]const u8 {
        return std.fmt.allocPrintSentinel(
            self.arena.allocator(),
            "{s}/{s}",
            .{ self.base, sub },
            0,
        ) catch @panic("OOM");
    }

    fn deinit(self: *Fixture) void {
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.base) catch {};
        self.arena.deinit();
    }
};

test "maltPrefixOrAbort returns default when env unset" {
    unsetPrefix();
    const got = atomic.maltPrefixOrAbort();
    try testing.expectEqualStrings("/opt/malt", got);
}

test "maltPrefixOrAbort honours MALT_PREFIX env var" {
    setPrefix("/tmp/malt_atomic_prefix_env");
    defer unsetPrefix();
    const got = atomic.maltPrefixOrAbort();
    try testing.expectEqualStrings("/tmp/malt_atomic_prefix_env", got);
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
    var fx = try Fixture.init("ctmp");
    defer fx.deinit();
    setPrefix(fx.base);
    defer unsetPrefix();

    const dir = try atomic.createTempDir(std.Options.debug_io, testing.allocator, "label");
    defer testing.allocator.free(dir);

    // Must exist as an absolute dir under {prefix}/tmp/
    try testing.expect(std.mem.startsWith(u8, dir, fx.p("tmp/label_")));
    var open_dir = try test_io.openDirAbsolute(std.Options.debug_io, dir, .{});
    open_dir.close(std.Options.debug_io);

    atomic.cleanupTempDir(std.Options.debug_io, dir);
    try testing.expectError(error.FileNotFound, test_io.openDirAbsolute(std.Options.debug_io, dir, .{}));
}

test "atomicRename moves a file within the same filesystem" {
    var fx = try Fixture.init("rename");
    defer fx.deinit();

    const src = fx.p("src.txt");
    const dst = fx.p("dst.txt");
    const f = try test_io.createFileAbsolute(std.Options.debug_io, src, .{});
    try f.writeStreamingAll(std.Options.debug_io, "payload");
    f.close(std.Options.debug_io);

    try atomic.atomicRename(std.Options.debug_io, testing.allocator, src, dst);
    try testing.expectError(error.FileNotFound, test_io.openFileAbsolute(std.Options.debug_io, src, .{}));

    const moved = try test_io.openFileAbsolute(std.Options.debug_io, dst, .{});
    defer moved.close(std.Options.debug_io);
    var buf: [16]u8 = undefined;
    const n = try moved.readPositionalAll(std.Options.debug_io, &buf, 0);
    try testing.expectEqualStrings("payload", buf[0..n]);
}

test "cleanupTempDir is a no-op on a non-existent path" {
    atomic.cleanupTempDir(std.Options.debug_io, "/tmp/malt_atomic_nonexistent_12345");
}

// atomicWriteFile: readers see either the old file or the full new
// file, never a partial write. These tests cover the observable
// contract — fresh path, overwrite, no stale tempfile, missing parent.
test "atomicWriteFile writes full payload to a fresh path" {
    var fx = try Fixture.init("write_fresh");
    defer fx.deinit();

    const dst = fx.p("cache.json");
    try atomic.atomicWriteFile(std.Options.debug_io, dst, "{\"formulae\":[]}");

    const f = try test_io.openFileAbsolute(std.Options.debug_io, dst, .{});
    defer f.close(std.Options.debug_io);
    var buf: [64]u8 = undefined;
    const n = try f.readPositionalAll(std.Options.debug_io, &buf, 0);
    try testing.expectEqualStrings("{\"formulae\":[]}", buf[0..n]);
}

test "atomicWriteFile replaces an existing file's contents in one step" {
    var fx = try Fixture.init("write_replace");
    defer fx.deinit();

    const dst = fx.p("cache.json");
    // Seed with old bytes so we can prove the replacement lands whole.
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, dst, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "OLD_PAYLOAD_THAT_SHOULD_VANISH");
    }

    try atomic.atomicWriteFile(std.Options.debug_io, dst, "NEW");

    const f = try test_io.openFileAbsolute(std.Options.debug_io, dst, .{});
    defer f.close(std.Options.debug_io);
    var buf: [64]u8 = undefined;
    const n = try f.readPositionalAll(std.Options.debug_io, &buf, 0);
    try testing.expectEqualStrings("NEW", buf[0..n]);
}

test "atomicWriteFile leaves no sibling .tmp files behind on success" {
    var fx = try Fixture.init("write_no_tmp");
    defer fx.deinit();

    const dst = fx.p("cache.json");
    try atomic.atomicWriteFile(std.Options.debug_io, dst, "payload");

    // Only `cache.json` must remain — a stale tempfile would accumulate
    // across calls and eventually blow up a user's cache dir.
    var dir = try test_io.openDirAbsolute(std.Options.debug_io, fx.base, .{ .iterate = true });
    defer dir.close(std.Options.debug_io);
    var iter = dir.iterate();
    var count: usize = 0;
    while (try iter.next(std.Options.debug_io)) |entry| {
        try testing.expectEqualStrings("cache.json", entry.name);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "atomicWriteFile surfaces FileNotFound when the parent dir is missing" {
    // Callers (`api.writeCache`) rely on this error to decide
    // whether their preceding makeDirAbsolute actually succeeded.
    const err = atomic.atomicWriteFile(
        std.Options.debug_io,
        "/tmp/malt_atomic_write_nodir_xxxxxx/cache.json",
        "payload",
    );
    try testing.expectError(error.FileNotFound, err);
}

// atomicReplaceFile: the rename publishes new content under the prior
// mode bits. Direct coverage so the helper's contract is pinned even
// when its only caller (the macho/patcher) is refactored.

test "atomicReplaceFile preserves the existing file's mode" {
    var fx = try Fixture.init("replace_preserve");
    defer fx.deinit();

    const dst = fx.p("wrapper");
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, dst, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "OLD");
        // 0o750 = unusual triple so a default-mode regression is unambiguous.
        try f.setPermissions(std.Options.debug_io, std.Io.File.Permissions.fromMode(0o750));
    }

    try atomic.atomicReplaceFile(std.Options.debug_io, dst, "NEW");

    const f = try test_io.openFileAbsolute(std.Options.debug_io, dst, .{});
    defer f.close(std.Options.debug_io);
    var buf: [8]u8 = undefined;
    const n = try f.readPositionalAll(std.Options.debug_io, &buf, 0);
    try testing.expectEqualStrings("NEW", buf[0..n]);

    const s = try f.stat(std.Options.debug_io);
    try testing.expectEqual(@as(std.posix.mode_t, 0o750), s.permissions.toMode() & 0o7777);
}

test "atomicReplaceFile writes a fresh file when dst is missing" {
    var fx = try Fixture.init("replace_fresh");
    defer fx.deinit();

    const dst = fx.p("new.txt");
    try atomic.atomicReplaceFile(std.Options.debug_io, dst, "hello");

    const f = try test_io.openFileAbsolute(std.Options.debug_io, dst, .{});
    defer f.close(std.Options.debug_io);
    var buf: [16]u8 = undefined;
    const n = try f.readPositionalAll(std.Options.debug_io, &buf, 0);
    try testing.expectEqualStrings("hello", buf[0..n]);
}

test "atomicReplaceFile leaves the original intact when staging fails" {
    // Root would bypass the 0o555 the test relies on to fail the rename.
    if (std.c.geteuid() == 0) return error.SkipZigTest;

    // Declared first so its deleteTree runs after the unlock defer below.
    var fx = try Fixture.init("replace_intact");
    defer fx.deinit();

    const dst = fx.p("wrapper");
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, dst, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "ORIGINAL");
    }

    // Lock the parent so the helper cannot stage a sibling tempfile.
    {
        var d = try test_io.openDirAbsolute(std.Options.debug_io, fx.base, .{});
        defer d.close(std.Options.debug_io);
        const handle: std.Io.File = .{ .handle = d.handle, .flags = .{ .nonblocking = false } };
        handle.setPermissions(std.Options.debug_io, std.Io.File.Permissions.fromMode(0o555)) catch return error.SkipZigTest;
    }
    defer {
        unlock: {
            var d = test_io.openDirAbsolute(std.Options.debug_io, fx.base, .{}) catch break :unlock;
            defer d.close(std.Options.debug_io);
            const handle: std.Io.File = .{ .handle = d.handle, .flags = .{ .nonblocking = false } };
            handle.setPermissions(std.Options.debug_io, std.Io.File.Permissions.fromMode(0o755)) catch {};
        }
    }

    // Whatever error the helper surfaces, the load-bearing invariant is
    // that the path still holds the original bytes afterwards.
    _ = atomic.atomicReplaceFile(std.Options.debug_io, dst, "NEW") catch {};

    {
        var d = try test_io.openDirAbsolute(std.Options.debug_io, fx.base, .{});
        defer d.close(std.Options.debug_io);
        const handle: std.Io.File = .{ .handle = d.handle, .flags = .{ .nonblocking = false } };
        try handle.setPermissions(std.Options.debug_io, std.Io.File.Permissions.fromMode(0o755));
    }

    const f = try test_io.openFileAbsolute(std.Options.debug_io, dst, .{});
    defer f.close(std.Options.debug_io);
    var buf: [16]u8 = undefined;
    const n = try f.readPositionalAll(std.Options.debug_io, &buf, 0);
    try testing.expectEqualStrings("ORIGINAL", buf[0..n]);
}

test "atomicRename moves a directory tree within the same filesystem" {
    var fx = try Fixture.init("rename_dir");
    defer fx.deinit();

    const src = fx.p("src");
    const dst = fx.p("dst");
    try test_io.makeDirAbsolute(std.Options.debug_io, src);

    // Put a file inside so an accidental copy+delete fallback would be
    // observable — a plain `rename(2)` on a same-FS directory must not
    // drop child entries.
    const child = fx.p("src/inner.txt");
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, child, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "payload");
    }

    try atomic.atomicRename(std.Options.debug_io, testing.allocator, src, dst);
    try testing.expectError(error.FileNotFound, test_io.openDirAbsolute(std.Options.debug_io, src, .{}));

    var moved = try test_io.openDirAbsolute(std.Options.debug_io, dst, .{});
    defer moved.close(std.Options.debug_io);
    const inner = try moved.openFile(std.Options.debug_io, "inner.txt", .{});
    defer inner.close(std.Options.debug_io);
    var buf: [16]u8 = undefined;
    const n = try inner.readPositionalAll(std.Options.debug_io, &buf, 0);
    try testing.expectEqualStrings("payload", buf[0..n]);
}
