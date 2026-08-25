#!/usr/bin/env bash
# Regression for `depends_on` on tap and local formulas.
#
# Tap formulas name their runtime dependencies in the `.rb`, not in the
# JSON API. The tap install path never read them, so a formula declaring
# `depends_on "flac"` installed as a bare binary with none of the
# libraries it links against — and `mt cleanup` then saw those libraries
# as orphans and reaped them.
#
# Asserts three things on a local `.rb` (no network, no live tap):
#   1. `--dry-run` names every declared dependency it would pull in.
#   2. `:build` and `:optional` deps are NOT named — Homebrew installs
#      neither by default, so neither describes the keg on disk.
#   3. A dependency that cannot be resolved fails the install rather than
#      landing a keg linked against libraries that are absent.
#
# Usage: scripts/regressions/tap-formula-declared-dependencies.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt. Offline.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

# MALT_PREFIX must be ≤ 13 bytes (Mach-O in-place patching budget).
PREFIX="/tmp/mt_tapdep"
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
rm -rf "$PREFIX"
mkdir -p "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

RB="$PREFIX/deptool.rb"
cat >"$RB" <<'FORMULA'
class Deptool < Formula
  desc "Fixture formula declaring a mix of dependency kinds"
  homepage "https://example.invalid/deptool"
  version "1.0.0"

  depends_on "flac"
  depends_on "libvorbis" => :recommended
  depends_on "cmake" => :build
  depends_on "lua" => :optional
  depends_on :xcode

  on_macos do
    on_arm do
      url "https://example.invalid/releases/download/v1.0.0/deptool-darwin-arm64"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
    on_intel do
      url "https://example.invalid/releases/download/v1.0.0/deptool-darwin-amd64"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
  end
end
FORMULA

# ── 1 + 2: the plan names runtime deps only ─────────────────────────────
LOG="$PREFIX/dryrun.log"
"$BIN" install --local "$RB" --dry-run >"$LOG" 2>&1 || {
  cat "$LOG" >&2
  fail "--dry-run on a local .rb reported a failure"
}

for dep in flac libvorbis; do
  grep -q "$dep" "$LOG" || {
    cat "$LOG" >&2
    fail "--dry-run did not name the runtime dependency '$dep'"
  }
done
pass "runtime and recommended dependencies appear in the plan"

for dep in cmake lua; do
  if grep -q "$dep" "$LOG"; then
    cat "$LOG" >&2
    fail "--dry-run named '$dep', which malt must not install by default"
  fi
done
pass "build-only and optional dependencies stay out of the plan"

# ── 3: an unresolvable dependency fails the install ─────────────────────
#
# The url is unreachable by construction, so without dependency handling
# this run dies at the download instead — the assertion is specifically
# that the dependency layer is the one that refuses, and that it refuses
# before anything is recorded.
RB2="$PREFIX/ghosttool.rb"
sed -e 's/Deptool/Ghosttool/' \
  -e 's/deptool/ghosttool/g' \
  -e 's/depends_on "flac"/depends_on "malt-no-such-dependency"/' "$RB" >"$RB2"

LOG2="$PREFIX/ghost.log"
if "$BIN" install --local "$RB2" >"$LOG2" 2>&1; then
  cat "$LOG2" >&2
  fail "a formula depending on a nonexistent package installed anyway"
fi
grep -qi "depend" "$LOG2" || {
  cat "$LOG2" >&2
  fail "install failed without naming the dependency layer"
}
[[ ! -e "$PREFIX/Cellar/ghosttool" ]] || fail "refused install left a keg behind"
pass "an unresolvable dependency fails the install before any keg lands"

printf '\n✔ tap formula dependency regression passed\n'
