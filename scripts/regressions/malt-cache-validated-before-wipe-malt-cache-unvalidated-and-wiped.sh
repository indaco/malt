#!/usr/bin/env bash
# Regression for MALT_CACHE reaching wipe/snapshot I/O unvalidated: an
# absolute `..`-bearing value was deleteTree'd, a relative one tripped the
# std isAbsolute assert and aborted. Now refused at the env boundary (exit
# 78); `mt tui` is gated the same way; the version notice skips instead.
#
# Usage: scripts/regressions/malt-cache-validated-before-wipe-malt-cache-unvalidated-and-wiped.sh
# Requirements: built `malt` binary at $MALT_BIN or zig-out/bin/malt. No network.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
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

# 3b. a space is legal in a cache root; only the install prefix carries a charset
mkdir -p "$S/prefix/db" "$S/with space"
MALT_PREFIX="$S/prefix" MALT_CACHE="$S/with space" "$BIN" purge --wipe --yes >/dev/null 2>&1 || {
  echo "FAIL: absolute MALT_CACHE with a space refused"
  exit 1
}
[[ ! -e "$S/with space" ]] || {
  echo "FAIL: cache dir with a space not wiped"
  exit 1
}

# 4. the dashboard is gated by the same check; it runs before the tty check,
# so a non-tty launch proves it without a pty
mkdir -p "$S/prefix/db"
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

# 4b. the prefix half of the same gate
set +e
out=$(cd "$S" && MALT_PREFIX=rel MALT_CACHE="$S/ok" "$BIN" tui </dev/null 2>&1)
rc=$?
set -e
[[ $rc -eq 78 ]] || {
  echo "FAIL: tui with relative MALT_PREFIX rc=$rc (want 78)"
  exit 1
}
grep -q 'refusing to use MALT_PREFIX' <<<"$out" || {
  echo "FAIL: no refusal message from tui for MALT_PREFIX"
  exit 1
}

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

echo "ok: MALT_CACHE validated before wipe, tui launch and the version notice"
