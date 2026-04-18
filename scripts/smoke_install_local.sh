#!/usr/bin/env bash
# Smoke test for `malt install --local`.
#
# Builds two fixture .rb formulae under scripts/fixtures/local_formulae/
# (one bottle-style, one GoReleaser-style) and exercises the dispatch,
# dry-run, autodetection, and negative paths. Hermetic — every run
# uses a throwaway MALT_PREFIX and no download ever executes.
#
# Usage: scripts/smoke_install_local.sh
# Requirements: built `malt` binary at $MALT_BIN or zig-out/bin/malt.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

FIX_DIR="$ROOT/scripts/fixtures/local_formulae"
[[ -d "$FIX_DIR" ]] || {
  echo "missing fixtures at $FIX_DIR" >&2
  exit 2
}

# MALT_PREFIX must be ≤ 13 bytes (Mach-O in-place patching budget).
PREFIX="/tmp/mt_smoke"
export MALT_PREFIX="$PREFIX"
rm -rf "$PREFIX"
mkdir -p "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# ── 1. --local + dry-run prints the expected plan ────────────────────
printf '▸ malt install --local --dry-run <fixture.rb>\n'
out=$("$BIN" install --local --dry-run "$FIX_DIR/hello.rb" 2>&1)
echo "$out" | grep -q "Installing from local file" || fail "missing security warning"
echo "$out" | grep -q "Found hello 1.2.3" || fail "missing 'Found hello 1.2.3'"
echo "$out" | grep -q "Dry run: would install" || fail "missing dry-run plan"
pass "hello.rb dry-run flow"

# ── 2. shape-based autodetect fires without --local ──────────────────
printf '▸ malt install --dry-run <fixture.rb> (autodetect)\n'
out=$("$BIN" install --dry-run "$FIX_DIR/hello.rb" 2>&1)
echo "$out" | grep -q "Installing from local file" || fail "autodetect should print the warning"
echo "$out" | grep -q "Found hello 1.2.3" || fail "autodetect should resolve version"
pass "autodetect branch fires"

# ── 3. --local with a missing path reports cleanly ───────────────────
printf '▸ malt install --local /tmp/does_not_exist.rb\n'
out=$("$BIN" install --local --dry-run /tmp/mt_smoke_missing.rb 2>&1 || true)
echo "$out" | grep -q "Cannot open local formula" || fail "missing-file error not surfaced"
pass "missing file is rejected"

# ── 4. --local with a malformed .rb is rejected cleanly ──────────────
printf '▸ malt install --local <malformed.rb>\n'
out=$("$BIN" install --local --dry-run "$FIX_DIR/broken.rb" 2>&1 || true)
echo "$out" | grep -q "Cannot parse local formula" || fail "parse error not surfaced"
pass "malformed file is rejected"

# ── 5. bare --local without a path is an error ───────────────────────
printf '▸ malt install --local (no operand)\n'
if "$BIN" install --local 2>/dev/null; then
  fail "bare --local should exit non-zero"
fi
pass "bare --local errors out"

# ── 6. help text advertises the flag ─────────────────────────────────
printf '▸ malt install --help lists --local\n'
"$BIN" install --help | grep -q -- "--local" || fail "--local missing from install help"
pass "help text documents --local"

# ── 7. non-https archive URL is refused ──────────────────────────────
printf '▸ malt install --local <plain-http.rb>\n'
# Not --dry-run: the URL check fires in materializeRubyFormula, which
# dry-run short-circuits past. The binary must still exit non-zero,
# have printed "Refusing to fetch non-HTTPS", and never hit the network.
out=$("$BIN" install --local "$FIX_DIR/insecure.rb" 2>&1 || true)
echo "$out" | grep -q "Refusing to fetch non-HTTPS" || fail "plain http was not refused"
pass "non-https archive URL is rejected"

# ── 8. mutually exclusive flag combinations ──────────────────────────
printf '▸ malt install --local --cask (refused)\n'
if "$BIN" install --local --cask "$FIX_DIR/hello.rb" 2>/dev/null; then
  fail "--local --cask should exit non-zero"
fi
pass "--local --cask is refused"

printf '▸ malt install --local --use-system-ruby (refused)\n'
if "$BIN" install --local --use-system-ruby "$FIX_DIR/hello.rb" 2>/dev/null; then
  fail "--local --use-system-ruby should exit non-zero"
fi
pass "--local --use-system-ruby is refused"

printf '\n✔ local-install smoke test passed\n'
