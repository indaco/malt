#!/usr/bin/env bash
# End-to-end check that the v11→v12 migration runs cleanly when triggered
# by the actual `mt` binary on an upgrade of an existing installation, and
# that the new nullable `forge` column changes nothing for pre-hint rows.
#
# Pinned behaviour:
#   1. A v11-shaped DB (taps with host but *without* forge) upgrades to v12
#      on first `mt` open. Existing rows get forge = NULL.
#   2. NULL forge means "classify by host": a github.com row still projects
#      a github URL, a gitlab.com row a gitlab URL — byte-for-byte as before.
#   3. After the upgrade, a fresh `--forge` registration persists the hint
#      and resolves a custom-domain instance as the named provider.
#   4. The migration is idempotent on an already-v12 DB.
#
# Methodology: build a DB against the current binary's initSchema, rewind
# the taps table to the v11 shape (drop forge) and the marker to 11, then
# re-run `mt tap` (initSchema → migrate). No network.
#
# Requirements: a built malt binary at zig-out/bin/malt; sqlite3 CLI; jq.
#
# Usage: scripts/regressions/tap_v12_schema_migration.sh

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

PREFIX=$(mktemp -d -t mt_v12_XXXXXX)
trap 'rm -rf "$PREFIX"' EXIT
mkdir -p "$PREFIX/db"
DB="$PREFIX/db/malt.db"

export MALT_PREFIX="$PREFIX"

# Step 1: bootstrap the DB at the current schema (>=v12).
"$MT" tap >/dev/null 2>&1 || true
[[ -f "$DB" ]] || {
  printf 'FAIL: mt did not create %s\n' "$DB" >&2
  exit 1
}

# Rewind the taps table to the v11 shape (with host, without forge) and the
# marker to 11 so the next `mt` invocation re-runs v11→v12.
sqlite3 "$DB" <<'SQL'
BEGIN;
DELETE FROM schema_version WHERE version >= 12;
CREATE TABLE taps_v11 (
    id            INTEGER PRIMARY KEY,
    name          TEXT NOT NULL UNIQUE,
    url           TEXT NOT NULL,
    added_at      TEXT NOT NULL DEFAULT (datetime('now')),
    commit_sha    TEXT,
    head_etag     TEXT,
    github_owner  TEXT NOT NULL DEFAULT '',
    github_repo   TEXT NOT NULL DEFAULT '',
    host          TEXT NOT NULL DEFAULT 'github.com'
);
INSERT INTO taps_v11 (id, name, url, added_at, commit_sha, head_etag, github_owner, github_repo, host)
SELECT id, name, url, added_at, commit_sha, head_etag, github_owner, github_repo, host FROM taps;
DROP TABLE taps;
ALTER TABLE taps_v11 RENAME TO taps;
INSERT INTO taps (name, url, commit_sha, github_owner, github_repo, host) VALUES
  ('aeroxy/tap', 'https://github.com/aeroxy/homebrew-tap', NULL, 'aeroxy', 'homebrew-tap', 'github.com'),
  ('grp/tap',    'https://gitlab.com/grp/tap',             NULL, 'grp',    'tap',          'gitlab.com');
COMMIT;
SQL

ver_after=$(sqlite3 "$DB" "SELECT MAX(version) FROM schema_version;")
[[ "$ver_after" == "11" ]] || {
  printf 'FAIL: rewind did not land at v11 (got %s).\n' "$ver_after" >&2
  exit 1
}

# Step 2: run `mt tap` so initSchema → migrate triggers v11→v12.
"$MT" tap >/dev/null 2>&1 || true

# Step 3: the migration landed at v12 and the forge column is present + NULL.
ver_post=$(sqlite3 "$DB" "SELECT MAX(version) FROM schema_version;")
[[ "$ver_post" -ge 12 ]] || {
  printf 'FAIL: migration did not bump to at least v12 (got %s).\n' "$ver_post" >&2
  exit 1
}
printf '  ✓ schema_version reached at least v12 (got %s)\n' "$ver_post"

sqlite3 "$DB" "PRAGMA table_info(taps);" | grep -q '|forge|' || {
  printf 'FAIL: taps.forge column missing after v11→v12.\n' >&2
  exit 1
}
nulls=$(sqlite3 "$DB" "SELECT COUNT(*) FROM taps WHERE forge IS NOT NULL;")
[[ "$nulls" == "0" ]] || {
  printf 'FAIL: %s pre-upgrade rows carry a non-NULL forge (expected all NULL).\n' "$nulls" >&2
  exit 1
}
printf '  ✓ existing rows gained a NULL forge (classify-by-host preserved)\n'

# Step 4: NULL forge keeps resolution byte-for-byte — host still classifies.
json=$("$MT" --json tap 2>/dev/null)
gh_url=$(printf '%s' "$json" | jq -r '.[] | select(.name=="aeroxy/tap") | .url')
[[ "$gh_url" == "https://github.com/aeroxy/homebrew-tap" ]] || {
  printf 'FAIL: github row projection changed: %s\n' "$gh_url" >&2
  exit 1
}
gl_url=$(printf '%s' "$json" | jq -r '.[] | select(.name=="grp/tap") | .url')
[[ "$gl_url" == "https://gitlab.com/grp/tap" ]] || {
  printf 'FAIL: gitlab row projection = %s, expected https://gitlab.com/grp/tap.\n' "$gl_url" >&2
  exit 1
}
printf '  ✓ NULL-forge rows resolve unchanged (github + host-classified gitlab)\n'

# Step 5: a post-upgrade --forge registration persists the hint and resolves
# a custom-domain instance the host alone could not classify.
"$MT" tap acme/tap --host code.acme.com --forge gitlab --repo acme/tap >/dev/null 2>&1 || {
  printf 'FAIL: mt tap --forge gitlab on a custom domain exited non-zero.\n' >&2
  exit 1
}
stored=$(sqlite3 "$DB" "SELECT forge FROM taps WHERE name='acme/tap';")
[[ "$stored" == "gitlab" ]] || {
  printf 'FAIL: expected stored forge gitlab, got %s.\n' "$stored" >&2
  exit 1
}
json=$("$MT" --json tap 2>/dev/null)
acme_url=$(printf '%s' "$json" | jq -r '.[] | select(.name=="acme/tap") | .url')
[[ "$acme_url" == "https://code.acme.com/acme/tap" ]] || {
  printf 'FAIL: --forge custom-domain projection = %s, expected https://code.acme.com/acme/tap.\n' "$acme_url" >&2
  exit 1
}
printf '  ✓ post-upgrade --forge pins a custom-domain GitLab instance\n'

# Step 6: rerun migration on the now-v12 DB — must be a no-op.
"$MT" tap >/dev/null 2>&1 || true
stored_post=$(sqlite3 "$DB" "SELECT forge FROM taps WHERE name='acme/tap';")
[[ "$stored_post" == "gitlab" ]] || {
  printf 'FAIL: idempotent rerun mutated the stored forge (%s).\n' "$stored_post" >&2
  exit 1
}
printf '  ✓ migration is idempotent on an already-v12 DB\n'

printf '\n✔ tap v11→v12 schema migration regression passed\n'
