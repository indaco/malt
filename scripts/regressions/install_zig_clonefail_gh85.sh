#!/usr/bin/env bash
# Regression: `mt install zig` against a prefix that already hosts a
# `Cellar/<name>/<version>` directory (left over from a SIGKILLed prior run,
# a partial warm-path failure, or a drop-in Homebrew prefix) used to
# bubble out of v0.10.0 as:
#
#   ✗ Failed to materialize lld@21: CloneFailed (APFS clonefile or copy failed)
#   ✗ Failed to materialize zstd:   CloneFailed (APFS clonefile or copy failed)
#   ⚠ Skipping zig: dependency lld@21 failed to install
#
# clonefile(2) refuses to write into an existing directory (EEXIST), so the
# cold-path materialise fails the moment any keg dir already exists at the
# target path. The fix wipes cellar_path before clonefile, mirroring the
# warm path's existing pre-wipe.
#
# Usage: scripts/regressions/install_zig_clonefail_gh85.sh
# Requirements: built `malt` binary at $MALT_BIN or zig-out/bin/malt,
# network access to ghcr.io / formulae.brew.sh.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

PREFIX=$(mktemp -d /tmp/mt.XXX)
export MALT_PREFIX="$PREFIX"
# Deterministic output so `grep` matches plain strings, not ANSI/emoji.
export NO_COLOR=1
export MALT_NO_EMOJI=1
mkdir -p "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

TARGET="${TARGET:-zig}" # zig drags in lld@21 + zstd, the original bug pair

# ── 1. Plant stale Cellar dirs at every DEP target. ────────────────────
# These mimic leftovers from a SIGKILLed prior `mt install zig` or a
# drop-in Homebrew prefix that already hosts the same kegs. We pin the
# stale dirs at the same {name}/{version} malt is about to write — if
# the `name` isn't on the dep list (e.g. the formula name moved), the
# fixture is harmless and the regression simply doesn't fire.
#
# We deliberately leave Cellar/$TARGET/ absent so the top-level fastpath
# (which only checks `Cellar/<top>` existence) does not short-circuit.
STALE_DEPS=("lld@21:21.1.8_1" "llvm@21:21.1.8" "zstd:1.5.7_1" "lz4:1.10.0" "xz:5.8.3")
for entry in "${STALE_DEPS[@]}"; do
  dep="${entry%%:*}"
  ver="${entry##*:}"
  mkdir -p "$PREFIX/Cellar/$dep/$ver"
  printf 'stale\n' >"$PREFIX/Cellar/$dep/$ver/STALE_FILE"
done
pass "planted stale Cellar/<dep>/<version> fixtures"

# ── 2. Install — must complete cleanly and emit the success line. ──────
LOG="$PREFIX/install.log"
printf '▸ malt --debug install %s (logs → %s)\n' "$TARGET" "$LOG"
"$BIN" --debug install "$TARGET" >"$LOG" 2>&1 || {
  printf '==== last 40 lines of install log ====\n' >&2
  tail -40 "$LOG" >&2
  fail "install of $TARGET failed against a prefix with stale Cellar dirs"
}
pass "installed $TARGET"

# ── 3. The exact regression markers must NOT appear. ───────────────────
if grep -qE "Failed to materialize.*CloneFailed" "$LOG"; then
  printf '==== materialize failures ====\n' >&2
  grep -E "Failed to materialize" "$LOG" >&2
  fail "regression: materialize failed with CloneFailed (gh#85)"
fi
pass "no CloneFailed materialise failures"

if grep -qE "Skipping .*: dependency .* failed to install" "$LOG"; then
  printf '==== dep skips ====\n' >&2
  grep -E "Skipping " "$LOG" >&2
  fail "regression: a dep was skipped because of a CloneFailed parent"
fi
pass "no dep skipped due to a failed parent"

# ── 4. Stale fixtures got replaced by real keg content. ───────────────
# clonefile would have refused to write into the planted dirs without
# the cold-path pre-wipe; STALE_FILE absence proves the wipe happened
# AND the real bottle landed.
for entry in "${STALE_DEPS[@]}"; do
  dep="${entry%%:*}"
  ver="${entry##*:}"
  if [[ -f "$PREFIX/Cellar/$dep/$ver/STALE_FILE" ]]; then
    fail "STALE_FILE survived under Cellar/$dep/$ver — pre-wipe did not run"
  fi
  [[ -f "$PREFIX/Cellar/$dep/$ver/INSTALL_RECEIPT.json" ]] ||
    fail "no INSTALL_RECEIPT.json under Cellar/$dep/$ver — bottle did not materialize"
done
pass "stale fixtures replaced; INSTALL_RECEIPT.json present for every dep"

# ── 5. Re-installing on top of the just-installed keg also succeeds. ──
# The same code path runs without warm cache for fresh installs and with
# warm cache for the second run; pin both.
LOG2="$PREFIX/install_warm.log"
printf '▸ malt install %s (warm; logs → %s)\n' "$TARGET" "$LOG2"
"$BIN" install "$TARGET" >"$LOG2" 2>&1 || {
  printf '==== last 40 lines of warm install log ====\n' >&2
  tail -40 "$LOG2" >&2
  fail "warm reinstall of $TARGET failed"
}
pass "warm reinstall of $TARGET completed"

printf '\n✔ gh85 install-zig clonefail regression passed\n'
