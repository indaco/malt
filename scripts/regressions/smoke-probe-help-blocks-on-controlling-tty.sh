#!/usr/bin/env bash
# Regression: the migrate smoke's --help probe must not inherit the
# operator's controlling terminal.
#
# The bug: run_with_timeout forked the probe with setpgrp only, so a TUI
# that ignores --help and opens /dev/tty blocked on the operator's
# terminal until the alarm fired and was reported as a broken migration
# (rc=124 on every flag, no output). Detached from the terminal the same
# binary fails fast with ENXIO, and its error line counts as output.
#
# The guard runs the smoke script's own run_with_timeout under a fresh
# controlling pty against a stand-in that reads /dev/tty; hitting the
# alarm means the probe still owns a terminal.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
SMOKE="scripts/smokes/smoke_migrate_parallel.sh"
# Guard against a vacuous green: the detach must still be in the wrapper.
rg -Fq -- "POSIX::setsid()" "$SMOKE" || {
  echo "FAIL: run_with_timeout no longer detaches from the controlling tty in $SMOKE" >&2
  exit 1
}
PROBE=$(mktemp -t smoke-probe.XXXXXX)
trap 'rm -f "$PROBE"' EXIT
{
  echo 'set -u'
  # Lift only the wrapper: the smoke script does real work at top level.
  sed -n '/^run_with_timeout() {/,/^}/p' "$SMOKE"
  echo "run_with_timeout 2 bash -c 'read -r _ </dev/tty'"
} >"$PROBE"
RC=$(
  python3 - "$PROBE" <<'PY'
import os, pty, select, sys
pid, fd = pty.fork()
if pid == 0:
    os.execv("/bin/bash", ["bash", sys.argv[1]])
while True:
    r, _, _ = select.select([fd], [], [], 5)
    if not r:
        break
    try:
        if not os.read(fd, 4096):
            break
    except OSError:
        break
_, st = os.waitpid(pid, 0)
print(os.waitstatus_to_exitcode(st))
PY
)
# Exactly the stand-in's own failure (read: /dev/tty ENXIO): 124 is the
# alarm, anything else means the wrapper itself broke rather than probed.
if [[ "$RC" -eq 124 ]]; then
  echo "FAIL: the --help probe blocked on the controlling tty until the alarm (rc=124)" >&2
  exit 1
elif [[ "$RC" -ne 1 ]]; then
  echo "FAIL: run_with_timeout did not run the stand-in (rc=$RC)" >&2
  exit 1
fi
echo "PASS: the --help probe runs without a controlling tty"
