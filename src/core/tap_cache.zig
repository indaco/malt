//! Persistent cache for tap-formula archives. Layout:
//! `<prefix>/cache/Tap/<sha256>.<ext>`. Keyed by the .rb-declared
//! SHA so two archives can never collide on the filename; lifetime is
//! managed by `mt purge --cache` (age-based) and `mt doctor` (size
//! reporting). Sibling to the cask cache at `<prefix>/cache/Cask/`.

const std = @import("std");

/// Compose the canonical cache path for a tap archive. `ext` includes
/// the leading dot (e.g. `.tar.gz`, `.zip`). Pure: no filesystem
/// access; surfaces `NoSpaceLeft` on buffer overflow so the caller
/// can fail loud instead of stranding bytes at a truncated path.
pub fn cachePath(buf: []u8, prefix: []const u8, sha256: []const u8, ext: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/cache/Tap/{s}{s}", .{ prefix, sha256, ext });
}

/// Idempotent `mkdir -p` for `<prefix>/cache/Tap`. Safe across
/// concurrent installs — `PathAlreadyExists` is the expected hot
/// path and not an error.
pub fn ensureCacheDir(io: std.Io, prefix: []const u8) !void {
    var buf: [512]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, "{s}/cache/Tap", .{prefix});
    std.Io.Dir.createDirAbsolute(io, dir, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => return,
        else => return e,
    };
}

/// Single-`access` probe of the cache entry for `(sha256, ext)`. Hot
/// path for the "warm cache" short-circuit: a cache hit lets the
/// caller skip both the HTTP archive fetch and the SHA recomputation
/// (the filename IS the SHA).
pub fn exists(io: std.Io, prefix: []const u8, sha256: []const u8, ext: []const u8) bool {
    var buf: [512]u8 = undefined;
    const path = cachePath(&buf, prefix, sha256, ext) catch return false;
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

/// Atomically promote a freshly-written staging archive to its
/// permanent SHA-keyed cache slot. Returns the cache path on success.
/// The rename is the publish point: a crash mid-write leaves only the
/// pid-suffixed staging file (which `mt doctor` and the existing
/// `install_tap_tmp_cleanup` regression already wipe), never a half-
/// written archive at a permanent filename. Caller has already
/// SHA-verified the staging bytes.
pub fn promoteStagingToCache(
    io: std.Io,
    prefix: []const u8,
    sha256: []const u8,
    ext: []const u8,
    staging_path: []const u8,
    cache_path_buf: []u8,
) ![]const u8 {
    try ensureCacheDir(io, prefix);
    const cache_path = try cachePath(cache_path_buf, prefix, sha256, ext);
    // rename(2) is atomic on the same filesystem — staging + cache
    // live under the same `<prefix>` so this is the hot path.
    try std.Io.Dir.renameAbsolute(staging_path, cache_path, io);
    return cache_path;
}

/// Recursive byte sum under `<prefix>/cache/Tap`. Best-effort: any
/// I/O failure contributes zero so doctor's read stays infallible.
pub fn bytesUnder(io: std.Io, allocator: std.mem.Allocator, prefix: []const u8) u64 {
    var buf: [512]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&buf, "{s}/cache/Tap", .{prefix}) catch return 0;
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var walker = dir.walk(allocator) catch return 0;
    defer walker.deinit();
    var total: u64 = 0;
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const stat = std.Io.Dir.statFile(entry.dir, io, entry.basename, .{}) catch continue;
        total += stat.size;
    }
    return total;
}

test "cachePath: composes prefix/cache/Tap/<sha>.<ext>" {
    var buf: [256]u8 = undefined;
    const got = try cachePath(&buf, "/opt/h", "ab" ** 32, ".tar.gz");
    try std.testing.expectEqualStrings(
        "/opt/h/cache/Tap/" ++ ("ab" ** 32) ++ ".tar.gz",
        got,
    );
}

test "cachePath: surfaces NoSpaceLeft on buffer overflow" {
    // Truncating to a half-written path would later strand bytes at
    // the wrong location. Fail loud instead.
    var buf: [4]u8 = undefined;
    try std.testing.expectError(
        error.NoSpaceLeft,
        cachePath(&buf, "/opt/h", "ab" ** 32, ".tar.gz"),
    );
}

test "cachePath: distinct SHAs produce distinct paths" {
    // The SHA is the only collision-defeating component, so a
    // typo in the formatter that dropped it would fail this.
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    const p1 = try cachePath(&a, "/opt/h", "ab" ** 32, ".zip");
    const p2 = try cachePath(&b, "/opt/h", "cd" ** 32, ".zip");
    try std.testing.expect(!std.mem.eql(u8, p1, p2));
}

test "exists: returns false when cache dir absent" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const ts = std.Io.Clock.real.now(io).toNanoseconds();
    const prefix = try std.fmt.bufPrint(&buf, "/tmp/malt_tap_cache_exists_absent_{d}", .{ts});
    try std.testing.expect(!exists(io, prefix, "ab" ** 32, ".tar.gz"));
}

test "exists: returns true when SHA-keyed entry is on disk" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ts = std.Io.Clock.real.now(io).toNanoseconds();
    const prefix = try std.fmt.bufPrint(&path_buf, "/tmp/malt_tap_cache_exists_hit_{d}", .{ts});
    std.Io.Dir.cwd().deleteTree(io, prefix) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, prefix) catch {};

    var cache_parent_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_parent = try std.fmt.bufPrint(&cache_parent_buf, "{s}/cache", .{prefix});
    try std.Io.Dir.cwd().createDirPath(io, cache_parent);
    try ensureCacheDir(io, prefix);

    var entry_buf: [std.fs.max_path_bytes]u8 = undefined;
    const entry = try cachePath(&entry_buf, prefix, "cd" ** 32, ".zip");
    const f = try std.Io.Dir.createFileAbsolute(io, entry, .{});
    f.close(io);

    try std.testing.expect(exists(io, prefix, "cd" ** 32, ".zip"));
    try std.testing.expect(!exists(io, prefix, "ee" ** 32, ".zip"));
}

test "promoteStagingToCache: renames staging file to SHA-keyed slot" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ts = std.Io.Clock.real.now(io).toNanoseconds();
    const prefix = try std.fmt.bufPrint(&path_buf, "/tmp/malt_tap_cache_promote_{d}", .{ts});
    std.Io.Dir.cwd().deleteTree(io, prefix) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, prefix) catch {};

    inline for ([_][]const u8{ "/tmp", "/cache" }) |sub| {
        var b: [std.fs.max_path_bytes]u8 = undefined;
        const p = try std.fmt.bufPrint(&b, "{s}{s}", .{ prefix, sub });
        try std.Io.Dir.cwd().createDirPath(io, p);
    }

    var staging_buf: [std.fs.max_path_bytes]u8 = undefined;
    const staging = try std.fmt.bufPrint(&staging_buf, "{s}/tmp/tap_download.9999.tar.gz", .{prefix});
    {
        const f = try std.Io.Dir.createFileAbsolute(io, staging, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "payload-bytes");
    }

    var cache_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_path = try promoteStagingToCache(io, prefix, "aa" ** 32, ".tar.gz", staging, &cache_buf);

    var want_buf: [std.fs.max_path_bytes]u8 = undefined;
    const want = try cachePath(&want_buf, prefix, "aa" ** 32, ".tar.gz");
    try std.testing.expectEqualStrings(want, cache_path);

    // The rename moved the staging file; the source path must be gone.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, staging, .{}));
    try std.Io.Dir.accessAbsolute(io, cache_path, .{});
}

test "bytesUnder: returns 0 when cache dir is absent" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ts = std.Io.Clock.real.now(io).toNanoseconds();
    const prefix = try std.fmt.bufPrint(&path_buf, "/tmp/malt_tap_cache_bytes_absent_{d}", .{ts});
    // Deliberately do not create <prefix>/cache/Tap.
    try std.testing.expectEqual(@as(u64, 0), bytesUnder(io, std.testing.allocator, prefix));
}

test "bytesUnder: sums regular file sizes under cache/Tap" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ts = std.Io.Clock.real.now(io).toNanoseconds();
    const prefix = try std.fmt.bufPrint(&path_buf, "/tmp/malt_tap_cache_bytes_sum_{d}", .{ts});
    std.Io.Dir.cwd().deleteTree(io, prefix) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, prefix) catch {};

    // Production callers reach `ensureCacheDir` only after the
    // top-level `ensureDirs` has seeded `<prefix>/cache`; mirror
    // that here so the test pins the production invariant.
    var cache_parent_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_parent = try std.fmt.bufPrint(&cache_parent_buf, "{s}/cache", .{prefix});
    try std.Io.Dir.cwd().createDirPath(io, cache_parent);

    try ensureCacheDir(io, prefix);

    var entry_buf: [std.fs.max_path_bytes]u8 = undefined;
    const entry = try cachePath(&entry_buf, prefix, "00" ** 32, ".tar.gz");
    const f = try std.Io.Dir.createFileAbsolute(io, entry, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, "x" ** 256);

    try std.testing.expectEqual(@as(u64, 256), bytesUnder(io, std.testing.allocator, prefix));
}
