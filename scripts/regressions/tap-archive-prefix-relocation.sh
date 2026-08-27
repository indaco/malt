#!/usr/bin/env bash
# Regression for relocating a tap formula shipped as an archive.
#
# A tarball's binary is linked against whatever prefix its author built on
# exactly like a bare release asset is — the container format changes
# nothing about the problem. malt relocated the bare-asset case but left
# extracted archives alone and stamped them "never relocated", so an
# archived third-party build installed and then failed to run, and the
# `n/a` stamp exempted the keg from every future relocation fix.
#
# Asserts on a real Homebrew-linked binary packed as a `.tar.gz`:
#   1. embedded build-prefix references are rewritten to the malt prefix.
#   2. the keg is stamped with a relocation logic version, not `n/a`.
#   3. an archive whose binary references no build prefix is left
#      byte-identical — rewriting nothing is what keeps a signature valid.
#
# Usage: scripts/regressions/tap-archive-prefix-relocation.sh
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

# MALT_PREFIX must be ≤ 13 bytes (Mach-O in-place patching budget).
PREFIX=$(mktemp -d /tmp/mt.XXX)
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
mkdir -p "$PREFIX/cache/Tap"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  ✓ %s\n' "$*"; }
skip() { printf '  - %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# Pack `$1` into a keg-shaped tarball as bin/`$2`, seed it at the SHA-keyed
# cache path the warm-cache branch reads, and emit a matching local `.rb`.
# Echoes the formula path.
stage_archive() {
  local subject=$1 name=$2
  local work="$PREFIX/work_$name"
  rm -rf "$work"
  mkdir -p "$work/bin"
  cp "$subject" "$work/bin/$name"

  local tarball="$PREFIX/$name.tar.gz"
  tar czf "$tarball" -C "$work" bin
  local sha
  sha=$(shasum -a 256 "$tarball" | cut -d' ' -f1)
  cp "$tarball" "$PREFIX/cache/Tap/$sha.tar.gz"

  local rb="$PREFIX/$name.rb"
  local class
  class=$(printf '%s' "$name" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')
  cat >"$rb" <<FORMULA
class $class < Formula
  desc "Fixture wrapping a real binary as a tap archive"
  homepage "https://example.invalid/$name"
  version "1.0.0"

  on_macos do
    on_arm do
      url "https://example.invalid/releases/download/v1.0.0/$name-darwin-arm64.tar.gz"
      sha256 "$sha"
    end
    on_intel do
      url "https://example.invalid/releases/download/v1.0.0/$name-darwin-amd64.tar.gz"
      sha256 "$sha"
    end
  end
end
FORMULA
  printf '%s\n' "$rb"
}

# ── 1 + 2: a Homebrew-linked binary inside an archive is relocated ──────
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

RB=$(stage_archive "$SUBJECT" "tarreloc")
LOG="$PREFIX/install.log"
"$BIN" install --local "$RB" >"$LOG" 2>&1 || {
  cat "$LOG" >&2
  fail "installing a Homebrew-linked tap archive reported a failure"
}

DEST="$PREFIX/Cellar/tarreloc/1.0.0/bin/tarreloc"
[[ -f "$DEST" ]] || {
  cat "$LOG" >&2
  fail "expected the extracted binary at $DEST"
}

if otool -L "$DEST" 2>/dev/null | grep -q "^	/opt/homebrew/"; then
  otool -L "$DEST" >&2
  fail "extracted binary still links the build prefix"
fi
otool -L "$DEST" 2>/dev/null | grep -q "	$PREFIX/" || {
  otool -L "$DEST" >&2
  fail "extracted binary does not link anything under the malt prefix"
}
pass "build-prefix references inside an archive are rewritten"

STAMP="$PREFIX/Cellar/tarreloc/1.0.0/.malt-reloc-version"
[[ -f "$STAMP" ]] || fail "no relocation stamp written at $STAMP"
if grep -q "n/a" "$STAMP"; then
  fail "extracted keg stamped 'never relocated' after relocation ran"
fi
pass "extracted keg carries a relocation logic version, not 'n/a'"

# ── 3: nothing to patch means nothing is touched ────────────────────────
rm -rf "${PREFIX:?}/Cellar" "${PREFIX:?}/db" "${PREFIX:?}/bin"
RB2=$(stage_archive /usr/bin/true "tarstatic")
LOG2="$PREFIX/install_static.log"
"$BIN" install --local "$RB2" >"$LOG2" 2>&1 || {
  cat "$LOG2" >&2
  fail "installing a system-only tap archive reported a failure"
}
DEST2="$PREFIX/Cellar/tarstatic/1.0.0/bin/tarstatic"
cmp -s /usr/bin/true "$DEST2" || fail "a binary with nothing to patch was modified"
pass "an archive with no build-prefix reference is left byte-identical"

printf '\n✔ tap archive relocation regression passed\n'
