#!/usr/bin/env bash
# scripts/e2e/tui_non_tty_refusal.sh
#
# `mt tui` must refuse to launch rather than emit a corrupted frame whenever the
# environment can't host the dashboard. It exits 2 with a message and never
# enters raw mode or the alt-screen. Three refusal reasons are pinned here:
#   - stdin/stdout not a terminal (the scripted/piped case);
#   - NO_COLOR set on a real terminal (the dashboard needs ANSI);
#   - CI detected on a real terminal.
# The pure refusal logic is unit-tested; this proves it at the binary edge.
#
# The non-tty cases need no pty tooling and always run. The NO_COLOR/CI cases
# must reach the binary on a real terminal, so they use the pty driver and are
# skipped (not failed) when perl/IO::Pty is unavailable.
#
# Hermetic: a throwaway MALT_PREFIX under /tmp, no network.
#
# Usage:   MT_BIN=./zig-out/bin/malt ./scripts/e2e/tui_non_tty_refusal.sh
# Exit:    0 on pass, 1 on failure, 2 when the binary is missing.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=scripts/lib/tui_pty.sh
source "$ROOT/scripts/lib/tui_pty.sh"

if [[ ! -x "$MT_BIN" ]]; then
  echo "tui-e2e: $MT_BIN not found or not executable" >&2
  echo "tui-e2e: run 'zig build' first (or set MT_BIN)" >&2
  exit 2
fi

tui_pty_make_prefix # disposable prefix; scrubs CI/NO_COLOR to a known baseline
trap 'rm -rf "$TUI_PREFIX"' EXIT

fail() {
  echo "tui-refusal: FAIL — $*" >&2
  exit 1
}

# Case 1: stdin + stdout redirected away from any terminal.
err="$TUI_PREFIX/err1.txt"
"$MT_BIN" tui </dev/null >/dev/null 2>"$err"
rc=$?
[[ $rc -eq 2 ]] || fail "redirected invocation exited $rc, expected 2"
grep -q "refusing to launch" "$err" || fail "no refusal message on stderr (redirected)"

# Case 2: stdout to a pipe (a common scripted misuse) — also refused.
err="$TUI_PREFIX/err2.txt"
"$MT_BIN" tui </dev/null 2>"$err" | cat >/dev/null
rc=${PIPESTATUS[0]}
[[ $rc -eq 2 ]] || fail "piped invocation exited $rc, expected 2"
grep -q "refusing to launch" "$err" || fail "no refusal message on stderr (piped)"

# Cases 3-4: refusals that only fire on a real terminal need the pty driver.
if perl -MIO::Pty -e 1 >/dev/null 2>&1 && perl -c "$TUI_PTY_DRIVER" >/dev/null 2>&1; then
  # NO_COLOR set, but a genuine tty: still refused (the dashboard needs ANSI).
  cap="$TUI_PREFIX/cap_nocolor.bin"
  out=$(
    export NO_COLOR=1
    tui_pty_drive "$cap" 90 24 <<<'quitwait 1.5'
  )
  echo "$out" | grep -q "EXIT_STATUS=2" || fail "NO_COLOR on a tty did not exit 2 ($out)"
  grep -qa "NO_COLOR" "$cap" || fail "no NO_COLOR refusal message under a tty"

  # CI detected on a tty: refused.
  cap="$TUI_PREFIX/cap_ci.bin"
  out=$(
    export CI=1
    tui_pty_drive "$cap" 90 24 <<<'quitwait 1.5'
  )
  echo "$out" | grep -q "EXIT_STATUS=2" || fail "CI on a tty did not exit 2 ($out)"
  grep -qa "CI environment" "$cap" || fail "no CI refusal message under a tty"

  echo "tui-refusal: OK — non-tty, NO_COLOR, and CI invocations all refused with exit 2"
else
  echo "tui-refusal: OK — non-tty refused with exit 2 (NO_COLOR/CI cases skipped: no perl IO::Pty)"
fi
