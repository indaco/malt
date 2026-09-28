#!/usr/bin/env bash
# Regression: an API/tap formula or cask record whose name, version, token,
# tap or dependency holds a control character must be refused at parse.
#
# The bug: `parseFormula` and `parseCask` screened those fields only for path
# hops (`/`, `..`, NUL). A hostile mirror serving `"name":"foo\nbar"` got a
# keg or Caskroom identity that split every line-oriented surface (progress,
# `list`, `info`); an ESC showed a name that could not be typed back.
#
# The fix refuses C0, DEL, and C1 spelled as UTF-8 at the one ingestion choke
# point. Each case drives `info --offline` against a seeded API cache and
# asserts neither the record nor the sentinel after the control byte reaches
# the output. The `search` and `outdated` side-cars are screened when built
# from the API dump, which needs the network; inline tests cover those.
#
# Usage: scripts/regressions/api-identity-control-bytes-api-and-service-identities-accept-control-bytes.sh
# Requirements: zig toolchain (the script rebuilds malt) or a built malt at
# $MALT_BIN. No network: `--offline` serves the seeded cache at any age.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
# A stale binary would mask the fix, so rebuild unless one was handed in.
[[ -n "${MALT_BIN:-}" ]] || (cd "$ROOT" && zig build)
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

SB=$(mktemp -d /tmp/mt.XXX)
trap 'rm -rf "$SB"' EXIT

# An inherited MALT_* (cache, API domain, ...) would point the run elsewhere.
while IFS='=' read -r v _; do unset "$v"; done < <(env | grep '^MALT_' || true)
export NO_COLOR=1
export MALT_PREFIX="$SB/p"
export MALT_CACHE="$SB/cache"
mkdir -p "$MALT_CACHE/api"

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# A cask record without a url does not parse, so every fixture carries one.
URL='"url":"https://example.invalid/a.dmg"'

# info <cache file> <json> <info args...> -> combined output in $SB/out.
# Only one record is cached at a time: `info evil` shows a cask of the same
# name when no formula is cached, so a leftover fixture would render in a
# refused case.
info() {
  rm -f "$MALT_CACHE"/api/*.json
  printf '%s' "$2" >"$MALT_CACHE/api/$1"
  shift 2
  local rc=0
  "$BIN" info "$@" --offline >"$SB/out" 2>&1 || rc=$?
  # A refusal is a clean exit; a signal (panic, abort) must not pass.
  ((rc < 128)) || {
    cat "$SB/out" >&2
    fail "info $* crashed (exit $rc)"
  }
}

# Controls: a clean record must render, or the refusals below prove nothing.
info formula_evil.json '{"name":"evil","versions":{"stable":"1.0"}}' evil
grep -q 'stable 1\.0' "$SB/out" || {
  cat "$SB/out" >&2
  fail "clean formula fixture did not render"
}
pass "a clean formula record renders"
info cask_evil.json "{\"token\":\"evil\",\"version\":\"1.0\",$URL}" --cask evil
grep -q 'evil: 1\.0 (cask)' "$SB/out" || {
  cat "$SB/out" >&2
  fail "clean cask fixture did not render"
}
pass "a clean cask record renders"

# refused <label> <cache file> <json> <info args...>
refused() {
  local label=$1
  shift
  info "$@"
  # The clean controls render `stable 1.0` / `(cask)`; a refused record must
  # render neither, not merely lose the sentinel.
  if grep -qE 'INJECTED|stable 1\.0|\(cask\)' "$SB/out"; then
    cat "$SB/out" >&2
    fail "$label was accepted"
  fi
  # A cache miss renders nothing either; the message proves the parser refused it.
  grep -q 'unreadable answer' "$SB/out" || {
    cat "$SB/out" >&2
    fail "$label was not reported as refused"
  }
  pass "$label is refused"
}

refused "a line feed in the formula name" formula_evil.json \
  '{"name":"evil\nINJECTED","versions":{"stable":"1.0"}}' evil
refused "an ESC and line feed in the formula version" formula_evil.json \
  '{"name":"evil","versions":{"stable":"1.0\u001b\nINJECTED"}}' evil
refused "an ESC in a formula dependency" formula_evil.json \
  '{"name":"evil","versions":{"stable":"1.0"},"dependencies":["x\u001b[2JINJECTED"]}' evil
refused "a line feed in the formula tap" formula_evil.json \
  '{"name":"evil","versions":{"stable":"1.0"},"tap":"a/b\nINJECTED"}' evil
refused "a line feed in the cask token" cask_evil.json \
  "{\"token\":\"evil\\nINJECTED\",\"version\":\"1.0\",$URL}" --cask evil
refused "a CR/LF in the cask version" cask_evil.json \
  "{\"token\":\"evil\",\"version\":\"1.0\\r\\nINJECTED\",$URL}" --cask evil
refused "a UTF-8 C1 control in the cask version" cask_evil.json \
  "{\"token\":\"evil\",\"version\":\"1.0\\u009bINJECTED\",$URL}" --cask evil

echo "api identity control-byte regression: all checks passed"
