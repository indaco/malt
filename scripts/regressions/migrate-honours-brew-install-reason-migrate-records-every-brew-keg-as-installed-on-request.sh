#!/usr/bin/env bash
# Regression: `mt migrate` must record the brew receipt's install reason.
#
# The bug: every keg moved from a Homebrew prefix was recorded as
# `install_reason='direct'` and receipted as `installed_on_request: true`.
# The brew receipt's `installed_on_request` bit was never read - the API
# path never opened it, and the local-Cellar fallback parsed the receipt
# but discarded the bit. A migrated prefix therefore had no dependency rows:
# bundle dump, backup, purge's orphan scope and link --isolate --all all
# treated former brew dependencies as top-level formulae.
#
# Two arms, both offline:
#   1. the bit is parsed and plumbed; the three hard-coded sites are gone;
#   2. the migrate integration suite, which pins receipt false -> row
#      dependency through the local-Cellar fallback.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

# --- Arm 1: the reason is read from the brew receipt, not hard-coded ---------
if ! grep -Fq -- "on_request" src/core/install_receipt.zig; then
  echo "FAIL: parseInstallReceipt does not extract installed_on_request" >&2
  exit 1
fi
if grep -Fq -- '"", tap, true);' src/core/cellar.zig; then
  echo "FAIL: materializeFromLocalCellar still writes is_direct=true" >&2
  exit 1
fi
# The "direct" literal also lives in two test blocks, so pair the negative
# grep with the positive one instead of asserting zero occurrences.
if grep -Fq -- '.install_reason = "direct",' src/cli/migrate/keg.zig &&
  ! grep -Fq -- 'if (receipt.on_request) "direct" else "dependency"' src/cli/migrate/keg.zig; then
  echo "FAIL: migrate fallback still records every keg as direct" >&2
  exit 1
fi
if grep -Fq -- 'keg.path, "direct", false' src/cli/migrate/keg.zig; then
  echo "FAIL: migrateKeg primary path still records every keg as direct" >&2
  exit 1
fi

# --- Arm 2: the integration suite pins receipt false -> row dependency -------
if ! grep -Fq -- "installed_on_request" tests/migrate_smoke_test.zig; then
  echo "FAIL: migrate smoke test does not cover the brew receipt reason" >&2
  exit 1
fi
BIN="$ROOT/zig-out/test-bin/migrate_smoke_test"
if ! zig build test-bin >/dev/null 2>&1; then
  echo "FAIL: could not build the test binaries (zig build test-bin)" >&2
  exit 1
fi
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/malt-reg-migrate-reason.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
if ! MALT_PREFIX="$SCRATCH" "$BIN" >"$SCRATCH/log" 2>&1; then
  echo "FAIL: a brew dependency was migrated as installed on request" >&2
  tail -n 30 "$SCRATCH/log" >&2
  exit 1
fi

echo "OK: migrate records the brew receipt's install reason"
