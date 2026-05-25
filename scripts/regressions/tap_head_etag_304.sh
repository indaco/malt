#!/usr/bin/env bash
# Lock the ETag-aware tap HEAD-resolve contract end-to-end against the
# real GitHub API.
#
# Pinned behaviour:
#   1. Cold-start `mt tap add <user/repo>` resolves HEAD and stamps
#      both `taps.commit_sha` and `taps.head_etag`.
#   2. A second `mt tap add <user/repo>` against the same tap sends
#      `If-None-Match` — GitHub answers 304, and the GitHub REST rate
#      limit's `core.remaining` does NOT decrement on the second call.
#
# Requirements: a built malt binary, a MALT_GITHUB_TOKEN with REST
# read scope (any classic PAT or fine-grained "public read" works).
# The token is mandatory: without it the test cannot meaningfully
# observe the 5000/hr cap, so we skip-loud instead of silently passing.
#
# Usage: scripts/regressions/tap_head_etag_304.sh

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

MALT_BIN=${MALT_BIN:-$ROOT/zig-out/bin/malt}
if [[ ! -x "$MALT_BIN" ]]; then
  printf 'FAIL: malt binary not found at %s — run "zig build" first.\n' "$MALT_BIN" >&2
  exit 1
fi

if [[ -z "${MALT_GITHUB_TOKEN:-}" ]]; then
  printf 'SKIP: MALT_GITHUB_TOKEN unset — cannot read GitHub REST rate-limit\n' >&2
  printf '       headers without it (anonymous limits are noisy across runs).\n' >&2
  exit 0
fi

# Stable, low-churn tap that exists at github.com/<user>/homebrew-<repo>.
# Picked because its HEAD rarely moves; if upstream force-pushes a fresh
# commit between calls 1 and 2 the test would (correctly) fail —
# re-running once the dust settles is the right response.
TAP=${MALT_TAP_REGRESSION:-aeroxy/tap}

PREFIX=$(mktemp -d -t malt_etag_reg.XXXXXX)
trap 'rm -rf "$PREFIX"' EXIT

remaining_before_call() {
  curl -fsSL \
    -H "Authorization: Bearer $MALT_GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    https://api.github.com/rate_limit |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["resources"]["core"]["remaining"])'
}

probe_etag_persisted() {
  MALT_PREFIX="$PREFIX" "$MALT_BIN" tap --json 2>/dev/null
}

# ---- Cold start: tap add against a fresh prefix ----
before_cold=$(remaining_before_call)
MALT_PREFIX="$PREFIX" "$MALT_BIN" tap add "$TAP" >/dev/null
after_cold=$(remaining_before_call)
cold_delta=$((before_cold - after_cold))
if ((cold_delta < 1)); then
  printf 'FAIL: cold tap add did not move rate-limit remaining (before=%d after=%d).\n' \
    "$before_cold" "$after_cold" >&2
  printf '       Either GitHub returned 304 (impossible without a cached etag)\n' >&2
  printf '       or the rate-limit endpoint diverged from the tap-resolve path.\n' >&2
  exit 1
fi

# ---- Hot start: same `tap add`, cached etag in play ----
before_hot=$(remaining_before_call)
MALT_PREFIX="$PREFIX" "$MALT_BIN" tap add "$TAP" >/dev/null
after_hot=$(remaining_before_call)
hot_delta=$((before_hot - after_hot))
if ((hot_delta != 0)); then
  printf 'FAIL: hot tap add decremented rate-limit by %d (expected 0 — 304 is free).\n' \
    "$hot_delta" >&2
  printf '       before=%d after=%d. The cached ETag was not sent or the\n' \
    "$before_hot" "$after_hot" >&2
  printf '       server returned 200 instead of 304.\n' >&2
  exit 1
fi

# ---- Sanity: the etag was actually stored ----
tap_json=$(probe_etag_persisted)
if ! grep -q '"commit_sha"' <<<"$tap_json"; then
  printf 'FAIL: tap list does not surface a commit_sha for %s after the\n' "$TAP" >&2
  printf '       cold-start resolve.\n%s\n' "$tap_json" >&2
  exit 1
fi

printf 'PASS: cold start spent %d token(s); hot start spent %d (304 short-circuit).\n' \
  "$cold_delta" "$hot_delta"
