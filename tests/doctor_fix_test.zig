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
const lock_mod = malt.lock;

// macOS user-immutable flag: makes a directory undeletable (rmdir → EPERM)
// even for root, so a blocked sweep is deterministic across environments.
const c = struct {
    extern "c" fn chflags(path: [*:0]const u8, flags: c_uint) c_int;
};
const UF_IMMUTABLE: c_uint = 0x00000002;

/// Process-unique scratch prefix, so overlapping test runs cannot wipe each
/// other's fixtures. Written into the caller's buffer via a fixed allocator.
fn makePrefix(prefix_buf: *[128]u8, label: []const u8) ![]const u8 {
    var scratch: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const unique = try test_io.uniqueTempPath(fba.allocator(), "doctor_fix", label);
    const prefix = try std.fmt.bufPrint(prefix_buf, "{s}", .{unique});
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

test "fixStaleLock: a holder we cannot signal is left alone" {
    // A root-owned malt holding the lock while doctor runs unprivileged: kill(2)
    // reports EPERM, not ESRCH. Clearing on EPERM would drop the lock metadata
    // of a live operation, so the holder must read as live.
    if (std.c.geteuid() == 0) return error.SkipZigTest; // root can signal pid 1

    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "epermlock");
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var db_buf: [256]u8 = undefined;
    const db_dir = try std.fmt.bufPrint(&db_buf, "{s}/db", .{prefix});
    try fs_compat.makeDirAbsolute(std.Options.debug_io, db_dir);

    var lock_buf: [256]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{prefix});
    try writeFile(lock_path, "1"); // launchd: live, never signalable by us

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const before = try statAbsolute(io, lock_path);
    try testing.expect(!fix.probeStaleLock(io, prefix));
    try testing.expect(!fix.fixStaleLock(io, prefix));

    // Untouched, not merely un-unlinked: the pid must survive intact.
    const after = try statAbsolute(io, lock_path);
    try testing.expectEqual(before.size, after.size);
}

test "fixStaleLock: a corrupt zero PID is stale, not an endless operation" {
    // kill(0, 0) targets our own process group and succeeds, so a truncated or
    // garbled lock file would otherwise pin doctor at "operation in flight".
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "zeropidlock");
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var db_buf: [256]u8 = undefined;
    const db_dir = try std.fmt.bufPrint(&db_buf, "{s}/db", .{prefix});
    try fs_compat.makeDirAbsolute(std.Options.debug_io, db_dir);

    var lock_buf: [256]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{prefix});
    try writeFile(lock_path, "0");

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try testing.expect(fix.probeStaleLock(io, prefix));
    try testing.expect(fix.fixStaleLock(io, prefix));
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

test "fixBrokenSymlinks: nested dangling links are found, not just top-level ones" {
    // The linker mirrors keg trees, so most links live below the top level:
    // share/man/man1, lib/pkgconfig, share/locale/<lang>/LC_MESSAGES. A walk
    // that only iterates `<prefix>/<subdir>` reports a clean prefix while
    // leaving those broken links in place.
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "nestedsymlinks");
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var anchor_buf: [256]u8 = undefined;
    const anchor = try std.fmt.bufPrint(&anchor_buf, "{s}/anchor", .{prefix});
    try writeFile(anchor, "x");

    // One dangling link per nesting depth, plus a live nested link that must
    // survive, and a deep chain matching share/locale's real shape.
    const nested_dirs = [_][]const u8{
        "share/man/man1",
        "lib/pkgconfig",
        "share/locale/en_US/LC_MESSAGES",
    };
    for (nested_dirs) |sub| {
        var d_buf: [256]u8 = undefined;
        const d = try std.fmt.bufPrint(&d_buf, "{s}/{s}", .{ prefix, sub });
        try fs_compat.cwd().createDirPath(std.Options.debug_io, d);

        var dir = try fs_compat.openDirAbsolute(std.Options.debug_io, d, .{ .iterate = true });
        defer dir.close(std.Options.debug_io);
        try dir.symLink(std.Options.debug_io, "/tmp/malt-doctor-nested-vanished", "dead", .{});
        try dir.symLink(std.Options.debug_io, anchor, "alive", .{});
    }

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try testing.expectEqual(@as(u32, nested_dirs.len), fix.probeBrokenSymlinks(io, prefix));
    try testing.expectEqual(@as(u32, nested_dirs.len), fix.fixBrokenSymlinks(io, prefix));

    for (nested_dirs) |sub| {
        var dead_buf: [256]u8 = undefined;
        const dead = try std.fmt.bufPrint(&dead_buf, "{s}/{s}/dead", .{ prefix, sub });
        try testing.expect(!pathExists(dead));
        var alive_buf: [256]u8 = undefined;
        const alive = try std.fmt.bufPrint(&alive_buf, "{s}/{s}/alive", .{ prefix, sub });
        try testing.expect(pathExists(alive));
    }

    try testing.expectEqual(@as(u32, 0), fix.probeBrokenSymlinks(io, prefix));
}

test "fixBrokenSymlinks: a symlinked directory is not descended into" {
    // Directory symlinks report as `.sym_link`, so the walk treats them as
    // leaves. Descending one would let the sweep escape the prefix.
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "symlinkeddir");
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var outside_buf: [256]u8 = undefined;
    const outside = try std.fmt.bufPrint(&outside_buf, "{s}/outside", .{prefix});
    try fs_compat.cwd().createDirPath(std.Options.debug_io, outside);
    var outside_dir = try fs_compat.openDirAbsolute(std.Options.debug_io, outside, .{ .iterate = true });
    defer outside_dir.close(std.Options.debug_io);
    try outside_dir.symLink(std.Options.debug_io, "/tmp/malt-doctor-offlimits", "dead", .{});

    var share_buf: [256]u8 = undefined;
    const share = try std.fmt.bufPrint(&share_buf, "{s}/share", .{prefix});
    try fs_compat.cwd().createDirPath(std.Options.debug_io, share);
    var share_dir = try fs_compat.openDirAbsolute(std.Options.debug_io, share, .{ .iterate = true });
    defer share_dir.close(std.Options.debug_io);
    try share_dir.symLink(std.Options.debug_io, outside, "linked", .{});

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // `share/linked` resolves, so it is not dangling; the dead link inside the
    // directory it points at is out of scope and must be left alone.
    try testing.expectEqual(@as(u32, 0), fix.probeBrokenSymlinks(io, prefix));
    try testing.expectEqual(@as(u32, 0), fix.fixBrokenSymlinks(io, prefix));

    // The dangling link is still there as a directory entry. `pathExists`
    // follows the link and would report absent, so check the entry itself.
    var found = false;
    var it = outside_dir.iterate();
    while (try it.next(std.Options.debug_io)) |entry| {
        if (std.mem.eql(u8, entry.name, "dead")) found = true;
    }
    try testing.expect(found);
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

test "fixOrphanedStore: an immutable child never leaves a partial entry under a live ref row" {
    // The corruption case: a deletable orphan dir with one undeletable child.
    // An in-place tree delete unlinks the siblings, fails on the child, and
    // keeps the ref row — leaving a half-empty entry the DB still calls valid.
    // The sweep must de-reference the entry atomically: gone from the store
    // namespace with its row cleared, the un-reapable bytes left as unreferenced
    // junk, never a corrupt-but-referenced entry.
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "immutable-child");
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

    // Two children so a failure on one leaves the other behind — the partial state.
    var a_buf: [384]u8 = undefined;
    try writeFile(try std.fmt.bufPrint(&a_buf, "{s}/a", .{entry_dir}), "x");
    var b_buf: [384]u8 = undefined;
    try writeFile(try std.fmt.bufPrint(&b_buf, "{s}/b", .{entry_dir}), "x");

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var store = store_mod.Store.init(io, testing.allocator, &db, prefix);
    try store.incrementRef(sha);
    try store.decrementRef(sha);

    // Make one child undeletable; clear the flag wherever it ends up (the sweep
    // renames the entry aside), or the prefix teardown itself would block.
    var child_z_buf: [384]u8 = undefined;
    const child_z = try std.fmt.bufPrintSentinel(&child_z_buf, "{s}/b", .{entry_dir}, 0);
    try testing.expectEqual(@as(c_int, 0), c.chflags(child_z.ptr, UF_IMMUTABLE));
    defer _ = c.chflags(child_z.ptr, 0);
    var reap_child_z_buf: [384]u8 = undefined;
    const reap_child_z = try std.fmt.bufPrintSentinel(&reap_child_z_buf, "{s}/.malt-reap-{s}/b", .{ prefix, sha }, 0);
    defer _ = c.chflags(reap_child_z.ptr, 0);

    const sweep = fix.fixOrphanedStore(io, prefix);
    // De-referenced and gone from the store namespace → credited, not blocked.
    try testing.expectEqual(@as(u32, 1), sweep.count);
    try testing.expectEqual(@as(u32, 0), sweep.blocked);
    // Consistent end-state: entry gone from the referenced path, ref row cleared.
    try testing.expect(!pathExists(entry_dir));
    try testing.expectEqual(@as(u32, 0), fix.probeOrphanedStoreCount(io, prefix));
    // The un-reapable child survives only as unreferenced junk, not corruption.
    var reap_dir_buf: [320]u8 = undefined;
    const reap_child = try std.fmt.bufPrint(&reap_dir_buf, "{s}/.malt-reap-{s}/b", .{ prefix, sha });
    try testing.expect(pathExists(reap_child));
}

test "fixOrphanedStore: a stale .malt-reap-* leftover is reclaimed by the reap, not the probe, and never counted" {
    // A prior sweep can strand a `.malt-reap-*` staging dir (immutable child).
    // The reap reclaims it as housekeeping — never counted as an orphan — while
    // the read-only probe must leave disk untouched.
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "reap-leftover");
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

    // A leftover staging dir, a sibling of store/ (never a valid orphan sha).
    var reap_buf: [320]u8 = undefined;
    const reap_dir = try std.fmt.bufPrint(&reap_buf, "{s}/.malt-reap-deadbeef", .{prefix});
    try fs_compat.makeDirAbsolute(std.Options.debug_io, reap_dir);
    var leaf_buf: [384]u8 = undefined;
    try writeFile(try std.fmt.bufPrint(&leaf_buf, "{s}/x", .{reap_dir}), "x");

    // The probe is read-only: leftover untouched, nothing counted.
    try testing.expectEqual(@as(u32, 0), fix.probeOrphanedStoreCount(io, prefix));
    try testing.expect(pathExists(reap_dir));

    // The reap reclaims the leftover without crediting it as a swept orphan.
    const sweep = fix.fixOrphanedStore(io, prefix);
    try testing.expectEqual(@as(u32, 0), sweep.count);
    try testing.expectEqual(@as(u32, 0), sweep.blocked);
    try testing.expect(!pathExists(reap_dir));
}

test "fixOrphanedStore: a stranded reap dir does not block reaping a fresh same-sha orphan" {
    // The corner a fixed staging name would trip: a prior sweep stranded
    // `.malt-reap-<sha>` (an immutable child housekeeping cannot reclaim), then
    // the same sha reappears as a fresh, fully-deletable orphan. Renaming onto
    // the stranded non-empty dir fails with DirNotEmpty; the sweep must probe a
    // free staging name and still reap the entry, not report it blocked.
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "reap-collision");
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

    const sha = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef";

    // A stranded, unreclaimable staging dir occupying the primary reap name.
    var stranded_buf: [320]u8 = undefined;
    const stranded = try std.fmt.bufPrint(&stranded_buf, "{s}/.malt-reap-{s}", .{ prefix, sha });
    try fs_compat.makeDirAbsolute(std.Options.debug_io, stranded);
    var stuck_z_buf: [384]u8 = undefined;
    const stuck_z = try std.fmt.bufPrintSentinel(&stuck_z_buf, "{s}/stuck", .{stranded}, 0);
    try writeFile(std.mem.sliceTo(stuck_z, 0), "x");
    try testing.expectEqual(@as(c_int, 0), c.chflags(stuck_z.ptr, UF_IMMUTABLE));
    defer _ = c.chflags(stuck_z.ptr, 0);

    // A fresh, fully-deletable orphan under the same sha.
    var entry_dir_buf: [320]u8 = undefined;
    const entry_dir = try std.fmt.bufPrint(&entry_dir_buf, "{s}/store/{s}", .{ prefix, sha });
    try fs_compat.makeDirAbsolute(std.Options.debug_io, entry_dir);
    var leaf_buf: [384]u8 = undefined;
    try writeFile(try std.fmt.bufPrint(&leaf_buf, "{s}/a", .{entry_dir}), "x");

    var store = store_mod.Store.init(io, testing.allocator, &db, prefix);
    try store.incrementRef(sha);
    try store.decrementRef(sha);

    const sweep = fix.fixOrphanedStore(io, prefix);
    // Reaped despite the stranded name — probed to a free slot, not blocked.
    try testing.expectEqual(@as(u32, 1), sweep.count);
    try testing.expectEqual(@as(u32, 0), sweep.blocked);
    try testing.expect(!pathExists(entry_dir));
    try testing.expectEqual(@as(u32, 0), fix.probeOrphanedStoreCount(io, prefix));
}

test "orphan parity: an entry a live keg holds is invisible to both doctor and purge" {
    // The shape a warm materialize after an uninstall leaves behind: the
    // counter is back at 0 but a `kegs` row still holds the bytes. Reaping it
    // costs the user a re-download of a package they have installed, so both
    // the sweep and the probe must consult `kegs`, not just the counter.
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "heldkeg");
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

    const sha = "cafebabecafebabecafebabecafebabecafebabecafebabecafebabecafebabe";
    var entry_dir_buf: [320]u8 = undefined;
    const entry_dir = try std.fmt.bufPrint(&entry_dir_buf, "{s}/store/{s}", .{ prefix, sha });
    try fs_compat.makeDirAbsolute(std.Options.debug_io, entry_dir);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var store = store_mod.Store.init(io, testing.allocator, &db, prefix);
    try store.incrementRef(sha); // cold install
    try store.decrementRef(sha); // uninstall drops the counter, keeps the bytes
    try db.exec(
        "INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path)" ++
            " VALUES ('probe', 'probe', '1.0', '" ++ sha ++ "', '/probe/Cellar/probe/1.0');",
    );

    // Remediation side: purge enumerates nothing.
    var orphans = try store.orphans();
    defer {
        for (orphans.items) |item| testing.allocator.free(item);
        orphans.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(usize, 0), orphans.items.len);

    // Detection side (shared by `--fix` and the inline doctor check) agrees,
    // and the sweep leaves the bytes alone.
    try testing.expectEqual(@as(u32, 0), fix.probeOrphanedStoreCount(io, prefix));
    const sweep = fix.fixOrphanedStore(io, prefix);
    try testing.expectEqual(@as(u32, 0), sweep.count);
    try testing.expect(pathExists(entry_dir));
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

// ── serialization: mutating sweeps run only under malt.lock ──────────

/// Create `<prefix>/db` and `<prefix>/bin`, plant one dangling symlink under
/// bin, and return the lock path — the shared scaffold for the held-lock
/// serialization tests. `lock_out` receives the `<prefix>/db/malt.lock` path.
fn seedLockAndDanglingLink(prefix: []const u8, lock_out: *[256]u8) ![]const u8 {
    const io = std.Options.debug_io;
    var db_buf: [256]u8 = undefined;
    const db_dir = try std.fmt.bufPrint(&db_buf, "{s}/db", .{prefix});
    try fs_compat.makeDirAbsolute(io, db_dir);

    var bin_buf: [256]u8 = undefined;
    const bin_dir = try std.fmt.bufPrint(&bin_buf, "{s}/bin", .{prefix});
    try fs_compat.makeDirAbsolute(io, bin_dir);
    var bin = try fs_compat.openDirAbsolute(io, bin_dir, .{ .iterate = true });
    defer bin.close(io);
    try bin.symLink(io, "/tmp/malt-doctor-fix-held-target-dne", "ghost", .{});

    return std.fmt.bufPrint(lock_out, "{s}/db/malt.lock", .{prefix});
}

test "executeFix: a live-held malt.lock blocks the broken-symlink sweep" {
    // R-011: the prefix-mutating classes must not run while another process
    // holds malt.lock — else `--fix` can delete an install's in-flight state.
    // A live holder makes the sweep a clean skip; the identical call once the
    // lock frees must remove the link. The acquire is the gate, so the round
    // trip is the proof.
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "held-lock");
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var lock_buf: [256]u8 = undefined;
    const lock_path = try seedLockAndDanglingLink(prefix, &lock_buf);

    var bin_buf: [256]u8 = undefined;
    const bin_dir = try std.fmt.bufPrint(&bin_buf, "{s}/bin", .{prefix});

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A synthetic live holder: our own process takes the lock.
    var held = try lock_mod.LockFile.acquire(io, lock_path, 1000);

    const skipped = fix.executeFix(
        .{ .prefix = prefix, .io = io, .conditions = .{ .broken_symlink_count = 1 } },
        false,
    );
    try testing.expectEqual(@as(u32, 0), skipped.broken_symlinks_removed);
    try testing.expect(symlinkEntryExists(io, bin_dir, "ghost"));

    // Free the lock; the identical call now sweeps the link away.
    held.release(io);
    const swept = fix.executeFix(
        .{ .prefix = prefix, .io = io, .conditions = .{ .broken_symlink_count = 1 } },
        false,
    );
    try testing.expectEqual(@as(u32, 1), swept.broken_symlinks_removed);
    try testing.expect(!symlinkEntryExists(io, bin_dir, "ghost"));
}

test "executeFix: the held-lock skip carries a reason, not a silent no-op" {
    // A live holder must read as "operation in progress", not a clean prefix:
    // both mutating classes skip and the outcome names Timeout as the cause.
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "skip-reason");
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var lock_buf: [256]u8 = undefined;
    const lock_path = try seedLockAndDanglingLink(prefix, &lock_buf);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var held = try lock_mod.LockFile.acquire(io, lock_path, 1000);
    defer held.release(io);

    const outcome = fix.executeFix(
        .{ .prefix = prefix, .io = io, .conditions = .{ .orphan_store_count = 1, .broken_symlink_count = 1 } },
        false,
    );
    try testing.expectEqual(@as(u32, 0), outcome.orphans_removed);
    try testing.expectEqual(@as(u32, 0), outcome.broken_symlinks_removed);
    try testing.expectEqual(lock_mod.LockError.Timeout, outcome.mutations_skipped.?);
}

test "acquire(timeout=0) on a held malt.lock times out at once (pins the executor's gate)" {
    // The executor gates the sweeps with a single non-blocking pass. Pin that
    // a live holder surfaces as Timeout immediately, so the timeout-0 choice
    // can't silently regress into a wait.
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "timeout0");
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var db_buf: [256]u8 = undefined;
    const db_dir = try std.fmt.bufPrint(&db_buf, "{s}/db", .{prefix});
    try fs_compat.makeDirAbsolute(std.Options.debug_io, db_dir);
    var lock_buf: [256]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{prefix});

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var held = try lock_mod.LockFile.acquire(io, lock_path, 1000);
    defer held.release(io);
    try testing.expectError(error.Timeout, lock_mod.LockFile.acquire(io, lock_path, 0));
}

test "executeFix: a prefix with no db/ dir reports the skip (DirMissing), never silently" {
    // No db/ → nothing to serialize against, so the sweep is declined — but
    // recorded, not silent, so the caller can say why (like every other
    // declined mutation in the codebase).
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "no-db-dir");
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var bin_buf: [256]u8 = undefined;
    const bin_dir = try std.fmt.bufPrint(&bin_buf, "{s}/bin", .{prefix});
    try fs_compat.makeDirAbsolute(std.Options.debug_io, bin_dir);
    var bin = try fs_compat.openDirAbsolute(std.Options.debug_io, bin_dir, .{ .iterate = true });
    defer bin.close(std.Options.debug_io);
    try bin.symLink(std.Options.debug_io, "/tmp/malt-doctor-fix-nodb-target-dne", "ghost", .{});

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const outcome = fix.executeFix(
        .{ .prefix = prefix, .io = io, .conditions = .{ .broken_symlink_count = 1 } },
        false,
    );
    try testing.expectEqual(@as(u32, 0), outcome.broken_symlinks_removed);
    try testing.expectEqual(lock_mod.LockError.DirMissing, outcome.mutations_skipped.?);
    try testing.expect(symlinkEntryExists(io, bin_dir, "ghost"));
}

test "executeFix: an unwritable db/ dir surfaces the acquire failure, not a silent skip" {
    // AccessDenied would read as "clean" if swallowed. It must reach the
    // outcome so doctor can point the user at the ownership fix.
    if (std.c.geteuid() == 0) return error.SkipZigTest; // root bypasses the perm wall

    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "denied");
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var lock_buf: [256]u8 = undefined;
    _ = try seedLockAndDanglingLink(prefix, &lock_buf);

    var db_buf: [256]u8 = undefined;
    const db_dir = try std.fmt.bufPrint(&db_buf, "{s}/db", .{prefix});

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // No lock file yet + a mode-0 db/ → the acquire's create hits EACCES.
    var db_dir_h = try fs_compat.openDirAbsolute(io, db_dir, .{});
    defer db_dir_h.close(io);
    try db_dir_h.setPermissions(io, std.Io.File.Permissions.fromMode(0));
    // Restore so the prefix teardown can recurse in.
    defer db_dir_h.setPermissions(io, std.Io.File.Permissions.fromMode(0o755)) catch {};

    const outcome = fix.executeFix(
        .{ .prefix = prefix, .io = io, .conditions = .{ .broken_symlink_count = 1 } },
        false,
    );
    try testing.expectEqual(@as(u32, 0), outcome.broken_symlinks_removed);
    try testing.expectEqual(lock_mod.LockError.AccessDenied, outcome.mutations_skipped.?);
}

test "executeFix: --dry-run never touches the lock, even while one is held" {
    // The acquire sits after the dry_run early return, so a plan-only run must
    // not contend the lock at all — no skip signal despite a live holder.
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "dry-held");
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var lock_buf: [256]u8 = undefined;
    const lock_path = try seedLockAndDanglingLink(prefix, &lock_buf);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var held = try lock_mod.LockFile.acquire(io, lock_path, 1000);
    defer held.release(io);

    const outcome = fix.executeFix(
        .{ .prefix = prefix, .io = io, .conditions = .{ .broken_symlink_count = 1 } },
        true,
    );
    try testing.expectEqual(@as(u32, 0), outcome.fixesApplied());
    try testing.expect(outcome.mutations_skipped == null);
    try testing.expect(outcome.plan.safe.contains(.broken_symlinks));
}

test "executeFix: the lock policy keys off the class, not the invocation" {
    // `--fix stale_lock` must not need the lock (repairing the lock can't
    // require it); `--fix broken_symlinks` must still serialize. Prove both
    // under one live holder.
    var prefix_buf: [128]u8 = undefined;
    const prefix = try makePrefix(&prefix_buf, "targeted");
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var lock_buf: [256]u8 = undefined;
    const lock_path = try seedLockAndDanglingLink(prefix, &lock_buf);

    var bin_buf: [256]u8 = undefined;
    const bin_dir = try std.fmt.bufPrint(&bin_buf, "{s}/bin", .{prefix});

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var held = try lock_mod.LockFile.acquire(io, lock_path, 1000);
    defer held.release(io);

    // stale_lock target never reaches the acquire.
    const s = fix.executeFix(
        .{ .prefix = prefix, .io = io, .only = .stale_lock, .conditions = .{ .stale_lock = true } },
        false,
    );
    try testing.expect(s.mutations_skipped == null);

    // broken_symlinks target contends and skips, leaving the link intact.
    const b = fix.executeFix(
        .{ .prefix = prefix, .io = io, .only = .broken_symlinks, .conditions = .{ .broken_symlink_count = 1 } },
        false,
    );
    try testing.expectEqual(lock_mod.LockError.Timeout, b.mutations_skipped.?);
    try testing.expectEqual(@as(u32, 0), b.broken_symlinks_removed);
    try testing.expect(symlinkEntryExists(io, bin_dir, "ghost"));
}
