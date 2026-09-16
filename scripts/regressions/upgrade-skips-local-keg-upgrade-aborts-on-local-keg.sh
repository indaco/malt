#!/usr/bin/env bash
# Regression: `mt upgrade` skips a `tap = "local"` keg instead of failing on it.
#
# `mt install --local` records the keg with `tap = "local"`. Pre-fix,
# `upgrade` treated any non-core label as a third-party tap and handed the
# row to the tap path, whose first act is to split the label on `/`. There
# is none, so every bulk run reported a failed formula, exited non-zero,
# and never warmed the dry-run snapshot; the named form could never succeed:
#
#   $ mt upgrade --dry-run
#     x Cannot parse tap 'local' for older
#     > Dry run: would upgrade wget 1.20 -> 1.22
#     x 1 formula failed to upgrade:
#     x   - older
#
# A local keg has no upstream malt can fetch from, so `upgrade` has nothing
# to do for it: skip it, count it, and point at `mt install --local`.
#
# Pinned, hermetic (MALT_OFFLINE=1, core answer served from the API cache):
#   1. bulk dry-run exits 0, no parse error, no failed clause, wget listed
#   2. `outdated.json` is warmed and names only the core keg
#   3. the named form exits 0 and hints at `install --local`
#
# Usage: scripts/regressions/upgrade-skips-local-keg-upgrade-aborts-on-local-keg.sh
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

PREFIX="/tmp/mt_local_upgrade_$$"
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

# 1. bulk dry-run: clean exit, the local keg neither errors nor fails
set +e
out=$("$BIN" upgrade --dry-run 2>&1)
rc=$?
set -e
[[ $rc -eq 0 ]] || fail "bulk dry-run exited $rc: $out"
grep -q 'Cannot parse tap' <<<"$out" && fail "local keg routed through the tap path: $out"
grep -q 'failed' <<<"$out" && fail "local keg counted as a failure: $out"
grep -q 'would upgrade wget' <<<"$out" || fail "core keg not audited: $out"
pass "bulk dry-run exits 0 and skips the local keg"

# 2. snapshot warmed and names only the core keg
[[ -f "$SNAP" ]] || fail "outdated.json not written"
names=$(jq -r '.formulas | map(.name) | join(",")' "$SNAP")
[[ "$names" == "wget" ]] || fail "snapshot names the wrong kegs: '$names'"
pass "outdated.json names only the core keg"

# 3. named form: clean exit with the way out
set +e
out=$("$BIN" upgrade older 2>&1)
rc=$?
set -e
[[ $rc -eq 0 ]] || fail "named upgrade exited $rc: $out"
grep -q 'install --local' <<<"$out" || fail "no install --local hint: $out"
pass "named upgrade skips the local keg with a hint"

echo "PASS: upgrade skips local kegs"
