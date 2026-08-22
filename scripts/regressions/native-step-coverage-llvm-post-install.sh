#!/usr/bin/env bash
# Regression: declarative post_install steps upstream ships but malt could not
# run.
#
# Homebrew is migrating formulas off Ruby `def post_install` onto a declarative
# `post_install_steps` array. Every step type outside `step_map` — and every
# guard condition outside `guard_condition_map` — routed to `logUnsupported`,
# so the declared work was silently never done and the install warned with a
# `--use-system-ruby` hint that cannot work for a formula with no Ruby body.
# llvm's `configure_clang_system` was the reported case: no
# `<prefix>/etc/clang/*.cfg`, so a malt-installed clang had no `-isysroot`.
#
# The `on` guard is the other half: it carries a `value` and no path at all, so
# it failed twice over — unknown condition, and nothing for the unconditional
# spec resolution to resolve.
#
# These steps cannot be driven offline through the `mt` binary without standing
# up a live tap, so behaviour is pinned by the colocated inline unit tests and
# this script asserts the load-bearing code plus its tests are present, then
# builds and runs `lib_tests`. A step type registered without a test would let a
# "register the tag, stub the body" change pass silently, so registration and
# test are judged together. ~45s, matching its post_install_steps siblings; no
# network.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

STEPS="$ROOT/src/core/post_install_steps.zig"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# 1. Every newly covered type must be in the single-source-of-truth table, and
#    must have at least one inline test naming it. `step_map` also drives
#    `supportedStepType`, `allStepsSupported` and the doctor probe row, so a
#    missing entry silently reinstates the partial-skip envelope.
for t in configure_clang_system configure_gcc_runtime warn move \
  set_permissions install_gzipped_executable change_dylib_id \
  terminate_process; do
  grep -qE "\"$t\", \." "$STEPS" || fail "$t missing from step_map — its formulas will partial-skip"
  grep -qE "^test \".*$t" "$STEPS" || fail "$t registered but untested — stub risk"
done

# 2. The `on` guard, and the restructure that lets it be evaluated at all: the
#    condition must be dispatched before any spec resolution, because an `on`
#    guard has no path to resolve.
grep -qE '\{ "on", \.on \}' "$STEPS" || fail "the on guard is no longer registered — its formulas stay blocked"
grep -qE '^test "the on guard' "$STEPS" || fail "the on guard is registered but untested"

# 3. Landmines that silently produce wrong output rather than failing.
#    The clang config filenames carry the Darwin kernel major, not the macOS
#    product major — reading the wrong sysctl writes six plausibly-named but
#    wrong files.
grep -q 'kern.osrelease' "$STEPS" || fail "no kern.osrelease read — darwin<N>.cfg would be named from the macOS major"
#    set_permissions recurses by default; the key opts OUT. Ignoring it inverts
#    the default and silently under-applies the mode.
grep -q 'non_recursive' "$STEPS" || fail "set_permissions ignores non_recursive — recursion default inverted"

# 4. Types deliberately left as loud skips must stay unregistered, so a later
#    drive-by cannot quietly stub them into a no-op that reports success.
for t in configure_glibc_runtime set_ownership configure_php \
  bootstrap_cpython bootstrap_pypy move_children move_contents; do
  if grep -qE "\"$t\", \." "$STEPS"; then
    fail "$t registered — it is a deliberate loud skip, not a native step"
  fi
done

# 5. Behavioural guards. If a test block is deleted the run below goes green
#    vacuously, so assert each is present first.
TESTS=(
  "configure_clang_system writes one isysroot config per arch and target"
  "configure_clang_system writes nothing when every config file already exists"
  "configure_clang_system refuses rather than naming files from an unknown version"
  "configure_gcc_runtime is a no-op on macOS rather than an unsupported step"
  "warn surfaces the formula's message instead of downgrading the install"
  "move relocates a tree and refuses an occupied target without overwrite"
  "move refuses a source that escapes the keg and prefix"
  "set_permissions recurses by default and honours non_recursive"
  "set_permissions applies symbolic modes and skips paths that do not exist"
  "set_permissions refuses a symbolic mode it cannot parse"
  "install_gzipped_executable unpacks, marks executable, and unlinks the source"
  "install_gzipped_executable leaves no temp file behind on a corrupt source"
  "change_dylib_id sets the install name on the real file behind a resolved source"
  "terminate_process treats an absent process as success"
  "the on guard admits a macOS step and skips a Linux one silently"
  "the on guard routes an unknown platform value loudly"
)

for t in "${TESTS[@]}"; do
  grep -Rqs -- "$t" "$STEPS" || fail "guard test missing from post_install_steps.zig: $t"
done

if ! zig build test-bin >/dev/null 2>&1; then
  fail "could not build the test binaries (zig build test-bin)"
fi

# One run of the suite, judged per guard line: a pass ends in "OK".
out=$("$ROOT/zig-out/test-bin/lib_tests" 2>&1 || true)
for t in "${TESTS[@]}"; do
  line=$(printf '%s\n' "$out" | grep -F -- "$t" || true)
  [[ -n "$line" ]] || fail "guard test did not run: $t"
  [[ "$line" == *OK ]] || fail "$t: $line"
done

echo "OK: the migrated step types and the platform guard run natively"
