#!/usr/bin/env bash
# Regression: artefacts written to `{prefix}/cache/Cask|Tap` before the
# tier honoured `MALT_CACHE` are moved under the override the first time a
# mutating command runs, so they stay reachable by the sweeps, by doctor
# and by an offline rollback. Pre-fix they were stranded: no sweep looked
# there and no reader found them.
#
# Hermetic: seeded files stand in for the writers; `purge --stale-casks`
# is the mutating command under test.
#
# Usage: scripts/regressions/legacy-artefacts-adopted-under-malt-cache.sh
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

PREFIX="/tmp/mt_legacy_cache_$$"
rm -rf "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$PREFIX/alt"
export MALT_OFFLINE=1
export NO_COLOR=1
export MALT_NO_EMOJI=1

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

mkdir -p "$PREFIX/db" "$PREFIX/cache/Cask" "$PREFIX/cache/Tap"
"$BIN" list >/dev/null 2>&1 || true
[[ -f "$PREFIX/db/malt.db" ]] || fail "DB was not initialised by mt list"

# An installed cask whose artefact and font sidecar predate the override,
# plus a tap archive. None of these is an orphan, so the sweep must keep
# them — under the override.
sqlite3 "$PREFIX/db/malt.db" "INSERT INTO casks (token, name, version, url, sha256, app_path, auto_updates)
  VALUES ('flux', 'flux', '2.0', 'https://example.invalid/dummy', NULL, NULL, 0);"
sha=$(printf 'ab%.0s' {1..32})
printf dmg >"$PREFIX/cache/Cask/flux-2.0.dmg"
printf spec >"$PREFIX/cache/Cask/flux-2.0.fonts"
printf tgz >"$PREFIX/cache/Tap/$sha.tar.gz"

"$BIN" purge --stale-casks --yes >/dev/null 2>&1 || true

for f in "Cask/flux-2.0.dmg" "Cask/flux-2.0.fonts" "Tap/$sha.tar.gz"; do
  [[ -e "$MALT_CACHE/$f" ]] || fail "$f was not adopted under \$MALT_CACHE"
  [[ ! -e "$PREFIX/cache/$f" ]] || fail "$f still sits under {prefix}/cache"
done
[[ "$(cat "$MALT_CACHE/Cask/flux-2.0.dmg")" == dmg ]] || fail "adopted artefact lost its bytes"
pass "legacy cask artefact, font sidecar and tap archive moved under MALT_CACHE"

echo "legacy artefacts adopted under MALT_CACHE: OK"
