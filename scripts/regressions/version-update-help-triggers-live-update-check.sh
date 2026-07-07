#!/usr/bin/env bash
# Regression: `malt version update --help` must print the version help
# text instead of starting a live update check, and `malt version --help`
# must print the same help instead of just the version number.
#
# The bug: the `version` dispatch arm never intercepted -h/--help, so
# `version update --help` went straight into the self-updater (network
# lookup, download prompt) and there was no `version` entry in the help
# table at all.
#
# Runs with --offline so a regressed binary can never reach the network.
# Exits 0 when both invocations show the help text, non-zero otherwise.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

# `zig build test` never rebuilds zig-out/bin/malt — build explicitly.
if [ ! -x "$ROOT/zig-out/bin/malt" ]; then
  (cd "$ROOT" && zig build)
fi

BIN="$ROOT/zig-out/bin/malt"
status=0

for argv in "version update --help" "version --help" "version update -h"; do
  # shellcheck disable=SC2086 # intentional word splitting of the argv string
  out=$("$BIN" --offline $argv 2>&1) || true
  if ! printf '%s' "$out" | grep -q "Usage: malt version"; then
    echo "FAIL: 'malt $argv' did not print the version help" >&2
    status=1
  fi
done

[ "$status" -eq 0 ] && echo "OK: version help intercepted before the updater"
exit "$status"
