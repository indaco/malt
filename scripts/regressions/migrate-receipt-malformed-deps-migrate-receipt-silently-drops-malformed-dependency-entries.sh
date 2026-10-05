#!/usr/bin/env bash
# Regression: a Homebrew receipt with a malformed dependency list is refused.
#
# The bug: `parseInstallReceipt` skipped any `runtime_dependencies` item that
# was not an object with a string `full_name`, and read a non-array value as
# "no dependencies". `mt migrate`'s local-Cellar fallback then recorded the keg
# without those dependency rows, so `purge --unused-deps` could remove a
# library the keg still links against.
#
# Offline, end to end against a hand-written local Cellar. A `null` list is
# the tolerated control: legacy brew tabs use it for "not recorded". A
# well-formed list must still land its dependency row.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

# An inherited MALT_* override would point migrate at the wrong prefix.
while IFS='=' read -r var _; do unset "$var"; done < <(env | grep '^MALT_' || true)

# `pwd -P` normalizes the trailing slash TMPDIR may carry: MALT_PREFIX
# refuses a path with an empty component.
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

if ! zig build >/dev/null 2>&1; then
  echo "FAIL: could not build zig-out/bin/malt" >&2
  exit 1
fi

base='{"source":{"tap":"x/y","versions":{"stable":"1.0"}},"runtime_dependencies":'

run_case() { # $1=label $2=runtime_dependencies json; leaves the case dir in $d
  d="$tmp/$1"
  mkdir -p "$d/prefix/cache/api" "$d/brew/Cellar/probe/1.0"
  # A cached API miss routes to the local-Cellar fallback without the network.
  touch "$d/prefix/cache/api/formula_probe.404"
  printf '%s%s}' "$base" "$2" >"$d/brew/Cellar/probe/1.0/INSTALL_RECEIPT.json"
  MALT_PREFIX="$d/prefix" HOMEBREW_PREFIX="$d/brew" NO_COLOR=1 \
    zig-out/bin/malt migrate >"$d/out" 2>&1 || true
}

for c in \
  'null-name:[{"full_name":null}]' \
  'no-name:[{"name":"libbar"}]' \
  'number-name:[{"full_name":7}]' \
  'empty-name:[{"full_name":""}]' \
  'space-name:[{"full_name":"lib bar"}]' \
  'bare-string:["libbar"]' \
  'not-array:"libbar"'; do
  label="${c%%:*}"
  run_case "$label" "${c#*:}"
  if ! grep -qi malformed "$d/out"; then
    echo "FAIL[$label]: migrate accepted the receipt" >&2
    cat "$d/out" >&2
    exit 1
  fi
  if [[ -n $(find "$d/prefix/Cellar/probe" -mindepth 1 -print -quit 2>/dev/null) ]]; then
    echo "FAIL[$label]: migrate materialized the keg" >&2
    exit 1
  fi
done

run_case legacy-null 'null'
kegs=$(sqlite3 "$d/prefix/db/malt.db" "SELECT COUNT(*) FROM kegs WHERE name = 'probe';" 2>/dev/null || true)
if [[ $kegs != 1 ]]; then
  echo "FAIL[legacy-null]: a null runtime_dependencies did not migrate the keg" >&2
  cat "$d/out" >&2
  exit 1
fi

run_case well-formed '[{"full_name":"libbar"}]'
deps=$(sqlite3 "$d/prefix/db/malt.db" "SELECT dep_name FROM dependencies;" 2>/dev/null || true)
if [[ $deps != "libbar" ]]; then
  echo "FAIL[well-formed]: the migrated keg lost its dependency row (got '$deps')" >&2
  cat "$d/out" >&2
  exit 1
fi

echo "PASS: malformed runtime_dependencies refuse the receipt"
