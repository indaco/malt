#!/usr/bin/env bash
# Lock the tap-resolution contract to the core/tap.zig + core/forge.zig
# seam.
#
# Every fetch URL, every writeback URL, and the `MALT_GITHUB_TOKEN`
# auth reach are co-located behind the forge seam so a future URL-shape
# change (prefixless taps, non-GitHub hosts) or auth-policy change lands
# in exactly one place. Drift here is the refresh-regression mode the
# tap-resolution refactor was designed to structurally prevent.
#
# Three anti-patterns are flagged:
#   1. `homebrew-{` — duplicated `homebrew-<repo>` synthesis (API/raw URLs)
#   2. `https://github.com/{s}"` — decorative writeback that lied about
#      the actually-resolvable repo URL
#   3. `MALT_GITHUB_TOKEN` / `authHeader` outside the seam —
#      the token reaches the tap-resolution forge seam and the
#      self-update GitHub API GET, and never the raw Formula/Cask
#      fetches. Widening (or narrowing) the reach without explicit
#      intent is a contract change.
#
# Allowed sites:
#   - src/core/forge.zig        the host-shaped seam (URLs, parse, auth)
#   - src/core/tap.zig          the row/orchestration caller of the seam
#   - src/tap_slug.zig          the canonical-identity leaf: strip and
#                                 re-prefix live together so they cannot
#                                 drift, and a leaf is the only tier both
#                                 core/ and db/ (the repair migration) can
#                                 import
#   - src/cli/migrate/keg.zig   on-disk Cellar path
#                                 (<prefix>/Library/Taps/<user>/homebrew-<repo>) —
#                                 Homebrew's filesystem layout, not a URL
#   - src/net/client.zig        the self-update / notifier GET auto-injects
#                                 the same primary token (HttpClient.githubApiToken)
#                                 so `version update` honors it like tap lookups
#   - Zig multiline-string (`\\`) lines — documentation, e.g. the `--help`
#                                 env-var listing. A real token reach is
#                                 executable code; it can never live inside
#                                 a string literal, so doc mentions are exempt.
#
# Usage: scripts/regressions/tap-resolution-contract.sh
# Requirements: POSIX grep — no network, no build.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

# Search root is `src` (no trailing slash) so grep outputs `src/path:N:…`
# uniformly across BSD and GNU; a trailing slash makes some grep
# versions emit `src//path` and the allowlist regex below would miss.
hits_prefix=$(grep -rn --include='*.zig' -F 'homebrew-{' src || true)
hits_bare_slug=$(grep -rn --include='*.zig' -F 'https://github.com/{s}"' src || true)
hits_token=$(grep -rn --include='*.zig' -F 'MALT_GITHUB_TOKEN' src || true)
hits_auth_helper=$(grep -rn --include='*.zig' -F 'authHeader' src || true)

all=$(printf '%s\n%s\n%s\n%s\n' \
  "$hits_prefix" "$hits_bare_slug" "$hits_token" "$hits_auth_helper")

# A leading backslash after the `path:line:` prefix marks a Zig
# multiline-string line (documentation, e.g. the --help env listing) — never
# a token reach, so exempt it. `bs` holds one backslash via ANSI-C quoting so
# the regex stays shellcheck-clean.
bs=$'\\'
filtered=$(printf '%s\n' "$all" |
  grep -v '^src/core/forge\.zig:' |
  grep -v '^src/core/tap\.zig:' |
  grep -v '^src/tap_slug\.zig:' |
  grep -v '^src/cli/migrate/keg\.zig:' |
  grep -v '^src/net/client\.zig:' |
  grep -vE ":[0-9]+:[[:space:]]*${bs}${bs}" |
  grep -v '^$' || true)

if [[ -n "$filtered" ]]; then
  printf "FAIL: tap-resolution contract violation outside the forge seam:\n\n" >&2
  printf '%s\n\n' "$filtered" >&2
  printf 'Route URLs through forge.buildBaseUrls/forge.rawFileUrl; keep the\n' >&2
  printf 'MALT_GITHUB_TOKEN reach inside forge.authHeader.\n' >&2
  exit 1
fi

# The `mt tap --pin` reachability verb (`commits/<sha>`) must build through
# forge.commitUrl, so a non-github tap pins against its own forge instead
# of 404ing at api.github.com. The `commits/{s}` URL literal therefore
# lives only in the seam — re-inlining it at a call site (the bug this
# guards) would route every pin back at GitHub.
pin_literal=$(grep -rn --include='*.zig' -F 'commits/{s}' src |
  grep -v '^src/core/forge\.zig:' || true)
if [[ -n "$pin_literal" ]]; then
  printf 'FAIL: commits/<sha> pin URL built outside forge.commitUrl:\n\n' >&2
  printf '%s\n\n' "$pin_literal" >&2
  printf 'Route the pin verb through forge.commitUrl so non-github taps\n' >&2
  printf 'pin against their own forge.\n' >&2
  exit 1
fi

echo "OK: tap-resolution contract holds — all fetches, auth, and the pin verb go through the forge seam"
