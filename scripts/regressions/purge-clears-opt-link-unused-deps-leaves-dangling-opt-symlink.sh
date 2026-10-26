#!/usr/bin/env bash
# Regression: `purge --unused-deps` removes the `opt/<name>` link of each keg it
# removes, and the broken-symlink sweep (`purge --broken-symlinks`, `doctor`)
# also covers `opt/`. A dangling `opt/` link is reported and removed; a live
# one is kept.
#
# Usage: scripts/regressions/purge-clears-opt-link-unused-deps-leaves-dangling-opt-symlink.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt; sqlite3 on PATH.
# No network access required.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}
command -v sqlite3 >/dev/null 2>&1 || {
  echo "this regression needs sqlite3 on PATH" >&2
  exit 2
}

P=""
trap '[[ -n "$P" ]] && rm -rf "$P"' EXIT
P=$(mktemp -d /tmp/mt_optlink.XXXXXX)
unset MALT_CACHE
export MALT_PREFIX="$P" MALT_CACHE="$P/cache"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

mkdir -p "$P/db" "$P/cache" "$P/tmp"
"$BIN" --offline list >/dev/null 2>&1

sha=$(printf 'a%.0s' $(seq 64))
mkdir -p "$P/Cellar/depx/1.0/lib" "$P/opt"
echo x >"$P/Cellar/depx/1.0/lib/f"
ln -s "$P/Cellar/depx/1.0" "$P/opt/depx"
sqlite3 "$P/db/malt.db" "INSERT INTO kegs(name,full_name,version,store_sha256,cellar_path,install_reason)
  VALUES('depx','depx','1.0','$sha','$P/Cellar/depx/1.0','dependency');"

# Positive precondition: the seeded orphan is what purge sees.
out=$("$BIN" purge --unused-deps --yes 2>&1) || true
[[ "$out" == *depx* ]] || fail "--unused-deps did not pick the seeded orphan: $out"
[[ ! -e "$P/Cellar/depx/1.0" ]] || fail "--unused-deps kept the Cellar dir"
[[ ! -L "$P/opt/depx" ]] || fail "--unused-deps left opt/depx dangling"

mkdir -p "$P/live"
ln -s "$P/live" "$P/opt/live"
ln -s "$P/Cellar/gone/1.0" "$P/opt/gone"

doc=$("$BIN" doctor 2>&1) || true
[[ "$doc" == *"Broken symlinks —"* ]] || fail "doctor missed dangling opt/gone: $doc"

"$BIN" purge --broken-symlinks --yes >/dev/null 2>&1 || true
[[ ! -L "$P/opt/gone" ]] || fail "--broken-symlinks kept dangling opt/gone"
[[ -L "$P/opt/live" ]] || fail "--broken-symlinks removed live opt/live"

echo "ok"
