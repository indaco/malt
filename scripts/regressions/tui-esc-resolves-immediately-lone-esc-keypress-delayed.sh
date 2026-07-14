#!/usr/bin/env bash
# Regression: a lone Esc keypress must act immediately. Under a real pty,
# pressing Esc with a filter being edited must clear it and repaint within
# the escape-resolution window — not sit buffered until the next keypress
# resolves it (and then fire both keys in one turn).
#
# The bug: a bare Esc arrives as a single 0x1b byte the decoder cannot tell
# from the start of a CSI sequence, so it buffered the byte and the run loop
# parked in a blocking read; Decoder.flush(), the designed resolution point,
# had no caller. Every Esc-driven action (guard cancel, pane close, filter
# clear) felt dead until another key arrived.
#
# Exits 0 when Esc repaints on its own, non-zero when nothing is emitted
# until the next key. Offline, throwaway prefix, no network.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=scripts/lib/tui_pty.sh
# shellcheck disable=SC1091 # sourced lib resolved at runtime; absent when this file is linted alone
source "$ROOT/scripts/lib/tui_pty.sh"

tui_pty_guard
tui_pty_make_prefix
trap 'rm -rf "$TUI_PREFIX"' EXIT

cap="$TUI_PREFIX/capture.bin"
seg="$TUI_PREFIX/esc_segment.bin"

# Installed tab, open the filter, type one char, then send Esc ALONE and
# give it a settle window. Everything the TUI emits between the two marks
# was provoked by the lone Esc — the follow-up q only quits.
tui_pty_drive "$cap" 80 24 <<'ACTIONS' >/dev/null
send 2
send /
send a
mark PRE_ESC
send \e
settle 0.8
mark POST_ESC
send q
quitwait 2
ACTIONS

# The launch-audit spinner may repaint stale frames inside the window, so
# judge only the LAST full frame (each frame opens with the \e[?2026h sync
# marker): by the end of the settle window Esc must have produced a
# cleared-filter repaint.
perl -0777 -ne 'my ($s) = /\@\@PRE_ESC\@\@(.*)\@\@POST_ESC\@\@/s or exit; my @f = split /\x1b\[\?2026h/, $s; print $f[-1] // ""' "$cap" >"$seg"

if [[ ! -s "$seg" ]]; then
  echo "REGRESSION: lone Esc emitted nothing — it did not resolve until the next key" >&2
  exit 1
fi

if grep -aq 'filter: a' "$seg"; then
  echo "REGRESSION: the last frame after Esc still shows the un-cleared filter" >&2
  exit 1
fi

echo "OK: a lone Esc clears the filter and repaints immediately"
