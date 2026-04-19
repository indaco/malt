#!/usr/bin/env bash
# Smoke test for DSL `def ... end` + `return` support.
#
# Before this change the native DSL had no `def` and treated `return` as
# an unknown identifier, so any formula whose `post_install` dispatched to
# a private helper (`macos_post_install`, `openssldir`, `write_config_files`,
# …) silently fell back to `--use-system-ruby`. The extractor now prepends
# sibling defs so helpers register at interpret time, and the interpreter
# runs `return` through a control-flow signal instead of losing it.
#
# This script installs a small set of commonly used formulas that exercise
# that path and asserts:
#   1. no `post_install DSL failed ... (fatal)` line (parser regressions)
#   2. no `[parse_error]` lines (AST/lex regressions)
#   3. install exits 0 for each formula
#
# `partially skipped` warnings are allowed — def support alone doesn't teach
# the DSL every builtin a formula might call (`Utils.safe_popen_read`,
# `Tempfile.new`, …). The point is that adding def support doesn't NEW fail
# anything and extends the native path further.
#
# Usage: scripts/regressions/dsl_def_support.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt, network.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

PREFIX="/tmp/mt_def"
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
rm -rf "$PREFIX"
mkdir -p "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# Formulas whose `post_install` touches a `def` — override with TARGETS=...
TARGETS=("${TARGETS[@]:-ca-certificates}")

for target in "${TARGETS[@]}"; do
  log="$PREFIX/${target//@/_}.log"
  printf '▸ malt install %s (logs → %s)\n' "$target" "$log"
  "$BIN" install "$target" >"$log" 2>&1 ||
    fail "install of $target failed — see $log"

  if grep -qE "post_install DSL failed for .* \(fatal\)" "$log"; then
    tail -20 "$log" >&2
    fail "$target: fatal DSL failure resurfaced"
  fi
  if grep -qE ":[0-9]+:[0-9]+: \[parse_error\]" "$log"; then
    grep -E "\[parse_error\]" "$log" >&2
    fail "$target: parse_error resurfaced"
  fi
  pass "$target installed cleanly; no fatal / no parse_error"
done

printf '\n✔ DSL def-support regression passed\n'
