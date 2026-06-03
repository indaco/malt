#!/usr/bin/env bash
# End-to-end check that the v10→v11 migration runs cleanly when triggered
# by the actual `mt` binary, and that the new `host` column backfills to
# `github.com` for every pre-v11 row.
#
# Pinned behaviour:
#   1. A v10-shaped DB (taps with name/url/commit_sha/head_etag/
#      github_owner/github_repo but *without* host) upgrades to v11 on
#      first `mt` open. Existing rows backfill to host='github.com'.
#   2. A row carrying a non-github host survives unchanged, and the
#      `taps.url` projection in `mt --json tap` is driven by that host —
#      a gitlab.com row resolves to its own instance, not a github URL.
#
# Methodology: build a v11 DB against the current binary's initSchema,
# rewind the taps table to the v10 shape and the schema_version marker to
# 10, then re-run `mt tap` (which calls initSchema → migrate). No network.
#
# Requirements: a built malt binary at zig-out/bin/malt; sqlite3 CLI; jq.
#
# Usage: scripts/regressions/tap_v11_schema_migration.sh

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

PREFIX=$(mktemp -d -t mt_v11_XXXXXX)
trap 'rm -rf "$PREFIX"' EXIT
mkdir -p "$PREFIX/db"
DB="$PREFIX/db/malt.db"

export MALT_PREFIX="$PREFIX"

# Step 1: bootstrap the DB at the current schema (>=v11).
"$MT" tap >/dev/null 2>&1 || true
[[ -f "$DB" ]] || {
  printf 'FAIL: mt did not create %s\n' "$DB" >&2
  exit 1
}

ver=$(sqlite3 "$DB" "SELECT MAX(version) FROM schema_version;")
[[ "$ver" -ge 11 ]] || {
  printf 'FAIL: fresh DB at v%s, expected at least v11.\n' "$ver" >&2
  exit 1
}

# Rewind the taps table to the v10 shape (drop host) and the marker to 10
# so the next `mt` invocation re-runs v10→v11.
sqlite3 "$DB" <<'SQL'
BEGIN;
DELETE FROM schema_version WHERE version >= 11;
CREATE TABLE taps_v10 (
    id            INTEGER PRIMARY KEY,
    name          TEXT NOT NULL UNIQUE,
    url           TEXT NOT NULL,
    added_at      TEXT NOT NULL DEFAULT (datetime('now')),
    commit_sha    TEXT,
    head_etag     TEXT,
    github_owner  TEXT NOT NULL DEFAULT '',
    github_repo   TEXT NOT NULL DEFAULT ''
);
INSERT INTO taps_v10 (id, name, url, added_at, commit_sha, head_etag, github_owner, github_repo)
SELECT id, name, url, added_at, commit_sha, head_etag, github_owner, github_repo FROM taps;
DROP TABLE taps;
ALTER TABLE taps_v10 RENAME TO taps;
INSERT INTO taps (name, url, commit_sha, github_owner, github_repo) VALUES
  ('aeroxy/tap', 'https://github.com/aeroxy/homebrew-tap', '0123456789abcdef0123456789abcdef01234567', 'aeroxy', 'homebrew-tap'),
  ('user/repo',  'https://github.com/user/homebrew-repo',  NULL, 'user', 'homebrew-repo');
COMMIT;
SQL

ver_after=$(sqlite3 "$DB" "SELECT MAX(version) FROM schema_version;")
[[ "$ver_after" == "10" ]] || {
  printf 'FAIL: rewind did not land at v10 (got %s).\n' "$ver_after" >&2
  exit 1
}

# Step 2: run `mt tap` so initSchema → migrate triggers v10→v11.
"$MT" tap >/dev/null 2>&1 || true

# Step 3: assert the migration landed at v11 (or newer) with host backfilled.
ver_post=$(sqlite3 "$DB" "SELECT MAX(version) FROM schema_version;")
[[ "$ver_post" -ge 11 ]] || {
  printf 'FAIL: migration did not bump to at least v11 (got %s).\n' "$ver_post" >&2
  exit 1
}
printf '  ✓ schema_version reached at least v11 (got %s)\n' "$ver_post"

host1=$(sqlite3 "$DB" "SELECT host FROM taps WHERE name='aeroxy/tap';")
[[ "$host1" == "github.com" ]] || {
  printf 'FAIL: aeroxy/tap host = %s, expected github.com.\n' "$host1" >&2
  exit 1
}
host2=$(sqlite3 "$DB" "SELECT host FROM taps WHERE name='user/repo';")
[[ "$host2" == "github.com" ]] || {
  printf 'FAIL: user/repo host = %s, expected github.com.\n' "$host2" >&2
  exit 1
}
printf '  ✓ existing rows backfilled to host=github.com\n'

# Step 4: a non-github host persists, is read, and now drives the URL
# projection — the gitlab arm resolves a gitlab.com row to its own host.
sqlite3 "$DB" "INSERT INTO taps (name, url, commit_sha, github_owner, github_repo, host) VALUES ('grp/tap', 'https://gitlab.com/grp/tap', NULL, 'grp', 'tap', 'gitlab.com');"

host3=$(sqlite3 "$DB" "SELECT host FROM taps WHERE name='grp/tap';")
[[ "$host3" == "gitlab.com" ]] || {
  printf 'FAIL: grp/tap host = %s, expected gitlab.com.\n' "$host3" >&2
  exit 1
}

json=$("$MT" --json tap 2>/dev/null)
projected=$(printf '%s' "$json" | jq -r '.[] | select(.name=="grp/tap") | .url')
[[ "$projected" == "https://gitlab.com/grp/tap" ]] || {
  printf 'FAIL: grp/tap URL projection = %s, expected https://gitlab.com/grp/tap.\n' "$projected" >&2
  exit 1
}
printf '  ✓ non-github host stored, read, and projected through the gitlab arm\n'

# Step 5: rerun migration on the now-v11 DB — must be a no-op.
"$MT" tap >/dev/null 2>&1 || true
host1_post=$(sqlite3 "$DB" "SELECT host FROM taps WHERE name='aeroxy/tap';")
[[ "$host1_post" == "github.com" ]] || {
  printf 'FAIL: idempotent rerun mutated the row host (%s).\n' "$host1_post" >&2
  exit 1
}
printf '  ✓ migration is idempotent on an already-v11 DB\n'

printf '\n✔ tap v10→v11 schema migration regression passed\n'
