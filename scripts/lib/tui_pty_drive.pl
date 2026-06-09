#!/usr/bin/perl
# scripts/lib/tui_pty_drive.pl
#
# PTY driver for the `mt tui` end-to-end tests. BSD script(1) cannot set or
# resize a pseudo-terminal's window size, so it cannot exercise the dashboard's
# resize path; this driver uses the base-system `IO::Pty` (ships with macOS
# system Perl under /System/Library/Perl/Extras — no Xcode CLT needed) to run
# `mt tui` under a real pty whose winsize we control via TIOCSWINSZ.
#
# Usage:
#   perl tui_pty_drive.pl <capfile> <cols> <rows> -- <cmd> [args...]  < actions
#
# The action program is read from stdin, one action per line:
#   mark LABEL        write "\n@@LABEL@@\n" into the capture (phase separator)
#   send BYTES        write BYTES to the pty (\t \n \r \e \xHH escapes honoured)
#   settle [secs]     read+capture until output goes idle (default 0.6s window)
#   resize COLS ROWS  TIOCSWINSZ the pty; the kernel delivers SIGWINCH
#   quitwait [secs]   wait for the child to exit, capturing its final bytes
#
# Captured bytes (raw, control sequences intact) go to <capfile>. The line
# "EXIT_STATUS=<n>" is printed to stdout: the child's exit code, or -999 if it
# had to be killed (never exited on its own).

use strict;
use warnings;
use IO::Pty;
use IO::Select;
use Time::HiRes qw(time sleep);

my ($capfile, $cols, $rows, @cmd) = @ARGV;
die "usage: tui_pty_drive.pl <capfile> <cols> <rows> <cmd...>\n" unless @cmd;

open(my $cap, '>:raw', $capfile) or die "open $capfile: $!";

my $pty = IO::Pty->new;
$pty->set_winsize($rows, $cols);    # initial geometry the child's first TIOCGWINSZ sees

my $pid = fork // die "fork: $!";
if (!$pid) {
  # Child: adopt the slave as the controlling terminal so `mt tui` sees a tty.
  $pty->make_slave_controlling_terminal;
  my $slave = $pty->slave;
  open(STDIN,  '<&', $slave) or die "child stdin: $!";
  open(STDOUT, '>&', $slave) or die "child stdout: $!";
  open(STDERR, '>&', $slave) or die "child stderr: $!";
  close($slave);
  close($pty);
  exec(@cmd) or die "exec @cmd: $!";
}

$pty->close_slave;
my $sel = IO::Select->new($pty);

# Read whatever the child has emitted into the capture until it falls idle for
# `idle` seconds or the `total` window elapses. Tolerant timing (poll/settle,
# not a fixed sleep) keeps the e2e from being flaky under load.
sub drain {
  my ($total, $idle) = @_;
  $total //= 0.6;
  $idle  //= 0.2;
  my $end  = time + $total;
  my $last = time;
  while (time < $end) {
    if ($sel->can_read(0.04)) {
      my $buf;
      my $n = sysread($pty, $buf, 65536);
      last if !defined $n || $n == 0;
      print $cap $buf;
      $last = time;
    } elsif (time - $last > $idle) {
      last;
    }
  }
}

sub unescape {
  my $s = shift // '';
  $s =~ s/\\x([0-9A-Fa-f]{2})/chr(hex($1))/ge;    # \xHH — arbitrary control bytes (e.g. \x03 = Ctrl-C)
  $s =~ s/\\t/\t/g;
  $s =~ s/\\n/\n/g;
  $s =~ s/\\r/\r/g;
  $s =~ s/\\e/\e/g;
  return $s;
}

sub child_alive { return waitpid($pid, 1) == 0 }

drain();    # the first paint, before any action

my $status = -1;
while (my $line = <STDIN>) {
  chomp $line;
  next if $line eq '';
  my ($op, $rest) = split /\s+/, $line, 2;
  if ($op eq 'mark') {
    print $cap "\n\@\@$rest\@\@\n";
  } elsif ($op eq 'send') {
    syswrite($pty, unescape($rest));
    drain();
  } elsif ($op eq 'settle') {
    drain($rest // 0.6);
  } elsif ($op eq 'resize') {
    my ($c, $r) = split /\s+/, $rest;
    $pty->set_winsize($r, $c);
    drain();
  } elsif ($op eq 'quitwait') {
    my $timeout = $rest // 1.5;
    my $end = time + $timeout;
    while (time < $end) {
      my $w = waitpid($pid, 1);
      if ($w != 0) {
        # Report the child's own exit code (or -signal if it was signalled),
        # not the raw wait status, so callers can assert e.g. the exit-2 refusal.
        $status = ($? & 127) ? -($? & 127) : ($? >> 8);
        last;
      }
      drain(0.1, 0.05);
    }
    if (child_alive()) {
      kill 'KILL', $pid;
      waitpid($pid, 0);
      $status = -999;
    }
    drain(0.3, 0.1);    # capture the terminal-restore bytes emitted on exit
  } else {
    die "unknown action: $line\n";
  }
}

close($cap);
print "EXIT_STATUS=$status\n";
