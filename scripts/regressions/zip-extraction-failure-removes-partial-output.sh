#!/usr/bin/env bash
# ZIP decoder failures must reclaim partial output while validation failures
# leave the destination intact.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

grep -Fq 'test "extractZip removes partial output when unzip cannot create an entry"' tests/archive_extract_symlink_test.zig
zig build test-bin
env -u MALT_CACHE MALT_PREFIX=/tmp/malt-test-prefix zig-out/test-bin/archive_extract_symlink_test
env -u MALT_CACHE MALT_PREFIX=/tmp/malt-test-prefix zig-out/test-bin/archive_test
