#!/usr/bin/env bash
# scripts/e2e/tui_header_counts.sh
#
# The dashboard header must show the live `<n> kegs` and `<m> outdated` counts on
# launch, sourced from cheap DB reads, without the user entering the Installed or
# Outdated tabs. Inline tests cover the count-refresh functions in isolation; this
# proves the launch path wires them into the header under a real pty.
#
# Asserts (with 8 seeded kegs, a fresh prefix → 0 outdated):
#   - the header reads "8 kegs" at launch, before any tab switch;
#   - the header reads "0 outdated" at launch;
#   - the Installed tab was never entered (no seeded row appears), so the count
#     came from the launch prime, not a lazy tab load.
#
# Usage:   MT_BIN=./zig-out/bin/malt ./scripts/e2e/tui_header_counts.sh
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
  echo "tui-header-counts: FAIL — $*" >&2
  exit 1
}

CAP="$TUI_PREFIX/cap.bin"
# Launch on Search, let the count primes return, then quit — never switching tabs,
# so a passing keg count can only have come from the launch prime.
out=$(
  tui_pty_drive "$CAP" 90 24 <<'ACT'
settle 0.6
send q
quitwait 1.5
ACT
)

echo "$out" | grep -q "EXIT_STATUS=0" || fail "mt tui did not exit 0 on q ($out)"

grep -qa "8 kegs" "$CAP" || fail "header never showed the seeded keg count at launch"
grep -qa "0 outdated" "$CAP" || fail "header never showed the outdated count at launch"
grep -qa "pkg01" "$CAP" && fail "Installed tab was entered — count did not come from the launch prime"

echo "tui-header-counts: PASS"
