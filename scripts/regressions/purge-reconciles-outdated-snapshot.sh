#!/usr/bin/env bash
# Regression: `mt purge --unused-deps` reaps a dependency keg nothing needs
# any more, leaving the cached audit at {cache}/outdated.json still listing
# it. `mt outdated` filters that file through the live DB so it never showed
# the reaped keg, but the TUI's Outdated tab parses it raw on first paint -
# so the tab and its count badge advertised a package that was gone, until
# the background audit landed and healed it.
#
# `mt uninstall` has always reconciled the file right after its row delete;
# autoremove reaches the same kegs by another door and did not.
#
# Offline: the prefix and the snapshot are both written by hand, so the
# reconcile is exercised without an audit ever running.

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

PREFIX=$(mktemp -d /tmp/mt.XXX)
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$PREFIX/cache"
export NO_COLOR=1
export MALT_NO_EMOJI=1
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

DB="$PREFIX/db/malt.db"
SNAP="$MALT_CACHE/outdated.json"
mkdir -p "$PREFIX/db" "$PREFIX/tmp" "$MALT_CACHE" \
  "$PREFIX/Cellar/staleboy/1.0/lib" "$PREFIX/Cellar/keepme/1.0/lib"

# An orphan dependency keg beside a directly-installed one (never an orphan),
# and a cached audit listing both.
"$BIN" list >/dev/null 2>&1 || true
sqlite3 "$DB" "INSERT INTO kegs(name,full_name,version,revision,store_sha256,cellar_path,install_reason)
  VALUES('staleboy','staleboy','1.0',0,'sha','$PREFIX/Cellar/staleboy/1.0','dependency'),
        ('keepme','keepme','1.0',0,'sha2','$PREFIX/Cellar/keepme/1.0','direct');" ||
  fail "could not seed the orphan keg"
cat >"$SNAP" <<'EOF'
{"version":2,"generated_at_ms":1700000000000,"formulas":[{"name":"staleboy","installed":"1.0","latest":"2.0"},{"name":"keepme","installed":"1.0","latest":"2.0"}],"casks":[]}
EOF
pass "orphan keg seeded beside an installed keg, both in the cached audit"

"$BIN" purge --unused-deps --yes >"$PREFIX/purge.log" 2>&1 || {
  tail -20 "$PREFIX/purge.log" >&2
  fail "purge --unused-deps failed"
}
[[ -z $(sqlite3 "$DB" "SELECT 1 FROM kegs WHERE name='staleboy';") ]] ||
  fail "the orphan keg was not removed - the fixture no longer reproduces the scenario"
pass "orphan keg removed"

[[ -f "$SNAP" ]] ||
  fail "the snapshot was deleted; every other keg's audit went with it"
grep -q 'keepme' "$SNAP" ||
  fail "the untouched keg lost its cached audit"
pass "the untouched keg kept its cached audit"

! grep -q 'staleboy' "$SNAP" ||
  fail "the cached audit still lists the reaped keg"
pass "cached audit no longer lists the reaped keg"

echo "PASS: autoremove reconciles the outdated snapshot with the keg it reaped"
