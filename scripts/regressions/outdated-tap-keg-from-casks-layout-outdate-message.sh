#!/usr/bin/env bash
# Regression: `mt outdated` verifies a tap keg whose `.rb` lives under
# the tap's `Casks/` subtree.
#
# `mt install <tap>/<name>` probes `Formula/`, then `Casks/`, then the
# repo root, and materialises a `Casks/<name>.rb` whose artifact is a
# plain tarball (the goreleaser `homebrew_casks` shape) as a keg. The
# outdated audit's formula leg only probed `Formula/` and the root, so
# every such keg 404'd on every run: never listed as outdated, the
# audit reported `"complete":false`, the snapshot was never warmed, and
# the TUI blamed the network for a deterministic layout miss.
#
# This script:
#   1. Registers a tap that ships `Casks/<name>.rb` and no `Formula/`.
#   2. Seeds a keg from that tap, marked installed at `0.0.0`.
#   3. Runs `mt outdated --refresh --json` and asserts the audit is
#      complete and lists the keg — no 404 on the `.rb`.
#
# Seeding (rather than a full `mt install`) isolates the audit's probe
# order; the tap registration is real.
#
# Usage: scripts/regressions/outdated-tap-keg-from-casks-layout-outdate-message.sh
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

TAP="caarlos0/tap"
NAME="prowl"

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

# The guard only means something while upstream still ships the keg under
# `Casks/` and nowhere else; otherwise skip rather than pass vacuously or
# blame the audit for an upstream layout change.
RAW="https://raw.githubusercontent.com/${TAP%/*}/homebrew-${TAP#*/}/HEAD"
http_status() { curl -s -o /dev/null -w '%{http_code}' "$1" || echo 000; }
if [[ "$(http_status "$RAW/Casks/${NAME}.rb")" != "200" ]]; then
  skip "${TAP}: Casks/${NAME}.rb no longer served upstream; cannot exercise the Casks/ probe"
  exit 0
fi
if [[ "$(http_status "$RAW/Formula/${NAME}.rb")" == "200" ]]; then
  skip "${TAP}: Formula/${NAME}.rb now exists upstream; the Casks/ probe would never be reached"
  exit 0
fi
pass "${NAME}: upstream still ships Casks/${NAME}.rb only"

DB="$PREFIX/db/malt.db"
[[ -f "$DB" ]] || fail "expected DB at $DB after tap"

# Seed the keg from the tap at an impossibly-old version.
sqlite3 "$DB" "INSERT INTO kegs (name, full_name, version, revision, tap, store_sha256, cellar_path) \
  VALUES ('${NAME}', '${TAP}/${NAME}', '0.0.0', 0, '${TAP}', 'sha', '${PREFIX}/Cellar/${NAME}/0.0.0');"
seeded=$(sqlite3 "$DB" "SELECT version FROM kegs WHERE name='${NAME}';")
[[ "$seeded" == "0.0.0" ]] || fail "${NAME}: failed to seed keg at 0.0.0 (got '${seeded}')"
pass "${NAME}: seeded Casks/-layout tap keg at installed=0.0.0"

OUT_JSON="$PREFIX/outdated.json"
ERR_LOG="$PREFIX/outdated.err"
printf '\xe2\x96\xb8 mt outdated --refresh --json (logs \xe2\x86\x92 %s)\n' "$ERR_LOG"
rc=0
"$BIN" outdated --refresh --json >"$OUT_JSON" 2>"$ERR_LOG" || rc=$?
[[ $rc -eq 0 ]] || {
  tail -20 "$ERR_LOG" >&2
  fail "outdated exited $rc"
}

if grep -qE "rate limit|Network failure|Could not resolve" "$ERR_LOG"; then
  skip "outdated hit a classified network condition; cannot assert the Casks/ probe"
  exit 0
fi

# Assertion 1: the audit must not 404 on the `.rb` — a 404 here is the
# bug (formula leg never asked for `Casks/`), never a network condition.
if grep -q 'status 404 for the .rb' "$ERR_LOG"; then
  tail -20 "$ERR_LOG" >&2
  fail "${NAME}: audit still 404s on Casks/${NAME}.rb (formula leg never probes Casks/)"
fi
pass "${NAME}: audit resolved the .rb"

# Assertion 2: the audit is complete, so the snapshot can be warmed.
if grep -q '"complete":false' "$OUT_JSON"; then
  cat "$OUT_JSON" >&2
  fail "${NAME}: audit reported incomplete"
fi
pass "audit reported complete"

# Assertion 3: the keg is listed with the seeded installed version.
grep -q "\"name\":\"${NAME}\"" "$OUT_JSON" || {
  cat "$OUT_JSON" >&2
  fail "${NAME}: not listed as outdated"
}
grep -q '"installed":"0.0.0"' "$OUT_JSON" || {
  cat "$OUT_JSON" >&2
  fail "${NAME}: seeded installed version not echoed"
}
pass "${NAME}: listed as outdated with installed=0.0.0"

printf '\n\xe2\x9c\x94 Casks/-layout tap keg verified and listed\n'
