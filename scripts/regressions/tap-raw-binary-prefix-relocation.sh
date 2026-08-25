#!/usr/bin/env bash
# Regression for relocating a tap formula's bare release binary.
#
# A GoReleaser-style asset is linked against whatever prefix its author
# built on — usually `/opt/homebrew`, which malt does not own. malt used
# to stage such an asset verbatim and stamp the keg "never relocated", so
# the installed binary resolved its libraries from a directory that may
# not exist: it installed, then failed to run.
#
# The install now patches those load commands to the malt prefix and
# re-signs whatever it touched. Asserts both halves on a synthetic keg:
#   1. an embedded `/opt/homebrew` dylib reference is rewritten, and the
#      keg is stamped with a relocation logic version (not "n/a", which
#      would exempt it from every future relocation fix).
#   2. a binary that references no build prefix is left byte-identical —
#      rewriting nothing is what keeps its signature valid.
#
# Usage: scripts/regressions/tap-raw-binary-prefix-relocation.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt, macOS.
# Offline.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

[[ "$(uname -s)" == "Darwin" ]] || {
  printf '  - not macOS; Mach-O relocation does not apply\n'
  exit 0
}

# MALT_PREFIX must be ≤ 13 bytes (Mach-O in-place patching budget) — the
# whole point of this guard is that a longer prefix cannot be patched in.
PREFIX="/tmp/mt_reloc"
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
rm -rf "$PREFIX"
mkdir -p "$PREFIX/cache/Tap"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  ✓ %s\n' "$*"; }
skip() { printf '  - %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# A real binary that links Homebrew libraries. Any keg-resident dylib
# consumer works; the loop takes the first candidate that is present and
# actually references the build prefix.
SUBJECT=""
for cand in /opt/homebrew/bin/*; do
  [[ -f "$cand" && -x "$cand" ]] || continue
  if otool -L "$cand" 2>/dev/null | grep -q "^	/opt/homebrew/"; then
    SUBJECT="$cand"
    break
  fi
done
[[ -n "$SUBJECT" ]] || {
  skip "no Homebrew-linked binary available to relocate"
  exit 0
}

# Stage it exactly as the raw-binary install path does: SHA-keyed cache
# entry, consumed by the warm-cache branch with no re-verification.
SHA=$(shasum -a 256 "$SUBJECT" | cut -d' ' -f1)
RB="$PREFIX/reloctool.rb"
cat >"$RB" <<FORMULA
class Reloctool < Formula
  desc "Fixture wrapping a Homebrew-linked binary as a bare release asset"
  homepage "https://example.invalid/reloctool"
  version "1.0.0"

  on_macos do
    on_arm do
      url "https://example.invalid/releases/download/v1.0.0/reloctool-darwin-arm64"
      sha256 "$SHA"
    end
    on_intel do
      url "https://example.invalid/releases/download/v1.0.0/reloctool-darwin-amd64"
      sha256 "$SHA"
    end
  end
end
FORMULA

cp "$SUBJECT" "$PREFIX/cache/Tap/$SHA.bin"

LOG="$PREFIX/install.log"
"$BIN" install --local "$RB" >"$LOG" 2>&1 || {
  cat "$LOG" >&2
  fail "installing a Homebrew-linked bare binary reported a failure"
}

DEST="$PREFIX/Cellar/reloctool/1.0.0/bin/reloctool"
[[ -f "$DEST" ]] || {
  cat "$LOG" >&2
  fail "expected the asset at $DEST"
}

if otool -L "$DEST" 2>/dev/null | grep -q "^	/opt/homebrew/"; then
  otool -L "$DEST" >&2
  fail "installed binary still links the build prefix"
fi
otool -L "$DEST" 2>/dev/null | grep -q "	$PREFIX/" || {
  otool -L "$DEST" >&2
  fail "installed binary does not link anything under the malt prefix"
}
pass "build-prefix dylib references rewritten to the malt prefix"

STAMP="$PREFIX/Cellar/reloctool/1.0.0/.malt-reloc-version"
[[ -f "$STAMP" ]] || fail "no relocation stamp written at $STAMP"
if grep -q "n/a" "$STAMP"; then
  fail "keg stamped 'never relocated' after relocation ran"
fi
pass "keg carries a relocation logic version, not 'n/a'"

# ── Second half: nothing to patch means nothing is touched ─────────────
#
# /usr/bin/true links only system libraries, so the walk must rewrite
# nothing and hand back the exact bytes — that is what leaves an adhoc
# signature intact.
rm -rf "${PREFIX:?}/Cellar" "${PREFIX:?}/db" "${PREFIX:?}/bin"
SHA2=$(shasum -a 256 /usr/bin/true | cut -d' ' -f1)
RB2="$PREFIX/statictool.rb"
sed -e 's/Reloctool/Statictool/' -e 's/reloctool/statictool/g' \
  -e "s/$SHA/$SHA2/" "$RB" >"$RB2"
cp /usr/bin/true "$PREFIX/cache/Tap/$SHA2.bin"

LOG2="$PREFIX/install_static.log"
"$BIN" install --local "$RB2" >"$LOG2" 2>&1 || {
  cat "$LOG2" >&2
  fail "installing a system-only binary reported a failure"
}
DEST2="$PREFIX/Cellar/statictool/1.0.0/bin/statictool"
cmp -s /usr/bin/true "$DEST2" || fail "a binary with nothing to patch was modified"
pass "a binary with no build-prefix reference is left byte-identical"

printf '\n✔ tap raw-binary relocation regression passed\n'
