#!/usr/bin/env bash
# Lock the tap-resolution contract to a single seam in src/core/tap.zig.
#
# Every fetch URL, every writeback URL, and the `MALT_GITHUB_TOKEN`
# auth reach are co-located in one file so a future URL-shape change
# (prefixless taps, non-GitHub hosts) or auth-policy change lands in
# exactly one place. Drift here is the refresh-regression mode the
# tap-resolution refactor was designed to structurally prevent.
#
# Three anti-patterns are flagged:
#   1. `homebrew-{` — duplicated `homebrew-<repo>` synthesis (API/raw URLs)
#   2. `https://github.com/{s}"` — decorative writeback that lied about
#      the actually-resolvable repo URL
#   3. `MALT_GITHUB_TOKEN` / `githubAuthHeader` outside the helper —
#      the token reaches exactly the GitHub API HEAD call and never
#      the raw Formula/Cask fetches. Widening (or narrowing) the reach
#      without explicit intent is a contract change.
#
# Allowed sites:
#   - src/core/tap.zig          the helper itself
#   - src/cli/migrate/keg.zig   on-disk Cellar path
#                                 (<prefix>/Library/Taps/<user>/homebrew-<repo>) —
#                                 Homebrew's filesystem layout, not a URL
#
# Usage: scripts/regressions/tap-resolution-contract.sh
# Requirements: POSIX grep — no network, no build.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

hits_prefix=$(grep -rn --include='*.zig' -F 'homebrew-{' src/ || true)
hits_bare_slug=$(grep -rn --include='*.zig' -F 'https://github.com/{s}"' src/ || true)
hits_token=$(grep -rn --include='*.zig' -F 'MALT_GITHUB_TOKEN' src/ || true)
hits_auth_helper=$(grep -rn --include='*.zig' -F 'githubAuthHeader' src/ || true)

all=$(printf '%s\n%s\n%s\n%s\n' \
  "$hits_prefix" "$hits_bare_slug" "$hits_token" "$hits_auth_helper")

filtered=$(printf '%s\n' "$all" |
  grep -v '^src/core/tap\.zig:' |
  grep -v '^src/cli/migrate/keg\.zig:' |
  grep -v '^$' || true)

if [[ -n "$filtered" ]]; then
  printf "FAIL: tap-resolution contract violation outside src/core/tap.zig:\n\n" >&2
  printf '%s\n\n' "$filtered" >&2
  printf 'Route URLs through resolveTapBaseUrls; keep MALT_GITHUB_TOKEN reach\n' >&2
  printf 'inside resolveHeadCommit via githubAuthHeader.\n' >&2
  exit 1
fi

echo "OK: tap-resolution contract holds — all fetches and auth go through src/core/tap.zig"
