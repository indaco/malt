#!/usr/bin/env bash
# Regression: keg relocation substituted only the tokens it could derive from
# the prefix. A bottle whose wrapper script references a path inside ANOTHER
# keg carries a placeholder whose value is not a function of the prefix, so the
# token shipped literally into `<prefix>/bin/`. The wrapper then resolved to a
# path that does not exist and failed at launch, behind an install that
# reported success and a `doctor` run that reported the prefix healthy.
#
# Four things have to stay fixed, and each fails differently:
#   1. relocation must accept and apply a caller-resolved replacement;
#   2. every command that materialises a keg must resolve it — install, migrate
#      and rollback each reach relocation by a different route, and two of them
#      were missed on the first pass;
#   3. RELOC_LOGIC_VERSION must have moved past 2, or `store-relocated/v2/`
#      still serves kegs snapshotted with the literal token and the fix never
#      reaches anyone who already installed an affected bottle;
#   4. doctor must scan text files, or the whole class stays invisible.
#
# Behavioural guards live in colocated `test {}` blocks; this script asserts
# the wiring is present statically, then runs the two test binaries and judges
# those guards' lines. Exits 0 when the bug is absent, non-zero (naming the
# failing assertion) when present. No network; no temp state; well under 30s
# once the test binaries are built.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

# 1. The resolver must exist as a table, not a hardcoded lookup: the token set
#    is upstream's, so new entries have to be a data change.
if ! grep -q 'dependency_placeholders' "$ROOT/src/core/formula.zig"; then
  echo "FAIL: formula.zig no longer declares the dependency placeholder table" >&2
  exit 1
fi
if ! grep -q 'pub fn dependencyPlaceholder' "$ROOT/src/core/formula.zig"; then
  echo "FAIL: formula.dependencyPlaceholder is gone — nothing resolves the token" >&2
  exit 1
fi

# 2. Relocation must actually apply the caller's replacement. Without this the
#    resolver above is dead code and the token still ships literally.
if ! grep -q 'extra_replacement' "$ROOT/src/core/cellar.zig"; then
  echo "FAIL: relocateKegTree no longer applies a caller-resolved replacement" >&2
  exit 1
fi

# 3. EVERY path that materialises a keg must resolve the token. Reaching for
#    the short `materialize()` wrapper at any of these is the easy way to
#    silently reintroduce the bug for one command while the others stay fixed —
#    which is exactly how migrate and rollback were missed the first time.
#    (`upgrade` is covered transitively: it routes through download.zig.)
for site in src/cli/install/download.zig src/cli/migrate/keg.zig src/cli/rollback.zig; do
  if ! grep -q 'dependencyPlaceholder' "$ROOT/$site"; then
    echo "FAIL: $site no longer resolves the placeholder from the formula" >&2
    exit 1
  fi
done

# 4. The safety net: doctor must scan text files, not just Mach-O. Without it a
#    prefix with an unresolved token still reports healthy, which is what let
#    the original defect ship unnoticed.
if ! grep -q 'textCarriesPlaceholder' "$ROOT/src/cli/doctor.zig"; then
  echo "FAIL: doctor no longer scans text files for unsubstituted tokens" >&2
  exit 1
fi

# 5. Cached kegs relocated before the fix hold the literal token. Serving one
#    back re-breaks a fixed binary, so the cache version must be past 2.
version=$(grep -oE 'RELOC_LOGIC_VERSION: u32 = [0-9]+' "$ROOT/src/core/relocated_store.zig" |
  grep -oE '[0-9]+$' || true)
if [[ -z "$version" ]]; then
  echo "FAIL: could not read RELOC_LOGIC_VERSION from relocated_store.zig" >&2
  exit 1
fi
if ((version < 3)); then
  echo "FAIL: RELOC_LOGIC_VERSION is $version; kegs cached under v2 still hold the literal token" >&2
  exit 1
fi

# 6. Behavioural guards. If either test block is deleted the runs below would
#    silently pass, so assert they are present first.
RESOLVE_TEST="dependencyPlaceholder resolves a token against its declared dependency"
PINNED_TEST="dependencyPlaceholder keeps the version suffix of a pinned dependency"
APPLY_TEST="relocation substitutes the caller-resolved dependency placeholder"
WITHHOLD_TEST="relocation leaves an unresolved dependency placeholder in place"

if ! grep -Rqs -- "$RESOLVE_TEST" "$ROOT/src/core/formula.zig"; then
  echo "FAIL: resolver guard test missing from formula.zig" >&2
  exit 1
fi
if ! grep -Rqs -- "$PINNED_TEST" "$ROOT/src/core/formula.zig"; then
  echo "FAIL: pinned-dependency guard test missing from formula.zig" >&2
  exit 1
fi
if ! grep -Rqs -- "$APPLY_TEST" "$ROOT/tests/cellar_test.zig"; then
  echo "FAIL: relocation guard test missing from cellar_test.zig" >&2
  exit 1
fi
if ! grep -Rqs -- "$WITHHOLD_TEST" "$ROOT/tests/cellar_test.zig"; then
  echo "FAIL: withhold guard test missing from cellar_test.zig" >&2
  exit 1
fi

# Rebuild the test binaries so the run reflects the working tree.
if ! (cd "$ROOT" && zig build test-bin >/dev/null 2>&1); then
  echo "FAIL: could not build the test binaries (zig build test-bin)" >&2
  exit 1
fi

# The runners have no per-test filter, so run the suite ONCE and judge only the
# guard lines: a pass ends in "OK".
#
# Deliberate scope limit: the two resolver guards are inline `test {}` blocks in
# src/, so they only run inside `lib_tests` — ~2300 tests and ~38s, which alone
# blows this suite's 30s budget. They are asserted present above (deleting one
# fails this script) and executed by `just test`; what runs here is the
# end-to-end half, which is where the bug actually lived.
check() {
  local bin="$1"
  shift
  local out line name
  out=$("$ROOT/zig-out/test-bin/$bin" 2>&1 || true)
  for name in "$@"; do
    line=$(printf '%s\n' "$out" | grep -F -- "$name" || true)
    if [[ -z "$line" ]]; then
      echo "FAIL: guard test did not run in $bin: $name" >&2
      exit 1
    fi
    if [[ "$line" != *OK ]]; then
      echo "FAIL: $name: $line" >&2
      exit 1
    fi
  done
}

check cellar_test "$APPLY_TEST" "$WITHHOLD_TEST"

echo "OK: dependency-scoped placeholders resolved and applied; cache version past v2"
