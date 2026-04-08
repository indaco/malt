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
        const fd = std.posix.open(path, .{
            .ACCMODE = .RDWR,
            .CREAT = true,
        }, 0o644) catch return error.OpenFailed;

        const deadline_ns: u128 = @as(u128, @intCast(timeout_ms)) * std.time.ns_per_ms;
        var elapsed_ns: u128 = 0;
        const sleep_ns: u64 = 100 * std.time.ns_per_ms;

        while (true) {
            // Try non-blocking exclusive lock.
            std.posix.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB) catch |err| {
                switch (err) {
                    error.WouldBlock => {
                        if (elapsed_ns >= deadline_ns) {
                            std.posix.close(fd);
                            return error.Timeout;
                        }
                        std.time.sleep(sleep_ns);
                        elapsed_ns += sleep_ns;
                        continue;
                    },
                    else => {
                        std.posix.close(fd);
                        return error.OpenFailed;
                    },
                }
            };
            break; // lock acquired
        }

        // Truncate and write PID.
        std.posix.ftruncate(fd, 0) catch {
            std.posix.flock(fd, std.posix.LOCK.UN) catch {};
            std.posix.close(fd);
            return error.WriteFailed;
        };

        var buf: [32]u8 = undefined;
        const pid = std.c.getpid();
        const pid_str = std.fmt.bufPrint(&buf, "{d}", .{pid}) catch {
            std.posix.flock(fd, std.posix.LOCK.UN) catch {};
            std.posix.close(fd);
            return error.WriteFailed;
        };

        _ = std.posix.write(fd, pid_str) catch {
            std.posix.flock(fd, std.posix.LOCK.UN) catch {};
            std.posix.close(fd);
            return error.WriteFailed;
        };

        return LockFile{
            .fd = fd,
            .path = path,
        };
    }

    /// Release the advisory lock and close the file descriptor.
    pub fn release(self: *LockFile) void {
        std.posix.flock(self.fd, std.posix.LOCK.UN) catch {};
        std.posix.close(self.fd);
    }

    /// Read the PID from an existing lock file.  Returns null when the file
    /// does not exist or cannot be parsed.
    pub fn holderPid(path: []const u8) ?std.posix.pid_t {
        const fd = std.posix.open(path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
        defer std.posix.close(fd);

        var buf: [32]u8 = undefined;
        const n = std.posix.read(fd, &buf) catch return null;
        if (n == 0) return null;

        const trimmed = std.mem.trimRight(u8, buf[0..n], &[_]u8{ '\n', '\r', ' ' });
        return std.fmt.parseInt(std.posix.pid_t, trimmed, 10) catch null;
    }
};
