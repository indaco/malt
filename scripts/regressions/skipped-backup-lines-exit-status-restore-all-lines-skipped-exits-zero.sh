#!/usr/bin/env bash
# Regression: a restore that skipped backup lines (control byte, not a package
# name, a flag-shaped name, malt itself, a versioned service) must say so and
# exit non-zero, so `mt restore f || alert` notices a file that installed less
# than it lists. Survivors are still attempted.
# Lines restore never reads as entries (unknown kind, comments) stay exit 0.
#
# Offline throughout: the only survivor is a service, and a missing service
# is warn-and-continue, so its exit status isolates the skip signal.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"

# `zig build test` does not refresh the binary; a stale one would mask the fix.
zig build >/dev/null

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# A developer shell's MALT_* must not point the run at a real prefix or cache.
while IFS='=' read -r var _; do unset "$var"; done < <(env | grep '^MALT_' || true)
export NO_COLOR=1 MALT_NO_EMOJI=1 MALT_OFFLINE=1 MALT_PREFIX="$tmp/p"
mkdir -p "$tmp/p"

fail() {
  printf '  ✗ %s\n' "$1" >&2
  printf '%s\n' "$out" >&2
  exit 1
}

printf 'formula ../../etc\n' >"$tmp/shape.txt"
printf 'formula foo\033[2J\n' >"$tmp/ctrl.txt"
printf 'formula malt\n' >"$tmp/self.txt"
printf 'formula -wget\nservice foo 1.0\n' >"$tmp/dropped.txt"
printf 'formula ../../etc\nservice nosuchsvc\n' >"$tmp/partial.txt"
printf 'potato wget\n# comment\n' >"$tmp/junk.txt"

rc=0 && out=$("$BIN" restore "$tmp/shape.txt" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "all lines skipped (name shape) exited 0"
grep -q 'nothing to restore' <<<"$out" || fail "missing the nothing-to-restore line"

rc=0 && out=$("$BIN" restore --quiet "$tmp/ctrl.txt" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "all lines skipped (control byte, --quiet) exited 0"
grep -q 'nothing to restore' <<<"$out" || fail "--quiet hid the nothing-to-restore line"

rc=0 && out=$("$BIN" restore "$tmp/self.txt" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "all lines skipped (malt itself) exited 0"

rc=0 && out=$("$BIN" restore "$tmp/dropped.txt" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "a flag-shaped name or versioned service line exited 0"
grep -q '2 lines skipped' <<<"$out" || fail "a flag-shaped name or versioned service line was dropped silently"

rc=0 && out=$("$BIN" restore "$tmp/partial.txt" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "partly skipped file exited 0"
grep -q 'nosuchsvc' <<<"$out" || fail "the surviving line was not attempted"

rc=0 && out=$("$BIN" restore "$tmp/junk.txt" 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "a file with no entries and no skips must still exit 0"

rc=0 && out=$("$BIN" restore --dry-run "$tmp/partial.txt" 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "--dry-run is a preview and must still exit 0"

rc=0 && out=$("$BIN" restore --dry-run "$tmp/shape.txt" 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "--dry-run of an all-skipped file must still exit 0"
grep -q 'nothing to restore' <<<"$out" || fail "--dry-run calls an all-skipped file empty"

printf '  ✓ restore exits non-zero when it skipped backup lines\n'
