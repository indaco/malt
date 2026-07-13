#!/usr/bin/env bash
# Regression: the relocated-keg cache must key on the relocation-logic version,
# not the bottle sha alone.
#
# The bug: `store-relocated/<sha>` cached the output of relocateKegTree
# (placeholder substitution + install_name_tool + ad-hoc codesign) keyed by the
# bottle sha only. That output depends on the relocation *rules* too, so a
# change to those rules would serve the previously-relocated keg on a warm
# reinstall of an unchanged bottle — the fix would silently not apply.
#
# The fix folds a `RELOC_LOGIC_VERSION` token into the key
# (`store-relocated/v<N>/<sha>`); bumping it invalidates every prior entry.
#
# This is a content-addressed-store *contract* guard. relocated_store.zig pulls
# in C-backed clonefile modules wired through build.zig, so the store API cannot
# be exercised standalone offline; the inline `zig build test` suite drives the
# real save/has behaviour, and this script guards the on-disk key layout at the
# source of truth so the version dimension can never silently disappear.
#
# Exits 0 when the cache key carries a version segment, non-zero otherwise.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC="$ROOT/src/core/relocated_store.zig"

[ -f "$SRC" ] || {
  echo "FAIL: relocated_store.zig not found at $SRC" >&2
  exit 1
}

# The path builder must interpolate a version segment between store-relocated/
# and the sha (the bare `store-relocated/{s}` layout is the pre-fix, stale key).
if ! grep -Eq 'store-relocated/v\{[^}]*\}/\{s\}' "$SRC"; then
  echo "FAIL: cache key is unversioned (store-relocated/<sha>); a relocation-logic change would serve a stale keg" >&2
  exit 1
fi

# The version token must exist as a bump-on-change constant.
if ! grep -Eq 'RELOC_LOGIC_VERSION' "$SRC"; then
  echo "FAIL: RELOC_LOGIC_VERSION token missing; nothing to bump on a relocation-logic change" >&2
  exit 1
fi

echo "OK: relocated-store cache key carries a relocation-logic version segment"
