#!/usr/bin/env bash
# Regression: a tap-installed keg must come back from its own tap. `mt backup`
# used to write tap kegs by their bare name, so `mt restore` looked them up in
# homebrew/core; `mt reinstall` matched only the bare name and forwarded it
# unchanged, so the full slug reported "not installed" and the bare name went
# to core.
#
# Seeds tap rows into a throwaway prefix, then checks the backup lines and that
# reinstall, by either name, routes to the owning tap. The reinstall itself is
# expected to fail; only its routing is asserted. The tap is pinned in the DB,
# so no HEAD lookup runs, and MALT_OFFLINE refuses the recipe fetch: nothing
# reaches the forge. MALT_APPDIR keeps any cask placement inside the tmp tree.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"

# The shell harness runs the built binary; `zig build test` does not refresh
# it, so a stale binary would mask the fix.
zig build >/dev/null

command -v sqlite3 >/dev/null 2>&1 || {
  echo "this regression needs sqlite3 on PATH" >&2
  exit 2
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/Applications"
export NO_COLOR=1 MALT_NO_EMOJI=1 MALT_OFFLINE=1 MALT_APPDIR="$tmp/Applications"

fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

P="$tmp/prefix"
mkdir -p "$P/db" "$P/Cellar"
export MALT_PREFIX="$P"
# A first backup materialises the schema so the seed rows have tables.
"$BIN" backup -o - >/dev/null 2>&1
sha=$(printf '0%.0s' {1..40})
sqlite3 "$P/db/malt.db" "
  INSERT INTO taps (name, url, github_owner, github_repo, host, commit_sha) VALUES
    ('acme/tools', 'https://github.com/acme/homebrew-tools', 'acme', 'homebrew-tools', 'github.com', '$sha');
  INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, tap, install_reason, tap_rb_subtree) VALUES
    ('foo', 'acme/tools/foo', '1.0', 'x', '$P/Cellar/foo/1.0', 'acme/tools', 'direct', 'formula'),
    ('bar', 'acme/tools/bar', '1.0', 'y', '$P/Cellar/bar/1.0', 'acme/tools', 'direct', 'cask'),
    ('wget', 'wget', '1.0', 'z', '$P/Cellar/wget/1.0', 'homebrew/core', 'direct', NULL),
    ('lx', '/src/my dir/lx.rb', '1.0', 'w', '$P/Cellar/lx/1.0', 'local', 'direct', NULL);
  INSERT INTO casks (token, name, version, url, tap) VALUES
    ('baz', 'Baz', '1.0', 'https://x/baz.dmg', 'acme/tools');"

"$BIN" backup -o "$tmp/b.txt" >/dev/null 2>&1 || fail "mt backup failed on the seeded prefix"
grep -qx 'formula acme/tools/foo' "$tmp/b.txt" || fail "tap keg not qualified in backup"
grep -qx 'cask acme/tools/bar' "$tmp/b.txt" || fail "Casks-sourced tap keg not routed via cask"
grep -qx 'formula wget' "$tmp/b.txt" || fail "core keg lost its bare name"
json=$("$BIN" backup --json -o - 2>/dev/null)
grep -q '"name":"foo","version":"1.0","tap":"acme/tools"' <<<"$json" ||
  fail "backup --json dropped the formula's tap"
grep -q '"name":"wget","version":"1.0","tap":""' <<<"$json" ||
  fail "backup --json reported a tap for a core formula"

for pair in acme/tools/foo:foo foo:foo bar:bar acme/tools/baz:baz baz:baz; do
  arg=${pair%%:*}
  out=$("$BIN" reinstall "$arg" 2>&1 || true)
  grep -q "Resolving tap acme/tools/${pair#*:}" <<<"$out" ||
    fail "reinstall $arg did not route to its tap: $(head -1 <<<"$out")"
  if grep -q 'HEAD commit' <<<"$out"; then fail "reinstall $arg looked the tap up on the forge"; fi
done

# One install run pins one tap and side, so a tap package can't share it.
if "$BIN" reinstall foo wget >"$tmp/multi" 2>&1; then fail "reinstall foo wget succeeded"; fi
grep -q 'one at a time' "$tmp/multi" || fail "mixed reinstall not refused: $(head -1 "$tmp/multi")"

# A local keg is refused with a pasteable command, never re-run from its path.
if "$BIN" reinstall lx >"$tmp/local" 2>&1; then fail "reinstall of a local keg succeeded"; fi
grep -qF "mt install --local --force '/src/my dir/lx.rb'" "$tmp/local" ||
  fail "local keg hint missing or unquoted: $(head -1 "$tmp/local")"

printf '  ✓ tap kegs back up and reinstall by their owning tap\n'
