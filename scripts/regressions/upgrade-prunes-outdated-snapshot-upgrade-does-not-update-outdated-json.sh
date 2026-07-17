#!/usr/bin/env bash
# Regression: a real (non-dry-run) `mt upgrade` mutates `kegs`/`casks` but left
# `{prefix}/cache/outdated.json` untouched, so the snapshot kept listing the
# just-upgraded package at its pre-upgrade `installed` version for the rest of
# the 5-minute TTL. `mt outdated` self-heals (it filters the snapshot through
# the live DB with `intersectWithDb`), but the TUI's warm read parses the file
# raw with no DB intersect — so the Outdated tab painted an already-upgraded
# package until the background audit overwrote it.
#
# The fix reconciles the snapshot against the live DB after a real upgrade:
# entries whose keg has moved are dropped, untouched entries survive, and
# `generated_at_ms` is preserved so survivors keep the lease they earned
# rather than a falsely extended one.
#
# Driving `mt upgrade` end-to-end would need the network and a real bottle, so
# — matching the offline style of
# `cached-outdated-drops-revision-bumped-packages.sh` — a standalone
# ReleaseSafe `zig test` harness seeds a DB plus a hand-written snapshot file
# and drives the prune directly, then reads the file back.
#
# `pruneSnapshot` transitively pulls SQLite, whose `c_sqlite` module only
# exists inside the build graph — so the harness reuses the build's own wiring
# (the `src/lib.zig` module root + translated C modules + vendored sqlite3.c)
# rather than a raw `zig test` that can't resolve it.
#
# Asserts, in one driver:
#   1. an upgraded formula (DB moved past the snapshot's `installed`) is dropped
#   2. an untouched formula survives the prune
#   3. an upgraded cask is dropped from its own array
#   4. `generated_at_ms` is preserved, not re-stamped
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

cat >"$TMP/driver.zig" <<'ZIG'
const std = @import("std");
const malt = @import("malt");
const outdated = malt.cli_outdated;
const sqlite = malt.sqlite;
const schema = malt.schema;

// `jq` upgraded 1.7.1 -> 1.8.0 and `firefox` (cask) 120 -> 121; `wget` never
// moved. The snapshot predates all of it.
const stamp: i64 = 1_700_000_000_000;

test "a real upgrade prunes the upgraded packages out of the cached snapshot" {
    const a = std.testing.allocator;
    const io = std.Options.debug_io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_dir = buf[0..try std.Io.Dir.realPath(tmp.dir, io, &buf)];

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    // The live DB as it stands *after* the upgrade.
    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path)
        \\VALUES ('jq', 'jq', '1.8.0', 's', '/c'), ('wget', 'wget', '1.24', 's', '/c');
    );
    try db.exec(
        \\INSERT INTO casks (token, name, version, url)
        \\VALUES ('firefox', 'Firefox', '121', 'https://example.invalid/f.dmg');
    );

    // The snapshot as written *before* the upgrade.
    try outdated.writeSnapshot(io, a, cache_dir, .{
        .generated_at_ms = stamp,
        .formulas = &.{
            .{ .name = @constCast("jq"), .installed = @constCast("1.7.1"), .latest = @constCast("1.8.0") },
            .{ .name = @constCast("wget"), .installed = @constCast("1.24"), .latest = @constCast("1.25") },
        },
        .casks = &.{
            .{ .name = @constCast("firefox"), .installed = @constCast("120"), .latest = @constCast("121") },
        },
    });

    outdated.pruneSnapshot(io, a, &db, cache_dir);

    const snap = outdated.readSnapshot(io, a, cache_dir) orelse return error.SnapshotVanished;
    defer outdated.freeSnapshot(a, snap);

    // The upgraded formula is gone; the untouched one survives.
    try std.testing.expectEqual(@as(usize, 1), snap.formulas.len);
    try std.testing.expectEqualStrings("wget", snap.formulas[0].name);

    // The upgraded cask is gone from its own array.
    try std.testing.expectEqual(@as(usize, 0), snap.casks.len);

    // Survivors keep the lease they earned — a re-stamp would falsely extend
    // the 5-minute TTL.
    try std.testing.expectEqual(stamp, snap.generated_at_ms);
}
ZIG

if zig test -OReleaseSafe \
  --dep malt -Mroot="$TMP/driver.zig" \
  --dep c_sqlite --dep c_clonefile --dep c_mount \
  -Mmalt="$ROOT/src/lib.zig" -lc -I "$ROOT/vendor/" -I "$ROOT/c/" \
  -cflags -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_THREADSAFE=1 -DSQLITE_DQS=0 -- "$ROOT/vendor/sqlite3.c" \
  -Mc_sqlite="$TMP/c_sqlite.zig" \
  -Mc_clonefile="$TMP/c_clonefile.zig" \
  -Mc_mount="$TMP/c_mount.zig" >"$TMP/out.log" 2>&1; then
  echo "PASS: a real upgrade prunes upgraded packages from the cached snapshot"
else
  echo "FAIL: the cached outdated snapshot still lists a package the DB says is already upgraded" >&2
  echo "----- harness output -----" >&2
  cat "$TMP/out.log" >&2
  exit 1
fi
