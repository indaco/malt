#!/usr/bin/env bash
# Regression: a change to the relocation logic must be paired with a decision
# about `RELOC_LOGIC_VERSION`.
#
# The bug: the Mach-O patcher gained LC_RPATH dedup, but the relocated-keg
# cache version stayed at 1. `store-relocated/v1/<bottle-sha>` still held the
# keg relocated by the OLD patcher, and `cellar.materializeWithCellar` serves
# that snapshot before it ever extracts or patches. Every user who had already
# installed the affected bottle kept the broken binary across reinstall,
# uninstall+install and cleanup - the shipped fix could not reach them.
#
# The versioned cache key (guarded by relocated-store-versioned-cache-key.sh)
# only helps if somebody remembers to bump it, so this script removes the
# remembering: it pins a digest of every source file whose behaviour ends up
# baked into a cached keg. When one of them changes, the digest stops matching
# and the run fails, forcing the bump-or-not call to be made explicitly.
#
# Answering the prompt:
#   - relocated bytes change  -> bump RELOC_LOGIC_VERSION, then re-run --update
#   - comments/tests only     -> re-run --update, leave the version alone
#
# Exits 0 when the pin matches the tree, non-zero otherwise. No network, no
# build; pure source inspection.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PIN="$ROOT/scripts/regressions/relocated-store-logic-version.pin"
STORE="$ROOT/src/core/relocated_store.zig"

# Everything whose output is captured in a `store-relocated` snapshot: the
# keg relocation walk, the Mach-O patcher it drives, and the ad-hoc codesign
# applied on the way out. relocated_store.zig itself is deliberately absent -
# it carries the version constant, so including it would make every bump
# invalidate its own pin.
SOURCES=(
  src/core/cellar.zig
  src/core/patch.zig
  src/macho/patcher.zig
  src/macho/parser.zig
  src/macho/codesign.zig
)

for rel in "${SOURCES[@]}"; do
  [ -f "$ROOT/$rel" ] || {
    echo "FAIL: relocation-logic source $rel is missing; the pin no longer covers the real code" >&2
    exit 1
  }
done

# Digest of the per-file digests: order is fixed by SOURCES, so the result is
# independent of directory listing order and of where the repo is checked out.
digest_now() {
  (cd "$ROOT" && shasum -a 256 "${SOURCES[@]}" | shasum -a 256 | cut -d' ' -f1)
}

version_now() {
  grep -Eo 'RELOC_LOGIC_VERSION: u32 = [0-9]+' "$STORE" | grep -Eo '[0-9]+$'
}

version=$(version_now)
[ -n "$version" ] || {
  echo "FAIL: could not read RELOC_LOGIC_VERSION from relocated_store.zig" >&2
  exit 1
}
digest=$(digest_now)

if [ "${1:-}" = "--update" ]; then
  printf 'version=%s\ndigest=%s\n' "$version" "$digest" >"$PIN"
  echo "OK: pinned relocation logic at version $version"
  exit 0
fi

[ -f "$PIN" ] || {
  echo "FAIL: pin file missing at $PIN; run '$0 --update' to create it" >&2
  exit 1
}

pinned_version=$(grep -E '^version=' "$PIN" | cut -d= -f2)
pinned_digest=$(grep -E '^digest=' "$PIN" | cut -d= -f2)

if [ "$digest" != "$pinned_digest" ]; then
  echo "FAIL: relocation logic changed since the pin was written." >&2
  echo "      If the relocated bytes change, bump RELOC_LOGIC_VERSION (currently $version)" >&2
  echo "      in src/core/relocated_store.zig so cached kegs are re-relocated." >&2
  echo "      Then run: $0 --update" >&2
  exit 1
fi

if [ "$version" != "$pinned_version" ]; then
  echo "FAIL: RELOC_LOGIC_VERSION is $version but the pin records $pinned_version." >&2
  echo "      Run: $0 --update" >&2
  exit 1
fi

echo "OK: relocation logic matches the pin at version $version"
