#!/usr/bin/env bash
# Smoke test for issue #85 — `post_install` DSL fails with "unexpected token"
# on Ruby's `&:sym` block-pass shorthand.
#
# The reporter hit this on `mt install zig`, where `llvm@21` pulls in a
# `post_install` that calls `config_files.all?(&:exist?)`. The native DSL
# must parse the `&:sym` block-pass *and* not mark the (previously fatal)
# parse error as fatal — otherwise the `--use-system-ruby` fallback is
# silently disabled.
#
# Usage: scripts/regressions/post_install_block_pass_gh85.sh
# Requirements: built `malt` binary at $MALT_BIN or zig-out/bin/malt,
# network access to ghcr.io / formulae.brew.sh.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

# MALT_PREFIX must be ≤ 13 bytes (Mach-O in-place patching budget).
PREFIX="/tmp/mt_gh85"
export MALT_PREFIX="$PREFIX"
# Deterministic output so `grep` matches the real strings, not ANSI.
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

TARGET="${TARGET:-zig}" # zig pulls llvm@21, which is the formula that failed
LOG="$PREFIX/install.log"

printf '▸ malt install %s (logs → %s)\n' "$TARGET" "$LOG"
"$BIN" install "$TARGET" >"$LOG" 2>&1 || fail "install of $TARGET failed — see $LOG"
pass "installed $TARGET"

# ── 1. The native DSL parser must not emit the old fatal. ────────────
if grep -q "post_install DSL failed for llvm@21" "$LOG"; then
  printf '---- last 40 lines of install log ----\n' >&2
  tail -40 "$LOG" >&2
  fail "regression: llvm@21 post_install fatal surfaced again"
fi
pass "no post_install DSL fatal for llvm@21"

# ── 2. The specific `unexpected token` diagnostic must be gone. ──────
# The fix is the parser accepting `&:sym` block-pass. Any parse_error
# pinned to the `&` column would be the regression.
if grep -qE "llvm@21:[0-9]+:[0-9]+: \[parse_error\]" "$LOG"; then
  printf '---- parse_error lines ----\n' >&2
  grep -E "llvm@21:.*parse_error" "$LOG" >&2
  fail "regression: parse_error on llvm@21 post_install"
fi
pass "no parse_error on llvm@21 post_install body"

# ── 3. Install finished cleanly for the top-level target. ────────────
grep -qE "✓ ${TARGET} .* installed|${TARGET} [^ ]+ installed" "$LOG" ||
  fail "install line for $TARGET missing in log"
pass "$TARGET install completed"

# ── 4. Follow-up commands see the keg. ───────────────────────────────
INFO_OUT=$("$BIN" info "$TARGET" 2>&1)
echo "$INFO_OUT" | grep -q "Cellar/$TARGET/" ||
  fail "mt info $TARGET does not surface a Cellar path"
pass "mt info $TARGET reports the installed keg"

# ── 5. --use-system-ruby=llvm@21 drives post_install to completion. ──
#
# llvm@21's post_install calls a private `def write_config_files(...)`
# that the native DSL doesn't execute (no `def` support), so the base
# install prints "partially skipped" and does NOT create the
# `<prefix>/etc/clang/<arch>-apple-*.cfg` files the formula ships.
# Passing `--use-system-ruby=llvm@21` delegates that single formula's
# post_install to the Ruby subprocess, which writes those config files
# and unlocks `clang -cc1` defaults for keg-only LLVM users.
#
# This path needs system Ruby + a homebrew-core tap clone. Skip rather
# than fail when either is absent — the fix still holds for the native
# path we just verified above.
TAP=""
for cand in /opt/homebrew/Library/Taps/homebrew/homebrew-core \
  /usr/local/Homebrew/Library/Taps/homebrew/homebrew-core; do
  [[ -d "$cand" ]] && TAP="$cand" && break
done

if [[ -x /usr/bin/ruby ]] && [[ -n "$TAP" ]]; then
  # Fresh prefix so write_config_files actually has work to do; the
  # formula's `return if config_files.all?(&:exist?)` guard would
  # otherwise no-op after the first run.
  rm -rf "$PREFIX"
  mkdir -p "$PREFIX"

  LOG2="$PREFIX/install_sysruby.log"
  printf '▸ malt install --use-system-ruby=llvm@21 %s (logs → %s)\n' "$TARGET" "$LOG2"
  "$BIN" install --use-system-ruby=llvm@21 "$TARGET" >"$LOG2" 2>&1 ||
    fail "install with --use-system-ruby=llvm@21 failed — see $LOG2"
  pass "installed $TARGET with --use-system-ruby=llvm@21"

  # The "partially skipped" warning must be gone — the Ruby subprocess
  # ran post_install to completion.
  if grep -q "post_install partially skipped" "$LOG2"; then
    tail -20 "$LOG2" >&2
    fail "--use-system-ruby=llvm@21 did not take the Ruby fallback path"
  fi
  pass "no 'partially skipped' warning under --use-system-ruby=llvm@21"

  # write_config_files must have written `<arch>-apple-*.cfg` files.
  arch=$(uname -m)
  shopt -s nullglob
  cfg_files=("$PREFIX"/etc/clang/"${arch}"-apple-*.cfg)
  shopt -u nullglob
  [[ ${#cfg_files[@]} -gt 0 ]] ||
    fail "expected ${arch}-apple-*.cfg under $PREFIX/etc/clang after --use-system-ruby run"
  pass "clang config files written (${#cfg_files[@]} file(s) under etc/clang)"
else
  printf '  - skipping --use-system-ruby=llvm@21 check: tap or /usr/bin/ruby absent\n'
fi

printf '\n✔ gh85 post_install block-pass regression passed\n'
