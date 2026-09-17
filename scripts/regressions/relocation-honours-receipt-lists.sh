#!/usr/bin/env bash
# Regression: relocation trusts the file lists a bottle's INSTALL_RECEIPT.json
# carries (`changed_files`, `linkage_files`, `binary_relocation_files`) and
# visits only those files instead of walking the whole keg. Two guards:
#
#   1. The colocated integration test drives a receipt with lists through the
#      public materialize entry point and asserts an unlisted file keeps its
#      placeholder. If the lists were ignored, that test fails.
#   2. A cold install of imagemagick (the largest keg whose bottle carries all
#      three lists) followed by a clean doctor placeholder check. Whether the
#      bottle shipped its receipt decides which relocation path ran; the
#      script reports which, and the doctor check must be clean either way,
#      so incomplete lists on a real bottle cannot pass unnoticed.
#
# Usage: scripts/regressions/relocation-honours-receipt-lists.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt; jq; network to
# formulae.brew.sh / ghcr.io. Honours $MALT_GITHUB_TOKEN (falls back to
# `gh auth token`) to dodge the anonymous GitHub API cap.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}
command -v jq >/dev/null 2>&1 || {
  echo "this regression needs jq on PATH" >&2
  exit 2
}
if [[ -z "${MALT_GITHUB_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
  MALT_GITHUB_TOKEN="$(gh auth token 2>/dev/null || true)"
  export MALT_GITHUB_TOKEN
fi

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

# 1. The behavioural guard lives in a colocated test; if it is ever deleted
#    the live run below would prove nothing about the lists.
GUARD="materializeWithCellar relocates only the files the bottle receipt lists"
grep -qF -- "$GUARD" "$ROOT/tests/cellar_receipt_lists_test.zig" ||
  fail "guard test missing from tests/cellar_receipt_lists_test.zig"
(cd "$ROOT" && zig build test-bin >/dev/null 2>&1) ||
  fail "could not build the test binaries (zig build test-bin)"
LINE=$("$ROOT/zig-out/test-bin/cellar_receipt_lists_test" 2>&1 | grep -F -- "$GUARD" || true)
[[ "$LINE" == *OK ]] || fail "guard test did not pass: ${LINE:-not run}"
pass "listed-only relocation guard passes"

# 2. Live: a real bottle relocates to a keg doctor finds clean.
PKG=imagemagick
PREFIX="/tmp/mt_reloc_lists_$$"
rm -rf "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1

"$BIN" install "$PKG" >/dev/null 2>&1 || fail "cold install of $PKG failed"
pass "cold install of $PKG"

# The bottle's own receipt survives in the store; malt overwrites the keg's.
RECEIPT=$(find "$PREFIX/store" -path "*/$PKG/*/INSTALL_RECEIPT.json" | head -1)
if [[ -n "$RECEIPT" ]] && [[ "$(jq -r '[.changed_files, .linkage_files, .binary_relocation_files] | map(type == "array") | all' "$RECEIPT")" == "true" ]]; then
  pass "bottle receipt carries the three lists; relocation took the list path"
else
  pass "bottle shipped no receipt lists; relocation walked the keg"
fi

OUT=$("$BIN" doctor --json 2>/dev/null || true)
SEV=$(printf '%s' "$OUT" | jq -r '.checks[] | select(.id == "mach_o_placeholders") | .severity')
[[ "$SEV" == "ok" ]] || fail "doctor placeholder check is '$SEV' after relocation"
pass "doctor finds no unpatched placeholders"

echo "relocation honours the bottle's receipt lists: OK"
