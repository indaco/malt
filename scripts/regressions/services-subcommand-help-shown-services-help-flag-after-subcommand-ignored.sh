#!/usr/bin/env bash
# Regression: `mt services <sub> --help` shows the services help instead of
# running the subcommand. Pre-fix only argv[0] was scanned, so the flag reached
# the subcommand parser (error, or an endless log tail), and `list` opened the
# database.
#
# Usage: scripts/regressions/services-subcommand-help-shown-services-help-flag-after-subcommand-ignored.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt.
# No network access required.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

P=$(mktemp -d /tmp/mt_svchelp.XXXXXX)
trap 'rm -rf "$P"' EXIT
export MALT_PREFIX="$P" MALT_CACHE="$P/cache"
mkdir -p "$P/cache" "$P/tmp"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# $1 = expected usage line, rest = argv
check() {
  local want=$1 rc=0 out
  shift
  out=$(timeout 10 "$BIN" "$@" 2>"$P/stderr") || rc=$?
  [[ "$rc" -eq 0 ]] || fail "malt $* exited $rc: $(<"$P/stderr")"
  [[ "$out" == *"$want"* ]] || fail "malt $* printed no help on stdout"
}

for sub in list status start stop logs; do
  check "Usage: malt services" services "$sub" --help
done
check "Usage: malt services" services restart foo -h
check "Usage: malt services" services logs foo --follow --help
[[ ! -e "$P/db" ]] || fail "services --help opened the database"

echo "OK"
