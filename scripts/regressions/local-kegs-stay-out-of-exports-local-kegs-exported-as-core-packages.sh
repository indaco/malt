#!/usr/bin/env bash
# Regression: a `--local` keg must never be exported as an installable core
# package, and bundle cleanup must never plan to remove it.
#
#   - `bundle export`/`bundle create` wrote it as `brew "<name>"`;
#   - `bundle export --format json` listed it under formulas;
#   - `backup --json` listed it under formulas with an empty tap, which is
#     byte-for-byte a core formula, and dropped its recipe path;
#   - dropping the Brewfile line alone would let `bundle cleanup` uninstall it.
#
# Offline throughout: MALT_OFFLINE refuses every fetch.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"

# `zig build test` does not refresh the binary; a stale one would mask the fix.
zig build >/dev/null

for tool in sqlite3 jq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "this regression needs $tool on PATH" >&2
    exit 2
  }
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# A developer shell's MALT_* must not point the run at a real prefix or cache.
while IFS='=' read -r var _; do unset "$var"; done < <(env | grep '^MALT_' || true)
export NO_COLOR=1 MALT_NO_EMOJI=1 MALT_OFFLINE=1 MALT_PREFIX="$tmp/prefix"
mkdir -p "$MALT_PREFIX"

fail() {
  printf '  ✗ [%s] %s\n' "$1" "$2" >&2
  exit 1
}

# A first export materialises the schema so the seed rows have tables.
"$BIN" bundle export >/dev/null 2>&1
sqlite3 "$MALT_PREFIX/db/malt.db" "
  INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, install_reason, tap) VALUES
    ('lx', '/src/lx.rb', '1.0', 'f', '/c/lx', 'direct', 'local'),
    ('wget', 'wget', '1.24', 'c', '/c/wget', 'direct', 'homebrew/core');"

out=$("$BIN" bundle export 2>/dev/null)
grep -q '"lx"' <<<"$out" && fail brewfile "local keg exported as a brew line"
grep -q '^brew "wget"' <<<"$out" || fail brewfile "core keg missing: $out"

"$BIN" bundle export --format json 2>/dev/null |
  jq -e '([.formulas[].name] | index("lx")) == null' >/dev/null ||
  fail bundle-json "local keg listed under formulas"

j=$("$BIN" backup --json 2>/dev/null)
jq -e '([.formulas[].name] | index("lx")) == null' <<<"$j" >/dev/null ||
  fail backup-json "local keg listed as a core formula: $j"
jq -e '[.formulas[].name] == ["wget"]' <<<"$j" >/dev/null ||
  fail backup-json "core keg missing: $j"
jq -e '.local == [{"name":"lx","version":"1.0","path":"/src/lx.rb"}]' <<<"$j" >/dev/null ||
  fail backup-json "local entry or recipe path missing: $j"

"$BIN" bundle create "$tmp/Brewfile" >/dev/null 2>&1
plan=$("$BIN" bundle cleanup --dry-run "$tmp/Brewfile" 2>&1 || true)
grep -q -- '- lx' <<<"$plan" && fail cleanup "local keg planned for removal: $plan"

# An explicitly empty Brewfile owns nothing, so it must not reach a local keg.
: >"$tmp/Empty"
plan=$("$BIN" bundle cleanup --dry-run "$tmp/Empty" 2>&1 || true)
grep -q -- '- lx' <<<"$plan" && fail cleanup "local keg planned for removal by an empty Brewfile: $plan"
grep -q -- '- wget' <<<"$plan" || fail cleanup "core keg absent from the empty-Brewfile plan (over-filtered): $plan"

echo "OK"
