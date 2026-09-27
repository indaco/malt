#!/usr/bin/env bash
# Regression: a package whose dependency record is refused must itself be
# refused, naming that dependency - not planned and installed without it.
#
# The bug: `collectFormulaJobs` turned each dependency into a download job
# behind `catch continue`, so a dependency record the parser refuses (a
# control byte in its version) or one with no bottle for this platform was
# dropped without a word. The parent was still planned, linked and recorded,
# `mt install` exited 0, and the parent then failed at load time.
#
# Usage: scripts/regressions/refused-dependency-fails-parent-install-silently-drops-a-refused-dependency.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt. No network: the
# API cache is seeded and `--dry-run` never fetches a bottle.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

# MALT_PREFIX must be <= 13 bytes (Mach-O in-place patching budget).
SB=$(mktemp -d /tmp/mt.XXX)
trap 'rm -rf "$SB"' EXIT

export NO_COLOR=1
export MALT_NO_EMOJI=1
export MALT_OFFLINE=1

PREFIX="$SB/p"
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$SB/c"
mkdir -p "$MALT_PREFIX/tmp" "$MALT_CACHE/api"

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# One bottle entry per macOS tag, so the fixture resolves on any host.
bottle_json() {
  local name=$1 sha=$2 files="" tag
  for tag in arm64_tahoe arm64_sequoia arm64_sonoma arm64_ventura tahoe sequoia sonoma ventura; do
    files+="\"$tag\":{\"cellar\":\":any\",\"url\":\"https://example.invalid/$name\",\"sha256\":\"$sha\"},"
  done
  printf '{"stable":{"root_url":"https://example.invalid","files":{%s}}}' "${files%,}"
}

# write_formula <name> <stable version> <dependencies json> <bottle json>
write_formula() {
  printf '{"name":"%s","full_name":"%s","tap":"homebrew/core","desc":"","homepage":"","revision":0,"keg_only":false,"post_install_defined":false,"versions":{"stable":"%s"},"dependencies":%s,"oldnames":[],"bottle":%s}' \
    "$1" "$1" "$2" "$3" "$4" >"$MALT_CACHE/api/formula_$1.json"
}

SHA_FOO=$(printf 'a%.0s' {1..64})
SHA_BAR=$(printf 'b%.0s' {1..64})

# Run `install --dry-run foo`; fail unless it is refused and names bar.
expect_refused() {
  local label=$1 st=0
  "$BIN" install --dry-run foo >"$SB/log" 2>&1 || st=$?
  if [[ "$st" -eq 0 ]]; then
    cat "$SB/log" >&2
    fail "foo planned despite $label (exit 0)"
  fi
  grep -q 'dependency bar' "$SB/log" || {
    cat "$SB/log" >&2
    fail "the refusal for $label does not name the dependency bar"
  }
  # The dependency line is the whole story; a generic line would blame foo.
  if grep -q 'Failed to resolve foo' "$SB/log"; then
    cat "$SB/log" >&2
    fail "the refusal for $label is followed by a misleading generic line"
  fi
  pass "foo is refused when its dependency has $label"
}

write_formula foo 1.0 '["bar"]' "$(bottle_json foo "$SHA_FOO")"

# A control byte in the version is refused by the record parser.
write_formula bar '1.2\r' '[]' "$(bottle_json bar "$SHA_BAR")"
expect_refused "a refused record"

# No bottle for this platform is refused by bottle resolution.
write_formula bar 1.2 '[]' '{}'
expect_refused "no bottle"

# A parent with no bottle is refused before any of its dependencies is planned.
write_formula foo 1.0 '["bar"]' '{}'
write_formula bar 1.2 '[]' "$(bottle_json bar "$SHA_BAR")"
st=0
"$BIN" install --dry-run foo >"$SB/log" 2>&1 || st=$?
if [[ "$st" -eq 0 ]] || grep -q 'would install' "$SB/log"; then
  cat "$SB/log" >&2
  fail "a bottle-less foo still planned its dependencies (exit $st)"
fi
pass "a bottle-less parent plans none of its dependencies"
write_formula foo 1.0 '["bar"]' "$(bottle_json foo "$SHA_FOO")"

# Offline serves a cached record at any age, so a stale but valid dependency
# must still be planned rather than refused as unfetchable.
write_formula bar 1.2 '[]' "$(bottle_json bar "$SHA_BAR")"
touch -t 202001010000 "$MALT_CACHE"/api/formula_*.json
st=0
"$BIN" install --dry-run foo >"$SB/log" 2>&1 || st=$?
if [[ "$st" -ne 0 ]] || ! grep -q 'bar 1.2' "$SB/log"; then
  cat "$SB/log" >&2
  fail "offline install did not plan a stale cached dependency (exit $st)"
fi
pass "offline install plans a stale cached dependency"

# An installed dependency satisfies the graph whatever its record now says,
# so a refused upstream record must not block the parent.
write_formula bar '1.2\r' '[]' "$(bottle_json bar "$SHA_BAR")"
DB="$PREFIX/db/malt.db"
[[ -f "$DB" ]] || fail "no database after the earlier runs, so the keg cannot be seeded"
mkdir -p "$PREFIX/Cellar/bar/1.2" "$PREFIX/opt"
ln -s "$PREFIX/Cellar/bar/1.2" "$PREFIX/opt/bar"
sqlite3 "$DB" "INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path)
  VALUES ('bar', 'bar', '1.2', '$SHA_BAR', '$PREFIX/Cellar/bar/1.2');"
st=0
"$BIN" install --dry-run foo >"$SB/log" 2>&1 || st=$?
if [[ "$st" -ne 0 ]]; then
  cat "$SB/log" >&2
  fail "an installed dependency with a refused record blocked foo (exit $st)"
fi
pass "an installed dependency with a refused record still satisfies foo"
