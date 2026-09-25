#!/usr/bin/env bash
# Regression: every package a backup lists must round-trip back through
# restore, bundle and reinstall.
#
#   - a pinned backup line reached install as a literal `name@version`, so
#     every `--versions` backup and every wipe manifest restored nothing;
#   - a `--local` keg was written as a bare `formula <name>`, which restore
#     sent to core;
#   - `bundle create` wrote tap packages by bare name; the qualified lines
#     must still be cleanup members and install-skipped when present;
#   - `backup --json` listed a keg built from a tap's Casks/ under formulas;
#   - `reinstall <cask> <formula>` forwarded `--cask` to both;
#   - `reinstall <core cask>` exited 0 having done nothing.
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
mkdir -p "$tmp/Applications"
# A developer shell's MALT_* must not point the run at a real prefix or cache.
while IFS='=' read -r var _; do unset "$var"; done < <(env | grep '^MALT_' || true)
export NO_COLOR=1 MALT_NO_EMOJI=1 MALT_OFFLINE=1 MALT_APPDIR="$tmp/Applications"

fail() {
  printf '  ✗ [%s] %s\n' "$1" "$2" >&2
  exit 1
}

P="$tmp/prefix"
mkdir -p "$P/db" "$P/Cellar"/{foo,bar,lx,wget}
export MALT_PREFIX="$P"
# A first backup materialises the schema so the seed rows have tables.
"$BIN" backup -o - >/dev/null 2>&1
sqlite3 "$P/db/malt.db" "
  INSERT INTO taps (name, url) VALUES ('acme/tools', 'https://github.com/acme/homebrew-tools');
  INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, tap, tap_rb_subtree, install_reason) VALUES
    ('foo', 'acme/tools/foo', '1.0', 'x', '$P/Cellar/foo/1.0', 'acme/tools', 'formula', 'direct'),
    ('bar', 'acme/tools/bar', '2.0', 'y', '$P/Cellar/bar/2.0', 'acme/tools', 'cask', 'direct'),
    ('lx', '/src/lx.rb', '1.0', 'z', '$P/Cellar/lx/1.0', 'local', NULL, 'direct'),
    ('wget', 'wget', '1.24', 'w', '$P/Cellar/wget/1.24', NULL, NULL, 'direct');
  INSERT INTO casks (token, name, version, url, tap) VALUES
    ('firefox', 'firefox', '120.0', 'https://x.invalid/f.dmg', NULL),
    ('baz', 'Baz', '3.0', 'https://x.invalid/b.dmg', 'acme/tools');"

b=$("$BIN" backup --versions -o - 2>/dev/null)
grep -qx 'formula wget 1.24' <<<"$b" || fail versions "version is not a separate field"
printf '%s\n' "$b" >"$tmp/b.txt"
d=$("$BIN" restore --dry-run "$tmp/b.txt" 2>&1)
grep -q 'wget@' <<<"$d" && fail versions "restore forwards name@version: $d"
grep -q 'formula wget (1.24)' <<<"$d" || fail versions "dry-run hides the recorded version: $d"

grep -qx 'formula lx' <<<"$("$BIN" backup -o - 2>/dev/null)" && fail local "local keg written as an installable line"
grep -qx '# local lx /src/lx.rb' <<<"$b" || fail local "local note missing"
grep -q "mt install --local '/src/lx.rb'" <<<"$d" || fail local "restore does not point at the local rebuild: $d"

(cd "$P" && "$BIN" bundle create >/dev/null 2>&1)
grep -qx 'brew "acme/tools/foo"' "$P/Brewfile" || fail bundle "bundle writes the tap formula bare"
grep -qx 'cask "acme/tools/bar"' "$P/Brewfile" || fail bundle "Casks/-sourced keg not written as a cask"
grep -qx 'cask "acme/tools/baz"' "$P/Brewfile" || fail bundle "bundle writes the tap cask bare"
c=$(cd "$P" && "$BIN" bundle cleanup --dry-run 2>&1)
grep -Eq '^  - (foo|bar|baz)( |$)' <<<"$c" && fail bundle "cleanup would remove a listed tap package: $c"
# Members only: re-adding the tap offline is a separate concern. Offline,
# any member not recognised as installed fails its fetch.
grep -v '^tap ' "$P/Brewfile" >"$P/Members.Brewfile"
(cd "$P" && "$BIN" bundle install Members.Brewfile >/dev/null 2>&1) || fail bundle "warm bundle install refetched a listed package"

"$BIN" backup --json | jq -e '.casks[] | select(.name == "bar")' >/dev/null || fail json "bar not under casks"
"$BIN" backup --json | jq -e '.formulas[] | select(.name == "bar")' >/dev/null && fail json "bar still under formulas"

out=$("$BIN" reinstall firefox wget 2>&1) && fail reinstall-mix "mixed reinstall not refused"
grep -q 'separately' <<<"$out" || fail reinstall-mix "wrong refusal: $out"

out=$("$BIN" reinstall firefox 2>&1) && fail reinstall-cask "core cask reinstall exited 0"
grep -q 'mt uninstall --cask firefox' <<<"$out" || fail reinstall-cask "no uninstall + install hint: $out"

echo "OK: backups round-trip through restore, bundle and reinstall"
