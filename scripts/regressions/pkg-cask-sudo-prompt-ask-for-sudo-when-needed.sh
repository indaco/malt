#!/usr/bin/env bash
# Regression: a PKG-cask install must refuse to escalate via
# `sudo installer -pkg … -target /` when there is no controlling terminal.
#
# The bug: the only guard before escalation was a warn() line. Off a TTY
# (piped stdin, CI, a `--json` consumer) `sudo` reads the password from
# /dev/tty, finds none, and fails — but the call runs through child.run,
# which captures stderr, so `sudo: a terminal is required …` surfaced only
# post-mortem, after a silent stall and a non-zero exit. The fix probes stdin
# for a TTY before the install and refuses up front with malt's own
# actionable message ("requires an interactive terminal"); on a TTY it also
# requires an explicit confirmation before the system-wide install.
#
# No CLI surface reaches the PKG artifact-type branch offline without standing
# up a local tap and a real download, and the guard fires before that branch —
# so the behaviour is pinned by the colocated unit test in the inline suite
# (lib_tests). This script asserts the predicate, the gate, both call sites,
# and the user-facing message are all present (so the suite cannot go green
# vacuously), then builds and runs that binary. Offline, about a minute.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

OUT="src/ui/output.zig"
CLI="src/cli/install.zig"
LOCAL="src/cli/install/local.zig"
UPGRADE="src/cli/upgrade.zig"
ROLLBACK="src/cli/rollback.zig"
TEST_NAME="isInteractive treats a non-terminal stdin as non-interactive"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# If the guard or its test is dropped, the unit binary would go green
# vacuously. Fail loudly instead: predicate, test, gate, every call site, and
# the actionable message must all be present in source. Every verb that can
# reach `sudo installer` — install, upgrade, rollback — must route through the
# one gate, or that verb regresses to the silent-stall behaviour.
grep -Fqs -- "$TEST_NAME" "$OUT" || fail "the non-tty guard test is missing from $OUT"
grep -Fqs -- "fn isInteractive" "$OUT" || fail "the stdin TTY predicate is missing from $OUT"
grep -Fqs -- "fn confirmPkgSudo" "$CLI" || fail "the PKG sudo gate is missing from $CLI"
grep -Fqs -- "interactive terminal" "$CLI" || fail "the actionable non-tty message is missing from $CLI"
grep -Fqs -- "confirmPkgSudo(" "$CLI" || fail "the brew-API install PKG path does not route through the sudo gate"
grep -Fqs -- "confirmPkgSudo(" "$LOCAL" || fail "the tap install PKG path does not route through the sudo gate"
grep -Fqs -- "confirmPkgSudo(" "$UPGRADE" || fail "the cask upgrade PKG path does not route through the sudo gate"
grep -Fqs -- "confirmPkgSudo(" "$ROLLBACK" || fail "the cask rollback PKG path does not route through the sudo gate"

BIN="$ROOT/zig-out/test-bin/lib_tests"
# Always rebuild so the binary reflects current source — a prebuilt
# lib_tests could predate the guard. Zig's cache makes a no-op rebuild cheap.
zig build test-bin >/dev/null 2>&1 || fail "could not build the unit test binary (zig build test-bin)"

# The runner has no per-test filter, so run the inline suite and judge by exit
# code. Pre-fix, the guard predicate does not exist and its test cannot hold,
# so the binary exits non-zero.
RUN=$("$BIN" 2>&1) && STATUS=0 || STATUS=$?
if [[ "$STATUS" -ne 0 ]]; then
  echo "FAIL: PKG-cask non-tty sudo guard unit test did not hold" >&2
  printf '%s\n' "$RUN" | grep -iE "failed|leaked|panic" >&2 || true
  exit 1
fi

echo "PASS: PKG-cask install refuses sudo escalation off a TTY"
