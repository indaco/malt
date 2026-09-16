#!/usr/bin/env bash
# Regression: a `tap = "local"` keg is out of scope for the outdated audit.
#
# `mt install --local` records the keg with `tap = "local"`. Pre-fix, every
# tap-branching reader in the audit treated any non-core label as a
# third-party tap, so the row was routed to the tap-HEAD resolver, came back
# unresolved, cleared `complete`, and blocked the snapshot for the whole
# prefix — silently, for as long as one local keg was installed:
#
#   $ mt outdated --refresh
#     ▸ wget (1.20) ≠ 1.22
#     ! Could not verify every package; snapshot not updated.
#
# A local keg has no upstream to consult, so it is neither current nor
# outdated: the audit must skip it without touching `complete`.
#
# Pinned, hermetic (MALT_OFFLINE=1, core answer served from the API cache):
#   1. the core keg is listed and no incomplete warning is printed
#   2. `outdated.json` is warmed and names only the core keg
#   3. the `--json` root is not flagged `"complete": false`
#
# Usage: scripts/regressions/local-keg-out-of-scope-for-audit-local-keg-never-audited-blocks-snapshot.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt,
# `sqlite3` and `jq` on PATH. No network.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}
for tool in sqlite3 jq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "this regression needs $tool on PATH" >&2
    exit 2
  }
done

PREFIX="/tmp/mt_local_audit_$$"
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$PREFIX/cache"
export MALT_OFFLINE=1
export NO_COLOR=1
export MALT_NO_EMOJI=1
unset MALT_OUTDATED_MAX_AGE
rm -rf "$PREFIX"
mkdir -p "$PREFIX/db" "$MALT_CACHE/api"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}
inconclusive() {
  printf '  ? %s\n' "$*" >&2
  exit 2
}

DB="$PREFIX/db/malt.db"
SNAP="$MALT_CACHE/outdated.json"

# Bootstrap the schema by letting malt open the DB once.
"$BIN" list --quiet >/dev/null 2>&1 || true
[[ -f "$DB" ]] || inconclusive "DB was not initialised by mt list"

# One local keg beside one core keg whose cached formula is newer. No
# formula_older.json is seeded: a same-named core formula would be a
# different package and must never be consulted for a local keg.
sqlite3 "$DB" <<SQL
INSERT INTO kegs (name, full_name, version, revision, tap, store_sha256, cellar_path, install_reason)
VALUES ('older', '/x/older.rb', '1.0', 1, 'local', 'sha', '$PREFIX/Cellar/older/1.0_1', 'direct');
INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, install_reason)
VALUES ('wget', 'wget', '1.20', 0, 'sha2', '$PREFIX/Cellar/wget/1.20', 'direct');
SQL
printf '{"name":"wget","versions":{"stable":"1.22"},"revision":0}' >"$MALT_CACHE/api/formula_wget.json"

# 1. human path: core keg listed, audit not marked incomplete
out=$("$BIN" outdated --refresh 2>&1 || true)
grep -q 'wget (1.20)' <<<"$out" || fail "core keg not listed: $out"
if grep -q 'Could not verify every package' <<<"$out"; then
  fail "local keg marked the audit incomplete"
fi
pass "core keg listed, no incomplete warning"

# 2. snapshot warmed and names only the core keg
[[ -f "$SNAP" ]] || fail "outdated.json not written"
names=$(jq -r '.formulas | map(.name) | join(",")' "$SNAP")
[[ "$names" == "wget" ]] || fail "snapshot names the wrong kegs: '$names'"
pass "outdated.json names only the core keg"

# 3. JSON root not flagged incomplete
complete=$("$BIN" outdated --refresh --json 2>/dev/null | jq -r '.complete // true')
[[ "$complete" == "true" ]] || fail "--json root marked incomplete"
pass "--json root not marked incomplete"

echo "PASS: local keg is out of scope for the audit"
