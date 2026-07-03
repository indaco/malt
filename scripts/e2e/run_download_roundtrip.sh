#!/usr/bin/env bash
# scripts/e2e/run_download_roundtrip.sh
#
# Opt-in e2e for the `mt run` ephemeral DOWNLOAD path — the one surface the
# offline regression can't reach (it drives the installed fast path). Does a
# real download+extract+exec of a tiny dependency-free formula and asserts:
#   1. the child's exit code is forwarded (both zero and non-zero), and
#   2. the ephemeral extract under $MALT_PREFIX/tmp is cleaned up, since the
#      exit-forwarding path calls std.process.exit and skips Zig `defer`s.
#
# Needs network (formulae API + GHCR) and a GitHub token, so it self-SKIPs
# (exit 0) when no token is available — it must never flake a push. Run it
# on demand, or in a job that exports MALT_GITHUB_TOKEN.
#
# Usage:
#   MALT_GITHUB_TOKEN=$(gh auth token) ./scripts/e2e/run_download_roundtrip.sh
#   MT_BIN=./zig-out/bin/malt RUN_E2E_PKG=tree ./scripts/e2e/run_download_roundtrip.sh
set -uo pipefail

MT_BIN="${MT_BIN:-./zig-out/bin/malt}"
PKG="${RUN_E2E_PKG:-tree}" # dependency-free single binary; a single-bottle run suffices

if [[ ! -x "$MT_BIN" ]]; then
  echo "run-download: $MT_BIN not found — run 'zig build' first (or set MT_BIN)" >&2
  exit 2
fi

# Mirror pre-push: borrow the gh token so the anonymous GitHub API cap doesn't
# turn a real regression into a silent network failure.
if [[ -z "${MALT_GITHUB_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
  MALT_GITHUB_TOKEN="$(gh auth token 2>/dev/null || true)"
  export MALT_GITHUB_TOKEN
fi
if [[ -z "${MALT_GITHUB_TOKEN:-}" ]]; then
  echo "SKIP  run-download: no MALT_GITHUB_TOKEN (and gh not authed) — needs GitHub API/GHCR"
  exit 0
fi

PREFIX=$(mktemp -d /tmp/mt-run-e2e.XXX)
CACHE=$(mktemp -d /tmp/mc-run-e2e.XXX)
trap 'rm -rf "$PREFIX" "$CACHE"' EXIT
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$CACHE"
export NO_COLOR=1
export MALT_NO_EMOJI=1
mkdir -p "$PREFIX/bin"

# (1a) success path: exit 0 forwards through download+exec.
"$MT_BIN" run "$PKG" -- --version >/dev/null
code=$?
[[ "$code" -eq 0 ]] || {
  echo "FAIL run-download: expected 0 from '$PKG --version', got $code" >&2
  exit 1
}

# (1b) failure path: a non-zero exit forwards. The pre-fix bug forced 0, so a
# non-zero here is what distinguishes the fix — '-@' is a bogus flag $PKG rejects.
"$MT_BIN" run "$PKG" -- -@ >/dev/null 2>&1
code=$?
[[ "$code" -ne 0 ]] || {
  echo "FAIL run-download: expected non-zero from '$PKG -@', got 0 (exit code not forwarded)" >&2
  exit 1
}

# (2) temp cleanup: no ephemeral extract may survive the run.
shopt -s nullglob
leftover=("$PREFIX"/tmp/run_*)
[[ ${#leftover[@]} -eq 0 ]] || {
  echo "FAIL run-download: ephemeral extract leaked: ${leftover[*]}" >&2
  exit 1
}

echo "OK  run-download: exit codes forwarded and \$MALT_PREFIX/tmp is clean"
