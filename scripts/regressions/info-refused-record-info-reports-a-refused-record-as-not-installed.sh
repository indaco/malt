#!/usr/bin/env bash
# Regression: `info` must report an API record it refused at parse, not call
# the package "not installed".
#
# The bug: emitApiFormula and emitApiCask swallowed every parse error as
# "the API has no such package". A fetched record the parser refused (control
# byte, traversal in name/version, malformed JSON) ended in "<name>: not
# installed" with exit 0, and a refused formula fell through to rendering a
# same-named cask.
#
# `info --offline` serves the on-disk API cache at any age, so a staged cache
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
    "$BIN" info "$@" --offline >"$SB/out" 2>"$SB/err" || rc=$?
}

# A refusal is a clean non-zero exit; a signal (panic, abort) must not pass.
refused() {
  local label=$1
  shift
  run "$@"
  if ((rc == 0 || rc >= 128)); then
    cat "$SB/out" "$SB/err" >&2
    echo "FAIL: $label exited $rc; a refused record must be reported, not called not-installed" >&2
    exit 1
  fi
  if ! grep -q 'unreadable answer' "$SB/err"; then
    echo "FAIL: $label was not reported as an unreadable answer" >&2
    exit 1
  fi
  if grep -qE 'not installed|\(cask\)|stable 1\.0' "$SB/out"; then
    echo "FAIL: $label was rendered" >&2
    exit 1
  fi
}

seed formula_demo.json '{"name":"demo","versions":{"stable":"1.0"},"dependencies":["x\u001b[2J"]}'
refused "refused formula" --formula demo

seed cask_c2.json '{"token":"c2","version":"../x","url":"https://e/x.dmg"}'
refused "refused cask" --cask c2

# The refused formula must stop the lookup, not fall through to the cask.
seed formula_both.json '{"name":"both","versions":{"stable":"1.0\u001b"}}'
seed cask_both.json '{"token":"both","version":"1.0","url":"https://e/x.dmg"}'
refused "refused formula shadowing a cask" both

seed formula_good.json '{"name":"good","versions":{"stable":"1.0"}}'
run --formula good
if ((rc != 0)) || ! grep -q 'stable 1.0' "$SB/out"; then
  cat "$SB/out" "$SB/err" >&2
  echo "FAIL: a clean record no longer renders (exit $rc)" >&2
  exit 1
fi

echo "PASS: a refused API record is reported, not called not-installed"
