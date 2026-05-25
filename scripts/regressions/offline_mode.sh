#!/usr/bin/env bash
# Lock the `MALT_OFFLINE` / `--offline` contract end-to-end at the binary edge.
#
# Four behaviours pinned:
#   1. Doctor "Offline mode" row reads "off" by default.
#   2. Doctor "Offline mode" row reads "active" under MALT_OFFLINE=1.
#   3. Doctor "Offline mode" row reads "active" under --offline.
#   4. `mt update --check` refuses cleanly under offline (non-zero exit
#      + canonical message), before any HTTP attempt.
#
# Usage: scripts/regressions/offline_mode.sh
# Requirements: a built malt binary at zig-out/bin/malt (just build).
# No network access required — only the env probe + doctor render are asserted.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

MALT_BIN=${MALT_BIN:-$ROOT/zig-out/bin/malt}
if [[ ! -x "$MALT_BIN" ]]; then
  printf 'FAIL: malt binary not found at %s — run "zig build" first.\n' "$MALT_BIN" >&2
  exit 1
fi

# Use a throwaway prefix so doctor never touches /opt/malt.
PREFIX=$(mktemp -d -t malt_offline_reg.XXXXXX)
trap 'rm -rf "$PREFIX"' EXIT

# Strip any inherited offline env so the host's shell can't poison
# the deterministic assertions below.
unset MALT_OFFLINE

run_doctor() {
  MALT_PREFIX="$PREFIX" "$MALT_BIN" doctor 2>&1 || true
}

# (1) Defaults — Offline mode row reports off.
out=$(run_doctor)
if ! grep -q "Offline mode — off" <<<"$out"; then
  printf 'FAIL: default offline row missing or wrong text.\n%s\n' "$out" >&2
  exit 1
fi

# (2) MALT_OFFLINE=1 → row reads "active".
out=$(MALT_PREFIX="$PREFIX" MALT_OFFLINE=1 "$MALT_BIN" doctor 2>&1 || true)
if ! grep -q "Offline mode — active" <<<"$out"; then
  printf 'FAIL: MALT_OFFLINE=1 did not flip the doctor row.\n%s\n' "$out" >&2
  exit 1
fi

# (3) --offline → row reads "active" too (mirrors the env).
out=$(MALT_PREFIX="$PREFIX" "$MALT_BIN" --offline doctor 2>&1 || true)
if ! grep -q "Offline mode — active" <<<"$out"; then
  printf 'FAIL: --offline did not flip the doctor row.\n%s\n' "$out" >&2
  exit 1
fi

# (4) `mt update --check` refuses cleanly under offline (non-zero exit
#     + canonical message). The refusal must happen before any HTTP
#     attempt — otherwise a user on a plane would stall on connect.
set +e
err=$(MALT_PREFIX="$PREFIX" MALT_OFFLINE=1 "$MALT_BIN" update --check 2>&1)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  # shellcheck disable=SC2016  # literal backticks in user-facing log line
  printf 'FAIL: `mt update --check` under offline should exit non-zero (got rc=0).\n' >&2
  exit 1
fi
if ! grep -q "offline mode: \`mt update --check\` requires network access" <<<"$err"; then
  printf 'FAIL: offline-refusal message missing.\n%s\n' "$err" >&2
  exit 1
fi

echo "OK: offline mode contract holds (doctor row + update --check refusal)."
