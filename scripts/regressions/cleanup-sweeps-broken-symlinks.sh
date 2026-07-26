#!/usr/bin/env bash
# Regression: `mt doctor` reports broken symlinks with "Run: mt cleanup", but
# cleanup had no symlink sweep at all - only `mt doctor --fix broken_symlinks`
# removed them, so following the advice left the prefix exactly as it was.
#
# The sweep also used its own copy of the link-dir list, which had lost `etc`,
# and it never descended past the top level of each dir. Since the linker
# mirrors keg trees, most links live deeper: share/man/man1, lib/pkgconfig,
# share/locale/<lang>/LC_MESSAGES.
#
# Plants dangling links at the top level, nested, and under etc/, plus a live
# link beside each that must survive. No network required.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

PREFIX="$(mktemp -d)/malt-prefix"
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1 MALT_NO_EMOJI=1
trap 'rm -rf "$(dirname "$PREFIX")"' EXIT

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

mkdir -p "$PREFIX/db" "$PREFIX/cache"
: >"$PREFIX/anchor"

# One dangling link and one live link in each location.
planted=("bin" "share/man/man1" "lib/pkgconfig" "etc")
for sub in "${planted[@]}"; do
  mkdir -p "$PREFIX/$sub"
  ln -s "/malt-regression-target-that-does-not-exist" "$PREFIX/$sub/dead"
  ln -s "$PREFIX/anchor" "$PREFIX/$sub/alive"
done

# Dry run must report without removing, so the advice can be previewed.
"$BIN" cleanup --dry-run --yes >/dev/null 2>&1 || true
for sub in "${planted[@]}"; do
  [[ -L "$PREFIX/$sub/dead" ]] ||
    fail "--dry-run removed $sub/dead; preview must not mutate the prefix"
done
pass "--dry-run left every planted link in place"

"$BIN" cleanup --yes >/dev/null 2>&1 || true

for sub in "${planted[@]}"; do
  [[ -L "$PREFIX/$sub/dead" ]] &&
    fail "cleanup left the broken symlink at $sub/dead"
  [[ -L "$PREFIX/$sub/alive" ]] ||
    fail "cleanup removed the live symlink at $sub/alive"
  pass "$sub: broken link swept, live link kept"
done

printf '\n✔ cleanup broken-symlink sweep regression passed\n'
