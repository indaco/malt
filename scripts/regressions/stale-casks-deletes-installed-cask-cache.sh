#!/usr/bin/env bash
# Regression: `purge --stale-casks` — reached by every `mt cleanup` run via
# `--housekeeping` — must keep every cached artefact belonging to a token that
# is still in `casks`, and remove only artefacts of tokens that are not.
#
# The bug: the scope rebuilt a token from a cache filename by stripping one of
# `.dmg`/`.zip`/`.pkg` and nothing else. Artefacts are cached per version as
# `<token>-<version><ext>`, so the lookup asked for `flux-2.0`, matched no row,
# and deleted the installed cask's artefact — the one `rollback` depends on and
# that latest-only vendor URLs cannot re-fetch. `.tar.gz`, `.tar.xz` and
# `.fonts` were not even extension-stripped, so they could never match.
#
# Exits 0 when the bug is absent, non-zero naming the offending file when
# present. No network; well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
# The harness runs the built binary, which `zig build test` does not refresh —
# build it here so a stale binary never masks the fix.
zig build >/dev/null

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export MALT_PREFIX="$tmp/p"
export NO_COLOR=1
export MALT_NO_EMOJI=1

# Must survive: installed token, every cached name shape, current and historical.
keep=(flux-2.0.dmg flux-2.0.tar.gz flux-2.0.tar.xz flux-2.0.fonts flux-1.0.zip flux.dmg)
# Must go: no such token in `casks`. `fluxbox` shares a prefix with `flux` but not
# a token boundary, so the `flux` row must not rescue it.
drop=(ghost-1.0.dmg fluxbox-1.0.dmg)

fail=0

seed() {
  rm -rf "$MALT_PREFIX"
  mkdir -p "$MALT_PREFIX/db" "$MALT_PREFIX/cache/Cask" "$MALT_PREFIX/Caskroom/flux/2.0"
  sqlite3 "$MALT_PREFIX/db/malt.db" <<'SQL'
CREATE TABLE IF NOT EXISTS casks (token TEXT PRIMARY KEY, name TEXT, version TEXT,
  url TEXT, sha256 TEXT, app_path TEXT, auto_updates INTEGER);
INSERT INTO casks VALUES ('flux','flux','2.0','https://example.invalid/x',NULL,NULL,0);
SQL
  for f in "${keep[@]}" "${drop[@]}"; do echo x >"$MALT_PREFIX/cache/Cask/$f"; done
}

check() {
  local via="$1" f
  for f in "${keep[@]}"; do
    [ -e "$MALT_PREFIX/cache/Cask/$f" ] || {
      echo "FAIL: $via deleted the installed cask's artefact $f" >&2
      fail=1
    }
  done
  for f in "${drop[@]}"; do
    [ -e "$MALT_PREFIX/cache/Cask/$f" ] && {
      echo "FAIL: $via kept the orphaned artefact $f" >&2
      fail=1
    }
  done
  # The Caskroom half classifies correctly and was left alone; pin that.
  [ -d "$MALT_PREFIX/Caskroom/flux/2.0" ] || {
    echo "FAIL: $via deleted the installed cask's Caskroom entry" >&2
    fail=1
  }
  return 0
}

seed
"$BIN" purge --stale-casks --yes >/dev/null
check "purge --stale-casks"

# `cleanup` prepends --housekeeping, which folds in --stale-casks: this is the
# verb the bug actually reached users through, so guard it directly.
seed
"$BIN" cleanup --yes >/dev/null
check "cleanup"

[ "$fail" -eq 0 ] || exit 1

echo "ok: stale-casks keeps installed cask artefacts and removes orphans"
