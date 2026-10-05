//! Test-utility shims over `std.Io` primitives. The integration tests
//! under `tests/` thread `std.Io` explicitly through these helpers so
//! production code can stay free of test-shape modules.

const std = @import("std");
const malt = @import("malt");

pub const path = std.fs.path;
pub const max_path_bytes = std.Io.Dir.max_path_bytes;
pub const max_name_bytes = std.Io.Dir.max_name_bytes;

var temp_seq = std.atomic.Value(u32).init(0);

/// Scratch path unique to this process and call. A fixed `/tmp` name is shared
/// by any overlapping run — a manual `zig build test` racing the pre-push hook —
/// and one run's `deleteTree` then wipes the other's fixtures mid-test.
pub fn uniqueTempPath(allocator: std.mem.Allocator, group: []const u8, tag: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "/tmp/malt_{s}_{s}_{d}_{d}", .{
        group, tag, std.c.getpid(), temp_seq.fetchAdd(1, .monotonic),
    });
}

/// libc `setenv`/`unsetenv` for fixtures. Tests must unset through here: the
/// runner prints a failing assertion via the debug `Threaded`, whose lazy
/// environ scan walks the inherited env block, and libc compacts that block
/// in place when an inherited variable is unset. Scanning once before the
/// first unset memoises the walk, so a later failure is reported, not a crash.
pub const c = struct {
    const libc = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    };

    pub const setenv = libc.setenv;

    pub fn unsetenv(name: [*:0]const u8) c_int {
        _ = std.debug.lockStderr(&.{});
        std.debug.unlockStderr();
        return libc.unsetenv(name);
    }
};

/// Lazy `/dev/null` handle used to sink writes under the test runner. The
/// runner owns fd 1 for its IPC protocol, and dumps any captured stderr
/// next to a "failed command:" trailer — both swamp the summary with noise
/// when tests pass. Funneling user-visible writes here keeps runs quiet.
var test_sink_fd: std.atomic.Value(std.c.fd_t) = .init(-1);

pub fn testSink() std.Io.File {
    var current = test_sink_fd.load(.acquire);
    if (current < 0) {
        const fd = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) return std.Io.File.stderr();
        if (test_sink_fd.cmpxchgStrong(-1, fd, .release, .acquire)) |winner| {
            _ = std.c.close(fd);
            current = winner;
        } else {
            current = fd;
        }
    }
    return .{ .handle = current, .flags = .{ .nonblocking = false } };
}

pub fn sleepNanos(io: std.Io, ns: u64) void {
    // `sleep` returns !void for cancellation; an early wake just shortens the delay.
    std.Io.sleep(io, std.Io.Duration.fromNanoseconds(@intCast(ns)), .awake) catch {};
}

pub fn randomBytes(io: std.Io, buf: []u8) void {
    io.random(buf);
}

pub fn randomInt(io: std.Io, comptime T: type) T {
    var bytes: [@sizeOf(T)]u8 = undefined;
    randomBytes(io, &bytes);
    return std.mem.bytesToValue(T, &bytes);
}

pub fn timestamp(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}

pub fn nanoTimestamp(io: std.Io) i128 {
    return std.Io.Clock.real.now(io).toNanoseconds();
}

pub fn milliTimestamp(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toMilliseconds();
}

/// Elapsed-time clock for tests that assert a duration. `.awake`, not
/// `.real`: a wall-clock step inside the measured window would otherwise
/// decide the result, which is the same reason the deadlines under test
/// stopped using `.real`.
pub fn elapsedMillis(io: std.Io) i64 {
    return std.Io.Clock.awake.now(io).toMilliseconds();
}

pub fn isatty(io: std.Io, fd: std.posix.fd_t) bool {
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    return file.isTty(io) catch false;
}

pub fn getenv(name: []const u8) ?[:0]const u8 {
    return std.process.Environ.getPosix(malt.app_ctx.processEnviron(), name);
}

/// Skip when the harness asks us not to fork external processes.
/// kcov's Mach-port instrumentation collides with sandbox-exec children
/// on macOS (vm_write / thread_get_state failures), turning a coverage
/// run into an unbounded hang.
pub fn skipIfNoSubprocess() !void {
    if (getenv("MALT_SKIP_SUBPROCESS_TESTS") != null) return error.SkipZigTest;
}

pub fn copyFileAbsolute(io: std.Io, source_path: []const u8, dest_path: []const u8, options: std.Io.Dir.CopyFileOptions) !void {
    const cwd_dir: std.Io.Dir = .cwd();
    return std.Io.Dir.copyFile(cwd_dir, source_path, cwd_dir, dest_path, io, options);
}

pub fn symLinkAbsolute(io: std.Io, target_path: []const u8, sym_link_path: []const u8, flags: std.Io.Dir.SymLinkFlags) !void {
    return std.Io.Dir.symLinkAbsolute(io, target_path, sym_link_path, flags);
}

pub fn readLinkAbsolute(io: std.Io, absolute_path: []const u8, buffer: []u8) ![]u8 {
    const n = try std.Io.Dir.readLinkAbsolute(io, absolute_path, buffer);
    return buffer[0..n];
}

pub fn makeDirAbsolute(io: std.Io, absolute_path: []const u8) !void {
    return std.Io.Dir.createDirAbsolute(io, absolute_path, .default_dir);
}

pub fn deleteTreeAbsolute(io: std.Io, absolute_path: []const u8) !void {
    return std.Io.Dir.cwd().deleteTree(io, absolute_path);
}

pub fn deleteFileAbsolute(io: std.Io, absolute_path: []const u8) !void {
    return std.Io.Dir.deleteFileAbsolute(io, absolute_path);
}

pub fn deleteDirAbsolute(io: std.Io, absolute_path: []const u8) !void {
    return std.Io.Dir.deleteDirAbsolute(io, absolute_path);
}

pub fn accessAbsolute(io: std.Io, absolute_path: []const u8, options: std.Io.Dir.AccessOptions) !void {
    return std.Io.Dir.accessAbsolute(io, absolute_path, options);
}

pub fn renameAbsolute(io: std.Io, old_path: []const u8, new_path: []const u8) !void {
    return std.Io.Dir.renameAbsolute(old_path, new_path, io);
}

pub fn cwd() std.Io.Dir {
    return std.Io.Dir.cwd();
}

pub fn openFileAbsolute(io: std.Io, absolute_path: []const u8, flags: std.Io.Dir.OpenFileOptions) !std.Io.File {
    return std.Io.Dir.openFileAbsolute(io, absolute_path, flags);
}

pub fn createFileAbsolute(io: std.Io, absolute_path: []const u8, flags: std.Io.Dir.CreateFileOptions) !std.Io.File {
    return std.Io.Dir.createFileAbsolute(io, absolute_path, flags);
}

pub fn openDirAbsolute(io: std.Io, absolute_path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    return std.Io.Dir.openDirAbsolute(io, absolute_path, options);
}

/// Read the whole file at `absolute_path` into a freshly allocated slice.
/// Tests use this for golden-file comparisons; production callers thread io directly.
pub fn readFileAbsoluteAlloc(io: std.Io, allocator: std.mem.Allocator, absolute_path: []const u8, max_bytes: usize) ![]u8 {
    const f = try openFileAbsolute(io, absolute_path, .{});
    defer f.close(io);
    const st = try f.stat(io);
    const size = @min(@as(u64, max_bytes), st.size);
    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);
    const n = try f.readPositionalAll(io, buf, 0);
    if (n == buf.len) return buf;
    if (allocator.resize(buf, n)) return buf[0..n];
    const shrunk = try allocator.alloc(u8, n);
    @memcpy(shrunk, buf[0..n]);
    allocator.free(buf);
    return shrunk;
}

/// Read a raw `std.Io.File` to end on a per-call `Threaded` io — the default
/// `debug_io` can't wait on blocking child pipes when the file is the read
/// side of a spawn pipe.
pub fn readFileToEndAlloc(file: std.Io.File, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var buf: [4096]u8 = undefined;
    var r = file.readerStreaming(threaded.io(), &buf);
    return r.interface.allocRemaining(allocator, std.Io.Limit.limited(max_bytes));
}

/// Overwrite every b-tree page of `table` (and its indexes) on disk. The
/// schema stays intact, so statements prepare and only `step` fails, the
/// way page corruption or an I/O error shows up at runtime.
pub fn corruptTable(db_path: [:0]const u8, table: []const u8) !void {
    var pages: [8]i64 = undefined;
    var n: usize = 0;
    var page_size: i64 = 0;
    {
        // Closing the last connection checkpoints the WAL into the main file.
        var db = try malt.sqlite.Database.open(db_path);
        defer db.close();
        var ps = try db.prepare("PRAGMA page_size;");
        defer ps.finalize();
        _ = try ps.step();
        page_size = ps.columnInt(0);
        var st = try db.prepare("SELECT rootpage FROM sqlite_master WHERE tbl_name = ?1 AND rootpage > 0;");
        defer st.finalize();
        try st.bindText(1, table);
        while (try st.step()) : (n += 1) pages[n] = st.columnInt(0);
    }
    const f = try std.Io.Dir.openFileAbsolute(std.Options.debug_io, db_path, .{ .mode = .read_write });
    defer f.close(std.Options.debug_io);
    const junk = [_]u8{0xff} ** 65536;
    for (pages[0..n]) |p| {
        const len: usize = @intCast(page_size);
        try f.writePositionalAll(std.Options.debug_io, junk[0..len], @intCast((p - 1) * page_size));
    }
}

/// Drop every permission bit on the directory at `abs_path`. The returned
/// handle is what restores it: a mode-000 directory can't be reopened, and
/// the fixture's `deleteTree` fails until it is readable again.
pub fn wallDir(io: std.Io, abs_path: []const u8) !std.Io.Dir {
    const d = try std.Io.Dir.openDirAbsolute(io, abs_path, .{});
    errdefer d.close(io);
    try d.setPermissions(io, std.Io.File.Permissions.fromMode(0));
    return d;
}

pub fn unwallDir(io: std.Io, d: std.Io.Dir) void {
    d.setPermissions(io, std.Io.File.Permissions.fromMode(0o755)) catch {};
    d.close(io);
}

/// A `MALT_PREFIX` of exactly `len` bytes with `db/` made. 494-512 bytes is
/// the band `validatePrefix` admits but SQLite's 512-byte pathname cap
/// cannot open, so commands there must fail loud rather than exit clean.
pub const LongPrefix = struct {
    path: [:0]u8,
    root: []const u8,

    pub fn init(allocator: std.mem.Allocator, group: []const u8, len: usize) !LongPrefix {
        const root = try uniqueTempPath(allocator, group, "long");
        errdefer allocator.free(root);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, root);
        // Components stay well under NAME_MAX; the last one is never empty.
        while (len - buf.items.len > 202) {
            try buf.append(allocator, '/');
            try buf.appendNTimes(allocator, 'a', 200);
        }
        std.debug.assert(len - buf.items.len >= 2);
        try buf.append(allocator, '/');
        try buf.appendNTimes(allocator, 'b', len - buf.items.len);

        const prefix = try allocator.dupeZ(u8, buf.items);
        errdefer allocator.free(prefix);
        deleteTreeAbsolute(std.Options.debug_io, root) catch {};
        const db_dir = try std.fmt.allocPrint(allocator, "{s}/db", .{prefix});
        defer allocator.free(db_dir);
        try cwd().createDirPath(std.Options.debug_io, db_dir);
        _ = c.setenv("MALT_PREFIX", prefix.ptr, 1);
        return .{ .path = prefix, .root = root };
    }

    pub fn deinit(self: *LongPrefix, allocator: std.mem.Allocator) void {
        _ = c.unsetenv("MALT_PREFIX");
        deleteTreeAbsolute(std.Options.debug_io, self.root) catch {};
        allocator.free(self.path);
        allocator.free(self.root);
    }
};
