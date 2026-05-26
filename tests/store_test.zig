//! malt — store module tests
//! Tests for content-addressable store operations and thread safety.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const sqlite = @import("malt").sqlite;
const schema = @import("malt").schema;
const store_mod = @import("malt").store;

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

    try testing.expect(!ctx.store.exists("nonexistent_sha256"));
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

    try ctx.store.commitFrom("abc123sha", src);
    try testing.expect(ctx.store.exists("abc123sha"));
}

test "commitFrom with null src renames from {prefix}/tmp/{sha}" {
    var ctx = try setupTestStore(testing.allocator);
    defer {
        ctx.db.close();
        test_io.deleteTreeAbsolute(std.Options.debug_io, ctx.prefix) catch {};
        testing.allocator.free(ctx.prefix);
    }

    const sha = "default_src_sha";

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
        ctx.store.commitFrom("missing_default_src_sha", null),
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

    try ctx.store.commitFrom("dup_sha", src);
    // Second commit should succeed (idempotent)
    try ctx.store.commitFrom("dup_sha", null);
    try testing.expect(ctx.store.exists("dup_sha"));
}

test "remove also drops the store_refs row so the orphan does not return" {
    var ctx = try setupTestStore(testing.allocator);
    defer {
        ctx.db.close();
        test_io.deleteTreeAbsolute(std.Options.debug_io, ctx.prefix) catch {};
        testing.allocator.free(ctx.prefix);
    }
    ctx.store.db = &ctx.db;

    try ctx.store.incrementRef("orphan_sha");
    try ctx.store.decrementRef("orphan_sha"); // refcount → 0

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
    try ctx.store.remove("orphan_sha");

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

    const sha = "txn_sha";
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
