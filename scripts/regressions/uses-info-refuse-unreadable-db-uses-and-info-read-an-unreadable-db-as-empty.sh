#!/usr/bin/env bash
# Regression: `uses`, `info` and `deps` must report an install database they
# cannot open, not read it as an empty prefix.
#
# The bug: the shared open helper mapped every open failure to "no database",
# so a garbage, mode-000 or walled-off `malt.db` made `uses` print "No
# installed formula uses X." and `info` print "Not installed", both exit 0.
# `deps` probed the file instead of `db/`, so a mode-000 `db/` read as absent.
#
# Only a missing `db/` directory is a fresh prefix. Under --offline `info`
# already exits 1 for a cache miss, so each refusal must also name the
# install database on stderr. Corrupt-table shapes are pinned by Zig tests.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
BIN="$ROOT/zig-out/bin/malt"

if ! zig build >/dev/null 2>&1; then
  echo "FAIL: could not build malt" >&2
  exit 1
fi

SB=$(mktemp -d)
trap 'chmod -R u+rwx "$SB"; rm -rf "$SB"' EXIT

run() {
  rc=0
  env -u MALT_API_DOMAIN -u CLICOLOR_FORCE NO_COLOR=1 MALT_PREFIX="$SB/p" MALT_CACHE="$SB/c" \
    "$BIN" --offline "$@" >"$SB/out" 2>"$SB/err" || rc=$?
}

# A clean non-zero exit that blames the database; a signal must not pass,
# and nothing may reach stdout, where --json consumers parse the answer.
refuses() {
  local label=$1
  shift
  for mode in "" --json; do
    run $mode "$@"
    if ((rc == 0 || rc >= 128)) || ! grep -q 'install database' "$SB/err"; then
      cat "$SB/out" "$SB/err" >&2
      echo "FAIL [$label] mt $mode $*: exited $rc without naming the install database" >&2
      exit 1
    fi
    if [[ -s "$SB/out" ]]; then
      cat "$SB/out" >&2
      echo "FAIL [$label] mt $mode $*: printed an answer for a database it could not open" >&2
      exit 1
    fi
  done
}

reset() {
  chmod -R u+rwx "$SB"
  rm -rf "$SB/p" "$SB/c"
  mkdir -p "$SB/p/db" "$SB/c"
}

# A fresh prefix (no db/) is the one empty answer left.
reset
rmdir "$SB/p/db"
run uses openssl@3
if ((rc != 0)) || ! grep -q 'No installed formula uses openssl@3' "$SB/out"; then
  cat "$SB/out" "$SB/err" >&2
  echo "FAIL [fresh] mt uses on a prefix with no db/ exited $rc" >&2
  exit 1
fi

reset
printf 'not sqlite%.0s' {1..8} >"$SB/p/db/malt.db"
refuses garbage uses openssl@3
refuses garbage info wget
refuses garbage deps --installed wget

reset
: >"$SB/p/db/malt.db"
chmod 000 "$SB/p/db/malt.db"
refuses mode000-file uses openssl@3
refuses mode000-file info wget

reset
chmod 000 "$SB/p/db"
refuses mode000-dir uses openssl@3
refuses mode000-dir info wget
refuses mode000-dir deps --installed wget

# db/ symlinked somewhere that is gone (an unmounted volume)
reset
rmdir "$SB/p/db"
ln -s "$SB/unmounted/malt-db" "$SB/p/db"
refuses dangling-db uses openssl@3
refuses dangling-db info wget
refuses dangling-db deps --installed wget

# MALT_PREFIX pointing at a file
reset
rm -rf "$SB/p"
: >"$SB/p"
refuses prefix-is-file uses openssl@3
refuses prefix-is-file info wget
refuses prefix-is-file deps --installed wget

echo "OK: uses, info and deps refuse an install database they cannot open"
