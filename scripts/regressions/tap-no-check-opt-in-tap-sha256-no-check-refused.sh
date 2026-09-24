#!/usr/bin/env bash
# Regression: a tap or local recipe declaring `sha256 :no_check` installs only
# behind `--allow-unpinned`, and then always warns that the artefact is not
# checksum-verified. Pre-fix the opt-out had no representation at all, so the
# flag was ignored and every such recipe was refused.
#
# Also pins the other direction: the opt-in never rescues a quoted "no_check"
# or an absent sha256. The unpinned-.pkg refusal is covered by
# tests/install_download_only_test.zig (`--local` never yields a cask).
#
# Usage: scripts/regressions/tap-no-check-opt-in-tap-sha256-no-check-refused.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt.
# No network access required: every run is --dry-run.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

T="/tmp/mt_nocheck_$$"
rm -rf "$T"
mkdir -p "$T/p" "$T/c"
trap 'rm -rf "$T"' EXIT
export MALT_PREFIX="$T/p" MALT_CACHE="$T/c" MALT_OFFLINE=1

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mk() {
  printf 'class Foo < Formula\n  version "1.0"\n  url "https://example.com/foo-1.0.tar.gz"\n  %s\nend\n' "$1" >"$T/$2.rb"
}
mk 'sha256 :no_check' nocheck
mk 'sha256 arm: :no_check, intel: :no_check' kwarg
mk 'sha256 "no_check"' quoted
mk '' absent

# 1. Without the opt-in the refusal stands and names its reason.
if out=$("$BIN" install --local --dry-run "$T/nocheck.rb" 2>&1); then
  fail "sha256 :no_check accepted without --allow-unpinned"
fi
grep -q 'declares sha256 :no_check' <<<"$out" || fail "refusal reason missing: $out"

# 2. The opt-in admits the flat and per-arch shapes, each with the warning.
for f in nocheck kwarg; do
  out=$("$BIN" install --local --dry-run --allow-unpinned "$T/$f.rb" 2>&1) ||
    fail "$f refused under --allow-unpinned: $out"
  grep -q 'not checksum-verified' <<<"$out" || fail "$f: no unverified warning: $out"
done

# 3. The usual vendor shape, `version :latest`, installs as the `latest` keg.
printf 'class Foo < Formula\n  version :latest\n  url "https://example.com/foo.tar.gz"\n  sha256 :no_check\nend\n' >"$T/nightly.rb"
out=$("$BIN" install --local --dry-run --allow-unpinned "$T/nightly.rb" 2>&1) ||
  fail "version :latest refused under --allow-unpinned: $out"
grep -q 'would install nightly latest from' <<<"$out" ||
  fail "version :latest did not resolve to the latest keg: $out"

# 4. The opt-in never rescues a quoted or absent checksum.
for f in quoted absent; do
  if "$BIN" install --local --dry-run --allow-unpinned "$T/$f.rb" >/dev/null 2>&1; then
    fail "$f checksum accepted under --allow-unpinned"
  fi
done

echo "PASS: sha256 :no_check installs only behind --allow-unpinned"
