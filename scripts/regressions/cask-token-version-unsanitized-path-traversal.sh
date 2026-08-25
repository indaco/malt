#!/usr/bin/env bash
# Regression: a cask whose JSON `token` or `version` carries a path-traversal
# payload must be rejected at parse time, before either field reaches a
# filesystem sink.
#
# The bug: parseCask copied `token` and `version` verbatim out of the cask
# JSON with no predicate between parse and use. Both are interpolated as raw
# path components downstream — the cache dest `<cache>/<token>-<version><ext>`,
# the DMG mount `<prefix>/tmp/cask_mount_<token>`, `Caskroom/<token>/<version>`,
# and on uninstall `deleteTree("<prefix>/Caskroom/<token>")`. A `..` or `/` in
# either field is honoured by the kernel as a real path hop, so a compromised
# or third-party tap could write the artifact, the Caskroom, or a privileged
# installer target outside the prefix — and later delete outside it.
#
# The fix adds one traversal guard in parseCask, at the single ingestion choke
# point, that rejects an empty value, `.`/`..`, or an embedded `/`, `..`, or
# NUL in `token` or `version` (charset-agnostic so real versions still pass).
#
# No CLI surface drives parseCask offline without standing up a local tap, and
# the guard fires before any download, so it is exercised by the colocated unit
# tests in the inline suite (`lib_tests`). This script builds and runs only that
# binary: it takes about a minute and needs no network. A pass means every
# inline test — including the traversal-rejection guard — held; a regression
# flips that binary to a non-zero exit.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

SRC="src/core/cask.zig"
TEST_NAME="parseCask rejects path-traversal in token or version"

# If the guard or its test is ever dropped, the unit binary would go green
# vacuously. Fail loudly instead: both the predicate call and the test must be
# present in the source.
if ! grep -Fqs -- "$TEST_NAME" "$SRC"; then
  echo "FAIL: the traversal-rejection guard test is missing from $SRC" >&2
  exit 1
fi
if ! grep -Fqs -- "isPathComponent" "$SRC"; then
  echo "FAIL: the parseCask path-component guard is missing from $SRC" >&2
  exit 1
fi

BIN="$ROOT/zig-out/test-bin/lib_tests"
# Always rebuild so the binary reflects current source — a prebuilt
# lib_tests could predate the guard. Zig's cache makes a no-op rebuild
# cheap, so this stays well under the time budget.
if ! zig build test-bin >/dev/null 2>&1; then
  echo "FAIL: could not build the unit test binary (zig build test-bin)" >&2
  exit 1
fi

# The runner has no per-test filter, so run the inline suite and judge by its
# summary line and exit code. Pre-fix, parseCask accepts the traversal payloads
# the guard test feeds it, so that test fails and the binary exits non-zero.
OUT=$("$BIN" 2>&1) && STATUS=0 || STATUS=$?
if [[ "$STATUS" -ne 0 ]]; then
  echo "FAIL: cask token/version traversal was accepted at parse time" >&2
  printf '%s\n' "$OUT" | grep -iE "failed|leaked|panic" >&2 || true
  exit 1
fi

echo "PASS: cask token/version path-traversal rejected before any path use"
