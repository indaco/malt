#!/usr/bin/env bash
# Regression: a formula migrated to the declarative `post_install_steps`
# framework must not be silently skipped at install/migrate time.
#
# The bug: migrated formulas report `post_install_defined: false` and carry
# their hook in a new `post_install_steps` JSON array. parseFormula read only
# the boolean, so the install gate never attempted post-install at all — no
# steps, no warning, no JSON event. The tap/migrate arm was blind the same
# way: body extraction only matches `def post_install`, so a steps-only .rb
# returned null and the hook was dropped without a word. User-visible result:
# broken kegs (gdk-pixbuf loaders.cache never regenerated, gsettings schemas
# never compiled) with nothing in the output to explain why.
#
# The fix parses the steps array (non-empty only — the key is present but
# empty on formulas still using `def post_install`), routes steps-migrated
# formulas into the existing loud-skip machinery on the bottle arm, detects
# `post_install_steps do` blocks on the tap arm so migrate warns instead of
# returning silently, and stops doctor undercounting migrated formulas.
#
# No CLI surface drives parseFormula or the tap extraction offline without
# standing up a live tap, so the behaviour is pinned by colocated inline unit
# tests (`lib_tests`). This script asserts the load-bearing code and its tests
# are present, then builds and runs that binary: about a minute, no network.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

# If any layer of the fix is dropped, lib_tests could go green vacuously.
# Fail loudly instead: parse layer, both gates, and tap-arm detection must
# all be present in the source.
if ! grep -Fqs -- "parseFormula flags a formula migrated to post_install_steps" src/core/formula.zig; then
  echo "FAIL: formula.zig no longer tests the post_install_steps parse — migrated formulas silently skip post-install" >&2
  exit 1
fi
if ! grep -Fqs -- "has_post_install_steps" src/core/formula.zig; then
  echo "FAIL: parseFormula dropped the post_install_steps field — migrated formulas parse as 'no post_install'" >&2
  exit 1
fi
if ! grep -Fqs -- "job.wants_post_install" src/cli/install.zig; then
  echo "FAIL: the install gate no longer honours steps-migrated formulas" >&2
  exit 1
fi
if ! grep -Fqs -- "hasPostInstallHook" src/cli/migrate/keg.zig; then
  echo "FAIL: the migrate bottle arm gate is blind to steps-migrated formulas again" >&2
  exit 1
fi
if ! grep -Fqs -- "rbHasPostInstallSteps" src/cli/migrate/keg.zig; then
  echo "FAIL: the migrate tap arm silently drops steps-only formulas again" >&2
  exit 1
fi
if ! grep -Fqs -- "hasPostInstallStepsBlock detects a declarative steps block" src/core/ruby/source.zig; then
  echo "FAIL: the steps-block detection test is missing from source.zig" >&2
  exit 1
fi
if ! grep -Fqs -- "driveSteps" src/cli/install/post_install.zig; then
  echo "FAIL: the native steps dispatch is gone from the post-install driver" >&2
  exit 1
fi
if [ ! -f src/core/post_install_steps.zig ]; then
  echo "FAIL: the declarative steps executor module is missing" >&2
  exit 1
fi

BIN="$ROOT/zig-out/test-bin/lib_tests"
# Always rebuild so the binary reflects current source; Zig's cache makes a
# no-op rebuild cheap, so this stays well under the time budget.
if ! zig build test-bin >/dev/null 2>&1; then
  echo "FAIL: could not build the unit test binary (zig build test-bin)" >&2
  exit 1
fi

OUT=$("$BIN" 2>&1) && STATUS=0 || STATUS=$?
if [[ "$STATUS" -ne 0 ]]; then
  echo "FAIL: steps-migrated formulas are silently skipped at post-install" >&2
  printf '%s\n' "$OUT" | grep -iE "failed|leaked|panic" >&2 || true
  exit 1
fi

echo "PASS: steps-migrated formulas are flagged at parse time and routed loudly"
