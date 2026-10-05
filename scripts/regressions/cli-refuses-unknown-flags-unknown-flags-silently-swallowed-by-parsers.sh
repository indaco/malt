#!/usr/bin/env bash
# Regression: the mutating commands dropped any dash-argument they did not
# recognise and ran without it, exit 0 - so a typo or brew's `-n` turned a
# preview into the real mutation. Each now refuses with `Unknown flag` before
# its side effect, and `--` still ends option parsing. The commands that take
# no names refuse a stray word too, and install refuses an empty name.
#
# Offline, throwaway prefix/cache and a fake empty Homebrew prefix for
# `migrate`. Uses the built binary: run `zig build`.

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

T=$(mktemp -d /tmp/mt-unk.XXXX)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/p/db" "$T/c" "$T/brew/Cellar"
# An empty database, so a name reaches the "not installed" lookup.
: >"$T/p/db/malt.db"

mt() {
  env -u MALT_PREFIX -u MALT_CACHE -u MALT_OFFLINE -u HOMEBREW_PREFIX \
    NO_COLOR=1 MALT_PREFIX="$T/p" MALT_CACHE="$T/c" HOMEBREW_PREFIX="$T/brew" \
    "$BIN" --offline "$@" </dev/null 2>&1
}

# $1 = refusal that must appear; $2 = side-effect marker that must not
# ("" = none); rest = argv.
refuses() {
  local expect=$1 marker=$2 rc=0 out
  shift 2
  out=$(mt "$@") || rc=$?
  [ "$rc" -ne 0 ] || fail "mt $* exited 0 instead of refusing:"$'\n'"$out"
  grep -q "$expect" <<<"$out" || fail "mt $* did not report '$expect':"$'\n'"$out"
  if [ -n "$marker" ] && grep -q "$marker" <<<"$out"; then
    fail "mt $* reached its side effect:"$'\n'"$out"
  fi
}

flag="Unknown flag"
refuses "$flag" "" upgrade --formulla
refuses "$flag" "" upgrade -n
refuses "$flag" "Checking for updates" version update --chck
refuses "$flag" "" install --forec x
refuses "$flag" "" link --overwrit x
refuses "$flag" "" unlink x -n
refuses "$flag" "" reinstall --bogus x
refuses "$flag" "Found Homebrew" --dry-run migrate --bogus
refuses "$flag" "Cache cleared" update --chck

arg="Unknown argument"
refuses "$arg" "Checking for updates" version update check
refuses "$arg" "Found Homebrew" --dry-run migrate x
refuses "$arg" "Cache cleared" update x
refuses "Empty package name" "not found" install x ""

# `--` ends options: a dash-led token after it is looked up as a name, where
# the old parser dropped it as a flag.
for cmd in upgrade install; do
  out=$(mt "$cmd" -- -nosuchpkg) || true
  if grep -q "Unknown flag" <<<"$out" || ! grep -q -- "-nosuchpkg" <<<"$out"; then
    fail "mt $cmd did not look up the name after '--':"$'\n'"$out"
  fi
done

echo "PASS: mutating commands refuse unknown flags before acting"
