#!/usr/bin/env bash
# Regression: formulas that template a config file from `post_install_steps`
# installed with the placeholder still in it.
#
# The `inreplace` step was not implemented, and neither were the `{{etc}}` and
# `{{user}}` tokens its steps depend on. Affected formulas shipped a config
# naming a user that does not exist — `change_this`, `@@HOMEBREW-UNBOUND-USER@@`
# — behind an install that reported success.
#
# The step edits live user configuration, so most of this guards the refusals
# rather than the happy path:
#   - an unresolved `{{user}}` must never be written into a config; with no
#     USER in the environment the step declines instead;
#   - there is no regex engine here. Only the `^<literal>.*` shape upstream
#     actually uses is honoured, behind a strict metacharacter allowlist;
#     anything richer reaches the fallback rather than being approximated,
#     because a near-miss silently corrupts the file;
#   - an unmet `if_exists` guard skips the step rather than inventing config;
#   - the write is atomic, so a crash mid-write cannot truncate the original.
#
# Nothing drives these steps offline without standing up a live tap, so the
# behaviour is pinned by colocated inline unit tests (`lib_tests`). This script
# asserts the load-bearing code and its tests are present, then builds and runs
# that binary. ~45s, matching its siblings; no network.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

STEPS="$ROOT/src/core/post_install_steps.zig"

# 1. The step and the two tokens its steps cannot work without.
if ! grep -qE '\.\{ "inreplace", \.inreplace \}' "$STEPS"; then
  echo "FAIL: the inreplace step is no longer registered in step_map" >&2
  exit 1
fi
for tok in etc user; do
  if ! grep -qE "\.\{ \"$tok\", \." "$STEPS"; then
    echo "FAIL: template {{$tok}} is no longer resolved" >&2
    exit 1
  fi
done

# 2. The refusals. Each of these turns a silent config corruption into a loud
#    partial skip, so losing one is worse than losing the feature.
if ! grep -q 'unresolved template' "$STEPS"; then
  echo "FAIL: inreplace no longer refuses an unresolved template — would write {{user}} into a config" >&2
  exit 1
fi
if ! grep -q 'fn anchoredLineLiteral' "$STEPS"; then
  echo "FAIL: the regexp allowlist is gone — richer patterns would be approximated" >&2
  exit 1
fi
if ! grep -q 'fn guardsSatisfied' "$STEPS"; then
  echo "FAIL: guards are no longer evaluated — inreplace would run on absent config" >&2
  exit 1
fi
if ! grep -q 'atomicReplaceFile' "$STEPS"; then
  echo "FAIL: inreplace no longer writes atomically" >&2
  exit 1
fi

# 3. Behavioural guards. A deleted test block would let the run below go green
#    vacuously, so assert each is present first.
LITERAL_TEST="execute substitutes a literal inreplace and resolves the invoking user"
GUARD_TEST="execute skips an inreplace whose if_exists guard is unmet"
REGEXP_TEST="execute rewrites a whole line for the anchored regexp form"
RICH_TEST="execute refuses a regexp outside the anchored-line subset"
CLASS_TEST="execute refuses an anchored regexp whose literal hides metacharacters"
NOUSER_TEST="execute refuses an inreplace whose user token cannot be resolved"

for t in "$LITERAL_TEST" "$GUARD_TEST" "$REGEXP_TEST" "$RICH_TEST" "$CLASS_TEST" "$NOUSER_TEST"; do
  if ! grep -Rqs -- "$t" "$STEPS"; then
    echo "FAIL: guard test missing from post_install_steps.zig: $t" >&2
    exit 1
  fi
done

if ! zig build test-bin >/dev/null 2>&1; then
  echo "FAIL: could not build the test binaries (zig build test-bin)" >&2
  exit 1
fi

out=$("$ROOT/zig-out/test-bin/lib_tests" 2>&1 || true)
for t in "$LITERAL_TEST" "$GUARD_TEST" "$REGEXP_TEST" "$RICH_TEST" "$CLASS_TEST" "$NOUSER_TEST"; do
  line=$(printf '%s\n' "$out" | grep -F -- "$t" || true)
  if [[ -z "$line" ]]; then
    echo "FAIL: guard test did not run: $t" >&2
    exit 1
  fi
  if [[ "$line" != *OK ]]; then
    echo "FAIL: $t: $line" >&2
    exit 1
  fi
done

echo "OK: inreplace templates configs, refuses unresolved tokens and unsupported regexps"
