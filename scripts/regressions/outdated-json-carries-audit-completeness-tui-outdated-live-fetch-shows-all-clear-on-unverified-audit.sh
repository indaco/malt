#!/usr/bin/env bash
# Regression: `mt outdated --json` must say when the audit could not verify
# every keg. The TUI Outdated tab consumes that document with the child's
# stderr discarded, so a warning printed there never reaches it - an
# unverified audit that resolved nothing arrives as a well-formed empty
# array and the tab paints "Everything is up to date." over kegs it never
# checked. The root object carries `"complete":false` in that case; a
# complete audit stays byte-identical (no key).
#
# Hermetic: one seeded core keg, no network.
#
#   1. Offline + cold cache: the JSON root says the audit was incomplete.
#   2. The same audit under `--quiet` still prints the warning: quiet hides
#      the all-clear too, so a silent empty listing would read as "nothing
#      outdated".
#   3. Positive control: a complete audit lists the keg and emits no key.
#   4. The TUI parser reads the key (leaf module, std-only `zig test`).
#
# Usage: scripts/regressions/outdated-json-carries-audit-completeness-tui-outdated-live-fetch-shows-all-clear-on-unverified-audit.sh
# Requirements: a built malt binary at $MALT_BIN or zig-out/bin/malt, sqlite3, zig.
# No network access required.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

PREFIX=$(mktemp -d -t malt_outdated_json_complete.XXXXXX)
trap 'rm -rf "$PREFIX"' EXIT
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$PREFIX/cache"
unset MALT_OFFLINE MALT_OUTDATED_MAX_AGE NO_COLOR CI

DB="$PREFIX/db/malt.db"
API="$MALT_CACHE/api"

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

# `mt list` migrates the schema only when db/ exists.
mkdir -p "$PREFIX/db" "$API"
"$BIN" list >/dev/null 2>&1 || true
sqlite3 "$DB" "INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
  VALUES ('behind_row','behind_row','1.0',0,'seedsha','/tmp/c/behind_row/1.0');"

# (1) Unverified audit: the JSON root must say so, on stdout, with exit 0.
out=$(MALT_OFFLINE=1 "$BIN" outdated --json 2>/dev/null) || fail "unverified --json exit code changed: $?"
if ! grep -qF '"complete":false' <<<"$out"; then
  fail "unverified --json carries no completeness signal: $out"
fi
pass "unverified audit marks the JSON root incomplete"

# (2) --quiet must not swallow the only signal that the listing is partial.
out=$(MALT_OFFLINE=1 "$BIN" outdated --quiet 2>&1) || true
if ! grep -qF 'Could not verify' <<<"$out"; then
  fail "--quiet swallowed the unverified-audit warning: ${out:-<empty>}"
fi
pass "unverified audit still warns under --quiet"

# (3) Complete audit: the keg is listed and the default stays byte-identical.
printf 'behind_row\t4.0\t0\n' >"$API/versions_formula.txt"
out=$("$BIN" outdated --json 2>/dev/null) || fail "complete --json exit code changed: $?"
if ! grep -qF 'behind_row' <<<"$out"; then
  fail "complete audit hid the outdated keg: $out"
fi
if grep -qF '"complete"' <<<"$out"; then
  fail "complete audit emitted a completeness key: $out"
fi
pass "complete audit lists the keg without a completeness key"

# (4) The TUI parser reads the key (std-only leaf module).
if ! (cd "$ROOT" && timeout 120 zig test src/tui/json/outdated.zig >/dev/null 2>&1); then
  fail "tui outdated parser tests failed"
fi
pass "tui outdated parser reads the completeness key"

printf '\n\xe2\x9c\x94 outdated --json audit-completeness regression passed\n'
