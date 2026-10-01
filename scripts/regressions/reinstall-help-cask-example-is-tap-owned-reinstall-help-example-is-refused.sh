#!/usr/bin/env bash
# Regression: `reinstall` refuses every core cask (a forced core-cask install
# deletes the live .app before placing the new copy), yet its help and man
# page advertised `malt reinstall --cask firefox`, a core token that always
# exits 1. Every `reinstall --cask` example must name a tap-owned cask.
#
# The second half pins the refusal itself: if core casks ever become
# reinstallable, this guard is stale and the help should be revisited.
#
# Usage: scripts/regressions/reinstall-help-cask-example-is-tap-owned-reinstall-help-example-is-refused.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt; sqlite3 on PATH.
# No network access required.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}
command -v sqlite3 >/dev/null 2>&1 || {
  echo "this regression needs sqlite3 on PATH" >&2
  exit 2
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Never inherit the caller's live prefix.
unset "${!MALT_@}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

check() { # $1 = source label, stdin = text
  local arg
  while read -r arg; do
    [[ $arg == */*/* ]] || fail "$1: 'malt reinstall --cask $arg' names a core cask, which reinstall refuses"
  done < <(grep -oE 'malt reinstall --cask [^ ]+' | awk '{print $4}')
}

"$BIN" reinstall --help | check "reinstall --help"
check "man/malt.1" <"$ROOT/man/malt.1"

export MALT_PREFIX=$TMP MALT_CACHE=$TMP/cache
mkdir -p "$TMP"/{db,cache,tmp}
"$BIN" --offline list >/dev/null 2>&1 || true
sqlite3 "$TMP/db/malt.db" \
  "INSERT INTO casks(token,name,version,url) VALUES('firefox','Firefox','1.0','https://example.invalid/f.dmg');"
out=$("$BIN" --offline reinstall --cask firefox 2>&1) &&
  fail "core cask reinstall is no longer refused - revisit this guard and the help"
grep -q 'uninstall --cask firefox' <<<"$out" || fail "unexpected refusal text: $out"

echo "ok"
