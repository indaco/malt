#!/usr/bin/env bash
# Regression: the cached `outdated` serve path filters the snapshot against the
# live DB with `intersectWithDb`. The snapshot's `installed` field is written
# revision-qualified (`pkgVersion(version, revision)`, e.g. "1.2.3_1"), but the
# intersect compared it against the bare `kegs.version` column ("1.2.3"). For any
# keg with a non-zero Homebrew revision the two strings never matched, so the
# entry was treated as "upgraded since snapshot" and silently dropped — cached
# `outdated` hid revision-bumped formulas that `--refresh` lists and `upgrade`
# still upgrades.
#
# No CLI subcommand exercises the pure intersect without seeding a DB and a
# snapshot, so a standalone ReleaseSafe `zig test` harness drives
# `intersectWithDb` directly with a revisioned keg row and a revision-qualified
# snapshot entry. The harness must keep the entry (len == 1); the pre-fix code
# drops it (len == 0) and the assertion fails.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network required; finishes well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

# The harness imports the module via a repo-relative path, so it must sit at the
# repo root: outdated.zig's sibling imports (`../app_ctx.zig`, `../db/...`) only
# resolve from inside the source tree's module boundary.
HARNESS="$ROOT/.cached-outdated-revision-regression.zig"
trap 'rm -f "$HARNESS"' EXIT

cat >"$HARNESS" <<'ZIG'
const std = @import("std");
const outdated = @import("src/cli/outdated.zig");

// A revisioned keg: DB carries bare version + revision; snapshot carries the
// revision-qualified `installed`. The intersect must keep it listed.
test "cached outdated keeps a revision-bumped formula" {
    const a = std.testing.allocator;
    const rows = [_]outdated.KegRow{
        .{ .name = "foo", .version = "1.2.3", .revision = 1 },
    };
    const snap = [_]outdated.OutdatedEntry{
        .{
            .name = @constCast("foo"),
            .installed = @constCast("1.2.3_1"),
            .latest = @constCast("1.3.0"),
        },
    };
    const out = try outdated.intersectWithDb(a, &rows, &snap);
    defer {
        for (out) |e| {
            a.free(e.name);
            a.free(e.installed);
            a.free(e.latest);
        }
        a.free(out);
    }
    try std.testing.expectEqual(@as(usize, 1), out.len);
}
ZIG

if (cd "$ROOT" && zig test -OReleaseSafe "$HARNESS") >/dev/null 2>&1; then
  echo "PASS: cached outdated keeps revision-bumped formulas"
else
  echo "FAIL: cached outdated dropped a revision-bumped formula (intersect compared revision-qualified installed against bare version)" >&2
  exit 1
fi
