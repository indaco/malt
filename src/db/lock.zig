const std = @import("std");

pub const LockError = error{
    Timeout,
    OpenFailed,
    WriteFailed,
};

pub const LockFile = struct {
    fd: std.posix.fd_t,
    path: []const u8,

    /// Acquire an exclusive advisory lock at `path`, retrying with 100 ms
    /// sleeps until `timeout_ms` elapses.  On success the current PID is
    /// written to the file so that other processes can identify the holder.
    pub fn acquire(path: []const u8, timeout_ms: u32) LockError!LockFile {
        const path_z = std.posix.toPosixPath(path) catch return error.OpenFailed;
        const fd = std.c.open(&path_z, .{
            .ACCMODE = .RDWR,
            .CREAT = true,
        }, @as(std.c.mode_t, 0o644));
        if (fd < 0) return error.OpenFailed;

        const deadline_ns: u128 = @as(u128, @intCast(timeout_ms)) * std.time.ns_per_ms;
        var elapsed_ns: u128 = 0;
        const sleep_ns: u64 = 100 * std.time.ns_per_ms;

        while (true) {
            // Try non-blocking exclusive lock.
            const rc = std.c.flock(fd, std.c.LOCK.EX | std.c.LOCK.NB);
            if (rc == 0) break;
            const errno = std.posix.errno(rc);
            switch (errno) {
                .AGAIN => {
                    if (elapsed_ns >= deadline_ns) {
                        _ = std.c.close(fd);
                        return error.Timeout;
                    }
                    const ts: std.c.timespec = .{
                        .sec = @intCast(sleep_ns / std.time.ns_per_s),
                        .nsec = @intCast(sleep_ns % std.time.ns_per_s),
                    };
                    _ = std.c.nanosleep(&ts, null);
                    elapsed_ns += sleep_ns;
                },
                else => {
                    _ = std.c.close(fd);
                    return error.OpenFailed;
                },
            }
        }

        // Truncate and write PID.
        if (std.c.ftruncate(fd, 0) != 0) {
            _ = std.c.flock(fd, std.c.LOCK.UN);
            _ = std.c.close(fd);
            return error.WriteFailed;
        }

        var buf: [32]u8 = undefined;
        const pid = std.c.getpid();
        const pid_str = std.fmt.bufPrint(&buf, "{d}", .{pid}) catch {
            _ = std.c.flock(fd, std.c.LOCK.UN);
            _ = std.c.close(fd);
            return error.WriteFailed;
        };

        const written = std.c.write(fd, pid_str.ptr, pid_str.len);
        if (written < 0) {
            _ = std.c.flock(fd, std.c.LOCK.UN);
            _ = std.c.close(fd);
            return error.WriteFailed;
        }

        return LockFile{
            .fd = fd,
            .path = path,
        };
    }

    /// Release the advisory lock and close the file descriptor.
    ///
    /// Truncates the file to 0 bytes before unlocking so subsequent
    /// `holderPid` calls (and therefore `mt doctor`) see the lock as
    /// vacated instead of reporting a stale PID. The file itself is
    /// left in place — removing it would race against other processes
    /// that may already have it open.
    pub fn release(self: *LockFile) void {
        _ = std.c.ftruncate(self.fd, 0);
        // fsync before unlock so a crash between truncate and close can't
        // leave a stale PID in the lock file — `doctor` would otherwise
        // report a phantom holder.
        _ = std.c.fsync(self.fd);
        _ = std.c.flock(self.fd, std.c.LOCK.UN);
        _ = std.c.close(self.fd);
    }

    /// Read the PID from an existing lock file.  Returns null when the file
    /// does not exist or cannot be parsed.
    pub fn holderPid(path: []const u8) ?std.posix.pid_t {
        const path_z = std.posix.toPosixPath(path) catch return null;
        const fd = std.c.open(&path_z, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) return null;
        defer _ = std.c.close(fd);

        var buf: [32]u8 = undefined;
        const n = std.posix.read(fd, &buf) catch return null;
        if (n == 0) return null;

        const trimmed = std.mem.trimEnd(u8, buf[0..n], &[_]u8{ '\n', '\r', ' ' });
        return std.fmt.parseInt(std.posix.pid_t, trimmed, 10) catch null;
    }
};
