#!/usr/bin/env bash
# Regression for MALT_CACHE reaching wipe/snapshot I/O unvalidated.
# The env value used to flow verbatim into `purge --wipe`'s target list,
# so an absolute `..`-bearing value deleted whatever it resolved to, and a
# relative value tripped the std absolute-path assert and aborted the
# process with a stack trace. The fix routes MALT_CACHE through the same
# boundary check MALT_PREFIX already has, refusing malformed values with
# exit 78 before any I/O. `mt tui` reads the env itself, so it is gated by
# the same check before the alt-screen can swallow the message. The passive
# version notice resolves its own state file from MALT_CACHE and is
# best-effort, so there a non-absolute root skips the notice instead.
#
# Usage: scripts/regressions/malt-cache-validated-before-wipe-malt-cache-unvalidated-and-wiped.sh
# Requirements: built `malt` binary at $MALT_BIN or zig-out/bin/malt.
# The TUI probe drives a pty when perl IO::Pty is available and falls back
# to a non-tty launch otherwise. No network.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
export MT_BIN="$BIN"
# shellcheck source=scripts/lib/tui_pty.sh
source "$ROOT/scripts/lib/tui_pty.sh"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

S=$(mktemp -d)
trap 'rm -rf "$S"' EXIT
mkdir -p "$S/prefix/db" "$S/victim/keep" "$S/rel" "$S/ok"
echo x >"$S/victim/keep/f"

# 1. relative value -> refused at the boundary, no panic
set +e
out=$(cd "$S" && MALT_PREFIX="$S/prefix" MALT_CACHE=rel "$BIN" purge --wipe --dry-run 2>&1)
rc=$?
set -e
[[ $rc -eq 78 ]] || {
  echo "FAIL: relative MALT_CACHE rc=$rc (want 78)"
  printf '%s\n' "$out" | head -5
  exit 1
}
grep -q 'refusing to use MALT_CACHE' <<<"$out" || {
  echo "FAIL: no refusal message for relative MALT_CACHE"
  exit 1
}
if grep -Eq 'panic:|reached unreachable' <<<"$out"; then
  echo "FAIL: relative MALT_CACHE still panics"
  exit 1
fi

# 2. absolute `..` traversal -> refused, the sibling dir survives
set +e
MALT_PREFIX="$S/prefix" MALT_CACHE="$S/prefix/db/../../victim" "$BIN" purge --wipe --yes >/dev/null 2>&1
rc=$?
set -e
[[ $rc -eq 78 ]] || {
  echo "FAIL: traversal MALT_CACHE rc=$rc (want 78)"
  exit 1
}
[[ -e "$S/victim/keep/f" ]] || {
  echo "FAIL: wipe followed .. and deleted the sibling dir"
  exit 1
}

# 3. positive control: a plain absolute override is still honoured
mkdir -p "$S/prefix/db"
MALT_PREFIX="$S/prefix" MALT_CACHE="$S/ok" "$BIN" purge --wipe --yes >/dev/null 2>&1 || {
  echo "FAIL: valid absolute MALT_CACHE refused"
  exit 1
}
[[ ! -e "$S/ok" ]] || {
  echo "FAIL: valid cache dir not wiped"
  exit 1
}

# 4. the dashboard is gated by the same check, before the alt-screen
mkdir -p "$S/prefix/db"
if perl -MIO::Pty -e 1 >/dev/null 2>&1 && perl -c "$TUI_PTY_DRIVER" >/dev/null 2>&1; then
  cap="$S/tui_cap.bin"
  status=$(
    cd "$S" || exit 1
    export MALT_PREFIX="$S/prefix" MALT_CACHE=rel MALT_OFFLINE=1
    unset CI NO_COLOR
    tui_pty_drive "$cap" 90 24 <<<'quitwait 1.5'
  )
  grep -q 'EXIT_STATUS=78' <<<"$status" || {
    echo "FAIL: tui with relative MALT_CACHE on a tty: $status (want EXIT_STATUS=78)"
    exit 1
  }
  if grep -aEq 'panic:|reached unreachable' "$cap"; then
    echo "FAIL: tui with relative MALT_CACHE still panics"
    exit 1
  fi
  grep -aq 'refusing to use MALT_CACHE' "$cap" || {
    echo "FAIL: no refusal message from tui on a tty"
    exit 1
  }
else
  set +e
  out=$(cd "$S" && MALT_PREFIX="$S/prefix" MALT_CACHE=rel "$BIN" tui </dev/null 2>&1)
  rc=$?
  set -e
  [[ $rc -eq 78 ]] || {
    echo "FAIL: tui with relative MALT_CACHE rc=$rc (want 78)"
    exit 1
  }
  grep -q 'refusing to use MALT_CACHE' <<<"$out" || {
    echo "FAIL: no refusal message from tui"
    exit 1
  }
fi

# 5. the passive version notice never aborts a command that succeeded.
# Every CI marker the notifier honours is scrubbed, or the probe passes
# vacuously on a runner; the assume-tty seam stands in for a real terminal.
set +e
out=$(cd "$S" && env -u CI -u GITHUB_ACTIONS -u BUILDKITE -u JENKINS_URL -u TF_BUILD -u CIRCLECI -u GITLAB_CI \
  MALT_PREFIX="$S/prefix" MALT_CACHE=rel MALT_VERSION_NOTIFIER_ASSUME_TTY=1 "$BIN" list 2>&1)
rc=$?
set -e
[[ $rc -eq 0 ]] || {
  echo "FAIL: list with relative MALT_CACHE rc=$rc (want 0)"
  printf '%s\n' "$out" | head -5
  exit 1
}
if grep -Eq 'panic:|reached unreachable' <<<"$out"; then
  echo "FAIL: version notice still panics on a relative MALT_CACHE"
  exit 1
fi

echo "ok: MALT_CACHE validated before wipe, tui launch and the version notice"
