#!/usr/bin/env bash
# Regression for MALT_CACHE reaching wipe/snapshot I/O unvalidated.
# The env value used to flow verbatim into `purge --wipe`'s target list,
# so an absolute `..`-bearing value deleted whatever it resolved to, and a
# relative value tripped the std absolute-path assert and aborted the
# process with a stack trace. The fix routes MALT_CACHE through the same
# boundary check MALT_PREFIX already has, refusing malformed values with
# exit 78 before any I/O.
#
# Usage: scripts/regressions/malt-cache-validated-before-wipe-malt-cache-unvalidated-and-wiped.sh
# Requirements: built `malt` binary at $MALT_BIN or zig-out/bin/malt.
# No network.

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

echo "ok: MALT_CACHE validated before wipe"
