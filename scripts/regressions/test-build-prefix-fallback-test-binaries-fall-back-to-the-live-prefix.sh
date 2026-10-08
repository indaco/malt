#!/usr/bin/env bash
# Regression: a test build with MALT_PREFIX unset must not use the live
# /opt/malt install. Scripts can run test binaries without the env that
# build.zig sets. Tests can also unset it during a run. Then the source
# fallback is the only protection against real deletes in the live prefix.
#
# The probe compiles only src/fs, so the script is fast. It uses no network
# and does not touch /opt/malt. It also fails if a source file keeps its own
# "/opt/malt" env fallback.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
S=$(mktemp -d /tmp/mt_prefix_fallback.XXXXXX)
trap 'rm -rf "$S"' EXIT

command cp -R "$ROOT/src/fs" "$S/fs"
cat >"$S/fs/probe_test.zig" <<'EOF'
const std = @import("std");
const atomic = @import("atomic.zig");
test "probe: unset MALT_PREFIX resolves under /tmp/malt-" {
    const got = try atomic.maltPrefixChecked();
    try std.testing.expect(std.mem.startsWith(u8, got, "/tmp/malt-"));
}
EOF

out=$(cd "$S/fs" && env -u MALT_PREFIX -u MALT_CACHE zig test --cache-dir "$S/zig-cache" probe_test.zig 2>&1) && rc=0 || rc=$?
if [[ $rc -ne 0 ]]; then
  echo "FAIL: test build falls back to the live prefix:" >&2
  echo "$out" >&2
  exit 1
fi
if ! grep -q 'probe: unset MALT_PREFIX.*OK\|All [0-9]* tests passed' <<<"$out"; then
  echo "FAIL: probe did not run" >&2
  exit 1
fi

# A MALT_PREFIX read must not fall back to the live prefix in any form. The
# match can span lines but stops at the end of the statement.
fallback_re='"MALT_PREFIX"\)[^;]*?\b(?:orelse|else)\s+(?:return\s+)?(?:"/opt/malt"|(?:atomic\.)?default_prefix\b)'
hits=$(find "$ROOT/src" -name '*.zig' -exec perl -0777 -ne "print \"\$ARGV\n\" if m{$fallback_re}" {} +)
if [[ -n $hits ]]; then
  echo "FAIL: a site keeps its own /opt/malt fallback:" >&2
  echo "$hits" >&2
  exit 1
fi

echo "PASS"
