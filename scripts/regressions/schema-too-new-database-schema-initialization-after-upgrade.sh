#!/usr/bin/env bash
# Regression: a DB whose schema_version is newer than the binary's
# known_schema_version (written by a newer malt, e.g. a dev build or a
# host on a later release sharing $MALT_PREFIX/db) was refused by
# schema.migrate but every CLI open site hid the refusal:
#   * `list` / `list --json` printed nothing and exited 0 — the TUI, which
#     parses `list --json`, then rendered an empty prefix;
#   * `install` printed an opaque "Failed to initialize database schema";
#   * `doctor` reported a green SQLite integrity line and nothing else;
#   * `pin` ignored the gate and operated on the too-new DB anyway.
#
# After the fix each of those commands names the DB version and the
# supported version and exits non-zero, and `doctor` has a failing
# schema row. Seeds the schema at head, bumps it with sqlite3, checks.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when
# present. No network required; finishes in a few seconds once built.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}
command -v sqlite3 >/dev/null || {
  echo "sqlite3 required" >&2
  exit 2
}

PREFIX="$(mktemp -d)/malt-prefix"
export MALT_PREFIX="$PREFIX" NO_COLOR=1 MALT_NO_EMOJI=1 MALT_OFFLINE=1
trap 'rm -rf "$(dirname "$PREFIX")"' EXIT

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

DB="$PREFIX/db/malt.db"
mkdir -p "$PREFIX/db"

# Let the binary seed the schema at its own head version.
"$BIN" list >/dev/null 2>&1 || true
head=$(sqlite3 "$DB" 'SELECT MAX(version) FROM schema_version;')
[[ -n "$head" ]] || fail "schema init did not seed schema_version"
too_new=$((head + 1))
sqlite3 "$DB" "INSERT INTO schema_version(version) VALUES ($too_new);"

for cmd in "list" "list --json" "install tree" "pin tree"; do
  set +e
  # shellcheck disable=SC2086
  err=$("$BIN" $cmd 2>&1 >/dev/null)
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || fail "mt $cmd exited 0 on a v$too_new DB"
  if ! grep -q "v$too_new" <<<"$err" || ! grep -q "v$head" <<<"$err"; then
    fail "mt $cmd did not name v$too_new vs v$head: $err"
  fi
  if grep -q "Failed to initialize database schema" <<<"$err"; then
    fail "mt $cmd still prints the opaque message"
  fi
  pass "mt $cmd refuses the v$too_new DB and names v$head"
done

# doctor exits non-zero on a bare prefix for unrelated rows; key on the
# schema row only.
set +e
doc=$("$BIN" doctor 2>&1)
set -e
grep -i "schema" <<<"$doc" | grep -q "v$too_new" ||
  fail "doctor does not report the v$too_new schema mismatch"
pass "doctor reports the schema mismatch"

printf '\n✔ too-new schema is reported, never swallowed\n'
