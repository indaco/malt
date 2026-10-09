#!/usr/bin/env bash
# Regression: the global --offline flag must select the installed search
# scope, wherever it sits on the command line. `main` strips the flag into
# `ctx.offline`, so scope must never depend on argv.
#
# Hermetic: throwaway prefix under /tmp with one seeded keg and an empty
# cache. Installed scope never fetches, so no network is needed.
#
# Usage: scripts/regressions/search-offline-installed-scope-search-offline-flag-never-degrades-scope.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt, sqlite3 on PATH.

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

P=$(mktemp -d /tmp/mt_srchoff.XXXXXX)
trap 'rm -rf "$P"' EXIT
export MALT_PREFIX=$P MALT_CACHE=$P/cache
unset MALT_OFFLINE
mkdir -p "$P/db" "$P/cache" "$P/tmp"

"$BIN" search --installed wget </dev/null >/dev/null 2>&1 || true # create schema
sqlite3 "$P/db/malt.db" "INSERT INTO kegs(name,full_name,version,store_sha256,cellar_path)
  VALUES('wget','wget','1.25.0','00','$P/Cellar/wget/1.25.0')"

want=$("$BIN" search --json --installed wget </dev/null)
# An empty baseline would match the buggy output too.
[[ $want == *'"name":"wget"'* ]] || {
  echo "FAIL: seeded keg not visible: $want"
  exit 1
}
fail=0
for argv in "search --json --offline wget" "--offline search --json wget" "search --json wget --offline"; do
  # shellcheck disable=SC2086 # word splitting builds argv on purpose
  got=$(timeout 20 "$BIN" $argv </dev/null) || {
    echo "FAIL: malt $argv exited $?"
    fail=1
    continue
  }
  [[ $got == "$want" ]] || {
    echo "FAIL: malt $argv -> $got (want $want)"
    fail=1
  }
done
exit $fail
