//! Process-wide interrupt flag + SIGINT handler.
//!
//! Long-running CLI ops poll `isInterrupted()` between step boundaries so
//! Ctrl-C cleans up instead of killing mid-write. Pulled out of `main.zig`
//! so 12 sites in `cli/*` and `update/*` stop reaching up across the
//! CLI/core boundary for a single atomic bool.

const std = @import("std");

/// Raised by `sigintHandler`, polled at step boundaries.
var interrupted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Test-only countdown: when > 0, the Nth subsequent `isInterrupted()`
/// poll flips `interrupted` to true. Lets a test target a specific
/// mid-execute interrupt site (resolution-loop, pre-link) that a plain
/// pre-set flag can't reach because the pre-resolution gate fires first.
/// In production this stays at 0, so the fast-path costs one atomic load.
var arm_after: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

/// Tracks whether `installHandler` has wired SIGINT. Lets dispatch
/// distinguish a real production run (preserve any flag the handler set)
/// from a test runner re-entering with stale state from a prior case.
var handler_installed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn isInterrupted() bool {
    if (arm_after.load(.acquire) > 0) {
        var prev = arm_after.load(.acquire);
        while (prev > 0) {
            if (arm_after.cmpxchgWeak(prev, prev - 1, .acq_rel, .acquire)) |fresh| {
                prev = fresh;
                continue;
            }
            if (prev == 1) interrupted.store(true, .release);
            break;
        }
    }
    return interrupted.load(.acquire);
}

/// Test-only override — raising real SIGINT would race the test runner.
pub fn setInterruptedForTest(v: bool) void {
    interrupted.store(v, .release);
}

/// Test-only: flip `interrupted` on the Nth subsequent `isInterrupted()`
/// poll. `n == 0` disarms. Use to reach interrupt sites past the pre-
/// resolution gate (the resolution-loop check or the pre-link check)
/// which a plain pre-set flag would never reach because the earlier
/// gate fires first.
pub fn armInterruptAfterForTest(n: usize) void {
    arm_after.store(n, .release);
}

/// Test-only override so the production-mode preservation branch is
/// reachable from inline tests without actually installing a process-wide
/// signal handler.
pub fn setSignalHandlerInstalledForTest(v: bool) void {
    handler_installed.store(v, .release);
}

pub fn signalHandlerInstalled() bool {
    return handler_installed.load(.acquire);
}

fn sigintHandler(_: std.posix.SIG) callconv(.c) void {
    interrupted.store(true, .release);
}

/// Wire SIGINT to flip the interrupt flag. Idempotent so repeated CLI
/// invocations inside a test process do not double-register and do not
/// clobber a flag the prior handler already set.
///
/// `SA_RESETHAND` restores the default disposition after the first delivery:
/// without it any command that never polls the flag is uninterruptible. The
/// second press is a hard kill by design — mid-step, no unwind.
pub fn installHandler() void {
    if (handler_installed.load(.acquire)) return;
    const act = std.posix.Sigaction{
        .handler = .{ .handler = &sigintHandler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESETHAND,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    handler_installed.store(true, .release);
}

// Forked child: wire the handler, then signal ourselves twice. The first
// SIGINT only flips the flag; with the disposition reset the second one is
// fatal. Without the reset the child survives both and exits 0, which the
// parent treats as failure.
fn raiseSigintTwiceAndDie() noreturn {
    setSignalHandlerInstalledForTest(false);
    installHandler();
    std.posix.raise(.INT) catch {};
    std.posix.raise(.INT) catch {};
    std.process.exit(0);
}

// Darwin won't report SA_RESETHAND back through a sigaction query, so pin its
// observable contract instead: a second Ctrl-C kills, which is the escape
// hatch for every command that never polls the flag.
test "a second SIGINT is fatal even though the first only sets the flag" {
    // A tracer (kcov) intercepts the child's signal-stop instead of letting it
    // die, so death-by-signal is unobservable and the wait below times out.
    if (std.c.getenv("MALT_SKIP_SUBPROCESS_TESTS") != null) return error.SkipZigTest;

    const pid = std.c.fork();
    try std.testing.expect(pid >= 0);
    if (pid == 0) raiseSigintTwiceAndDie();

    var status: c_int = undefined;
    var waited_ms: usize = 0;
    const reaped = while (waited_ms < 5000) : (waited_ms += 50) {
        if (std.c.waitpid(pid, &status, std.c.W.NOHANG) == pid) break true;
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    } else false;
    if (!reaped) {
        std.posix.kill(pid, .KILL) catch {};
        _ = std.c.waitpid(pid, &status, 0);
        return error.SecondSigintNotFatal;
    }

    const st: u32 = @bitCast(status);
    try std.testing.expect(std.c.W.IFSIGNALED(st));
    try std.testing.expectEqual(std.posix.SIG.INT, std.c.W.TERMSIG(st));
}

test "armInterruptAfterForTest fires on the Nth subsequent poll" {
    const prior_interrupted = isInterrupted();
    defer setInterruptedForTest(prior_interrupted);
    setInterruptedForTest(false);
    armInterruptAfterForTest(3);
    defer armInterruptAfterForTest(0);

    try std.testing.expect(!isInterrupted()); // poll 1
    try std.testing.expect(!isInterrupted()); // poll 2
    try std.testing.expect(isInterrupted()); // poll 3 → flips
    try std.testing.expect(isInterrupted()); // already flipped, stays true
}

test "armInterruptAfterForTest(0) disarms without flipping" {
    const prior_interrupted = isInterrupted();
    defer setInterruptedForTest(prior_interrupted);
    setInterruptedForTest(false);
    armInterruptAfterForTest(2);
    armInterruptAfterForTest(0);
    defer armInterruptAfterForTest(0);

    try std.testing.expect(!isInterrupted());
    try std.testing.expect(!isInterrupted());
    try std.testing.expect(!isInterrupted());
}

test "setInterruptedForTest round-trips through isInterrupted" {
    setInterruptedForTest(true);
    defer setInterruptedForTest(false);
    try std.testing.expect(isInterrupted());

    setInterruptedForTest(false);
    try std.testing.expect(!isInterrupted());
}

test "setSignalHandlerInstalledForTest round-trips through signalHandlerInstalled" {
    const prior = signalHandlerInstalled();
    defer setSignalHandlerInstalledForTest(prior);

    setSignalHandlerInstalledForTest(true);
    try std.testing.expect(signalHandlerInstalled());

    setSignalHandlerInstalledForTest(false);
    try std.testing.expect(!signalHandlerInstalled());
}

// Idempotency matters because tests re-enter `main`-shaped code paths in
// the same process. A naive second `sigaction` would still work at the
// kernel level, but the worry is the interrupt flag: if the handler
// already fired between two installs, the second call must not clobber it.
test "installHandler does not clobber a raised interrupt flag" {
    const prior_installed = signalHandlerInstalled();
    const prior_interrupted = isInterrupted();
    defer setSignalHandlerInstalledForTest(prior_installed);
    defer setInterruptedForTest(prior_interrupted);

    setSignalHandlerInstalledForTest(false);
    setInterruptedForTest(false);

    installHandler();
    try std.testing.expect(signalHandlerInstalled());

    // Simulate the handler firing between two install attempts.
    setInterruptedForTest(true);
    installHandler();
    try std.testing.expect(isInterrupted());
}
