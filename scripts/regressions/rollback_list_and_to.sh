#!/usr/bin/env bash
# Regression: `mt rollback --list` and `--to <version>` surface the malt
# store's multi-version history without touching disk state.
#
# Pre-this-feature, rollback only landed on "the most recent previous"
# entry; users keeping three versions could not step back two and had no
# way to ask "what versions are available?" short of `ls`-ing the store.
# This regression seeds three on-disk store entries and asserts:
#
#   1. `mt rollback --list <pkg>` prints every non-current entry.
#   2. `mt rollback --list --json <pkg>` emits a parseable JSON object
#      with `name` + `entries[]` carrying `sha256`, `version`, `mtime`.
#   3. `mt rollback --to <missing> <pkg>` refuses with the listing.
#
# Sandbox-only: no network, no installs, no real bottles. The seeded
# store entries are bare directories with placeholder receipts — enough
# for `collectEntries` to discover them. The `--to` happy path requires
# a real bottle to materialize and is covered by the unit tests.
#
# Usage: scripts/regressions/rollback_list_and_to.sh
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

PREFIX="/tmp/mt_rb_reg"
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

# Bootstrap the schema by letting malt open the DB once. `list --quiet`
# does no network work and exits 0 on an empty store.
"$BIN" list --quiet >/dev/null 2>&1 || true
[[ -f "$DB" ]] || fail "DB was not initialised by mt list"

# Seed: a currently-installed wget@1.22 keg plus three on-disk store
# entries (1.20 / 1.21 / 1.22). 1.22 matches the current version so
# `--list` must omit it; 1.20 and 1.21 are the available rollback
# targets.
sqlite3 "$DB" <<SQL
INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, install_reason)
VALUES ('wget', 'wget', '1.22', 0, 'sha_cur', '/cellar/wget/1.22', 'direct');
SQL

mkdir -p "$PREFIX/store/sha_a/wget/1.20"
touch "$PREFIX/store/sha_a/wget/1.20/INSTALL_RECEIPT.json"
sleep 1.1
mkdir -p "$PREFIX/store/sha_b/wget/1.21"
touch "$PREFIX/store/sha_b/wget/1.21/INSTALL_RECEIPT.json"
sleep 1.1
mkdir -p "$PREFIX/store/sha_cur/wget/1.22"
touch "$PREFIX/store/sha_cur/wget/1.22/INSTALL_RECEIPT.json"

# --- 1. --list happy path -------------------------------------------------
LIST_OUT="$PREFIX/list.out"
"$BIN" rollback --list wget >"$LIST_OUT" 2>&1 ||
  fail "mt rollback --list wget exited non-zero — see $LIST_OUT"

grep -q '1.20' "$LIST_OUT" ||
  fail "--list missing 1.20 (see $LIST_OUT)"
grep -q '1.21' "$LIST_OUT" ||
  fail "--list missing 1.21 (see $LIST_OUT)"
if grep -q '1.22' "$LIST_OUT"; then
  fail "--list must NOT include the current version 1.22 (see $LIST_OUT)"
fi
pass "mt rollback --list lists only non-current entries"

# Newest-first ordering: 1.21 (newer mtime) before 1.20.
POS_21=$(grep -n '1.21' "$LIST_OUT" | head -1 | cut -d: -f1)
POS_20=$(grep -n '1.20' "$LIST_OUT" | head -1 | cut -d: -f1)
[[ -n "$POS_21" && -n "$POS_20" && "$POS_21" -lt "$POS_20" ]] ||
  fail "--list order: 1.21 must appear before 1.20 (1.21@$POS_21, 1.20@$POS_20)"
pass "mt rollback --list orders entries newest-first"

# --- 2. --list --json shape ----------------------------------------------
JSON_OUT="$PREFIX/list.json"
"$BIN" --json rollback --list wget >"$JSON_OUT" 2>&1 ||
  fail "mt --json rollback --list wget exited non-zero — see $JSON_OUT"

JSON=$(cat "$JSON_OUT")
case "$JSON" in
*'"name":"wget"'*) ;;
*) fail "--list --json missing name=wget (see $JSON_OUT)" ;;
esac
case "$JSON" in
*'"version":"1.21"'*'"version":"1.20"'*) ;;
*) fail "--list --json: expected 1.21 then 1.20 in document order (see $JSON_OUT)" ;;
esac
case "$JSON" in
*'"version":"1.22"'*)
  fail "--list --json must not include the current version (see $JSON_OUT)"
  ;;
esac
# Sha + mtime presence; mtime is an integer literal so the digit class suffices.
case "$JSON" in
*'"sha256":"sha_a"'*) ;;
*) fail "--list --json missing sha_a entry (see $JSON_OUT)" ;;
esac
case "$JSON" in
*'"sha256":"sha_b"'*) ;;
*) fail "--list --json missing sha_b entry (see $JSON_OUT)" ;;
esac
echo "$JSON" | grep -Eq '"mtime":[0-9]+' ||
  fail "--list --json: mtime is not an integer (see $JSON_OUT)"
pass "mt rollback --list --json emits the documented shape"

# --- 3. --to <missing> refusal -------------------------------------------
MISS_OUT="$PREFIX/miss.out"
if "$BIN" rollback --to 9.9.9 wget >"$MISS_OUT" 2>&1; then
  fail "mt rollback --to 9.9.9 wget should have exited non-zero"
fi
grep -q '1.20' "$MISS_OUT" || fail "--to missing-version did not print the listing (see $MISS_OUT)"
grep -q '1.21' "$MISS_OUT" || fail "--to missing-version did not print the listing (see $MISS_OUT)"
pass "mt rollback --to <missing> refuses and prints the available entries"

# --- 4. cask side: --list reads cask_versions history --------------------
sqlite3 "$DB" <<SQL
INSERT INTO casks (token, name, version, url, sha256)
VALUES ('flux-markdown', 'flux-markdown', '1.32.427',
        'https://example.invalid/flux.dmg', 'aa');
INSERT INTO cask_versions (token, version, url, sha256, artifact_type, installed_at)
VALUES ('flux-markdown','1.30.0','https://example.invalid/old.dmg','dd','dmg','2026-01-01T00:00:00'),
       ('flux-markdown','1.31.0','https://example.invalid/mid.dmg','ee','dmg','2026-02-01T00:00:00'),
       ('flux-markdown','1.32.427','https://example.invalid/cur.dmg','aa','dmg','2026-03-01T00:00:00');
SQL

CASK_LIST_OUT="$PREFIX/cask_list.out"
"$BIN" rollback flux-markdown --list >"$CASK_LIST_OUT" 2>&1 ||
  fail "mt rollback flux-markdown --list exited non-zero (see $CASK_LIST_OUT)"

grep -q '1.30.0' "$CASK_LIST_OUT" || fail "cask --list missing 1.30.0 (see $CASK_LIST_OUT)"
grep -q '1.31.0' "$CASK_LIST_OUT" || fail "cask --list missing 1.31.0 (see $CASK_LIST_OUT)"
if grep -q '1.32.427' "$CASK_LIST_OUT"; then
  fail "cask --list must not include the current cask version (see $CASK_LIST_OUT)"
fi
pass "mt rollback <cask> --list lists every retained cask version"

# Newest-first: 1.31.0 (2026-02) precedes 1.30.0 (2026-01).
POS_31=$(grep -n '1.31.0' "$CASK_LIST_OUT" | head -1 | cut -d: -f1)
POS_30=$(grep -n '1.30.0' "$CASK_LIST_OUT" | head -1 | cut -d: -f1)
[[ -n "$POS_31" && -n "$POS_30" && "$POS_31" -lt "$POS_30" ]] ||
  fail "cask --list order: 1.31.0 must precede 1.30.0 (1.31.0@$POS_31, 1.30.0@$POS_30)"
pass "mt rollback <cask> --list orders entries newest-first"

CASK_JSON_OUT="$PREFIX/cask_list.json"
"$BIN" --json rollback flux-markdown --list >"$CASK_JSON_OUT" 2>&1 ||
  fail "mt --json rollback flux-markdown --list exited non-zero (see $CASK_JSON_OUT)"

CASK_JSON=$(cat "$CASK_JSON_OUT")
case "$CASK_JSON" in
*'"name":"flux-markdown"'*) ;;
*) fail "cask --list --json missing name (see $CASK_JSON_OUT)" ;;
esac
case "$CASK_JSON" in
*'"version":"1.31.0"'*'"version":"1.30.0"'*) ;;
*) fail "cask --list --json: expected 1.31.0 before 1.30.0 (see $CASK_JSON_OUT)" ;;
esac
case "$CASK_JSON" in
*'"version":"1.32.427"'*)
  fail "cask --list --json must not include the current version (see $CASK_JSON_OUT)"
  ;;
esac
pass "mt rollback <cask> --list --json emits the documented shape"

# --- 5. cask --to: idempotent no-op when version == current --------------
NOOP_OUT="$PREFIX/cask_noop.out"
"$BIN" rollback flux-markdown --to 1.32.427 >"$NOOP_OUT" 2>&1 ||
  fail "mt rollback flux-markdown --to <current> should be a clean no-op (see $NOOP_OUT)"
grep -q 'already at' "$NOOP_OUT" || fail "cask --to <current> did not name the no-op (see $NOOP_OUT)"
pass "mt rollback <cask> --to <current> is an idempotent no-op"

# --- 6. cask --to: refuse when the version is absent ---------------------
CASK_MISS_OUT="$PREFIX/cask_miss.out"
if "$BIN" rollback flux-markdown --to 9.9.9 >"$CASK_MISS_OUT" 2>&1; then
  fail "mt rollback flux-markdown --to 9.9.9 should have exited non-zero"
fi
grep -q '1.31.0' "$CASK_MISS_OUT" || fail "cask --to <missing> did not print the listing (see $CASK_MISS_OUT)"
pass "mt rollback <cask> --to <missing> refuses and prints the cask history"

printf '\n\xe2\x9c\x94 rollback-list-and-to regression passed\n'
