#!/usr/bin/env bash
# Regression: a `--local` keg's `# local` note in a text backup must stay one
# line. A recipe path or keg name carrying a newline split the note, and the
# text after it became a `formula` line that `mt restore` would install.
#
# Offline throughout: MALT_OFFLINE refuses every fetch.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"

# `zig build test` does not refresh the binary; a stale one would mask the fix.
zig build >/dev/null

command -v sqlite3 >/dev/null 2>&1 || {
  echo "this regression needs sqlite3 on PATH" >&2
  exit 2
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# A developer shell's MALT_* must not point the run at a real prefix or cache.
while IFS='=' read -r var _; do unset "$var"; done < <(env | grep '^MALT_' || true)
export NO_COLOR=1 MALT_NO_EMOJI=1 MALT_OFFLINE=1 MALT_PREFIX="$tmp"

fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

mkdir -p "$tmp/db"
"$BIN" list >/dev/null 2>&1 # creates the schema

seed() {
  sqlite3 "$tmp/db/malt.db" "DELETE FROM kegs; INSERT INTO kegs(name, full_name, version, tap, store_sha256, cellar_path) VALUES ($1, $2, '1.0', 'local', 'aa', '/c');"
}

check() {
  "$BIN" backup -o "$tmp/b.txt" >/dev/null 2>&1 || fail "$1: backup failed"
  if grep -q '^formula ' "$tmp/b.txt"; then
    fail "$1: backup file carries an injected formula line"
  fi
  # Editors treat a bare CR as a line break when the file is hand-edited.
  if grep -q $'\r' "$tmp/b.txt"; then
    fail "$1: backup file carries a carriage return"
  fi
  # With the note gone, only stderr names the keg, and --quiet must not hide it.
  err=$("$BIN" backup -q -o "$tmp/b.txt" 2>&1 >/dev/null) || fail "$1: quiet backup failed"
  grep -q 'holds a line break' <<<"$err" || fail "$1: quiet backup dropped the keg without a warning"
  out=$("$BIN" restore --dry-run "$tmp/b.txt" 2>&1 || true)
  if grep -q 'formula evil' <<<"$out"; then
    fail "$1: restore would install the injected entry"
  fi
}

seed "'lx'" "'/w/x' || char(10) || 'formula evil/lx.rb'"
check "newline in path"
seed "'lx' || char(10) || 'formula evil'" "'/w/lx' || char(10) || 'formula evil.rb'"
check "newline in name"
seed "'lx'" "'/w/x' || char(13) || 'formula evil/lx.rb'"
check "carriage return in path"

# The screen must be narrow: a clean local keg keeps its note.
seed "'lx'" "'/w/lx.rb'"
"$BIN" backup -o "$tmp/b.txt" >/dev/null 2>&1 || fail "control: backup failed"
grep -qx '# local lx /w/lx.rb' "$tmp/b.txt" || fail "control: a clean local note was dropped"

printf '  ✓ local recipe notes never split into restorable entries\n'
