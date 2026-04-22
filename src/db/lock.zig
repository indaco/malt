const std = @import("std");

pub const LockError = error{
    Timeout,
    OpenFailed,
    WriteFailed,
    /// ENOLCK: kernel advisory-lock slots exhausted — not contention, so surface distinctly.
    LockResourceExhausted,
};

/// Cap on EINTR retries so a signal storm can't spin the acquire loop forever.
pub const MAX_EINTR_RETRIES: u32 = 5;

/// Mapping of a non-zero `flock` errno to a loop action. Pure so it's unit-testable.
pub const FlockOutcome = enum {
    retry_later, // EAGAIN — sleep and try again within the deadline.
    interrupted, // EINTR — retry immediately (bounded).
    resource_exhausted, // ENOLCK — kernel lock table full.
    open_failed, // EBADF / EINVAL / … — treat as a hard failure.
};

pub fn classifyFlockErrno(errno: std.c.E) FlockOutcome {
    return switch (errno) {
        .AGAIN => .retry_later,
        .INTR => .interrupted,
        .NOLCK => .resource_exhausted,
        else => .open_failed,
    };
}

/// Next action for the acquire loop, from the current `flock` probe plus loop state.
pub const AcquireStep = enum {
    acquired,
    sleep_and_retry,
    timeout,
    retry_interrupted,
    interrupted_exhausted,
    resource_exhausted,
    open_failed,
};

pub const AcquireProbe = struct {
    rc: c_int,
    errno: std.c.E,
    elapsed_ns: u128,
    deadline_ns: u128,
    eintr_retries: u32,
};

pub fn nextAcquireStep(p: AcquireProbe) AcquireStep {
    if (p.rc == 0) return .acquired;
    return switch (classifyFlockErrno(p.errno)) {
        .retry_later => if (p.elapsed_ns >= p.deadline_ns) .timeout else .sleep_and_retry,
        .interrupted => if (p.eintr_retries >= MAX_EINTR_RETRIES) .interrupted_exhausted else .retry_interrupted,
        .resource_exhausted => .resource_exhausted,
        .open_failed => .open_failed,
    };
}

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
        errdefer _ = std.c.close(fd);

        const deadline_ns: u128 = @as(u128, @intCast(timeout_ms)) * std.time.ns_per_ms;
        var elapsed_ns: u128 = 0;
        var eintr_retries: u32 = 0;
        const sleep_ns: u64 = 100 * std.time.ns_per_ms;

        acquire_loop: while (true) {
            const rc = std.c.flock(fd, std.c.LOCK.EX | std.c.LOCK.NB);
            // errno is read unconditionally; ignored on rc==0 inside nextAcquireStep.
            const step = nextAcquireStep(.{
                .rc = rc,
                .errno = std.posix.errno(rc),
                .elapsed_ns = elapsed_ns,
                .deadline_ns = deadline_ns,
                .eintr_retries = eintr_retries,
            });
            switch (step) {
                .acquired => break :acquire_loop,
                .sleep_and_retry => {
                    const ts: std.c.timespec = .{
                        .sec = @intCast(sleep_ns / std.time.ns_per_s),
                        .nsec = @intCast(sleep_ns % std.time.ns_per_s),
                    };
                    _ = std.c.nanosleep(&ts, null);
                    elapsed_ns += sleep_ns;
                },
                .retry_interrupted => eintr_retries += 1,
                .timeout => return error.Timeout,
                .resource_exhausted => return error.LockResourceExhausted,
                // Exhausted EINTR retries collapse into OpenFailed — no new tag in scope.
                .interrupted_exhausted, .open_failed => return error.OpenFailed,
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

    /// Bounded retry on WouldBlock so a future O_NONBLOCK flip can't silently hide a held lock.
    fn readHolderBytes(fd: std.posix.fd_t, buf: []u8) ?usize {
        var attempts: u2 = 0;
        while (attempts < 2) : (attempts += 1) {
            return std.posix.read(fd, buf) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return null,
            };
        }
        return null;
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
        const n = readHolderBytes(fd, &buf) orelse return null;
        if (n == 0) return null;

        const trimmed = std.mem.trimEnd(u8, buf[0..n], &[_]u8{ '\n', '\r', ' ' });
        return std.fmt.parseInt(std.posix.pid_t, trimmed, 10) catch null;
    }
};
