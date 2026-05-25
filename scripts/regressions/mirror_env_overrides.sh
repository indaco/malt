#!/usr/bin/env bash
# Lock the corporate-mirror env contract end-to-end at the binary edge.
#
# Three behaviours pinned:
#   1. Defaults shape — no env, doctor row reads "using upstream Homebrew defaults".
#   2. HTTPS-only refusal — a non-https override exits non-zero before any
#      subcommand runs, with the operator-facing message.
#   3. Override + fallback precedence — MALT_* wins over HOMEBREW_*; both
#      knobs surface in the doctor row exactly as resolved (incl.
#      trailing-slash normalisation).
#
# Usage: scripts/regressions/mirror_env_overrides.sh
# Requirements: a built malt binary at zig-out/bin/malt (just build).
# No network access required — `mt doctor` runs locally against
# MALT_PREFIX and only the env probe is asserted.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

MALT_BIN=${MALT_BIN:-$ROOT/zig-out/bin/malt}
if [[ ! -x "$MALT_BIN" ]]; then
  printf 'FAIL: malt binary not found at %s — run "zig build" first.\n' "$MALT_BIN" >&2
  exit 1
fi

# Use a throwaway prefix so doctor never touches /opt/malt.
PREFIX=$(mktemp -d -t malt_mirror_reg.XXXXXX)
trap 'rm -rf "$PREFIX"' EXIT

# Strip any inherited mirror env so the host's shell can't poison
# the deterministic assertions below.
unset MALT_API_DOMAIN MALT_BOTTLE_DOMAIN HOMEBREW_API_DOMAIN HOMEBREW_BOTTLE_DOMAIN

run_doctor() {
  MALT_PREFIX="$PREFIX" "$MALT_BIN" doctor 2>&1 || true
}

# (1) Defaults — no override, the upstream-defaults message must surface.
out=$(run_doctor)
if ! grep -q "Mirror overrides — using upstream Homebrew defaults" <<<"$out"; then
  printf 'FAIL: defaults row missing.\n%s\n' "$out" >&2
  exit 1
fi

# (2) HTTPS-only refusal — a non-https override exits non-zero before
# any subcommand runs, with the canonical message.
set +e
err=$(MALT_PREFIX="$PREFIX" MALT_API_DOMAIN=http://insecure.example.com "$MALT_BIN" --help 2>&1)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  printf 'FAIL: non-https override should exit non-zero (got rc=0).\n' >&2
  exit 1
fi
if ! grep -q "must use https://" <<<"$err"; then
  printf 'FAIL: non-https error message missing.\n%s\n' "$err" >&2
  exit 1
fi

# (3a) MALT_* wins over HOMEBREW_* and trailing slash is normalised.
out=$(MALT_PREFIX="$PREFIX" \
  MALT_API_DOMAIN="https://malt.example.com/api/" \
  HOMEBREW_API_DOMAIN="https://hb.example.com/api" \
  MALT_BOTTLE_DOMAIN="https://reg.example.com/" \
  run_doctor)
if ! grep -q "API=https://malt.example.com/api, Bottle=https://reg.example.com" <<<"$out"; then
  printf 'FAIL: MALT_* precedence or trailing-slash normalisation regressed.\n%s\n' "$out" >&2
  exit 1
fi

# (3b) HOMEBREW_* fallback surfaces when MALT_* is unset.
out=$(MALT_PREFIX="$PREFIX" \
  HOMEBREW_API_DOMAIN="https://hb-fallback.example.com/api" \
  run_doctor)
if ! grep -q "API=https://hb-fallback.example.com/api" <<<"$out"; then
  printf 'FAIL: HOMEBREW_* fallback row missing.\n%s\n' "$out" >&2
  exit 1
fi

# (3c) The API-reachable probe targets the resolved host (no fall-back
# to the upstream URL on override).
out=$(MALT_PREFIX="$PREFIX" \
  MALT_API_DOMAIN="https://probe-host.example.com/api" \
  run_doctor)
if ! grep -q "Cannot reach https://probe-host.example.com" <<<"$out"; then
  printf 'FAIL: API-reachable probe did not target the override host.\n%s\n' "$out" >&2
  exit 1
fi

echo "OK: mirror env-override contract holds (defaults, https-only, precedence, probe host)."
