const std = @import("std");

pub const LockError = error{
    /// Genuine contention: another live process still holds the lock when
    /// the timeout elapses.
    Timeout,
    /// The lock's parent directory does not exist — a fresh prefix that has
    /// never had anything installed. Kept distinct from contention so callers
    /// can treat it as "nothing installed" instead of a phantom "process
    /// running".
    DirMissing,
    /// The lock's directory exists but is not writable — e.g. a root-owned
    /// /opt/malt created by `sudo mkdir` without a follow-up `chown`.
    AccessDenied,
    /// Any other failure opening the lock file.
    OpenFailed,
    /// The lock was taken but its pid could not be recorded.
    WriteFailed,
};

/// Between contention probes. Short enough to feel snappy, long enough not to
/// spin the cpu against a long-held lock.
const retry_interval_ns: u64 = 100 * std.time.ns_per_ms;

pub const LockFile = struct {
    /// Owned by the LockFile; touch only via `release` / `holderPid`.
    file: std.Io.File,
    path: []const u8,

    /// Acquire an exclusive advisory lock at `path`, retrying with 100 ms
    /// sleeps until `timeout_ms` elapses. On success the current PID is
    /// written and fsync'd so other processes can identify the live holder.
    pub fn acquire(io: std.Io, path: []const u8, timeout_ms: u32) LockError!LockFile {
        const file = std.Io.Dir.createFileAbsolute(io, path, .{
            .read = true,
            .truncate = false,
        }) catch |e| switch (e) {
            // ENOENT on the parent dir = fresh prefix, not contention.
            error.FileNotFound => return error.DirMissing,
            error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
            else => return error.OpenFailed,
        };
        errdefer file.close(io);

        try acquireLockWithin(io, file, timeout_ms);
        errdefer file.unlock(io);

        try writePidAndSync(io, file);

        return .{ .file = file, .path = path };
    }

    /// Release the advisory lock and close the file descriptor.
    ///
    /// Truncates the file to 0 bytes before unlocking so subsequent
    /// `holderPid` calls (and therefore `mt doctor`) see the lock as
    /// vacated instead of reporting a stale PID. The file itself is
    /// left in place — removing it would race against other processes
    /// that may already have it open.
    pub fn release(self: *LockFile, io: std.Io) void {
        // Vacate the pid before unlock so a racing reader sees an empty
        // file, not the just-released holder's pid. The truncate+sync are
        // best-effort: any failure leaves a stale pid that the next
        // acquire immediately overwrites.
        self.file.setLength(io, 0) catch {};
        self.file.sync(io) catch {};
        self.file.unlock(io);
        self.file.close(io);
    }

    /// Read the PID from an existing lock file. Returns null when the file
    /// does not exist, is empty, or cannot be parsed.
    pub fn holderPid(io: std.Io, path: []const u8) ?std.posix.pid_t {
        const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
        defer file.close(io);

        var buf: [32]u8 = undefined;
        const n = file.readPositionalAll(io, &buf, 0) catch return null;
        if (n == 0) return null;

        const trimmed = std.mem.trimEnd(u8, buf[0..n], &[_]u8{ '\n', '\r', ' ', 0 });
        return std.fmt.parseInt(std.posix.pid_t, trimmed, 10) catch null;
    }
};

fn acquireLockWithin(io: std.Io, file: std.Io.File, timeout_ms: u32) LockError!void {
    const deadline_ns: u128 = @as(u128, @intCast(timeout_ms)) * std.time.ns_per_ms;
    var elapsed_ns: u128 = 0;
    while (true) {
        const locked = file.tryLock(io, .exclusive) catch return error.OpenFailed;
        if (locked) return;
        if (elapsed_ns >= deadline_ns) return error.Timeout;
        // Cancel just shortens the wait; the next loop iteration re-checks the deadline.
        std.Io.sleep(io, std.Io.Duration.fromNanoseconds(@intCast(retry_interval_ns)), .awake) catch {};
        elapsed_ns += retry_interval_ns;
    }
}

fn writePidAndSync(io: std.Io, file: std.Io.File) LockError!void {
    file.setLength(io, 0) catch return error.WriteFailed;

    var buf: [32]u8 = undefined;
    // `getpid` has no typed std peer in Zig 0.16; the libc wrapper never fails.
    const pid = std.posix.system.getpid();
    const pid_str = std.fmt.bufPrint(&buf, "{d}", .{pid}) catch return error.WriteFailed;
    file.writePositionalAll(io, pid_str, 0) catch return error.WriteFailed;

    // Durability of the live pid for `mt doctor` after a SIGKILL —
    // without this the pid lives only in the page cache.
    file.sync(io) catch return error.WriteFailed;
}

test "acquire reports DirMissing when the lock's parent directory is absent" {
    // A fresh prefix that never had anything installed has no `db/` dir, so
    // the lock create hits ENOENT. The historical bug surfaced that to the
    // user as "another malt process may be running". Pin the distinct error
    // so callers can treat it as "nothing installed", not contention.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var rnd: [9]u8 = undefined;
    io.random(&rnd);
    var suffix: [std.base64.url_safe.Encoder.calcSize(9)]u8 = undefined;
    _ = std.base64.url_safe.Encoder.encode(&suffix, &rnd);

    // The `<base>/db` parent is deliberately never created.
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        "/tmp/malt-lock-missing-{s}/db/malt.lock",
        .{suffix},
    );
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.DirMissing, LockFile.acquire(io, path, 100));
}

test "acquire records a pid while held and release vacates it" {
    // The success path is the other half of the DirMissing contract: when
    // the dir exists the lock must take, expose its holder pid, then clear
    // it on release so `mt doctor` never reports a phantom holder.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var rnd: [9]u8 = undefined;
    io.random(&rnd);
    var suffix: [std.base64.url_safe.Encoder.calcSize(9)]u8 = undefined;
    _ = std.base64.url_safe.Encoder.encode(&suffix, &rnd);

    const dir = try std.fmt.allocPrint(std.testing.allocator, "/tmp/malt-lock-ok-{s}", .{suffix});
    defer std.testing.allocator.free(dir);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/malt.lock", .{dir});
    defer std.testing.allocator.free(path);

    try std.Io.Dir.createDirAbsolute(io, dir, .default_dir);
    defer {
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
        std.Io.Dir.deleteDirAbsolute(io, dir) catch {};
    }

    var lk = try LockFile.acquire(io, path, 1000);
    try std.testing.expect(LockFile.holderPid(io, path) != null);
    lk.release(io);
    try std.testing.expect(LockFile.holderPid(io, path) == null);
}

test "acquire has a single close path (regression guard for double-close)" {
    // The historical bug was three explicit `close(fd)` calls inside the
    // WriteFailed arms colliding with a function-top errdefer. The fix
    // is structural: one `errdefer file.close(io)` covers every error
    // arm. Single-threaded tests can't observe the original race, so
    // scan the source to pin the invariant.
    const src = @embedFile("lock.zig");
    const marker = "pub fn acquire(io: std.Io, path: []const u8, timeout_ms: u32) LockError!LockFile {";
    const start = std.mem.indexOf(u8, src, marker) orelse return error.AcquireFnNotFound;

    var depth: usize = 0;
    var body_end: usize = 0;
    var i: usize = start + marker.len;
    while (i < src.len) : (i += 1) {
        switch (src[i]) {
            '{' => depth += 1,
            '}' => {
                if (depth == 0) {
                    body_end = i;
                    break;
                }
                depth -= 1;
            },
            else => {},
        }
    }
    try std.testing.expect(body_end > start);
    const body = src[start..body_end];

    var close_count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, body, idx, ".close(")) |pos| : (idx = pos + 1) {
        close_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), close_count);
    try std.testing.expect(std.mem.indexOf(u8, body, "errdefer file.close(io)") != null);
}

test "acquire fsyncs the pid (regression guard for stale-pid bug)" {
    // The historical bug was a missing fsync between the pid write and
    // the lock being held — a SIGKILL'd holder left a phantom pid on
    // disk for `mt doctor`. Page cache satisfies single-process tests,
    // so pin the invariant in the source.
    const src = @embedFile("lock.zig");
    const writer_marker = "fn writePidAndSync";
    const fn_start = std.mem.indexOf(u8, src, writer_marker) orelse return error.WriterFnNotFound;
    const body = src[fn_start..];

    const write_pos = std.mem.indexOf(u8, body, "writePositionalAll") orelse return error.WriteCallMissing;
    const sync_pos = std.mem.indexOf(u8, body, "file.sync(io)") orelse return error.SyncCallMissing;
    try std.testing.expect(sync_pos > write_pos);
}
