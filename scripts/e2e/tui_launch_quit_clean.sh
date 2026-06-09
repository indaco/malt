#!/usr/bin/env bash
# scripts/e2e/tui_launch_quit_clean.sh
#
# Under a real pty, `mt tui` must: render its tab bar and list on launch, switch
# cleanly between all five tabs, and restore the terminal on quit — leaving no
# residual raw mode or alt-screen. The pure render/key logic is unit-tested; this
# proves the terminal lifecycle that only exists under a tty.
#
# Asserts:
#   - the tab bar renders and a seeded package row appears once the Installed
#     tab becomes active during the cycle (launch opens on the Search tab);
#   - cycling with `tab` makes each tab the active (reverse-video) one in turn;
#   - `q` exits 0 and the stream restores the terminal exactly once — one
#     alt-screen enter paired with one leave, and the cursor shown again.
#
# Usage:   MT_BIN=./zig-out/bin/malt ./scripts/e2e/tui_launch_quit_clean.sh
# Exit:    0 on pass, 1 on failure, 2 when the binary or pty tooling is missing.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=scripts/lib/tui_pty.sh
# shellcheck disable=SC1091 # sourced lib resolved at runtime; absent when this file is linted alone
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
# Start on Search; four `tab`s cycle through Installed, Outdated, Services, and
# Doctor, settling on each so its frame is captured.
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

# The tab bar renders (its 'Installed' label is always present) and, once the
# Installed tab is entered during the cycle, a seeded row appears.
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
count() { grep -c -a -F "$2" "$1" || true; }
enter=$(count "$CAP" $'\x1b[?1049h')
leave=$(count "$CAP" $'\x1b[?1049l')
show=$(count "$CAP" $'\x1b[?25h')
[[ "$enter" == "1" ]] || fail "expected exactly 1 alt-screen enter, got $enter"
[[ "$leave" == "1" ]] || fail "expected exactly 1 alt-screen leave, got $leave"
[[ "$show" -ge "1" ]] || fail "cursor was never shown again on exit"

# Ctrl-C must quit and restore the terminal just like `q` — the command help
# promises "quit with q or Ctrl-C". Without it the dashboard would leave the
# alt-screen active on interrupt.
CAPC="$TUI_PREFIX/cap_ctrlc.bin"
outc=$(
  tui_pty_drive "$CAPC" 90 24 <<'ACT'
settle 0.4
send \x03
quitwait 1.5
ACT
)
echo "$outc" | grep -q "EXIT_STATUS=0" || fail "Ctrl-C did not quit mt tui cleanly ($outc)"
[[ "$(count "$CAPC" $'\x1b[?1049l')" -ge 1 ]] || fail "Ctrl-C left the alt-screen active (terminal not restored)"
[[ "$(count "$CAPC" $'\x1b[?25h')" -ge 1 ]] || fail "Ctrl-C did not restore the cursor"

echo "tui-launch-quit: OK — launch, tab cycle, q + Ctrl-C both restore the terminal"
