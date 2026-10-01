#!/usr/bin/env bash
# Regression: `bundle create`, `install` and `cleanup` must refuse a second
# path instead of silently using only the last one. `create a b` used to write
# b alone, and `cleanup base work` planned removals against work alone.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network; all state lives under a throwaway prefix removed on EXIT.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"

# The shell harness runs the built binary; `zig build test` does not refresh
# it, so a stale binary would mask the fix.
zig build >/dev/null

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export NO_COLOR=1 MALT_NO_EMOJI=1
export MALT_PREFIX="$tmp/p" MALT_CACHE="$tmp/cache"
mkdir -p "$MALT_PREFIX" "$MALT_CACHE"

fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

rc=0
out=$("$BIN" bundle create "$tmp/a" "$tmp/c" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "create took the last of two paths and exited 0: $out"
grep -q "expected at most one \[path\]" <<<"$out" || fail "create did not say why: $out"
if [ -e "$tmp/a" ] || [ -e "$tmp/c" ]; then
  fail "create wrote a file despite two paths"
fi

# --yes and a closed stdin keep a pre-fix cleanup from blocking on the confirm.
echo '# empty' >"$tmp/b"
for sub in install "cleanup --yes"; do
  rc=0
  # shellcheck disable=SC2086 # $sub carries cleanup's extra flag
  out=$("$BIN" bundle $sub -n "$tmp/a" "$tmp/b" 2>&1 </dev/null) || rc=$?
  [ "$rc" -ne 0 ] || fail "$sub took the last of two paths and exited 0: $out"
  grep -q "expected at most one \[file\]" <<<"$out" || fail "$sub did not say why: $out"
done

echo "  ✓ bundle create, install and cleanup refuse a second path"
