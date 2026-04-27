//! malt — `mt doctor --fix` integration tests.
//!
//! Drives the safe-class fixers against a hermetic /tmp prefix so the
//! filesystem effects (lockfile removal, broken-symlink cleanup) are
//! observable without mocking. Renderer output is asserted to keep the
//! `--dry-run` plan text stable.

const std = @import("std");
const malt = @import("malt");
const testing = std.testing;
const fix = malt.doctor_fix;
const fs_compat = malt.fs_compat;
const sqlite = malt.sqlite;
const schema = malt.schema;
const store_mod = malt.store;

fn randHex(buf: *[16]u8) void {
    var rand: [8]u8 = undefined;
    fs_compat.randomBytes(&rand);
    const hex_chars = "0123456789abcdef";
    for (rand, 0..) |b, i| {
        buf[i * 2] = hex_chars[b >> 4];
        buf[i * 2 + 1] = hex_chars[b & 0x0f];
    }
}

fn makePrefix(prefix_buf: *[128]u8, label: []const u8) ![]const u8 {
    var hex: [16]u8 = undefined;
    randHex(&hex);
    const prefix = try std.fmt.bufPrint(prefix_buf, "/tmp/malt-doctor-fix-{s}-{s}", .{ label, &hex });
    fs_compat.deleteTreeAbsolute(prefix) catch {};
    try fs_compat.makeDirAbsolute(prefix);
    return prefix;
}

fn writeFile(path: []const u8, content: []const u8) !void {
    const f = try fs_compat.createFileAbsolute(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

fn pathExists(path: []const u8) bool {
    fs_compat.accessAbsolute(path, .{}) catch return false;
    return true;
}

// Pick a PID that almost certainly does not exist. PIDs above 2^22 are
// outside the macOS default range so kill(0) returns ESRCH.
const dead_pid_str = "999999";

// ── stale lock ──────────────────────────────────────────────────────

test "fixStaleLock: dead PID lock file is removed" {
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "stalelock");
    defer fs_compat.deleteTreeAbsolute(prefix) catch {};

    var db_buf: [256]u8 = undefined;
    const db_dir = try std.fmt.bufPrint(&db_buf, "{s}/db", .{prefix});
    try fs_compat.makeDirAbsolute(db_dir);

    var lock_buf: [256]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{prefix});
    try writeFile(lock_path, dead_pid_str);

    try testing.expect(fix.probeStaleLock(prefix));
    try testing.expect(fix.fixStaleLock(prefix));
    try testing.expect(!pathExists(lock_path));
}

test "fixStaleLock: live PID is left alone" {
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "livelock");
    defer fs_compat.deleteTreeAbsolute(prefix) catch {};

    var db_buf: [256]u8 = undefined;
    const db_dir = try std.fmt.bufPrint(&db_buf, "{s}/db", .{prefix});
    try fs_compat.makeDirAbsolute(db_dir);

    var lock_buf: [256]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{prefix});

    var pid_buf: [16]u8 = undefined;
    const pid_str = try std.fmt.bufPrint(&pid_buf, "{d}", .{std.c.getpid()});
    try writeFile(lock_path, pid_str);

    try testing.expect(!fix.probeStaleLock(prefix));
    try testing.expect(!fix.fixStaleLock(prefix));
    try testing.expect(pathExists(lock_path));
}

test "fixStaleLock: missing lock file is a no-op" {
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "nolock");
    defer fs_compat.deleteTreeAbsolute(prefix) catch {};

    try testing.expect(!fix.probeStaleLock(prefix));
    try testing.expect(!fix.fixStaleLock(prefix));
}

// ── broken symlinks ─────────────────────────────────────────────────

test "fixBrokenSymlinks: dangling links are unlinked, valid links survive" {
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "symlinks");
    defer fs_compat.deleteTreeAbsolute(prefix) catch {};

    var bin_buf: [256]u8 = undefined;
    const bin_dir = try std.fmt.bufPrint(&bin_buf, "{s}/bin", .{prefix});
    try fs_compat.makeDirAbsolute(bin_dir);

    // valid target lives next to the link directory
    var anchor_buf: [256]u8 = undefined;
    const anchor = try std.fmt.bufPrint(&anchor_buf, "{s}/anchor", .{prefix});
    try writeFile(anchor, "x");

    var bin = try fs_compat.openDirAbsolute(bin_dir, .{ .iterate = true });
    defer bin.close();
    try bin.symLink(anchor, "alive", .{});
    try bin.symLink("/tmp/malt-doctor-fix-vanished-target", "dead", .{});

    try testing.expectEqual(@as(u32, 1), fix.probeBrokenSymlinks(prefix));
    try testing.expectEqual(@as(u32, 1), fix.fixBrokenSymlinks(prefix));

    // Re-open to refresh the iterator after the unlink.
    var alive_path_buf: [256]u8 = undefined;
    const alive_path = try std.fmt.bufPrint(&alive_path_buf, "{s}/bin/alive", .{prefix});
    try testing.expect(pathExists(alive_path));

    var dead_path_buf: [256]u8 = undefined;
    const dead_path = try std.fmt.bufPrint(&dead_path_buf, "{s}/bin/dead", .{prefix});
    try testing.expect(!pathExists(dead_path));

    // After fixing, the next probe must report zero.
    try testing.expectEqual(@as(u32, 0), fix.probeBrokenSymlinks(prefix));
}

test "fixBrokenSymlinks: prefix without link dirs reports zero" {
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "emptylinks");
    defer fs_compat.deleteTreeAbsolute(prefix) catch {};
    try testing.expectEqual(@as(u32, 0), fix.probeBrokenSymlinks(prefix));
    try testing.expectEqual(@as(u32, 0), fix.fixBrokenSymlinks(prefix));
}

// ── executor ────────────────────────────────────────────────────────

test "executeFix: dry run leaves filesystem untouched and surfaces the plan" {
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "dryrun");
    defer fs_compat.deleteTreeAbsolute(prefix) catch {};

    var db_buf: [256]u8 = undefined;
    const db_dir = try std.fmt.bufPrint(&db_buf, "{s}/db", .{prefix});
    try fs_compat.makeDirAbsolute(db_dir);

    var lock_buf: [256]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{prefix});
    try writeFile(lock_path, dead_pid_str);

    const outcome = fix.executeFix(
        .{
            .prefix = prefix,
            .conditions = .{ .stale_lock = true },
        },
        true,
    );
    try testing.expectEqual(@as(u32, 0), outcome.fixesApplied());
    try testing.expect(pathExists(lock_path));
    try testing.expect(outcome.plan.safe.contains(.stale_lock));
}

test "executeFix: live run sweeps stale lock + broken symlinks together" {
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "live");
    defer fs_compat.deleteTreeAbsolute(prefix) catch {};

    var db_buf: [256]u8 = undefined;
    const db_dir = try std.fmt.bufPrint(&db_buf, "{s}/db", .{prefix});
    try fs_compat.makeDirAbsolute(db_dir);

    var lock_buf: [256]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{prefix});
    try writeFile(lock_path, dead_pid_str);

    var bin_buf: [256]u8 = undefined;
    const bin_dir = try std.fmt.bufPrint(&bin_buf, "{s}/bin", .{prefix});
    try fs_compat.makeDirAbsolute(bin_dir);
    var bin = try fs_compat.openDirAbsolute(bin_dir, .{ .iterate = true });
    defer bin.close();
    try bin.symLink("/tmp/malt-doctor-fix-vanished-multi", "ghost", .{});

    const outcome = fix.executeFix(
        .{
            .prefix = prefix,
            .conditions = .{ .stale_lock = true, .broken_symlink_count = 1 },
        },
        false,
    );
    try testing.expect(outcome.stale_lock_removed);
    try testing.expectEqual(@as(u32, 1), outcome.broken_symlinks_removed);
    try testing.expectEqual(@as(u32, 2), outcome.fixesApplied());
    try testing.expect(!pathExists(lock_path));

    var ghost_buf: [256]u8 = undefined;
    const ghost = try std.fmt.bufPrint(&ghost_buf, "{s}/bin/ghost", .{prefix});
    try testing.expect(!pathExists(ghost));
}

test "fixOrphanedStore: sweeps refcount-zero entries against a real DB" {
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "orphans");
    defer fs_compat.deleteTreeAbsolute(prefix) catch {};

    var db_dir_buf: [256]u8 = undefined;
    const db_dir = try std.fmt.bufPrint(&db_dir_buf, "{s}/db", .{prefix});
    try fs_compat.makeDirAbsolute(db_dir);

    var store_dir_buf: [256]u8 = undefined;
    const store_dir = try std.fmt.bufPrint(&store_dir_buf, "{s}/store", .{prefix});
    try fs_compat.makeDirAbsolute(store_dir);

    var db_path_buf: [256]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    // Seed: a store entry whose refcount drops to 0 is what `--store-orphans`
    // sweeps; the fixer must do the same.
    const sha = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef";
    var entry_dir_buf: [320]u8 = undefined;
    const entry_dir = try std.fmt.bufPrint(&entry_dir_buf, "{s}/store/{s}", .{ prefix, sha });
    try fs_compat.makeDirAbsolute(entry_dir);

    var store = store_mod.Store.init(testing.allocator, &db, prefix);
    try store.incrementRef(sha);
    try store.decrementRef(sha);

    try testing.expectEqual(@as(u32, 1), fix.probeOrphanedStoreCount(prefix));
    try testing.expectEqual(@as(u32, 1), fix.fixOrphanedStore(prefix));
    try testing.expectEqual(@as(u32, 0), fix.probeOrphanedStoreCount(prefix));
    try testing.expect(!pathExists(entry_dir));
}

test "fixOrphanedStore: missing DB is a no-op (returns 0)" {
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "no-db");
    defer fs_compat.deleteTreeAbsolute(prefix) catch {};
    try testing.expectEqual(@as(u32, 0), fix.probeOrphanedStoreCount(prefix));
    try testing.expectEqual(@as(u32, 0), fix.fixOrphanedStore(prefix));
}

test "executeFix: idempotent — second run finds nothing left to do" {
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "idempotent");
    defer fs_compat.deleteTreeAbsolute(prefix) catch {};

    var db_buf: [256]u8 = undefined;
    const db_dir = try std.fmt.bufPrint(&db_buf, "{s}/db", .{prefix});
    try fs_compat.makeDirAbsolute(db_dir);
    var lock_buf: [256]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{prefix});
    try writeFile(lock_path, dead_pid_str);

    const first = fix.executeFix(.{ .prefix = prefix }, false);
    try testing.expect(first.stale_lock_removed);

    const second = fix.executeFix(.{ .prefix = prefix }, false);
    try testing.expectEqual(@as(u32, 0), second.fixesApplied());
    try testing.expect(second.plan.isEmpty());
}

test "executeFix: dangerous classes carry into the plan, not the safe set" {
    const outcome = fix.executeFix(
        .{
            .prefix = "/nonexistent/malt/prefix",
            .conditions = .{ .db_corrupt = true, .missing_kegs = true },
        },
        false,
    );
    try testing.expectEqual(@as(u32, 0), outcome.fixesApplied());
    try testing.expectEqual(@as(usize, 0), outcome.plan.safe.count());
    try testing.expect(outcome.plan.manual.contains(.corrupt_database));
    try testing.expect(outcome.plan.manual.contains(.missing_kegs));
}
