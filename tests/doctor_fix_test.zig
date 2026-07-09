//! malt — `mt doctor --fix` integration tests.
//!
//! Drives the safe-class fixers against a hermetic /tmp prefix so the
//! filesystem effects (lockfile removal, broken-symlink cleanup) are
//! observable without mocking. Renderer output is asserted to keep the
//! `--dry-run` plan text stable.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const fix = malt.doctor_fix;
const fs_compat = test_io;
const sqlite = malt.sqlite;
const schema = malt.schema;
const store_mod = malt.store;

// macOS user-immutable flag: makes a directory undeletable (rmdir → EPERM)
// even for root, so a blocked sweep is deterministic across environments.
const c = struct {
    extern "c" fn chflags(path: [*:0]const u8, flags: c_uint) c_int;
};
const UF_IMMUTABLE: c_uint = 0x00000002;

fn randHex(buf: *[16]u8) void {
    var rand: [8]u8 = undefined;
    fs_compat.randomBytes(std.Options.debug_io, &rand);
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
    fs_compat.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try fs_compat.makeDirAbsolute(std.Options.debug_io, prefix);
    return prefix;
}

fn writeFile(path: []const u8, content: []const u8) !void {
    const f = try fs_compat.createFileAbsolute(std.Options.debug_io, path, .{ .truncate = true });
    defer f.close(std.Options.debug_io);
    try f.writeStreamingAll(std.Options.debug_io, content);
}

fn pathExists(path: []const u8) bool {
    fs_compat.accessAbsolute(std.Options.debug_io, path, .{}) catch return false;
    return true;
}

/// Stat an absolute path through a short-lived handle — used to assert the
/// stale-lock repair keeps the same inode and empties it (R-010).
fn statAbsolute(io: std.Io, path: []const u8) !std.Io.File.Stat {
    const f = try fs_compat.openFileAbsolute(io, path, .{});
    defer f.close(io);
    return f.stat(io);
}

// Pick a PID that almost certainly does not exist. PIDs above 2^22 are
// outside the macOS default range so kill(0) returns ESRCH.
const dead_pid_str = "999999";

// ── stale lock ──────────────────────────────────────────────────────

test "fixStaleLock: dead PID lock is truncated in place, not unlinked" {
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "stalelock");
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var db_buf: [256]u8 = undefined;
    const db_dir = try std.fmt.bufPrint(&db_buf, "{s}/db", .{prefix});
    try fs_compat.makeDirAbsolute(std.Options.debug_io, db_dir);

    var lock_buf: [256]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{prefix});
    try writeFile(lock_path, dead_pid_str);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const before = try statAbsolute(io, lock_path);
    try testing.expect(before.size > 0);

    try testing.expect(fix.probeStaleLock(io, prefix));
    try testing.expect(fix.fixStaleLock(io, prefix));

    // R-010: the inode is the flock identity. Repair mirrors LockFile.release
    // — truncate to zero and leave the file in place. Unlinking would let a
    // fresh acquire take a new inode and break exclusion.
    try testing.expect(pathExists(lock_path));
    const after = try statAbsolute(io, lock_path);
    try testing.expectEqual(before.inode, after.inode);
    try testing.expectEqual(@as(u64, 0), after.size);

    // Truncation must resolve the finding, not just zero bytes: an emptied
    // lock reads as vacated, so a re-run is a no-op (idempotent).
    try testing.expect(!fix.probeStaleLock(io, prefix));
    try testing.expect(!fix.fixStaleLock(io, prefix));
}

test "fixStaleLock: live PID is left alone" {
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "livelock");
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var db_buf: [256]u8 = undefined;
    const db_dir = try std.fmt.bufPrint(&db_buf, "{s}/db", .{prefix});
    try fs_compat.makeDirAbsolute(std.Options.debug_io, db_dir);

    var lock_buf: [256]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{prefix});

    var pid_buf: [16]u8 = undefined;
    const pid_str = try std.fmt.bufPrint(&pid_buf, "{d}", .{std.c.getpid()});
    try writeFile(lock_path, pid_str);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try testing.expect(!fix.probeStaleLock(io, prefix));
    try testing.expect(!fix.fixStaleLock(io, prefix));
    try testing.expect(pathExists(lock_path));
}

test "fixStaleLock: missing lock file is a no-op" {
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "nolock");
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try testing.expect(!fix.probeStaleLock(io, prefix));
    try testing.expect(!fix.fixStaleLock(io, prefix));
}

// ── broken symlinks ─────────────────────────────────────────────────

test "fixBrokenSymlinks: dangling links are unlinked, valid links survive" {
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "symlinks");
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var bin_buf: [256]u8 = undefined;
    const bin_dir = try std.fmt.bufPrint(&bin_buf, "{s}/bin", .{prefix});
    try fs_compat.makeDirAbsolute(std.Options.debug_io, bin_dir);

    // valid target lives next to the link directory
    var anchor_buf: [256]u8 = undefined;
    const anchor = try std.fmt.bufPrint(&anchor_buf, "{s}/anchor", .{prefix});
    try writeFile(anchor, "x");

    var bin = try fs_compat.openDirAbsolute(std.Options.debug_io, bin_dir, .{ .iterate = true });
    defer bin.close(std.Options.debug_io);
    try bin.symLink(std.Options.debug_io, anchor, "alive", .{});
    try bin.symLink(std.Options.debug_io, "/tmp/malt-doctor-fix-vanished-target", "dead", .{});

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try testing.expectEqual(@as(u32, 1), fix.probeBrokenSymlinks(io, prefix));
    try testing.expectEqual(@as(u32, 1), fix.fixBrokenSymlinks(io, prefix));

    // Re-open to refresh the iterator after the unlink.
    var alive_path_buf: [256]u8 = undefined;
    const alive_path = try std.fmt.bufPrint(&alive_path_buf, "{s}/bin/alive", .{prefix});
    try testing.expect(pathExists(alive_path));

    var dead_path_buf: [256]u8 = undefined;
    const dead_path = try std.fmt.bufPrint(&dead_path_buf, "{s}/bin/dead", .{prefix});
    try testing.expect(!pathExists(dead_path));

    // After fixing, the next probe must report zero.
    try testing.expectEqual(@as(u32, 0), fix.probeBrokenSymlinks(io, prefix));
}

test "fixBrokenSymlinks: prefix without link dirs reports zero" {
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "emptylinks");
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try testing.expectEqual(@as(u32, 0), fix.probeBrokenSymlinks(io, prefix));
    try testing.expectEqual(@as(u32, 0), fix.fixBrokenSymlinks(io, prefix));
}

// ── executor ────────────────────────────────────────────────────────

test "executeFix: dry run leaves filesystem untouched and surfaces the plan" {
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "dryrun");
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var db_buf: [256]u8 = undefined;
    const db_dir = try std.fmt.bufPrint(&db_buf, "{s}/db", .{prefix});
    try fs_compat.makeDirAbsolute(std.Options.debug_io, db_dir);

    var lock_buf: [256]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{prefix});
    try writeFile(lock_path, dead_pid_str);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const outcome = fix.executeFix(
        .{
            .prefix = prefix,
            .io = io,
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
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var db_buf: [256]u8 = undefined;
    const db_dir = try std.fmt.bufPrint(&db_buf, "{s}/db", .{prefix});
    try fs_compat.makeDirAbsolute(std.Options.debug_io, db_dir);

    var lock_buf: [256]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{prefix});
    try writeFile(lock_path, dead_pid_str);

    var bin_buf: [256]u8 = undefined;
    const bin_dir = try std.fmt.bufPrint(&bin_buf, "{s}/bin", .{prefix});
    try fs_compat.makeDirAbsolute(std.Options.debug_io, bin_dir);
    var bin = try fs_compat.openDirAbsolute(std.Options.debug_io, bin_dir, .{ .iterate = true });
    defer bin.close(std.Options.debug_io);
    try bin.symLink(std.Options.debug_io, "/tmp/malt-doctor-fix-vanished-multi", "ghost", .{});

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const outcome = fix.executeFix(
        .{
            .prefix = prefix,
            .io = io,
            .conditions = .{ .stale_lock = true, .broken_symlink_count = 1 },
        },
        false,
    );
    try testing.expect(outcome.stale_lock_removed);
    try testing.expectEqual(@as(u32, 1), outcome.broken_symlinks_removed);
    try testing.expectEqual(@as(u32, 2), outcome.fixesApplied());
    // Stale lock is vacated in place, not unlinked (R-010).
    try testing.expect(pathExists(lock_path));
    try testing.expectEqual(@as(u64, 0), (try statAbsolute(io, lock_path)).size);

    var ghost_buf: [256]u8 = undefined;
    const ghost = try std.fmt.bufPrint(&ghost_buf, "{s}/bin/ghost", .{prefix});
    try testing.expect(!pathExists(ghost));
}

test "fixOrphanedStore: sweeps refcount-zero entries against a real DB" {
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "orphans");
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var db_dir_buf: [256]u8 = undefined;
    const db_dir = try std.fmt.bufPrint(&db_dir_buf, "{s}/db", .{prefix});
    try fs_compat.makeDirAbsolute(std.Options.debug_io, db_dir);

    var store_dir_buf: [256]u8 = undefined;
    const store_dir = try std.fmt.bufPrint(&store_dir_buf, "{s}/store", .{prefix});
    try fs_compat.makeDirAbsolute(std.Options.debug_io, store_dir);

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
    try fs_compat.makeDirAbsolute(std.Options.debug_io, entry_dir);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var store = store_mod.Store.init(io, testing.allocator, &db, prefix);
    try store.incrementRef(sha);
    try store.decrementRef(sha);

    try testing.expectEqual(@as(u32, 1), fix.probeOrphanedStoreCount(io, prefix));
    const sweep = fix.fixOrphanedStore(io, prefix);
    try testing.expectEqual(@as(u32, 1), sweep.count);
    try testing.expectEqual(@as(u32, 0), sweep.blocked);
    try testing.expectEqual(@as(u32, 0), fix.probeOrphanedStoreCount(io, prefix));
    try testing.expect(!pathExists(entry_dir));
}

test "fixOrphanedStore: an undeletable orphan is reported as blocked, not silently skipped" {
    // A refcount-0 orphan whose directory cannot be removed must surface as
    // blocked with a reason — not a silent count of 0 that reads exactly like
    // a clean prefix. Here the macOS immutable flag is the (root-proof) blocker.
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "blocked");
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var db_dir_buf: [256]u8 = undefined;
    const db_dir = try std.fmt.bufPrint(&db_dir_buf, "{s}/db", .{prefix});
    try fs_compat.makeDirAbsolute(std.Options.debug_io, db_dir);

    var store_dir_buf: [256]u8 = undefined;
    const store_dir = try std.fmt.bufPrint(&store_dir_buf, "{s}/store", .{prefix});
    try fs_compat.makeDirAbsolute(std.Options.debug_io, store_dir);

    var db_path_buf: [256]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    const sha = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef";
    var entry_dir_buf: [320]u8 = undefined;
    const entry_dir = try std.fmt.bufPrint(&entry_dir_buf, "{s}/store/{s}", .{ prefix, sha });
    try fs_compat.makeDirAbsolute(std.Options.debug_io, entry_dir);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var store = store_mod.Store.init(io, testing.allocator, &db, prefix);
    try store.incrementRef(sha);
    try store.decrementRef(sha);

    // Make the entry undeletable; clear the flag before the prefix teardown,
    // or deleteTree of the prefix would itself be blocked.
    var entry_z_buf: [320]u8 = undefined;
    const entry_z = try std.fmt.bufPrintSentinel(&entry_z_buf, "{s}/store/{s}", .{ prefix, sha }, 0);
    try testing.expectEqual(@as(c_int, 0), c.chflags(entry_z.ptr, UF_IMMUTABLE));
    defer _ = c.chflags(entry_z.ptr, 0);

    const sweep = fix.fixOrphanedStore(io, prefix);
    try testing.expectEqual(@as(u32, 0), sweep.count); // nothing actually removed
    try testing.expectEqual(@as(u32, 1), sweep.blocked); // the one orphan, blocked
    try testing.expect(sweep.reason != null);
    try testing.expect(pathExists(entry_dir)); // still on disk
}

test "fixOrphanedStore: a partial sweep removes what it can and reports the rest as blocked" {
    // Two orphans, one removable and one immutable: the sweep must credit the
    // removable one and still surface the blocked one — neither masking the
    // other, so "swept 1" and "could not sweep 1" can both be reported.
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "partial");
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var db_dir_buf: [256]u8 = undefined;
    const db_dir = try std.fmt.bufPrint(&db_dir_buf, "{s}/db", .{prefix});
    try fs_compat.makeDirAbsolute(std.Options.debug_io, db_dir);
    var store_dir_buf: [256]u8 = undefined;
    const store_dir = try std.fmt.bufPrint(&store_dir_buf, "{s}/store", .{prefix});
    try fs_compat.makeDirAbsolute(std.Options.debug_io, store_dir);

    var db_path_buf: [256]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var store = store_mod.Store.init(io, testing.allocator, &db, prefix);
    const removable = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const locked = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    inline for (.{ removable, locked }) |sha| {
        var dir_buf: [320]u8 = undefined;
        const dir = try std.fmt.bufPrint(&dir_buf, "{s}/store/{s}", .{ prefix, sha });
        try fs_compat.makeDirAbsolute(std.Options.debug_io, dir);
        try store.incrementRef(sha);
        try store.decrementRef(sha);
    }

    var locked_z_buf: [320]u8 = undefined;
    const locked_z = try std.fmt.bufPrintSentinel(&locked_z_buf, "{s}/store/{s}", .{ prefix, locked }, 0);
    try testing.expectEqual(@as(c_int, 0), c.chflags(locked_z.ptr, UF_IMMUTABLE));
    defer _ = c.chflags(locked_z.ptr, 0);

    const sweep = fix.fixOrphanedStore(io, prefix);
    try testing.expectEqual(@as(u32, 1), sweep.count); // the removable one
    try testing.expectEqual(@as(u32, 1), sweep.blocked); // the immutable one
    try testing.expect(sweep.reason != null);
}

test "orphan parity: a no-row store entry is invisible to both doctor and purge" {
    // A store dir with no `store_refs` row is a warm / in-flight commit
    // (`--download-only`, or an install interrupted before `incrementRef`).
    // `purge --store-orphans` is DB-driven and cannot remove it; doctor must
    // not flag it as one, or it routes the user to a command that no-ops.
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "norow");
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var db_dir_buf: [256]u8 = undefined;
    const db_dir = try std.fmt.bufPrint(&db_dir_buf, "{s}/db", .{prefix});
    try fs_compat.makeDirAbsolute(std.Options.debug_io, db_dir);

    var store_dir_buf: [256]u8 = undefined;
    const store_dir = try std.fmt.bufPrint(&store_dir_buf, "{s}/store", .{prefix});
    try fs_compat.makeDirAbsolute(std.Options.debug_io, store_dir);

    var db_path_buf: [256]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    // On disk but never `incrementRef`-d: no `store_refs` row.
    const sha = "feedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface";
    var entry_dir_buf: [320]u8 = undefined;
    const entry_dir = try std.fmt.bufPrint(&entry_dir_buf, "{s}/store/{s}", .{ prefix, sha });
    try fs_compat.makeDirAbsolute(std.Options.debug_io, entry_dir);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Remediation side: purge enumerates nothing.
    var store = store_mod.Store.init(io, testing.allocator, &db, prefix);
    var orphans = try store.orphans();
    defer {
        for (orphans.items) |item| testing.allocator.free(item);
        orphans.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(usize, 0), orphans.items.len);

    // Detection side (shared by `--fix` and the inline doctor check) must agree.
    try testing.expectEqual(@as(u32, 0), fix.probeOrphanedStoreCount(io, prefix));
    try testing.expect(pathExists(entry_dir));
}

test "fixOrphanedStore: missing DB is a no-op (returns 0)" {
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "no-db");
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try testing.expectEqual(@as(u32, 0), fix.probeOrphanedStoreCount(io, prefix));
    const sweep = fix.fixOrphanedStore(io, prefix);
    try testing.expectEqual(@as(u32, 0), sweep.count);
    try testing.expectEqual(@as(u32, 0), sweep.blocked);
}

test "executeFix: idempotent — second run finds nothing left to do" {
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "idempotent");
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var db_buf: [256]u8 = undefined;
    const db_dir = try std.fmt.bufPrint(&db_buf, "{s}/db", .{prefix});
    try fs_compat.makeDirAbsolute(std.Options.debug_io, db_dir);
    var lock_buf: [256]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{prefix});
    try writeFile(lock_path, dead_pid_str);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const first = fix.executeFix(.{ .prefix = prefix, .io = io }, false);
    try testing.expect(first.stale_lock_removed);

    const second = fix.executeFix(.{ .prefix = prefix, .io = io }, false);
    try testing.expectEqual(@as(u32, 0), second.fixesApplied());
    try testing.expect(second.plan.isEmpty());
}

// ── selective apply (`--fix <id>`) ──────────────────────────────────

test "executeFix: only=stale_lock removes the lock and leaves broken symlinks" {
    // A targeted fix must touch only its class. Seed both a stale lock
    // and a broken symlink; selecting stale_lock alone must remove the
    // lock and leave the dangling symlink in place.
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "only-lock");
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var db_buf: [256]u8 = undefined;
    const db_dir = try std.fmt.bufPrint(&db_buf, "{s}/db", .{prefix});
    try fs_compat.makeDirAbsolute(std.Options.debug_io, db_dir);
    var lock_buf: [256]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{prefix});
    try writeFile(lock_path, dead_pid_str);

    var bin_buf: [256]u8 = undefined;
    const bin_dir = try std.fmt.bufPrint(&bin_buf, "{s}/bin", .{prefix});
    try fs_compat.makeDirAbsolute(std.Options.debug_io, bin_dir);
    var bin = try fs_compat.openDirAbsolute(std.Options.debug_io, bin_dir, .{ .iterate = true });
    defer bin.close(std.Options.debug_io);
    try bin.symLink(std.Options.debug_io, "/tmp/malt-doctor-fix-only-target-dne", "dead", .{});

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const outcome = fix.executeFix(.{ .prefix = prefix, .io = io, .only = .stale_lock }, false);
    try testing.expect(outcome.stale_lock_removed);
    try testing.expectEqual(@as(u32, 0), outcome.broken_symlinks_removed);
    try testing.expectEqual(@as(u32, 1), outcome.fixesApplied());
    // The plan the user is shown lists only the targeted class.
    try testing.expectEqual(@as(usize, 1), outcome.plan.safe.count());
    try testing.expect(outcome.plan.safe.contains(.stale_lock));

    // Stale lock is vacated in place, not unlinked (R-010).
    try testing.expect(pathExists(lock_path));
    try testing.expectEqual(@as(u64, 0), (try statAbsolute(io, lock_path)).size);
    // `access()` follows the link, so a surviving dangling symlink reads
    // as absent — confirm the entry itself is still present by iterating.
    try testing.expect(symlinkEntryExists(io, bin_dir, "dead"));
}

/// True when `name` exists as a symlink entry under `dir_path`, without
/// following the link (unlike `pathExists`, which `access()`es through).
fn symlinkEntryExists(io: std.Io, dir_path: []const u8, name: []const u8) bool {
    var dir = fs_compat.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .sym_link and std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

test "executeFix: a valid id whose condition is absent is a clean no-op" {
    // `--fix broken_symlinks` on a prefix that only has a stale lock
    // must change nothing and leave the lock intact.
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "only-absent");
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var db_buf: [256]u8 = undefined;
    const db_dir = try std.fmt.bufPrint(&db_buf, "{s}/db", .{prefix});
    try fs_compat.makeDirAbsolute(std.Options.debug_io, db_dir);
    var lock_buf: [256]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{prefix});
    try writeFile(lock_path, dead_pid_str);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const outcome = fix.executeFix(.{ .prefix = prefix, .io = io, .only = .broken_symlinks }, false);
    try testing.expectEqual(@as(u32, 0), outcome.fixesApplied());
    try testing.expect(outcome.plan.isEmpty());
    try testing.expect(pathExists(lock_path));
}

test "executeFix: only=stale_lock --dry-run plans but mutates nothing" {
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "only-dry");
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var db_buf: [256]u8 = undefined;
    const db_dir = try std.fmt.bufPrint(&db_buf, "{s}/db", .{prefix});
    try fs_compat.makeDirAbsolute(std.Options.debug_io, db_dir);
    var lock_buf: [256]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{prefix});
    try writeFile(lock_path, dead_pid_str);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const outcome = fix.executeFix(.{ .prefix = prefix, .io = io, .only = .stale_lock }, true);
    try testing.expectEqual(@as(u32, 0), outcome.fixesApplied());
    try testing.expect(outcome.plan.safe.contains(.stale_lock));
    try testing.expect(pathExists(lock_path));
}

test "executeFix: dangerous classes carry into the plan, not the safe set" {
    const outcome = fix.executeFix(
        .{
            .prefix = "/nonexistent/malt/prefix",
            .io = std.Options.debug_io,
            .conditions = .{ .db_corrupt = true, .missing_kegs = true },
        },
        false,
    );
    try testing.expectEqual(@as(u32, 0), outcome.fixesApplied());
    try testing.expectEqual(@as(usize, 0), outcome.plan.safe.count());
    try testing.expect(outcome.plan.manual.contains(.corrupt_database));
    try testing.expect(outcome.plan.manual.contains(.missing_kegs));
}
