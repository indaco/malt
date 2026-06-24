#!/usr/bin/env bash
# Lock the `mt tui` responsiveness contract: the dashboard's input loop
# multiplexes the controlling tty with every background tab-fetch's stdout, so a
# queued keypress is serviced *before* a fetch child reaches EOF. The bug this
# guards: a slow tab's `--json` audit (outdated at launch, doctor/services on
# entry) ran as a synchronous, network-blocking subprocess wait before the only
# tty read, freezing the dashboard for the full cold-cache audit duration.
#
# Pinned behaviour of `pollMux` (the multiplex core):
#   1. It reports the tty ready while a fetch child's stdout is still open (no
#      EOF) — a keypress queued during an audit is serviced live, never after the
#      child exits.
#   2. The tty wins when both it and a fetch are ready, so input is never starved
#      by a chatty child.
#   3. A fetch is reported ready *by index* on its EOF, so the loop drains the
#      right one among several concurrent audits.
#
# The wait/select core is pure over its fds, so this drives it directly through a
# standalone `zig test` over real pipes (a held-open pipe is the "slow child")
# rather than a flaky timed PTY race. The check imports the real source module,
# so a regression in the loop's multiplexing fails it.
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

// A held-open pipe stands in for a still-running audit child; another for the
// controlling tty. The loop must report the tty ready *without* waiting for the
// child's EOF — the whole point of the multiplexed wait.
test "a keypress queued during a fetch is serviced before the child's EOF" {
    const tty = try pipe();
    defer _ = std.c.close(tty[0]);
    defer _ = std.c.close(tty[1]);
    const child = try pipe();
    defer _ = std.c.close(child[0]);
    defer _ = std.c.close(child[1]); // write end stays open == child still auditing

    _ = std.c.write(tty[1], "q", 1); // a keypress lands while the audit runs

    // Child stdout has no data and no EOF; a frozen loop that waits on the child
    // would block here. The fixed loop reports the tty ready and moves on.
    try std.testing.expectEqual(app.MuxEvent.tty, try app.pollMux(tty[0], &.{child[0]}, 1000));
}

test "the tty wins when both it and a fetch are ready, so input is never starved" {
    const tty = try pipe();
    defer _ = std.c.close(tty[0]);
    defer _ = std.c.close(tty[1]);
    const child = try pipe();
    defer _ = std.c.close(child[0]);
    defer _ = std.c.close(child[1]);

    _ = std.c.write(tty[1], "x", 1);
    _ = std.c.write(child[1], "{\"outdated\":[]}", 15);
    try std.testing.expectEqual(app.MuxEvent.tty, try app.pollMux(tty[0], &.{child[0]}, 1000));
}

test "a fetch is reported ready by index on its EOF, among several" {
    const tty = try pipe();
    defer _ = std.c.close(tty[0]);
    defer _ = std.c.close(tty[1]);
    const a = try pipe(); // open: no EOF
    defer _ = std.c.close(a[0]);
    defer _ = std.c.close(a[1]);
    const b = try pipe();
    defer _ = std.c.close(b[0]);
    _ = std.c.close(b[1]); // EOF on the second fetch
    switch (try app.pollMux(tty[0], &.{ a[0], b[0] }, 1000)) {
        .fetch => |i| try std.testing.expectEqual(@as(usize, 1), i),
        else => return error.UnexpectedEvent,
    }
}
ZIG

if ! zig test "$CHECK" 2>"$WORK/err.txt"; then
  sed 's/^/  /' "$WORK/err.txt" >&2
  fail 'tui async-fetch multiplex check failed — the input loop does not multiplex the tty with the background tab audits'
fi

printf 'PASS: mt tui input loop multiplexes the tty with the background tab audits\n'
