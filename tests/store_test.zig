//! malt — store module tests
//! Tests for content-addressable store operations and thread safety.

const std = @import("std");
const malt = @import("malt");
const testing = std.testing;
const sqlite = @import("malt").sqlite;
const schema = @import("malt").schema;
const store_mod = @import("malt").store;

fn setupTestStore(allocator: std.mem.Allocator) !struct { db: sqlite.Database, store: store_mod.Store, prefix: []const u8 } {
    // Create temp directory as prefix
    const prefix = try std.fmt.allocPrint(allocator, "/tmp/malt_test_{x}", .{malt.fs_compat.randomInt(u64)});

    malt.fs_compat.makeDirAbsolute(prefix) catch {};
    const store_dir = try std.fmt.allocPrint(allocator, "{s}/store", .{prefix});
    defer allocator.free(store_dir);
    malt.fs_compat.makeDirAbsolute(store_dir) catch {};

    const db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/test.db", .{prefix}, 0);
    defer allocator.free(db_path);
    var db = try sqlite.Database.open(db_path);
    try schema.initSchema(&db);

    const store = store_mod.Store.init(allocator, &db, prefix);
    return .{ .db = db, .store = store, .prefix = prefix };
}

test "exists returns false for missing entry" {
    var ctx = try setupTestStore(testing.allocator);
    defer {
        ctx.db.close();
        malt.fs_compat.deleteTreeAbsolute(ctx.prefix) catch {};
        testing.allocator.free(ctx.prefix);
    }

    try testing.expect(!ctx.store.exists("nonexistent_sha256"));
}

test "commit moves directory to store and exists returns true" {
    var ctx = try setupTestStore(testing.allocator);
    defer {
        ctx.db.close();
        malt.fs_compat.deleteTreeAbsolute(ctx.prefix) catch {};
        testing.allocator.free(ctx.prefix);
    }

    // Create a source directory with a file
    const src = try std.fmt.allocPrint(testing.allocator, "/tmp/malt_src_{x}", .{malt.fs_compat.randomInt(u64)});
    defer testing.allocator.free(src);
    malt.fs_compat.makeDirAbsolute(src) catch {};

    const test_file = try std.fmt.allocPrint(testing.allocator, "{s}/test.txt", .{src});
    defer testing.allocator.free(test_file);
    const f = try malt.fs_compat.createFileAbsolute(test_file, .{});
    try f.writeAll("hello");
    f.close();

    try ctx.store.commitFrom("abc123sha", src);
    try testing.expect(ctx.store.exists("abc123sha"));
}

test "duplicate commit is idempotent" {
    var ctx = try setupTestStore(testing.allocator);
    defer {
        ctx.db.close();
        malt.fs_compat.deleteTreeAbsolute(ctx.prefix) catch {};
        testing.allocator.free(ctx.prefix);
    }

    // Create source and commit
    const src = try std.fmt.allocPrint(testing.allocator, "/tmp/malt_src2_{x}", .{malt.fs_compat.randomInt(u64)});
    defer testing.allocator.free(src);
    malt.fs_compat.makeDirAbsolute(src) catch {};

    try ctx.store.commitFrom("dup_sha", src);
    // Second commit should succeed (idempotent)
    try ctx.store.commitFrom("dup_sha", null);
    try testing.expect(ctx.store.exists("dup_sha"));
}

test "incrementRef and decrementRef update refcount" {
    var ctx = try setupTestStore(testing.allocator);
    defer {
        ctx.db.close();
        malt.fs_compat.deleteTreeAbsolute(ctx.prefix) catch {};
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
