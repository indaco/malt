#!/usr/bin/env bash
# Regression: INSTALL_RECEIPT.json must carry the keg's real install reason.
#
# The bug: `materializeWithCellar` wrote every receipt through a shim that
# pinned `installed_on_request: true` / `installed_as_dependency: false`,
# while the DB row for the same keg said `install_reason='dependency'`.
# Homebrew-compatible tooling that reads receipts therefore treated every
# malt dependency as user-requested.
#
# Two arms, both offline:
#   1. the constant-true shim stays gone and the bit reaches the writer from
#      the install pool worker and the dep-promotion path;
#   2. the cellar integration suite, which pins that a dependency materialize
#      (cold and relocated-cache warm path alike) writes a dependency receipt.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

# --- Arm 1: the bit is threaded, not hard-coded -------------------------------
if grep -Fq -- "store_sha256, null, true)" src/core/cellar.zig; then
  echo "FAIL: cellar.zig still writes the receipt with a hard-coded is_direct=true" >&2
  exit 1
fi
declare -a GUARDS=(
  "src/core/cellar.zig|on_request|the on_request parameter"
  "src/cli/install/download.zig|.is_dep = job.is_dep|the pool worker's is_dep forward"
  "src/cli/install.zig|writeInstallReceiptFull|the promotion receipt rewrite"
  "tests/cellar_test.zig|installed_as_dependency|the dependency receipt test"
)
for g in "${GUARDS[@]}"; do
  IFS='|' read -r file needle label <<<"$g"
  if ! grep -Fqs -- "$needle" "$file"; then
    echo "FAIL: $label is missing from $file" >&2
    exit 1
  fi
done

# --- Arm 2: the receipt mirrors the reason at runtime -------------------------
BIN="$ROOT/zig-out/test-bin/cellar_test"
if ! zig build test-bin >/dev/null 2>&1; then
  echo "FAIL: could not build the test binaries (zig build test-bin)" >&2
  exit 1
fi
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/malt-reg-receipt.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
if ! MALT_PREFIX="$SCRATCH" "$BIN" >"$SCRATCH/log" 2>&1; then
  echo "FAIL: a dependency keg was receipted as installed on request" >&2
  tail -n 30 "$SCRATCH/log" >&2
  exit 1
fi

echo "OK: INSTALL_RECEIPT.json mirrors the keg's install reason"
