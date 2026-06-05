//! malt — terminal control primitives for `mt tui`.
//!
//! Leaf module: imports only `std` (the `mt tui` dashboard pressure-tests
//! the `--json` contract instead of reaching into `cli/*`/`core/*`). Provides
//! raw-mode, alternate-screen, cursor, and window-size machinery plus a
//! `SIGWINCH` handler so the current `(cols, rows)` stays live without a
//! keypress. A single idempotent `restore()` undoes everything entered and is
//! wired through `errdefer` downstream so a crash can never wedge the terminal.

const std = @import("std");

/// Current terminal geometry. The single source of truth every later layout
/// task renders against.
pub const Size = struct { cols: u16, rows: u16 };

/// Escape sequences whose effect is idempotent at the terminal level, so the
/// state guards below only exist to avoid redundant writes, not to stay correct.
pub const seq = struct {
    pub const alt_enter = "\x1b[?1049h";
    pub const alt_leave = "\x1b[?1049l";
    pub const cursor_hide = "\x1b[?25l";
    pub const cursor_show = "\x1b[?25h";
};

/// Write a 1-based cursor-position (CUP) sequence into a caller buffer, the
/// `progress.zig` no-hidden-writer convention. `error.NoSpaceLeft` only when the
/// buffer is undersized — a 32-byte buffer always suffices.
pub fn cursorMove(buf: []u8, row: u16, col: u16) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buf, "\x1b[{d};{d}H", .{ row, col });
}

fn packSize(s: Size) u32 {
    return (@as(u32, s.cols) << 16) | s.rows;
}
fn unpackSize(v: u32) Size {
    return .{ .cols = @intCast(v >> 16), .rows = @truncate(v) };
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

    /// Enter cbreak/raw input: ECHO + ICANON off, byte-at-a-time reads. Saves
    /// the original termios for `exitRaw`/`restore`. Idempotent; cleanly
    /// `error.NotATty` off a terminal with no half-entered state.
    pub fn enterRaw(self: *Term) TermError!void {
        if (self.saved != null) return; // idempotent
        if (!self.isTty()) return TermError.NotATty; // guard avoids a noisy tcgetattr
        const saved = std.posix.tcgetattr(self.fd) catch return TermError.TermiosFailed;
        var raw = saved;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        std.posix.tcsetattr(self.fd, .FLUSH, raw) catch return TermError.TermiosFailed;
        self.saved = saved;
    }

    pub fn exitRaw(self: *Term) void {
        const saved = self.saved orelse return;
        // Best-effort: a gone tty cannot be put back, and there is no sane
        // recovery from inside restore/errdefer.
        std.posix.tcsetattr(self.fd, .FLUSH, saved) catch {};
        self.saved = null;
    }
};

/// Query the terminal window size via `TIOCGWINSZ`. `error.NotATty` when the
/// fd is not a terminal — no errno decode, so the degrade path stays quiet.
pub fn winsize(fd: std.posix.fd_t) TermError!Size {
    var ws: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(fd, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc != 0) return TermError.NotATty;
    return .{ .cols = ws.col, .rows = ws.row };
}

// ─── SIGWINCH resize tracking ────────────────────────────────────────
//
// Process-global because a signal handler carries no context, mirroring
// `core/signals.zig`. The handler is the only writer; the main thread reads
// the flag and the packed size between input reads, so a resize is observed
// without any keypress.

var resized_flag: std.atomic.Value(bool) = .init(false);
var cached_size: std.atomic.Value(u32) = .init(0);
var winch_installed: std.atomic.Value(bool) = .init(false);
var winch_fd: std.posix.fd_t = -1;

fn winchHandler(_: std.posix.SIG) callconv(.c) void {
    resized_flag.store(true, .release);
    // A single ioctl is signal-safe in practice; refreshing here is what lets
    // a resize be seen without a read. A failed query keeps the last size.
    if (winsize(winch_fd)) |s| {
        cached_size.store(packSize(s), .release);
    } else |_| {}
}

/// Wire `SIGWINCH` to keep `(cols, rows)` live. `fd` is the terminal queried
/// in-handler. Idempotent so re-entry (tests, repeated dispatch) neither
/// double-registers nor clobbers a flag the handler already raised.
pub fn installWinch(fd: std.posix.fd_t) void {
    if (winch_installed.swap(true, .acq_rel)) return;
    winch_fd = fd;
    if (winsize(fd)) |s| cached_size.store(packSize(s), .release) else |_| {}
    const act = std.posix.Sigaction{
        .handler = .{ .handler = &winchHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.WINCH, &act, null);
}

pub fn winchInstalled() bool {
    return winch_installed.load(.acquire);
}

/// True exactly once per resize: consumes the flag so the event loop reacts
/// to each `SIGWINCH` a single time.
pub fn takeResized() bool {
    return resized_flag.swap(false, .acq_rel);
}

/// Last geometry seen by the handler (or the install-time seed).
pub fn currentSize() Size {
    return unpackSize(cached_size.load(.acquire));
}

/// Test-only: seed/reset the process-global install + flag state between
/// cases so a test starts from a known baseline (mirrors `core/signals.zig`).
pub fn setWinchInstalledForTest(v: bool) void {
    winch_installed.store(v, .release);
}
pub fn setResizedForTest(v: bool) void {
    resized_flag.store(v, .release);
}

test "alt-screen and cursor escape sequences are the expected bytes" {
    try std.testing.expectEqualStrings("\x1b[?1049h", seq.alt_enter);
    try std.testing.expectEqualStrings("\x1b[?1049l", seq.alt_leave);
    try std.testing.expectEqualStrings("\x1b[?25l", seq.cursor_hide);
    try std.testing.expectEqualStrings("\x1b[?25h", seq.cursor_show);
}

test "cursorMove writes a 1-based CUP sequence" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[3;5H", try cursorMove(&buf, 3, 5));
    try std.testing.expectEqualStrings("\x1b[1;1H", try cursorMove(&buf, 1, 1));
}

test "Size carries cols and rows" {
    const s: Size = .{ .cols = 80, .rows = 24 };
    try std.testing.expectEqual(@as(u16, 80), s.cols);
    try std.testing.expectEqual(@as(u16, 24), s.rows);
}

// A Size packs into one u32 so the SIGWINCH handler can publish it with a
// single atomic store the main thread reads without a torn value.
test "packSize/unpackSize round-trip a Size losslessly" {
    const cases = [_]Size{
        .{ .cols = 0, .rows = 0 },
        .{ .cols = 80, .rows = 24 },
        .{ .cols = 65535, .rows = 65535 },
        .{ .cols = 1, .rows = 65535 },
    };
    for (cases) |s| try std.testing.expectEqual(s, unpackSize(packSize(s)));
}
