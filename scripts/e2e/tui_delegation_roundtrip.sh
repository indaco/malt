#!/usr/bin/env bash
# scripts/e2e/tui_delegation_roundtrip.sh
#
# The delegation principle: the TUI never reimplements a mutation — it drops the
# alt-screen, re-execs the real `mt <subcommand>`, then re-enters and refreshes
# the pane. This proves that round-trip end-to-end with `x` (uninstall) on the
# Installed tab against a disposable fixture store.
#
# Asserts:
#   - the delegated `mt uninstall` actually ran (its real output is in the
#     stream) and completed (the seeded keg is gone from the store);
#   - the dashboard dropped and re-entered the alt-screen around the child (a
#     second alt-screen enter), i.e. the inline re-exec really happened;
#   - the pane refreshed afterwards — the uninstalled package no longer appears
#     in the final frame.
#
# Usage:   MT_BIN=./zig-out/bin/malt ./scripts/e2e/tui_delegation_roundtrip.sh
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
  echo "tui-delegation: FAIL — $*" >&2
  exit 1
}

CAP="$TUI_PREFIX/cap.bin"
# Launch opens on the Search tab; one `tab` reaches Installed. `x` raises the
# one-key uninstall guard; `y` confirms and delegates to the real
# `mt uninstall solopkg`, then the Installed pane refetches.
out=$(
  tui_pty_drive "$CAP" 90 24 <<'ACT'
settle 0.4
send \t
settle 0.4
send x
settle 0.4
send y
settle 1.2
mark DONE
send q
quitwait 1.5
ACT
)
echo "$out" | grep -q "EXIT_STATUS=0" || fail "mt tui did not exit 0 on q ($out)"

# The real subcommand ran inline (its output landed in the captured stream).
grep -qa "uninstalled" "$CAP" || fail "no 'uninstalled' output — mt uninstall was not delegated"

# It completed: the seeded keg is gone from the store.
count=$(tui_pty_keg_count)
[[ "$count" == "0" ]] || fail "keg still present after delegated uninstall (count=$count)"

# The alt-screen was dropped and re-entered around the child — a second enter.
enter=$(grep -c -a -F $'\x1b[?1049h' "$CAP" || true)
[[ "$enter" -ge "2" ]] || fail "expected >=2 alt-screen enters (drop+re-enter), got $enter"

# The pane refreshed: the uninstalled package is absent from the final frame.
perl -0777 -e '
  my $data = do { local $/; <STDIN> };
  my ($final) = $data =~ /\n\@\@DONE\@\@(.*)\z/s;
  defined $final or die "no final frame after DONE\n";
  $final !~ /solopkg/ or die "uninstalled package still shown after refresh\n";
' <"$CAP" || fail "pane did not refresh after the delegated uninstall"

echo "tui-delegation: OK — in-TUI action re-execs real mt and refreshes the pane"
