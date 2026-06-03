#!/usr/bin/env bash
# Lock forge-aware `mt tap --pin` for non-GitHub taps.
#
# `mt tap --pin <slug> <sha>` proves a SHA is reachable before storing it.
# The check must route through the tap's OWN forge — a GitLab or Codeberg
# tap pins against its v4/v1 `commits/<sha>` endpoint, never api.github.com,
# and a failure names the tap's forge host rather than a hard-coded
# "GitHub". The recorded-response HTTP path is covered offline by
# `tests/tap_pin_forge_test.zig`; this script exercises the real binary
# end-to-end against the live forges.
#
# Pinned behaviour (per gitlab.com and codeberg.org tap):
#   1. A bogus SHA never lands — the pin is refused (non-zero exit) and the
#      row stays unpinned (`commit_sha` null).
#   2. The refusal never prints the old GitHub-only string ("GitHub has no
#      such commit"); a non-github tap must not be validated against GitHub.
#   3. When the forge is reachable (a clean 404 for the missing commit), the
#      message names the forge host. Offline, that leg is skipped — the
#      reachability check can't run without network.
#
# Opt-in (MALT_PIN_LIVE=1): a positive leg that pins a *reachable* commit on
# a real GitLab and Codeberg repo and asserts it lands — end-to-end proof
# that a non-github pin succeeds, not just that a bad one is refused. Off by
# default because it depends on live upstreams; it skips (never fails) on a
# transient forge hiccup so an opt-in run can't be blocked by an outage.
#
# Usage: scripts/regressions/tap_pin_forge.sh
#        MALT_PIN_LIVE=1 scripts/regressions/tap_pin_forge.sh   # + success leg
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt; network for
# the host-named-message leg (degrades gracefully when offline). The opt-in
# success leg also needs `curl`.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

MALT_BIN=${MALT_BIN:-$ROOT/zig-out/bin/malt}
if [[ ! -x "$MALT_BIN" ]]; then
  printf 'FAIL: malt binary not found at %s — run "zig build" first.\n' "$MALT_BIN" >&2
  exit 1
fi

PREFIX=$(mktemp -d -t mt_tappin.XXXXXX)
mkdir -p "$PREFIX/db"
trap 'rm -rf "$PREFIX"' EXIT
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1

# A well-formed but non-existent commit — passes SHA validation, so the
# pin proceeds to the reachability check and the forge answers 404.
BOGUS_SHA="0000000000000000000000000000000000000000"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# Pin a registered non-github tap to a bogus SHA and assert the contract.
#   $1 host   $2 slug
assert_forge_pin() {
  local host="$1" slug="$2" out
  out=$("$MALT_BIN" tap --pin "$slug" "$BOGUS_SHA" 2>&1) && rc=0 || rc=$?

  [[ "$rc" -ne 0 ]] || fail "$host: pinning a bogus SHA must be refused (got exit 0)"

  # The core regression: a non-github tap is never validated against GitHub.
  if printf '%s' "$out" | grep -q 'GitHub has no such commit'; then
    printf '%s\n' "$out" | sed 's/^/        /' >&2
    fail "$host: pin refusal wrongly routed through GitHub"
  fi

  # A refused pin never lands: the bogus SHA must appear in no row.
  if "$MALT_BIN" tap --json | grep -q "$BOGUS_SHA"; then
    fail "$host: $slug was pinned to the bogus SHA despite a refused pin"
  fi

  # Strong leg: when the forge is reachable, the message names its host.
  if printf '%s' "$out" | grep -qiE 'network|connect|resolve host|timed out'; then
    printf '  - SKIP %s host-named-message leg (no network): %s\n' "$host" \
      "$(printf '%s' "$out" | tr '\n' ' ')"
  elif printf '%s' "$out" | grep -q "$host"; then
    printf '  \xe2\x9c\x93 %s pin refused and names its own forge host\n' "$host"
  else
    printf '%s\n' "$out" | sed 's/^/        /' >&2
    fail "$host: refusal neither named the host nor reported a network error"
  fi
}

# Register a real repo as a tap, fetch a reachable commit SHA from its forge,
# pin it, and assert the pin lands. Skips (not fails) on a network/upstream
# hiccup so an opt-in live run is never blocked by a transient outage.
#   $1 host   $2 slug   $3 owner/repo   $4 commits-list API URL
assert_live_pin() {
  local host="$1" slug="$2" repo="$3" api="$4" sha out rc
  "$MALT_BIN" tap "$slug" --host "$host" --repo "$repo" >/dev/null 2>&1 ||
    fail "$host: registering $repo as $slug failed"

  # The commits-list body leads with the head commit's 40-hex id/sha.
  sha=$(curl -fsSL "$api" 2>/dev/null | grep -oiE '[0-9a-f]{40}' | head -1 || true)
  if [[ -z "$sha" ]]; then
    printf '  - SKIP %s live pin (could not fetch a reachable sha)\n' "$host"
    return 0
  fi

  out=$("$MALT_BIN" tap --pin "$slug" "$sha" 2>&1) && rc=0 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    if printf '%s' "$out" | grep -qiE 'network|connect|rate|timed out|unexpected status'; then
      printf '  - SKIP %s live pin (forge transient: %s)\n' "$host" \
        "$(printf '%s' "$out" | tr '\n' ' ')"
      return 0
    fi
    printf '%s\n' "$out" | sed 's/^/        /' >&2
    fail "$host: live pin of a reachable commit did not land"
  fi

  printf '%s' "$out" | grep -q 'Pinned' || fail "$host: expected a 'Pinned' confirmation"
  "$MALT_BIN" tap --json | grep -q "$sha" || fail "$host: row not pinned to the reachable sha"
  printf '  \xe2\x9c\x93 %s live pin of a reachable commit landed\n' "$host"
}

# Register a GitLab and a Codeberg tap (offline, unpinned), then pin each.
"$MALT_BIN" tap grp/tap --host gitlab.com --repo grp/tap >/dev/null 2>&1 ||
  fail 'mt tap --host gitlab.com --repo grp/tap exited non-zero'
"$MALT_BIN" tap team/tap --host codeberg.org --repo team/tap >/dev/null 2>&1 ||
  fail 'mt tap --host codeberg.org --repo team/tap exited non-zero'

assert_forge_pin gitlab.com grp/tap
assert_forge_pin codeberg.org team/tap

# Opt-in: prove a *successful* pin against a reachable commit on a real forge.
if [[ "${MALT_PIN_LIVE:-0}" == "1" ]]; then
  if command -v curl >/dev/null; then
    assert_live_pin gitlab.com live-gl/tap gitlab-org/gitlab-runner \
      'https://gitlab.com/api/v4/projects/gitlab-org%2Fgitlab-runner/repository/commits?per_page=1'
    assert_live_pin codeberg.org live-cb/tap forgejo/forgejo \
      'https://codeberg.org/api/v1/repos/forgejo/forgejo/commits?limit=1'
  else
    printf '  - SKIP live-success leg (curl not found)\n'
  fi
fi

printf 'OK: non-GitHub tap pins route through their own forge and never fall back to GitHub.\n'
