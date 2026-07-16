#!/usr/bin/env bash
# Regression: the dashboard came back from an inline command keyboard-only. The
# TUI hands the terminal to the child for a real `mt <subcommand>` — which drops
# mouse tracking along with raw mode and the alt-screen — but the re-enter path
# restored raw mode, the alt-screen and the cursor and forgot the mouse. The
# wheel and every click were dead for the rest of the session, and nothing short
# of quitting brought them back.
#
# The unit tests around the re-enter used a fake terminal that pinned only the
# leave → spawn → enter *ordering*, so a missing re-enable was invisible to them.
# This drives the real binary on a real pty through a real delegation and asserts
# on the bytes the terminal actually received.
#
# Asserts:
#   - mouse tracking was enabled at launch and disabled for the child (proving
#     the round-trip really happened and this test isn't vacuous);
#   - it was re-enabled afterwards — a second `?1000h` — so the dashboard comes
#     back clickable.
#
# Every inline path (upgrade, install, uninstall, doctor fix) shares one
# re-enter seam, so the cheapest offline delegation stands in for all of them.
#
# Usage:   MT_BIN=./zig-out/bin/malt ./scripts/regressions/tui-mouse-tracking-dropped-after-inline-command.sh
# Exit:    0 when the bug is absent, 1 when present, 2 when tooling is missing.

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
  echo "tui-mouse-reenter: FAIL — $*" >&2
  exit 1
}

CAP="$TUI_PREFIX/cap.bin"
# Launch opens on Search; one `tab` reaches Installed. `x` raises the uninstall
# guard, `y` confirms and delegates to the real `mt uninstall solopkg`, which
# hands over the terminal and re-enters on the way back.
out=$(
  tui_pty_drive "$CAP" 90 24 <<'ACT'
settle 0.4
send \t
settle 0.4
send x
settle 0.4
send y
settle 2.0
send q
quitwait 3.0
ACT
)
echo "$out" | grep -q "EXIT_STATUS=0" || fail "mt tui did not exit 0 on q ($out)"

# Guard against a vacuous pass: the delegation must actually have happened, or
# the counts below would prove nothing. A second alt-screen enter is the marker.
alt=$(grep -c -a -F $'\x1b[?1049h' "$CAP" || true)
[[ "$alt" -ge 2 ]] || fail "no inline delegation happened (alt-screen enters=$alt) — test is vacuous"

# The child ran with the mouse off: the leave must have emitted a disable.
grep -qa -F $'\x1b[?1000l' "$CAP" || fail "mouse tracking was never disabled for the child"

# The bug: exactly one enable — armed at launch, never re-armed after the child.
enable=$(grep -c -a -F $'\x1b[?1000h' "$CAP" || true)
[[ "$enable" -ge 2 ]] ||
  fail "mouse tracking not re-armed after the inline command (?1000h seen ${enable}x, want >=2) — the dashboard came back keyboard-only"

echo "tui-mouse-reenter: OK — the wheel and clicks survive an inline command"
