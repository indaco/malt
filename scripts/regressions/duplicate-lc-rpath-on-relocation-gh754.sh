#!/usr/bin/env bash
# Regression: a bottle carrying two rpaths that name different Homebrew
# prefixes (e.g. `@@HOMEBREW_PREFIX@@/lib` and `/usr/local/lib`) had both
# rewritten to the same MALT_PREFIX during relocation. The Mach-O patcher
# had no LC_RPATH dedup, so the installed binary shipped two identical
# LC_RPATHs and dyld aborted every launch with SIGABRT.
#
# The fix keeps the first occurrence of each relocated rpath value and
# queues any later collider for `install_name_tool -delete_rpath`, riding
# the existing fallback spawn. Both guards live in colocated `test {}`
# blocks; this script asserts the fix is present statically, then runs the
# integration test binary and judges its guard's line.
#
# Exits 0 when the bug is absent, non-zero (with a message naming the
# failing assertion) when present. The default path needs no network and
# finishes well under 30s once the test binaries are built.
#
# Opt-in live check: set MALT_LIVE_RPATH_CHECK=1 to additionally install the
# reported formula (fastfetch — two colliding rpaths) into a throwaway prefix
# and assert the collapsed rpath survives exactly once and the binary really
# runs. Needs network + a built `mt`, so it is off by default.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

PATCHER="$ROOT/src/macho/patcher.zig"

# 1. Static guard: the relocation walk must dedup LC_RPATH and the fallback
#    must be able to emit -delete_rpath. Absence of either is the bug.
if ! grep -q 'seen_rpaths' "$PATCHER"; then
  echo "FAIL: patcher no longer deduplicates relocated LC_RPATH slots" >&2
  exit 1
fi
if ! grep -q -- '-delete_rpath' "$PATCHER"; then
  echo "FAIL: fallback cannot strip a collapsed LC_RPATH (-delete_rpath missing)" >&2
  exit 1
fi

# 2. Behavioural guards live in colocated `test {}` blocks; if either is
#    ever deleted the run below would silently pass. Fail loudly instead.
UNIT_TEST="patchPathsCollecting dedups an LC_RPATH that relocation collapses onto a kept one"
INTEG_TEST="patchPathsCollecting collapses two rpaths onto one target with a single kept slot"
if ! grep -Rqs -- "$UNIT_TEST" "$PATCHER"; then
  echo "FAIL: inline rpath-dedup guard test missing from patcher.zig" >&2
  exit 1
fi
if ! grep -Rqs -- "$INTEG_TEST" "$ROOT/tests/patcher_test.zig"; then
  echo "FAIL: integration rpath-dedup guard test missing from patcher_test.zig" >&2
  exit 1
fi

# Rebuild the test binaries so the run reflects the working tree.
if ! (cd "$ROOT" && zig build test-bin >/dev/null 2>&1); then
  echo "FAIL: could not build the test binaries (zig build test-bin)" >&2
  exit 1
fi

# The runner has no per-test filter, so run the suite and judge only the
# integration guard's line: a pass ends in "OK".
out=$("$ROOT/zig-out/test-bin/patcher_test" 2>&1 || true)
line=$(printf '%s\n' "$out" | grep -F -- "$INTEG_TEST" || true)
if [[ -z "$line" ]]; then
  echo "FAIL: rpath-dedup guard test did not run in patcher_test" >&2
  exit 1
fi
if [[ "$line" != *OK ]]; then
  echo "FAIL: $INTEG_TEST: $line" >&2
  exit 1
fi

# Opt-in: prove it end-to-end against the real formula from the report.
if [[ "${MALT_LIVE_RPATH_CHECK:-0}" == "1" ]]; then
  MT="$ROOT/zig-out/bin/mt"
  if [[ ! -x "$MT" ]]; then
    (cd "$ROOT" && zig build >/dev/null 2>&1) || {
      echo "FAIL: could not build mt for the live check" >&2
      exit 1
    }
  fi

  # Short throwaway prefix keeps relocated rpaths from outgrowing their slots.
  live="/tmp/mt-rpath-live-$$"
  trap 'rm -rf "$live"' EXIT
  rm -rf "$live"
  mkdir -p "$live"

  # gh token dodges the anonymous GitHub API cap; harmless if gh is absent.
  MALT_GITHUB_TOKEN="$(gh auth token 2>/dev/null || true)" \
  MALT_PREFIX="$live" "$MT" install fastfetch >/dev/null 2>&1 ||
    {
      echo "FAIL: live install of fastfetch failed" >&2
      exit 1
    }

  bin=$(echo "$live"/Cellar/fastfetch/*/bin/fastfetch)
  n=$(otool -l "$bin" | grep -c "path $live/lib ")
  [[ "$n" -eq 1 ]] || {
    echo "FAIL: $n LC_RPATH '$live/lib' in installed fastfetch (want 1)" >&2
    exit 1
  }

  # dyld aborts before main on a duplicate, so a real render is the proof.
  if ! "$bin" --logo none >/dev/null 2>"$live/err"; then
    echo "FAIL: fastfetch did not run after relocation" >&2
    cat "$live/err" >&2
    exit 1
  fi
  grep -q 'duplicate LC_RPATH' "$live/err" &&
    {
      echo "FAIL: dyld reports duplicate LC_RPATH at launch" >&2
      exit 1
    }

  echo "OK: live fastfetch install carries one LC_RPATH and runs"
fi

echo "OK: relocation dedups colliding LC_RPATHs; no duplicate ships"
