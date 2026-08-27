#!/usr/bin/env bash
# Regression: `mt outdated` resolves a tap-installed formula's latest
# version against the owning tap, not the core Homebrew API.
#
# Pre-fix, the formula side of `mt outdated` always took the bulk
# version-map path (`isCorePathRow` was unconditionally true for
# formulae). The core dump is Homebrew-core only, so a third-party-tap
# formula missed the map and was silently dropped from the audit. The
# fix routes non-core-tap formulae through the tap HEAD, fetching the
# tap's `Formula/<name>.rb` (with a root-layout fallback) and parsing
# the version field — mirroring the tap-cask path.
#
# This script:
#   1. Registers a stable third-party tap (hashicorp/tap).
#   2. Seeds a `terraform` keg from that tap, marked installed at
#      `0.0.0` — well below any version the tap will ever ship.
#   3. Runs `mt outdated` and asserts the formula appears as outdated
#      with the tampered installed version and a real tap latest.
#
# Seeding (rather than a full `mt install`) keeps the test fast and
# isolates the outdated resolution path; the tap registration is real.
#
# Usage: scripts/regressions/outdated_tap_formula.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt, sqlite3
# on PATH, network access.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}
command -v sqlite3 >/dev/null 2>&1 || {
  echo "this regression needs sqlite3 on PATH" >&2
  exit 2
}

PREFIX=$(mktemp -d /tmp/mt.XXX)
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
mkdir -p "$PREFIX/db"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
skip() { printf '  - %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

TAP="hashicorp/tap"
NAME="terraform"

# Initialise the schema.
"$BIN" list >/dev/null 2>&1 || true

TAP_LOG="$PREFIX/tap.log"
printf '\xe2\x96\xb8 mt tap %s (logs \xe2\x86\x92 %s)\n' "$TAP" "$TAP_LOG"
if ! "$BIN" tap "$TAP" >"$TAP_LOG" 2>&1; then
  if grep -qE "rate limit|Network failure|Could not resolve|timed out" "$TAP_LOG"; then
    skip "${TAP}: tap registration hit a classified network condition; cannot exercise outdated"
    exit 0
  fi
  tail -20 "$TAP_LOG" >&2
  fail "${TAP}: tap registration failed for an unclassified reason"
fi
pass "${TAP}: registered"

DB="$PREFIX/db/malt.db"
[[ -f "$DB" ]] || fail "expected DB at $DB after tap"

# Seed the keg from the tap at an impossibly-old version.
sqlite3 "$DB" "INSERT INTO kegs (name, full_name, version, revision, tap, store_sha256, cellar_path) \
  VALUES ('${NAME}', '${TAP}/${NAME}', '0.0.0', 0, '${TAP}', 'sha', '${PREFIX}/Cellar/${NAME}/0.0.0');"
seeded=$(sqlite3 "$DB" "SELECT version FROM kegs WHERE name='${NAME}';")
[[ "$seeded" == "0.0.0" ]] || fail "${NAME}: failed to seed keg at 0.0.0 (got '${seeded}')"
pass "${NAME}: seeded tap keg at installed=0.0.0"

OUT_LOG="$PREFIX/outdated.log"
printf '\xe2\x96\xb8 mt outdated (expect tap-routed audit, logs \xe2\x86\x92 %s)\n' "$OUT_LOG"
"$BIN" outdated >"$OUT_LOG" 2>&1 || true

if grep -qE "rate limit|Network failure|Could not resolve" "$OUT_LOG"; then
  skip "outdated hit a classified network condition; cannot assert tap routing"
  exit 0
fi

# Assertion 1: the formula is listed.
if ! grep -q "${NAME}" "$OUT_LOG"; then
  tail -20 "$OUT_LOG" >&2
  fail "${NAME}: tap-formula outdated audit did not list the formula"
fi
pass "${NAME}: outdated reported the tap formula"

# Assertion 2: tampered installed version surfaces.
if ! grep -qE "${NAME}.*0\.0\.0" "$OUT_LOG"; then
  tail -20 "$OUT_LOG" >&2
  fail "${NAME}: outdated did not report the seeded installed version"
fi
pass "${NAME}: outdated reported installed=0.0.0"

# Assertion 3: it must not collapse to the up-to-date branch (the pre-fix
# failure mode — the tap formula was silently dropped from the map path).
if grep -q "All packages are up to date" "$OUT_LOG"; then
  tail -20 "$OUT_LOG" >&2
  fail "${NAME}: outdated silently classified the tap formula as up to date"
fi
pass "${NAME}: outdated did not collapse to the up-to-date branch"

printf '\n\xe2\x9c\x94 outdated tap-formula regression passed\n'
