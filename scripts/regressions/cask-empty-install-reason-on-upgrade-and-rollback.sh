#!/usr/bin/env bash
# Regression: upgrade and rollback printed the bare error name when a cask had
# nothing to place, and a dmg with no bundle kept the generic failure.
#
# Static guard plus unit run: the call sites have no unit seam, so each must
# use the shared error text.
#
# Usage: scripts/regressions/cask-empty-install-reason-on-upgrade-and-rollback.sh
# Requirements: zig, grep. No network access required. Creates no temp state.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

grep -q 'pub fn installErrorText' src/cli/install.zig || fail "shared error text missing"
grep -q 'test "installErrorText' src/cli/install.zig || fail "error text test missing"
[[ $(grep -c 'install_mod.installErrorText(re_err)' src/cli/upgrade.zig) -eq 2 ]] ||
  fail "upgrade reinstall sites do not use the shared error text"
grep -q 'install_mod.reportCaskInstallFailure(allocator, &parsed_cask, in_err' src/cli/upgrade.zig ||
  fail "upgrade failure line does not explain an empty cask"
! grep -q 'Failed to upgrade tap cask {s}: {s}' src/cli/upgrade.zig ||
  fail "tap upgrade repeats the folded error name"
grep -q 'install_mod.installErrorText(e)' src/cli/rollback.zig ||
  fail "rollback reinstall site does not use the shared error text"
# A dmg with no bundle must report the same cause as a zip.
awk '/findAppInDir\(self.io, mount_point,/{getline; if ($0 ~ /NothingToPlace/) ok=1} END{exit !ok}' src/core/cask.zig ||
  fail "dmg path does not return NothingToPlace"

if [[ -n "${MALT_STATIC_ONLY:-}" ]]; then
  echo "OK: upgrade, rollback and dmg explain an empty cask (static-only)"
  exit 0
fi

env -u MALT_PREFIX zig build test || fail "unit tests red"
echo "OK: upgrade, rollback and dmg explain an empty cask"
