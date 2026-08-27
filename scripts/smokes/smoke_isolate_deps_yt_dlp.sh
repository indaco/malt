#!/usr/bin/env bash
# scripts/smokes/smoke_isolate_deps_yt_dlp.sh
#
# Canonical-example smoke for the `--isolate-deps` contract.
#
# The feature is motivated by yt-dlp: a real-world formula whose
# runtime deps include `deno` and `python@3.14`. The PR's user-facing
# promise is "I asked for yt-dlp, I get yt-dlp in my PATH — not also
# deno and python3.14 just because yt-dlp needed them." This smoke
# drives that exact scenario against the live Homebrew API and asserts
# the contract end-to-end.
#
# Slower than `scripts/regressions/bin_isolation_basics.sh` (downloads
# python@3.14 + deno; ~5 min on a warm connection), so it lives under
# `smokes/` rather than `regressions/`.
#
# Assertions:
#   1. <prefix>/bin/yt-dlp present (user's named package lands in PATH).
#   2. <prefix>/bin/deno and <prefix>/bin/python3.14 absent (deps are
#      isolated).
#   3. <prefix>/opt/deno and <prefix>/opt/python@3.14 present (Mach-O
#      and rewritten-shebang dependents still resolve).
#   4. DB rows: yt-dlp is `direct, bin_isolated=0`; every transitive
#      dep is `dependency, bin_isolated=1`.
#   5. `links` table holds zero bin/sbin rows for any isolated dep.
#   6. `yt-dlp --version` runs cleanly — verifies the bottle-time
#      shebang rewriting that pins yt-dlp to its own Cellar's python
#      still works under isolation.
#
# Usage: scripts/smokes/smoke_isolate_deps_yt_dlp.sh
# Requirements: built `malt` binary, network to formulae.brew.sh + ghcr.io.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

PREFIX=$(mktemp -d /tmp/mt.XXX)
export MALT_PREFIX="$PREFIX"
mkdir -p "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

DB="$PREFIX/db/malt.db"
TARGET="yt-dlp"
ISOLATED_DEPS=("deno" "python@3.14" "certifi")

printf '▸ malt install --isolate-deps %s\n' "$TARGET"
"$BIN" install --quiet --isolate-deps "$TARGET" || fail "install --isolate-deps $TARGET failed"

[[ -f "$DB" ]] || fail "DB not created at $DB"

# ── 1. Named package's bin landed in <prefix>/bin ─────────────────
[[ -e "$PREFIX/bin/$TARGET" ]] || fail "$TARGET binary not linked into <prefix>/bin"
pass "<prefix>/bin/$TARGET present (named package in PATH)"

# ── 2. Each isolated dep's bin is *absent* from <prefix>/bin ──────
# Use the formula's bottled bin names; brew exposes deno as `deno`
# and python@3.14 as `python3.14` (the versioned name the formula
# installs into bin/).
for absent in "deno" "python3.14"; do
  if [[ -e "$PREFIX/bin/$absent" ]]; then
    fail "$absent leaked into <prefix>/bin under --isolate-deps"
  fi
  pass "<prefix>/bin/$absent absent (isolated dep hidden from PATH)"
done

# ── 3. opt/ anchors present so Mach-O + rewritten shebangs work ───
for dep in "${ISOLATED_DEPS[@]}"; do
  [[ -L "$PREFIX/opt/$dep" ]] || fail "opt/$dep anchor missing — dyld/shebang resolution would break"
  pass "opt/$dep anchor present"
done

# ── 4. DB rows confirm the recorded intent ────────────────────────
direct_target_isolated=$(sqlite3 "$DB" "SELECT bin_isolated FROM kegs WHERE name='$TARGET';")
[[ "$direct_target_isolated" == "0" ]] ||
  fail "$TARGET bin_isolated=$direct_target_isolated (expected 0 — user-named package stays direct)"
pass "$TARGET row: bin_isolated=0 (direct keg, kept in PATH)"

direct_target_reason=$(sqlite3 "$DB" "SELECT install_reason FROM kegs WHERE name='$TARGET';")
[[ "$direct_target_reason" == "direct" ]] ||
  fail "$TARGET install_reason=$direct_target_reason (expected direct)"
pass "$TARGET row: install_reason=direct"

for dep in "${ISOLATED_DEPS[@]}"; do
  dep_isolated=$(sqlite3 "$DB" "SELECT bin_isolated FROM kegs WHERE name='$dep';" 2>/dev/null || echo "")
  dep_reason=$(sqlite3 "$DB" "SELECT install_reason FROM kegs WHERE name='$dep';" 2>/dev/null || echo "")
  [[ "$dep_isolated" == "1" ]] || fail "$dep bin_isolated=$dep_isolated (expected 1)"
  [[ "$dep_reason" == "dependency" ]] ||
    fail "$dep install_reason=$dep_reason (expected dependency)"
  pass "$dep row: dependency + bin_isolated=1"
done

# ── 5. links table has zero bin/sbin rows for any isolated dep ────
for dep in "${ISOLATED_DEPS[@]}"; do
  bin_count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM links l JOIN kegs k ON l.keg_id=k.id WHERE k.name='$dep' AND (l.link_path LIKE '%/bin/%' OR l.link_path LIKE '%/sbin/%');" 2>/dev/null || echo "0")
  [[ "$bin_count" == "0" ]] ||
    fail "$dep has $bin_count bin/sbin link rows (expected 0)"
done
pass "links table holds zero bin/sbin rows for the isolated deps"

# ── 6. yt-dlp runs — exercises the bottle-time shebang rewriting ──
#    Bottle authors `inreplace` `#!/usr/bin/env python3` into a path
#    that anchors yt-dlp to its own Cellar interpreter. Under
#    isolation `<prefix>/bin/python3.14` is missing, but the
#    pinned path stays valid through `<prefix>/opt/python@3.14`.
out=$("$PREFIX/bin/$TARGET" --version 2>&1 | head -1)
[[ -n "$out" ]] || fail "$TARGET --version produced no output"
printf '  ✓ %s --version → %s\n' "$TARGET" "$out"

printf '\n✓ smoke_isolate_deps_yt_dlp: yt-dlp/deno/python3.14 contract holds\n'
