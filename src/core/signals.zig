//! Process-wide interrupt flag + SIGINT handler.
//!
//! Long-running CLI ops poll `isInterrupted()` between step boundaries so
//! Ctrl-C cleans up instead of killing mid-write. Pulled out of `main.zig`
//! so 12 sites in `cli/*` and `update/*` stop reaching up across the
//! CLI/core boundary for a single atomic bool.

const std = @import("std");

/// Raised by `sigintHandler`, polled at step boundaries.
var interrupted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Tracks whether `installHandler` has wired SIGINT. Lets dispatch
/// distinguish a real production run (preserve any flag the handler set)
/// from a test runner re-entering with stale state from a prior case.
var handler_installed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn isInterrupted() bool {
    return interrupted.load(.acquire);
}

/// Test-only override — raising real SIGINT would race the test runner.
pub fn setInterruptedForTest(v: bool) void {
    interrupted.store(v, .release);
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
pub fn installHandler() void {
    if (handler_installed.load(.acquire)) return;
    const act = std.posix.Sigaction{
        .handler = .{ .handler = &sigintHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    handler_installed.store(true, .release);
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
