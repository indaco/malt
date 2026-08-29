const std = @import("std");
const clonefile = @import("clonefile.zig");
const prefix_path = @import("prefix_path.zig");

/// Re-exported from `fs/prefix_path.zig`, which owns the prefix bound, its
/// charset and its validator alongside the path-join buffer size.
pub const max_prefix_len = prefix_path.max_prefix_len;

/// Charset for a formula `name` or `version`. Same alphabet as
/// `prefix_path.isAllowedPrefixByte`
/// minus `/` (a name with `/` would pierce a `{prefix}/Cellar/{name}/...`
/// path) plus `@` (versioned formulae like `llvm@21`, `python@3.12`).
pub fn isAllowedNameByte(b: u8) bool {
    return switch (b) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '+', '-', '@' => true,
        else => false,
    };
}

/// Direct getenv from `std.c.environ`; the prefix/cache helpers are read at
/// process startup so tying them to the parent block keeps the API
/// arg-free without re-introducing a `fs/compat` shim dep.
fn getenvLocal(name: []const u8) ?[:0]const u8 {
    var n: usize = 0;
    while (std.c.environ[n] != null) : (n += 1) {}
    const slice: [:null]const ?[*:0]const u8 = @ptrCast(std.c.environ[0..n :null]);
    const env: std.process.Environ = .{ .block = .{ .slice = slice } };
    return std.process.Environ.getPosix(env, name);
}

/// Validated form of `maltPrefixOrAbort`, returns an error on bad env so tests
/// can inspect the failure without the process exiting.
pub fn maltPrefixChecked() prefix_path.PrefixError![:0]const u8 {
    const raw = getenvLocal("MALT_PREFIX") orelse return "/opt/malt";
    try prefix_path.validatePrefix(raw);
    return raw;
}

/// Install prefix with a fail-closed env check. A malformed MALT_PREFIX
/// is a startup misconfig or traversal attempt — abort loudly rather
/// than falling back silently. Callers that hold an AppCtx and want to
/// surface the error should use `maltPrefixChecked` instead.
pub fn maltPrefixOrAbort() [:0]const u8 {
    return maltPrefixChecked() catch |e| {
        const raw = getenvLocal("MALT_PREFIX") orelse "<unset>";
        // Bypass the UI layer — atomic.zig sits below it in the dep graph.
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "malt: refusing to use MALT_PREFIX='{s}': {s}\n",
            .{ raw, prefix_path.describePrefixError(e) },
        ) catch "malt: MALT_PREFIX rejected; refusing to proceed\n";
        _ = std.c.write(std.c.STDERR_FILENO, msg.ptr, msg.len);
        std.process.exit(78); // EX_CONFIG
    };
}

/// Rename `src_path` to `dst_path`. Tries a single `rename(2)` first — the
/// atomic, crash-safe path that every caller wants on the happy case. If
/// the kernel returns EXDEV (src and dst live on different filesystems,
/// which `rename(2)` cannot span) we fall back to a clone-or-copy of the
/// tree followed by removal of the source. The fallback is not atomic
/// from a crash standpoint, but the end state (dst present, src absent)
/// matches `rename` semantics; a crash mid-way leaves the tmp source
/// intact for the next housekeeping sweep to clean up.
pub fn atomicRename(io: std.Io, allocator: std.mem.Allocator, src_path: []const u8, dst_path: []const u8) !void {
    std.Io.Dir.renameAbsolute(src_path, dst_path, io) catch |e| switch (e) {
        error.CrossDevice => {
            try clonefile.cloneTree(io, allocator, src_path, dst_path);
            // Source cleanup after a successful cross-device clone; a leftover
            // src is tolerable and gets reaped by the next housekeeping sweep.
            std.Io.Dir.cwd().deleteTree(io, src_path) catch {};
        },
        else => return e,
    };
}

/// Real fsync ops; inline tests pass a mock with the same shape so they can
/// observe fsync was issued without a syscall tracer.
const DefaultSyncOps = struct {
    fn syncFile(_: @This(), io: std.Io, f: std.Io.File) !void {
        return f.sync(io);
    }
    fn syncDir(_: @This(), io: std.Io, d: std.Io.Dir) !void {
        const file: std.Io.File = .{ .handle = d.handle, .flags = .{ .nonblocking = false } };
        return file.sync(io);
    }
};

const default_sync_ops: DefaultSyncOps = .{};

/// Write `data` to `dst_path` via a uniquely-named sibling tempfile
/// and a single `rename(2)`. Readers see either the old contents or
/// the new ones — never a partial write. A crash before the rename
/// leaves the tempfile behind; the next call writes its own and
/// overwrites atomically.
///
/// Preconditions: `dst_path` must be absolute and its parent directory must
/// already exist (the tempfile is a sibling and the parent is fsync'd). For an
/// arbitrary user-supplied path that may need parents created, use
/// `fs/path_write.zig` instead (non-atomic).
pub fn atomicWriteFile(io: std.Io, dst_path: []const u8, data: []const u8) !void {
    return atomicWriteFileImpl(io, dst_path, data, default_sync_ops, .default_file, .umask);
}

/// Atomic write that publishes `data` under an explicit mode, for content
/// whose permissions are part of its contract rather than inherited from
/// whatever was there before or from the caller's umask. Set at create time
/// so the rename stays the only observable transition.
pub fn atomicWriteFileMode(
    io: std.Io,
    dst_path: []const u8,
    data: []const u8,
    permissions: std.Io.File.Permissions,
) !void {
    return atomicWriteFileImpl(io, dst_path, data, default_sync_ops, permissions, .exact);
}

/// Atomic write that publishes `data` under the existing file's
/// permissions. The tempfile is created with the snapshotted mode so
/// the rename itself is the single observable transition — no window
/// where the new file carries the platform default. Use this when
/// overwriting a live file whose mode bits (exec on shebangs, libtool
/// archives, pkgconfig fragments) must survive the swap. A missing
/// `dst_path` falls back to the platform default, matching
/// `atomicWriteFile`.
pub fn atomicReplaceFile(io: std.Io, dst_path: []const u8, data: []const u8) !void {
    const perms: std.Io.File.Permissions = blk: {
        const existing = std.Io.Dir.openFileAbsolute(io, dst_path, .{}) catch break :blk .default_file;
        defer existing.close(io);
        const s = existing.stat(io) catch break :blk .default_file;
        break :blk s.permissions;
    };
    return atomicWriteFileImpl(io, dst_path, data, default_sync_ops, perms, .umask);
}

fn atomicWriteFileImpl(
    io: std.Io,
    dst_path: []const u8,
    data: []const u8,
    sync_ops: anytype,
    permissions: std.Io.File.Permissions,
    /// `open(2)` masks the requested mode with the caller's umask. `.exact`
    /// chmods it back before the rename publishes the file, for content whose
    /// permissions are a contract; `.umask` keeps the platform behaviour every
    /// other caller expects.
    mode_policy: enum { umask, exact },
) !void {
    var rand_bytes: [4]u8 = undefined;
    std.c.arc4random_buf(&rand_bytes, rand_bytes.len);
    const hex = std.fmt.bytesToHex(rand_bytes, .lower);

    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.{s}.tmp", .{ dst_path, &hex }) catch
        return error.NameTooLong;

    {
        const f = try std.Io.Dir.createFileAbsolute(io, tmp_path, .{
            .truncate = true,
            .permissions = permissions,
        });
        defer f.close(io);
        // Drop the tempfile on any failure before rename publishes it.
        errdefer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
        if (mode_policy == .exact) try f.setPermissions(io, permissions);
        try f.writeStreamingAll(io, data);
        // fsync before close so the bytes are durable BEFORE rename publishes them.
        try sync_ops.syncFile(io, f);
    }

    {
        // rename failure leaves the tempfile at the original name; clean it up.
        errdefer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
        try std.Io.Dir.renameAbsolute(tmp_path, dst_path, io);
    }

    // fsync the parent dir so the renamed dirent itself survives a kernel crash.
    const parent = std.fs.path.dirname(dst_path) orelse "/";
    var parent_dir = try std.Io.Dir.openDirAbsolute(io, parent, .{});
    defer parent_dir.close(io);
    try sync_ops.syncDir(io, parent_dir);
}

/// Create a temporary directory under {prefix}/tmp/ with the given label and
/// a random hex suffix.  The returned path is allocated via `allocator` and
/// the caller owns the memory.
pub fn createTempDir(io: std.Io, allocator: std.mem.Allocator, label: []const u8) ![]const u8 {
    const prefix = maltPrefixOrAbort();

    // Ensure the tmp base directory exists. If makePath fails, makeDirAbsolute
    // below surfaces the real error on the final dir.
    const tmp_base = try std.fmt.allocPrint(allocator, "{s}/tmp", .{prefix});
    defer allocator.free(tmp_base);
    std.Io.Dir.cwd().createDirPath(io, tmp_base) catch {};

    // Generate 8 random bytes -> 16 hex chars.
    var rand_bytes: [8]u8 = undefined;
    std.c.arc4random_buf(&rand_bytes, rand_bytes.len);
    const hex_buf = std.fmt.bytesToHex(rand_bytes, .lower);

    const dir_path = try std.fmt.allocPrint(allocator, "{s}/tmp/{s}_{s}", .{ prefix, label, &hex_buf });

    std.Io.Dir.createDirAbsolute(io, dir_path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {}, // unlikely but harmless
        else => {
            allocator.free(dir_path);
            return err;
        },
    };

    return dir_path;
}

/// Remove a temporary directory recursively.  Best-effort: errors are ignored.
pub fn cleanupTempDir(io: std.Io, dir_path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};
}

/// Return "{prefix}/tmp", allocated via `allocator`.
pub fn maltTmpDir(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/tmp", .{maltPrefixOrAbort()});
}

/// Return "{prefix}/db", allocated via `allocator`.
pub fn maltDbDir(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/db", .{maltPrefixOrAbort()});
}

/// Return the cache directory, honouring MALT_CACHE env var.
/// Falls back to "{prefix}/cache".
pub fn maltCacheDir(allocator: std.mem.Allocator) ![]const u8 {
    if (getenvLocal("MALT_CACHE")) |cache| {
        return allocator.dupe(u8, std.mem.sliceTo(cache, 0));
    }
    return std.fmt.allocPrint(allocator, "{s}/cache", .{maltPrefixOrAbort()});
}

// Inline tests for the atomicWriteFileImpl durability seam.
// Observable-behaviour coverage lives in tests/atomic_test.zig.

const SyncCounters = struct {
    file: usize = 0,
    dir: usize = 0,
};

var test_sync_counters: SyncCounters = .{};

const dbg_io = std.Options.debug_io;

fn rmrf(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(dbg_io, path) catch {};
}

var scratch_seq: std.atomic.Value(u32) = .init(0);

/// Scratch tree under a process- and call-unique base: overlapping test runs
/// share /tmp and would otherwise delete each other's fixtures.
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
        try std.Io.Dir.createDirAbsolute(dbg_io, base, .default_dir);
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

const TestSyncOps = struct {
    fail_file: bool = false,
    fail_dir: bool = false,

    fn syncFile(self: @This(), _: std.Io, _: std.Io.File) !void {
        if (self.fail_file) return error.AccessDenied;
        test_sync_counters.file += 1;
    }
    fn syncDir(self: @This(), _: std.Io, _: std.Io.Dir) !void {
        if (self.fail_dir) return error.AccessDenied;
        test_sync_counters.dir += 1;
    }
};

test "an exact-mode atomic write survives a restrictive umask" {
    var s = try Scratch.init("atomic_mode");
    defer s.deinit();
    const io = std.Options.debug_io;

    // open(2) masks the requested mode; content whose permissions are a
    // contract must land on the right bits anyway.
    const prev = std.c.umask(0o077);
    defer _ = std.c.umask(prev);

    const path = s.p("/bundle.pem");
    try atomicWriteFileMode(io, path, "data", @enumFromInt(0o644));

    const f = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer f.close(io);
    const st = try f.stat(io);
    try std.testing.expectEqual(@as(u32, 0o644), @intFromEnum(st.permissions) & 0o777);
}

test "a default-mode atomic write still honours the umask" {
    var s = try Scratch.init("atomic_umask");
    defer s.deinit();
    const io = std.Options.debug_io;

    const prev = std.c.umask(0o077);
    defer _ = std.c.umask(prev);

    const path = s.p("/plain.bin");
    try atomicWriteFile(io, path, "data");

    const f = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer f.close(io);
    const st = try f.stat(io);
    // Widening this for every caller would be a security change, not a fix.
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(st.permissions) & 0o077);
}

test "atomicWriteFileImpl fsyncs the tempfile via the injected sync ops" {
    const io = std.Options.debug_io;
    var s = try Scratch.init("atomic_inline_sync_file");
    defer s.deinit();

    test_sync_counters = .{};
    try atomicWriteFileImpl(io, s.p("/data.bin"), "abc", TestSyncOps{}, .default_file, .umask);
    try std.testing.expectEqual(@as(usize, 1), test_sync_counters.file);
}

test "atomicWriteFileImpl fsyncs the parent directory via the injected sync ops" {
    const io = std.Options.debug_io;
    var s = try Scratch.init("atomic_inline_sync_dir");
    defer s.deinit();

    test_sync_counters = .{};
    try atomicWriteFileImpl(io, s.p("/data.bin"), "abc", TestSyncOps{}, .default_file, .umask);
    try std.testing.expectEqual(@as(usize, 1), test_sync_counters.dir);
}

test "atomicWriteFileImpl propagates syncFile errors and removes the tempfile" {
    const io = std.Options.debug_io;
    var s = try Scratch.init("atomic_inline_sync_file_err");
    defer s.deinit();
    const base = s.base;

    const dst = s.p("/data.bin");
    try std.testing.expectError(
        error.AccessDenied,
        atomicWriteFileImpl(io, dst, "abc", TestSyncOps{ .fail_file = true }, .default_file, .umask),
    );

    // dst was never renamed in; tempfiles must not accumulate either.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.openFileAbsolute(io, dst, .{}));
    var dir = try std.Io.Dir.openDirAbsolute(io, base, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    try std.testing.expectEqual(@as(?std.Io.Dir.Entry, null), try iter.next(io));
}

test "atomicWriteFileImpl propagates syncDir errors but leaves the renamed file in place" {
    const io = std.Options.debug_io;
    var s = try Scratch.init("atomic_inline_sync_dir_err");
    defer s.deinit();

    const dst = s.p("/data.bin");
    try std.testing.expectError(
        error.AccessDenied,
        atomicWriteFileImpl(io, dst, "abc", TestSyncOps{ .fail_dir = true }, .default_file, .umask),
    );

    // syncDir runs after rename, so dst_path must hold the durable bytes.
    const f = try std.Io.Dir.openFileAbsolute(io, dst, .{});
    defer f.close(io);
    var buf: [8]u8 = undefined;
    const n = try f.readPositionalAll(io, &buf, 0);
    try std.testing.expectEqualStrings("abc", buf[0..n]);
}
