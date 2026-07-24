#!/usr/bin/env bash
# Lock the ETag-aware tap HEAD-resolve contract end-to-end against the
# real GitHub API.
#
# Pinned behaviour:
#   1. Cold-start `mt tap <user/repo>` resolves HEAD and stamps both
#      `taps.commit_sha` and `taps.head_etag`.
#   2. A second `mt tap <user/repo>` against the same tap sends
#      `If-None-Match` — GitHub answers 304, and the conditional GET
#      does NOT decrement `X-RateLimit-Remaining`.
#
# Methodology: GitHub's `/rate_limit` endpoint is a cached snapshot
# that lags reality by several seconds. The truth is the
# `X-RateLimit-Remaining` response header on the actual call. So we
# probe `/repos/.../commits/HEAD` directly before and after each
# `mt tap` invocation and read the live header — the inter-probe
# delta minus the probe's own cost is what `mt` spent.
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
SLASH_IDX=$(awk -v s="$TAP" 'BEGIN{print index(s, "/")}')
USER=${TAP:0:$((SLASH_IDX - 1))}
REPO=${TAP:SLASH_IDX}
PROBE_URL="https://api.github.com/repos/${USER}/homebrew-${REPO}/commits/HEAD"

PREFIX=$(mktemp -d -t mt_etag.XXXXXX)
mkdir -p "$PREFIX/db"
trap 'rm -rf "$PREFIX"' EXIT

# Issue an unconditional probe to the same endpoint malt resolves and
# extract `X-RateLimit-Remaining` from the response header. The header
# reflects post-call state (i.e. includes this very call), which is
# exactly what we want.
probe_remaining() {
  local hdr
  hdr=$(curl -fsSL -o /dev/null -D - \
    -H "Authorization: Bearer $MALT_GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "$PROBE_URL")
  awk 'BEGIN{IGNORECASE=1} /^x-ratelimit-remaining:/{gsub(/[\r\n ]/, "", $2); print $2; exit}' <<<"$hdr"
}

# A rising X-RateLimit-Remaining between two probes is physically impossible
# from our own calls — it means GitHub's hourly window reset (bucket refilled)
# mid-run. Any token-delta measured across that boundary is noise, so skip-loud
# and let the caller re-run rather than emit a bogus negative "cost".
skip_if_reset() {
  local before="$1" after="$2" where="$3"
  if ((after > before)); then
    printf 'SKIP: rate-limit window reset during %s (%d -> %d) — re-run.\n' \
      "$where" "$before" "$after" >&2
    exit 0
  fi
}

# ---- Probe A: baseline before any mt call ----
a=$(probe_remaining)

# ---- Cold start: tap against a fresh prefix ----
MALT_PREFIX="$PREFIX" "$MALT_BIN" tap "$TAP" >/dev/null

# ---- Probe B: shows post-cold state (b = a - mt_cold_cost - 1) ----
b=$(probe_remaining)
skip_if_reset "$a" "$b" "cold resolve"
cold_cost=$((a - b - 1))
if ((cold_cost < 1)); then
  printf 'FAIL: cold tap resolve did not spend a token (a=%d b=%d cold=%d).\n' \
    "$a" "$b" "$cold_cost" >&2
  printf '       Expected at least 1 — the unconditional GET should have hit the limit.\n' >&2
  exit 1
fi

# ---- Hot start: same tap, cached etag now persisted ----
MALT_PREFIX="$PREFIX" "$MALT_BIN" tap "$TAP" >/dev/null

# ---- Probe C: shows post-hot state (c = b - mt_hot_cost - 1) ----
c=$(probe_remaining)
skip_if_reset "$b" "$c" "hot resolve"
hot_cost=$((b - c - 1))
if ((hot_cost != 0)); then
  printf 'FAIL: hot tap re-resolve spent %d token(s) (expected 0 — 304 is free).\n' \
    "$hot_cost" >&2
  printf '       a=%d b=%d c=%d. The cached ETag was not sent or the server\n' \
    "$a" "$b" "$c" >&2
  printf '       returned 200 instead of 304.\n' >&2
  exit 1
fi

# ---- Sanity: the etag actually landed in the DB ----
if command -v sqlite3 >/dev/null; then
  et=$(sqlite3 "$PREFIX/db/malt.db" \
    "SELECT head_etag FROM taps WHERE name='$TAP';" 2>/dev/null || true)
  if [[ -z "$et" ]]; then
    printf 'FAIL: head_etag not persisted for %s after cold-start resolve.\n' "$TAP" >&2
    exit 1
  fi
fi

printf 'PASS (etag round-trip): cold spent %d token; hot spent %d (304 short-circuit) — a=%d b=%d c=%d\n' \
  "$cold_cost" "$hot_cost" "$a" "$b" "$c"

# ---- Within-process dedup (gap #2): N casks from one tap → 1 HEAD ----
# Seed 10 fake casks routed to TAP so `mt outdated` walks them through
# the tap-resolve path. The .rb fetches will 404 on the raw CDN (not
# rate-limited) — only the HEAD resolve spends an API token. Clobber
# the cached etag first so the HEAD call returns 200 (not 304), making
# the dedup distinguishable at the rate-limit level: with dedup the
# 10 workers share 1 HEAD call; without dedup they each pay one.
if ! command -v sqlite3 >/dev/null; then
  printf 'SKIP (dedup check): sqlite3 not on PATH — skipping the within-process\n' >&2
  printf '      dedup assertion. The cross-process etag path was verified above.\n' >&2
  exit 0
fi

sqlite3 "$PREFIX/db/malt.db" \
  "UPDATE taps SET head_etag = 'W/\"stale-force-200\"' WHERE name='$TAP';" 2>/dev/null

# 10 > outdated_default_workers (8) so this exercises the pool path.
sqlite3 "$PREFIX/db/malt.db" "$(
  cat <<SQL
INSERT INTO casks (token, name, version, url, tap) VALUES
  ('zzfake1', 'zzfake1', '0', 'https://example.invalid/x.dmg', '$TAP'),
  ('zzfake2', 'zzfake2', '0', 'https://example.invalid/x.dmg', '$TAP'),
  ('zzfake3', 'zzfake3', '0', 'https://example.invalid/x.dmg', '$TAP'),
  ('zzfake4', 'zzfake4', '0', 'https://example.invalid/x.dmg', '$TAP'),
  ('zzfake5', 'zzfake5', '0', 'https://example.invalid/x.dmg', '$TAP'),
  ('zzfake6', 'zzfake6', '0', 'https://example.invalid/x.dmg', '$TAP'),
  ('zzfake7', 'zzfake7', '0', 'https://example.invalid/x.dmg', '$TAP'),
  ('zzfake8', 'zzfake8', '0', 'https://example.invalid/x.dmg', '$TAP'),
  ('zzfake9', 'zzfake9', '0', 'https://example.invalid/x.dmg', '$TAP'),
  ('zzfakeA', 'zzfakeA', '0', 'https://example.invalid/x.dmg', '$TAP');
SQL
)" 2>/dev/null

d=$(probe_remaining)
# `--json` suppresses the per-row "couldn't check" warnings the fake
# tokens trigger. Exit code may be non-zero (snapshot write may fail
# on a partial prefix) — we only care about the rate-limit delta.
MALT_PREFIX="$PREFIX" "$MALT_BIN" outdated --json >/dev/null 2>&1 || true
e=$(probe_remaining)
skip_if_reset "$d" "$e" "dedup walk"
dedup_cost=$((d - e - 1))

# With dedup: 1 HEAD (200, stale etag) = 1 token. Without: 10.
if ((dedup_cost > 1)); then
  printf 'FAIL: within-process dedup leaked %d token(s) for 10 same-tap casks (expected ≤1).\n' \
    "$dedup_cost" >&2
  printf '       d=%d e=%d. Workers sharing a tap should pay 1 HEAD call,\n' "$d" "$e" >&2
  printf '       not N — the TapHeadResolve cache is missing or unwired.\n' >&2
  exit 1
fi

printf 'PASS (dedup): 10 same-tap casks shared %d HEAD token (d=%d e=%d)\n' \
  "$dedup_cost" "$d" "$e"
