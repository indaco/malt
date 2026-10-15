#!/usr/bin/env bash
# Regression: a background tab (Outdated, Services, Doctor) must stay dirty
# when its entry fetch could not start, so the next entry retries it.
#
# The bug: onEntryReload cleared the dirty flag before the spawn. A quiet
# spawn fault then left the tab stale, with no spinner and no retry.
#
# The logic is pure-core, so this is a source-level guard; `just test` runs
# the behaviour tests it checks for.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

fail() {
  echo "REGRESSION: $1" >&2
  exit 1
}

f=src/tui/app.zig

body=$(awk '/^fn onEntryReload\(/{on=1} on{print} on&&/^}/{exit}' "$f")
[ -n "$body" ] || fail "onEntryReload not found in $f"

# Only the fetch branch: from fetch_spec up to the blocking refreshCmd branch.
fetch_branch=$(printf '%s\n' "$body" | awk '/fetch_spec != null/{on=1} /refreshCmd/{exit} on{print}')

if printf '%s\n' "$fetch_branch" | grep -q 'if (takeDirty(app, tag))'; then
  fail "onEntryReload clears the dirty flag before the background fetch starts"
fi
printf '%s\n' "$fetch_branch" | grep -q 'tab_loading.contains(tag)' ||
  fail "onEntryReload no longer clears dirty only when the fetch is in flight"

grep -q 'keeps the tab dirty so the next entry retries it' "$f" ||
  fail "retry-on-next-entry test missing from app.zig"

echo "OK: a failed entry fetch keeps the tab dirty for the next entry"
