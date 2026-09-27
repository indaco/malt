#!/usr/bin/env bash
# Regression: `install --local` must refuse a recipe whose name, version or
# path holds a control character.
#
# The bug: the recipe's realpath became `kegs.full_name`, its basename minus
# `.rb` became `kegs.name` and the Cellar directory, and the DSL `version` a
# second Cellar component - all screened only for path hops. A line break in
# any of them installed a keg whose name split every line-oriented surface
# (progress, `list`, `info`); an ESC was scrubbed on display, so the name
# shown could not be typed back to `uninstall`.
#
# The fix refuses any control character (C0, DEL, and C1 spelled as UTF-8,
# which the display scrubber passes) at install construction: on the realpath
# before anything is printed, and in the name/version screen. On `--local` the
# name is the realpath's basename, so the path screen is the one that fires;
# each case checks the refusal line so a case cannot pass on the wrong screen.
#
# Usage: scripts/regressions/local-recipe-control-bytes-install-local-accepts-line-breaks-in-recipe-name-and-path.sh
# Requirements: zig toolchain (the script rebuilds malt) or a built malt at
# $MALT_BIN; sqlite3. No network: the archive is seeded into the SHA-keyed
# tap cache so the download is a warm hit.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
# A stale binary would mask the fix, so rebuild unless one was handed in.
[[ -n "${MALT_BIN:-}" ]] || (cd "$ROOT" && zig build)
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

# MALT_PREFIX must be <= 13 bytes (Mach-O in-place patching budget).
SB=$(mktemp -d /tmp/mt.XXX)
trap 'rm -rf "$SB"' EXIT

# An inherited MALT_* (cache, API domain, ...) would point the run elsewhere.
while IFS='=' read -r v _; do unset "$v"; done < <(env | grep '^MALT_' || true)
export NO_COLOR=1
export MALT_NO_EMOJI=1
export MALT_OFFLINE=1
PREFIX="$SB/p"
export MALT_PREFIX="$PREFIX"

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

mkdir -p "$MALT_PREFIX/cache/Tap" "$SB/work/bin"
printf '#!/bin/sh\necho hi\n' >"$SB/work/bin/lx"
chmod +x "$SB/work/bin/lx"
tar czf "$SB/a.tar.gz" -C "$SB/work" bin
SHA=$(shasum -a 256 "$SB/a.tar.gz" | cut -d' ' -f1)
command cp -f "$SB/a.tar.gz" "$MALT_PREFIX/cache/Tap/$SHA.tar.gz"

# write_rb <path> <version>
write_rb() {
  mkdir -p "$(dirname "$1")"
  printf 'class Lx < Formula\n  version "%s"\n  url "https://example.invalid/a.tar.gz"\n  sha256 "%s"\nend\n' \
    "$2" "$SHA" >"$1"
}

kegs() { sqlite3 "$MALT_PREFIX/db/malt.db" 'SELECT name FROM kegs' 2>/dev/null || true; }

# refused <label> <recipe path> <expected refusal line>
refused() {
  if "$BIN" install --local "$2" >"$SB/log" 2>&1; then
    cat "$SB/log" >&2
    fail "$1 accepted (exit 0)"
  fi
  grep -qF "$3" "$SB/log" || {
    cat "$SB/log" >&2
    fail "$1 was not refused by the control-character screen"
  }
  [[ -z $(kegs) ]] || fail "$1 left a kegs row"
  [[ -z $(ls -A "$MALT_PREFIX/Cellar" 2>/dev/null) ]] || fail "$1 left a Cellar entry"
  pass "$1 is refused"
}

LF_NAME="$SB/lx"$'\n'"formula evil.rb"
CR_NAME="$SB/lx"$'\r'"z.rb"
C1_NAME="$SB/lx"$'\xc2\x9b'"2J.rb"
LF_DIR="$SB/x"$'\n'"formula evil/lx.rb"
write_rb "$LF_NAME" 1.0
write_rb "$CR_NAME" 1.0
write_rb "$C1_NAME" 1.0
write_rb "$LF_DIR" 1.0
write_rb "$SB/lv.rb" "1.0"$'\e'"z"
write_rb "$SB/lc.rb" "1.0"$'\xc2\x9b'"2J"
write_rb "$SB/ok/lx.rb" 1.0

path_msg="Local formula path holds a control character"
refused "a line feed in the recipe file name" "$LF_NAME" "$path_msg"
refused "a carriage return in the recipe file name" "$CR_NAME" "$path_msg"
refused "a UTF-8 C1 control in the recipe file name" "$C1_NAME" "$path_msg"
refused "a line feed in the recipe directory" "$LF_DIR" "$path_msg"
refused "an ESC in the DSL version" "$SB/lv.rb" "lv declares a version holding a control character"
refused "a UTF-8 C1 control in the DSL version" "$SB/lc.rb" "lc declares a version holding a control character"

# Control: the screen must be narrow enough that a clean recipe still installs.
"$BIN" install --local "$SB/ok/lx.rb" >"$SB/log" 2>&1 || {
  cat "$SB/log" >&2
  fail "a clean recipe was refused"
}
[[ $(kegs) == lx ]] || fail "a clean recipe did not record its kegs row"
pass "a clean recipe still installs"
