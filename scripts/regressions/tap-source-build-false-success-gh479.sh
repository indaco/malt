#!/usr/bin/env bash
# Regression: a source-built formula must be refused, not recorded as a
# false success.
#
# A formula whose `def install` builds from source (`system "make"`, …)
# ships a source archive, not a prebuilt binary. malt extracts the
# archive, finds no binary to promote into bin/, and — pre-fix — linked
# an empty bin/, recorded the keg, and printed `installed`. The fix
# detects the empty bin/ on the extracted result and refuses, naming the
# `brew install` escape hatch and unwinding the half-extracted keg.
#
# This drives the REAL install path: a genuine source archive is fetched,
# extracted, and walked — the detection is on the actual result, not a
# textual guess (a prebuilt formula also carries a `def install`, so a
# parse-time check would wrongly refuse it). The archive's sha256 is
# computed at run time, so an upstream tarball regeneration never stales
# the guard; only an unreachable host does, and that is a SKIP.
#
# Asserts:
#   1. `malt install --local <fixture>` exits non-zero (refusal).
#   2. stdout/stderr never carries the false-success `installed` line.
#   3. no keg is left under $PREFIX/Cellar/<name> (the keg was unwound).
#   4. the refusal explains the source-build cause (mentions `build`).
#
# Usage: scripts/regressions/tap-source-build-false-success-gh479.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt; network to
# the source archive host (override with SRC_ARCHIVE_URL=...).

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

# A tiny, stable source tarball — a pure-JS package with no file named
# after our fixture, so the promote walk finds nothing to lift into bin/.
URL="${SRC_ARCHIVE_URL:-https://github.com/sindresorhus/slugify/archive/refs/tags/v2.0.0.tar.gz}"

PREFIX="/tmp/mt_srcbuild"
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
rm -rf "$PREFIX"
mkdir -p "$PREFIX"

WORK=$(mktemp -d)
FIXTURE="$WORK/srcbuildprobe.rb"
trap 'rm -rf "$PREFIX" "$WORK"' EXIT

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# Fetching is the network gate; a miss is a SKIP, not a failure — the bug
# under test is the post-extract record, not the download.
ARCHIVE="$WORK/archive.tar.gz"
if ! curl -fsSL "$URL" -o "$ARCHIVE"; then
  echo "SKIP: cannot reach source archive host (network/offline)"
  exit 0
fi

SHA=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
[[ -n "$SHA" ]] || fail "could not compute sha256 of the source archive"

# A def-install source formula (the issue's shape): the archive is the
# source tree, the binary is produced by the build, which malt won't run.
cat >"$FIXTURE" <<RB
class Srcbuildprobe < Formula
  url "$URL"
  sha256 "$SHA"
  version "2.0.0"
  def install
    system "make"
    bin.install "#{buildpath}/bin/srcbuildprobe"
  end
end
RB

printf '▸ malt install --local %s\n' "$FIXTURE"
set +e
OUT=$("$BIN" install --local "$FIXTURE" 2>&1)
RC=$?
set -e

if [[ "$RC" -eq 0 ]] || printf '%s' "$OUT" | grep -q 'installed'; then
  printf '%s\n' "$OUT" >&2
  fail "source-built formula was extracted and recorded as a false success"
fi
pass "install refused with a non-zero exit and no 'installed' line"

KEG="$PREFIX/Cellar/srcbuildprobe"
if [[ -d "$KEG" ]] && [[ -n "$(ls -A "$KEG" 2>/dev/null)" ]]; then
  printf '%s\n' "$OUT" >&2
  fail "a keg was left under \$PREFIX/Cellar/srcbuildprobe (refusal did not unwind it)"
fi
pass "no keg materialised — the extracted source tree was unwound"

if ! printf '%s' "$OUT" | grep -qi 'build'; then
  printf '%s\n' "$OUT" >&2
  fail "refusal message did not explain the source-build cause"
fi
pass "refusal message names the source-build cause"

printf '\n✔ source-build refusal regression passed\n'
