//! malt — terminal size + `SIGWINCH` tracking.
//!
//! `std`-only leaf shared by the CLI progress engine and the `mt tui` terminal
//! layer so the resize machinery lives below both, never reached sideways from
//! `ui/` into `tui/`. Owns the window-size query and a `SIGWINCH` handler that
//! keeps the current `(cols, rows)` live without a keypress.

const std = @import("std");

/// Current terminal geometry. The single source of truth every later layout
/// task renders against.
pub const Size = struct { cols: u16, rows: u16 };

fn packSize(s: Size) u32 {
    return (@as(u32, s.cols) << 16) | s.rows;
}
fn unpackSize(v: u32) Size {
    return .{ .cols = @intCast(v >> 16), .rows = @truncate(v) };
}

/// Query the terminal window size via `TIOCGWINSZ`. `error.NotATty` when the
/// fd is not a terminal — no errno decode, so the degrade path stays quiet.
pub fn winsize(fd: std.posix.fd_t) error{NotATty}!Size {
    var ws: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(fd, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc != 0) return error.NotATty;
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

/// Stricter `SIGWINCH` handler for the CLI progress engine: raise the flag
/// and nothing else. The repaint owner queries the live size in normal
/// context, so no syscall runs in signal context.
fn winchHandlerFlagOnly(_: std.posix.SIG) callconv(.c) void {
    resized_flag.store(true, .release);
}

/// Wire `SIGWINCH` to raise only the resize flag — no `ioctl` in signal
/// context, unlike `installWinch`. The progress engine reads the live width
/// itself on the next render tick. Idempotent like `installWinch`.
pub fn installWinchFlagOnly() void {
    if (winch_installed.swap(true, .acq_rel)) return;
    const act = std.posix.Sigaction{
        .handler = .{ .handler = &winchHandlerFlagOnly },
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
/// Test-only: publish a size the way the handler would, so `currentSize` is
/// unit-testable without a real terminal.
pub fn setSizeForTest(s: Size) void {
    cached_size.store(packSize(s), .release);
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

test "winsize off a non-tty errors cleanly" {
    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    try std.testing.expectError(error.NotATty, winsize(fds[0]));
}

test "installWinch is idempotent" {
    setWinchInstalledForTest(false);
    installWinch(std.posix.STDIN_FILENO);
    try std.testing.expect(winchInstalled());
    installWinch(std.posix.STDIN_FILENO); // second call is a no-op
    try std.testing.expect(winchInstalled());
}

test "takeResized consumes the flag exactly once" {
    setResizedForTest(true);
    try std.testing.expect(takeResized());
    try std.testing.expect(!takeResized());
}

// The install-path handler must do no work in signal context beyond raising
// the flag — proven by a sentinel size left untouched (a `winsize` query
// would overwrite it).
test "flag-only winch handler raises the flag without querying winsize" {
    setResizedForTest(false);
    setSizeForTest(.{ .cols = 111, .rows = 222 });
    winchHandlerFlagOnly(std.posix.SIG.WINCH);
    try std.testing.expect(takeResized());
    try std.testing.expectEqual(Size{ .cols = 111, .rows = 222 }, currentSize());
}

// A redundant install (repeated CLI dispatch, tests re-entering setup) must
// not clobber a flag a prior handler already raised — the swap guard returns
// before re-registering. Mirrors the SIGINT idempotency contract.
test "installWinchFlagOnly does not clobber a raised resize flag" {
    const prior_installed = winchInstalled();
    defer setWinchInstalledForTest(prior_installed);
    setWinchInstalledForTest(false);
    setResizedForTest(false);

    installWinchFlagOnly();
    try std.testing.expect(winchInstalled());

    // Simulate the handler firing between two install attempts.
    setResizedForTest(true);
    installWinchFlagOnly(); // idempotent no-op
    try std.testing.expect(takeResized());
}

test "currentSize reflects the last published size" {
    setSizeForTest(.{ .cols = 80, .rows = 24 });
    try std.testing.expectEqual(Size{ .cols = 80, .rows = 24 }, currentSize());
}
