#!/usr/bin/env bash
# Regression: a full `mt outdated` recompute that could not verify its kegs
# (offline with a cold API cache, upstream unreachable, Ctrl-C) must neither
# claim "All packages are up to date." nor warm `outdated.json`. A snapshot
# written from an audit that resolved nothing is byte-identical to a genuine
# all-clear, and every reader (`mt outdated`, the TUI Outdated tab) serves it
# as fresh for the whole TTL - hiding every outdated keg.
#
# Hermetic: one seeded core keg, no network.
#
#   1. Offline + cold cache: no snapshot is written and no all-clear printed.
#   2. Next run recomputes live: a seeded versions index proves the keg
#      behind and the listing shows it (not served from a poisoned cache).
#   3. Positive control: that complete audit still warms the snapshot.
#
# Manual variant (skipped here: the client's connect retry/backoff takes
# ~15 s and hits the same collapse sites): `MALT_API_DOMAIN=https://127.0.0.1:1`.
#
# Usage: scripts/regressions/outdated-recompute-does-not-persist-unverified-all-clear-failed-recompute-persists-empty-outdated-snapshot.sh
# Requirements: a built malt binary at $MALT_BIN or zig-out/bin/malt, sqlite3.
# No network access required.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

PREFIX=$(mktemp -d -t malt_outdated_unverified.XXXXXX)
trap 'rm -rf "$PREFIX"' EXIT
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$PREFIX/cache"
unset MALT_OFFLINE MALT_OUTDATED_MAX_AGE NO_COLOR CI

DB="$PREFIX/db/malt.db"
SNAP="$MALT_CACHE/outdated.json"
API="$MALT_CACHE/api"

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

# `mt list` migrates the schema only when db/ exists.
mkdir -p "$PREFIX/db" "$API"
"$BIN" list >/dev/null 2>&1 || true
sqlite3 "$DB" "INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
  VALUES ('behind_row','behind_row','1.0',0,'seedsha','/tmp/c/behind_row/1.0');"

# (1) Offline + cold cache: nothing verified => nothing cached, no all-clear.
out=$(MALT_OFFLINE=1 "$BIN" outdated 2>&1) || true
if [[ -e "$SNAP" ]]; then
  fail "unverified offline recompute persisted a snapshot: $(cat "$SNAP")"
fi
if grep -q 'All packages are up to date' <<<"$out"; then
  fail "offline recompute claimed all-clear for a keg it could not check: $out"
fi
pass "unverified recompute writes no snapshot and claims no all-clear"

# (2) Next run recomputes live: the seeded index proves the keg behind.
printf 'behind_row\t4.0\t0\n' >"$API/versions_formula.txt"
out=$("$BIN" outdated 2>&1) || true
if ! grep -q 'behind_row' <<<"$out"; then
  fail "outdated keg hidden after a failed recompute: $out"
fi
pass "next run recomputes live and lists the outdated keg"

# (3) Positive control: a complete audit still warms the snapshot.
if ! [[ -e "$SNAP" ]] || ! grep -qF 'behind_row' "$SNAP"; then
  fail "complete recompute did not warm the snapshot naming the keg"
fi
pass "complete recompute warms the snapshot"

printf '\n\xe2\x9c\x94 outdated unverified-audit no-cache regression passed\n'
