#!/usr/bin/env bash
# scripts/e2e/tui_uninstall_prompt_before_paste.sh
#
# Under a real pty, "x" followed by a paste far larger than one read (and the
# tty queue, with a 150 ms pause midway) on Installed must paint the uninstall prompt and keep the keg.
# Input that never stops must cancel the prompt; its banner stays until the next key.
# The unit tests cover the arm rule; this proves the run loop applies it.
#
# Usage:   MT_BIN=./zig-out/bin/malt ./scripts/e2e/tui_uninstall_prompt_before_paste.sh
# Exit:    0 on pass, 1 on failure, 2 when the binary or pty tooling is missing.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=scripts/lib/tui_pty.sh
# shellcheck disable=SC1091 # sourced lib resolved at runtime; absent when this file is linted alone
source "$ROOT/scripts/lib/tui_pty.sh"

tui_pty_guard
tui_pty_make_prefix
trap 'rm -rf "$TUI_PREFIX"' EXIT
tui_pty_seed_keg_real solopkg

fail() {
  echo "tui-uninstall-prompt-paste: FAIL — $*" >&2
  exit 1
}

CAP="$TUI_PREFIX/cap.bin"
half=$(printf 'y%.0s' $(seq 750))
out=$(
  tui_pty_drive "$CAP" 90 24 <<ACT
settle 0.6
send 2
settle 0.8
put x$half
pause 0.15
put $half
pause 0.8
send n
send q
quitwait 1.5
ACT
)

echo "$out" | grep -q "EXIT_STATUS=0" || fail "mt tui did not exit 0 ($out)"
grep -qa '\[y/N\]' "$CAP" || fail "the prompt was never painted"
kegs=$(sqlite3 "$TUI_PREFIX/db/malt.db" 'SELECT COUNT(*) FROM kegs;')
[ "$kegs" = 1 ] || fail "a buffered y confirmed the prompt (keg count $kegs)"

# Slow input (one key per 30 ms) outlasting the 5 s drain budget: the prompt is
# cancelled, the keg stays, and the banner survives until input has been quiet.
# A resize repaints, so each step can assert on the screen.
# A driver stall near the 300 ms quiet window looks like the user stopped
# typing, and then a confirm is correct, so that run proves nothing: retry it.
CAP2="$TUI_PREFIX/cap2.bin"
for attempt in 1 2 3; do
  out=$(
    tui_pty_drive "$CAP2" 90 24 <<ACT
settle 0.6
send 2
settle 0.8
put x
trickle 7 0.03 y
pause 0.8
mark kept
resize 91 24
settle 0.8
send z
mark gone
resize 90 24
settle 0.8
send q
quitwait 1.5
ACT
  )
  gap=$(echo "$out" | sed -n 's/^TRICKLE_MAX_GAP=//p')
  [ -n "$gap" ] || fail "the driver did not report the trickle gap ($out)"
  awk -v g="$gap" 'BEGIN { exit !(g < 0.25) }' && break
  [ "$attempt" = 3 ] && fail "the driver stalled on every attempt (last gap ${gap}s)"
  echo "tui-uninstall-prompt-paste: driver stalled ${gap}s between keys, retrying" >&2
  [ "$(tui_pty_keg_count)" = 1 ] || tui_pty_seed_keg_real solopkg
done
echo "$out" | grep -q "EXIT_STATUS=0" || fail "mt tui did not exit 0 after the trickle ($out)"
kegs=$(sqlite3 "$TUI_PREFIX/db/malt.db" 'SELECT COUNT(*) FROM kegs;')
[ "$kegs" = 1 ] || fail "slow input confirmed the prompt (keg count $kegs)"
sed -n '/^@@kept@@/,/^@@gone@@/p' "$CAP2" | grep -qa 'prompt cancelled' || fail "the cancel banner did not survive the input"
sed -n '/^@@gone@@/,$p' "$CAP2" | grep -qa 'prompt cancelled' && fail "the cancel banner outlived the next key"

echo "tui-uninstall-prompt-paste: PASS"
