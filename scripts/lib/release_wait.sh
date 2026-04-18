#!/usr/bin/env bash
# scripts/lib/release_wait.sh
#
# Helpers that answer "is this release ready for users yet?" against
# GitHub's REST API. Split into two checks because they fail for
# distinct reasons:
#
#   • release_tag_exists — /releases/tags/<tag> is 200 the instant the
#     release is published. If it's NOT 200, the release workflow
#     hasn't finished or failed outright.
#
#   • release_latest_matches — /releases/latest reports our tag. The
#     "latest" flag flips asynchronously after publish; `install.sh`
#     (and therefore the README one-liner) depends on this.
#
# The top-level `wait_for_release` stitches them together so failures
# can say precisely which of the two is lagging.
#
# Intended to be sourced. Exit-only `fail` from the caller's smoke
# script is wired in via the MALT_SMOKE_FAIL_FN env var (defaults to
# "fail" — the name the smoke script already defines).

# Configurable via env so tests can compress the wait to milliseconds.
WAIT_BUDGET_SECONDS="${WAIT_BUDGET_SECONDS:-300}" # 5 minutes default
WAIT_POLL_INTERVAL="${WAIT_POLL_INTERVAL:-5}"     # 5s between probes
MALT_SMOKE_API_BASE="${MALT_SMOKE_API_BASE:-https://api.github.com/repos/indaco/malt}"

# Returns 0 when GitHub's tag-specific release endpoint responds 200.
release_tag_exists() {
  local tag="$1"
  local code
  code=$(curl -fsSL -o /dev/null -w '%{http_code}' --max-time 10 \
    "${MALT_SMOKE_API_BASE}/releases/tags/${tag}" 2>/dev/null || true)
  [ "$code" = "200" ]
}

# Returns 0 when /releases/latest.tag_name equals `tag` exactly.
# Strict match (no partial) so v0.7.0 cannot accept v0.7.00.
release_latest_matches() {
  local tag="$1"
  local body
  body=$(curl -fsSL --max-time 10 \
    "${MALT_SMOKE_API_BASE}/releases/latest" 2>/dev/null || true)
  # Require the exact closing quote so prefix-only tags don't match.
  printf '%s' "$body" | grep -q "\"tag_name\": *\"${tag}\""
}

# Poll both endpoints until /latest reflects `tag` or the budget runs
# out. On failure, calls the caller's `fail` function (exported as
# MALT_SMOKE_FAIL_FN) with one of two precise messages so operators
# know whether to re-run the release workflow or just wait on the CDN.
wait_for_release() {
  local tag="$1"
  local fail_fn="${MALT_SMOKE_FAIL_FN:-fail}"
  local deadline=$(($(date +%s) + WAIT_BUDGET_SECONDS))
  local tag_exists=0

  while [ "$(date +%s)" -lt "$deadline" ]; do
    # Once we've seen the tag endpoint go 200 we don't re-probe — the
    # release isn't going to un-publish itself.
    if [ "$tag_exists" -eq 0 ] && release_tag_exists "$tag"; then
      tag_exists=1
    fi
    if release_latest_matches "$tag"; then
      return 0
    fi
    sleep "$WAIT_POLL_INTERVAL"
  done

  if [ "$tag_exists" -eq 1 ]; then
    "$fail_fn" "${tag} is published but /releases/latest is still serving an older tag after $((WAIT_BUDGET_SECONDS / 60))m — install.sh will fall back to source for users until the CDN catches up."
  else
    "$fail_fn" "${tag} does not exist on the release API after $((WAIT_BUDGET_SECONDS / 60))m — release workflow may have failed; check the Actions log."
  fi
  return 1
}
