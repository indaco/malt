#!/usr/bin/env bash
# Lock tap-slug canonicalisation: every spelling of a tap is one tap.
#
# Homebrew downcases a tap reference and strips a leading `homebrew-`
# from the repo component before addressing the git repo as
# `homebrew-<repo>`. malt used to keep the user's spelling verbatim, so
# a slug that already carried the prefix resolved to
# `github.com/<user>/homebrew-homebrew-<repo>` (404), and the same
# missing canonicalisation split one tap's identity across two rows.
#
# Pinned behaviour:
#   1. Resolve — a `homebrew-`-prefixed slug reaches the `.rb` probe
#      instead of 404ing on the tap repo. Keyed on error *text*, not exit
#      code: both the broken and fixed runs exit non-zero on a formula
#      that does not exist; only the broken one blames the repo.
#   2. Identity — registering one spelling and removing another leaves
#      no row behind. `untap` is silent about a miss, so the registry
#      listing is the assertion.
#
# Uses a deliberately absent formula, so nothing is installed and a
# single API round trip covers the whole run. Throwaway MALT_PREFIX,
# never the live one.
#
# Usage: scripts/regressions/tap-slug-canonicalisation-myx-installation-fails.sh
# Requirements: a built malt binary; one GitHub API call.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

MALT_BIN=${MALT_BIN:-$ROOT/zig-out/bin/malt}
if [[ ! -x "$MALT_BIN" ]]; then
  printf 'FAIL: malt binary not found at %s — run "zig build" first.\n' "$MALT_BIN" >&2
  exit 1
fi

# The override must name a tap whose slug ALREADY carries `homebrew-`.
TAP_PREFIXED=${MALT_TAP_REGRESSION:-indaco/homebrew-tap}
TAP_BARE=${TAP_PREFIXED/\/homebrew-//}

PREFIX=$(mktemp -d)
trap 'rm -rf "$PREFIX"' EXIT
export MALT_PREFIX="$PREFIX"
export MALT_GITHUB_TOKEN=${MALT_GITHUB_TOKEN:-$(gh auth token 2>/dev/null || true)}

# Skip loud rather than fail: the anonymous 60/hr cap makes an untokened
# run indistinguishable from the bug. Same gate as tap_head_etag_304.sh.
if [[ -z "$MALT_GITHUB_TOKEN" ]]; then
  printf 'SKIP: MALT_GITHUB_TOKEN unset — a rate-limited resolve is\n' >&2
  printf '       indistinguishable from the 404 this test looks for.\n' >&2
  exit 0
fi

# (1) resolve
out=$("$MALT_BIN" install --dry-run "$TAP_PREFIXED/nope-not-a-formula" 2>&1 || true)
# An environment failure is not a regression — say so and stop.
if grep -qE 'rate limit reached|Network failure' <<<"$out"; then
  printf 'SKIP: GitHub unreachable or rate-limited:\n%s\n' "$out" >&2
  exit 0
fi
if grep -q '404 for the tap repo' <<<"$out"; then
  printf "FAIL: '%s' still resolves to a doubled homebrew- prefix:\n\n" "$TAP_PREFIXED" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
if ! grep -q 'Tap formula/cask not found' <<<"$out"; then
  printf 'FAIL: unexpected resolve output for %s:\n\n' "$TAP_PREFIXED" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

# (2) identity
if ! reg_out=$("$MALT_BIN" tap "$TAP_BARE" 2>&1); then
  printf 'SKIP: could not register %s:\n%s\n' "$TAP_BARE" "$reg_out" >&2
  exit 0
fi
"$MALT_BIN" untap "$TAP_PREFIXED" >/dev/null 2>&1 || true
listing=$("$MALT_BIN" tap --list 2>&1 || true)
if grep -qi -- "$TAP_BARE" <<<"$listing"; then
  printf "FAIL: '%s' survived untap of '%s' — two rows for one tap:\n\n" \
    "$TAP_BARE" "$TAP_PREFIXED" >&2
  printf '%s\n' "$listing" >&2
  exit 1
fi

echo "OK: prefixed and bare spellings resolve alike and share one tap identity"
