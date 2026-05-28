#!/usr/bin/env bash
# End-to-end check that the v8→v9 migration runs cleanly when triggered
# by the actual `mt` binary, and that the (github_owner, github_repo)
# pair is backfilled correctly from existing slugs.
#
# Pinned behaviour:
#   1. A v8-shaped DB (taps with name/url/commit_sha/head_etag but
#      *without* github_owner/github_repo) upgrades to v9 on first
#      `mt` open. Existing rows backfill to (user, "homebrew-" || repo).
#   2. The `taps.url` projection in `mt --json tap` reflects the
#      stored (github_owner, github_repo) pair — a custom-repo row
#      surfaces its exact URL, not the `homebrew-<repo>` synthesis.
#   3. The new columns carry NOT NULL — the migration's DEFAULT ''
#      plus the backfill UPDATE must converge on real values.
#
# Methodology: build a v8 DB by hand against the current binary's
# initSchema, rewind the schema_version marker, then re-run `mt tap`
# (which calls initSchema → migrate). No network needed.
#
# Requirements: a built malt binary at zig-out/bin/malt; sqlite3 CLI;
# jq for JSON probes.
#
# Usage: scripts/regressions/tap_v9_schema_migration.sh

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

MT="$ROOT/zig-out/bin/malt"
if [[ ! -x "$MT" ]]; then
  printf 'FAIL: malt binary not found at %s — run "zig build" first.\n' "$MT" >&2
  exit 1
fi
command -v sqlite3 >/dev/null || {
  printf 'SKIP: sqlite3 CLI required.\n' >&2
  exit 0
}
command -v jq >/dev/null || {
  printf 'SKIP: jq required.\n' >&2
  exit 0
}

PREFIX=$(mktemp -d -t mt_v9_XXXXXX)
trap 'rm -rf "$PREFIX"' EXIT
mkdir -p "$PREFIX/db"
DB="$PREFIX/db/malt.db"

export MALT_PREFIX="$PREFIX"

# Step 1: bootstrap the DB at the current schema (v9), seed a row, then
# rewind schema_version to 8 so the next `mt` invocation re-runs v8→v9.
"$MT" tap >/dev/null 2>&1 || true
[[ -f "$DB" ]] || {
  printf 'FAIL: mt did not create %s\n' "$DB" >&2
  exit 1
}

ver=$(sqlite3 "$DB" "SELECT MAX(version) FROM schema_version;")
[[ "$ver" == "9" ]] || {
  printf 'FAIL: fresh DB at v%s, expected v9.\n' "$ver" >&2
  exit 1
}

# Drop the v9 columns and rewind to simulate an upgraded-from-v8 DB.
# SQLite has no DROP COLUMN before 3.35 — emulate via table rebuild.
sqlite3 "$DB" <<'SQL'
BEGIN;
DELETE FROM schema_version WHERE version >= 9;
CREATE TABLE taps_v8 (
    id         INTEGER PRIMARY KEY,
    name       TEXT NOT NULL UNIQUE,
    url        TEXT NOT NULL,
    added_at   TEXT NOT NULL DEFAULT (datetime('now')),
    commit_sha TEXT,
    head_etag  TEXT
);
INSERT INTO taps_v8 (id, name, url, added_at, commit_sha, head_etag)
SELECT id, name, url, added_at, commit_sha, head_etag FROM taps;
DROP TABLE taps;
ALTER TABLE taps_v8 RENAME TO taps;
INSERT INTO taps (name, url, commit_sha) VALUES
  ('aeroxy/tap',  'https://github.com/aeroxy/homebrew-tap',  '0123456789abcdef0123456789abcdef01234567'),
  ('user/repo',   'https://github.com/user/homebrew-repo',   NULL),
  ('user-1/some.v2', 'https://github.com/user-1/homebrew-some.v2', NULL);
COMMIT;
SQL

ver_after=$(sqlite3 "$DB" "SELECT MAX(version) FROM schema_version;")
[[ "$ver_after" == "8" ]] || {
  printf 'FAIL: rewind did not land at v8 (got %s).\n' "$ver_after" >&2
  exit 1
}

# Step 2: run `mt tap` so initSchema → migrate triggers v8→v9.
"$MT" tap >/dev/null 2>&1 || true

# Step 3: assert the migration landed at v9 with the expected backfill.
ver_post=$(sqlite3 "$DB" "SELECT MAX(version) FROM schema_version;")
[[ "$ver_post" == "9" ]] || {
  printf 'FAIL: migration did not bump to v9 (got %s).\n' "$ver_post" >&2
  exit 1
}
printf '  ✓ schema_version bumped 8 -> 9\n'

row1=$(sqlite3 -separator '|' "$DB" "SELECT github_owner, github_repo FROM taps WHERE name='aeroxy/tap';")
[[ "$row1" == "aeroxy|homebrew-tap" ]] || {
  printf 'FAIL: aeroxy/tap backfill = %s, expected aeroxy|homebrew-tap.\n' "$row1" >&2
  exit 1
}
printf '  ✓ aeroxy/tap backfilled to (aeroxy, homebrew-tap)\n'

row2=$(sqlite3 -separator '|' "$DB" "SELECT github_owner, github_repo FROM taps WHERE name='user-1/some.v2';")
[[ "$row2" == "user-1|homebrew-some.v2" ]] || {
  printf 'FAIL: user-1/some.v2 backfill = %s.\n' "$row2" >&2
  exit 1
}
printf '  ✓ hyphens and dots preserved in backfill\n'

# Step 4: insert a custom-repo row directly, confirm the URL projection
# in `mt --json tap` reflects the stored pair (not the homebrew- default).
sqlite3 "$DB" "INSERT INTO taps (name, url, commit_sha, github_owner, github_repo) VALUES ('aeroxy/ast-outline', 'https://example.invalid/decorative', NULL, 'aeroxy', 'ast-outline');"

json=$("$MT" --json tap 2>/dev/null)
projected=$(printf '%s' "$json" | jq -r '.[] | select(.name=="aeroxy/ast-outline") | .url')
[[ "$projected" == "https://github.com/aeroxy/ast-outline" ]] || {
  printf 'FAIL: custom-repo URL projection = %s, expected https://github.com/aeroxy/ast-outline.\n' "$projected" >&2
  exit 1
}
printf '  ✓ custom-repo URL projected from (github_owner, github_repo)\n'

# Step 5: rerun migration on the now-v9 DB — must be a no-op.
"$MT" tap >/dev/null 2>&1 || true
row1_post=$(sqlite3 -separator '|' "$DB" "SELECT github_owner, github_repo FROM taps WHERE name='aeroxy/tap';")
[[ "$row1_post" == "aeroxy|homebrew-tap" ]] || {
  printf 'FAIL: idempotent rerun mutated the row (%s).\n' "$row1_post" >&2
  exit 1
}
printf '  ✓ migration is idempotent on an already-v9 DB\n'

printf '\n✔ tap v8→v9 schema migration regression passed\n'
