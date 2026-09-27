#!/usr/bin/env bash
# Regression: a `--local` keg's `# local` note must not carry a terminal
# control byte. A row stored before install screened names and paths could
# hold ESC or a UTF-8-spelled C1; backup, restore, bundle and --json echoed
# it, where the display scrubber passes a well-formed C1 sequence. A shared
# backup file can carry one on an entry line too.
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

# ESC or the two-byte UTF-8 spelling of a C1 control (0xC2 0x80-0x9F).
# perl, not grep: BSD grep does not honour a high-byte bracket range.
has_control() {
  perl -0777 -ne 'exit(/\x1b|\xc2[\x80-\x9f]/ ? 0 : 1)' "$@"
}

check() {
  err=$("$BIN" backup -o "$tmp/b.txt" 2>&1 >/dev/null) || fail "$1: backup failed"
  has_control "$tmp/b.txt" && fail "$1: control byte in the backup file"
  has_control <<<"$err" && fail "$1: control byte on backup's stderr"
  # With the note gone, only stderr names the keg, and --quiet must not hide it.
  err=$("$BIN" backup -q -o "$tmp/b.txt" 2>&1 >/dev/null) || fail "$1: quiet backup failed"
  grep -q 'holds a control character' <<<"$err" || fail "$1: quiet backup dropped the keg without a warning"
  out=$("$BIN" restore --dry-run "$tmp/b.txt" 2>&1 || true)
  has_control <<<"$out" && fail "$1: control byte in restore's output"
  err=$("$BIN" backup --json 2>&1 >/dev/null) || fail "$1: JSON backup failed"
  has_control <<<"$err" && fail "$1: control byte on JSON backup's stderr"
  "$BIN" backup --json 2>/dev/null | has_control && fail "$1: control byte on JSON backup's stdout"
  # bundle keeps no trace of a skipped local keg, so -q must not hide it.
  err=$("$BIN" bundle export -q 2>&1 >/dev/null) || fail "$1: bundle export failed"
  has_control <<<"$err" && fail "$1: control byte on bundle export's stderr"
  grep -q 'holds a control character; bundle skips it' <<<"$err" || fail "$1: bundle export dropped the keg without a warning"
  return 0
}

seed "'lx'" "'/w/x' || char(27) || '[2Jy/lx.rb'"
check "ESC in path"
seed "'lx'" "'/w/x' || char(155) || '2Jy/lx.rb'"
check "C1 in path"
seed "'l' || char(27) || 'x'" "'/w/lx.rb'"
check "ESC in name"

# A backup written before the fix is already on disk.
printf '# local lx /w/x\xc2\x9b2Jy/lx.rb\n' >"$tmp/old.txt"
out=$("$BIN" restore --dry-run "$tmp/old.txt" 2>&1 || true)
has_control <<<"$out" && fail "restore echoes a C1 from an existing backup file's note"
grep -qF 'lx (/w/x\xc2\x9b2Jy/lx.rb) is a local formula whose name or recipe path holds a control character' <<<"$out" ||
  fail "restore skips an existing backup file's note without naming the keg"

# A shared or hand-edited file can carry C1 on an entry line too.
printf 'formula foo 1.0\xc2\x9b2J\nformula bar@\xc2\x9d0;x\xc2\x9c\n' >"$tmp/entry.txt"
out=$("$BIN" restore --dry-run "$tmp/entry.txt" 2>&1 || true)
has_control <<<"$out" && fail "restore echoes a C1 from a formula line"

# The screen must be narrow: clean and non-ASCII UTF-8 notes survive.
seed "'la'" "'/w/la.rb'"
"$BIN" backup -o "$tmp/b.txt" >/dev/null 2>&1 || fail "control: backup failed"
grep -qx '# local la /w/la.rb' "$tmp/b.txt" || fail "control: a clean local note was dropped"
seed "'la'" "'/w/caf' || char(233) || '/la.rb'"
"$BIN" backup -o "$tmp/b.txt" >/dev/null 2>&1 || fail "control: backup failed"
grep -qx $'# local la /w/caf\xc3\xa9/la.rb' "$tmp/b.txt" || fail "control: a UTF-8 local note was dropped"

printf '  ✓ local recipe notes never carry a terminal control byte\n'
