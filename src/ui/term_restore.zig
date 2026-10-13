//! malt — signal-safe crash-restore registry for terminal state.
//!
//! `std`-only leaf (tests use `testing/resize_interrupt.zig`) in the `ui/`
//! sink layer, below both the CLI progress engine and `tui/term.zig`. The
//! TUI's saved termios lives on the run loop's stack, unreachable from the process-global panic hook and from
//! signal handlers; this registry mirrors the two fields the crash path
//! needs — the terminal fd and the pre-raw termios — so either path can
//! put the terminal back before the process dies. The TUI and the OSC 11
//! background probe are the two raw-mode users.

const std = @import("std");

/// Everything a crashing raw-mode process must emit: leave the alt screen,
/// show the cursor, re-enable autowrap, return to column 0, and stop mouse
/// reporting so a dead shell isn't buried in report bytes. Emitting these
/// while the mode was never entered is a no-op on xterm-family terminals, so
/// the crash path never tracks alt-screen or mouse state separately.
pub const restore_seq = "\x1b[?1049l\x1b[?25h\x1b[?7h\r\x1b[?1000l\x1b[?1006l";

// The flag flips `.release` only after fd/termios are in place, so a crash
// path's `.acquire` load never observes a half-written registration.
var active: std.atomic.Value(bool) = .init(false);
var reg_fd: std.posix.fd_t = -1;
var reg_termios: std.posix.termios = undefined;
var reg_emit_seq: bool = true;

/// Record the terminal to restore on a crash. One registration at a time —
/// the TUI or the colour probe owns at most one raw terminal.
pub fn register(fd: std.posix.fd_t, saved: std.posix.termios) void {
    reg_fd = fd;
    reg_termios = saved;
    reg_emit_seq = true;
    active.store(true, .release);
}

/// Like `register`, for a raw window that never touched the screen: the crash
/// path restores the termios only and writes no escape sequences.
pub fn registerTermios(fd: std.posix.fd_t, saved: std.posix.termios) void {
    reg_fd = fd;
    reg_termios = saved;
    reg_emit_seq = false;
    active.store(true, .release);
}

/// True while a registration is held, so a second raw window can tell it
/// does not own the restore.
pub fn isActive() bool {
    return active.load(.acquire);
}

/// Forget the registration once the owner has restored the terminal itself.
pub fn clear() void {
    active.store(false, .release);
}

/// Put the registered terminal back from a panic or signal handler.
/// Async-signal-safe: no allocation, no locks, only `write` + `tcsetattr`,
/// both best-effort. Idempotent and a no-op when nothing is registered.
pub fn crashRestore() void {
    if (!active.load(.acquire)) return;
    var off: usize = if (reg_emit_seq) 0 else restore_seq.len;
    while (off < restore_seq.len) {
        const n = std.c.write(reg_fd, restore_seq[off..].ptr, restore_seq.len - off);
        if (n < 0 and std.posix.errno(n) == .INTR) continue; // a signal (e.g. resize) interrupted the write
        if (n <= 0) break; // best-effort: a vanished tty has nothing to restore
        off += @intCast(n);
    }
    std.posix.tcsetattr(reg_fd, .FLUSH, reg_termios) catch {};
}

/// Termination signals that must restore the terminal before the process
/// dies. `SIGINT` is absent: TUI raw mode turns `ISIG` off, so Ctrl-C arrives
/// as a byte. The colour probe keeps `ISIG` on (see `queryOsc11Background`),
/// so a second SIGINT inside its window is not covered.
const crash_signals = [_]std.posix.SIG{ .TERM, .HUP, .QUIT };

fn crashSignalHandler(sig: std.posix.SIG) callconv(.c) void {
    crashRestore();
    // SA_RESETHAND already restored the default disposition; re-raising
    // delivers it when the handler returns, so the parent still observes
    // death-by-signal and SIGQUIT keeps its core-dump semantics.
    std.posix.raise(sig) catch {};
}

/// Wire `SIGTERM`/`SIGHUP`/`SIGQUIT` to restore-then-die, for the TUI. With
/// nothing registered the handler just re-raises. Handled signals reset to
/// default on `execve`, so delegated children are unaffected.
pub fn installCrashSignals() void {
    install(false);
}

/// Same wiring for the colour probe, which runs in any command: a signal the
/// parent chose to ignore (`trap '' TERM`) stays ignored, children included.
pub fn installCrashSignalsKeepIgnored() void {
    install(true);
}

fn install(keep_ignored: bool) void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = &crashSignalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESETHAND,
    };
    for (crash_signals) |sig| {
        var old: std.posix.Sigaction = undefined;
        std.posix.sigaction(sig, null, &old);
        if (keep_ignored and old.handler.handler == std.posix.SIG.IGN) continue;
        std.posix.sigaction(sig, &act, null);
    }
}

// The regression script exercises SIGTERM end-to-end on a real pty; this
// pins that HUP and QUIT get the same restore-then-die wiring. SA_RESETHAND
// is not asserted here — Darwin does not report it back through a sigaction
// query — its effect is covered by the death-by-signal test below.
test "restore_seq disables mouse tracking so a dead shell stops receiving reports" {
    try std.testing.expectEqualStrings(
        "\x1b[?1049l\x1b[?25h\x1b[?7h\r\x1b[?1000l\x1b[?1006l",
        restore_seq,
    );
}

// A runner started with `&` or `trap ''` inherits ignored signals, which would
// mask what these tests install; start each from the default disposition.
fn resetCrashSignals() void {
    const dfl = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    for (crash_signals) |sig| std.posix.sigaction(sig, &dfl, null);
}

test "installCrashSignals wires TERM/HUP/QUIT to the restore handler" {
    var prev: [crash_signals.len]std.posix.Sigaction = undefined;
    for (crash_signals, 0..) |sig, i| std.posix.sigaction(sig, null, &prev[i]);
    defer for (crash_signals, 0..) |sig, i| std.posix.sigaction(sig, &prev[i], null);
    resetCrashSignals();

    installCrashSignals();
    for (crash_signals) |sig| {
        var act: std.posix.Sigaction = undefined;
        std.posix.sigaction(sig, null, &act);
        try std.testing.expectEqual(&crashSignalHandler, act.handler.handler);
    }
}

// Forked child: install the crash handlers, then raise the signal on
// ourselves. With SA_RESETHAND intact the handler's re-raise is fatal; if
// the flag ever regressed, delivery would loop through the handler forever
// and the parent's deadline below catches it. Exit 0 marks "survived", which
// the parent treats as failure.
fn raiseAndDie(sig: std.posix.SIG) noreturn {
    clear(); // inherited registration would make crashRestore scribble on a test pipe
    resetCrashSignals();
    // A runner may block these in its mask; a blocked raise stays pending.
    var unblock = std.posix.sigemptyset();
    for (crash_signals) |s| std.posix.sigaddset(&unblock, s);
    std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &unblock, null);
    installCrashSignals();
    std.posix.raise(sig) catch {};
    std.process.exit(0);
}

// Darwin won't report SA_RESETHAND back through a sigaction query, so pin
// its observable contract instead: a handled termination signal still kills
// the process *by that signal* (the parent must see a signaled wait status,
// not an exit).
test "a handled termination signal is fatal and preserves death-by-signal" {
    // A tracer (kcov) intercepts the child's signal-stop instead of letting
    // it die, so death-by-signal is unobservable and the wait below times
    // out. Same opt-out the subprocess tests use; live under `zig build test`.
    if (std.c.getenv("MALT_SKIP_SUBPROCESS_TESTS") != null) return error.SkipZigTest;

    for (crash_signals) |sig| {
        const pid = std.c.fork();
        try std.testing.expect(pid >= 0);
        if (pid == 0) raiseAndDie(sig);

        var status: c_int = undefined;
        var waited_ms: usize = 0;
        const reaped = while (waited_ms < 5000) : (waited_ms += 50) {
            if (std.c.waitpid(pid, &status, std.c.W.NOHANG) == pid) break true;
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
        } else false;
        if (!reaped) {
            // A child still alive is the RESETHAND regression: its handler
            // re-raise loops instead of dying. Reap and fail.
            std.posix.kill(pid, .KILL) catch {};
            _ = std.c.waitpid(pid, &status, 0);
            return error.HandledSignalNotFatal;
        }

        const st: u32 = @bitCast(status);
        try std.testing.expect(std.c.W.IFSIGNALED(st));
        try std.testing.expectEqual(sig, std.c.W.TERMSIG(st));
    }
}

test "crashRestore writes exactly the restore sequence and is safe to call twice" {
    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    // Non-blocking read end: a restore that writes nothing fails the test
    // instead of hanging it.
    const nonblock: c_int = @bitCast(std.posix.O{ .NONBLOCK = true });
    try std.testing.expect(std.c.fcntl(fds[0], std.posix.F.SETFL, nonblock) != -1);

    // tcsetattr on a pipe fails — swallowing it IS the best-effort contract.
    register(fds[1], std.mem.zeroes(std.posix.termios));
    defer clear();
    crashRestore();
    crashRestore(); // still registered: panic hook and signal path may both fire

    var buf: [2 * restore_seq.len]u8 = undefined;
    var got: usize = 0;
    while (got < buf.len) {
        const n = std.c.read(fds[0], buf[got..].ptr, buf.len - got);
        try std.testing.expect(n > 0);
        got += @intCast(n);
    }
    try std.testing.expectEqualStrings(restore_seq ++ restore_seq, &buf);
}

test "crashRestore after register/clear round-trip writes nothing" {
    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    register(fds[1], std.mem.zeroes(std.posix.termios));
    clear();
    crashRestore();

    // A sentinel byte must be the first thing readable — an unregistered
    // restore that wrote anything would land ahead of it.
    try std.testing.expectEqual(@as(isize, 1), std.c.write(fds[1], "S", 1));
    var buf: [restore_seq.len]u8 = undefined;
    const n = std.c.read(fds[0], &buf, buf.len);
    try std.testing.expectEqual(@as(isize, 1), n);
    try std.testing.expectEqual(@as(u8, 'S'), buf[0]);
}

test "crashRestore delivers the whole sequence when a signal interrupts a blocked write" {
    var fx = try @import("../testing/resize_interrupt.zig").Fixture.init();
    defer fx.deinit();
    try fx.start();

    register(fx.writeFd(), std.mem.zeroes(std.posix.termios));
    defer clear();
    crashRestore();
    try std.testing.expectEqual(fx.filled + restore_seq.len, fx.finish());
}

test "isActive follows register, registerTermios and clear" {
    clear();
    try std.testing.expect(!isActive());
    register(-1, std.mem.zeroes(std.posix.termios));
    try std.testing.expect(isActive());
    clear();
    try std.testing.expect(!isActive());
    registerTermios(-1, std.mem.zeroes(std.posix.termios));
    try std.testing.expect(isActive());
    clear();
    try std.testing.expect(!isActive());
}

test "crashRestore after registerTermios leaves plain CLI output untouched" {
    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    registerTermios(fds[1], std.mem.zeroes(std.posix.termios));
    defer clear();
    crashRestore();

    // The probe never entered the alt screen; a stray restore_seq would print
    // escape garbage into the command's output. The sentinel must come first.
    try std.testing.expectEqual(@as(isize, 1), std.c.write(fds[1], "S", 1));
    var buf: [restore_seq.len]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 1), std.c.read(fds[0], &buf, buf.len));
    try std.testing.expectEqual(@as(u8, 'S'), buf[0]);
}

test "register after registerTermios emits the restore sequence again" {
    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    registerTermios(fds[1], std.mem.zeroes(std.posix.termios));
    register(fds[1], std.mem.zeroes(std.posix.termios));
    defer clear();
    crashRestore();

    // A stale termios-only flag would silently drop the TUI's screen restore.
    var buf: [restore_seq.len]u8 = undefined;
    try std.testing.expectEqual(@as(isize, restore_seq.len), std.c.read(fds[0], &buf, buf.len));
    try std.testing.expectEqualStrings(restore_seq, &buf);
}

test "installCrashSignalsKeepIgnored keeps a signal the parent chose to ignore ignored" {
    var prev: [crash_signals.len]std.posix.Sigaction = undefined;
    for (crash_signals, 0..) |sig, i| std.posix.sigaction(sig, null, &prev[i]);
    defer for (crash_signals, 0..) |sig, i| std.posix.sigaction(sig, &prev[i], null);
    resetCrashSignals();

    const ignore = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.TERM, &ignore, null);
    installCrashSignalsKeepIgnored();

    var term: std.posix.Sigaction = undefined;
    std.posix.sigaction(.TERM, null, &term);
    try std.testing.expectEqual(std.posix.SIG.IGN, term.handler.handler);
    // Only the ignored signal is spared; the rest still get the handler.
    var hup: std.posix.Sigaction = undefined;
    std.posix.sigaction(.HUP, null, &hup);
    try std.testing.expectEqual(&crashSignalHandler, hup.handler.handler);
}

test "installCrashSignals still takes over an ignored signal for the TUI" {
    var prev: [crash_signals.len]std.posix.Sigaction = undefined;
    for (crash_signals, 0..) |sig, i| std.posix.sigaction(sig, null, &prev[i]);
    defer for (crash_signals, 0..) |sig, i| std.posix.sigaction(sig, &prev[i], null);
    resetCrashSignals();

    const ignore = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.TERM, &ignore, null);
    installCrashSignals();

    // The TUI restores its screen on a kill, and its children must not
    // inherit an ignored SIGTERM or the quit path could not stop them.
    var term: std.posix.Sigaction = undefined;
    std.posix.sigaction(.TERM, null, &term);
    try std.testing.expectEqual(&crashSignalHandler, term.handler.handler);
}
