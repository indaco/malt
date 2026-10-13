//! malt — test-only fixture: a tty write that blocks on a full pipe and is
//! hit by SIGWINCH, the way a resize interrupts a real terminal write.

const std = @import("std");

/// A pipe whose write end is full, so the next `write(2)` blocks with zero
/// bytes moved (a partial transfer would hide the EINTR). Installs a no-op
/// SIGWINCH handler without SA_RESTART, like `termsize.installWinch`.
pub const Fixture = struct {
    fds: [2]std.posix.fd_t,
    filled: usize,
    old: std.posix.Sigaction,
    thread: ?std.Thread = null,
    target: std.c.pthread_t,
    drained: usize = 0,

    pub fn init() !Fixture {
        var fds: [2]std.posix.fd_t = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
        const nonblock: c_int = @bitCast(std.posix.O{ .NONBLOCK = true });
        try std.testing.expect(std.c.fcntl(fds[1], std.posix.F.SETFL, nonblock) != -1);
        const chunk = [_]u8{0} ** 4096;
        var filled: usize = 0;
        while (true) {
            const n = std.c.write(fds[1], &chunk, chunk.len);
            if (n <= 0) break;
            filled += @intCast(n);
        }
        try std.testing.expect(std.c.fcntl(fds[1], std.posix.F.SETFL, @as(c_int, 0)) != -1);
        // Non-blocking read end: a drain stops at empty instead of hanging.
        try std.testing.expect(std.c.fcntl(fds[0], std.posix.F.SETFL, nonblock) != -1);

        // The disposition is process-global; `deinit` puts the old one back.
        var old: std.posix.Sigaction = undefined;
        const act = std.posix.Sigaction{
            .handler = .{ .handler = &noop },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.WINCH, &act, &old);
        return .{ .fds = fds, .filled = filled, .old = old, .target = std.c.pthread_self() };
    }

    pub fn deinit(self: *Fixture) void {
        if (self.thread) |t| t.join();
        std.posix.sigaction(.WINCH, &self.old, null);
        _ = std.c.close(self.fds[0]);
        _ = std.c.close(self.fds[1]);
    }

    /// Write end under test. Call `start` right before the blocking write.
    pub fn writeFd(self: *const Fixture) std.posix.fd_t {
        return self.fds[1];
    }

    /// Signals the calling thread a few times, then drains the pipe so the
    /// blocked write can finish. Repeating covers a signal that lands before
    /// the write blocks; the bound keeps a broken retry from hanging.
    pub fn start(self: *Fixture) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Joins the helper and returns every byte that went through the pipe.
    /// The caller's write has returned by now, so a main-thread drain after
    /// the join sees whatever the helper's drain missed.
    pub fn finish(self: *Fixture) usize {
        self.thread.?.join();
        self.thread = null;
        self.drained += drain(self.fds[0]);
        return self.drained;
    }

    fn run(self: *Fixture) void {
        const gap = std.c.timespec{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
        for (0..4) |_| {
            _ = std.c.nanosleep(&gap, null);
            _ = std.c.pthread_kill(self.target, .WINCH);
        }
        _ = std.c.nanosleep(&gap, null);
        self.drained += drain(self.fds[0]);
    }

    fn drain(fd: std.posix.fd_t) usize {
        var buf: [4096]u8 = undefined;
        var got: usize = 0;
        while (true) {
            const n = std.c.read(fd, &buf, buf.len);
            if (n <= 0) return got;
            got += @intCast(n);
        }
    }

    fn noop(_: std.posix.SIG) callconv(.c) void {}
};
