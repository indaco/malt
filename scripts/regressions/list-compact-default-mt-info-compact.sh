#!/usr/bin/env bash
# Regression: `mt list` on a terminal shows installed packages as compact
# columns under Formulae/Casks headers, `-v` keeps the one-row-per-package
# layout, and piped output is bare names so `mt list | grep -x` still works.
#
# The human path used to have a single bullet-per-row layout that ignored
# `--verbose`, so a long install list filled the screen and formulae were
# indistinguishable from casks.
#
# Usage: scripts/regressions/list-compact-default-mt-info-compact.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt, sqlite3,
# script(1). Offline.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

MALT_BIN=${MALT_BIN:-$ROOT/zig-out/bin/malt}
if [[ ! -x "$MALT_BIN" ]]; then
  printf 'FAIL: malt binary not found at %s — run "zig build" first.\n' "$MALT_BIN" >&2
  exit 1
fi

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

PFX=$(mktemp -d -t mt_list_compact.XXXXXX)
export MALT_PREFIX="$PFX"
trap 'rm -rf "$PFX"' EXIT

mkdir -p "$PFX/db"
# Materialise the schema with the real initializer, then seed two kegs + a cask.
"$MALT_BIN" list </dev/null >/dev/null 2>&1 || true
sqlite3 "$PFX/db/malt.db" \
  "INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path) VALUES
     ('aaa','aaa','1','x','/x'), ('bbb','bbb','1','x','/x');
   INSERT INTO casks (token, name, version, url) VALUES ('ccc','ccc','1','u');"

export MALT_NO_VERSION_NOTIFIER=1

# script(1) hands stdout a pty; stty pins the width the grid packs against.
# Strip the pty's CRs and the `^D` + backspaces it echoes for stdin EOF.
on_tty() {
  script -q /dev/null sh -c "stty cols 80; NO_COLOR=1 '$MALT_BIN' $*" </dev/null |
    tr -d '\r\b' | sed 's/^\^D//'
}

tty_out=$(on_tty list)
grep -qx 'Formulae' <<<"$tty_out" || fail "terminal default has no Formulae header: $tty_out"
grep -qx 'Casks' <<<"$tty_out" || fail "terminal default has no Casks header: $tty_out"
grep -Eqx 'aaa +bbb' <<<"$tty_out" || fail "terminal default does not pack formulae into columns: $tty_out"

v_out=$(on_tty list -v)
grep -q '▸ aaa' <<<"$v_out" || fail "-v lost the one-row-per-package layout: $v_out"
grep -qx 'Formulae' <<<"$v_out" && fail "-v still prints the compact headers: $v_out"

# -q and --versions keep one package per line even on a terminal.
q_out=$(on_tty list -q)
[[ "$q_out" == $'aaa\nbbb\nccc' ]] || fail "-q on a terminal is not bare names: $q_out"
ver_out=$(on_tty list --versions)
grep -q '▸ aaa (1)' <<<"$ver_out" || fail "--versions on a terminal lost the row layout: $ver_out"

pipe_out=$(NO_COLOR=1 "$MALT_BIN" list </dev/null)
[[ "$pipe_out" == $'aaa\nbbb\nccc' ]] || fail "piped output is not bare names: $pipe_out"

printf 'PASS: mt list is compact on a terminal, rows under -v, bare names when piped\n'
