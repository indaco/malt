#!/usr/bin/env bash
# scripts/e2e/tui_resize_reflow.sh
#
# The dashboard's headline promise: resize the terminal mid-session and the
# frame reflows to the new geometry while the selection and scroll position
# survive (no data refetch, no jump to the top). The pure layout is unit-tested
# against synthetic sizes; this proves it end-to-end under a real SIGWINCH.
#
# Drives a 30-row Installed list at 100x14, moves the selection deep enough to
# scroll, then shrinks the pty to 56x12 and asserts:
#   - the frame width tracks the new column count (separator 100 -> 56), so the
#     frame genuinely reflowed;
#   - the same package stays selected (reverse-video cursor on the same name);
#   - that package is still visible after the resize (the viewport re-clamped
#     around the selection rather than resetting to the top).
#
# Usage:   MT_BIN=./zig-out/bin/malt ./scripts/e2e/tui_resize_reflow.sh
# Exit:    0 on pass, 1 on failure, 2 when the binary or pty tooling is missing.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=scripts/lib/tui_pty.sh
# shellcheck disable=SC1091 # sourced lib resolved at runtime; absent when this file is linted alone
source "$ROOT/scripts/lib/tui_pty.sh"

tui_pty_guard
tui_pty_make_prefix
trap 'rm -rf "$TUI_PREFIX"' EXIT
tui_pty_seed_kegs 30

fail() {
  echo "tui-resize: FAIL — $*" >&2
  exit 1
}

CAP="$TUI_PREFIX/cap.bin"
# 12 down-arrows put the selection well below the fold at height 14, so the
# viewport has already scrolled before the resize. After the wide->narrow
# reflow, shrink below the usable minimum (12 cols < the 20-col floor) to prove
# the clean "terminal too small" fallback, then restore the original size to
# prove the dashboard recovers with its selection intact.
out=$(
  tui_pty_drive "$CAP" 100 14 <<'ACT'
send \e[B\e[B\e[B\e[B\e[B\e[B\e[B\e[B\e[B\e[B\e[B\e[B
settle 0.5
mark PRE
resize 56 12
settle 0.5
mark POST
resize 12 6
settle 0.5
mark TINY
resize 100 14
settle 0.5
mark RECOVER
send q
quitwait 1.5
ACT
)
echo "$out" | grep -q "EXIT_STATUS=0" || fail "mt tui did not exit 0 on q ($out)"

# Per-phase frames, split on the marks: PRE (100 cols), POST (56 cols), TINY
# (12 cols, below the floor), RECOVER (back to 100 cols). For each list frame
# extract the selected package (bare reverse-video before a pkg name) and the
# separator width (a run of U+2500 box-drawing chars).
perl -0777 -e '
  my $data = do { local $/; <STDIN> };
  my ($pre)     = $data =~ /\A(.*?)\n\@\@PRE\@\@/s;
  my ($post)    = $data =~ /\n\@\@PRE\@\@(.*?)\n\@\@POST\@\@/s;
  my ($tiny)    = $data =~ /\n\@\@POST\@\@(.*?)\n\@\@TINY\@\@/s;
  my ($recover) = $data =~ /\n\@\@TINY\@\@(.*?)\n\@\@RECOVER\@\@/s;
  defined && length or die "missing a resize phase region\n"
    for ($pre, $post, $tiny, $recover);
  sub sel  { my $b = shift; my @m = $b =~ /\x1b\[7m(pkg\d+)/g; return $m[-1] }
  sub seps { my $b = shift; my @r = $b =~ /((?:\x{e2}\x{94}\x{80})+)/g;
             my $w = 0; for (@r) { my $n = length($_)/3; $w = $n if $n > $w } return $w }
  my ($psel, $pw) = (sel($pre),  seps($pre));
  my ($qsel, $qw) = (sel($post), seps($post));
  my ($rsel, $rw) = (sel($recover), seps($recover));
  defined $psel or die "no selection in PRE frame\n";
  defined $qsel or die "no selection in POST frame\n";
  defined $rsel or die "no selection in RECOVER frame\n";
  # Wide -> narrow reflow, selection + scroll preserved.
  $pw >= 90 or die "PRE separator width $pw, expected ~100 (frame did not start wide)\n";
  $qw <= 60 or die "POST separator width $qw, expected ~56 (frame did not reflow narrower)\n";
  $qw <  $pw or die "frame width did not shrink on resize ($pw -> $qw)\n";
  $psel eq $qsel or die "selection changed across resize ($psel -> $qsel)\n";
  $post =~ /\Q$qsel\E/ or die "selected package $qsel not visible after resize\n";
  # Below the floor: clean fallback, no corrupt list rows.
  $tiny =~ /terminal/ or die "no terminal-too-small fallback below the minimum size\n";
  $tiny !~ /pkg\d/ or die "list rows leaked into the too-small fallback frame\n";
  # Recovery: list returns at full width with the original selection intact.
  $rw >= 90 or die "RECOVER separator width $rw, expected ~100 (did not restore wide)\n";
  $rsel eq $psel or die "selection lost across the too-small excursion ($psel -> $rsel)\n";
  print "selected=$psel preserved; width $pw -> $qw -> fallback -> $rw\n";
' <"$CAP" || fail "resize assertions failed (see message above)"

echo "tui-resize: OK — reflow, too-small fallback, and recovery all preserve selection"
