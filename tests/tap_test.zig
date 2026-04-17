//! malt — core/tap module tests
//! Covers add/remove/list round-trip, resolveFormula helper, and the
//! commit-pin lifecycle (tap_mod.add with SHA, updateCommit, validator).

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const sqlite = malt.sqlite;
const schema = malt.schema;

const tap = malt.tap;

const valid_sha = "0123456789abcdef0123456789abcdef01234567";
const other_sha = "abcdef0123456789abcdef0123456789abcdef01";

fn openDb() !sqlite.Database {
    return sqlite.Database.open(":memory:");
}

fn freeTaps(taps: []tap.TapInfo) void {
    for (taps) |t| {
        testing.allocator.free(t.name);
        testing.allocator.free(t.url);
        if (t.commit_sha) |sha| testing.allocator.free(sha);
    }
    testing.allocator.free(taps);
}

test "list returns empty slice on a fresh database" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    const taps = try tap.list(testing.allocator, &db);
    defer freeTaps(taps);
    try testing.expectEqual(@as(usize, 0), taps.len);
}

test "add then list round-trips tap name, url, and commit SHA" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "user/repo", "https://github.com/user/repo", valid_sha);

    const taps = try tap.list(testing.allocator, &db);
    defer freeTaps(taps);
    try testing.expectEqual(@as(usize, 1), taps.len);
    try testing.expectEqualStrings("user/repo", taps[0].name);
    try testing.expectEqualStrings("https://github.com/user/repo", taps[0].url);
    try testing.expectEqualStrings(valid_sha, taps[0].commit_sha.?);
}

test "add with null SHA persists as unpinned" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "user/repo", "https://github.com/user/repo", null);

    const taps = try tap.list(testing.allocator, &db);
    defer freeTaps(taps);
    try testing.expectEqual(@as(usize, 1), taps.len);
    try testing.expectEqual(@as(?[]const u8, null), taps[0].commit_sha);
}

test "add preserves URL on conflict (URL is sticky)" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "user/repo", "https://github.com/user/repo", null);
    try tap.add(&db, "user/repo", "https://github.com/user/repo-other", null);

    const taps = try tap.list(testing.allocator, &db);
    defer freeTaps(taps);
    try testing.expectEqual(@as(usize, 1), taps.len);
    try testing.expectEqualStrings("https://github.com/user/repo", taps[0].url);
}

test "add preserves existing commit pin when new add passes null" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "user/repo", "https://x", valid_sha);
    // Second add without a SHA must NOT wipe the pin.
    try tap.add(&db, "user/repo", "https://x", null);

    const taps = try tap.list(testing.allocator, &db);
    defer freeTaps(taps);
    try testing.expectEqualStrings(valid_sha, taps[0].commit_sha.?);
}

test "updateCommit replaces an existing pin" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "user/repo", "https://x", valid_sha);
    try tap.updateCommit(&db, "user/repo", other_sha);

    const taps = try tap.list(testing.allocator, &db);
    defer freeTaps(taps);
    try testing.expectEqualStrings(other_sha, taps[0].commit_sha.?);
}

test "updateCommit rejects malformed SHA" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "user/repo", "https://x", valid_sha);
    try testing.expectError(error.InvalidSha, tap.updateCommit(&db, "user/repo", "notasha"));
    try testing.expectError(error.InvalidSha, tap.updateCommit(&db, "user/repo", "XXXX567890abcdef0123456789abcdef01234567"));
}

test "getCommitSha returns the stored pin" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "user/repo", "https://x", valid_sha);
    const got = (try tap.getCommitSha(testing.allocator, &db, "user/repo")) orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(valid_sha, got);
}

test "getCommitSha returns null for unpinned tap" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "user/repo", "https://x", null);
    try testing.expectEqual(
        @as(?[]const u8, null),
        try tap.getCommitSha(testing.allocator, &db, "user/repo"),
    );
}

test "getCommitSha returns null for unknown tap" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);
    try testing.expectEqual(
        @as(?[]const u8, null),
        try tap.getCommitSha(testing.allocator, &db, "nobody/unregistered"),
    );
}

test "validateCommitSha accepts 40-char lowercase hex" {
    try tap.validateCommitSha(valid_sha);
}

test "validateCommitSha rejects wrong length" {
    try testing.expectError(error.InvalidSha, tap.validateCommitSha("deadbeef"));
    try testing.expectError(error.InvalidSha, tap.validateCommitSha(valid_sha ++ "00"));
}

test "validateCommitSha rejects uppercase" {
    const upper = "ABCDEF0123456789ABCDEF0123456789ABCDEF01";
    try testing.expectError(error.InvalidSha, tap.validateCommitSha(upper));
}

test "validateCommitSha rejects non-hex chars" {
    const bad = "ggggggggggggggggggggggggggggggggggggggg0";
    try testing.expectError(error.InvalidSha, tap.validateCommitSha(bad));
}

test "remove deletes a tap" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "a/b", "https://x", valid_sha);
    try tap.add(&db, "c/d", "https://y", valid_sha);
    try tap.remove(&db, "a/b");

    const taps = try tap.list(testing.allocator, &db);
    defer freeTaps(taps);
    try testing.expectEqual(@as(usize, 1), taps.len);
    try testing.expectEqualStrings("c/d", taps[0].name);
}

test "resolveFormula joins user/repo/formula with slashes" {
    const s = try tap.resolveFormula(testing.allocator, "u", "r", "f");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("u/r/f", s);
}
