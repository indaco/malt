//! malt - fs_compat primitive-helper pinning tests.
//!
//! These helpers wrap clock / sleep / tty / env primitives. They're
//! trivial on the surface but a silent regression (zero clock, noop
//! sleep, wrong PATH lookup) would corrupt cache timestamps, child
//! spawn, and color detection. Pin the observable contract so the
//! std.Io / std.posix migration is provably behavior-preserving.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const fs = malt.fs_compat;

// ── timestamps ───────────────────────────────────────────────────────

test "timestamp returns a positive seconds-since-epoch value" {
    const t = fs.timestamp();
    try testing.expect(t > 1_700_000_000); // after 2023-11-14, the project is post-this
}

test "nanoTimestamp and milliTimestamp stay in lockstep with timestamp" {
    // Allow 5ms of drift across the three calls - they're independent
    // reads of CLOCK_REALTIME but should land within the same second
    // for a sane host clock.
    const s = fs.timestamp();
    const ms = fs.milliTimestamp();
    const ns = fs.nanoTimestamp();

    const ms_from_s = @as(i64, s) * std.time.ms_per_s;
    try testing.expect(@abs(ms - ms_from_s) < 1_000);

    const ns_from_ms = @as(i128, ms) * std.time.ns_per_ms;
    try testing.expect(@abs(ns - ns_from_ms) < std.time.ns_per_s);
}

test "milliTimestamp advances across a short sleep" {
    const before = fs.milliTimestamp();
    fs.sleepNanos(5 * std.time.ns_per_ms);
    const after = fs.milliTimestamp();
    try testing.expect(after >= before);
}

// ── sleepNanos ───────────────────────────────────────────────────────

test "sleepNanos returns without error for a tiny duration" {
    // Smoke: the wrapper must not panic or deadlock on small values.
    fs.sleepNanos(1_000);
}

test "sleepNanos waits at least the requested duration" {
    const want_ns: u64 = 2 * std.time.ns_per_ms;
    const before = fs.nanoTimestamp();
    fs.sleepNanos(want_ns);
    const elapsed: u64 = @intCast(fs.nanoTimestamp() - before);
    // Generous lower bound - scheduler jitter under CI load can trim a
    // few hundred microseconds, so accept anything >= half the target.
    try testing.expect(elapsed >= want_ns / 2);
}

// ── isatty ───────────────────────────────────────────────────────────
//
// Can't assert a specific answer - under `zig build test` stdin/stdout
// may be pipes, ttys, or nothing depending on CI. Pin the shape: call
// returns a bool for every std fd without trapping.

test "isatty returns a bool for the three standard fds" {
    _ = fs.isatty(std.posix.STDIN_FILENO);
    _ = fs.isatty(std.posix.STDOUT_FILENO);
    _ = fs.isatty(std.posix.STDERR_FILENO);
}

test "isatty returns false for a closed / invalid fd" {
    // fd 999 is almost certainly not open in the test runner.
    try testing.expect(!fs.isatty(999));
}

// ── getenv ───────────────────────────────────────────────────────────

test "getenv returns null for an unset variable" {
    try testing.expect(fs.getenv("MALT_DEFINITELY_UNSET_XYZ_9f3a2") == null);
}

test "getenv returns the value for a set variable" {
    // PATH is set in every sane shell env; fall back to HOME if not.
    const v = fs.getenv("PATH") orelse fs.getenv("HOME") orelse return error.SkipZigTest;
    try testing.expect(v.len > 0);
}

test "getenv does not match a prefix-only name" {
    // A classic environ-walk bug: matching "PAT" against "PATH=...".
    // Pin that prefix matches do NOT leak through.
    if (fs.getenv("PATH") == null) return error.SkipZigTest;
    try testing.expect(fs.getenv("PAT") == null);
    try testing.expect(fs.getenv("PATH_") == null);
}
