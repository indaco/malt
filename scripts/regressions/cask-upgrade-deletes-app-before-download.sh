#!/usr/bin/env bash
# Regression: both cask upgrade routes used to uninstall the installed app
# before a single byte of the replacement artifact had been fetched. A dropped
# connection then destroyed the app while the DB rollback restored the row, so
# `mt list --cask` and `doctor` kept reporting a package that was gone.
#
# Two halves, because neither alone is sufficient and neither may need network:
#   1. Ordering (static): in each upgrade route the prefetch call must appear
#      strictly before `installer.uninstall(token)`. That is the invariant a
#      future refactor would silently break.
#   2. Behaviour: a failed prefetch must leave the seeded bundle and the casks
#      row intact. That guard is a colocated test in tests/cask_extra_test.zig,
#      which `zig build test` already runs — this script only asserts it still
#      exists, rather than rebuilding every test binary to re-run it.
#
# Exits 0 when the bug is absent, non-zero (naming the offending route) when
# present. Static only: no network, no build, runs in milliseconds.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
UP="$ROOT/src/cli/upgrade.zig"
FILTER="a failed cask prefetch leaves the installed app and its row intact"
fail=0

# 1. Ordering, per route.
check_order() { # $1=route label  $2=start line  $3=end line
  local pre un
  pre=$(awk -v a="$2" -v b="$3" 'NR>=a&&NR<=b&&/downloadOnly|download_only = true/{print NR;exit}' "$UP")
  un=$(awk -v a="$2" -v b="$3" 'NR>=a&&NR<=b&&/installer\.uninstall\(token\)/{print NR;exit}' "$UP")
  if [[ -z "$pre" || -z "$un" || "$pre" -ge "$un" ]]; then
    echo "FAIL: $1 uninstalls before it fetches the replacement artifact" >&2
    fail=1
  fi
}

# Derive the route ranges from the fn headers rather than hardcoding lines.
TAP_LINE=$(grep -n 'fn upgradeRoutedTapCask' "$UP" | cut -d: -f1)
API_LINE=$(grep -n 'fn upgradeCask(' "$UP" | cut -d: -f1)
if [[ -z "$TAP_LINE" || -z "$API_LINE" ]]; then
  echo "FAIL: could not locate the cask upgrade routes in upgrade.zig" >&2
  exit 1
fi
check_order "tap route" "$TAP_LINE" "$API_LINE"
check_order "API route" "$API_LINE" "$(wc -l <"$UP")"

# 1b. The tap route must hand the artefact it fetched to its install pass.
# Without that, the uninstall's cache sweep can drop those bytes and the
# install goes back to the network with the old app already deleted.
slots=$(awk -v a="$TAP_LINE" -v b="$API_LINE" 'NR>=a&&NR<=b&&/installTapCask\(/&&/&prefetched/{n++} END{print n+0}' "$UP")
if [[ "$slots" -ne 2 ]]; then
  echo "FAIL: tap route does not carry its prefetched artefact into the install pass" >&2
  fail=1
fi

# 2. Behaviour. The test itself runs under `zig build test`; deleting it would
# silently drop that coverage, so assert it is still there.
if ! grep -Rqs -- "$FILTER" "$ROOT/tests/cask_extra_test.zig"; then
  echo "FAIL: the failed-prefetch guard test is missing from cask_extra_test.zig" >&2
  fail=1
fi

if [[ $fail -eq 0 ]]; then
  echo "PASS: cask upgrade fetches the replacement before it destroys the old app"
fi
exit $fail
