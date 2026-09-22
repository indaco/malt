#!/usr/bin/env bash
# Regression: a cask upgrade must classify a suffix-less download URL the way
# an install does, before the sudo gate and before the download.
#
# The API upgrade route handed the cask straight to the installer, which reads
# the artifact type from the URL suffix unless told otherwise. A URL with no
# suffix - a download endpoint that redirects to the real file - therefore
# read as unknown on that route: the PKG sudo gate was skipped and the
# prefetch refused it as an unsupported format, even though the same cask had
# just installed. Now that the type is resolved, the gate must read the
# resolved value too, or a walk-resolved pkg would escalate unconfirmed.
#
# Two halves, as with the sibling upgrade guards:
#   1. Shape (static): inside `upgradeCask` the installer is handed a resolved
#      type, and the sudo gate no longer keys on the raw suffix.
#   2. Behaviour: the classification an upgrade shares with install resolves a
#      GET-only redirect on a loopback pair (integration test binary); the
#      upgrade's own gate, prefetch and plan line are driven end to end by
#      the cask_test cases `zig build test` runs.
#
# No network, no temp state; a few seconds once the test binary is cached.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

UP="src/cli/upgrade.zig"
T="tests/net_redirect_auth_test.zig"

API_LINE=$(grep -n 'fn upgradeCask(' "$UP" | cut -d: -f1)
if [[ -z "$API_LINE" ]]; then
  echo "FAIL: could not locate the API cask upgrade route in $UP" >&2
  exit 1
fi
ROUTE=$(awk -v a="$API_LINE" 'NR>=a' "$UP")

if ! grep -Fqs -- 'installer.artifact_type_override = ' <<<"$ROUTE"; then
  echo "FAIL: the API upgrade route never hands the installer a resolved artifact type" >&2
  exit 1
fi
if grep -Fqs -- 'artifactTypeFromUrl(parsed_cask.url) == .pkg' <<<"$ROUTE"; then
  echo "FAIL: the upgrade sudo gate still keys on the raw URL suffix" >&2
  exit 1
fi
for name in \
  'an upgrade takes a cask artifact type from the URL suffix without a walk' \
  'an upgrade refuses a suffix-less cask URL it cannot resolve before downloading'; do
  grep -Fqs -- "$name" "$UP" || {
    echo "FAIL: inline test missing from $UP: $name" >&2
    exit 1
  }
done
CT="tests/cask_test.zig"
for name in \
  'upgrade hands a walk-resolved pkg to the sudo gate before touching the installed version' \
  'upgrade prefetches a walk-resolved dmg instead of refusing it as unsupported'; do
  grep -Fqs -- "$name" "$CT" || {
    echo "FAIL: end-to-end upgrade test missing from $CT: $name" >&2
    exit 1
  }
done
grep -Fqs -- 'a suffix-less cask URL classifies from the redirect its origin only sends on GET' "$T" || {
  echo "FAIL: shared-classifier fixture test missing from $T" >&2
  exit 1
}

# Always rebuild so the binaries reflect current source. Zig's cache makes a
# no-op rebuild cheap.
if ! zig build test-bin >/dev/null 2>&1; then
  echo "FAIL: could not build the test binaries (zig build test-bin)" >&2
  exit 1
fi

BIN="$ROOT/zig-out/test-bin/net_redirect_auth_test"
OUT=$("$BIN" 2>&1) && STATUS=0 || STATUS=$?
if [[ "$STATUS" -ne 0 ]]; then
  echo "FAIL: net_redirect_auth_test - the shared cask classifier does not resolve a GET-only redirect" >&2
  printf '%s\n' "$OUT" | grep -iE "failed|leaked|panic" >&2 || true
  exit 1
fi

echo "PASS: a cask upgrade resolves a suffix-less URL before it gates on sudo or downloads"
