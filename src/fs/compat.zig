//! Test-utility shims over `std.Io` primitives. Production code threads
//! `std.Io` and `std.process.Environ` through `AppCtx`; this module
//! exposes thin convenience wrappers used by the integration tests
//! under `tests/`. All helpers route through `io_mod.ctx()`, which is
//! the test-runner's `Threaded` io.

const std = @import("std");
const io_mod = @import("../ui/io.zig");

pub const path = std.fs.path;
pub const max_path_bytes = std.Io.Dir.max_path_bytes;
pub const max_name_bytes = std.Io.Dir.max_name_bytes;

pub fn sleepNanos(ns: u64) void {
    // `sleep` returns !void for cancellation; an early wake just shortens the delay.
    std.Io.sleep(io_mod.ctx(), std.Io.Duration.fromNanoseconds(@intCast(ns)), .awake) catch {};
}

pub fn randomBytes(buf: []u8) void {
    // std.Io.random is portable and infallible — no libc return to ignore.
    io_mod.ctx().random(buf);
}

pub fn randomInt(comptime T: type) T {
    var bytes: [@sizeOf(T)]u8 = undefined;
    randomBytes(&bytes);
    return std.mem.bytesToValue(T, &bytes);
}

pub fn timestamp() i64 {
    return std.Io.Clock.real.now(io_mod.ctx()).toSeconds();
}

pub fn nanoTimestamp() i128 {
    return std.Io.Clock.real.now(io_mod.ctx()).toNanoseconds();
}

pub fn milliTimestamp() i64 {
    return std.Io.Clock.real.now(io_mod.ctx()).toMilliseconds();
}

pub fn isatty(fd: std.posix.fd_t) bool {
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    return file.isTty(io_mod.ctx()) catch false;
}

pub fn getenv(name: []const u8) ?[:0]const u8 {
    const app_ctx = @import("../app_ctx.zig");
    return std.process.Environ.getPosix(app_ctx.processEnviron(), name);
}

pub fn copyFileAbsolute(source_path: []const u8, dest_path: []const u8, options: std.Io.Dir.CopyFileOptions) !void {
    const io = io_mod.ctx();
    const cwd_dir: std.Io.Dir = .cwd();
    return std.Io.Dir.copyFile(cwd_dir, source_path, cwd_dir, dest_path, io, options);
}

pub fn symLinkAbsolute(target_path: []const u8, sym_link_path: []const u8, flags: std.Io.Dir.SymLinkFlags) !void {
    return std.Io.Dir.symLinkAbsolute(io_mod.ctx(), target_path, sym_link_path, flags);
}

pub fn readLinkAbsolute(absolute_path: []const u8, buffer: []u8) ![]u8 {
    const n = try std.Io.Dir.readLinkAbsolute(io_mod.ctx(), absolute_path, buffer);
    return buffer[0..n];
}

pub fn makeDirAbsolute(absolute_path: []const u8) !void {
    return std.Io.Dir.createDirAbsolute(io_mod.ctx(), absolute_path, .default_dir);
}

pub fn deleteTreeAbsolute(absolute_path: []const u8) !void {
    return std.Io.Dir.cwd().deleteTree(io_mod.ctx(), absolute_path);
}

pub fn deleteFileAbsolute(absolute_path: []const u8) !void {
    return std.Io.Dir.deleteFileAbsolute(io_mod.ctx(), absolute_path);
}

pub fn deleteDirAbsolute(absolute_path: []const u8) !void {
    return std.Io.Dir.deleteDirAbsolute(io_mod.ctx(), absolute_path);
}

pub fn accessAbsolute(absolute_path: []const u8, options: std.Io.Dir.AccessOptions) !void {
    return std.Io.Dir.accessAbsolute(io_mod.ctx(), absolute_path, options);
}

pub fn renameAbsolute(old_path: []const u8, new_path: []const u8) !void {
    return std.Io.Dir.renameAbsolute(old_path, new_path, io_mod.ctx());
}

/// Convenience: `std.Io.Dir.cwd()` re-exported so test fixtures can spell
/// it `fs_compat.cwd()` and immediately call methods that take
/// `io_mod.ctx()`.
pub fn cwd() std.Io.Dir {
    return std.Io.Dir.cwd();
}

/// Open an absolute path, returning a raw `std.Io.File`. Callers pass
/// `io_mod.ctx()` to the file's methods.
pub fn openFileAbsolute(absolute_path: []const u8, flags: std.Io.Dir.OpenFileOptions) !std.Io.File {
    return std.Io.Dir.openFileAbsolute(io_mod.ctx(), absolute_path, flags);
}

pub fn createFileAbsolute(absolute_path: []const u8, flags: std.Io.Dir.CreateFileOptions) !std.Io.File {
    return std.Io.Dir.createFileAbsolute(io_mod.ctx(), absolute_path, flags);
}

pub fn openDirAbsolute(absolute_path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    return std.Io.Dir.openDirAbsolute(io_mod.ctx(), absolute_path, options);
}

/// Read the whole file at `absolute_path` into a freshly allocated slice.
/// Tests use this for golden-file comparisons; production callers thread
/// io directly.
pub fn readFileAbsoluteAlloc(allocator: std.mem.Allocator, absolute_path: []const u8, max_bytes: usize) ![]u8 {
    const io = io_mod.ctx();
    const f = try openFileAbsolute(absolute_path, .{});
    defer f.close(io);
    const st = try f.stat(io);
    const size = @min(@as(u64, max_bytes), st.size);
    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);
    const n = try f.readPositionalAll(io, buf, 0);
    if (n == buf.len) return buf;
    // Short read: shrink so the caller-side free matches.
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

test "File close round-trips a freshly written file" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&path_buf, "/tmp/malt_compat_{d}", .{nanoTimestamp()});
    deleteTreeAbsolute(dir_path) catch {};
    try makeDirAbsolute(dir_path);
    defer deleteTreeAbsolute(dir_path) catch {};

    var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&file_path_buf, "{s}/data", .{dir_path});

    const f = try createFileAbsolute(file_path, .{});
    defer f.close(io_mod.ctx());
    try f.writeStreamingAll(io_mod.ctx(), "durable-bytes");
    try f.sync(io_mod.ctx());
}
