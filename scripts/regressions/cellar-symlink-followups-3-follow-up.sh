#!/usr/bin/env bash
# Regression: the three unclosed edges around the Cellar symlink guard.
#
# The guard refuses to materialise a keg into a symlinked
# `<prefix>/Cellar/<name>`. Three things around that refusal were open:
#
#   1. `doctor` had no check that looks at a package dir, so the one
#      command a user is sent to after the refusal was silent about it;
#   2. a refused materialise still bumped the store refcount, pinning the
#      bottle's bytes at `refcount = 1` with no keg row referencing them —
#      unreclaimable, because an orphan is `refcount <= 0`;
#   3. `upgrade` passed no `cellar_diag` sink, so it printed the bare
#      `Failed to materialize <name>` while `install` named the variant.
#
# All three arms are offline and run against a scratch prefix.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
if [[ ! -x "$BIN" ]] && ! zig build >/dev/null 2>&1; then
  echo "FAIL: could not build zig-out/bin/malt" >&2
  exit 1
fi

# `pwd -P` normalizes the trailing slash TMPDIR may carry: MALT_PREFIX
# refuses a path with an empty component.
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

prefix="$tmp/prefix"
mkdir -p "$prefix"/{store,Cellar,Caskroom,opt,bin,lib,tmp,cache,db} "$tmp/victim"
export MALT_PREFIX="$prefix" NO_COLOR=1 MALT_NO_EMOJI=1 MALT_OFFLINE=1

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# --- Arm 1: doctor names a symlinked package dir ----------------------------
# The clean half first: a check that always warns would satisfy the
# symlinked half on its own.
mkdir -p "$prefix/Cellar/real/1.0"
"$BIN" doctor --json >"$tmp/clean.json" 2>/dev/null || true
grep -q '"id":"cellar_package_directories","severity":"ok"' "$tmp/clean.json" ||
  fail "a Cellar holding only real package dirs is not reported clean"

ln -s "$tmp/victim" "$prefix/Cellar/planted"

"$BIN" doctor >"$tmp/human.txt" 2>&1 || true
grep -q 'Cellar package directories.*planted' "$tmp/human.txt" ||
  fail "doctor did not name the symlinked package dir"
grep -qi 'refused' "$tmp/human.txt" ||
  fail "doctor did not say installs into it are refused"

"$BIN" doctor --json >"$tmp/warn.json" 2>/dev/null || true
grep -q '"id":"cellar_package_directories","severity":"warn"' "$tmp/warn.json" ||
  fail "doctor --json did not report the symlinked package dir"
grep -q 'planted' "$tmp/warn.json" ||
  fail "doctor --json did not name the symlinked package dir"

# --- Arm 2: a refused materialise claims no store bytes ---------------------
# The bump only happens on a cold commit, which needs a registry; the
# integration test drives one over loopback, so run it here rather than
# reaching for the network.
KEG_TEST="$ROOT/zig-out/test-bin/install_keg_from_bottle_test"
if ! zig build test-bin >/dev/null 2>&1; then
  fail "could not build the integration test binaries (zig build test-bin)"
fi
if ! OUT=$(MALT_PREFIX=/tmp/malt-test-prefix "$KEG_TEST" 2>&1); then
  printf '%s\n' "$OUT" | grep -iE "failed|leaked|panic" >&2 || true
  fail "a refused materialise left a claimed store refcount"
fi

# --- Arm 3: the upgrade failure line carries the variant --------------------
# Seed a keg row at 1.0, a cached formula at 2.0, and the 2.0 bottle warm
# in the store, so the upgrade reaches the cellar refusal with no network.
sha="feed$(printf '0%.0s' $(seq 1 60))"
mkdir -p "$prefix/store/$sha/planted/2.0" "$prefix/cache/api"
echo warm >"$prefix/store/$sha/planted/2.0/README"
cat >"$prefix/cache/api/formula_planted.json" <<EOF
{"name":"planted","full_name":"planted","tap":"homebrew/core","desc":"","homepage":"",
 "versions":{"stable":"2.0"},"revision":0,"dependencies":[],"keg_only":false,
 "post_install_defined":false,"oldnames":[],
 "bottle":{"stable":{"files":{"all":{"cellar":":any",
   "url":"https://ghcr.io/v2/homebrew/core/planted/blobs/sha256:$sha","sha256":"$sha"}}}}}
EOF
sqlite3 "$prefix/db/malt.db" \
  "INSERT INTO kegs (name, full_name, version, revision, tap, store_sha256, cellar_path)
   VALUES ('planted','planted','1.0',0,'homebrew/core','$sha','$prefix/Cellar/planted/1.0');"

"$BIN" upgrade planted >"$tmp/upgrade.txt" 2>&1 || true
grep -q 'Failed to materialize planted: UnsafeCellarLink' "$tmp/upgrade.txt" ||
  fail "upgrade's materialize failure line lost the CellarError variant"

echo "PASS: the Cellar symlink refusal is diagnosed and claims no store bytes"
