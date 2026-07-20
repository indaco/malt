#!/usr/bin/env bash
# Regression: the passive version notifier decided whether to nag with a
# pure string inequality (current != latest), never a semver ordering. A
# build whose running version was *ahead* of the cached `latest_tag` was
# still told "A newer malt is available", i.e. nagged to downgrade.
#
# Pre-seed a fresh cache (far-future checked_at => never stale, so no
# network is needed) naming a LOWER latest than the running version, bypass
# the non-TTY suppression via the assume-TTY seam, and assert it stays
# silent. Exits non-zero when the downgrade nag is present, 0 once the
# semver guard lands. No network, no pty; finishes well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

cur="$("$BIN" version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[^ ]*')"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Fresh cache (far-future checked_at => never stale) naming a LOWER latest
# than current. last_attempt == checked_at is the success shape.
future=$(($(date +%s) + 86400))
printf '{"checked_at":%d,"latest_tag":"v0.0.1","current_seen":"%s","last_attempt":%d}\n' \
  "$future" "$cur" "$future" >"$tmp/version-notify.json"

# Bypass the non-TTY suppression via the assume-TTY seam; clear CI/json/quiet
# suppressors. Deterministic in any runner (CI, background); no pty needed.
out="$(env -u CI -u GITHUB_ACTIONS MALT_CACHE="$tmp" \
  MALT_VERSION_NOTIFIER_ASSUME_TTY=1 "$BIN" list 2>&1 || true)"

if grep -q "A newer malt is available" <<<"$out"; then
  echo "FAIL: notifier nagged about v0.0.1 while on $cur (latest < current must be silent)" >&2
  exit 1
fi

# Positive guard: a clearly higher latest must still fire, so the fix
# rejects equal/behind without over-suppressing real updates.
printf '{"checked_at":%d,"latest_tag":"v999.0.0","current_seen":"%s","last_attempt":%d}\n' \
  "$future" "$cur" "$future" >"$tmp/version-notify.json"
out_hi="$(env -u CI -u GITHUB_ACTIONS MALT_CACHE="$tmp" \
  MALT_VERSION_NOTIFIER_ASSUME_TTY=1 "$BIN" list 2>&1 || true)"
if ! grep -q "A newer malt is available" <<<"$out_hi"; then
  echo "FAIL: notifier stayed silent about v999.0.0 while on $cur (real update suppressed)" >&2
  exit 1
fi

echo "ok: no downgrade nag when cached latest < current; still nags when latest > current"
