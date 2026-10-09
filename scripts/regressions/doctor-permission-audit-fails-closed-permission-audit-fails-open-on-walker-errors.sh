#!/usr/bin/env bash
# Regression: the `malt doctor` prefix permission audit must not report a
# clean prefix when part of the tree cannot be audited. Pre-fix, an error
# while entering a subdirectory ended the walk silently and the partial
# finding list was reported as `ok`.
#
# The fixture is deterministic: the only entry is a directory with mode 000.
# Entering it fails, so pre-fix the walk ends with no finding, whatever the
# readdir order. The mode is not itself weak, so an audit that skips the
# subtree also fails here. The control steps prove a readable clean prefix is
# still `ok` and a weak file is still reported.
#
# Usage: scripts/regressions/doctor-permission-audit-fails-closed-permission-audit-fails-open-on-walker-errors.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt; not root.
# No network access required.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}
if [[ $(id -u) -eq 0 ]]; then
  echo "SKIP: root ignores the directory mode"
  exit 0
fi

PREFIX=$(mktemp -d /tmp/mt_perm_audit.XXXXXX)
trap 'chmod -R u+rwx "$PREFIX" 2>/dev/null; rm -rf "$PREFIX"' EXIT
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

mkdir "$PREFIX/a_locked"
chmod 000 "$PREFIX/a_locked"

OUT=$("$BIN" doctor </dev/null 2>&1 || true)
LINE=$(grep -m1 'Prefix permissions' <<<"$OUT") || fail "no Prefix permissions row; got: $OUT"
grep -qi 'walk failed' <<<"$LINE" ||
  fail "audit reported a clean prefix with an unreadable subtree: $LINE"
pass "audit warns when a subtree cannot be read"

chmod 755 "$PREFIX/a_locked"

OUT=$("$BIN" doctor </dev/null 2>&1 || true)
LINE=$(grep -m1 'Prefix permissions' <<<"$OUT") || fail "control: no Prefix permissions row; got: $OUT"
grep -qiE 'walk failed|weak permissions' <<<"$LINE" &&
  fail "control: audit warned on a readable clean prefix: $LINE"
pass "control: audit is ok on a readable clean prefix"

mkdir "$PREFIX/b_open"
touch "$PREFIX/b_open/evil"
chmod 666 "$PREFIX/b_open/evil"

OUT=$("$BIN" doctor </dev/null 2>&1 || true)
grep -q 'b_open/evil' <<<"$OUT" || fail "control: other-writable file not reported; got: $OUT"
pass "control: audit reports an other-writable file in a readable tree"

echo "doctor permission audit fails closed on an unreadable subtree: OK"
