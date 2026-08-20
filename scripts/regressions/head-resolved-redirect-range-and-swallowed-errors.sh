#!/usr/bin/env bash
# Regression: the manual HEAD redirect loop must follow only real redirects,
# and must report a failed walk as a failure.
#
# Two defects lived in the same loop. It gated the follow on a raw
# `301..308` range instead of the `isFollowableRedirect` predicate twelve
# lines above it, so 304/305/306 — none of them redirects — had their
# `Location` followed. And every transport failure (`Uri.parse`, `request`,
# `sendBodiless`, `receiveHead`) did a bare `break`, which is the same exit
# the terminal-response path takes: a DNS failure before hop 0 came back
# indistinguishable from a resolved URL. The cask installer then classified
# that untouched extensionless URL as `.unknown` and told the user
# "Unsupported cask format" when the truth was that the network was down.
#
# Both halves are loopback-reproducible, so the fixture test binary is the
# honest gate here. Source preconditions guard the one-line predicate call
# from drifting back, and are written fail-closed: they assert the pre-fix
# shape is ABSENT rather than trying to prove a shape is present.
#
# No network, no temp state, well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

SRC="src/net/client.zig"
CONSUMER="src/cli/install.zig"

if grep -Fqs -- "status >= 301 and status <= 308" "$SRC"; then
  echo "FAIL: the HEAD loop still follows non-redirect statuses" >&2
  exit 1
fi
if ! grep -Fqs -- "isFollowableRedirect(status)" "$SRC"; then
  echo "FAIL: the HEAD loop no longer uses the follow predicate" >&2
  exit 1
fi

# A bare `catch break` on a transport call is the swallow. The loop must
# surface the failure instead.
if grep -Eqs -- "(request|sendBodiless|receiveHead)\(.*\) catch break" "$SRC"; then
  echo "FAIL: a transport failure in the HEAD loop is still swallowed" >&2
  exit 1
fi

# The consumer must keep the error channel it was widened to, or the honest
# error would be flattened back into the misleading format message.
if grep -Fqs -- "http.headResolved(url) catch return .unknown" "$CONSUMER"; then
  echo "FAIL: the cask installer still reports a network failure as an unknown format" >&2
  exit 1
fi

# Always rebuild so the binaries reflect current source. Zig's cache makes a
# no-op rebuild cheap.
if ! zig build test-bin >/dev/null 2>&1; then
  echo "FAIL: could not build the test binaries (zig build test-bin)" >&2
  exit 1
fi

for name in net_redirect_auth_test lib_tests; do
  BIN="$ROOT/zig-out/test-bin/$name"
  OUT=$("$BIN" 2>&1) && STATUS=0 || STATUS=$?
  if [[ "$STATUS" -ne 0 ]]; then
    echo "FAIL: $name — a non-redirect hop was followed or a failed walk was reported as resolved" >&2
    printf '%s\n' "$OUT" | grep -iE "failed|leaked|panic" >&2 || true
    exit 1
  fi
done

echo "PASS: the HEAD redirect loop follows only redirects and reports failed walks"
