#!/usr/bin/env bash
# DSL corpus-coverage smoke — battle-tests the post_install pipeline
# across a diverse slice of homebrew-core formulas, not just one.
#
# For each target it asserts the invariants introduced by PRs #86-#90+:
#   1. install exits 0 (top-level install didn't fail)
#   2. no `post_install DSL failed for <formula> (fatal)` line
#   3. no `[parse_error]` diagnostic (regression guard on lexer/parser)
#   4. per-formula `[unknown_method] / [unsupported_node]` count stays
#      at or below a pinned baseline — any NEW unknown is a regression,
#      any drop is an improvement that should lower the baseline
#
# Override the target list with `TARGETS="a b c"` and the baselines
# with `BASELINE_<target>=<n>` (dots in formula names become underscores,
# `@` becomes `_AT_`). Defaults cover a mix of post_install shapes:
#
#   - ca-certificates: dispatcher + sibling defs + keychain shell-outs
#   - gnupg: tiny post_install, no helpers
#   - openssl@3: sibling def (`openssldir`) + path chain
#   - libidn2: minimal, used to keep the run fast
#
# Usage: scripts/regressions/dsl_corpus_coverage.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt, network.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

# MALT_PREFIX must be ≤ 13 bytes (Mach-O in-place patching budget) so
# keep the path tight. `/tmp/mt_cs` + per-target log dir fits.
PREFIX_ROOT="/tmp/mt_cs"
# Preserve logs on failure so the user can see WHICH diagnostics fired.
# Always-clean trap only when everything passes.
LOG_DIR="$PREFIX_ROOT/logs"
CLEAN_ON_EXIT=1
export NO_COLOR=1
export MALT_NO_EMOJI=1
rm -rf "$PREFIX_ROOT"
mkdir -p "$LOG_DIR"
trap '[[ "$CLEAN_ON_EXIT" -eq 1 ]] && rm -rf "$PREFIX_ROOT" || printf "\n  ℹ logs preserved at %s\n" "$LOG_DIR" >&2' EXIT

pass() { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
fail() {
  CLEAN_ON_EXIT=0
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# Convert a formula name (which may contain `.`, `@`, `-`, `+`) into a
# shell-safe suffix used both as filename and as baseline env var key.
# Bash variable names allow only `[A-Za-z_][A-Za-z0-9_]*`, so any of
# `@.-+` would break indirect expansion — normalise them all.
slug() {
  printf '%s' "$1" | sed 's/@/_AT_/g; s/\./_/g; s/-/_/g; s/+/_P_/g'
}

# Default target list — picked to exercise the full range of shapes the
# DSL must tolerate. Override with TARGETS="a b c" to customise.
#
#   * ca-certificates: dispatcher + sibling defs + keychain shell-outs
#   * gnupg:           trivial post_install (var/run.mkpath + killall)
#   * openssl@3:       sibling def (openssldir) + install_symlink chain
#   * libidn2:         minimal post_install — quick baseline
#   * tree:            NO post_install — confirms DSL path is inert
#   * jq:              NO post_install — same
#   * ripgrep:         NO post_install — bottle with lots of completions
TARGETS="${TARGETS:-ca-certificates gnupg openssl@3 libidn2 tree jq ripgrep}"

# Per-target expected maximum `[unknown_method]+[unsupported_node]` count.
# Baselines leave a small cushion above the observed count so a single
# Homebrew formula update doesn't trip CI, but stay tight enough that a
# real regression (new unsupported construct, Enumerable method drop)
# is caught. Formulas without post_install must stay at 0.
BASELINE_ca_certificates="${BASELINE_ca_certificates:-5}"
BASELINE_gnupg="${BASELINE_gnupg:-4}"
BASELINE_openssl_AT_3="${BASELINE_openssl_AT_3:-5}"
BASELINE_libidn2="${BASELINE_libidn2:-2}"
BASELINE_tree="${BASELINE_tree:-0}"
BASELINE_jq="${BASELINE_jq:-0}"
BASELINE_ripgrep="${BASELINE_ripgrep:-0}"

total=0
improved=0
# Shared bottle cache so sequential installs don't re-download. Kept
# short so it fits within the Mach-O prefix budget when combined with
# per-target install prefixes.
export MALT_CACHE="$PREFIX_ROOT/cache"
mkdir -p "$MALT_CACHE"

for target in $TARGETS; do
  total=$((total + 1))
  s=$(slug "$target")
  log="$LOG_DIR/${s}.log"

  # Each install gets an isolated prefix (shorter than 13 bytes) so
  # previous installs don't interact with subsequent ones and so we
  # can baseline per-formula without cross-contamination. Use a small
  # numeric suffix keyed by count so paths stay ≤ 13 bytes.
  target_prefix="/tmp/mt_cs${total}"
  rm -rf "$target_prefix"
  mkdir -p "$target_prefix"
  export MALT_PREFIX="$target_prefix"

  printf '▸ %s\n' "$target"
  set +e
  "$BIN" install --debug "$target" >"$log" 2>&1
  rc=$?
  set -e
  [[ "$rc" -eq 0 ]] || fail "install of $target exited with code $rc — see $log"

  if grep -qE "post_install DSL failed for .* \(fatal\)" "$log"; then
    tail -30 "$log" >&2
    fail "$target: fatal DSL failure"
  fi
  if grep -qE ":[0-9]+:[0-9]+: \[parse_error\]" "$log"; then
    grep -E "\[parse_error\]" "$log" >&2
    fail "$target: parse_error (lexer/parser regression)"
  fi

  # Count non-fatal diagnostics. `grep -c` returns 1 with exit 1 when
  # the pattern matches 0 lines; we want "0" without tripping set -e.
  unknowns=$(grep -cE "\[unknown_method\]|\[unsupported_node\]" "$log" || true)

  baseline_var="BASELINE_${s}"
  baseline="${!baseline_var:-}"
  if [[ -z "$baseline" ]]; then
    warn "$target: no BASELINE_$s set — observed $unknowns (treating as baseline)"
  elif [[ "$unknowns" -gt "$baseline" ]]; then
    printf '    diagnostics this run:\n' >&2
    grep -E "\[unknown_method\]|\[unsupported_node\]" "$log" | head -20 >&2
    fail "$target: $unknowns unknowns exceeds baseline $baseline (regression)"
  elif [[ "$unknowns" -lt "$baseline" ]]; then
    pass "$target: $unknowns unknowns (baseline $baseline — improved!)"
    improved=$((improved + 1))
    continue
  fi

  pass "$target: $unknowns unknowns ≤ baseline $baseline"
  # Per-target prefix is reclaimed between installs; logs stay in
  # $LOG_DIR under the shared $PREFIX_ROOT.
  rm -rf "$target_prefix"
done

printf '\n✔ DSL corpus coverage: %d target(s) passed' "$total"
if [[ "$improved" -gt 0 ]]; then
  printf '; %d improved — consider tightening baseline\n' "$improved"
else
  printf '\n'
fi
