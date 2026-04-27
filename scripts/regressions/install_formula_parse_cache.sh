#!/usr/bin/env bash
# Regression test for the per-invocation parsed-formula cache.
#
# A multi-dep formula install must succeed end-to-end after the cache
# refactor: BFS dep resolution, parallel fetch, post-process, link phase
# (linkAndRecord), and findFailedDep all share one cache. A real install
# is the only path that walks every consumer at once, so a single
# warm-path round catches any regression in cache wiring or lifetime.
#
# Usage: scripts/regressions/install_formula_parse_cache.sh
# Requirements: built `malt` binary at $MALT_BIN or zig-out/bin/malt,
# network access to ghcr.io / formulae.brew.sh.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

# MALT_PREFIX must be <= 13 bytes (Mach-O in-place patching budget).
PREFIX="/tmp/mt_pcc"
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

# wget has 6 deps (openssl@3, libidn2, gettext, libunistring, c-ares,
# ca-certificates) — enough to drive the dep-resolve BFS, the parallel
# fetch, post-process, and the link-phase findFailedDep walk.
TARGET="${TARGET:-wget}"
LOG="$PREFIX/install.log"

printf '▸ malt install %s (logs → %s)\n' "$TARGET" "$LOG"
"$BIN" install "$TARGET" >"$LOG" 2>&1 || {
  printf '---- last 40 lines of install log ----\n' >&2
  tail -40 "$LOG" >&2
  fail "install of $TARGET failed — see $LOG"
}
pass "installed $TARGET"

# ── 1. The keg + every dep must be present in the Cellar. ────────────
[[ -d "$PREFIX/Cellar/$TARGET" ]] || fail "$PREFIX/Cellar/$TARGET missing"
pass "Cellar/$TARGET present"

dep_count=$(find "$PREFIX/Cellar" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
[[ "$dep_count" -ge 2 ]] || fail "expected at least 2 kegs in Cellar (target + deps), got $dep_count"
pass "Cellar holds $dep_count kegs (target + deps)"

# ── 2. The installed binary must actually resolve at runtime. ────────
"$PREFIX/bin/$TARGET" --version >/dev/null 2>&1 ||
  fail "$PREFIX/bin/$TARGET --version failed (cache may have broken linkAndRecord)"
pass "$TARGET --version runs cleanly"

# ── 3. Warm reinstall (--force) must replay the entire pipeline ──────
# through the same cache path without leaving stale state.
"$BIN" install --force "$TARGET" >>"$LOG" 2>&1 || {
  printf '---- last 40 lines of install log ----\n' >&2
  tail -40 "$LOG" >&2
  fail "warm reinstall of $TARGET failed — see $LOG"
}
pass "warm reinstall of $TARGET succeeded"

"$PREFIX/bin/$TARGET" --version >/dev/null 2>&1 ||
  fail "$TARGET --version regressed after warm reinstall"
pass "$TARGET still runs after warm reinstall"

# ── 4. Idempotent re-install (already-installed branch) ──────────────
# must short-circuit without touching the cache or the Cellar.
"$BIN" install "$TARGET" >>"$LOG" 2>&1 || fail "idempotent reinstall of $TARGET failed"
grep -q "is already installed" "$LOG" ||
  fail "idempotent install missed the 'already installed' short-circuit"
pass "idempotent reinstall short-circuits"

printf '\n✔ install-formula-parse-cache regression test passed\n'
