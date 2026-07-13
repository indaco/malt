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

    /// Idempotent undo of everything entered, safe to call twice and mid-render.
    /// Reverse of a typical entry (raw → alt → hide): show cursor, leave the
    /// alt-screen, then drop back to cooked mode.
    pub fn restore(self: *Term) void {
        self.showCursor();
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
}

test "cursorMove writes a 1-based CUP sequence" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[3;5H", try cursorMove(&buf, 3, 5));
    try std.testing.expectEqualStrings("\x1b[1;1H", try cursorMove(&buf, 1, 1));
}
