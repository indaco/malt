#!/usr/bin/env bash
# Pin that tap commands do their work on a prefix that has no database yet.
#
# sqlite cannot create its file inside a `db/` that does not exist, and the
# tap command read that failure as "no taps registered" for every intent.
# That is only true for listing: add, refresh, pin and untap all reported
# success while doing nothing, so a tap the user believed was registered
# simply was not.
#
# Pinned behaviour:
#   1. A mutating intent works on a fresh prefix and leaves the database
#      behind, rather than exiting 0 having done nothing.
#   2. Listing still answers for an empty prefix without creating one, in
#      both human and --json form.
#
# Hermetic: untap and listing need no network, so nothing here leaves the box.
#
# Usage: scripts/regressions/tap-fresh-prefix-silent-noop.sh

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

MALT_BIN=${MALT_BIN:-$ROOT/zig-out/bin/malt}
if [[ ! -x "$MALT_BIN" ]]; then
  printf 'FAIL: malt binary not found at %s - run "zig build" first.\n' "$MALT_BIN" >&2
  exit 1
fi

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

PFX=$(mktemp -d -t mt_tapfresh.XXXXXX)
trap 'rm -rf "$PFX"' EXIT
export MALT_PREFIX="$PFX" NO_COLOR=1

# Listing is read-only: it must answer, and leave the prefix untouched.
out=$("$MALT_BIN" tap 2>&1) || fail "listing an empty prefix failed: $out"
grep -q 'No taps registered' <<<"$out" ||
  fail "listing an empty prefix said nothing at all: [$out]"
[[ -d "$PFX/db" ]] && fail 'listing created a database on a read-only command'

json=$("$MALT_BIN" --json tap 2>&1) || fail "--json listing failed: $json"
[[ "$json" == "[]" ]] || fail "--json listing emitted [$json], expected []"

# A mutating intent must actually run. untap needs no network, so it carries
# this half on its own.
out=$("$MALT_BIN" untap nosuch/tap 2>&1) || fail "untap on a fresh prefix failed: $out"
grep -q 'Untapped nosuch/tap' <<<"$out" ||
  fail "untap on a fresh prefix reported nothing: [$out]"
[[ -f "$PFX/db/malt.db" ]] ||
  fail 'untap reported success without ever creating the database'

printf 'PASS: tap intents act on a fresh prefix, listing leaves it alone\n'
