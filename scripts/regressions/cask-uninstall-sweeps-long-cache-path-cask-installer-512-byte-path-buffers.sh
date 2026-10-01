#!/usr/bin/env bash
# Regression: the cask cache writer is unbounded while uninstall's sweep
# formatted the same path into a 512-byte buffer, so a long MALT_CACHE plus
# token and version installed fine and then leaked the artefact and its
# `.binaries` sidecar on every uninstall, silently.
#
# Usage: scripts/regressions/cask-uninstall-sweeps-long-cache-path-cask-installer-512-byte-path-buffers.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt, sqlite3.
# No network access required.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

PREFIX=$(mktemp -d /tmp/mt_r512.XXXXXX)
trap 'rm -rf "$PREFIX"' EXIT
export MALT_PREFIX="$PREFIX"
export MALT_OFFLINE=1
export NO_COLOR=1
export MALT_NO_EMOJI=1
MALT_CACHE="$PREFIX/$(printf 'c%.0s' {1..200})/$(printf 'd%.0s' {1..100})"
export MALT_CACHE

fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

tok=$(printf 't%.0s' {1..100})
ver=$(printf '9%.0s' {1..100})
mkdir -p "$PREFIX/db" "$MALT_CACHE/Cask" "$PREFIX/Caskroom/$tok/$ver"
art="$MALT_CACHE/Cask/$tok-$ver.dmg"
side="$MALT_CACHE/Cask/$tok-$ver.binaries"
((${#art} > 512)) || {
  echo "fixture too short: ${#art}" >&2
  exit 2
}
: >"$art"
: >"$side"

"$BIN" list >/dev/null 2>&1 || true # let malt create the DB
sqlite3 "$PREFIX/db/malt.db" "
  INSERT INTO casks(token,name,version,url,app_path) VALUES('$tok','$tok','$ver','https://x/y.dmg','$PREFIX/Applications/X.app');
  INSERT INTO cask_versions(token,version,url,artifact_type,cache_path) VALUES('$tok','$ver','https://x/y.dmg','dmg','$art');"

"$BIN" uninstall --cask "$tok" >/dev/null 2>&1 || fail "uninstall exited $?"
[[ ! -e $art ]] || fail "uninstall left the >512 B cache artefact behind"
[[ ! -e $side ]] || fail "uninstall left the .binaries sidecar behind"
echo "cask uninstall sweeps long cache paths: OK"
