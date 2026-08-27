#!/usr/bin/env bash
# Regression: uninstalling a cask must sweep only its OWN cached per-version
# artefacts — the versions recorded in cask_versions — not every file whose
# basename shares a bare `<token>-` prefix.
#
# The bug: the uninstall cache sweep matched `startsWith("<token>-")`. The
# token `git` is a lexical prefix of the sibling token `git-lfs`, so
# uninstalling `git` also deleted `git-lfs`'s cached artefact. Versions
# legitimately contain dashes, so no purely lexical tightening can separate a
# real version from a sibling token's suffix; the authoritative version list
# is the only safe signal.
#
# The fix drives the sweep from `SELECT version FROM cask_versions WHERE
# token = ?1` and deletes the exact `<token>-<version>.<ext>` shape per row.
# The download cache is recoverable, but forcing an unrelated cask to
# re-download on its next install is a real cost the sweep must never impose.
#
# End-to-end, offline: seed a DB row + cached artefact for `git` and a sibling
# cache file for `git-lfs`, run `malt uninstall git`, and assert the sibling
# survives. Pre-fix the sibling is wiped (exit 1); post-fix it survives.

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

PREFIX=$(mktemp -d /tmp/mt.XXX)
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
mkdir -p "$PREFIX/db" "$PREFIX/cache/Cask"
trap 'rm -rf "$PREFIX"' EXIT

DB="$PREFIX/db/malt.db"

# Let malt create the DB with the current schema. A fresh prefix has no
# install, so this exits non-zero ("not installed") — we only want the schema.
"$BIN" uninstall git >/dev/null 2>&1 || true
[[ -f "$DB" ]] || {
  echo "FAIL: malt did not initialise its database" >&2
  exit 1
}

# Seed an installed `git` cask + its per-version history row. app_path points
# at an absent bundle so the uninstall's deleteTree is a no-op.
sqlite3 "$DB" "
INSERT INTO casks (token, name, version, url, app_path)
VALUES ('git', 'Git', '2.39.0', 'https://x.invalid/git.dmg', '$PREFIX/Caskroom/git/2.39.0/Git.app');
INSERT INTO cask_versions (token, version, url, artifact_type)
VALUES ('git', '2.39.0', 'https://x.invalid/git.dmg', 'dmg');
" || {
  echo "FAIL: could not seed cask rows" >&2
  exit 1
}

: >"$PREFIX/cache/Cask/git-2.39.0.dmg"  # git's own artefact — expected swept
: >"$PREFIX/cache/Cask/git-lfs-2.0.dmg" # prefix sibling — must survive

"$BIN" uninstall git >/dev/null 2>&1 || true

[[ ! -e "$PREFIX/cache/Cask/git-2.39.0.dmg" ]] || {
  echo "FAIL: git's own cached artefact was not swept" >&2
  exit 1
}
[[ -e "$PREFIX/cache/Cask/git-lfs-2.0.dmg" ]] || {
  echo "FAIL: sibling git-lfs cached artefact was deleted by git's uninstall" >&2
  exit 1
}

echo "PASS: uninstall swept only the cask's own cached versions"
