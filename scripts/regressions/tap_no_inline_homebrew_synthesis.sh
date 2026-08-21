#!/usr/bin/env bash
# Structural enforcement that no fetch site inlines the
# `homebrew-<repo>` prefix synthesis. Every URL-building helper must
# read `(github_owner, github_repo)` from the tap row, which means
# `homebrew-{` may live in exactly the allowed files below and nowhere
# else.
#
# Allowed sites:
#   - src/tap_slug.zig          the one synthesis, beside the prefix strip
#                               it has to stay consistent with. Both the
#                               cold-path fallback in `effectiveOwnerRepo`
#                               and the repair migration call it, which is
#                               why it sits in a leaf.
#   - src/cli/migrate/keg.zig   `<prefix>/Library/Taps/<user>/homebrew-<repo>`
#                               on-disk path — Homebrew's filesystem layout,
#                               not a URL.
#
# Any new hit outside this list fails the regression suite — that is the
# coverage-drift guard against a future helper that bypasses the seam.
#
# Usage: scripts/regressions/tap_no_inline_homebrew_synthesis.sh
# Requirements: POSIX grep — no network, no build.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

hits=$(grep -rn --include='*.zig' -F 'homebrew-{' src || true)

filtered=$(printf '%s\n' "$hits" |
  grep -v '^src/tap_slug\.zig:' |
  grep -v '^src/cli/migrate/keg\.zig:' |
  grep -v '^$' || true)

if [[ -n "$filtered" ]]; then
  printf "FAIL: inline homebrew- synthesis outside the allow-list:\n\n" >&2
  printf '%s\n' "$filtered" >&2
  printf "\nAdd the new site to the allow-list only if the synthesis is\n" >&2
  printf "load-bearing for the migration or the on-disk path. Otherwise\n" >&2
  printf "route through src/core/tap.zig:effectiveOwnerRepo.\n" >&2
  exit 1
fi

printf "OK: no inline 'homebrew-{' synthesis outside the allow-list.\n"
