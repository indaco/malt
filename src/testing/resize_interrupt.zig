//! malt — test-only fixture: a tty write that blocks on a full pipe and is
//! hit by SIGWINCH, the way a resize interrupts a real terminal write.

const std = @import("std");

// `std.c` lacks this one; the port is borrowed, so it is never released.
extern "c" fn pthread_mach_thread_np(std.c.pthread_t) std.c.mach_port_t;
// TH_STATE_WAITING in <mach/thread_info.h>.
const th_state_waiting = 3;
// Signals that must hit a blocked call; two rule out a one-off wake-up.
const wanted_hits = 2;
// About 2 s of 1 ms polls: a caller that never blocks must not hang the test.
const max_polls = 2000;

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
    port: std.c.mach_port_t,
    /// Signals that landed while the target was blocked.
    hits: usize = 0,
    interrupted: std.atomic.Value(bool) = .init(false),

    pub fn init() !Fixture {
        var fds: [2]std.posix.fd_t = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
        errdefer {
            _ = std.c.close(fds[0]);
            _ = std.c.close(fds[1]);
        }
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
        return .{ .fds = fds, .filled = filled, .old = old, .target = std.c.pthread_self(), .port = pthread_mach_thread_np(std.c.pthread_self()) };
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

    /// Signals the calling thread while it is blocked, then drains the pipe so
    /// the blocked write can finish. A call that starts late is still caught.
    pub fn start(self: *Fixture) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Blocks until the signals are sent. For tests that own their release.
    pub fn waitInterrupted(self: *Fixture) void {
        while (!self.interrupted.load(.acquire)) pause(1);
    }

    /// Joins the helper and returns every byte that went through the pipe.
    /// Fails when no signal hit a blocked call: the test proved nothing.
    pub fn finish(self: *Fixture) !usize {
        self.thread.?.join();
        self.thread = null;
        self.drained += drain(self.fds[0]);
        try std.testing.expect(self.hits > 0);
        return self.drained;
    }

    fn run(self: *Fixture) void {
        var polls: usize = 0;
        while (self.hits < wanted_hits and polls < max_polls) : (polls += 1) {
            pause(1);
            if (!self.targetWaiting()) continue;
            _ = std.c.pthread_kill(self.target, .WINCH);
            self.hits += 1;
            pause(10);
        }
        self.interrupted.store(true, .release);
        self.drained += drain(self.fds[0]);
    }

    fn targetWaiting(self: *const Fixture) bool {
        var info: std.c.thread_basic_info = undefined;
        var count: std.c.mach_msg_type_number_t = std.c.THREAD.BASIC.INFO_COUNT;
        const rc = std.c.thread_info(self.port, std.c.THREAD.BASIC.INFO, @ptrCast(&info), &count);
        return rc == 0 and info.run_state == th_state_waiting;
    }

    fn pause(ms: u32) void {
        const gap = std.c.timespec{ .sec = 0, .nsec = ms * std.time.ns_per_ms };
        _ = std.c.nanosleep(&gap, null);
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

/// Spins instead of sleeping: the fixture's SIGWINCH would cut a nanosleep short.
fn busyWait(ms: i64) void {
    var t0: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &t0);
    while (true) {
        var t: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &t);
        if ((t.sec - t0.sec) * 1000 + @divTrunc(t.nsec - t0.nsec, 1_000_000) >= ms) return;
    }
}

/// One write, no EINTR retry: the bug the fixture exists to catch.
fn writeOnce(fd: std.posix.fd_t, bytes: []const u8) void {
    _ = std.c.write(fd, bytes.ptr, bytes.len);
}

fn writeRetry(fd: std.posix.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) return;
        off += @intCast(n);
    }
}

test "late caller without an EINTR retry is caught" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.start();
    busyWait(300);
    writeOnce(fx.writeFd(), "0123456789");
    try std.testing.expect(try fx.finish() != fx.filled + 10);
}

test "late caller with an EINTR retry delivers every byte" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.start();
    busyWait(300);
    writeRetry(fx.writeFd(), "0123456789");
    try std.testing.expectEqual(fx.filled + 10, try fx.finish());
}

test "immediate caller with an EINTR retry delivers every byte" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.start();
    writeRetry(fx.writeFd(), "0123456789");
    try std.testing.expectEqual(fx.filled + 10, try fx.finish());
    try std.testing.expect(fx.hits > 0);
}

test "finish fails when no signal hit a blocked call" {
    var fx = try Fixture.init();
    defer fx.deinit();
    // A helper that sends nothing leaves `hits` at zero.
    fx.thread = try std.Thread.spawn(.{}, struct {
        fn run() void {}
    }.run, .{});
    try std.testing.expectError(error.TestUnexpectedResult, fx.finish());
}
