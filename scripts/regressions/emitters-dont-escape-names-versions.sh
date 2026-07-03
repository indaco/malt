#!/usr/bin/env bash
# Regression: the JSON, Brewfile and install-receipt emitters must escape the
# names, versions and taps they interpolate, so the emit -> parse round-trip
# survives a `"` or `\` byte in any of those fields.
#
# The bug: all three emitters wrote DB/user strings into quoted output with a
# raw `{s}` and no escaping. `emitJson`, `brewfile_emit.emit` and
# `writeInstallReceiptFull` each produced malformed JSON/Brewfile the moment a
# field held a quote or backslash, so `parse(emit(m))` no longer equalled `m`
# (JSON re-parse failed; the Brewfile value truncated at the first quote).
#
# No CLI surface round-trips a quoted identifier offline without standing up a
# tap or seeding the DB with an adversarial name, so the guarantee is pinned by
# the colocated inline tests (`lib_tests`). This script builds and runs only
# that binary: it stays well under 30s and needs no network. Pre-fix, the three
# round-trip tests fail and the binary exits non-zero; the fix flips it green.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

# If any emitter's escaper or its round-trip test is dropped, the unit binary
# would go green vacuously. Fail loudly instead: both the escaper and its test
# must be present in each source file.
declare -a GUARDS=(
  "src/core/bundle/manifest.zig|writeJsonString|the JSON emitter escaper"
  "src/core/bundle/manifest.zig|round-trip survives quotes and backslashes|the JSON round-trip test"
  "src/core/bundle/brewfile_emit.zig|writeRubyString|the Brewfile emitter escaper"
  "src/core/bundle/brewfile.zig|decodeEscapes|the Brewfile escape decoder"
  "src/core/bundle/brewfile.zig|Brewfile round-trip preserves quotes|the Brewfile round-trip test"
  "src/core/cellar.zig|jsonEscapeInto|the install-receipt escaper"
  "src/core/cellar.zig|install receipt with quoted tap and version|the install-receipt round-trip test"
)
for g in "${GUARDS[@]}"; do
  IFS='|' read -r file needle label <<<"$g"
  if ! grep -Fqs -- "$needle" "$file"; then
    echo "FAIL: $label is missing from $file" >&2
    exit 1
  fi
done

BIN="$ROOT/zig-out/test-bin/lib_tests"
# Always rebuild so the binary reflects current source — a prebuilt lib_tests
# could predate the fix. Zig's cache makes a no-op rebuild cheap.
if ! zig build test-bin >/dev/null 2>&1; then
  echo "FAIL: could not build the unit test binary (zig build test-bin)" >&2
  exit 1
fi

# The runner has no per-test filter, so run the inline suite and judge by exit
# code. Pre-fix, the three round-trip tests fail and this binary exits non-zero.
OUT=$("$BIN" 2>&1) && STATUS=0 || STATUS=$?
if [[ "$STATUS" -ne 0 ]]; then
  echo "FAIL: an emitter round-trip did not survive quote/backslash bytes" >&2
  printf '%s\n' "$OUT" | grep -iE "failed|leaked|panic" >&2 || true
  exit 1
fi

echo "PASS: JSON, Brewfile and receipt emitters escape names/versions/taps"
