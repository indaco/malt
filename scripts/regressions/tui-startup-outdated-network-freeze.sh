#!/usr/bin/env bash
# Lock the `mt tui` launch responsiveness contract: the dashboard's input loop
# multiplexes the controlling tty with the background outdated-count audit, so a
# queued keypress is serviced *before* that audit's child reaches EOF. The bug
# this guards: the launch outdated count ran as a synchronous, network-blocking
# subprocess wait before the only tty read, freezing the first impression for
# the full cold-cache audit duration.
#
# Pinned behaviour:
#   1. `pollTtyChild` waits on both fds and reports the tty ready while the
#      audit child's stdout is still open (no EOF) — i.e. a keypress queued
#      during the audit is serviced live, not after the child exits.
#   2. The tty wins when both fds are ready, so input is never starved by a
#      chatty child.
#   3. A finished fetch maps an empty payload to a known `0`, a parsed document
#      to its row count, and a *failed* fetch to `null` (unknown) — never
#      collapsing a failure into `0`.
#
# The launch loop's wait/select core is pure over its fds, so this drives it
# directly through a standalone `zig test` over real pipes (a held-open pipe is
# the "slow child") rather than a flaky timed PTY race. The check imports the
# real source module, so a regression in the loop's multiplexing fails it.
#
# Usage: scripts/regressions/tui-startup-outdated-network-freeze.sh
# No network required.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v zig >/dev/null 2>&1 || fail 'zig not found on PATH'

WORK=$(mktemp -d -t mt_tui_async.XXXXXX)
# The check file must sit at the repo root so its `src/...` imports stay inside
# the module path. Both temp artifacts are removed on exit.
CHECK="$ROOT/.tui_async_outdated_check.zig"
trap 'rm -rf "$WORK" "$CHECK"' EXIT

cat >"$CHECK" <<'ZIG'
const std = @import("std");
const app = @import("src/tui/app.zig");

fn pipe() ![2]std.c.fd_t {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    return fds;
}

// A held-open pipe stands in for the still-running audit child; the other for
// the controlling tty. The launch loop must report the tty ready *without*
// waiting for the child's EOF — the whole point of the multiplexed wait.
test "a keypress queued during the audit is serviced before the child's EOF" {
    const tty = try pipe();
    defer _ = std.c.close(tty[0]);
    defer _ = std.c.close(tty[1]);
    const child = try pipe();
    defer _ = std.c.close(child[0]);
    defer _ = std.c.close(child[1]); // write end stays open == child still auditing

    _ = std.c.write(tty[1], "q", 1); // a keypress lands while the audit runs

    // Child stdout has no data and no EOF; a frozen loop that waits on the child
    // would block here. The fixed loop reports the tty ready and moves on.
    try std.testing.expectEqual(app.PollEvent.tty, try app.pollTtyChild(tty[0], child[0], 1000));
}

test "the tty wins when both fds are ready, so input is never starved" {
    const tty = try pipe();
    defer _ = std.c.close(tty[0]);
    defer _ = std.c.close(tty[1]);
    const child = try pipe();
    defer _ = std.c.close(child[0]);
    defer _ = std.c.close(child[1]);

    _ = std.c.write(tty[1], "x", 1);
    _ = std.c.write(child[1], "{\"items\":[]}", 12);

    try std.testing.expectEqual(app.PollEvent.tty, try app.pollTtyChild(tty[0], child[0], 1000));
}

test "the audit child is reported ready on its EOF" {
    const tty = try pipe();
    defer _ = std.c.close(tty[0]);
    defer _ = std.c.close(tty[1]);
    const child = try pipe();
    defer _ = std.c.close(child[0]);
    _ = std.c.close(child[1]); // child closed stdout == EOF

    try std.testing.expectEqual(app.PollEvent.child, try app.pollTtyChild(tty[0], child[0], 1000));
}

test "a finished fetch keeps the unknown-vs-zero distinction" {
    // Empty payload (fresh prefix) is a *known* zero, not unknown.
    try std.testing.expectEqual(@as(usize, 0), app.parseOutdatedBytes(std.testing.allocator, "").count);
    // A failed parse is unknown (—), never collapsed to 0.
    try std.testing.expect(app.parseOutdatedBytes(std.testing.allocator, "not json") == .failed);
}
ZIG

if ! zig test "$CHECK" 2>"$WORK/err.txt"; then
  sed 's/^/  /' "$WORK/err.txt" >&2
  fail 'tui launch async-outdated check failed — startup input loop does not multiplex the tty with the background audit'
fi

printf 'PASS: mt tui launch loop multiplexes the tty with the background outdated audit\n'
