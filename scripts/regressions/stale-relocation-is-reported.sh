#!/usr/bin/env bash
# Regression: relocation rules change over time, and a keg materialised under
# older rules keeps whatever paths those rules produced. `wget` installed
# before the Mach-O string pass existed still reads `/opt/homebrew/etc/wgetrc`
# - it links and runs, so nothing surfaces the staleness.
#
# Relocation now stamps each keg with the logic version that produced it, and
# doctor reports kegs left behind by a later bump. The keg's own contents
# cannot answer this: a relocatable bottle legitimately keeps build-prefix
# strings, so only the recorded version separates the two cases.
#
# Pinned behaviour:
#   1. a keg stamped with the current version is silent;
#   2. a keg stamped with an older version is reported, by name, in both the
#      human and json views;
#   3. a keg with no stamp at all is silent - it predates tracking, and
#      "reinstall everything" is a guess, not a diagnosis.
#
# Exits 0 when all three hold, non-zero naming the failed one. No network.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

PREFIX=$(mktemp -d)/malt-prefix
mkdir -p "$PREFIX"
trap 'rm -rf "$(dirname "$PREFIX")"' EXIT

export MALT_PREFIX="$PREFIX" NO_COLOR=1 MALT_NO_EMOJI=1 MALT_OFFLINE=1

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

MARKER=.malt-reloc-version
CUR=$(grep -oE 'RELOC_LOGIC_VERSION: u32 = [0-9]+' "$ROOT/src/core/relocated_store.zig" | grep -oE '[0-9]+$')
[[ -n "$CUR" ]] || fail "could not read the current relocation logic version"

KEG="$PREFIX/Cellar/probe/1.0"
mkdir -p "$KEG/bin" "$PREFIX/store" "$PREFIX/db"

# doctor exits non-zero once it warns, so every capture tolerates that -
# under `pipefail` an untolerated exit fails the assertion, not the check.
row() {
  local out
  out=$("$BIN" doctor --verbose 2>&1 1>/dev/null || true)
  printf '%s' "$out"
}
json() { "$BIN" doctor --json 2>/dev/null || true; }

# ── 1. current stamp → silent ────────────────────────────────────────
printf '%s\n' "$CUR" >"$KEG/$MARKER"
if row | grep -q 'Relocation freshness .*older malt'; then
  fail "a keg stamped with the current version was still reported"
fi
pass "a keg relocated by the current logic is silent"

# ── 2. older stamp → reported by name ────────────────────────────────
printf '%s\n' "$((CUR - 1))" >"$KEG/$MARKER"
HUMAN=$(row)
printf '%s' "$HUMAN" | grep -q 'Relocation freshness .*older malt' ||
  fail "a keg stamped with an older version drew no warning"
printf '%s' "$HUMAN" | grep -q 'probe 1.0' ||
  fail "the relocation-freshness row did not name the affected keg"
json | grep -q '"id":"relocation_freshness","severity":"warn"' ||
  fail "doctor --json did not serialize a warn finding for relocation_freshness"
pass "a keg relocated by older logic is reported by name"

# ── 3. "relocation never ran" → silent at any version ────────────────
# Kegs extracted from a tap archive are never relocated, so no bump can
# leave them behind. Stamping that positively keeps them out of the row
# instead of relying on the absent-stamp case below.
printf 'n/a\n' >"$KEG/$MARKER"
if row | grep -q 'Relocation freshness .*older malt'; then
  fail "a keg marked as never-relocated was reported as stale"
fi
pass "a keg relocation never applied to is silent"

# ── 4. no stamp → silent ─────────────────────────────────────────────
# Every keg installed before this shipped is unstamped. Reporting them would
# recommend reinstalling the whole prefix on the strength of a guess.
rm -f "$KEG/$MARKER"
if row | grep -q 'Relocation freshness .*older malt'; then
  fail "an unstamped keg was reported as stale"
fi
pass "a keg predating the stamp is silent"

printf '\n✔ stale relocation is reported, unknown relocation is not\n'
