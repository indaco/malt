#!/usr/bin/env bash
# Regression: `deps` must report an API record it could not read, not call the
# formula "not found".
#
# The bug: the API adapter behind `deps` folded every fetch and parse error
# into "no record of this name", and `execute` turned any walk error into an
# empty graph. A refused record (control byte, traversal, malformed JSON), an
# offline cache miss and an unreachable API all printed "<name>: not found."
# (or `[]`) with exit 0; under -r a refused inner record rendered as
# "(not installed)" and vanished from the --json entries.
#
# `deps --offline` serves the on-disk API cache at any age, so a staged cache
# file drives the shipped code path end to end with no network.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
BIN="$ROOT/zig-out/bin/malt"

if ! zig build >/dev/null 2>&1; then
  echo "FAIL: could not build malt" >&2
  exit 1
fi

SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/cache/api" "$SB/prefix"

seed() { printf '%s' "$2" >"$SB/cache/api/$1"; }

run() {
  rc=0
  env -u MALT_API_DOMAIN -u CLICOLOR_FORCE NO_COLOR=1 MALT_PREFIX="$SB/prefix" MALT_CACHE="$SB/cache" \
    "$BIN" deps "$@" --offline >"$SB/out" 2>"$SB/err" || rc=$?
}

# A failed lookup is a clean non-zero exit with nothing rendered; a signal
# (panic, abort) must not pass.
refused() {
  local label=$1 want=$2
  shift 2
  run "$@"
  if ((rc == 0 || rc >= 128)); then
    cat "$SB/out" "$SB/err" >&2
    echo "FAIL: $label exited $rc; an unreadable record must be reported, not called not-found" >&2
    exit 1
  fi
  if ! grep -q "$want" "$SB/err"; then
    cat "$SB/err" >&2
    echo "FAIL: $label did not report '$want'" >&2
    exit 1
  fi
  if [[ -s "$SB/out" ]]; then
    cat "$SB/out" >&2
    echo "FAIL: $label rendered a graph" >&2
    exit 1
  fi
}

seed formula_demo.json '{"name":"demo","versions":{"stable":"1.0"},"dependencies":["x\u001b[2J"]}'
seed formula_top.json '{"name":"top","versions":{"stable":"1.0"},"dependencies":["demo","leaf"]}'
seed formula_leaf.json '{"name":"leaf","versions":{"stable":"1.0"},"dependencies":[]}'

refused "refused root" 'unreadable answer' demo
refused "refused root --json" 'unreadable answer' demo --json
refused "refused inner -r" 'unreadable answer' -r top
refused "refused inner -r --json" 'unreadable answer' -r top --json
refused "offline cache miss" 'not cached' nope

run leaf
if ((rc != 0)) || ! grep -q 'has no dependencies' "$SB/out"; then
  cat "$SB/out" "$SB/err" >&2
  echo "FAIL: a clean record no longer renders (exit $rc)" >&2
  exit 1
fi

# Non-recursive never looks up direct deps, so a refused one stays a name.
run top
if ((rc != 0)) || ! grep -q 'demo' "$SB/out"; then
  cat "$SB/out" "$SB/err" >&2
  echo "FAIL: non-recursive deps of a clean root broke (exit $rc)" >&2
  exit 1
fi

echo "PASS: an unreadable or uncached API record is reported, not called not-found"
