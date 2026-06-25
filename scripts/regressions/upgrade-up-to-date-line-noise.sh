#!/usr/bin/env bash
# Regression: `mt upgrade` (bulk, no positionals) must be quiet-by-default.
#
# The bulk path used to print one dim line per already-current package and
# borrow the upgrade glyph for pinned rows, drowning the few actionable
# rows on a mostly-current machine. The fix suppresses the per-package
# "already at latest" line on the bulk path (keeping the NDJSON event),
# re-homes pinned onto the `·` skip glyph, and prints one summary footer.
#
# This proves, fully offline, that on the bulk path:
#   1. an up-to-date package emits NO "already at latest" human line,
#   2. the summary footer carries the right counts,
#   3. a pinned package stays individually visible,
#   4. the named path (`mt upgrade <name>`) still prints its per-package line,
#   5. the NDJSON event stream still carries the up_to_date event.
#
# Two synthetic core kegs are seeded and a fresh formula cache JSON is
# planted for each so every version lookup resolves offline to the SAME
# version that is installed → the up-to-date branch, no network.
#
# Usage: scripts/regressions/upgrade-up-to-date-line-noise.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt, sqlite3.

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

# MALT_PREFIX must be <= 13 bytes (Mach-O in-place patching budget).
PREFIX="/tmp/mt_uptd"
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
rm -rf "$PREFIX"
mkdir -p "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

# Bootstrap the schema the same way malt does: a `list` call opens and
# initialises the DB on a fresh prefix.
mkdir -p "$PREFIX/db"
"$BIN" list >/dev/null 2>&1 || true
DB="$PREFIX/db/malt.db"
[[ -f "$DB" ]] || fail "expected DB at $DB after a list call"

CURRENT="alpha" # up to date
HELD="bravo"    # pinned

# Seed two core kegs (empty tap → core-API path, not tap routing), both at
# version 1.0.0 revision 0. Pin the second.
sqlite3 "$DB" <<SQL || fail "could not seed kegs"
INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, install_reason)
VALUES ('$CURRENT', '$CURRENT', '1.0.0', 0, '', '/c/$CURRENT/1.0.0', 'direct'),
       ('$HELD', '$HELD', '1.0.0', 0, '', '/c/$HELD/1.0.0', 'direct');
UPDATE kegs SET pinned = 1 WHERE name = '$HELD';
SQL

# Plant fresh formula cache JSON so each lookup resolves offline to the
# installed version (revision 0 → pkg_version == "1.0.0" == installed).
mkdir -p "$PREFIX/cache/api"
for n in "$CURRENT" "$HELD"; do
  printf '{"name":"%s","versions":{"stable":"1.0.0"},"revision":0}' "$n" \
    >"$PREFIX/cache/api/formula_$n.json"
done

# --- Bulk path: quiet-by-default + summary footer ---------------------
BULK="$PREFIX/bulk.log"
printf '\xe2\x96\xb8 mt upgrade (bulk, offline)\n'
"$BIN" upgrade >"$BULK" 2>&1 || true

# 1. The up-to-date human line is suppressed on the bulk path.
if grep -q "$CURRENT is already at latest" "$BULK"; then
  cat "$BULK" >&2
  fail "bulk path still narrates the up-to-date package ($CURRENT)"
fi
pass "up-to-date line suppressed on the bulk path"

# 2. The summary footer carries the right counts.
grep -q "2 checked" "$BULK" || {
  cat "$BULK" >&2
  fail "missing 'N checked' footer"
}
grep -q "0 upgraded" "$BULK" || {
  cat "$BULK" >&2
  fail "footer upgraded count wrong"
}
grep -q "1 up to date" "$BULK" || {
  cat "$BULK" >&2
  fail "footer up-to-date count wrong"
}
grep -q "1 pinned" "$BULK" || {
  cat "$BULK" >&2
  fail "footer pinned count wrong"
}
pass "summary footer: 2 checked · 0 upgraded · 1 up to date · 1 pinned"

# 3. The pinned package stays individually visible.
grep -q "$HELD is pinned, skipped" "$BULK" || {
  cat "$BULK" >&2
  fail "pinned package ($HELD) is no longer individually visible"
}
pass "pinned package still visible"

# --- Named path: per-package line preserved ---------------------------
NAMED="$PREFIX/named.log"
"$BIN" upgrade "$CURRENT" >"$NAMED" 2>&1 || true
grep -q "$CURRENT is already at latest" "$NAMED" || {
  cat "$NAMED" >&2
  fail "named path wrongly suppressed its per-package line"
}
# A single named upgrade must NOT print the bulk footer.
if grep -q "checked ·" "$NAMED" || grep -q "1 checked" "$NAMED"; then
  cat "$NAMED" >&2
  fail "named path printed a bulk summary footer"
fi
pass "named path keeps its per-package line, no footer"

# --- NDJSON parity: the machine stream is untouched -------------------
NDJSON="$PREFIX/events.ndjson"
"$BIN" --output-format=ndjson upgrade >"$NDJSON" 2>/dev/null || true
grep -q '"event":"up_to_date"' "$NDJSON" || {
  cat "$NDJSON" >&2
  fail "NDJSON up_to_date event lost"
}
grep -q "\"name\":\"$CURRENT\"" "$NDJSON" || {
  cat "$NDJSON" >&2
  fail "NDJSON event missing the up-to-date package name"
}
pass "NDJSON up_to_date event still emitted"

printf '\n\xe2\x9c\x94 upgrade-up-to-date-line-noise regression passed\n'
