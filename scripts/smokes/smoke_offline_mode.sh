#!/usr/bin/env bash
# Smoke test for `MALT_OFFLINE` / `--offline`.
#
# Six behaviours exercised end-to-end against a throwaway prefix:
#   1. `mt install <uncached>` under offline fails with the canonical
#      "offline" diagnostic instead of stalling on connect.
#   2. `mt info <uncached>` under offline succeeds (falls through to
#      "not installed") — read commands stay graceful on cache miss.
#   3. `mt info <pkg>` under offline serves a pre-seeded cache hit.
#   4. `mt update --check` under offline refuses with a non-zero exit
#      and the canonical message.
#   5. `mt doctor` skips the API-reachable probe under offline (no
#      "Cannot reach" warn row) and reports the active state.
#   6. `mt --offline …` mirrors `MALT_OFFLINE=1`.
#
# Usage: scripts/smokes/smoke_offline_mode.sh
# Requirements: built `malt` binary at $MALT_BIN or zig-out/bin/malt.
# No network access — every assertion runs against a hermetic prefix
# with the API cache either pre-seeded or deliberately empty.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

# MALT_PREFIX must be ≤ 13 bytes (Mach-O in-place patching budget),
# same constraint as smoke_install_local.sh.
PREFIX=$(mktemp -d /tmp/mt.XXX)
export MALT_PREFIX="$PREFIX"
mkdir -p "$PREFIX/cache/api" "$PREFIX/db"
trap 'rm -rf "$PREFIX"' EXIT

# Scrub any inherited offline knob so each branch below sets its own.
unset MALT_OFFLINE

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# ── 1. install <uncached> under offline → OfflineRequired ────────────
printf '▸ MALT_OFFLINE=1 mt install <uncached> exits non-zero\n'
out=$(MALT_OFFLINE=1 "$BIN" install ghost-pkg-no-such-thing 2>&1 || true)
echo "$out" | grep -qiE "offline|OfflineRequired" || fail "missing offline diagnostic on uncached install"
pass "uncached install fails with offline diagnostic"

# ── 2. info <uncached> under offline stays graceful ──────────────────
printf '▸ MALT_OFFLINE=1 mt info <uncached> degrades cleanly\n'
out=$(MALT_OFFLINE=1 "$BIN" info ghost-pkg-no-such-thing 2>&1 || true)
echo "$out" | grep -q "not installed" || fail "info should fall through to 'not installed' on cache miss"
pass "info falls through cleanly on cache miss"

# ── 3. info <pkg> under offline serves a pre-seeded cache hit ────────
printf '▸ MALT_OFFLINE=1 mt info <cached> reads from the cache\n'
cat >"$PREFIX/cache/api/formula_wget.json" <<'JSON'
{"name":"wget","full_name":"wget","desc":"Smoke fixture","homepage":"https://example.invalid","versions":{"stable":"1.0.0"},"dependencies":[]}
JSON
out=$(MALT_OFFLINE=1 "$BIN" info wget 2>&1 || true)
echo "$out" | grep -q "Smoke fixture" || fail "info should serve the pre-seeded cache body"
pass "info reads the warmed cache under offline"

# ── 4. update --check under offline refuses cleanly ──────────────────
printf '▸ MALT_OFFLINE=1 mt update --check refuses\n'
set +e
err=$(MALT_OFFLINE=1 "$BIN" update --check 2>&1)
rc=$?
set -e
[[ $rc -ne 0 ]] || fail "update --check under offline must exit non-zero"
echo "$err" | grep -q "offline mode" || fail "missing 'offline mode' refusal text"
pass "update --check refuses with the canonical message"

# ── 5. doctor under offline skips the API-reachable probe ────────────
printf '▸ MALT_OFFLINE=1 mt doctor shows Offline mode row + skipped API probe\n'
out=$(MALT_OFFLINE=1 "$BIN" doctor 2>&1 || true)
echo "$out" | grep -q "Offline mode — active" || fail "doctor should report Offline mode active"
echo "$out" | grep -q "API reachable — skipped — offline mode" || fail "doctor should skip the API probe"
pass "doctor reports offline state + skips API probe"

# ── 6. --offline mirrors MALT_OFFLINE=1 on the doctor surface ────────
printf '▸ mt --offline doctor reports active state\n'
out=$("$BIN" --offline doctor 2>&1 || true)
echo "$out" | grep -q "Offline mode — active" || fail "--offline must flip the doctor row"
pass "--offline mirrors MALT_OFFLINE=1"

printf '\n✔ offline-mode smoke test passed\n'
