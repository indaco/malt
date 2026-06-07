//! malt — integration tests for the `tui/term.zig` terminal primitives.
//!
//! Drives the real syscalls (pipes, termios, ioctl, SIGWINCH) the inline unit
//! tests can't: byte output is captured through a pipe drained to EOF, and the
//! TTY-only paths run for real when a terminal is present and degrade-assert
//! otherwise. No PTY — the live resize proof lands in TUI-016.

const std = @import("std");
const testing = std.testing;
const term = @import("malt").tui_term;

const io = std.Options.debug_io;

// Drain a pipe read end to EOF into `buf`. The write end must be closed first
// so this never blocks regardless of how many bytes were written.
fn drainToEof(fd: std.posix.fd_t, buf: []u8) []const u8 {
    var n: usize = 0;
    while (n < buf.len) {
        const r = std.c.read(fd, buf[n..].ptr, buf.len - n);
        if (r <= 0) break;
        n += @intCast(r);
    }
    return buf[0..n];
}

/// First fd among stdin/stdout/stderr that is a real terminal, else null —
/// lets the TTY-only assertions run on a dev terminal and skip in CI.
fn ttyFd() ?std.posix.fd_t {
    for ([_]std.posix.fd_t{ std.posix.STDIN_FILENO, std.posix.STDOUT_FILENO, std.posix.STDERR_FILENO }) |fd| {
        const f: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        if (f.isTty(io) catch false) return fd;
    }
    return null;
}

test "alt-screen + cursor enter/exit are symmetric, idempotent, restore-ordered" {
    var fds: [2]std.posix.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    var t = term.Term.init(io, fds[1]);

    try t.enterAltScreen();
    try t.enterAltScreen(); // idempotent: writes nothing the second time
    try t.hideCursor();
    try t.hideCursor(); // idempotent

    t.restore(); // shows cursor, then leaves the alt-screen
    t.restore(); // idempotent: nothing left to undo

    _ = std.c.close(fds[1]); // EOF terminates the drain
    var buf: [64]u8 = undefined;
    const got = drainToEof(fds[0], &buf);

    const want = term.seq.alt_enter ++ term.seq.cursor_hide ++ term.seq.cursor_show ++ term.seq.alt_leave;
    try testing.expectEqualStrings(want, got);
}

// A render that enters the terminal then fails must leave it restored via the
// caller's `errdefer` — the contract that keeps a crashed TUI from wedging.
fn renderThenFail(t: *term.Term) !void {
    try t.enterAltScreen();
    errdefer t.restore();
    try t.hideCursor();
    return error.Forced;
}

test "restore runs via errdefer when a render errors mid-frame" {
    var fds: [2]std.posix.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    var t = term.Term.init(io, fds[1]);

    try testing.expectError(error.Forced, renderThenFail(&t));

    t.restore(); // re-running after the errdefer already ran is safe

    _ = std.c.close(fds[1]);
    var buf: [64]u8 = undefined;
    const got = drainToEof(fds[0], &buf);

    // entry bytes, then exactly one undo from the errdefer — the second
    // restore emits nothing, proving idempotency through the error path.
    const want = term.seq.alt_enter ++ term.seq.cursor_hide ++ term.seq.cursor_show ++ term.seq.alt_leave;
    try testing.expectEqualStrings(want, got);
}

test "enterRaw off a non-tty errors cleanly and enters no state" {
    var fds: [2]std.posix.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    var t = term.Term.init(io, fds[1]);

    try testing.expectError(term.TermError.NotATty, t.enterRaw());
    t.restore(); // safe even though nothing was entered
}

test "winsize off a non-tty errors cleanly" {
    var fds: [2]std.posix.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    try testing.expectError(term.TermError.NotATty, term.winsize(fds[0]));
}

test "on a real tty, winsize reports a non-zero size and raw round-trips termios" {
    const fd = ttyFd() orelse return error.SkipZigTest;

    const size = try term.winsize(fd);
    try testing.expect(size.cols > 0 and size.rows > 0);

    const before = try std.posix.tcgetattr(fd);
    var t = term.Term.init(io, fd);
    try t.enterRaw();
    // While raw: echo/canon off for byte-at-a-time reads, and ISIG off so
    // Ctrl-C arrives as a 0x03 byte (decoder -> quit) instead of a signal.
    const raw = try std.posix.tcgetattr(fd);
    try testing.expect(!raw.lflag.ECHO);
    try testing.expect(!raw.lflag.ICANON);
    try testing.expect(!raw.lflag.ISIG);
    t.restore(); // must put cooked mode back exactly
    const after = try std.posix.tcgetattr(fd);
    try testing.expectEqual(before.lflag, after.lflag);
    try testing.expectEqual(before.cc, after.cc);
}

test "SIGWINCH delivery sets the resized flag with no input read" {
    term.setWinchInstalledForTest(false);
    term.setResizedForTest(false);
    term.installWinch(std.posix.STDIN_FILENO);
    try testing.expect(term.winchInstalled());

    try std.posix.raise(std.posix.SIG.WINCH);

    try testing.expect(term.takeResized()); // raised by the handler alone
    try testing.expect(!term.takeResized()); // consumed exactly once
}

test "installWinch is idempotent and never clobbers a raised flag" {
    term.setWinchInstalledForTest(false);
    term.setResizedForTest(false);

    term.installWinch(std.posix.STDIN_FILENO);
    try testing.expect(term.winchInstalled());

    // Simulate the handler firing between two install attempts.
    term.setResizedForTest(true);
    term.installWinch(std.posix.STDIN_FILENO); // second call is a no-op
    try testing.expect(term.winchInstalled());
    try testing.expect(term.takeResized()); // flag survived the re-install
}
