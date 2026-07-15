//! malt — terminal control primitives for `mt tui`.
//!
//! Leaf module: imports only `std` and the shared `ui/termsize` +
//! `ui/term_restore` leaves (the `mt tui` dashboard pressure-tests the
//! `--json` contract instead of reaching into `cli/*`/`core/*`). Provides
//! raw-mode, alternate-screen, and cursor machinery; window-size + `SIGWINCH`
//! tracking lives in `ui/termsize` and is re-exported here. A single
//! idempotent `restore()` undoes everything entered and is wired through
//! `errdefer` downstream; `enterRaw` also mirrors the saved termios into the
//! `ui/term_restore` registry so the panic hook and termination-signal
//! handlers can restore even when defers never run.

const std = @import("std");
const termsize = @import("../ui/termsize.zig");
const term_restore = @import("../ui/term_restore.zig");

/// Window-size + `SIGWINCH` tracking lives in the shared `ui/termsize` leaf so
/// the CLI side can reuse it without reaching into the TUI. Re-exported here so
/// existing `term.*` callers compile unchanged.
pub const Size = termsize.Size;
pub const winsize = termsize.winsize;
pub const installWinch = termsize.installWinch;
pub const winchInstalled = termsize.winchInstalled;
pub const takeResized = termsize.takeResized;
pub const currentSize = termsize.currentSize;
pub const setWinchInstalledForTest = termsize.setWinchInstalledForTest;
pub const setResizedForTest = termsize.setResizedForTest;

/// Crash-only escape hatch, re-exported from `ui/term_restore` so the TUI
/// run loop wires termination signals next to `installWinch`.
pub const installCrashSignals = term_restore.installCrashSignals;

/// Escape sequences whose effect is idempotent at the terminal level, so the
/// state guards below only exist to avoid redundant writes, not to stay correct.
pub const seq = struct {
    pub const alt_enter = "\x1b[?1049h";
    pub const alt_leave = "\x1b[?1049l";
    pub const cursor_hide = "\x1b[?25l";
    pub const cursor_show = "\x1b[?25h";
    pub const erase_line = "\x1b[K"; // erase from cursor to end of line
    // ?1000 button+wheel, ?1006 SGR extended coords. Not ?1002/?1003 motion,
    // which would flood the loop.
    pub const mouse_enable = "\x1b[?1000h\x1b[?1006h";
    pub const mouse_disable = "\x1b[?1000l\x1b[?1006l";
    // Bracket a frame so a supporting terminal buffers the whole repaint and
    // swaps it atomically; a terminal that ignores them still renders correctly.
    pub const sync_begin = "\x1b[?2026h";
    pub const sync_end = "\x1b[?2026l";
};

/// Write a 1-based cursor-position (CUP) sequence into a caller buffer, the
/// `progress.zig` no-hidden-writer convention. `error.NoSpaceLeft` only when the
/// buffer is undersized — a 32-byte buffer always suffices.
pub fn cursorMove(buf: []u8, row: u16, col: u16) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buf, "\x1b[{d};{d}H", .{ row, col });
}

pub const TermError = error{ NotATty, WriteFailed, TermiosFailed };

/// A live terminal session. Tracks exactly what was entered so `restore`
/// undoes precisely those things, idempotently and in a crash-safe order.
/// `fd` is the controlling terminal (read+write); `io` only services the
/// `isTty` probe so the raw-mode path degrades cleanly off a TTY.
pub const Term = struct {
    io: std.Io,
    fd: std.posix.fd_t,
    saved: ?std.posix.termios = null,
    in_alt: bool = false,
    cursor_hidden: bool = false,
    mouse_on: bool = false,

    pub fn init(io: std.Io, fd: std.posix.fd_t) Term {
        return .{ .io = io, .fd = fd };
    }

    fn writeAll(self: *const Term, bytes: []const u8) TermError!void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = std.c.write(self.fd, bytes[off..].ptr, bytes.len - off);
            if (n <= 0) return TermError.WriteFailed;
            off += @intCast(n);
        }
    }

    pub fn enterAltScreen(self: *Term) TermError!void {
        if (self.in_alt) return;
        try self.writeAll(seq.alt_enter);
        self.in_alt = true;
    }

    pub fn exitAltScreen(self: *Term) void {
        if (!self.in_alt) return;
        // Best-effort on the way out: a vanished tty has nothing to restore.
        self.writeAll(seq.alt_leave) catch {};
        self.in_alt = false;
    }

    pub fn hideCursor(self: *Term) TermError!void {
        if (self.cursor_hidden) return;
        try self.writeAll(seq.cursor_hide);
        self.cursor_hidden = true;
    }

    pub fn showCursor(self: *Term) void {
        if (!self.cursor_hidden) return;
        self.writeAll(seq.cursor_show) catch {};
        self.cursor_hidden = false;
    }

    pub fn enableMouse(self: *Term) TermError!void {
        if (self.mouse_on) return;
        try self.writeAll(seq.mouse_enable);
        self.mouse_on = true;
    }

    pub fn disableMouse(self: *Term) void {
        if (!self.mouse_on) return;
        // Best-effort on the way out: a vanished tty has nothing to restore.
        self.writeAll(seq.mouse_disable) catch {};
        self.mouse_on = false;
    }

    /// Idempotent undo of everything entered, safe to call twice and mid-render.
    /// Reverse of entry (raw → alt → hide): show cursor, leave the alt-screen,
    /// then drop back to cooked mode. disableMouse is folded in ahead of the
    /// alt-screen leave so a later enableMouse unwinds here too.
    pub fn restore(self: *Term) void {
        self.showCursor();
        self.disableMouse();
        self.exitAltScreen();
        self.exitRaw();
    }

    fn isTty(self: *const Term) bool {
        const f: std.Io.File = .{ .handle = self.fd, .flags = .{ .nonblocking = false } };
        return f.isTty(self.io) catch false;
    }

    /// Enter cbreak/raw input: ECHO + ICANON + ISIG off, byte-at-a-time reads.
    /// Saves the original termios for `exitRaw`/`restore`. Idempotent; cleanly
    /// `error.NotATty` off a terminal with no half-entered state.
    pub fn enterRaw(self: *Term) TermError!void {
        if (self.saved != null) return; // idempotent
        if (!self.isTty()) return TermError.NotATty; // guard avoids a noisy tcgetattr
        const saved = std.posix.tcgetattr(self.fd) catch return TermError.TermiosFailed;
        var raw = saved;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        // ISIG off so Ctrl-C reaches the key decoder as a byte (-> quit) instead
        // of raising SIGINT, which the global CLI handler would swallow. Cooked
        // mode (with ISIG) is restored on exit, and during a delegated `mt` run
        // (`restore` then re-`enterRaw`), so Ctrl-C still interrupts the child.
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        std.posix.tcsetattr(self.fd, .FLUSH, raw) catch return TermError.TermiosFailed;
        self.saved = saved;
        // Mirror into the crash registry: defers never run on panic or a
        // termination signal, and this stack-local `saved` is unreachable
        // from those process-global paths.
        term_restore.register(self.fd, saved);
    }

    pub fn exitRaw(self: *Term) void {
        const saved = self.saved orelse return;
        term_restore.clear();
        // Best-effort: a gone tty cannot be put back, and there is no sane
        // recovery from inside restore/errdefer.
        std.posix.tcsetattr(self.fd, .FLUSH, saved) catch {};
        self.saved = null;
    }
};

test "alt-screen and cursor escape sequences are the expected bytes" {
    try std.testing.expectEqualStrings("\x1b[?1049h", seq.alt_enter);
    try std.testing.expectEqualStrings("\x1b[?1049l", seq.alt_leave);
    try std.testing.expectEqualStrings("\x1b[?25l", seq.cursor_hide);
    try std.testing.expectEqualStrings("\x1b[?25h", seq.cursor_show);
    try std.testing.expectEqualStrings("\x1b[K", seq.erase_line);
    try std.testing.expectEqualStrings("\x1b[?2026h", seq.sync_begin);
    try std.testing.expectEqualStrings("\x1b[?2026l", seq.sync_end);
    try std.testing.expectEqualStrings("\x1b[?1000h\x1b[?1006h", seq.mouse_enable);
    try std.testing.expectEqualStrings("\x1b[?1000l\x1b[?1006l", seq.mouse_disable);
}

test "cursorMove writes a 1-based CUP sequence" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[3;5H", try cursorMove(&buf, 3, 5));
    try std.testing.expectEqualStrings("\x1b[1;1H", try cursorMove(&buf, 1, 1));
}

// A pipe stands in for the tty so tests can read back exactly what `Term`
// writes; `io` is untouched by the write helpers, so `undefined` is safe.
fn termOnPipe(write_fd: std.posix.fd_t) Term {
    return .{ .io = undefined, .fd = write_fd };
}

// Non-blocking read end so an under-writing helper fails the read assertion
// instead of hanging the test.
fn setNonblock(read_fd: std.posix.fd_t) !void {
    const nonblock: c_int = @bitCast(std.posix.O{ .NONBLOCK = true });
    try std.testing.expect(std.c.fcntl(read_fd, std.posix.F.SETFL, nonblock) != -1);
}

test "enableMouse twice writes mouse_enable once and flips mouse_on" {
    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    try setNonblock(fds[0]);

    var t = termOnPipe(fds[1]);
    try t.enableMouse();
    try t.enableMouse(); // idempotent guard: no second write
    try std.testing.expect(t.mouse_on);

    // Sentinel proves the guard wrote nothing after the first enable.
    try std.testing.expectEqual(@as(isize, 1), std.c.write(fds[1], "S", 1));
    var buf: [seq.mouse_enable.len + 1]u8 = undefined;
    var got: usize = 0;
    while (got < buf.len) {
        const n = std.c.read(fds[0], buf[got..].ptr, buf.len - got);
        try std.testing.expect(n > 0);
        got += @intCast(n);
    }
    try std.testing.expectEqualStrings(seq.mouse_enable ++ "S", &buf);
}

test "disableMouse writes nothing when mouse_on is false" {
    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    try setNonblock(fds[0]);

    var t = termOnPipe(fds[1]);
    t.disableMouse(); // never enabled -> guard skips the write

    // A sentinel must be the first byte readable; a stray disable would precede it.
    try std.testing.expectEqual(@as(isize, 1), std.c.write(fds[1], "S", 1));
    var buf: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 1), std.c.read(fds[0], &buf, buf.len));
    try std.testing.expectEqual(@as(u8, 'S'), buf[0]);
}

test "restore emits mouse_disable before alt_leave" {
    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    try setNonblock(fds[0]);

    // Cursor not hidden, not in raw: restore's only writes are the mouse and
    // alt-screen ones, so their order is observable in isolation.
    var t = Term{ .io = undefined, .fd = fds[1], .in_alt = true, .mouse_on = true };
    t.restore();

    const want = seq.mouse_disable ++ seq.alt_leave;
    var buf: [want.len]u8 = undefined;
    var got: usize = 0;
    while (got < buf.len) {
        const n = std.c.read(fds[0], buf[got..].ptr, buf.len - got);
        try std.testing.expect(n > 0);
        got += @intCast(n);
    }
    try std.testing.expectEqualStrings(want, &buf);
}
