//! malt — core/tap module tests
//! Covers add/remove/list round-trip and resolveFormula helper.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const sqlite = malt.sqlite;
const schema = malt.schema;

const tap = malt.tap;

fn openDb() !sqlite.Database {
    return sqlite.Database.open(":memory:");
}

test "list returns empty slice on a fresh database" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    const taps = try tap.list(testing.allocator, &db);
    defer testing.allocator.free(taps);
    try testing.expectEqual(@as(usize, 0), taps.len);
}

test "add then list round-trips tap name and url" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "user/repo", "https://github.com/user/repo");

    const taps = try tap.list(testing.allocator, &db);
    defer {
        for (taps) |t| {
            testing.allocator.free(t.name);
            testing.allocator.free(t.url);
        }
        testing.allocator.free(taps);
    }
    try testing.expectEqual(@as(usize, 1), taps.len);
    try testing.expectEqualStrings("user/repo", taps[0].name);
    try testing.expectEqualStrings("https://github.com/user/repo", taps[0].url);
}

test "add is idempotent (INSERT OR IGNORE)" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "user/repo", "https://github.com/user/repo");
    try tap.add(&db, "user/repo", "https://github.com/user/repo-other");

    const taps = try tap.list(testing.allocator, &db);
    defer {
        for (taps) |t| {
            testing.allocator.free(t.name);
            testing.allocator.free(t.url);
        }
        testing.allocator.free(taps);
    }
    try testing.expectEqual(@as(usize, 1), taps.len);
    try testing.expectEqualStrings("https://github.com/user/repo", taps[0].url);
}

test "remove deletes a tap" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "a/b", "https://x");
    try tap.add(&db, "c/d", "https://y");
    try tap.remove(&db, "a/b");

    const taps = try tap.list(testing.allocator, &db);
    defer {
        for (taps) |t| {
            testing.allocator.free(t.name);
            testing.allocator.free(t.url);
        }
        testing.allocator.free(taps);
    }
    try testing.expectEqual(@as(usize, 1), taps.len);
    try testing.expectEqualStrings("c/d", taps[0].name);
}

test "resolveFormula joins user/repo/formula with slashes" {
    const s = try tap.resolveFormula(testing.allocator, "u", "r", "f");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("u/r/f", s);
}
