#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)

# Must live at the repo root: ghcr.zig's relative sibling imports
# (client.zig, client_pool.zig, mirror.zig) only resolve from inside
# the source tree's module boundary.
HARNESS="$ROOT/.extract-token-field-regression.$$.zig"
trap 'rm -f "$HARNESS"' EXIT

cat >"$HARNESS" <<'ZIG'
const std = @import("std");
const ghcr = @import("src/net/ghcr.zig");

// Root shapes a registry or bottle-domain mirror can answer 200 with.
// Each was a distinct inactive-union-field abort before the fix.
test "extractTokenField rejects a non-object token payload" {
    for ([_][]const u8{ "[]", "\"x\"", "42", "null", "true" }) |body| {
        try std.testing.expectError(
            error.InvalidResponse,
            ghcr.extractTokenField(std.testing.allocator, body),
        );
    }
}
ZIG

if (cd "$ROOT" && zig test --test-filter "rejects a non-object token payload" "$HARNESS") >/dev/null 2>&1; then
  echo "PASS: extractTokenField reports a non-object token payload as an error"
else
  echo "FAIL: extractTokenField aborted on a non-object token payload (unchecked std.json.Value tag)" >&2
  exit 1
fi
