#!/usr/bin/env bash
# Regression: `bundle import` must record the manifest by its canonical
# absolute path, and `remove --purge` must never resolve a stored relative
# one against the cwd.
#
# The bug: `import` persisted the typed path verbatim, so a later
# `remove --purge` re-opened it against whatever cwd that invocation ran
# from. A same-named file there silently became the purge plan; no file at
# all made the command fail. Rows written by older binaries still carry the
# relative path; purge now plans from the recorded members, never a file.
#
# Runs the built binary against a throwaway prefix; the purge is a dry run
# so nothing is ever uninstalled. No network.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

# `zig build test` never refreshes the CLI binary; build it so this exercises
# current source rather than a stale artefact.
if ! zig build >/dev/null 2>&1; then
  echo "FAIL: could not build the malt binary (zig build)" >&2
  exit 1
fi

MT="${MT:-$ROOT/zig-out/bin/mt}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export MALT_PREFIX="$TMP/p" NO_COLOR=1 MALT_NO_EMOJI=1
mkdir -p "$MALT_PREFIX" "$TMP/a" "$TMP/b"
DB="$MALT_PREFIX/db/malt.db"

printf 'brew "only-in-a"\n' >"$TMP/a/Brewfile"
# Deliberately unparsable: reading it from `b` is unmistakable in the output.
printf 'not a brewfile ((\n' >"$TMP/b/Brewfile"

fail=0

(cd "$TMP/a" && "$MT" bundle import Brewfile >/dev/null 2>&1)
# `pwd -P` resolves symlinks the same way the store does. An unnamed
# manifest is registered by that same canonical path.
want="$(cd "$TMP/a" && pwd -P)/Brewfile"
stored=$(sqlite3 "$DB" "select manifest_path from bundles where name='$want';")
if [[ "$stored" != "$want" ]]; then
  echo "FAIL: import stored '$stored', want '$want'" >&2
  fail=1
fi

# Named by a non-canonical spelling, from another cwd: still a's manifest.
if ! out=$(cd "$TMP/b" && "$MT" bundle remove --purge --dry-run "$TMP/a/Brewfile" 2>&1); then
  echo "FAIL: purge from another cwd failed: $out" >&2
  fail=1
elif grep -q "parse error" <<<"$out"; then
  echo "FAIL: purge read b/Brewfile instead of the imported file" >&2
  fail=1
fi
# A bare `Brewfile` there names b's file, which is not registered.
if out=$(cd "$TMP/b" && "$MT" bundle remove --purge --dry-run Brewfile 2>&1); then
  echo "FAIL: purge of an unregistered Brewfile succeeded: $out" >&2
  fail=1
elif grep -q "parse error" <<<"$out"; then
  echo "FAIL: purge read b/Brewfile" >&2
  fail=1
fi

# Legacy row: a pre-fix binary stored the relative path as typed, and no
# members. Installed, `only-in-a` shows up in any plan read from a's file.
sqlite3 "$DB" "insert into bundles(name,manifest_path,created_at,version) values('legacy','Brewfile',0,1);
  insert into kegs(name,full_name,version,store_sha256,cellar_path,tap,tap_rb_subtree,install_reason)
  values('only-in-a','only-in-a','1.0','a','/c/only-in-a','homebrew/core',NULL,'direct');"
# No members to go by: refuse, in a real run too, rather than unregister it
# as if the purge had happened.
for mode in --dry-run --yes; do
  if msg=$(cd "$TMP/a" && "$MT" bundle remove --purge "$mode" legacy 2>&1); then
    echo "FAIL: purge $mode of a bundle with no recorded members succeeded: $msg" >&2
    fail=1
  elif grep -q "only-in-a" <<<"$msg"; then
    echo "FAIL: legacy relative manifest_path was resolved against cwd: $msg" >&2
    fail=1
  elif ! grep -q "no recorded members" <<<"$msg"; then
    echo "FAIL: refusal did not say why: $msg" >&2
    fail=1
  fi
done
if [[ "$(sqlite3 "$DB" "select count(*) from bundles where name='legacy';")" != "1" ]]; then
  echo "FAIL: a refused purge unregistered the legacy bundle" >&2
  fail=1
fi

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi

echo "PASS: bundle import records the canonical manifest path"
