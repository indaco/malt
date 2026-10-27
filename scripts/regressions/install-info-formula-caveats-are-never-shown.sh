#!/usr/bin/env bash
# Regression: `mt info` and `mt install` print the formula `caveats` text with
# the malt prefix expanded. Pre-fix the parser dropped the field, so a manual
# setup step the formula asks for was never shown.
#
# Usage: scripts/regressions/install-info-formula-caveats-are-never-shown.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt.
# Network: one API fetch and one small bottle.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Run malt, keep its output, and name the failing command instead of dying
# silently under `set -e`.
out=""
run() {
  local rc=0
  out=$("$BIN" "$@" 2>&1) || rc=$?
  [[ $rc -eq 0 ]] || fail "malt $* exited $rc: $out"
}

PREFIX=$(mktemp -d /tmp/mt_caveats.XXXXXX)
trap 'rm -rf "$PREFIX"' EXIT
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$PREFIX/cache"
export NO_COLOR=1
export MALT_NO_EMOJI=1
if [[ -z "${MALT_GITHUB_TOKEN:-}" ]]; then
  MALT_GITHUB_TOKEN=$(gh auth token 2>/dev/null || true)
  export MALT_GITHUB_TOKEN
fi

# Tiny, no dependencies, caveats name $HOMEBREW_PREFIX.
pkg=zsh-syntax-highlighting
want="$PREFIX/share/zsh-syntax-highlighting"

run info "$pkg"
grep -qF "$want" <<<"$out" || fail "info: caveats missing or prefix not expanded"
# shellcheck disable=SC2016 # the literal placeholder is the needle
grep -qF '$HOMEBREW_PREFIX' <<<"$out" && fail "info: placeholder printed literally"

run install "$pkg"
grep -qF "$want" <<<"$out" || fail "install: caveats not printed"

# Installed package: the DB keeps no formula text, so info reads the API.
run info "$pkg"
grep -qF "$want" <<<"$out" || fail "installed info: caveats not printed"

# Control: a formula without caveats prints no caveats header.
run info tree
grep -qi 'caveats' <<<"$out" && fail "caveats header printed for a formula with none"

echo "ok"
