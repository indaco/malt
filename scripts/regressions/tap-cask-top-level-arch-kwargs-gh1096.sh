#!/usr/bin/env bash
# Regression: a tap cask that declares `arch arm:, intel:` and
# `sha256 arm:, intel:` at the top level of `cask "x" do` (the canonical
# Homebrew shape) must resolve its sha256 and arch token.
#
# The bug: parseRubyFormula consumed those keyword directives only inside an
# `on_macos` block, so a top-level multi-arch cask resolved no sha256 and the
# tap install was refused as an unsupported Ruby DSL shape.
#
# The parser runs offline only through the inline suite (`lib_tests`), so this
# script builds and runs that binary. No network. It judges only the tests
# named below, so an unrelated inline failure is not reported as this bug.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

TESTS=(
  "top-level cask arch/sha256 kwargs resolve for the host arch"
  "top-level cask arch/sha256 kwargs on a single line"
  "on_linux kwargs do not leak ahead of on_macos"
  "kwargs scoped to macOS release blocks are refused"
)

BIN="$ROOT/zig-out/test-bin/lib_tests"
# Always rebuild so the binary reflects current source. Unbounded: CI runs
# this after the suite, off a warm cache; a cold build outlasts any cap.
if ! env -u MALT_PREFIX -u MALT_CACHE zig build test-bin >/dev/null 2>&1; then
  echo "FAIL: could not build the unit test binary (zig build test-bin)" >&2
  exit 1
fi

# `timeout` is coreutils; the CI job that runs this does not install it and
# its own time cap bounds the run there.
RUN=("$BIN")
if TIMEOUT=$(command -v timeout || command -v gtimeout); then
  RUN=("$TIMEOUT" "${MALT_REGRESSION_TIMEOUT:-600}" "$BIN")
fi
OUT=$(env -u MALT_PREFIX -u MALT_CACHE "${RUN[@]}" 2>&1) || true
for t in "${TESTS[@]}"; do
  # A missing name means the guard was dropped; the suite would pass vacuously.
  # Here-string, not a pipe: grep -q exiting early would SIGPIPE printf
  # and pipefail would read the match as a failure.
  if ! grep -Fq -- "$t...OK" <<<"$OUT"; then
    echo "FAIL: '$t' did not pass - top-level cask arch/sha256 kwargs mis-resolved" >&2
    grep -F -- "$t" <<<"$OUT" >&2 || {
      echo "  (test not found in lib_tests output; its tail follows)" >&2
      tail -5 <<<"$OUT" >&2
    }
    exit 1
  fi
done

echo "PASS: top-level multi-arch cask parses"
