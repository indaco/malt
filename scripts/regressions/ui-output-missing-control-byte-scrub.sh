#!/usr/bin/env bash
# Regression: text lifted from a tap or a formula must reach the terminal as
# inert characters, never as terminal control sequences.
#
# The bug: every `ui/output` writer interpolated its runtime argument bytes
# verbatim. A formula/cask `desc` (free text, no parse-time predicate) and a
# DSL-authored ohai/opoo/odie/raise message could therefore carry OSC, DCS or
# arbitrary CSI straight into the user's terminal — clipboard writes, scrollback
# rewrites, prompt spoofing — from `mt info` or a post_install run.
#
# The fix scrubs the interpolated bytes at the render choke points, dropping
# ESC, other C0, DEL and lone C1 while leaving multibyte UTF-8 intact.
#
# Driving a hostile `desc` end to end would need a local HTTP fixture server the
# repo does not have, so the guarantee is pinned by colocated inline tests that
# assert against the real writers. This script builds and runs only that unit
# binary: no network, no state outside zig-cache/zig-out, well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

# The unit binary would go green vacuously if the scrub call or its tests were
# dropped, so require both call sites and both assertions to still be present.
for src in src/ui/output.zig src/cli/install/post_install.zig; do
  if ! grep -Fqs -- "scrubInPlace" "$src"; then
    echo "FAIL: $src no longer scrubs interpolated text before writing it" >&2
    exit 1
  fi
done

while IFS= read -r name; do
  if ! grep -Fqs -- "$name" src/ui/output.zig; then
    echo "FAIL: the control-byte test is missing from src/ui/output.zig: $name" >&2
    exit 1
  fi
done <<'NAMES'
info drops OSC 52 from an interpolated message
writeField drops OSC 52 from a tap-sourced value
NAMES

BIN="$ROOT/zig-out/test-bin/lib_tests"
# Always rebuild: a prebuilt binary could predate the scrub. Zig's cache keeps
# the no-op rebuild cheap.
if ! zig build test-bin >/dev/null 2>&1; then
  echo "FAIL: could not build the unit test binary (zig build test-bin)" >&2
  exit 1
fi

OUT=$(MALT_PREFIX=/tmp/malt-test-prefix "$BIN" 2>&1) && STATUS=0 || STATUS=$?
if [[ "$STATUS" -ne 0 ]]; then
  echo "FAIL: interpolated tap/formula text reached the terminal unscrubbed" >&2
  printf '%s\n' "$OUT" | grep -iE "failed|leaked|panic" >&2 || true
  exit 1
fi

echo "PASS: ui/output scrubs terminal control bytes from interpolated text"
