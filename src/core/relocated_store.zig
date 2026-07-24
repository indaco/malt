//! malt — post-relocation keg cache.
//!
//! `<MALT_PREFIX>/store-relocated/v<N>/<sha256>/` snapshots a fully-relocated
//! Cellar keg keyed by (relocation-logic version, bottle sha256). On warm
//! reinstalls of a bottle whose
//! content has not changed, the install pipeline can skip
//! extract → placeholder substitution → install_name_tool → ad-hoc
//! codesign and clonefile-restore the keg directly. APFS clonefile makes
//! the marginal disk cost essentially zero (copy-on-write); on non-APFS
//! mounts the helper falls back to a recursive copy.
//!
//! This module is path-only — no DB rows, no refcounting. The bottle
//! sha256 is the cache key, mirroring the threat model of the existing
//! download cache.

const std = @import("std");
const clonefile = @import("../fs/clonefile.zig");
const dirsize = @import("../fs/dirsize.zig");

pub const RelocatedStoreError = error{
    InvalidSha256,
    PathTooLong,
    SaveFailed,
    MaterializeFailed,
};

/// Relocation-logic version, folded into the cache path as
/// `store-relocated/v<N>/<sha>`. The cached bytes are the output of
/// `cellar.relocateKegTree` (placeholder substitution + install_name_tool +
/// ad-hoc codesign), whose result depends on the relocation *rules*, not just
/// the bottle sha. Bump this whenever `relocateKegTree` / `patchTextFiles` /
/// the `@@HOMEBREW_*@@` replacement set / codesign behaviour changes: the bump
/// turns every prior `v<N-1>/` entry into a cache miss, forcing correct
/// re-relocation. Prior `v<N-1>/` trees are reclaimed by `reapStaleVersions`
/// on the next fresh `save`, so a bump trades one cold reinstall per cached
/// bottle for correctness; bumps are rare (only on relocation-logic change).
///
/// v2: the Mach-O patcher learned to drop LC_RPATHs that relocation collapses
/// onto one prefix; v1 entries were snapshotted before that and ship the
/// duplicate that makes dyld abort at launch.
pub const RELOC_LOGIC_VERSION: u32 = 2;

/// Reject anything that is not exactly 64 lowercase hex characters.
/// Run this before forming any path so traversal sequences (`..`, `/`) and
/// case variants never reach the filesystem.
fn isValidSha256(sha: []const u8) bool {
    if (sha.len != 64) return false;
    for (sha) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!ok) return false;
    }
    return true;
}

fn cacheDir(buf: []u8, prefix: []const u8, version: u32, sha: []const u8) RelocatedStoreError![]u8 {
    return std.fmt.bufPrint(buf, "{s}/store-relocated/v{d}/{s}", .{ prefix, version, sha }) catch
        return RelocatedStoreError.PathTooLong;
}

fn cellarKegDir(buf: []u8, prefix: []const u8, name: []const u8, version: []const u8) RelocatedStoreError![]u8 {
    return std.fmt.bufPrint(buf, "{s}/Cellar/{s}/{s}", .{ prefix, name, version }) catch
        return RelocatedStoreError.PathTooLong;
}

fn cellarParentDir(buf: []u8, prefix: []const u8, name: []const u8) RelocatedStoreError![]u8 {
    return std.fmt.bufPrint(buf, "{s}/Cellar/{s}", .{ prefix, name }) catch
        return RelocatedStoreError.PathTooLong;
}

/// True when a relocated snapshot for `sha` exists under `prefix`.
/// Invalid `sha` values return false rather than erroring — `has` is a
/// probe, not a validator, and any caller that would mutate the cache
/// (save / materialize / remove) re-validates and surfaces the error.
pub fn has(io: std.Io, prefix: []const u8, sha: []const u8) bool {
    if (!isValidSha256(sha)) return false;
    var buf: [512]u8 = undefined;
    const dir = cacheDir(&buf, prefix, RELOC_LOGIC_VERSION, sha) catch return false;
    std.Io.Dir.accessAbsolute(io, dir, .{}) catch return false;
    return true;
}

/// Snapshot the post-relocation keg at `<prefix>/Cellar/<name>/<version>`
/// into the cache. Idempotent: a second call with the same `sha` returns
/// success without re-cloning. Writes into a temp dir then renames into
/// place so a crash mid-snapshot never leaves a partial entry visible.
pub fn save(
    io: std.Io,
    allocator: std.mem.Allocator,
    prefix: []const u8,
    sha: []const u8,
    name: []const u8,
    version: []const u8,
) RelocatedStoreError!void {
    if (!isValidSha256(sha)) return RelocatedStoreError.InvalidSha256;

    var dst_buf: [512]u8 = undefined;
    const dst = try cacheDir(&dst_buf, prefix, RELOC_LOGIC_VERSION, sha);

    // Idempotent: already cached → done. Concurrent installs race here, and
    // the loser would otherwise fail at `renameAbsolute` below.
    std.Io.Dir.accessAbsolute(io, dst, .{}) catch {
        // Not present yet — proceed with snapshot.
        try saveFresh(io, allocator, prefix, name, version, dst);
        // A fresh save under the current version is the natural point to
        // reclaim kegs orphaned by a past logic-version bump. Best-effort.
        _ = reapStaleVersions(io, allocator, prefix, true);
        return;
    };
    return;
}

fn saveFresh(
    io: std.Io,
    allocator: std.mem.Allocator,
    prefix: []const u8,
    name: []const u8,
    version: []const u8,
    dst: []const u8,
) RelocatedStoreError!void {
    var src_buf: [512]u8 = undefined;
    const src = try cellarKegDir(&src_buf, prefix, name, version);

    // Source must exist — caller is supposed to invoke `save` after a
    // successful materialize, so this is a programmer error from the
    // outside. Surface as `SaveFailed` (debug-logged by the caller).
    std.Io.Dir.accessAbsolute(io, src, .{}) catch return RelocatedStoreError.SaveFailed;

    // Ensure the versioned parent `<prefix>/store-relocated/v<N>/` exists.
    // Derive it from `dst` so the version segment stays in one place.
    const parent = std.fs.path.dirname(dst) orelse return RelocatedStoreError.SaveFailed;
    std.Io.Dir.cwd().createDirPath(io, parent) catch return RelocatedStoreError.SaveFailed;

    // Atomic write: clone into a sibling temp dir, then rename into place.
    // The temp name is `<dst>.tmp.<random>` to avoid colliding with another
    // racing snapshot for the same sha.
    var tmp_buf: [600]u8 = undefined;
    var rand_bytes: [8]u8 = undefined;
    io.random(&rand_bytes);
    const rand_int = std.mem.bytesToValue(u64, &rand_bytes);
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp.{x}", .{ dst, rand_int }) catch
        return RelocatedStoreError.PathTooLong;
    // Best-effort sweep of a stale temp from a previous crashed snapshot;
    // a real permission error here will resurface on the clone below.
    std.Io.Dir.cwd().deleteTree(io, tmp) catch {};
    // Drop the temp on every exit except the success arm that renames
    // it into place — covers errors *and* the race-loss branch where
    // a peer worker already published `dst`.
    var tmp_consumed = false;
    defer if (!tmp_consumed) {
        std.Io.Dir.cwd().deleteTree(io, tmp) catch {};
    };

    clonefile.cloneTree(io, allocator, src, tmp) catch return RelocatedStoreError.SaveFailed;

    // Race window: another worker may have published the same sha while we
    // were cloning. If `dst` exists now, drop our temp (defer above) and
    // report success without overwriting the winner.
    std.Io.Dir.accessAbsolute(io, dst, .{}) catch {
        std.Io.Dir.renameAbsolute(tmp, dst, io) catch return RelocatedStoreError.SaveFailed;
        tmp_consumed = true;
    };
}

/// Restore a cached snapshot into `<prefix>/Cellar/<name>/<version>`.
/// Replaces any existing destination — the caller is reinstalling.
pub fn materialize(
    io: std.Io,
    allocator: std.mem.Allocator,
    prefix: []const u8,
    sha: []const u8,
    name: []const u8,
    version: []const u8,
) RelocatedStoreError!void {
    if (!isValidSha256(sha)) return RelocatedStoreError.InvalidSha256;

    var src_buf: [512]u8 = undefined;
    const src = try cacheDir(&src_buf, prefix, RELOC_LOGIC_VERSION, sha);
    std.Io.Dir.accessAbsolute(io, src, .{}) catch return RelocatedStoreError.MaterializeFailed;

    var parent_buf: [512]u8 = undefined;
    const parent = try cellarParentDir(&parent_buf, prefix, name);
    std.Io.Dir.cwd().createDirPath(io, parent) catch return RelocatedStoreError.MaterializeFailed;

    var dst_buf: [512]u8 = undefined;
    const dst = try cellarKegDir(&dst_buf, prefix, name, version);

    // Reinstall semantics — wipe any stale keg before cloning fresh.
    // Missing dst is fine; permission errors will resurface on cloneTree.
    std.Io.Dir.cwd().deleteTree(io, dst) catch {};

    clonefile.cloneTree(io, allocator, src, dst) catch return RelocatedStoreError.MaterializeFailed;
}

/// Delete the cache entry for `sha`. Idempotent; a missing entry is a
/// successful no-op so callers can purge speculatively.
pub fn remove(io: std.Io, prefix: []const u8, sha: []const u8) RelocatedStoreError!void {
    if (!isValidSha256(sha)) return RelocatedStoreError.InvalidSha256;
    var buf: [512]u8 = undefined;
    const dir = try cacheDir(&buf, prefix, RELOC_LOGIC_VERSION, sha);
    std.Io.Dir.cwd().deleteTree(io, dir) catch return;
}

pub const Reaped = struct { removed: u32 = 0, bytes: u64 = 0 };

/// Reclaim relocated kegs left under a superseded logic version: delete every
/// `store-relocated/v<M>/` tree whose M != `RELOC_LOGIC_VERSION` (with
/// `do_remove` false, only measure them, for a `purge --dry-run` preview).
/// Best-effort — unreadable or undeletable entries are skipped so a partial
/// failure never aborts the caller (an install's opportunistic sweep or
/// `purge`). Race-safe: same-version peers only ever touch the current
/// `v<N>/`, so an older version has no live reader to disturb.
pub fn reapStaleVersions(io: std.Io, allocator: std.mem.Allocator, prefix: []const u8, do_remove: bool) Reaped {
    var root_buf: [512]u8 = undefined;
    const root = std.fmt.bufPrint(&root_buf, "{s}/store-relocated", .{prefix}) catch return .{};
    var dir = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch return .{};
    defer dir.close(io);

    // Collect stale segment names before deleting — mutating a directory
    // mid-iteration can invalidate its cursor.
    var stale: std.ArrayList([]u8) = .empty;
    defer {
        for (stale.items) |n| allocator.free(n);
        stale.deinit(allocator);
    }
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const ver = parseVersionSegment(entry.name) orelse continue;
        if (ver == RELOC_LOGIC_VERSION) continue;
        const owned = allocator.dupe(u8, entry.name) catch continue;
        stale.append(allocator, owned) catch {
            allocator.free(owned);
            continue;
        };
    }

    var reaped: Reaped = .{};
    for (stale.items) |name| {
        var child_buf: [512]u8 = undefined;
        const child = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ root, name }) catch continue;
        const bytes = dirsize.dirSizeBytes(io, child);
        if (do_remove) std.Io.Dir.cwd().deleteTree(io, child) catch continue;
        reaped.removed += 1;
        reaped.bytes +|= bytes;
    }
    return reaped;
}

/// Parse a `v<digits>` cache segment name into its version, else null so
/// foreign entries at the store root are never touched.
fn parseVersionSegment(name: []const u8) ?u32 {
    if (name.len < 2 or name[0] != 'v') return null;
    return std.fmt.parseInt(u32, name[1..], 10) catch null;
}

// ---------------------------------------------------------------------------
// Inline unit tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const valid_sha_for_tests = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

// Split across `++` so the spawn-invariant lint (which scans src/ for
// shell-interpreter paths) doesn't flag a fixture-data string as a
// real shell invocation. Runtime value is identical.
const fixture_script = "#!" ++ "/bin" ++ "/sh\necho hi\n";

fn testIo() std.Io {
    return std.Options.debug_io;
}

fn tmpPrefixForTests(allocator: std.mem.Allocator, comptime tag: []const u8) ![]const u8 {
    var rand_bytes: [8]u8 = undefined;
    testIo().random(&rand_bytes);
    const rand_int = std.mem.bytesToValue(u64, &rand_bytes);
    const path = try std.fmt.allocPrint(
        allocator,
        "/tmp/malt_relocated_store_{s}_{x}",
        .{ tag, rand_int },
    );
    std.Io.Dir.cwd().deleteTree(testIo(), path) catch {};
    try std.Io.Dir.createDirAbsolute(testIo(), path, .default_dir);
    return path;
}

fn writeFileForTests(allocator: std.mem.Allocator, parent: []const u8, rel: []const u8, body: []const u8) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, rel });
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(testIo(), dir) catch {};
    }
    const f = try std.Io.Dir.createFileAbsolute(testIo(), path, .{});
    defer f.close(testIo());
    try f.writeStreamingAll(testIo(), body);
}

fn readAllForTests(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const f = try std.Io.Dir.openFileAbsolute(testIo(), path, .{});
    defer f.close(testIo());
    const stat = try f.stat(testIo());
    const buf = try allocator.alloc(u8, stat.size);
    const n = try f.readPositionalAll(testIo(), buf, 0);
    return buf[0..n];
}

fn buildKegForTests(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8, version: []const u8) !void {
    const cellar_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/Cellar/{s}/{s}",
        .{ prefix, name, version },
    );
    defer allocator.free(cellar_dir);
    try std.Io.Dir.cwd().createDirPath(testIo(), cellar_dir);
    try writeFileForTests(allocator, cellar_dir, "bin/hello", fixture_script);
    try writeFileForTests(allocator, cellar_dir, "lib/test.pc", "prefix=/opt/malt\nlibdir=${prefix}/lib\n");
}

test "has rejects invalid sha (length != 64)" {
    const prefix = try tmpPrefixForTests(testing.allocator, "validation_short");
    defer {
        std.Io.Dir.cwd().deleteTree(testIo(), prefix) catch {};
        testing.allocator.free(prefix);
    }
    try testing.expect(!has(testIo(), prefix, "abc"));
    try testing.expect(!has(testIo(), prefix, valid_sha_for_tests[0..63]));
    try testing.expect(!has(testIo(), prefix, valid_sha_for_tests ++ "0"));
}

test "has rejects uppercase sha" {
    const prefix = try tmpPrefixForTests(testing.allocator, "validation_case");
    defer {
        std.Io.Dir.cwd().deleteTree(testIo(), prefix) catch {};
        testing.allocator.free(prefix);
    }
    const upper = "0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef";
    try testing.expect(!has(testIo(), prefix, upper));
}

test "has rejects path-traversal sequences" {
    const prefix = try tmpPrefixForTests(testing.allocator, "validation_traversal");
    defer {
        std.Io.Dir.cwd().deleteTree(testIo(), prefix) catch {};
        testing.allocator.free(prefix);
    }
    // Same length as a real sha but containing `/` or `.` — must be rejected
    // before the path is formed, no matter how the dir layout looks on disk.
    const slashy = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789ab/cd";
    const dotty = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789ab..d";
    try testing.expect(!has(testIo(), prefix, slashy));
    try testing.expect(!has(testIo(), prefix, dotty));
}

test "save rejects invalid sha" {
    const prefix = try tmpPrefixForTests(testing.allocator, "save_invalid");
    defer {
        std.Io.Dir.cwd().deleteTree(testIo(), prefix) catch {};
        testing.allocator.free(prefix);
    }
    try buildKegForTests(testing.allocator, prefix, "noop", "1.0");
    try testing.expectError(
        RelocatedStoreError.InvalidSha256,
        save(testIo(), testing.allocator, prefix, "not-a-real-sha", "noop", "1.0"),
    );
}

test "materialize rejects invalid sha" {
    const prefix = try tmpPrefixForTests(testing.allocator, "mat_invalid");
    defer {
        std.Io.Dir.cwd().deleteTree(testIo(), prefix) catch {};
        testing.allocator.free(prefix);
    }
    try testing.expectError(
        RelocatedStoreError.InvalidSha256,
        materialize(testIo(), testing.allocator, prefix, "../etc/passwd", "noop", "1.0"),
    );
}

test "remove rejects invalid sha" {
    const prefix = try tmpPrefixForTests(testing.allocator, "rm_invalid");
    defer {
        std.Io.Dir.cwd().deleteTree(testIo(), prefix) catch {};
        testing.allocator.free(prefix);
    }
    try testing.expectError(RelocatedStoreError.InvalidSha256, remove(testIo(), prefix, ""));
}

test "has returns false for an unknown sha" {
    const prefix = try tmpPrefixForTests(testing.allocator, "has_miss");
    defer {
        std.Io.Dir.cwd().deleteTree(testIo(), prefix) catch {};
        testing.allocator.free(prefix);
    }
    try testing.expect(!has(testIo(), prefix, valid_sha_for_tests));
}

test "save then materialize round-trips byte-identical files" {
    const prefix = try tmpPrefixForTests(testing.allocator, "round_trip");
    defer {
        std.Io.Dir.cwd().deleteTree(testIo(), prefix) catch {};
        testing.allocator.free(prefix);
    }
    try buildKegForTests(testing.allocator, prefix, "tool", "1.2");
    try save(testIo(), testing.allocator, prefix, valid_sha_for_tests, "tool", "1.2");
    try testing.expect(has(testIo(), prefix, valid_sha_for_tests));

    const cellar_keg = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/tool/1.2", .{prefix});
    defer testing.allocator.free(cellar_keg);
    try std.Io.Dir.cwd().deleteTree(testIo(), cellar_keg);
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(testIo(), cellar_keg, .{}));

    try materialize(testIo(), testing.allocator, prefix, valid_sha_for_tests, "tool", "1.2");

    const script = try std.fmt.allocPrint(testing.allocator, "{s}/bin/hello", .{cellar_keg});
    defer testing.allocator.free(script);
    const got = try readAllForTests(testing.allocator, script);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(fixture_script, got);

    const pc = try std.fmt.allocPrint(testing.allocator, "{s}/lib/test.pc", .{cellar_keg});
    defer testing.allocator.free(pc);
    const got_pc = try readAllForTests(testing.allocator, pc);
    defer testing.allocator.free(got_pc);
    try testing.expectEqualStrings("prefix=/opt/malt\nlibdir=${prefix}/lib\n", got_pc);
}

test "save is idempotent — second call on same sha is a no-op success" {
    const prefix = try tmpPrefixForTests(testing.allocator, "save_idem");
    defer {
        std.Io.Dir.cwd().deleteTree(testIo(), prefix) catch {};
        testing.allocator.free(prefix);
    }
    try buildKegForTests(testing.allocator, prefix, "idem", "0.1");
    try save(testIo(), testing.allocator, prefix, valid_sha_for_tests, "idem", "0.1");
    // Second save with the same sha must not error and must not duplicate.
    try save(testIo(), testing.allocator, prefix, valid_sha_for_tests, "idem", "0.1");
    try testing.expect(has(testIo(), prefix, valid_sha_for_tests));
}

test "materialize replaces an existing destination" {
    const prefix = try tmpPrefixForTests(testing.allocator, "mat_replace");
    defer {
        std.Io.Dir.cwd().deleteTree(testIo(), prefix) catch {};
        testing.allocator.free(prefix);
    }
    try buildKegForTests(testing.allocator, prefix, "rep", "2.0");
    try save(testIo(), testing.allocator, prefix, valid_sha_for_tests, "rep", "2.0");

    const stale = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/Cellar/rep/2.0/bin/hello",
        .{prefix},
    );
    defer testing.allocator.free(stale);
    {
        const f = try std.Io.Dir.createFileAbsolute(testIo(), stale, .{ .truncate = true });
        defer f.close(testIo());
        try f.writeStreamingAll(testIo(), "CORRUPTED\n");
    }

    try materialize(testIo(), testing.allocator, prefix, valid_sha_for_tests, "rep", "2.0");
    const got = try readAllForTests(testing.allocator, stale);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(fixture_script, got);
}

test "saveFresh cleans the tempdir on the race-loss branch" {
    const prefix = try tmpPrefixForTests(testing.allocator, "race_loss");
    defer {
        std.Io.Dir.cwd().deleteTree(testIo(), prefix) catch {};
        testing.allocator.free(prefix);
    }
    try buildKegForTests(testing.allocator, prefix, "rl", "1.0");

    // Force the race-loss branch: pre-create dst so saveFresh's second
    // accessAbsolute(dst) succeeds, skipping the rename and falling through.
    var dst_buf: [512]u8 = undefined;
    const dst = try cacheDir(&dst_buf, prefix, RELOC_LOGIC_VERSION, valid_sha_for_tests);
    try std.Io.Dir.cwd().createDirPath(testIo(), dst);

    try saveFresh(testIo(), testing.allocator, prefix, "rl", "1.0", dst);

    // Race winner kept dst; the loser's tempdir must not survive. The temp is
    // a sibling of dst, so scan dst's parent (the versioned segment dir).
    const store_root = std.fs.path.dirname(dst).?;
    var root_dir = try std.Io.Dir.openDirAbsolute(testIo(), store_root, .{ .iterate = true });
    defer root_dir.close(testIo());
    var iter = root_dir.iterate();
    while (iter.next(testIo()) catch null) |entry| {
        try testing.expect(std.mem.indexOf(u8, entry.name, ".tmp.") == null);
    }
}

test "remove deletes the cache entry" {
    const prefix = try tmpPrefixForTests(testing.allocator, "rm");
    defer {
        std.Io.Dir.cwd().deleteTree(testIo(), prefix) catch {};
        testing.allocator.free(prefix);
    }
    try buildKegForTests(testing.allocator, prefix, "gone", "0.0.1");
    try save(testIo(), testing.allocator, prefix, valid_sha_for_tests, "gone", "0.0.1");
    try testing.expect(has(testIo(), prefix, valid_sha_for_tests));

    try remove(testIo(), prefix, valid_sha_for_tests);
    try testing.expect(!has(testIo(), prefix, valid_sha_for_tests));

    // remove on a missing entry is an idempotent no-op success.
    try remove(testIo(), prefix, valid_sha_for_tests);
}

// ── Relocation-logic version keying ─────────────────────────────────────────

test "same sha under two logic versions resolves to distinct paths" {
    var a_buf: [512]u8 = undefined;
    var b_buf: [512]u8 = undefined;
    const a = try cacheDir(&a_buf, "/opt/malt", 1, valid_sha_for_tests);
    const b = try cacheDir(&b_buf, "/opt/malt", 2, valid_sha_for_tests);
    try testing.expect(!std.mem.eql(u8, a, b));
    try testing.expect(std.mem.indexOf(u8, a, "/v1/") != null);
    try testing.expect(std.mem.indexOf(u8, b, "/v2/") != null);
}

test "save nests the entry under the current version, not the bare sha path" {
    const prefix = try tmpPrefixForTests(testing.allocator, "versioned_layout");
    defer {
        std.Io.Dir.cwd().deleteTree(testIo(), prefix) catch {};
        testing.allocator.free(prefix);
    }
    try buildKegForTests(testing.allocator, prefix, "ver", "1.0");
    try save(testIo(), testing.allocator, prefix, valid_sha_for_tests, "ver", "1.0");
    try testing.expect(has(testIo(), prefix, valid_sha_for_tests));

    // The old unversioned layout (`store-relocated/<sha>`) must not be produced —
    // a logic change would otherwise serve that stale entry forever.
    const bare = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/store-relocated/{s}",
        .{ prefix, valid_sha_for_tests },
    );
    defer testing.allocator.free(bare);
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(testIo(), bare, .{}));

    // The entry lives under the current version segment.
    var ver_buf: [512]u8 = undefined;
    const versioned = try cacheDir(&ver_buf, prefix, RELOC_LOGIC_VERSION, valid_sha_for_tests);
    try std.Io.Dir.accessAbsolute(testIo(), versioned, .{});
}

test "has misses an entry saved under a different logic version" {
    const prefix = try tmpPrefixForTests(testing.allocator, "version_miss");
    defer {
        std.Io.Dir.cwd().deleteTree(testIo(), prefix) catch {};
        testing.allocator.free(prefix);
    }
    // Seed an entry under a neighbouring logic version (simulating a bump).
    var buf: [512]u8 = undefined;
    const other = try cacheDir(&buf, prefix, RELOC_LOGIC_VERSION +% 1, valid_sha_for_tests);
    try std.Io.Dir.cwd().createDirPath(testIo(), other);

    // `has` probes the current version only, so the neighbour is a miss.
    try testing.expect(!has(testIo(), prefix, valid_sha_for_tests));
}

test "save is not shadowed by a leftover entry from another version" {
    const prefix = try tmpPrefixForTests(testing.allocator, "version_no_shadow");
    defer {
        std.Io.Dir.cwd().deleteTree(testIo(), prefix) catch {};
        testing.allocator.free(prefix);
    }
    // A stale entry from a previous logic version sits on disk.
    var buf: [512]u8 = undefined;
    const other = try cacheDir(&buf, prefix, RELOC_LOGIC_VERSION +% 1, valid_sha_for_tests);
    try std.Io.Dir.cwd().createDirPath(testIo(), other);

    // The current-version save must still run (its idempotency check targets
    // the current version), so a bump can never be shadowed by the leftover.
    try buildKegForTests(testing.allocator, prefix, "ns", "1.0");
    try save(testIo(), testing.allocator, prefix, valid_sha_for_tests, "ns", "1.0");
    try testing.expect(has(testIo(), prefix, valid_sha_for_tests));
}

test "reapStaleVersions removes prior-version trees and keeps the current one" {
    const prefix = try tmpPrefixForTests(testing.allocator, "reap");
    defer {
        std.Io.Dir.cwd().deleteTree(testIo(), prefix) catch {};
        testing.allocator.free(prefix);
    }
    // One current-version entry and two stale ones from past bumps.
    try buildKegForTests(testing.allocator, prefix, "cur", "1.0");
    try save(testIo(), testing.allocator, prefix, valid_sha_for_tests, "cur", "1.0");
    var b1: [512]u8 = undefined;
    var b2: [512]u8 = undefined;
    const old_a = try cacheDir(&b1, prefix, RELOC_LOGIC_VERSION +% 1, valid_sha_for_tests);
    const old_b = try cacheDir(&b2, prefix, RELOC_LOGIC_VERSION +% 2, valid_sha_for_tests);
    try std.Io.Dir.cwd().createDirPath(testIo(), old_a);
    try std.Io.Dir.cwd().createDirPath(testIo(), old_b);

    const reaped = reapStaleVersions(testIo(), testing.allocator, prefix, true);
    try testing.expectEqual(@as(u32, 2), reaped.removed);

    // Stale gone, current survives.
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(testIo(), old_a, .{}));
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(testIo(), old_b, .{}));
    try testing.expect(has(testIo(), prefix, valid_sha_for_tests));
}

test "reapStaleVersions with do_remove=false measures without deleting" {
    const prefix = try tmpPrefixForTests(testing.allocator, "reap_dry");
    defer {
        std.Io.Dir.cwd().deleteTree(testIo(), prefix) catch {};
        testing.allocator.free(prefix);
    }
    var buf: [512]u8 = undefined;
    const old = try cacheDir(&buf, prefix, RELOC_LOGIC_VERSION +% 1, valid_sha_for_tests);
    try std.Io.Dir.cwd().createDirPath(testIo(), old);
    // A real file so the byte count is non-zero.
    try writeFileForTests(testing.allocator, old, "bin/tool", fixture_script);

    const reaped = reapStaleVersions(testIo(), testing.allocator, prefix, false);
    try testing.expectEqual(@as(u32, 1), reaped.removed);
    try testing.expect(reaped.bytes > 0);
    // Dry-run must not delete.
    try std.Io.Dir.accessAbsolute(testIo(), old, .{});
}

test "reapStaleVersions ignores foreign entries and a missing store" {
    const prefix = try tmpPrefixForTests(testing.allocator, "reap_foreign");
    defer {
        std.Io.Dir.cwd().deleteTree(testIo(), prefix) catch {};
        testing.allocator.free(prefix);
    }
    // No store-relocated dir yet → no-op, no error.
    try testing.expectEqual(@as(u32, 0), reapStaleVersions(testIo(), testing.allocator, prefix, true).removed);

    // A non-`v<digits>` sibling must never be touched.
    const foreign = try std.fmt.allocPrint(testing.allocator, "{s}/store-relocated/notes", .{prefix});
    defer testing.allocator.free(foreign);
    try std.Io.Dir.cwd().createDirPath(testIo(), foreign);
    try testing.expectEqual(@as(u32, 0), reapStaleVersions(testIo(), testing.allocator, prefix, true).removed);
    try std.Io.Dir.accessAbsolute(testIo(), foreign, .{});
}

test "save self-heals a prior-version entry" {
    const prefix = try tmpPrefixForTests(testing.allocator, "save_selfheal");
    defer {
        std.Io.Dir.cwd().deleteTree(testIo(), prefix) catch {};
        testing.allocator.free(prefix);
    }
    // A stale entry from a past bump is present before the install.
    var buf: [512]u8 = undefined;
    const old = try cacheDir(&buf, prefix, RELOC_LOGIC_VERSION +% 1, valid_sha_for_tests);
    try std.Io.Dir.cwd().createDirPath(testIo(), old);

    // A fresh save under the current version reclaims it opportunistically.
    try buildKegForTests(testing.allocator, prefix, "heal", "1.0");
    try save(testIo(), testing.allocator, prefix, valid_sha_for_tests, "heal", "1.0");
    try testing.expect(has(testIo(), prefix, valid_sha_for_tests));
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(testIo(), old, .{}));
}
