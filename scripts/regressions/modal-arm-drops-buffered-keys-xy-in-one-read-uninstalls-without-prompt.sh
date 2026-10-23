#!/usr/bin/env bash
# Regression: a key that arms the uninstall prompt must drop the rest of the
# read and the queued input, so a buffered "y" cannot confirm a prompt the user
# never saw. Runs the inline test through a root-level shim, then the pty e2e
# that drives the real run loop (skipped when pty tooling is missing).

set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
shim="$root/.regress-modal-arm.$$.zig"
trap 'rm -f "$shim"' EXIT
printf 'test { _ = @import("src/tui/app.zig"); }\n' >"$shim"
filter='a key that arms a modal guard drops the rest of the read'
out=$(cd "$root" && env -u MALT_PREFIX -u MALT_CACHE \
  zig test "$shim" --test-filter "$filter" 2>&1) && rc=0 || rc=$?
# an unmatched filter still passes, so require the target test's name
if ! grep -Fq "app.test.$filter" <<<"$out"; then
  echo "FAIL: test '$filter' not found - guard removed or renamed" >&2
  exit 1
fi
if [ "$rc" -ne 0 ]; then
  echo "FAIL: keys buffered behind the arming key still reach the prompt" >&2
  echo "$out" >&2
  exit 1
fi

# Own session, so a stalled pty driver dies with the alarm and never stops on the tty.
# TERM first so the e2e trap removes its /tmp prefix; KILL only after a grace period.
run_with_timeout() {
  local secs="$1"
  shift
  perl -MPOSIX -e '
    my $secs = shift;
    my $pid = fork // die "fork: $!";
    if ($pid == 0) { POSIX::setsid() // die "setsid: $!"; exec @ARGV or exit 127 }
    my $stop = sub {
      my $code = shift;
      kill TERM => -$pid;
      for (1 .. 20) { last if waitpid($pid, WNOHANG) == $pid; select undef, undef, undef, 0.1 }
      kill KILL => -$pid;
      waitpid $pid, 0;
      exit $code;
    };
    $SIG{ALRM} = sub { $stop->(124) };
    $SIG{INT} = sub { $stop->(130) };
    $SIG{TERM} = sub { $stop->(143) };
    alarm $secs;
    waitpid $pid, 0;
    exit(($? >> 8) || ($? & 127 ? 128 + ($? & 127) : 0));
  ' "$secs" "$@"
}

cd "$root"
zig build >/dev/null
rc=0
MT_BIN="$root/zig-out/bin/malt" run_with_timeout 90 scripts/e2e/tui_uninstall_prompt_before_paste.sh || rc=$?
case "$rc" in
0) echo "ok: a key that arms the prompt drops the rest of the read" ;;
2)
  # exit 2 = no pty tooling; CI must not pass without running the loop test
  if [ -n "${CI:-}" ]; then
    echo "FAIL: pty e2e cannot run on CI" >&2
    exit 1
  fi
  echo "ok: predicate holds; pty e2e skipped (tooling missing)"
  ;;
124)
  echo "FAIL: pty e2e timed out" >&2
  exit 1
  ;;
130 | 143)
  echo "FAIL: pty e2e was interrupted" >&2
  exit 1
  ;;
*)
  echo "FAIL: pty e2e failed (reason above)" >&2
  exit 1
  ;;
esac
