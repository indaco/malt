#!/usr/bin/env bash
# Regression: a mixed-case local exact-match search must collapse to ONE
# row for the package, carrying the canonical (lowercase) name, in both
# human and JSON output. The exactness decision case-folds, but the
# writers used to echo the raw query and dedupe the canonical substring
# hit case-sensitively, so `mt search --installed JQ` emitted both
# `JQ` and `jq`.
#
# Hermetic: a seeded keg row in a throwaway prefix, MALT_OFFLINE=1 so the
# local lookup is the only thing under test — no live Homebrew metadata.
#
# Usage: scripts/regressions/local-search-raw-query-duplicate-rows.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt, sqlite3 + jq on PATH.

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
command -v jq >/dev/null 2>&1 || {
  echo "this regression needs jq on PATH" >&2
  exit 2
}

PREFIX="$(mktemp -d)"
mkdir -p "$PREFIX/db"
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
export MALT_OFFLINE=1
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

DB="$PREFIX/db/malt.db"

# Bootstrap schema by letting malt open the DB once, then seed a keg whose
# canonical name is lowercase.
"$BIN" list --quiet >/dev/null 2>&1 || true
[[ -f "$DB" ]] || fail "DB was not initialised by mt list"
sqlite3 "$DB" <<SQL
INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, install_reason)
VALUES ('jq', 'jq', '1.7.1', 0, 'sha_jq', '$PREFIX/Cellar/jq/1.7.1', 'direct');
SQL
mkdir -p "$PREFIX/Cellar/jq/1.7.1"

# Human: a non-canonical-case query must yield exactly ONE formula row,
# carrying the canonical lowercase name and no raw-query echo.
HOUT="$("$BIN" search --installed JQ)"
n=$(printf '%s\n' "$HOUT" | grep -c '(formula)' || true)
[ "$n" -eq 1 ] || fail "human: expected 1 formula row, got $n:
$HOUT"
printf '%s\n' "$HOUT" | grep -q 'jq (formula)' ||
  fail "human: canonical 'jq (formula)' row missing:
$HOUT"
printf '%s\n' "$HOUT" | grep -q 'JQ (formula)' &&
  fail "human: raw-query echo 'JQ (formula)' present:
$HOUT"
pass "human: one canonical 'jq (formula)' row, no raw-query echo"

# JSON: exactly one formula result object, name == "jq".
JOUT="$("$BIN" search --installed --json JQ)"
cnt=$(printf '%s' "$JOUT" | jq '[.results[] | select(.type=="formula")] | length')
[ "$cnt" -eq 1 ] || fail "json: expected 1 formula result, got $cnt: $JOUT"
name=$(printf '%s' "$JOUT" | jq -r '.results[0].name')
[ "$name" = "jq" ] || fail "json: name=$name, expected jq: $JOUT"
pass "json: one result object, name=jq"

printf '\n\xe2\x9c\x94 local-search mixed-case dedup regression passed\n'
