#!/usr/bin/env bash
# Unit tests for scripts/lib/release_wait.sh.
#
# Mocks `curl` so the helpers can be exercised offline against every
# GitHub API state the smoke script has to tolerate:
#   • tag endpoint 404 + latest wrong      → release doesn't exist yet
#   • tag endpoint 200 + latest old        → published, CDN still catching up
#   • tag endpoint 200 + latest correct    → happy path
#   • tag endpoint 5xx / network flakiness → retry without false-failing

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
LIB="$ROOT/scripts/lib/release_wait.sh"

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# ── curl mock harness ────────────────────────────────────────────────
#
# Tests set two env vars:
#   FAKE_TAG_STATUS  — HTTP code returned for /releases/tags/<tag>
#   FAKE_LATEST_TAG  — tag name reported by /releases/latest (empty ⇒ 404)
#
# The mocked curl honours only the flags the lib uses (-f, -s, -w, -o,
# --max-time). It writes the status-code to stdout when -w '%{http_code}'
# is present; otherwise it writes the fake body.
curl() {
  local url="" want_status=0 output_file="" has_f=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
    -f | -fsSL | -fsS | -fs | -fsL) has_f=1 ;;
    -s | -L | -S) ;;
    -w)
      shift
      if [ "$1" = '%{http_code}' ]; then want_status=1; fi
      ;;
    -o)
      shift
      output_file="$1"
      ;;
    --max-time)
      shift
      ;;
    --connect-timeout)
      shift
      ;;
    http*) url="$1" ;;
    *) ;;
    esac
    shift
  done

  local status="" body=""
  case "$url" in
  */releases/tags/*)
    status="${FAKE_TAG_STATUS:-404}"
    body="{\"tag_name\":\"$(basename "$url")\"}"
    ;;
  */releases/latest)
    if [ -n "${FAKE_LATEST_TAG:-}" ]; then
      status="200"
      body="{\"tag_name\": \"${FAKE_LATEST_TAG}\"}"
    else
      status="404"
      body=""
    fi
    ;;
  *)
    status="404"
    body=""
    ;;
  esac

  # -o redirects body to file.
  [ -n "$output_file" ] && printf '%s' "$body" >"$output_file"

  # -w '%{http_code}' overrides body with the numeric status.
  if [ "$want_status" = "1" ]; then
    printf '%s' "$status"
  elif [ -z "$output_file" ]; then
    printf '%s' "$body"
  fi

  # With -f, non-2xx status means curl itself exits non-zero.
  if [ "$has_f" = "1" ] && [ "${status:0:1}" != "2" ]; then
    return 22
  fi
  return 0
}
export -f curl

# Disable the lib's real sleep so tests finish in ms, not minutes.
sleep() { :; }
export -f sleep

# Load the unit under test — requires the lib to exist (TDD: the first
# runs should fail on "no such file").
# shellcheck source=/dev/null
source "$LIB"

# Make `fail` / `pass` inside the lib visible but not fatal during
# tests. The lib calls `fail` which `exit 1`s — we run each case in a
# subshell so one failure does not abort the rest.
run() (
  set +e
  "$@"
  echo "rc=$?"
)

# ── release_tag_exists ───────────────────────────────────────────────

t=0
ok() {
  t=$((t + 1))
  printf '  ✓ [%02d] %s\n' "$t" "$*"
}
bad() {
  t=$((t + 1))
  printf '  ✗ [%02d] %s\n' "$t" "$*" >&2
  exit 1
}

if FAKE_TAG_STATUS=200 release_tag_exists "v0.7.0"; then
  ok "release_tag_exists returns 0 on 200"
else
  bad "release_tag_exists should succeed on 200"
fi
if FAKE_TAG_STATUS=404 release_tag_exists "v0.7.0"; then
  bad "release_tag_exists should fail on 404"
else
  ok "release_tag_exists returns non-zero on 404"
fi
if FAKE_TAG_STATUS=503 release_tag_exists "v0.7.0"; then
  bad "release_tag_exists should fail on 5xx"
else
  ok "release_tag_exists returns non-zero on 5xx"
fi

# ── release_latest_matches ───────────────────────────────────────────

if FAKE_LATEST_TAG="v0.7.0" release_latest_matches "v0.7.0"; then
  ok "release_latest_matches matches the exact tag"
else
  bad "release_latest_matches should match on identical tag"
fi
if FAKE_LATEST_TAG="v0.6.2" release_latest_matches "v0.7.0"; then
  bad "release_latest_matches should NOT match an older tag"
else
  ok "release_latest_matches rejects an older tag"
fi
if FAKE_LATEST_TAG="" release_latest_matches "v0.7.0"; then
  bad "release_latest_matches should NOT match on empty body / 404"
else
  ok "release_latest_matches rejects empty/404 response"
fi
# Partial-match guard: `v0.7.0` must not match `v0.7.00` etc.
if FAKE_LATEST_TAG="v0.7.00" release_latest_matches "v0.7.0"; then
  bad "release_latest_matches must not accept a partial tag match"
else
  ok "release_latest_matches rejects partial-string matches"
fi

# ── wait_for_release: happy + both failure shapes ────────────────────
#
# Sentinel: the lib's `fail` function (inherited from smoke script)
# normally `exit 1`s. For the unit tests, override it to record the
# message and return non-zero so the harness can introspect.
LAST_FAIL=""
# shellcheck disable=SC2317
fail_capture() {
  LAST_FAIL="$*"
  return 1
}

# wait_for_release may call `fail_capture` which returns non-zero —
# don't let `set -e` abort the harness before we inspect LAST_FAIL.
set +e

# Happy path: tag present, /latest flipped on first probe.
if FAKE_TAG_STATUS=200 FAKE_LATEST_TAG="v0.7.0" \
  WAIT_BUDGET_SECONDS=5 WAIT_POLL_INTERVAL=0 \
  MALT_SMOKE_FAIL_FN=fail_capture \
  wait_for_release "v0.7.0" >/dev/null; then
  ok "wait_for_release succeeds when tag+latest both ready"
else
  bad "wait_for_release failed on the happy path"
fi

# Tag exists but /latest lags — must fail with the precise message.
LAST_FAIL=""
FAKE_TAG_STATUS=200 FAKE_LATEST_TAG="v0.6.2" \
  WAIT_BUDGET_SECONDS=1 WAIT_POLL_INTERVAL=0 \
  MALT_SMOKE_FAIL_FN=fail_capture \
  wait_for_release "v0.7.0" >/dev/null
case "$LAST_FAIL" in
*"published"*"/releases/latest"*) ok "wait_for_release reports the precise CDN-lag message" ;;
*) bad "expected precise CDN-lag message, got: ${LAST_FAIL:-<empty>}" ;;
esac

# Tag does not exist — must fail with the "release missing" message.
LAST_FAIL=""
FAKE_TAG_STATUS=404 FAKE_LATEST_TAG="" \
  WAIT_BUDGET_SECONDS=1 WAIT_POLL_INTERVAL=0 \
  MALT_SMOKE_FAIL_FN=fail_capture \
  wait_for_release "v0.7.0" >/dev/null
case "$LAST_FAIL" in
*"does not exist"*) ok "wait_for_release reports the release-missing message" ;;
*) bad "expected release-missing message, got: ${LAST_FAIL:-<empty>}" ;;
esac

# Intermittent flake: tag + /latest both arrive eventually.
if FAKE_TAG_STATUS=200 FAKE_LATEST_TAG="v0.7.0" \
  WAIT_BUDGET_SECONDS=2 WAIT_POLL_INTERVAL=0 \
  MALT_SMOKE_FAIL_FN=fail_capture \
  wait_for_release "v0.7.0" >/dev/null; then
  ok "wait_for_release tolerates eventual readiness within budget"
else
  bad "wait_for_release failed to tolerate eventual readiness"
fi

echo
echo "✔ release_wait: $t unit case(s) passed"
