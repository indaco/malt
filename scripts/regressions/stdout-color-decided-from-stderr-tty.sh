#!/usr/bin/env bash
# Regression: commands that write their colourised rows to stdout decided
# whether to colour by probing *stderr*. Run from a terminal with stdout
# redirected - `mt info jq > out.txt` - and raw ANSI landed in the file.
#
# Only a real terminal on stderr can reproduce it, so the run happens under
# script(1): the child gets a pty, and the inner redirect sends stdout to a
# file while stderr stays on the pty. That is the exact user-facing shape.
#
# The second half proves the forced policy still reaches the stdout path:
# CLICOLOR_FORCE=1 must colourise even when stdout is a plain file.
#
# Hermetic: a seeded keg in a throwaway prefix, MALT_OFFLINE=1, no network.
#
# Usage: scripts/regressions/stdout-color-decided-from-stderr-tty.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt, sqlite3 on PATH.

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

PREFIX="$(mktemp -d)"
OUTDIR="$PREFIX/out"
mkdir -p "$PREFIX/db" "$OUTDIR"
export MALT_PREFIX="$PREFIX"
export MALT_NO_EMOJI=1
export MALT_OFFLINE=1
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

ESC=$'\033['

DB="$PREFIX/db/malt.db"

# Let malt bootstrap the schema, then seed one keg plus the bin symlink
# `mt which` resolves through.
"$BIN" list --quiet >/dev/null 2>&1 || true
[[ -f "$DB" ]] || fail "DB was not initialised by mt list"
sqlite3 "$DB" <<SQL
INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, install_reason)
VALUES ('jq', 'jq', '1.7.1', 0, 'sha_jq', '$PREFIX/Cellar/jq/1.7.1', 'direct');
-- A dependent, so \`mt uses jq\` renders a real row instead of the empty notice.
INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, install_reason)
VALUES ('gojq', 'gojq', '0.12.0', 0, 'sha_gojq', '$PREFIX/Cellar/gojq/0.12.0', 'direct');
INSERT INTO dependencies (keg_id, dep_name, dep_type)
SELECT id, 'jq', 'runtime' FROM kegs WHERE name = 'gojq';
SQL
mkdir -p "$PREFIX/Cellar/jq/1.7.1/bin" "$PREFIX/bin"
: >"$PREFIX/Cellar/jq/1.7.1/bin/jq"
ln -s "$PREFIX/Cellar/jq/1.7.1/bin/jq" "$PREFIX/bin/jq"

# Every subcommand here builds a stdout writer and styles what it writes.
CMDS=(
  "info jq"
  "which jq"
  "list"
  "search --installed jq"
  "uses jq"
)

slug() { printf '%s' "$1" | tr -c 'a-z0-9' '_'; }

# script(1) hands the child a fresh pty and records it; the inner `>` peels
# stdout off that pty, leaving stderr on it. shellcheck cannot see the inner
# expansion.
# shellcheck disable=SC2016
run_under_pty() {
  local cmd="$1" out="$2" tty_log="$3"
  MT_BIN="$BIN" MT_CMD="$cmd" MT_OUT="$out" \
    script -q "$tty_log" sh -c '$MT_BIN $MT_CMD >"$MT_OUT"' </dev/null >/dev/null 2>&1 || true
}

for cmd in "${CMDS[@]}"; do
  out="$OUTDIR/$(slug "$cmd").txt"
  run_under_pty "$cmd" "$out" /dev/null
  [[ -s "$out" ]] || fail "mt $cmd wrote nothing to the redirected stdout"
  grep -qF "$ESC" "$out" &&
    fail "mt $cmd leaked ANSI into a redirected stdout (stderr was the terminal)"
  pass "mt $cmd: redirected stdout stayed plain"
done

# The other half of the divergence, and the reason the checks above are not
# vacuous: in the same run, stderr is still a terminal and must KEEP its
# colour. Without this, silencing colour on both streams would pass.
run_under_pty "which definitely-not-installed" "$OUTDIR/miss.txt" "$OUTDIR/miss.tty"
grep -qF "$ESC" "$OUTDIR/miss.tty" ||
  fail "stderr lost its colour while stdout was redirected; both streams went plain"
pass "stderr kept its colour in the same run"

# The forced policy is stream-independent: no terminal anywhere, colour anyway.
for cmd in "${CMDS[@]}"; do
  out="$OUTDIR/forced_$(slug "$cmd").txt"
  # shellcheck disable=SC2086 # $cmd carries its own arguments; splitting is the point
  CLICOLOR_FORCE=1 "$BIN" $cmd >"$out" 2>/dev/null || true
  grep -qF "$ESC" "$out" ||
    fail "CLICOLOR_FORCE=1 did not colourise mt $cmd on a piped stdout"
  pass "mt $cmd: CLICOLOR_FORCE=1 colourised the redirected stdout"
done

printf '\n\xe2\x9c\x94 stdout colour follows the stdout stream\n'
