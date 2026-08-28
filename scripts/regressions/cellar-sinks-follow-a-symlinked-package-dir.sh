#!/usr/bin/env bash
# Regression: a symlinked `<prefix>/Cellar/<name>` must not redirect a keg
# write or delete.
#
# The bug: the Cellar sinks proved `name`/`version` were single path
# components and then handed `<prefix>/Cellar/<name>/<version>` to the
# kernel, which happily resolved a symlinked package dir. `mt migrate`
# wiped and rewrote a directory outside `MALT_PREFIX` and reported
# success; the following `mt uninstall` deleted it, also reporting
# success. A symlinked *leaf* is unlinked rather than followed, so only
# the intermediate needs guarding.
#
# Two arms, both offline:
#   1. the guard is wired at every sink, then the inline unit suite runs;
#   2. `migrate` + `uninstall` end to end against a symlinked package dir
#      with a canary outside the prefix.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

# `pwd -P` normalizes the trailing slash TMPDIR may carry: MALT_PREFIX
# refuses a path with an empty component.
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

# --- Arm 1: the guard is wired at every sink --------------------------------
# Counted, not merely present: a file-wide `grep -q` still passes when the
# call is stripped from two of three sinks, which is the drift this pins
# against. cellar.zig routes its three sinks through one helper, so it is
# counted by the helper's call sites rather than by the probe's.
expect_sites() {
  local src=$1 pattern=$2 want=$3 got
  got=$(grep -Fc -- "$pattern" "$src" || true)
  if [ "$got" -lt "$want" ]; then
    echo "FAIL: $src has $got of $want '$pattern' guard sites" >&2
    exit 1
  fi
}
expect_sites src/core/cellar.zig "packageDirIsLink(io, prefix, name)" 3
expect_sites src/cli/install.zig "symlink.isSymlinkOrUnreadable(" 3
expect_sites src/cli/install/local.zig "symlink.isSymlinkOrUnreadable(" 1
expect_sites src/cli/uninstall.zig "symlink.isSymlinkOrUnreadable(" 1

BIN="$ROOT/zig-out/test-bin/lib_tests"
if ! zig build test-bin >/dev/null 2>&1; then
  echo "FAIL: could not build the unit test binary (zig build test-bin)" >&2
  exit 1
fi
if ! OUT=$("$BIN" 2>&1); then
  echo "FAIL: a Cellar sink followed a symlinked package dir" >&2
  printf '%s\n' "$OUT" | grep -iE "failed|leaked|panic" >&2 || true
  exit 1
fi

# --- Arm 2: migrate + uninstall through a symlinked package dir -------------
if [[ ! -x zig-out/bin/malt ]] && ! zig build >/dev/null 2>&1; then
  echo "FAIL: could not build zig-out/bin/malt" >&2
  exit 1
fi

prefix="$tmp/prefix"
brew_keg="$tmp/brew/Cellar/probe/1.0"
mkdir -p "$prefix/Cellar" "$brew_keg/bin" "$tmp/victim/1.0"
printf '%s' '{"source":{"tap":"homebrew/core","versions":{"stable":"1.0"}}}' \
  >"$brew_keg/INSTALL_RECEIPT.json"
printf 'hi\n' >"$brew_keg/bin/probe"
chmod +x "$brew_keg/bin/probe"
touch "$tmp/victim/1.0/SENTINEL"
ln -s "$tmp/victim" "$prefix/Cellar/probe"

MALT_PREFIX="$prefix" HOMEBREW_PREFIX="$tmp/brew" \
  zig-out/bin/malt migrate probe >"$tmp/out" 2>&1 || true

if [[ ! -f "$tmp/victim/1.0/SENTINEL" ]]; then
  echo "FAIL: migrate deleted outside the prefix ($tmp/victim/1.0)" >&2
  exit 1
fi
leaked=$(find "$tmp/victim/1.0" -mindepth 1 ! -name SENTINEL -print -quit)
if [[ -n "$leaked" ]]; then
  echo "FAIL: migrate wrote outside the prefix ($leaked)" >&2
  exit 1
fi
if ! grep -qiE "symlink" "$tmp/out"; then
  echo "FAIL: migrate accepted a symlinked package dir" >&2
  cat "$tmp/out" >&2
  exit 1
fi

# The keg was never recorded, so uninstall has nothing to remove; drive it
# anyway — pre-fix the DB row existed and its teardown deleted the victim.
MALT_PREFIX="$prefix" zig-out/bin/malt uninstall probe >>"$tmp/out" 2>&1 || true

if [[ ! -f "$tmp/victim/1.0/SENTINEL" ]]; then
  echo "FAIL: uninstall deleted outside the prefix ($tmp/victim/1.0)" >&2
  exit 1
fi

echo "PASS: a symlinked package dir cannot redirect a Cellar write or delete"
