#!/usr/bin/env bash
# Regression: the implicit `mt vulns` walk must attempt every tap keg instead
# of silently dropping it.
#
# The bug: the command's only advisory source was the per-formula API field,
# which is computed for homebrew/core only, so `readInstalled` counted every
# tap keg as "not covered" and the run exited 0 - a tap-installed tool with an
# open advisory was reported as clean. The fix resolves the keg's recipe from
# its tap at the installed commit and asks OSV.dev about the source url.
#
# Two gates, no external network:
#   1. Binary: a tap keg whose tap points at a closed loopback port. Before
#      the fix it is dropped (`not_covered:1`, exit 0). After the fix the
#      recipe fetch is attempted and fails, so the keg lands in `unchecked`
#      and the scan exits 2 - the same contract a core 404 already has.
#   2. Fixture: the vulns integration suite drives a loopback OSV + raw `.rb`
#      fixture and asserts a seeded tap keg produces a real advisory row.
#
# Exits 0 when tap kegs are scanned, non-zero when they are dropped.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

MT="$ROOT/zig-out/bin/malt"
if [[ ! -x "$MT" ]]; then
  echo "FAIL: build first (zig build)" >&2
  exit 1
fi

# A trailing slash on TMPDIR would put "//" in the prefix, which malt refuses.
TMP=${TMPDIR:-/tmp}
PREFIX=$(mktemp -d "${TMP%/}/malt-vulns-tap-XXXXXX")
trap 'rm -rf "$PREFIX"' EXIT
mkdir -p "$PREFIX/db" "$PREFIX/cache"
MALT_PREFIX="$PREFIX" "$MT" list >/dev/null 2>&1 || true

# Port 1 is never listened on, so the raw fetch fails at connect and the run
# stays offline. `forge` gitea keeps the loopback host in the raw url (the
# github arm hard-codes its hosts).
sqlite3 "$PREFIX/db/malt.db" <<'SQL'
INSERT INTO taps (name, url, github_owner, github_repo, host, forge)
VALUES ('someone/tap', 'https://127.0.0.1:1/someone/tap', 'someone', 'tap', '127.0.0.1:1', 'gitea');
INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, tap, tap_commit_sha)
VALUES ('cliamp', 'someone/tap/cliamp', '2.2.0', 0, '', '/c/x', 'someone/tap', '0000000000000000000000000000000000000000');
SQL

set +e
OUT=$(MALT_PREFIX="$PREFIX" MALT_CACHE="$PREFIX/cache" "$MT" --json vulns 2>/dev/null)
RC=$?
set -e

case "$OUT" in
*'"not_covered":1'*)
  echo "FAIL: tap keg silently dropped from the walk: $OUT" >&2
  exit 1
  ;;
esac
if [[ "$RC" -ne 2 || "$OUT" != *'"unchecked":["cliamp"]'* ]]; then
  echo "FAIL: expected the tap keg in unchecked with exit 2, got rc=$RC $OUT" >&2
  exit 1
fi

TEST_NAME="a tap keg is scanned against OSV from its recipe url"
TEST_SRC="tests/vulns_test.zig"
# If the fixture test is ever deleted, the runner would report "no tests" and
# pass. Fail loudly instead.
if ! grep -Rqs -- "$TEST_NAME" "$TEST_SRC"; then
  echo "FAIL: the OSV fixture test is missing from $TEST_SRC" >&2
  exit 1
fi

BIN="$ROOT/zig-out/test-bin/vulns_test"
if [[ ! -x "$BIN" ]]; then
  if ! zig build test-bin >/dev/null 2>&1; then
    echo "FAIL: could not build the test binaries (zig build test-bin)" >&2
    exit 1
  fi
fi
if ! "$BIN"; then
  echo "FAIL: vulns integration tests (OSV fixture) failed" >&2
  exit 1
fi

echo "PASS: tap kegs are scanned via OSV"
