#!/usr/bin/env bash
# Regression: a keg path must never leave `<prefix>/Cellar`.
#
# The bug: the three Cellar path sinks — `cellar.remove`,
# `pruneCellarForReinstall`, `pruneOtherCellarVersionsForReinstall` — spliced
# `name`/`version` into `<prefix>/Cellar/<name>/<version>` and handed the
# result to `deleteTree` with no confinement check of their own. Every feeder
# was expected to screen first, and one did not: `parseInstallReceipt` returned
# `source.versions.stable` from a foreign INSTALL_RECEIPT.json unscreened, so
# `mt migrate` materialized — and, on a rollback, deleted — a path that hopped
# out of the Cellar entirely.
#
# Two arms, both offline:
#   1. the sink + receipt guards, via the inline unit suite (`lib_tests`);
#   2. `migrate` end to end against a hand-written local Cellar whose receipt
#      version escapes, with a canary directory outside the prefix.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

# `pwd -P` normalizes the trailing slash TMPDIR may carry: MALT_PREFIX
# refuses a path with an empty component.
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

# --- Arm 1: the guards themselves -------------------------------------------
# A dropped guard would leave the unit suite green vacuously, so require the
# predicate at each sink before trusting the binary's exit code.
for src in src/core/cellar.zig src/cli/install.zig src/core/install_receipt.zig; do
  if ! grep -Fqs -- "isPathComponent" "$src"; then
    echo "FAIL: the path-component guard is missing from $src" >&2
    exit 1
  fi
done

BIN="$ROOT/zig-out/test-bin/lib_tests"
if ! zig build test-bin >/dev/null 2>&1; then
  echo "FAIL: could not build the unit test binary (zig build test-bin)" >&2
  exit 1
fi
if ! OUT=$("$BIN" 2>&1); then
  echo "FAIL: a Cellar path sink accepted an escaping name or version" >&2
  printf '%s\n' "$OUT" | grep -iE "failed|leaked|panic" >&2 || true
  exit 1
fi

# --- Arm 2: migrate against a hostile receipt -------------------------------
if [[ ! -x zig-out/bin/malt ]] && ! zig build >/dev/null 2>&1; then
  echo "FAIL: could not build zig-out/bin/malt" >&2
  exit 1
fi

prefix="$tmp/prefix"
brew_keg="$tmp/brew/Cellar/probe/1.0"
mkdir -p "$prefix" "$brew_keg" "$tmp/canary"
printf '%s' '{"source":{"tap":"homebrew/core","versions":{"stable":"../../../canary"}}}' \
  >"$brew_keg/INSTALL_RECEIPT.json"
touch "$tmp/canary/SENTINEL"

MALT_PREFIX="$prefix" HOMEBREW_PREFIX="$tmp/brew" \
  zig-out/bin/malt migrate probe >"$tmp/out" 2>&1 || true

# `<prefix>/Cellar/probe/../../../canary` resolves to the canary dir: pre-fix
# the migrate wrote a keg into it, so anything beyond SENTINEL is an escape.
leaked=$(find "$tmp/canary" -mindepth 1 ! -name SENTINEL -print -quit)
if [[ -n "$leaked" ]]; then
  echo "FAIL: migrate wrote outside the Cellar ($leaked)" >&2
  exit 1
fi
if [[ ! -f "$tmp/canary/SENTINEL" ]]; then
  echo "FAIL: migrate deleted outside the Cellar" >&2
  exit 1
fi
if ! grep -qiE "malformed" "$tmp/out"; then
  echo "FAIL: migrate accepted an escaping receipt version" >&2
  cat "$tmp/out" >&2
  exit 1
fi

echo "PASS: keg paths stay inside the Cellar"
