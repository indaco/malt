#!/usr/bin/env bash
# A quiet child must receive trickled keys within the uninstall guard's window,
# even when the host coalesces short sleeps into much longer waits.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/SlowSleep.pm" <<'PERL'
package SlowSleep;
use Time::HiRes ();
use IO::Select ();
my $sleep = \&Time::HiRes::sleep;
my $can_read = \&IO::Select::can_read;
{
    no warnings 'redefine';
    *Time::HiRes::sleep = sub (;@) { $sleep->($_[0] + 0.25) };
    *IO::Select::can_read = sub {
        return () if defined $_[1] && $_[1] == 0;
        $can_read->(@_);
    };
}
1;
PERL

out=$(
  PERL5LIB="$TMP" PERL5OPT=-MSlowSleep /usr/bin/perl \
    "$ROOT/scripts/lib/tui_pty_drive.pl" "$TMP/cap" 80 24 \
    /usr/bin/perl -MPOSIX -e '
      my $term = POSIX::Termios->new;
      $term->getattr(0);
      $term->setlflag(0);
      $term->setcc(POSIX::VMIN(), 1);
      $term->setcc(POSIX::VTIME(), 0);
      $term->setattr(0, POSIX::TCSANOW());
      $| = 1;
      print "READY\n";
      while (sysread(STDIN, my $buf, 64)) { last if index($buf, "q") >= 0 }
    ' <<'ACTIONS'
trickle 1 0.03 x
put q
quitwait 1.5
ACTIONS
)

grep -q READY "$TMP/cap"
grep -q '^EXIT_STATUS=0$' <<<"$out"
gap=$(sed -n 's/^TRICKLE_MAX_GAP=//p' <<<"$out")
if ! awk -v g="$gap" 'BEGIN { exit !(g != "" && g < 0.25) }'; then
  echo "FAIL: completed PTY writes introduced a quiet window (${gap}s)" >&2
  exit 1
fi
echo "PASS: trickled PTY input stays continuous with coalesced sleeps (${gap}s)"
