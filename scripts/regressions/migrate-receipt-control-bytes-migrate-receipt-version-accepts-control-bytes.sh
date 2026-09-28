#!/usr/bin/env bash
# Regression: a Homebrew receipt carrying a control character is refused.
#
# The bug: `parseInstallReceipt` screened `source.versions.stable` for path
# shape only and left `source.tap` and each dependency `full_name` unscreened.
# `mt migrate`'s private-tap fallback then printed, recorded and linked a keg
# whose version or tap split progress lines, `list` rows and sidecars.
#
# Two arms, both offline:
#   1. the receipt guards, via the inline unit suite (`lib_tests`);
#   2. `migrate` end to end against a hand-written local Cellar whose receipt
#      version, tap, then dependency name carries a line break.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

# An inherited MALT_* override would point migrate at the wrong prefix.
while IFS='=' read -r var _; do unset "$var"; done < <(env | grep '^MALT_' || true)

# `pwd -P` normalizes the trailing slash TMPDIR may carry: MALT_PREFIX
# refuses a path with an empty component.
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

# --- Arm 1: the guards themselves -------------------------------------------
# A dropped guard would leave the unit suite green vacuously.
if ! grep -Fqs -- "hasControlByte" src/core/install_receipt.zig; then
  echo "FAIL: the control-byte guard is missing from src/core/install_receipt.zig" >&2
  exit 1
fi

BIN="$ROOT/zig-out/test-bin/lib_tests"
if ! zig build test-bin >/dev/null 2>&1; then
  echo "FAIL: could not build the unit test binary (zig build test-bin)" >&2
  exit 1
fi
if ! OUT=$("$BIN" 2>&1); then
  echo "FAIL: lib_tests failed; see the failing test names below" >&2
  printf '%s\n' "$OUT" | grep -iE "failed|leaked|panic" >&2 || true
  exit 1
fi

# --- Arm 2: migrate against a hostile receipt -------------------------------
if ! zig build >/dev/null 2>&1; then
  echo "FAIL: could not build zig-out/bin/malt" >&2
  exit 1
fi

run_case() { # $1=label $2=receipt json
  local d="$tmp/$1"
  mkdir -p "$d/prefix/cache/api" "$d/brew/Cellar/probe/1.0"
  # A cached API miss routes to the local-Cellar fallback without the network.
  touch "$d/prefix/cache/api/formula_probe.404"
  printf '%s' "$2" >"$d/brew/Cellar/probe/1.0/INSTALL_RECEIPT.json"
  MALT_PREFIX="$d/prefix" HOMEBREW_PREFIX="$d/brew" NO_COLOR=1 \
    zig-out/bin/malt migrate probe >"$d/out" 2>&1 || true

  if grep -q '^INJECTED' "$d/out"; then
    echo "FAIL[$1]: the receipt split an output line" >&2
    cat "$d/out" >&2
    exit 1
  fi
  if ! grep -qi malformed "$d/out"; then
    echo "FAIL[$1]: migrate accepted the receipt" >&2
    cat "$d/out" >&2
    exit 1
  fi
  if [[ -n $(find "$d/prefix/Cellar/probe" -mindepth 1 -print -quit 2>/dev/null) ]]; then
    echo "FAIL[$1]: migrate materialized the keg" >&2
    exit 1
  fi
}

run_case version '{"source":{"tap":"evil/tap","versions":{"stable":"1.0\nINJECTED"}}}'
run_case tap '{"source":{"tap":"evil/\nINJECTED","versions":{"stable":"1.0"}}}'
run_case dependency '{"source":{"tap":"evil/tap","versions":{"stable":"1.0"}},"runtime_dependencies":[{"full_name":"a\nINJECTED"}]}'

echo "PASS: receipts with a control character are refused"
