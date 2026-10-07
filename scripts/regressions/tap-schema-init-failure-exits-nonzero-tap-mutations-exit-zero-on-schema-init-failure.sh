#!/usr/bin/env bash
# Regression: `mt tap <slug>`, `--refresh` and `--pin` must fail loudly when
# the database opens but `initSchema` cannot bring it up to date. A swallowed
# init error returns success from `tap.run`: exit 0, no message, no row.
#
# Two seeds: a schema newer than this malt (SchemaTooNew, exit 4) and a DB
# whose `kegs` is a VIEW, so initSchema's base index DDL fails (exit 1).
#
# Usage: scripts/regressions/tap-schema-init-failure-exits-nonzero-tap-mutations-exit-zero-on-schema-init-failure.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt, sqlite3.
# No network access required (the failure happens before any fetch).

set -uo pipefail

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

PREFIX=$(mktemp -d /tmp/mt_tap_schema_init.XXXXXX) || exit 2
trap 'rm -rf "$PREFIX"' EXIT
mkdir -p "$PREFIX/db" "$PREFIX/cache"
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$PREFIX/cache"
export MALT_OFFLINE=1
export NO_COLOR=1
export MALT_NO_EMOJI=1

DB="$PREFIX/db/malt.db"
SHA=$(printf '0%.0s' {1..40})

TOO_NEW="CREATE TABLE schema_version(version INTEGER PRIMARY KEY); INSERT INTO schema_version VALUES(99);"
BROKEN="CREATE VIEW kegs AS SELECT 1 AS id;"

failed=0
check() {
  local name=$1 want=$2 needle=$3 sql=$4 argv err rc
  for argv in "tap user/repo" "tap --refresh user/repo" "tap --pin user/repo $SHA"; do
    rm -f "$DB"
    sqlite3 "$DB" "$sql"
    read -ra args <<<"$argv"
    err=$("$BIN" "${args[@]}" 2>&1 >/dev/null)
    rc=$?
    # Match the cause, not just any stderr: an argument error also exits 1.
    if [[ $rc == "$want" && $err == *"$needle"* ]]; then
      printf '  \xe2\x9c\x93 %s [%s] exit=%s\n' "$name" "$argv" "$rc"
    else
      printf '  \xe2\x9c\x97 %s [%s] exit=%s want=%s err=%q\n' "$name" "$argv" "$rc" "$want" "$err" >&2
      failed=1
    fi
  done
}

check too-new 4 "schema v99" "$TOO_NEW"
check uninitialisable 1 "Failed to initialize database schema" "$BROKEN"

exit $failed
