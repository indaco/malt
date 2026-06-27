#!/usr/bin/env bash
# Regression: `mt rollback <cask>` must serialize on the prefix advisory lock.
#
# The cask rollback path runs an uninstall+reinstall that writes the
# casks/cask_versions rows and mutates the Caskroom on disk. Every other
# mutating command — including the keg rollback path — acquires
# `<prefix>/db/malt.lock` before touching shared state, giving mutual
# exclusion against a concurrent install/upgrade/uninstall. The cask
# rollback dispatcher skipped that acquisition, so it raced freely.
#
# This holds the advisory lock from a side process (the same flock(2) malt
# uses), then runs `mt rollback <cask>`. With the lock present, the rollback
# must BLOCK on the lock; with the bug it skips the lock and proceeds to
# mutate immediately. `timeout` distinguishes the two: a blocked rollback is
# killed (exit 124), an unlocked one returns fast (any other code).
#
# Read-only paths (`--list`) must stay lock-free and succeed even while the
# lock is held.
#
# Usage: scripts/regressions/cask-rollback-malt-lock-cask-rollback-without-malt-lock.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt; sqlite3, perl,
# and timeout (coreutils/gtimeout) on PATH. Offline, no network.

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
command -v perl >/dev/null 2>&1 || {
  echo "this regression needs perl to hold the advisory lock" >&2
  exit 2
}
TIMEOUT=$(command -v timeout || command -v gtimeout || true)
[[ -n "$TIMEOUT" ]] || {
  echo "this regression needs timeout (coreutils/gtimeout) on PATH" >&2
  exit 2
}

PREFIX=$(mktemp -d)
export MALT_PREFIX="$PREFIX"
export MALT_OFFLINE=1
export NO_COLOR=1
export MALT_NO_EMOJI=1
HOLDER=""
cleanup() {
  [[ -n "$HOLDER" ]] && kill "$HOLDER" 2>/dev/null
  rm -rf "$PREFIX"
}
trap cleanup EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

mkdir -p "$PREFIX/db"

# Bootstrap the schema by letting malt open the DB once.
"$BIN" list --quiet >/dev/null 2>&1 || true
DB="$PREFIX/db/malt.db"
[[ -f "$DB" ]] || fail "DB was not initialised by mt list"

# Seed an installed cask plus >=2 cask_versions rows so a rollback target
# exists and dispatchCask reaches the mutation (and therefore the lock).
sqlite3 "$DB" <<SQL
INSERT INTO casks (token, name, version, url, sha256)
VALUES ('seeded-cask', 'seeded-cask', '2.0.0',
        'https://example.invalid/cur.dmg', 'aa');
INSERT INTO cask_versions (token, version, url, sha256, artifact_type, installed_at)
VALUES ('seeded-cask','1.0.0','https://example.invalid/old.dmg','bb','dmg','2026-01-01T00:00:00'),
       ('seeded-cask','2.0.0','https://example.invalid/cur.dmg','aa','dmg','2026-02-01T00:00:00');
SQL

LOCK="$PREFIX/db/malt.lock"
READY="$PREFIX/db/.holder_ready"

# Hold the advisory lock exactly as malt does (flock(2) exclusive) from a side
# process; touch READY only after the lock is owned so we never race the test.
perl -e 'open(my $f, ">", $ARGV[0]) or die "open: $!";
         flock($f, 2) or die "flock: $!";
         open(my $r, ">", $ARGV[1]); close($r);
         sleep $ARGV[2];' "$LOCK" "$READY" 20 &
HOLDER=$!

for _ in $(seq 1 50); do
  [[ -f "$READY" ]] && break
  sleep 0.1
done
[[ -f "$READY" ]] || fail "lock holder failed to acquire the advisory lock"

# With the lock held, cask rollback must block on it. Without the fix it skips
# the lock and mutates immediately, returning a non-124 code well under 3s.
RB_OUT="$PREFIX/rb.out"
"$TIMEOUT" 3 "$BIN" rollback seeded-cask --to 1.0.0 >"$RB_OUT" 2>&1
RC=$?

[[ "$RC" -eq 124 ]] || {
  printf '%s\n' "$(cat "$RB_OUT")" >&2
  fail "cask rollback did not block on a held malt.lock (rc=$RC) — no mutual exclusion"
}
pass "cask rollback serializes on malt.lock (blocked while held)"

# Read-only paths must stay lock-free even while the lock is held.
"$TIMEOUT" 5 "$BIN" rollback seeded-cask --list >/dev/null 2>&1 ||
  fail "rollback --list blocked or failed under a held lock — read-only paths must stay lock-free"
pass "rollback --list stays lock-free under a held lock"

printf '\n\xe2\x9c\x94 cask-rollback-malt-lock regression passed\n'
