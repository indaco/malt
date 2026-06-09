#!/usr/bin/env bash
# scripts/e2e/tui_fresh_prefix_launch.sh
#
# A fresh prefix has no `db/` yet, so every `mt … --json` read the dashboard
# issues exits 0 with NO output. That empty response must be treated as an empty
# Cellar, not a failure: `mt tui` has to launch, render its tabs, and cycle
# through all of them without ever crashing on `EmptyOutput`. (Regression: it
# used to abort at boot in `loadInstalled`.)
#
# Asserts:
#   - the dashboard launches and quits 0 against an UNSEEDED prefix (no kegs,
#     no db);
#   - no `EmptyOutput` (or any error.* backtrace) leaks into the frame stream;
#   - the tab bar renders (every tab cycles in turn) so the empty tabs are live.
#
# Usage:   MT_BIN=./zig-out/bin/malt ./scripts/e2e/tui_fresh_prefix_launch.sh
# Exit:    0 on pass, 1 on failure, 2 when the binary or pty tooling is missing.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=scripts/lib/tui_pty.sh
# shellcheck disable=SC1091 # sourced lib resolved at runtime; absent when this file is linted alone
source "$ROOT/scripts/lib/tui_pty.sh"

tui_pty_guard
tui_pty_make_prefix # deliberately NO tui_pty_seed_kegs — a fresh, db-less prefix
trap 'rm -rf "$TUI_PREFIX"' EXIT

fail() {
  echo "tui-fresh-prefix: FAIL — $*" >&2
  exit 1
}

CAP="$TUI_PREFIX/cap.bin"
# Launch on Search, then four `tab`s walk Installed, Outdated, Services, Doctor —
# each lazily loads its (empty) `--json` on entry, so every loader's empty path
# is exercised in one run.
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

echo "$out" | grep -q "EXIT_STATUS=0" || fail "mt tui did not launch+quit 0 on a fresh prefix ($out)"

# The boot/lazy loads must not have crashed: no error backtrace in the stream.
grep -qa "EmptyOutput" "$CAP" && fail "EmptyOutput leaked into the frame — the fresh-prefix load still crashes"
grep -qa "error\." "$CAP" && fail "an error.* backtrace leaked into the frame on a fresh prefix"

# The tab bar rendered, so the empty tabs are live (not a blank/wedged screen).
grep -qa "Installed" "$CAP" || fail "tab bar never rendered on a fresh prefix"

echo "tui-fresh-prefix: OK — empty prefix launches, cycles all tabs, quits clean"
