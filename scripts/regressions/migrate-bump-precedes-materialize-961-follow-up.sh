#!/usr/bin/env bash
# Regression: a blocked `migrate` must not claim store bytes.
#
# `migrateKeg` bumped the store refcount before materialising the keg,
# and nothing decremented it when materialise refused. Retrying a
# blocked migrate therefore left `store_refs.refcount = N` with no
# `kegs` row to match — and since every reclaim path (`Store.orphans`,
# `doctor --fix`) treats `refcount <= 0` as the only reclaimable state,
# those bytes were pinned for the life of the prefix.
#
# Fully offline: a warm store and a seeded API cache keep the run off
# the network, and a symlinked package dir forces a repeatable refusal.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
if [[ ! -x "$BIN" ]] && ! zig build >/dev/null 2>&1; then
  echo "FAIL: could not build zig-out/bin/malt" >&2
  exit 1
fi

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# `pwd -P` normalizes the trailing slash TMPDIR may carry: MALT_PREFIX
# refuses a path with an empty component.
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

prefix="$tmp/prefix"
brew="$tmp/brew"
sha="feed$(printf '0%.0s' $(seq 1 60))"

mkdir -p "$prefix"/{store,Cellar,Caskroom,opt,bin,lib,tmp,cache,db} \
  "$prefix/store/$sha/planted/1.0" "$prefix/cache/api" \
  "$brew/Cellar/planted/1.0" "$tmp/victim"
echo warm >"$prefix/store/$sha/planted/1.0/README"

cat >"$prefix/cache/api/formula_planted.json" <<EOF
{"name":"planted","full_name":"planted","tap":"homebrew/core","desc":"","homepage":"",
 "versions":{"stable":"1.0"},"revision":0,"dependencies":[],"keg_only":false,
 "post_install_defined":false,"oldnames":[],
 "bottle":{"stable":{"files":{"all":{"cellar":":any",
   "url":"https://ghcr.io/v2/homebrew/core/planted/blobs/sha256:$sha","sha256":"$sha"}}}}}
EOF

# Planting the package dir as a symlink out of the prefix is the
# cheapest way to make materialise refuse the same way every run.
ln -s "$tmp/victim" "$prefix/Cellar/planted"

export MALT_PREFIX="$prefix" HOMEBREW_PREFIX="$brew" NO_COLOR=1 MALT_NO_EMOJI=1 MALT_OFFLINE=1

for _ in 1 2 3; do
  "$BIN" migrate >"$tmp/run.txt" 2>&1 || true
done

grep -q 'failed to materialize' "$tmp/run.txt" ||
  fail "migrate did not reach the cellar refusal — the fixture no longer exercises the bug"

n=$(sqlite3 "$prefix/db/malt.db" \
  "SELECT COALESCE(SUM(refcount),0) FROM store_refs WHERE store_sha256='$sha';")
[[ "$n" == "0" ]] ||
  fail "three blocked migrate runs claimed refcount=$n for a keg that was never created"

echo "PASS: a blocked migrate claims no store bytes, however often it is retried"
