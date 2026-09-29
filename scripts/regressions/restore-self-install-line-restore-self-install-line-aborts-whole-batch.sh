#!/usr/bin/env bash
# Regression: a shared or hand-edited backup line naming malt itself
# (`mt`, `acme/tools/mt`, `malt.rb`) must be named and left out of a restore.
# Install refuses a self-install name for the whole package list, so one such
# line used to take every other formula (or cask) in the file down with it.
#
# Offline throughout: MALT_OFFLINE refuses every fetch, so the remaining
# packages fail with a "not cached" error - proof install was reached.
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

printf '%s\n' 'formula acme/tools/mt' 'formula wget' 'cask malt.rb' 'cask firefox' >"$tmp/b.txt"
# Offline, wget and firefox fail too; the exit code is not the signal.
out=$("$BIN" restore "$tmp/b.txt" 2>&1) || true

grep -q 'Refusing to install malt itself' <<<"$out" && fail "a self-install line aborted its restore batch:"$'\n'"$out"
n=$(grep -c 'restore never installs malt itself' <<<"$out" || true)
[ "$n" -eq 2 ] || fail "expected 2 skip warnings, got $n:"$'\n'"$out"
grep -qF "formula 'wget' not cached" <<<"$out" || fail "wget was never attempted:"$'\n'"$out"
grep -qF 'Failed to install firefox' <<<"$out" || fail "firefox was never attempted:"$'\n'"$out"
grep -qF 'Restoring 1 formula(e), 1 cask(s)' <<<"$out" || fail "counts include skipped lines:"$'\n'"$out"

printf '  ✓ restore skips backup lines naming malt itself\n'
