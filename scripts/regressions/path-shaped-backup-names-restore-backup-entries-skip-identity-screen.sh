#!/usr/bin/env bash
# Regression: a shared or hand-edited backup line whose name is path-shaped
# (`..`, `../../etc`, `a/b/c.rb`) must be named and left out of a restore,
# not listed in the preview and handed to install, which resolved `../..` as
# a tap over the network and ran a `.rb` name as a local recipe. A
# `user/repo/name` tap slug is a real name.
#
# Offline throughout: `--dry-run` returns before install, and MALT_OFFLINE
# refuses every fetch anyway.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"

# `zig build test` does not refresh the binary; a stale one would mask the fix.
zig build >/dev/null

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# A developer shell's MALT_* must not point the run at a real prefix or cache.
while IFS='=' read -r var _; do unset "$var"; done < <(env | grep '^MALT_' || true)
export NO_COLOR=1 MALT_NO_EMOJI=1 MALT_OFFLINE=1 MALT_PREFIX="$tmp/p"
mkdir -p "$tmp/p"

fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

printf '%s\n' 'formula ../../etc' 'formula a/b/../../x' 'cask ..' 'service ..' \
  'cask a/b/c.rb' 'formula acme/tools/foo' 'formula postgresql@16 16.4' >"$tmp/b.txt"
out=$("$BIN" restore --dry-run "$tmp/b.txt" 2>&1) || fail "restore --dry-run failed: $out"

# Preview lines end in the entry; a skip warning quotes it in backticks.
for bad in 'formula +\.\./\.\./etc' 'formula +a/b/\.\./\.\./x' '(cask|service) +\.\.' 'cask +a/b/c\.rb'; do
  grep -qE "(^|[[:space:]])$bad\$" <<<"$out" && fail "preview lists a path-shaped name ($bad)"
done
n=$(grep -c 'does not name a package' <<<"$out" || true)
[ "$n" -eq 5 ] || fail "expected 5 skip warnings, got $n:"$'\n'"$out"
grep -qE ' formula +acme/tools/foo$' <<<"$out" || fail "a tap slug was dropped"
grep -qE ' formula +postgresql@16 \(16\.4\)$' <<<"$out" || fail "a versioned name was dropped"
grep -qF 'Restoring 2 formula(e), 0 cask(s) and 0 service(s)' <<<"$out" || fail "counts include skipped lines:"$'\n'"$out"

printf '  ✓ restore skips backup entries that do not name a package\n'
