#!/usr/bin/env bash
# Regression: `mt outdated` marks a row whose tap moved *backward*, and the
# marker stays derived — it never reaches the cached `outdated.json`.
#
# The marker is computed at emit time from the two version labels the row
# already carries, so the snapshot codec is untouched and `snapshot_version`
# does not move. That is what keeps an older malt able to read a snapshot
# written by a newer one, and a newer malt able to mark a row served from a
# snapshot written before the marker existed. If the marker were ever
# persisted instead, this script fails on the last two assertions.
#
# Hermetic: a keg is seeded straight into the DB and the snapshot is served
# offline, so no API call and no network are involved.
#
# Usage: scripts/regressions/outdated-downgrade-marker-not-persisted.sh
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

PREFIX=$(mktemp -d -t malt_outdated_downgrade.XXXXXX)
trap 'rm -rf "$PREFIX"' EXIT
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$PREFIX/cache"
export NO_COLOR=1
export MALT_NO_EMOJI=1
unset MALT_OUTDATED_MAX_AGE CI

SNAP="$MALT_CACHE/outdated.json"

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

mkdir -p "$PREFIX/db" "$MALT_CACHE"
"$BIN" list >/dev/null 2>&1 || true

DB="$PREFIX/db/malt.db"
[[ -f "$DB" ]] || fail "expected DB at $DB after schema init"

# A real yanked-release pair: upstream 2.4.14 is behind the installed 2.4.15.
sqlite3 "$DB" "INSERT INTO kegs (name, full_name, version, revision, tap, store_sha256, cellar_path) \
  VALUES ('pip-audit', 'pip-audit', '2.4.15', 0, 'homebrew/core', 'sha', '${PREFIX}/Cellar/pip-audit/2.4.15');"

gen_ms=$((($(date +%s) - 60) * 1000))
printf '{"version":2,"generated_at_ms":%s,"formulas":[{"name":"pip-audit","installed":"2.4.15","latest":"2.4.14"}],"casks":[]}' \
  "$gen_ms" >"$SNAP"

JSON_OUT=$(MALT_OFFLINE=1 "$BIN" outdated --json 2>/dev/null)
grep -q '"downgrade":true' <<<"$JSON_OUT" ||
  fail "--json did not mark the backward row: $JSON_OUT"
pass "--json marks the backward row"

HUMAN_OUT=$(MALT_OFFLINE=1 "$BIN" outdated 2>/dev/null)
grep -q '\[downgrade\]' <<<"$HUMAN_OUT" ||
  fail "the human row did not mark the backward move: $HUMAN_OUT"
pass "the human row marks the backward move"

grep -q '"version":2' "$SNAP" ||
  fail "snapshot_version moved — a derived marker must not need a codec bump"
pass "the snapshot keeps snapshot_version 2"

if grep -q 'downgrade' "$SNAP"; then
  fail "the marker leaked into the cached snapshot — it must stay derived"
fi
pass "the cached snapshot carries no marker field"

printf '\n\xe2\x9c\x94 outdated downgrade-marker regression passed\n'
