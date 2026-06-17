#!/usr/bin/env bash
# scripts/e2e/tui_doctor_fix_roundtrip.sh
#
# The Doctor-fix round-trip: pressing `f` on a fixable finding drops the
# alt-screen, re-execs the real `mt doctor --fix <class>`, re-enters, and
# refreshes the pane to the post-fix findings. This is the doctor sibling of
# tui_delegation_roundtrip.sh (uninstall), and it guards a specific seam:
# `mt doctor` exits non-zero by *severity* (1 = warnings), not by pass/fail, so
# a successful fix of a warning-class finding still exits 1. The inline runner
# must tolerate that severity exit and still run the refresh — otherwise the
# pane keeps its pre-fix findings behind a spurious "doctor fix failed" banner.
#
# Asserts:
#   - the delegated `mt doctor --fix` actually ran (its "swept" line is in the
#     stream), i.e. `f` still delegates;
#   - no "doctor fix failed" banner — a severity exit must not read as a fault;
#   - the post-fix frame no longer shows the orphan's warning detail
#     ("mt purge --store-orphans"), proving the in-session refresh ran.
#
# The fixture is a complete prefix (all expected dirs present, bin on PATH) so
# the seeded orphan is the *only* finding — it sorts to the top, is selected on
# load, and its detail pane carries the warning string we assert on. If the
# directory_structure check's expected set changes, update DIRS below.
#
# Usage:   MT_BIN=./zig-out/bin/malt ./scripts/e2e/tui_doctor_fix_roundtrip.sh
# Exit:    0 on pass, 1 on failure, 2 when the binary or pty tooling is missing.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=scripts/lib/tui_pty.sh
# shellcheck disable=SC1091 # sourced lib resolved at runtime; absent when this file is linted alone
source "$ROOT/scripts/lib/tui_pty.sh"

tui_pty_guard
tui_pty_make_prefix
trap 'rm -rf "$TUI_PREFIX"' EXIT

# Make the prefix structurally complete so directory_structure and prefix_on_path
# stay green — then the orphan is the sole finding and is the selected row.
DIRS=(store Cellar Caskroom opt bin lib tmp cache db)
for d in "${DIRS[@]}"; do mkdir -p "$TUI_PREFIX/$d"; done
export PATH="$TUI_PREFIX/bin:$PATH"

tui_pty_seed_orphan_store

fail() {
  echo "tui-doctor-fix: FAIL — $*" >&2
  exit 1
}

CAP="$TUI_PREFIX/cap.bin"
# Launch opens on Search; four `tab`s reach Doctor (search→installed→outdated→
# services→doctor). `f` fixes the selected orphan finding inline, then the pane
# refetches. The orphan sweep does not prompt, so no confirm input is needed.
out=$(
  tui_pty_drive "$CAP" 110 30 <<'ACT'
settle 0.4
send \t
settle 0.3
send \t
settle 0.3
send \t
settle 0.3
send \t
settle 0.7
send f
settle 1.4
mark DONE
send q
quitwait 1.5
ACT
)
echo "$out" | grep -q "EXIT_STATUS=0" || fail "mt tui did not exit 0 on q ($out)"

# The real subcommand ran inline (its output landed in the captured stream).
grep -qa "swept .* orphaned store entr" "$CAP" || fail "no 'swept' output — mt doctor --fix was not delegated"

# A severity exit must not be misread as a failure: no error banner anywhere.
grep -qa "doctor fix failed" "$CAP" && fail "spurious 'doctor fix failed' banner — severity exit treated as a fault"

# The pane refreshed: the orphan's warning detail is gone from the final frame.
# ("mt purge --store-orphans" is the warn-only detail string; the swept line does
#  not contain it, so a match in the post-DONE frame means stale, unrefreshed.)
perl -0777 -e '
  my $data = do { local $/; <STDIN> };
  my ($final) = $data =~ /\n\@\@DONE\@\@(.*)\z/s;
  defined $final or die "no final frame after DONE\n";
  $final !~ /mt purge --store-orphans/ or die "orphan warning still shown after refresh\n";
' <"$CAP" || fail "pane did not refresh after the delegated fix"

echo "tui-doctor-fix: OK — f re-execs real mt doctor --fix and refreshes the pane"
