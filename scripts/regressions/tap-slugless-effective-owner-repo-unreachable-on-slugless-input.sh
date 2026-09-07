#!/usr/bin/env bash
# Lock the tap cold path against a slugless tap name.
#
# `effectiveOwnerRepo` used to split the caller's raw slug with
# `orelse unreachable`, so a name with no `/` was UB in ReleaseFast and a
# panic in ReleaseSafe. The split now runs on the buffer
# `canonicalTapSlug` builds, which rejects a slugless input one frame
# earlier and surfaces it as a typed error.
#
# Pinned properties:
#   1. Structural — the cold path never splits the raw slug again. This
#      is the leg that guards the finding: reintroducing the direct
#      `orelse unreachable` fails here even when no CLI surface can
#      reach it today.
#   2. Behavioural — a slugless name fails typed and never panics.
#
# Usage: scripts/regressions/tap-slugless-effective-owner-repo-unreachable-on-slugless-input.sh
# Requirements: a built malt binary; POSIX grep/awk — no network.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# (1) structural
body=$(awk '/^pub fn effectiveOwnerRepo\(/,/^}/' src/core/tap.zig)
[[ -n "$body" ]] || fail "could not locate effectiveOwnerRepo in src/core/tap.zig"

if grep -q 'orelse unreachable' <<<"$body"; then
  printf "FAIL: effectiveOwnerRepo regained an 'orelse unreachable':\n\n" >&2
  grep -n 'orelse unreachable' <<<"$body" >&2
  printf "\nDerive the pair from canonicalTapSlug's buffer instead — the\n" >&2
  printf "raw slug is caller-supplied and need not contain a '/'.\n" >&2
  exit 1
fi

grep -q 'canonicalTapSlug(&canon_buf, slug) orelse return' <<<"$body" ||
  fail "cold path no longer routes its split through canonicalTapSlug"

# (2) behavioural
MALT_BIN=${MALT_BIN:-$ROOT/zig-out/bin/malt}
[[ -x "$MALT_BIN" ]] ||
  fail "malt binary not found at $MALT_BIN — run \"zig build\" first."

PREFIX=$(mktemp -d)
trap 'rm -rf "$PREFIX"' EXIT

out=$(MALT_PREFIX="$PREFIX" "$MALT_BIN" tap noslash 2>&1) && rc=0 || rc=$?
[[ $rc -eq 1 ]] || fail "expected exit 1 for a slugless tap, got $rc: $out"
grep -qi 'panic' <<<"$out" && fail "panic on a slugless tap: $out"
grep -q "Invalid tap 'noslash'" <<<"$out" ||
  fail "slugless tap did not produce the validation message: $out"

printf 'OK: the tap cold path rejects a slugless name without panicking.\n'
