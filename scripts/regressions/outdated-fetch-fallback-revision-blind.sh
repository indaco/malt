#!/usr/bin/env bash
# Regression: the per-keg fetch fallback in `mt outdated` compared the bare
# installed `kegs.version` against the upstream `versions.stable` (also bare),
# so an upstream revision-only bump (1.2.3 -> 1.2.3_1) was read as "up to date"
# and the package silently dropped from the audit. The bulk version-map path was
# already revision-aware; only the fallback (degraded map / tap packages) lagged.
#
# Hermetic: a throwaway prefix + a file-based API cache drive the fallback with
# an empty version side-car (forces per-keg fetch) and a formula JSON carrying a
# revision. Offline, so no network. Pre-fix the formula is absent from the
# listing; after the fix it appears with latest = 1.2.3_1.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.

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

PREFIX="$(mktemp -d)/p"
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$PREFIX/cache"
export MALT_OFFLINE=1 NO_COLOR=1 MALT_NO_EMOJI=1
trap 'rm -rf "$(dirname "$PREFIX")"' EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

mkdir -p "$PREFIX/db" "$MALT_CACHE/api"
DB="$PREFIX/db/malt.db"

# Initialise the schema.
"$BIN" list >/dev/null 2>&1 || true
[[ -f "$DB" ]] || fail "expected DB at $DB after schema init"

# Installed keg at bare 1.2.3 (revision 0).
sqlite3 "$DB" "INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path) \
  VALUES ('foo', 'foo', '1.2.3', 0, 'sha', '$PREFIX/Cellar/foo/1.2.3');"

# Empty version side-car forces the per-keg fetch fallback; the JSON keeps the
# same stable but bumps the revision to 1.
: >"$MALT_CACHE/api/versions_formula.txt"
printf '{"name":"foo","versions":{"stable":"1.2.3"},"revision":1}' >"$MALT_CACHE/api/formula_foo.json"

OUT="$PREFIX/out.json"
"$BIN" outdated --formula --refresh --json >"$OUT" 2>"$PREFIX/err.log" || true

grep -q '"foo"' "$OUT" ||
  fail "fetch fallback dropped the revision-bumped formula (bare-vs-bare compare)"
grep -q '1.2.3_1' "$OUT" ||
  fail "fetch fallback did not report the revision-qualified upstream version"
pass "fetch fallback lists the revision-bumped formula (latest 1.2.3_1)"

printf '\n\xe2\x9c\x94 outdated fetch-fallback revision regression passed\n'
