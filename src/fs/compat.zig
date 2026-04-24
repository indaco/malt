//! 0.15-style `std.fs` / `std.posix.getenv` shim over the 0.16 `std.Io` APIs.
//! Helpers pull `Io` from `io_mod.ctx()`; retires once callers thread `Io`.

const std = @import("std");
const io_mod = @import("../ui/io.zig");

pub const path = std.fs.path;
pub const max_path_bytes = std.Io.Dir.max_path_bytes;
pub const max_name_bytes = std.Io.Dir.max_name_bytes;

/// Read a raw `std.Io.File` to end on a per-call `Threaded` io — the default
/// `debug_io` can't wait on blocking child pipes.
pub fn readFileToEndAlloc(file: std.Io.File, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var buf: [4096]u8 = undefined;
    var r = file.readerStreaming(threaded.io(), &buf);
    return r.interface.allocRemaining(allocator, std.Io.Limit.limited(max_bytes));
}

pub fn sleepNanos(ns: u64) void {
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

pub fn timestamp() i64 {
    return std.Io.Clock.real.now(io_mod.ctx()).toSeconds();
}

pub fn nanoTimestamp() i128 {
    return std.Io.Clock.real.now(io_mod.ctx()).toNanoseconds();
}

pub fn milliTimestamp() i64 {
    return std.Io.Clock.real.now(io_mod.ctx()).toMilliseconds();
}

/// Closed error set for `StreamCallback.func`; forces exhaustive handling.
pub const StreamError = error{ OutOfMemory, CallbackAborted };

/// Context + func for `streamFile`; a non-void error aborts the walk.
pub const StreamCallback = struct {
    context: *anyopaque,
    func: *const fn (context: *anyopaque, chunk: []const u8) StreamError!void,
};

/// Stream `file` to EOF in `buf`-sized chunks via advancing positional reads.
/// Fails fast on a zero-length buffer (would loop).
pub fn streamFile(file: File, buf: []u8, cb: StreamCallback) !void {
    if (buf.len == 0) return error.InvalidArgument;
    var offset: u64 = 0;
    while (true) {
        const n = try file.readAllAt(buf, offset);
        if (n == 0) break;
        try cb.func(cb.context, buf[0..n]);
        offset += n;
        // Short read ⇒ EOF; skip one extra syscall on exact-multiple sizes.
        if (n < buf.len) break;
    }
}

pub fn isatty(fd: std.posix.fd_t) bool {
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    return file.isTty(io_mod.ctx()) catch false;
}

pub fn getenv(name: []const u8) ?[:0]const u8 {
    return std.process.Environ.getPosix(processEnviron(), name);
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

pub fn openFileAbsolute(absolute_path: []const u8, flags: std.Io.Dir.OpenFileOptions) !File {
    const inner = try std.Io.Dir.openFileAbsolute(io_mod.ctx(), absolute_path, flags);
    return .{ .inner = inner };
}

pub fn createFileAbsolute(absolute_path: []const u8, flags: std.Io.Dir.CreateFileOptions) !File {
    const inner = try std.Io.Dir.createFileAbsolute(io_mod.ctx(), absolute_path, flags);
    return .{ .inner = inner };
}

pub fn openDirAbsolute(absolute_path: []const u8, options: std.Io.Dir.OpenOptions) !Dir {
    const inner = try std.Io.Dir.openDirAbsolute(io_mod.ctx(), absolute_path, options);
    return .{ .inner = inner };
}

pub fn accessAbsolute(absolute_path: []const u8, options: std.Io.Dir.AccessOptions) !void {
    return std.Io.Dir.accessAbsolute(io_mod.ctx(), absolute_path, options);
}

pub fn renameAbsolute(old_path: []const u8, new_path: []const u8) !void {
    return std.Io.Dir.renameAbsolute(old_path, new_path, io_mod.ctx());
}

/// 0.15-style `readFileAlloc` convenience for absolute paths.
pub fn readFileAbsoluteAlloc(allocator: std.mem.Allocator, absolute_path: []const u8, max_bytes: usize) ![]u8 {
    const f = try openFileAbsolute(absolute_path, .{});
    defer f.close();
    return f.readToEndAlloc(allocator, max_bytes);
}

pub fn cwd() Dir {
    return .{ .inner = std.Io.Dir.cwd() };
}

/// 0.15-style std stream accessors returning the shim `File`.
pub fn stderrFile() File {
    return .{ .inner = io_mod.stderrFile() };
}

pub fn stdoutFile() File {
    return .{ .inner = io_mod.stdoutFile() };
}

pub fn stdinFile() File {
    return .{ .inner = std.Io.File.stdin() };
}

/// Parent `environ` as `std.process.Environ`. `std.Io.Threaded`'s default is
/// empty, which falls back to a PATH that misses `/opt/homebrew/bin` on Apple
/// Silicon and hides `cosign`.
pub fn processEnviron() std.process.Environ {
    var n: usize = 0;
    while (std.c.environ[n] != null) : (n += 1) {}
    const slice: [:null]const ?[*:0]const u8 = @ptrCast(std.c.environ[0..n :null]);
    return .{ .block = .{ .slice = slice } };
}

/// 0.15-style `std.process.Child` shim over the 0.16 `std.process` free fns.
pub const Child = struct {
    argv: []const []const u8,
    allocator: std.mem.Allocator,
    stdin_behavior: StdIo = .inherit,
    stdout_behavior: StdIo = .inherit,
    stderr_behavior: StdIo = .inherit,
    inner: ?std.process.Child = null,
    /// Populated after `spawn` when the corresponding behavior is `.pipe`.
    stdout: ?std.Io.File = null,
    stderr: ?std.Io.File = null,
    stdin: ?std.Io.File = null,

    pub const StdIo = std.process.SpawnOptions.StdIo;
    pub const Term = std.process.Child.Term;

    pub fn init(argv: []const []const u8, allocator: std.mem.Allocator) Child {
        return .{ .argv = argv, .allocator = allocator };
    }

    pub fn spawn(self: *Child) !void {
        // `debug_io`'s failing allocator can't back argv/env dups; build a
        // per-call `Threaded` io with the real environ so PATH matches parent.
        var threaded: std.Io.Threaded = .init(self.allocator, .{ .environ = processEnviron() });
        defer threaded.deinit();
        const spawned = try std.process.spawn(threaded.io(), .{
            .argv = self.argv,
            .stdin = self.stdin_behavior,
            .stdout = self.stdout_behavior,
            .stderr = self.stderr_behavior,
        });
        self.inner = spawned;
        self.stdin = spawned.stdin;
        self.stdout = spawned.stdout;
        self.stderr = spawned.stderr;
    }

    pub fn wait(self: *Child) !Term {
        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        if (self.inner) |*c| return c.wait(threaded.io());
        return error.NotSpawned;
    }

    pub fn spawnAndWait(self: *Child) !Term {
        try self.spawn();
        return self.wait();
    }
};

/// Thin wrapper: `std.Io.File` plus methods that supply `io` implicitly.
pub const File = struct {
    inner: std.Io.File,

    pub const Stat = std.Io.File.Stat;
    pub const Kind = std.Io.File.Kind;

    pub fn close(self: File) void {
        self.inner.close(io_mod.ctx());
    }

    pub fn writeAll(self: File, bytes: []const u8) !void {
        return self.inner.writeStreamingAll(io_mod.ctx(), bytes);
    }

    /// Partial write (at most one syscall). Returns bytes written.
    pub fn write(self: File, bytes: []const u8) !usize {
        return self.inner.writeStreaming(io_mod.ctx(), &.{}, &.{bytes}, 1);
    }

    pub fn updateTimes(self: File, atime_ns: i128, mtime_ns: i128) !void {
        const atime_ts: std.Io.Timestamp = .{ .nanoseconds = @intCast(atime_ns) };
        const mtime_ts: std.Io.Timestamp = .{ .nanoseconds = @intCast(mtime_ns) };
        return self.inner.setTimestamps(io_mod.ctx(), .{
            .access_timestamp = .{ .new = atime_ts },
            .modify_timestamp = .{ .new = mtime_ts },
        });
    }

    /// Positional read from offset 0 — single-shot only; loops re-read bytes.
    pub fn readAll(self: File, buffer: []u8) !usize {
        return self.inner.readPositionalAll(io_mod.ctx(), buffer, 0);
    }

    /// Positional read; caller advances `offset`. Prefer `streamFile`.
    pub fn readAllAt(self: File, buffer: []u8, offset: u64) !usize {
        return self.inner.readPositionalAll(io_mod.ctx(), buffer, offset);
    }

    pub fn stat(self: File) !Stat {
        return self.inner.stat(io_mod.ctx());
    }

    /// Positional write of all bytes starting at `offset`.
    pub fn writeAllAt(self: File, bytes: []const u8, offset: u64) !void {
        return self.inner.writePositionalAll(io_mod.ctx(), bytes, offset);
    }

    pub fn setEndPos(self: File, length: u64) !void {
        return self.inner.setLength(io_mod.ctx(), length);
    }

    pub fn writer(self: File, buffer: []u8) std.Io.File.Writer {
        return self.inner.writer(io_mod.ctx(), buffer);
    }

    pub fn supportsAnsiEscapeCodes(self: File) bool {
        return self.inner.supportsAnsiEscapeCodes(io_mod.ctx()) catch false;
    }

    pub fn chmod(self: File, mode: u16) !void {
        return self.inner.setPermissions(io_mod.ctx(), std.Io.File.Permissions.fromMode(@intCast(mode)));
    }

    /// fsync; callers that rename-for-atomicity must sync first (POSIX
    /// rename is not durable).
    pub fn sync(self: File) !void {
        return self.inner.sync(io_mod.ctx());
    }

    pub fn readToEndAlloc(self: File, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
        const io = io_mod.ctx();
        const st = try self.inner.stat(io);
        const size = @min(@as(u64, max_bytes), st.size);
        const buf = try allocator.alloc(u8, @intCast(size));
        errdefer allocator.free(buf);
        const n = try self.inner.readPositionalAll(io, buf, 0);
        if (n == buf.len) return buf;
        // Short read: shrink so caller-side free matches — GPA traps on
        // length mismatch, others leak the tail.
        if (allocator.resize(buf, n)) return buf[0..n];
        const shrunk = try allocator.alloc(u8, n);
        @memcpy(shrunk, buf[0..n]);
        allocator.free(buf);
        return shrunk;
    }
};

/// Thin wrapper: `std.Io.Dir` plus methods that supply `io` implicitly.
pub const Dir = struct {
    inner: std.Io.Dir,

    pub const OpenOptions = std.Io.Dir.OpenOptions;
    pub const OpenFileOptions = std.Io.Dir.OpenFileOptions;
    pub const CreateFileOptions = std.Io.Dir.CreateFileOptions;
    pub const AccessOptions = std.Io.Dir.AccessOptions;
    pub const Stat = std.Io.Dir.Stat;

    pub fn close(self: *Dir) void {
        self.inner.close(io_mod.ctx());
    }

    pub fn makePath(self: Dir, sub_path: []const u8) !void {
        try self.inner.createDirPath(io_mod.ctx(), sub_path);
    }

    pub fn statFile(self: Dir, sub_path: []const u8) !std.Io.File.Stat {
        return self.inner.statFile(io_mod.ctx(), sub_path, .{});
    }

    pub fn openFile(self: Dir, sub_path: []const u8, flags: OpenFileOptions) !File {
        const inner = try self.inner.openFile(io_mod.ctx(), sub_path, flags);
        return .{ .inner = inner };
    }

    pub fn createFile(self: Dir, sub_path: []const u8, flags: CreateFileOptions) !File {
        const inner = try self.inner.createFile(io_mod.ctx(), sub_path, flags);
        return .{ .inner = inner };
    }

    pub fn access(self: Dir, sub_path: []const u8, options: AccessOptions) !void {
        return self.inner.access(io_mod.ctx(), sub_path, options);
    }

    pub fn deleteFile(self: Dir, sub_path: []const u8) !void {
        return self.inner.deleteFile(io_mod.ctx(), sub_path);
    }

    pub fn deleteDir(self: Dir, sub_path: []const u8) !void {
        return self.inner.deleteDir(io_mod.ctx(), sub_path);
    }

    pub fn deleteTree(self: Dir, sub_path: []const u8) !void {
        return self.inner.deleteTree(io_mod.ctx(), sub_path);
    }

    /// 0.15-style `Dir.realpath` into `out_buffer`.
    pub fn realpath(self: Dir, pathname: []const u8, out_buffer: []u8) ![]u8 {
        const n = try self.inner.realPathFile(io_mod.ctx(), pathname, out_buffer);
        return out_buffer[0..n];
    }

    pub fn readLink(self: Dir, sub_path: []const u8, buffer: []u8) ![]u8 {
        const n = try self.inner.readLink(io_mod.ctx(), sub_path, buffer);
        return buffer[0..n];
    }

    pub fn symLink(self: Dir, target_path: []const u8, sym_link_path: []const u8, flags: std.Io.Dir.SymLinkFlags) !void {
        return self.inner.symLink(io_mod.ctx(), target_path, sym_link_path, flags);
    }

    pub fn rename(self: Dir, old_sub_path: []const u8, new_sub_path: []const u8) !void {
        return self.inner.rename(old_sub_path, self.inner, new_sub_path, io_mod.ctx());
    }

    /// Flush directory metadata via fsync(2) on the dir fd (POSIX contract).
    pub fn sync(self: Dir) !void {
        const file: std.Io.File = .{ .handle = self.inner.handle, .flags = .{ .nonblocking = false } };
        try file.sync(io_mod.ctx());
    }

    pub fn openDir(self: Dir, sub_path: []const u8, options: OpenOptions) !Dir {
        const inner = try self.inner.openDir(io_mod.ctx(), sub_path, options);
        return .{ .inner = inner };
    }

    pub fn iterate(self: Dir) Iterator {
        return .{ .inner = self.inner.iterate() };
    }

    pub fn walk(self: Dir, allocator: std.mem.Allocator) !Walker {
        const inner = try self.inner.walk(allocator);
        return .{ .inner = inner };
    }

    pub fn copyFile(
        self: Dir,
        source_path: []const u8,
        dest_dir: Dir,
        dest_path: []const u8,
        options: std.Io.Dir.CopyFileOptions,
    ) !void {
        return std.Io.Dir.copyFile(
            self.inner,
            source_path,
            dest_dir.inner,
            dest_path,
            io_mod.ctx(),
            options,
        );
    }
};

/// Thin wrapper for `std.Io.Dir.Iterator` that supplies `io` implicitly.
pub const Iterator = struct {
    inner: std.Io.Dir.Iterator,

    pub const Entry = std.Io.Dir.Entry;

    pub fn next(self: *Iterator) !?Entry {
        return self.inner.next(io_mod.ctx());
    }
};

/// Thin wrapper for `std.Io.Dir.Walker` that supplies `io` implicitly.
pub const Walker = struct {
    inner: std.Io.Dir.Walker,

    pub const Entry = std.Io.Dir.Walker.Entry;

    pub fn next(self: *Walker) !?Entry {
        return self.inner.next(io_mod.ctx());
    }

    pub fn deinit(self: *Walker) void {
        self.inner.deinit();
    }
};
