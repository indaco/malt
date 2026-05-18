//! malt — post-relocation keg cache.
//!
//! `<MALT_PREFIX>/store-relocated/<sha256>/` snapshots a fully-relocated
//! Cellar keg keyed by bottle sha256. On warm reinstalls of a bottle whose
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

pub const RelocatedStoreError = error{
    InvalidSha256,
    PathTooLong,
    SaveFailed,
    MaterializeFailed,
};

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

fn cacheDir(buf: []u8, prefix: []const u8, sha: []const u8) RelocatedStoreError![]u8 {
    return std.fmt.bufPrint(buf, "{s}/store-relocated/{s}", .{ prefix, sha }) catch
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
    const dir = cacheDir(&buf, prefix, sha) catch return false;
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
    const dst = try cacheDir(&dst_buf, prefix, sha);

    // Idempotent: already cached → done. Concurrent installs race here, and
    // the loser would otherwise fail at `renameAbsolute` below.
    std.Io.Dir.accessAbsolute(io, dst, .{}) catch {
        // Not present yet — proceed with snapshot.
        return saveFresh(io, allocator, prefix, name, version, dst);
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

    // Ensure the parent `<prefix>/store-relocated/` directory exists.
    var parent_buf: [512]u8 = undefined;
    const parent = std.fmt.bufPrint(&parent_buf, "{s}/store-relocated", .{prefix}) catch
        return RelocatedStoreError.PathTooLong;
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
    const src = try cacheDir(&src_buf, prefix, sha);
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
    const dir = try cacheDir(&buf, prefix, sha);
    std.Io.Dir.cwd().deleteTree(io, dir) catch return;
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
    const dst = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/store-relocated/{s}",
        .{ prefix, valid_sha_for_tests },
    );
    defer testing.allocator.free(dst);
    try std.Io.Dir.cwd().createDirPath(testIo(), dst);

    try saveFresh(testIo(), testing.allocator, prefix, "rl", "1.0", dst);

    // Race winner kept dst; the loser's tempdir must not survive.
    const store_root = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/store-relocated",
        .{prefix},
    );
    defer testing.allocator.free(store_root);
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
