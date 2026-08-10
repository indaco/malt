#!/usr/bin/env bash
# Regression: a keg-only formula that publishes its launcher from
# `post_install_steps` installed with nothing on PATH.
#
# Two gaps, one symptom. The steps name their source with a `{{bin}}`-style
# template rather than a `base`, and those tokens were absent from
# `template_map`, so `expandTemplates` left them literal. The resulting path did
# not start with `/`, `stepSymlink` read that as a relative source and refused
# it, and the companion `remove` step was not implemented at all. Net effect for
# rustup: no `<prefix>/bin/rustup`, no completions, a stale `rustup-init` left
# behind, and a "post_install partially skipped" warning as the only clue.
#
# The `remove` half is a GUARDED delete — it retires a symlink identified by a
# substring of its target. That guard is the security-relevant part: without it
# the step becomes an unconditional formula-driven delete, so this script
# asserts the guard is still required rather than merely that removal happens.
#
# Nothing drives these steps offline without standing up a live tap, so the
# behaviour is pinned by colocated inline unit tests (`lib_tests`). This script
# asserts the load-bearing code and its tests are present, then builds and runs
# that binary. ~45s, matching its sibling silent-skip-post-install-steps.sh; no
# network.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

STEPS="$ROOT/src/core/post_install_steps.zig"

# 1. The keg-relative templates. A formula's `{{bin}}` is inside the keg — not
#    `<prefix>/bin`, which is what the same word means as a `base`. Losing any
#    of these puts the token back on the "relative source" refusal path.
for tok in bin bash_completion zsh_completion fish_completion pwsh_completion; do
  if ! grep -qE "\.\{ \"$tok\", \." "$STEPS"; then
    echo "FAIL: template {{$tok}} is no longer resolved — its steps will be refused as relative" >&2
    exit 1
  fi
done

# 2. `remove` must be a native step, and `supportedStepType` must agree, or
#    migrated formulas get miscounted as needing the Ruby fallback.
if ! grep -qE '\.\{ "remove", \.remove \}' "$STEPS"; then
  echo "FAIL: the remove step is no longer registered in step_map" >&2
  exit 1
fi

# 3. The guard on remove. An unconditional delete driven by formula data is a
#    different and far worse thing than retiring one's own symlink.
if ! grep -q 'symlink_target_contains' "$STEPS"; then
  echo "FAIL: remove no longer consults symlink_target_contains — unguarded delete" >&2
  exit 1
fi
if ! grep -q 'readLinkAbsolute' "$STEPS"; then
  echo "FAIL: remove no longer type-checks the path as a symlink before deleting" >&2
  exit 1
fi

# 3b. The recursive form retires a subtree the formula owns. Its boundary is
#     `sharedPrefixDir`: without it, confinement alone would let formula data
#     delete `<prefix>/lib` and every other package's files inside it.
if ! grep -q 'fn sharedPrefixDir' "$STEPS"; then
  echo "FAIL: recursive remove no longer refuses shared top-level prefix directories" >&2
  exit 1
fi

# 4. Behavioural guards. If a test block is deleted the run below goes green
#    vacuously, so assert each is present first.
TEMPLATE_TEST="execute links keg-relative template paths into the prefix"
REMOVE_TEST="execute removes a symlink whose target matches the guard"
KEEP_FILE_TEST="execute leaves a regular file alone on remove"
KEEP_LINK_TEST="execute keeps a symlink whose target does not match the guard"
# The pre-existing base-form path shares stepSymlink; judged too so a fix to
# the template form cannot quietly break the form every other formula uses.
BASE_FORM_TEST="execute runs the filesystem tier natively and leaves the log clean"
# The recursive form and its refusal. A first install must stay silent, and a
# shared prefix directory must survive even when the guard finds it.
UNMET_GUARD_TEST="execute skips a remove whose if_exists guard is unmet"
SHARED_DIR_TEST="execute refuses a recursive remove that would take a whole prefix dir"

for t in "$TEMPLATE_TEST" "$REMOVE_TEST" "$KEEP_FILE_TEST" "$KEEP_LINK_TEST" "$BASE_FORM_TEST" \
  "$UNMET_GUARD_TEST" "$SHARED_DIR_TEST"; do
  if ! grep -Rqs -- "$t" "$STEPS"; then
    echo "FAIL: guard test missing from post_install_steps.zig: $t" >&2
    exit 1
  fi
done

if ! zig build test-bin >/dev/null 2>&1; then
  echo "FAIL: could not build the test binaries (zig build test-bin)" >&2
  exit 1
fi

# One run of the suite, judged per guard line: a pass ends in "OK".
out=$("$ROOT/zig-out/test-bin/lib_tests" 2>&1 || true)
for t in "$TEMPLATE_TEST" "$REMOVE_TEST" "$KEEP_FILE_TEST" "$KEEP_LINK_TEST" "$BASE_FORM_TEST" \
  "$UNMET_GUARD_TEST" "$SHARED_DIR_TEST"; do
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

echo "OK: keg-relative templates resolve, remove is guarded, base-form symlinks intact"
