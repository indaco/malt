#!/usr/bin/env bash
# Regression: `CaskInstaller.uninstall` spared the prefetched artifact from its
# cache sweep but not from the `deleteTree(app_path)` branch. A PKG cask records
# its cached `.pkg` as `app_path`, so a token reusing one cache name across
# versions had an upgrade delete the very bytes its install pass was about to
# read — with the old version already gone.
#
# Static only: no network, no build, runs in milliseconds. The behavioural
# guards run under `zig build test`; this asserts the spare and both tests are
# still there, since deleting any of them would drop the coverage silently.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CASK="$ROOT/src/core/cask.zig"
TESTS="$ROOT/tests/cask_extra_test.zig"
SPARED="a PKG cask's cached artefact survives uninstall when the prefetch named it"
NARROW="uninstall still removes an app_path the prefetch does not name"
fail=0

# 1. The app_path branch must consult the prefetch spare.
if ! grep -Fqs -- 'and !spared' "$CASK"; then
  echo "FAIL: uninstall can delete the artifact its own prefetch fetched" >&2
  fail=1
fi

# 2. Coverage anchors — the spare and its narrowness.
if ! grep -Fqs -- "$SPARED" "$TESTS"; then
  echo "FAIL: the spared-artifact guard test is missing" >&2
  fail=1
fi
if ! grep -Fqs -- "$NARROW" "$TESTS"; then
  echo "FAIL: the guard-stays-narrow test is missing" >&2
  fail=1
fi

if [[ $fail -eq 0 ]]; then
  echo "PASS: uninstall keeps the artifact an upgrade prefetched"
fi
exit $fail
