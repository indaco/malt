#!/usr/bin/env bash
# Regression: malt reported a cask whose URL ends in `.zip.<hash>` (Steam)
# as an unsupported format. Only the URL suffix chose the artifact type.
# Now the declared `container.type` wins. malt extracts and places a
# declared nested tarball, and a restore from history keeps the nested name.
#
# Unit and integration tests hold the pins. Half one checks that the tests
# are still in the source. Half two runs the binaries that carry them.
# No network.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T="$ROOT/tests"
SRC="$ROOT/src"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# 1. Static pins: a revert or a rename cannot pass silently.
TEST_PINS=(
  "a declared ZIP container upgrades offline despite a hash-suffixed URL"
  "a declared ZIP container installs offline despite a hash-suffixed URL"
  "a ZIP installs the app inside its declared nested tarball"
  "a nested-tarball cask restores from its history after the app is removed"
  "a same-version reinstall without a nested container clears the recorded name"
  "a nested-ZIP upgrade refuses a wildcard version before it removes the old app"
  "a tap ZIP cask upgrade refuses a wildcard version before its prefetch"
  "a nested ZIP whose token holds a wildcard is refused before the download"
  "a pinned plain ZIP with a wildcard version still installs"
  "a nested ZIP installs from a cache directory whose name holds a wildcard"
  "a pinned nested ZIP with an encrypted entry fails instead of waiting on a password"
  "a nested ZIP whose cache path holds a wildcard is refused before unzip expands it"
  "a nested entry that links outside the extracted ZIP is refused"
  "parseCask rejects a nested container path outside the extracted archive"
  "parseCask rejects a nested container path with a control byte"
  "parseCask keeps only a nested tarball so other nested casks stay on the ditto path"
)
for name in "${TEST_PINS[@]}"; do
  grep -rqF -- "test \"$name\"" "$T" || fail "missing pin test: $name"
done
SRC_PINS=(
  "variation overlay carries the variation's own container"
  "a declared container type wins over the URL suffix"
  "a null or typeless container falls back to the URL suffix"
  "only a wildcard in the ZIP file name is a pattern to unzip"
  "a nested ZIP is decoded with a dummy password and a plain ZIP by ditto"
  "an unpinned ZIP whose file name holds a wildcard is refused"
  "v18→v19 adds cask_versions.nested_container and leaves existing rows plain"
)
for name in "${SRC_PINS[@]}"; do
  grep -rqF -- "test \"$name\"" "$SRC" || fail "missing pin test: $name"
done

# 2. Behaviour: the inline pins run only in lib_tests.
(cd "$ROOT" && zig build test-bin >/dev/null 2>&1) ||
  fail "could not build the test binaries (zig build test-bin)"
for bin in cask_test install_download_only_test lib_tests; do
  env -u MALT_CACHE MALT_PREFIX=/tmp/malt-test-prefix "$ROOT/zig-out/test-bin/$bin" >/dev/null 2>&1 ||
    fail "$bin reports a failure"
done

echo "PASS: a declared cask container chooses the extractor and survives a restore"
