#!/usr/bin/env bash
# Smoke test for revisioned formulas (issue #77).
#
# Revisioned formulas (Homebrew `revision: 1` onwards) must land at
# `Cellar/<name>/<version>_<revision>` because bottles bake that path
# into LC_LOAD_DYLIB entries. Plain `<version>` produces dyld errors
# at runtime. This script installs one end-to-end and verifies both
# the on-disk layout AND that the installed binary actually loads.
#
# Usage: scripts/smoke_install_revisioned.sh
# Requirements: built `malt` binary at $MALT_BIN or zig-out/bin/malt,
# network access to ghcr.io / formulae.brew.sh.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

# MALT_PREFIX must be ≤ 13 bytes (Mach-O in-place patching budget).
PREFIX="/tmp/mt_rev"
export MALT_PREFIX="$PREFIX"
rm -rf "$PREFIX"
mkdir -p "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# ── Helper: pull revision + version straight from the live API ───────
get_rev() {
  local name="$1"
  curl -fsSL "https://formulae.brew.sh/api/formula/${name//@/%40}.json" |
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('revision',0))"
}
get_ver() {
  local name="$1"
  curl -fsSL "https://formulae.brew.sh/api/formula/${name//@/%40}.json" |
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d['versions']['stable'])"
}

TARGET="${TARGET:-pcre2}" # overrideable if the caller knows a better candidate
REV=$(get_rev "$TARGET")
VER=$(get_ver "$TARGET")

if [[ "$REV" == "0" ]]; then
  printf '▸ skipping: %s currently has revision 0 — rerun once a revision bump lands\n' "$TARGET"
  exit 0
fi

PKGVER="${VER}_${REV}"
printf '▸ target: %s  (version=%s  revision=%s  ⇒ Cellar dir = %s)\n' "$TARGET" "$VER" "$REV" "$PKGVER"

# ── 1. Install end-to-end ────────────────────────────────────────────
printf '▸ malt install %s\n' "$TARGET"
"$BIN" install --quiet "$TARGET" || fail "install of $TARGET failed"
pass "installed $TARGET"

# ── 2. Cellar path carries the _<revision> suffix ────────────────────
printf '▸ cellar dir exists at Cellar/%s/%s\n' "$TARGET" "$PKGVER"
[[ -d "$PREFIX/Cellar/$TARGET/$PKGVER" ]] ||
  fail "expected Cellar/$TARGET/$PKGVER to exist, got: $(ls -1 "$PREFIX/Cellar/$TARGET" 2>/dev/null || echo '(missing)')"
pass "on-disk path is Cellar/$TARGET/$PKGVER"

# Negative: the plain-version dir must NOT exist.
[[ ! -d "$PREFIX/Cellar/$TARGET/$VER" ]] ||
  fail "plain Cellar/$TARGET/$VER was also created — the fix did not take effect"
pass "plain Cellar/$TARGET/$VER absent (no stale dir)"

# ── 3. opt/<name> symlink resolves to the correct dir ────────────────
if [[ -L "$PREFIX/opt/$TARGET" ]]; then
  LINK_TARGET=$(readlink "$PREFIX/opt/$TARGET")
  [[ "$LINK_TARGET" == *"/$PKGVER" ]] ||
    fail "opt/$TARGET points at $LINK_TARGET (expected …/$PKGVER)"
  pass "opt/$TARGET → …/$PKGVER"
fi

# ── 4. Installed dylib is dyld-loadable (the bug from issue #77) ─────
# `otool -L` walks the LC_LOAD_DYLIB chain and will error if any
# referenced library can't be located. This is the exact failure the
# user hit when running `tig`.
# Walk every real dylib (not symlink) and resolve its LC_LOAD_DYLIB
# chain against the installed prefix. Any missing path = dyld would
# abort at runtime, which is exactly the bug from issue #77.
LIB_DIR="$PREFIX/Cellar/$TARGET/$PKGVER/lib"
if [[ -d "$LIB_DIR" ]]; then
  checked=0
  while IFS= read -r dylib; do
    # Extract every absolute LC_LOAD_DYLIB reference under $PREFIX
    # and stat them.
    # `otool -L`'s first line is the file itself (trailing colon);
    # indented lines are the actual LC_LOAD_DYLIB entries. Grab only
    # the indented ones, strip `(compat …)` suffix.
    while IFS= read -r dep; do
      [[ -e "$dep" ]] || fail "dyld would fail: $(basename "$dylib") references missing $dep"
    done < <(otool -L "$dylib" | awk -v p="$PREFIX" '/^\t/ && $1 ~ p"/" { print $1 }')
    checked=$((checked + 1))
  done < <(find "$LIB_DIR" -name '*.dylib' -type f 2>/dev/null)
  [[ "$checked" -gt 0 ]] && pass "all $checked dylib(s) resolve to real files under $PREFIX"
fi

# ── 5. info command shows the correct path ───────────────────────────
printf '▸ malt info %s\n' "$TARGET"
INFO_OUT=$("$BIN" info "$TARGET" 2>&1)
echo "$INFO_OUT" | grep -q "Cellar/$TARGET/$PKGVER" ||
  fail "mt info should surface the _<revision> path"
pass "mt info reports the revisioned path"

printf '\n✔ revisioned-install smoke test passed\n'
