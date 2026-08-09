#!/usr/bin/env bash
# Regression: relocation substituted only four fixed tokens plus one
# caller-resolved one, and the caller could resolve exactly one token. Bottles
# that ship perl scripts carry `#!@@HOMEBREW_PERL@@`, so the literal token
# reached disk as the interpreter path and every such script died with
# "bad interpreter" behind an install that reported success.
#
# Four things have to stay fixed, and each fails differently:
#   1. a resolver must exist for the token — it is not derivable from the
#      prefix alone, since a brewed perl and the system perl are both valid;
#   2. relocation must actually wire that token into the text replacement set,
#      or the resolver is dead code;
#   3. RELOC_LOGIC_VERSION must have moved past 5, or `store-relocated/v5/`
#      keeps serving kegs snapshotted with the literal token;
#   4. doctor must stop prescribing a reinstall, which reproduces the state
#      byte for byte when the substitution table is what is behind.
#
# Behavioural guards live in `tests/cellar_test.zig`; this script asserts the
# wiring statically, then runs that test binary and judges those guards' lines.
# Exits 0 when the bug is absent, non-zero (naming the failing assertion) when
# present. No network; no temp state; well under 30s once the binary is built.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

# 1. The resolver, and the token it answers for. Unlike the dependency-scoped
#    table it never withholds a value: an unresolved shebang is an unrunnable
#    script, not a visible token.
if ! grep -q 'pub fn perlPlaceholder' "$ROOT/src/core/formula.zig"; then
  echo "FAIL: formula.perlPlaceholder is gone — nothing resolves the perl token" >&2
  exit 1
fi
if ! grep -q '@@HOMEBREW_PERL@@' "$ROOT/src/core/formula.zig"; then
  echo "FAIL: the perl token is gone from the resolver" >&2
  exit 1
fi

# 2. Relocation must feed the resolver into its replacement set. Without this
#    the resolver is dead code and the shebang ships literally.
if ! grep -q 'perlReplacement' "$ROOT/src/core/cellar.zig"; then
  echo "FAIL: relocation no longer substitutes the perl token" >&2
  exit 1
fi

# 3. Kegs relocated before the fix hold the literal token; serving one back
#    re-breaks a fixed install, so the cache version must be past 5.
version=$(grep -oE 'RELOC_LOGIC_VERSION: u32 = [0-9]+' "$ROOT/src/core/relocated_store.zig" |
  grep -oE '[0-9]+$' || true)
if [[ -z "$version" ]]; then
  echo "FAIL: could not read RELOC_LOGIC_VERSION from relocated_store.zig" >&2
  exit 1
fi
if ((version < 6)); then
  echo "FAIL: RELOC_LOGIC_VERSION is $version; kegs cached under v5 still hold the literal token" >&2
  exit 1
fi

# 4. The remediation must not send the user back through the install that
#    produced the broken keg.
if grep -q 'Reinstall the affected packages' "$ROOT/src/cli/doctor.zig"; then
  echo "FAIL: doctor still prescribes a reinstall, which reproduces the state" >&2
  exit 1
fi

# 5. Behavioural guards. If either test block is deleted the run below would
#    silently pass, so assert they are present first.
BREWED_TEST="relocation substitutes the perl shebang placeholder"
SYSTEM_TEST="relocation falls back to the system perl when no perl is brewed"

for name in "$BREWED_TEST" "$SYSTEM_TEST"; do
  if ! grep -Rqs -- "$name" "$ROOT/tests/cellar_test.zig"; then
    echo "FAIL: guard test missing from cellar_test.zig: $name" >&2
    exit 1
  fi
done

# Rebuild the test binaries so the run reflects the working tree.
if ! (cd "$ROOT" && zig build test-bin >/dev/null 2>&1); then
  echo "FAIL: could not build the test binaries (zig build test-bin)" >&2
  exit 1
fi

# The runners have no per-test filter, so run the suite ONCE and judge only the
# guard lines: a pass ends in "OK".
#
# Deliberate scope limit, matching the sibling placeholder script: the resolver
# guards are inline `test {}` blocks in src/, so they only run inside
# `lib_tests` (~38s, which alone blows this suite's budget). They are asserted
# present above and executed by `just test`.
out=$("$ROOT/zig-out/test-bin/cellar_test" 2>&1 || true)
for name in "$BREWED_TEST" "$SYSTEM_TEST"; do
  line=$(printf '%s\n' "$out" | grep -F -- "$name" || true)
  if [[ -z "$line" ]]; then
    echo "FAIL: guard test did not run in cellar_test: $name" >&2
    exit 1
  fi
  if [[ "$line" != *OK ]]; then
    echo "FAIL: $name: $line" >&2
    exit 1
  fi
done

echo "OK: perl shebang placeholder substituted; cache version past v5"
