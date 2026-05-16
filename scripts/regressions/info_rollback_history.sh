#!/usr/bin/env bash
# Regression: `mt info <pkg>` surfaces the retained rollback history that
# `mt rollback <pkg> --list` already exposes — one mental model across
# both verbs. Without this guard the two views could drift, leaving
# users guessing which one is authoritative.
#
# The seeded state mirrors the rollback_list_and_to regression: a
# currently-installed wget@1.22 keg with two prior on-disk store
# entries (1.20, 1.21), and a flux-markdown cask at 1.32.427 with two
# prior cask_versions rows (1.30.0, 1.31.0).
#
# Sandbox-only: no network, no installs, no bottles. The store entries
# are bare directories with placeholder receipts; the rollback writer
# never reaches for the bottle contents in `--list` / `info`.
#
# Usage: scripts/regressions/info_rollback_history.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt,
# `sqlite3` on PATH.

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

PREFIX="/tmp/mt_info_hist_reg"
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
rm -rf "$PREFIX"
mkdir -p "$PREFIX/db"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

DB="$PREFIX/db/malt.db"

# Bootstrap schema by letting malt open the DB once.
"$BIN" list --quiet >/dev/null 2>&1 || true
[[ -f "$DB" ]] || fail "DB was not initialised by mt list"

# --- formula side: keg row + two prior store versions ---------------------
sqlite3 "$DB" <<SQL
INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, install_reason)
VALUES ('wget', 'wget', '1.22', 0, 'sha_cur', '$PREFIX/Cellar/wget/1.22', 'direct');
SQL

mkdir -p "$PREFIX/Cellar/wget/1.22"
mkdir -p "$PREFIX/store/sha_a/wget/1.20"
touch "$PREFIX/store/sha_a/wget/1.20/INSTALL_RECEIPT.json"
sleep 1.1
mkdir -p "$PREFIX/store/sha_b/wget/1.21"
touch "$PREFIX/store/sha_b/wget/1.21/INSTALL_RECEIPT.json"
sleep 1.1
mkdir -p "$PREFIX/store/sha_cur/wget/1.22"
touch "$PREFIX/store/sha_cur/wget/1.22/INSTALL_RECEIPT.json"

# 1. Formula human: section appears with both prior versions.
INFO_OUT="$PREFIX/info.out"
"$BIN" info wget >"$INFO_OUT" 2>&1 ||
  fail "mt info wget exited non-zero (see $INFO_OUT)"

grep -q 'Available rollback versions for wget' "$INFO_OUT" ||
  fail "mt info wget did not emit the rollback section (see $INFO_OUT)"
grep -q '1.20' "$INFO_OUT" || fail "mt info wget missing 1.20 (see $INFO_OUT)"
grep -q '1.21' "$INFO_OUT" || fail "mt info wget missing 1.21 (see $INFO_OUT)"
# Section must skip the current version.
SECTION_LINE=$(grep -n 'Available rollback versions' "$INFO_OUT" | head -1 | cut -d: -f1)
tail -n +"$SECTION_LINE" "$INFO_OUT" | grep -q '1.22' &&
  fail "mt info wget should not list the current version in its own history"
pass "mt info <formula> appends the rollback section (skipping the current version)"

# 2. Formula --json: available_rollback_versions populated with the same shape.
JSON_OUT="$PREFIX/info.json"
"$BIN" --json info wget >"$JSON_OUT" 2>&1 ||
  fail "mt --json info wget exited non-zero (see $JSON_OUT)"

JSON=$(cat "$JSON_OUT")
case "$JSON" in
*'"available_rollback_versions":'*) ;;
*) fail "mt --json info wget missing available_rollback_versions key (see $JSON_OUT)" ;;
esac
case "$JSON" in
*'"version":"1.21"'*'"version":"1.20"'*) ;;
*) fail "mt --json info wget: expected 1.21 then 1.20 in document order (see $JSON_OUT)" ;;
esac
case "$JSON" in
*'"sha256":"sha_a"'*) ;;
*) fail "mt --json info wget missing sha_a (see $JSON_OUT)" ;;
esac
echo "$JSON" | grep -Eq '"mtime":[0-9]+' ||
  fail "mt --json info wget: mtime is not an integer (see $JSON_OUT)"
pass "mt info <formula> --json carries the rollback entries[] shape"

# --- cask side: installed row + two prior cask_versions ------------------
sqlite3 "$DB" <<SQL
INSERT INTO casks (token, name, version, url, sha256)
VALUES ('flux-markdown', 'flux-markdown', '1.32.427',
        'https://example.invalid/flux.dmg', 'aa');
INSERT INTO cask_versions (token, version, url, sha256, artifact_type, installed_at)
VALUES ('flux-markdown','1.30.0','https://example.invalid/old.dmg','dd','dmg','2026-01-01T00:00:00'),
       ('flux-markdown','1.31.0','https://example.invalid/mid.dmg','ee','dmg','2026-02-01T00:00:00'),
       ('flux-markdown','1.32.427','https://example.invalid/cur.dmg','aa','dmg','2026-03-01T00:00:00');
SQL

# 3. Cask human: section appears with both prior cask versions.
CASK_OUT="$PREFIX/cask.out"
"$BIN" info flux-markdown >"$CASK_OUT" 2>&1 ||
  fail "mt info flux-markdown exited non-zero (see $CASK_OUT)"
grep -q 'Available rollback versions for flux-markdown' "$CASK_OUT" ||
  fail "mt info <cask> did not emit the rollback section (see $CASK_OUT)"
grep -q '1.30.0' "$CASK_OUT" || fail "mt info <cask> missing 1.30.0 (see $CASK_OUT)"
grep -q '1.31.0' "$CASK_OUT" || fail "mt info <cask> missing 1.31.0 (see $CASK_OUT)"
SECTION_LINE=$(grep -n 'Available rollback versions' "$CASK_OUT" | head -1 | cut -d: -f1)
tail -n +"$SECTION_LINE" "$CASK_OUT" | grep -q '1.32.427' &&
  fail "mt info <cask> should not list the current version in its own history"
pass "mt info <cask> appends the rollback section (skipping the current version)"

# 4. Cask --json: parses cleanly, available_rollback_versions has the entries.
CASK_JSON_OUT="$PREFIX/cask.json"
"$BIN" --json info flux-markdown >"$CASK_JSON_OUT" 2>&1 ||
  fail "mt --json info flux-markdown exited non-zero (see $CASK_JSON_OUT)"
CASK_JSON=$(cat "$CASK_JSON_OUT")
case "$CASK_JSON" in
*'"available_rollback_versions":'*) ;;
*) fail "mt --json info <cask> missing available_rollback_versions key (see $CASK_JSON_OUT)" ;;
esac
case "$CASK_JSON" in
*'"version":"1.31.0"'*'"version":"1.30.0"'*) ;;
*) fail "mt --json info <cask>: expected 1.31.0 before 1.30.0 (see $CASK_JSON_OUT)" ;;
esac
pass "mt info <cask> --json carries the rollback entries[] shape"

# --- empty-history case: no section in human, [] in JSON ------------------
sqlite3 "$DB" <<SQL
INSERT INTO casks (token, name, version, url, sha256)
VALUES ('firefox', 'Firefox', '120.0',
        'https://example.invalid/ff.dmg', 'bb');
SQL

EMPTY_OUT="$PREFIX/empty.out"
"$BIN" info firefox >"$EMPTY_OUT" 2>&1 ||
  fail "mt info firefox exited non-zero (see $EMPTY_OUT)"
if grep -q 'Available rollback versions' "$EMPTY_OUT"; then
  fail "mt info <cask> with no history should not emit the section (see $EMPTY_OUT)"
fi
pass "mt info <pkg> with empty history suppresses the section"

EMPTY_JSON_OUT="$PREFIX/empty.json"
"$BIN" --json info firefox >"$EMPTY_JSON_OUT" 2>&1 ||
  fail "mt --json info firefox exited non-zero (see $EMPTY_JSON_OUT)"
case "$(cat "$EMPTY_JSON_OUT")" in
*'"available_rollback_versions":[]'*) ;;
*) fail "mt --json info <cask> with no history: expected available_rollback_versions:[] (see $EMPTY_JSON_OUT)" ;;
esac
pass "mt info <pkg> --json with empty history emits available_rollback_versions:[]"

printf '\n\xe2\x9c\x94 info-rollback-history regression passed\n'
