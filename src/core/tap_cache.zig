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

// ─── inline test scratch ──────────────────────────────────────────────

const dbg_io = std.Options.debug_io;

fn rmrf(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(dbg_io, path) catch {};
}

var scratch_seq: std.atomic.Value(u32) = .init(0);

/// Scratch tree under a process- and call-unique base. A wall-clock stamp is
/// not enough: two runs starting in the same millisecond collide and delete
/// each other's fixtures.
const Scratch = struct {
    arena: std.heap.ArenaAllocator,
    base: [:0]const u8,

    fn init(comptime tag: []const u8) !Scratch {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const base = try std.fmt.allocPrintSentinel(
            arena.allocator(),
            "/tmp/malt_" ++ tag ++ "_{d}_{d}",
            .{ std.c.getpid(), scratch_seq.fetchAdd(1, .monotonic) },
            0,
        );
        rmrf(base);
        return .{ .arena = arena, .base = base };
    }

    /// Absolute path to `sub` (leading slash included) inside the scratch
    /// tree; valid until `deinit`.
    fn p(self: *Scratch, sub: []const u8) [:0]const u8 {
        return std.fmt.allocPrintSentinel(
            self.arena.allocator(),
            "{s}{s}",
            .{ self.base, sub },
            0,
        ) catch @panic("OOM");
    }

    fn deinit(self: *Scratch) void {
        rmrf(self.base);
        self.arena.deinit();
    }
};

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
    var s = try Scratch.init("tap_cache_exists_absent");
    defer s.deinit();
    try std.testing.expect(!exists(io, s.base, "ab" ** 32, ".tar.gz"));
}

test "exists: returns true when SHA-keyed entry is on disk" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var s = try Scratch.init("tap_cache_exists_hit");
    defer s.deinit();
    const prefix = s.base;

    try std.Io.Dir.cwd().createDirPath(io, s.p("/cache"));
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

    var s = try Scratch.init("tap_cache_promote");
    defer s.deinit();
    const prefix = s.base;

    inline for ([_][]const u8{ "/tmp", "/cache" }) |sub| {
        try std.Io.Dir.cwd().createDirPath(io, s.p(sub));
    }

    const staging = s.p("/tmp/tap_download.9999.tar.gz");
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
    var s = try Scratch.init("tap_cache_bytes_absent");
    defer s.deinit();
    // Deliberately do not create <prefix>/cache/Tap.
    try std.testing.expectEqual(@as(u64, 0), bytesUnder(io, std.testing.allocator, s.base));
}

test "bytesUnder: sums regular file sizes under cache/Tap" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var s = try Scratch.init("tap_cache_bytes_sum");
    defer s.deinit();
    const prefix = s.base;

    // Production callers reach `ensureCacheDir` only after the
    // top-level `ensureDirs` has seeded `<prefix>/cache`; mirror
    // that here so the test pins the production invariant.
    try std.Io.Dir.cwd().createDirPath(io, s.p("/cache"));

    try ensureCacheDir(io, prefix);

    var entry_buf: [std.fs.max_path_bytes]u8 = undefined;
    const entry = try cachePath(&entry_buf, prefix, "00" ** 32, ".tar.gz");
    const f = try std.Io.Dir.createFileAbsolute(io, entry, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, "x" ** 256);

    try std.testing.expectEqual(@as(u64, 256), bytesUnder(io, std.testing.allocator, prefix));
}
