#!/usr/bin/env bash
# Regression: a formula with no `versions.stable` must never reach the Cellar.
#
# The bug: `parseFormula` accepted an absent/null `versions.stable` and
# yielded `version = ""`, and the materialize sinks were deliberately
# tolerant of that empty version. The keg then landed at
# `<prefix>/Cellar/<name>/` with no version component, the linker recorded
# `<prefix>/Cellar/<name>//bin/<exe>`, and every `<name>/<version>` reader
# disagreed with it: `mt which` reported MalformedCellarPath, `cellar.remove`
# refused the path so `mt uninstall` orphaned the directory, and post-install
# failed with InvalidInput.
#
# No CLI surface feeds malt a local formula JSON, so the invariant is pinned
# where it is decided: the parser refuses the empty version, and no Cellar
# sink will splice one into a keg path. Two arms, both offline:
#   1. neither the parser exemption nor the tolerant-sink split can come back;
#   2. the inline unit suite, which asserts both refusals end to end.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

# --- Arm 1: the tolerant paths stay gone ------------------------------------
# Counted, not merely absent: the parser had one exemption and the Cellar had
# a per-sink opt-out, and either one alone re-admits a versionless keg.
refuse_pattern() {
  local src=$1 pattern=$2 why=$3
  if grep -Fq -- "$pattern" "$src"; then
    echo "FAIL: $src still carries '$pattern' — $why" >&2
    exit 1
  fi
}
refuse_pattern src/core/formula.zig "version_str.len != 0" \
  "an empty versions.stable is exempt from the path-component screen"
refuse_pattern src/core/cellar.zig "EmptyVersion" \
  "a Cellar sink can opt out of the version screen"

expect_sites() {
  local src=$1 pattern=$2 want=$3 got
  got=$(grep -Fc -- "$pattern" "$src" || true)
  if [ "$got" -lt "$want" ]; then
    echo "FAIL: $src has $got of $want '$pattern' guard sites" >&2
    exit 1
  fi
}
expect_sites src/core/cellar.zig "confined(name, version)" 3

# --- Arm 2: the refusals hold at runtime ------------------------------------
BIN="$ROOT/zig-out/test-bin/lib_tests"
if ! zig build test-bin >/dev/null 2>&1; then
  echo "FAIL: could not build the unit test binary (zig build test-bin)" >&2
  exit 1
fi
if ! OUT=$("$BIN" 2>&1); then
  echo "FAIL: a versionless formula was admitted by the parser or a Cellar sink" >&2
  printf '%s\n' "$OUT" | grep -iE "failed|leaked|panic" >&2 || true
  exit 1
fi

echo "PASS: a formula without a stable version is refused before the Cellar"
