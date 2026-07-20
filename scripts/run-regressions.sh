#!/usr/bin/env bash
# Run the regression pool the way the guards expect, so a flaky environment
# isn't misread as a failure: a GitHub token (the tap/cask/self-update guards
# hit the anonymous rate cap without one), a built binary (the guards run
# zig-out/bin/malt, which `zig build test` never produces), and a generous
# per-script timeout (a slow live install must not be killed mid-run).
#
# Pass script names to run a subset; with no args it runs every guard.
# Override the timeout with MALT_REGRESSION_TIMEOUT (seconds).
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 2

: "${MALT_REGRESSION_TIMEOUT:=600}"

# Only mint a token when the caller hasn't supplied one and gh can.
if [[ -z "${MALT_GITHUB_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
  token="$(gh auth token 2>/dev/null || true)"
  [[ -n "$token" ]] && export MALT_GITHUB_TOKEN="$token"
fi

[[ -x zig-out/bin/malt ]] || zig build

# Portable timeout prefix (coreutils `timeout` or brew `gtimeout`); empty
# array when neither is present, so the guard still runs, just unbounded.
timeout_cmd=()
if command -v timeout >/dev/null 2>&1; then
  timeout_cmd=(timeout -k 10 "$MALT_REGRESSION_TIMEOUT")
elif command -v gtimeout >/dev/null 2>&1; then
  timeout_cmd=(gtimeout -k 10 "$MALT_REGRESSION_TIMEOUT")
fi

if [[ $# -gt 0 ]]; then
  scripts=("$@")
else
  scripts=(scripts/regressions/*.sh)
fi

pass=0
fail=0
failed=()
for s in "${scripts[@]}"; do
  [[ -f "$s" ]] || s="scripts/regressions/$s"
  b=$(basename "$s")
  log="/tmp/malt-reg-${b}.log"
  if "${timeout_cmd[@]}" bash "$s" >"$log" 2>&1; then
    pass=$((pass + 1))
    printf '  ok   %s\n' "$b"
  else
    rc=$?
    fail=$((fail + 1))
    failed+=("$b (rc=$rc, log: $log)")
    printf '  FAIL %s (rc=%d, log: %s)\n' "$b" "$rc" "$log"
  fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if ((fail > 0)); then
  printf 'failed:\n'
  printf '  - %s\n' "${failed[@]}"
  exit 1
fi
