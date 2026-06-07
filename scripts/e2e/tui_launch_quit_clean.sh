#!/usr/bin/env bash
# scripts/e2e/tui_launch_quit_clean.sh
#
# Under a real pty, `mt tui` must: render its tab bar and list on launch, switch
# cleanly between all five tabs, and restore the terminal on quit — leaving no
# residual raw mode or alt-screen. The pure render/key logic is unit-tested; this
# proves the terminal lifecycle that only exists under a tty.
#
# Asserts:
#   - the first frame carries the tab bar and a seeded package row;
#   - cycling with `tab` makes each tab the active (reverse-video) one in turn;
#   - `q` exits 0 and the stream restores the terminal exactly once — one
#     alt-screen enter paired with one leave, and the cursor shown again.
#
# Usage:   MT_BIN=./zig-out/bin/malt ./scripts/e2e/tui_launch_quit_clean.sh
# Exit:    0 on pass, 1 on failure, 2 when the binary or pty tooling is missing.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=scripts/lib/tui_pty.sh
source "$ROOT/scripts/lib/tui_pty.sh"

tui_pty_guard
tui_pty_make_prefix
trap 'rm -rf "$TUI_PREFIX"' EXIT
tui_pty_seed_kegs 8

fail() {
  echo "tui-launch-quit: FAIL — $*" >&2
  exit 1
}

CAP="$TUI_PREFIX/cap.bin"
# Start on Installed; four `tab`s cycle through Outdated, Services, Doctor, and
# Search, settling on each so its frame is captured.
out=$(
  tui_pty_drive "$CAP" 90 24 <<'ACT'
settle 0.4
send \t
settle 0.4
send \t
settle 0.4
send \t
settle 0.4
send \t
settle 0.4
send q
quitwait 1.5
ACT
)

echo "$out" | grep -q "EXIT_STATUS=0" || fail "mt tui did not exit 0 on q ($out)"

# First frame: tab bar + a seeded row both rendered.
grep -qa "Installed" "$CAP" || fail "tab bar 'Installed' label never rendered"
grep -qa "pkg01" "$CAP" || fail "seeded package row never rendered"

# Cycling must make each tab the active block in turn. The active tab is the
# only one drawn reverse-video + bold; a list selection is reverse-video but
# never bold, so that prefix identifies the active tab unambiguously.
assert_activated() {
  local want="$1"
  WANT="$want" perl -0777 -ne '
    exit(/\x1b\[7m\x1b\[1m\Q$ENV{WANT}\E/ ? 0 : 1);
  ' "$CAP" || fail "tab '$want' never became active during the cycle"
}
assert_activated Installed
assert_activated Outdated
assert_activated Services
assert_activated Doctor
assert_activated Search

# Terminal restored cleanly: one alt-screen enter, one leave, cursor shown.
count() { grep -c -a -F "$1" "$CAP" || true; }
enter=$(count $'\x1b[?1049h')
leave=$(count $'\x1b[?1049l')
show=$(count $'\x1b[?25h')
[[ "$enter" == "1" ]] || fail "expected exactly 1 alt-screen enter, got $enter"
[[ "$leave" == "1" ]] || fail "expected exactly 1 alt-screen leave, got $leave"
[[ "$show" -ge "1" ]] || fail "cursor was never shown again on exit"

echo "tui-launch-quit: OK — launch, tab cycle, and clean terminal restore"
