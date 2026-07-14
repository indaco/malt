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
# `intersectWithDb` transitively pulls SQLite, whose `c_sqlite` module only
# exists inside the build graph — so the harness reuses the build's own wiring
# (the `src/lib.zig` module root + translated C modules + vendored sqlite3.c)
# rather than a raw `zig test` that can't resolve it. malt is a dependency
# module, so only the driver's single assertion runs, not the whole suite.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network required; finishes well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Translate the C-interop headers the malt module depends on, mirroring
# build.zig's addTranslateC set (sqlite needs vendor/ on its include path).
zig translate-c -I "$ROOT/vendor/" "$ROOT/c/sqlite.h" >"$TMP/c_sqlite.zig" 2>/dev/null
zig translate-c "$ROOT/c/clonefile.h" >"$TMP/c_clonefile.zig" 2>/dev/null
zig translate-c "$ROOT/c/mount.h" >"$TMP/c_mount.zig" 2>/dev/null

# A revisioned keg: DB carries bare version + revision; snapshot carries the
# revision-qualified `installed`. The intersect must keep it listed.
cat >"$TMP/driver.zig" <<'ZIG'
const std = @import("std");
const outdated = @import("malt").cli_outdated;

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

if zig test -OReleaseSafe \
  --dep malt -Mroot="$TMP/driver.zig" \
  --dep c_sqlite --dep c_clonefile --dep c_mount \
  -Mmalt="$ROOT/src/lib.zig" -lc -I "$ROOT/vendor/" -I "$ROOT/c/" \
  -cflags -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_THREADSAFE=1 -DSQLITE_DQS=0 -- "$ROOT/vendor/sqlite3.c" \
  -Mc_sqlite="$TMP/c_sqlite.zig" \
  -Mc_clonefile="$TMP/c_clonefile.zig" \
  -Mc_mount="$TMP/c_mount.zig" >/dev/null 2>&1; then
  echo "PASS: cached outdated keeps revision-bumped formulas"
else
  echo "FAIL: cached outdated dropped a revision-bumped formula (intersect compared revision-qualified installed against bare version)" >&2
  exit 1
fi
