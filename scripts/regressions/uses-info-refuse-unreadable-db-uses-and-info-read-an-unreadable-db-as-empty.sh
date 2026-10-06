#!/usr/bin/env bash
# Regression: `uses`, `info`, `deps`, `list` and `search` must report an
# install database they cannot open, not read it as an empty prefix.
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

# Resolved: SQLite measures the real path, and the temp root is a symlink.
SB=$(cd "$(mktemp -d)" && pwd -P)
trap 'chmod -R u+rwx "$SB"; rm -rf "$SB"' EXIT

run() {
  rc=0
  env -u MALT_API_DOMAIN -u CLICOLOR_FORCE NO_COLOR=1 MALT_PREFIX="$P" MALT_CACHE="$SB/c" \
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
  P="$SB/p"
}

refuses_all() {
  refuses "$1" uses openssl@3
  refuses "$1" info wget
  refuses "$1" deps --installed wget
  refuses "$1" list
  refuses "$1" search --installed wget
}

# `outdated` words its refusal differently; it only has to not pass.
outdated_fails() {
  run outdated
  if ((rc == 0 || rc >= 128)); then
    cat "$SB/out" "$SB/err" >&2
    echo "FAIL [$1] mt outdated exited $rc on a database it could not open" >&2
    exit 1
  fi
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
refuses_all garbage
outdated_fails garbage

reset
: >"$SB/p/db/malt.db"
chmod 000 "$SB/p/db/malt.db"
refuses_all mode000-file

reset
chmod 000 "$SB/p/db"
refuses_all mode000-dir

# db/ symlinked somewhere that is gone (an unmounted volume)
reset
rmdir "$SB/p/db"
ln -s "$SB/unmounted/malt-db" "$SB/p/db"
refuses_all dangling-db

# MALT_PREFIX itself symlinked to an unmounted volume
reset
rm -rf "$SB/p"
ln -s "$SB/unmounted/malt" "$SB/p"
refuses_all dangling-prefix

# MALT_PREFIX pointing at a file
reset
rm -rf "$SB/p"
: >"$SB/p"
refuses_all prefix-is-file

# A prefix at the 493-byte cap still has to reach its database.
reset
P="$SB/l"
while ((${#P} < 390)); do P="$P/$(printf 'a%.0s' {1..90})"; done
P="$P/$(printf "%$((493 - ${#P} - 1))s" | tr ' ' b)"
mkdir -p "$P/db"
printf 'not sqlite%.0s' {1..8} >"$P/db/malt.db"
refuses_all long-prefix
outdated_fails long-prefix

echo "OK: uses, info, deps, list and search refuse an install database they cannot open"
