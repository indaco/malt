#!/usr/bin/env bash
# Regression: a tap keg served from formula/ or the root layout must stay on
# the formula side. Read as a cask bool, it re-resolves through Casks/ and is
# replaced by a same-named cask. No public tap has that dual layout, so this
# is a static guard; the inline tests pin the behaviour.
#
# Usage: scripts/regressions/tap-formula-keg-keeps-formula-side-tap-formula-keg-outside-formula-dir-upgrades-to-same-named-cask.sh

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# grep, not rg: the CI runner has no ripgrep.

# 1. The subtree readers must not collapse the column to a cask bool.
for f in src/cli/upgrade.zig src/cli/outdated/rows.zig src/cli/vulns.zig; do
  if grep -Eq "tap_rb_subtree *= *'cask'" "$f"; then
    fail "$f reads tap_rb_subtree as a cask bool; formula_lower/formula_root kegs re-resolve through Casks/"
  fi
done

# 2. The formula-side order is exact: the formula layouts first, Casks/ last.
body=$(awk '/pub fn kegRbSubtrees/,/^}/' src/core/tap.zig)
[[ -n "$body" ]] || fail "kegRbSubtrees not found"
grep -Eq '^[[:space:]]*\.formula => &\.\{ \.formula, \.formula_lower, \.formula_root, \.cask \},' <<<"$body" ||
  fail "the formula-side order is not formula, formula_lower, formula_root, cask"

# 3. The upgrade switch arm for formula-side kegs must call the cask-last install.
grep -Eq '^[[:space:]]*\.formula => install_local_mod\.installTapFormulaCaskLast\(' src/cli/upgrade.zig ||
  fail "the upgrade .formula arm does not call installTapFormulaCaskLast"

# 4. Reinstall must read the side from the shared parser, so root kegs stay pinned.
side=$(awk '/fn sideOf/,/^}/' src/cli/reinstall.zig)
[[ -n "$side" ]] || fail "sideOf not found"
grep -q 'KegRbSide\.fromSubtree' <<<"$side" || fail "sideOf does not use the shared side parser"

echo "OK: formula-side tap kegs read Casks/ last"
