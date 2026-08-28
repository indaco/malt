//! malt — store module tests
//! Tests for content-addressable store operations and thread safety.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const sqlite = @import("malt").sqlite;
const schema = @import("malt").schema;
const store_mod = @import("malt").store;

// One distinct 64-hex key per fixture: collapsing them onto a shared constant
// would quietly void the idempotent-commit and refcount assertions below.
const sha_missing = "1" ** 64;
const sha_commit_src = "2" ** 64;
const sha_default_src = "3" ** 64;
const sha_missing_src = "4" ** 64;
const sha_dup = "5" ** 64;
const sha_orphan = "6" ** 64;
const sha_txn = "7" ** 64;

fn setupTestStore(allocator: std.mem.Allocator) !struct { db: sqlite.Database, store: store_mod.Store, prefix: []const u8 } {
    // Create temp directory as prefix
    const prefix = try std.fmt.allocPrint(allocator, "/tmp/malt_test_{x}", .{test_io.randomInt(std.Options.debug_io, u64)});

    test_io.makeDirAbsolute(std.Options.debug_io, prefix) catch {};
    const store_dir = try std.fmt.allocPrint(allocator, "{s}/store", .{prefix});
    defer allocator.free(store_dir);
    test_io.makeDirAbsolute(std.Options.debug_io, store_dir) catch {};

    const db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/test.db", .{prefix}, 0);
    defer allocator.free(db_path);
    var db = try sqlite.Database.open(db_path);
    try schema.initSchema(&db);

    const store = store_mod.Store.init(std.Options.debug_io, allocator, &db, prefix);
    return .{ .db = db, .store = store, .prefix = prefix };
}

test "exists returns false for missing entry" {
    var ctx = try setupTestStore(testing.allocator);
    defer {
        ctx.db.close();
        test_io.deleteTreeAbsolute(std.Options.debug_io, ctx.prefix) catch {};
        testing.allocator.free(ctx.prefix);
    }

    try testing.expect(!ctx.store.exists(sha_missing));
}

test "commit moves directory to store and exists returns true" {
    var ctx = try setupTestStore(testing.allocator);
    defer {
        ctx.db.close();
        test_io.deleteTreeAbsolute(std.Options.debug_io, ctx.prefix) catch {};
        testing.allocator.free(ctx.prefix);
    }

    // Create a source directory with a file
    const src = try std.fmt.allocPrint(testing.allocator, "/tmp/malt_src_{x}", .{test_io.randomInt(std.Options.debug_io, u64)});
    defer testing.allocator.free(src);
    test_io.makeDirAbsolute(std.Options.debug_io, src) catch {};

    const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/test.txt", .{src});
    defer testing.allocator.free(test_file);
    const f = try test_io.createFileAbsolute(std.Options.debug_io, test_file, .{});
    try f.writeStreamingAll(std.Options.debug_io, "hello");
    f.close(std.Options.debug_io);

    try ctx.store.commitFrom(sha_commit_src, src);
    try testing.expect(ctx.store.exists(sha_commit_src));
}

test "commitFrom with null src renames from {prefix}/tmp/{sha}" {
    var ctx = try setupTestStore(testing.allocator);
    defer {
        ctx.db.close();
        test_io.deleteTreeAbsolute(std.Options.debug_io, ctx.prefix) catch {};
        testing.allocator.free(ctx.prefix);
    }

    const sha = sha_default_src;

    const tmp_dir = try std.fmt.allocPrint(testing.allocator, "{s}/tmp", .{ctx.prefix});
    defer testing.allocator.free(tmp_dir);
    test_io.makeDirAbsolute(std.Options.debug_io, tmp_dir) catch {};

    const default_src = try std.fmt.allocPrint(testing.allocator, "{s}/tmp/{s}", .{ ctx.prefix, sha });
    defer testing.allocator.free(default_src);
    test_io.makeDirAbsolute(std.Options.debug_io, default_src) catch {};

    const marker = try std.fmt.allocPrint(testing.allocator, "{s}/marker.txt", .{default_src});
    defer testing.allocator.free(marker);
    const f = try test_io.createFileAbsolute(std.Options.debug_io, marker, .{});
    try f.writeStreamingAll(std.Options.debug_io, "moved");
    f.close(std.Options.debug_io);

    try ctx.store.commitFrom(sha, null);

    try testing.expect(ctx.store.exists(sha));
    // The marker must have moved with the directory, not stayed behind.
    const moved_marker = try std.fmt.allocPrint(testing.allocator, "{s}/store/{s}/marker.txt", .{ ctx.prefix, sha });
    defer testing.allocator.free(moved_marker);
    var probe = try test_io.openFileAbsolute(std.Options.debug_io, moved_marker, .{});
    probe.close(std.Options.debug_io);
}

test "commitFrom with null src returns CommitFailed when default tmp path is missing" {
    var ctx = try setupTestStore(testing.allocator);
    defer {
        ctx.db.close();
        test_io.deleteTreeAbsolute(std.Options.debug_io, ctx.prefix) catch {};
        testing.allocator.free(ctx.prefix);
    }

    // No {prefix}/tmp/{sha} on disk, no {prefix}/store/{sha} either —
    // atomicRename surfaces the missing source as CommitFailed.
    try testing.expectError(
        store_mod.StoreError.CommitFailed,
        ctx.store.commitFrom(sha_missing_src, null),
    );
}

test "duplicate commit is idempotent" {
    var ctx = try setupTestStore(testing.allocator);
    defer {
        ctx.db.close();
        test_io.deleteTreeAbsolute(std.Options.debug_io, ctx.prefix) catch {};
        testing.allocator.free(ctx.prefix);
    }

    // Create source and commit
    const src = try std.fmt.allocPrint(testing.allocator, "/tmp/malt_src2_{x}", .{test_io.randomInt(std.Options.debug_io, u64)});
    defer testing.allocator.free(src);
    test_io.makeDirAbsolute(std.Options.debug_io, src) catch {};

    try ctx.store.commitFrom(sha_dup, src);
    // Second commit should succeed (idempotent)
    try ctx.store.commitFrom(sha_dup, null);
    try testing.expect(ctx.store.exists(sha_dup));
}

test "remove also drops the store_refs row so the orphan does not return" {
    var ctx = try setupTestStore(testing.allocator);
    defer {
        ctx.db.close();
        test_io.deleteTreeAbsolute(std.Options.debug_io, ctx.prefix) catch {};
        testing.allocator.free(ctx.prefix);
    }
    ctx.store.db = &ctx.db;

    try ctx.store.incrementRef(sha_orphan);
    try ctx.store.decrementRef(sha_orphan); // refcount → 0

    // Pre-condition: enumerate sees the orphan.
    {
        var orphans = try ctx.store.orphans();
        defer {
            for (orphans.items) |o| testing.allocator.free(o);
            orphans.deinit(testing.allocator);
        }
        try testing.expectEqual(@as(usize, 1), orphans.items.len);
    }

    // remove() with no on-disk path must still clear the DB row — otherwise
    // the same row keeps reappearing on every purge run.
    try ctx.store.remove(sha_orphan);

    var orphans = try ctx.store.orphans();
    defer {
        for (orphans.items) |o| testing.allocator.free(o);
        orphans.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(usize, 0), orphans.items.len);
}

test "remove drops FS path and store_refs row in one transactional pass" {
    var ctx = try setupTestStore(testing.allocator);
    defer {
        ctx.db.close();
        test_io.deleteTreeAbsolute(std.Options.debug_io, ctx.prefix) catch {};
        testing.allocator.free(ctx.prefix);
    }
    ctx.store.db = &ctx.db;

    const sha = sha_txn;
    const dir = try std.fmt.allocPrint(testing.allocator, "{s}/store/{s}", .{ ctx.prefix, sha });
    defer testing.allocator.free(dir);
    test_io.makeDirAbsolute(std.Options.debug_io, dir) catch {};
    try ctx.store.incrementRef(sha);
    try testing.expect(ctx.store.exists(sha));

    try ctx.store.remove(sha);

    try testing.expect(!ctx.store.exists(sha));

    var orphans = try ctx.store.orphans();
    defer {
        for (orphans.items) |o| testing.allocator.free(o);
        orphans.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(usize, 0), orphans.items.len);

    // A leaked open transaction would make the next BEGIN IMMEDIATE error.
    try ctx.db.beginTransaction();
    try ctx.db.commit();
}

test "incrementRef and decrementRef update refcount" {
    var ctx = try setupTestStore(testing.allocator);
    defer {
        ctx.db.close();
        test_io.deleteTreeAbsolute(std.Options.debug_io, ctx.prefix) catch {};
        testing.allocator.free(ctx.prefix);
    }
    // setupTestStore stored a `*sqlite.Database` pointing at its own stack
    // `db`. Re-bind it to the now-owned `ctx.db` so prepare() doesn't read
    // a freed frame.
    ctx.store.db = &ctx.db;

    try ctx.store.incrementRef("ref_test");
    try ctx.store.incrementRef("ref_test");
    try ctx.store.decrementRef("ref_test");

    // After 2 increments and 1 decrement, refcount should be 1
    // Verify via orphans — should NOT be an orphan
    var orphans = try ctx.store.orphans();
    defer {
        for (orphans.items) |o| testing.allocator.free(o);
        orphans.deinit(testing.allocator);
    }
    for (orphans.items) |o| {
        try testing.expect(!std.mem.eql(u8, o, "ref_test"));
    }
}

// ── Key validation ─────────────────────────────────────────────────────────

test "exists probes false for a key it cannot form a path from" {
    var ctx = try setupTestStore(testing.allocator);
    defer {
        ctx.db.close();
        test_io.deleteTreeAbsolute(std.Options.debug_io, ctx.prefix) catch {};
        testing.allocator.free(ctx.prefix);
    }

    // "" used to probe the store root itself and answer "already warm".
    try testing.expect(!ctx.store.exists(""));
    try testing.expect(!ctx.store.exists("../.."));
    try testing.expect(!ctx.store.exists("A" ** 64));
}

test "terminal methods reject a malformed key loudly" {
    var ctx = try setupTestStore(testing.allocator);
    defer {
        ctx.db.close();
        test_io.deleteTreeAbsolute(std.Options.debug_io, ctx.prefix) catch {};
        testing.allocator.free(ctx.prefix);
    }
    ctx.store.db = &ctx.db;

    try testing.expectError(store_mod.StoreError.InvalidSha256, ctx.store.commitFrom("", null));
    try testing.expectError(store_mod.StoreError.InvalidSha256, ctx.store.commitFrom("A" ** 64, null));
    try testing.expectError(store_mod.StoreError.InvalidSha256, ctx.store.remove("not-hex"));
    try testing.expectError(store_mod.StoreError.InvalidSha256, ctx.store.remove("A" ** 64));
    try testing.expectError(store_mod.StoreError.InvalidSha256, ctx.store.path("../etc"));
}

test "an explicit source path does not buy a caller past the key check" {
    var ctx = try setupTestStore(testing.allocator);
    defer {
        ctx.db.close();
        test_io.deleteTreeAbsolute(std.Options.debug_io, ctx.prefix) catch {};
        testing.allocator.free(ctx.prefix);
    }

    // Supplying src_path skips the tmp-path formation, which is the one way
    // the destination check could plausibly be bypassed.
    const src = try std.fmt.allocPrint(testing.allocator, "{s}/tmp/donor", .{ctx.prefix});
    defer testing.allocator.free(src);
    try test_io.cwd().createDirPath(std.Options.debug_io, src);

    try testing.expectError(store_mod.StoreError.InvalidSha256, ctx.store.commitFrom("", src));
    try testing.expectError(store_mod.StoreError.InvalidSha256, ctx.store.commitFrom("../evil", src));

    // The donor is still where it was: nothing was renamed.
    try test_io.accessAbsolute(std.Options.debug_io, src, .{});
}

test "path returns the store entry for a valid key" {
    var ctx = try setupTestStore(testing.allocator);
    defer {
        ctx.db.close();
        test_io.deleteTreeAbsolute(std.Options.debug_io, ctx.prefix) catch {};
        testing.allocator.free(ctx.prefix);
    }

    const p = try ctx.store.path(sha_txn);
    defer testing.allocator.free(p);

    const want = try std.fmt.allocPrint(testing.allocator, "{s}/store/{s}", .{ ctx.prefix, sha_txn });
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, p);
}

test "remove rejects a malformed key before it can delete or transact" {
    var ctx = try setupTestStore(testing.allocator);
    defer {
        ctx.db.close();
        test_io.deleteTreeAbsolute(std.Options.debug_io, ctx.prefix) catch {};
        testing.allocator.free(ctx.prefix);
    }
    ctx.store.db = &ctx.db;

    // A hand-edited row: refcount 0, key not hex, entry present on disk.
    const bad = "not-hex";
    const dir = try std.fmt.allocPrint(testing.allocator, "{s}/store/{s}", .{ ctx.prefix, bad });
    defer testing.allocator.free(dir);
    test_io.makeDirAbsolute(std.Options.debug_io, dir) catch {};
    try ctx.store.incrementRef(bad);
    try ctx.store.decrementRef(bad);

    try testing.expectError(store_mod.StoreError.InvalidSha256, ctx.store.remove(bad));

    // Neither side effect happened: the tree is intact and the row survives.
    try test_io.accessAbsolute(std.Options.debug_io, dir, .{});

    var orphans = try ctx.store.orphans();
    defer {
        for (orphans.items) |o| testing.allocator.free(o);
        orphans.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(usize, 1), orphans.items.len);

    // No transaction was left open.
    try ctx.db.beginTransaction();
    try ctx.db.commit();
}
