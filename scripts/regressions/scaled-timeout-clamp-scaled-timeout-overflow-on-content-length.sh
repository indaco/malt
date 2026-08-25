#!/usr/bin/env bash
# Regression: the whole-transfer deadline is derived from the peer's declared
# Content-Length. That value is attacker-controlled, and the ns multiply used to
# turn it into a deadline overflows u64 past ~1.2e15 - a checked-arithmetic
# panic that aborts the whole `mt` process in a safe build before a single body
# byte is read. The deadline must clamp to the largest transfer the client would
# ever accept instead.
#
# A real overflow panic kills the test runner by signal, so the assertion lives
# in a standalone ReleaseSafe `zig test` harness whose death-by-signal is itself
# the failure signal.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network required; finishes well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

# The harness imports the client via a repo-relative path, so it must sit at the
# repo root for that path to resolve.
HARNESS="$ROOT/.scaled-timeout-clamp-regression.$$.zig"
trap 'rm -f "$HARNESS"' EXIT

cat >"$HARNESS" <<'ZIG'
const std = @import("std");
const client = @import("src/net/client.zig");

test "scaledTimeoutNs clamps a hostile Content-Length" {
    // Old code panicked here; new code returns the 2 GiB-at-64 KiB/s ceiling.
    const ceiling = client.scaledTimeoutNs(std.math.maxInt(u64));
    try std.testing.expectEqual(@as(u64, 32768) * std.time.ns_per_s, ceiling);

    // The exact pre-fix overflow threshold and a plausible hostile header.
    try std.testing.expectEqual(ceiling, client.scaledTimeoutNs(1_208_925_819_568_128));
    try std.testing.expectEqual(ceiling, client.scaledTimeoutNs(2_000_000_000_000_000));

    // The honest range must still scale, not flatten to the ceiling.
    try std.testing.expect(client.scaledTimeoutNs(500 * 1024 * 1024) < ceiling);
}
ZIG

if (cd "$ROOT" && zig test -OReleaseSafe "$HARNESS") >/dev/null 2>&1; then
  echo "PASS: scaledTimeoutNs clamps a hostile Content-Length"
else
  echo "FAIL: scaledTimeoutNs overflowed on a hostile Content-Length" >&2
  exit 1
fi
