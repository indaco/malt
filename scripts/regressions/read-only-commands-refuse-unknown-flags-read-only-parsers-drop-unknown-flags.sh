#!/usr/bin/env bash
# Regression: the read-only commands dropped any dash-argument they did not
# recognise and answered without it, so `mt outdated --greedy` or
# `mt deps --tree x` printed a different answer than the one asked for. Each
# now refuses with `Unknown flag`, and `--` still ends option parsing.
#
# Offline, throwaway prefix/cache. Uses the built binary: run `zig build`.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN=${MALT_BIN:-$ROOT/zig-out/bin/mt}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -x "$BIN" ] || {
  echo "missing $BIN - run zig build" >&2
  exit 2
}

T=$(mktemp -d /tmp/mt-ro.XXXX)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/p" "$T/c"

mt() {
  env -u MALT_PREFIX -u MALT_CACHE -u MALT_OFFLINE \
    NO_COLOR=1 MALT_PREFIX="$T/p" MALT_CACHE="$T/c" \
    "$BIN" --offline "$@" </dev/null 2>&1
}

refuses() {
  local rc=0 out
  out=$(mt "$@") || rc=$?
  [ "$rc" -ne 0 ] || fail "mt $* exited 0 instead of refusing:"$'\n'"$out"
  grep -q "Unknown flag" <<<"$out" || fail "mt $* did not report the unknown flag:"$'\n'"$out"
}

refuses outdated --greedy
refuses deps --tree x
refuses info --bogus x
refuses search --bogus x
refuses uses --bogus x
refuses which -a x
refuses vulns --severty=high

# `--` ends options: what follows is a name, never a flag.
for cmd in deps info search uses which vulns; do
  out=$(mt "$cmd" -- -x) || true
  if grep -q "Unknown flag" <<<"$out"; then
    fail "mt $cmd treated the name after '--' as a flag:"$'\n'"$out"
  fi
done

echo "PASS: read-only commands refuse unknown flags"
