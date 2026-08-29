//! One definition of the content-addressable store's on-disk layout.
//! Construction validates the key, so a traversal sequence, a case variant
//! or an empty string cannot reach the filesystem through a caller that
//! forgot to check first.

const std = @import("std");
const prefix_path = @import("prefix_path.zig");

pub const Error = error{ InvalidSha256, PathTooLong };

/// A validated prefix plus the longest shape this module formats
/// (`/store/` + 64 hex). The one buffer size every call site reserves.
pub const entry_buf_len: usize = prefix_path.max_prefix_len + "/store/".len + 64;

/// Exported so ingestion sites can reject an unusable digest at the source
/// rather than open-code a second charset loop.
pub fn isValidSha256(sha: []const u8) bool {
    if (sha.len != 64) return false;
    for (sha) |ch| {
        const ok = (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f');
        if (!ok) return false;
    }
    return true;
}

/// `{prefix}/store/{sha}` - the committed entry.
pub fn entry(buf: []u8, prefix: []const u8, sha: []const u8) Error![]u8 {
    if (!isValidSha256(sha)) return Error.InvalidSha256;
    return std.fmt.bufPrint(buf, "{s}/store/{s}", .{ prefix, sha }) catch Error.PathTooLong;
}

/// `{prefix}/tmp/{sha}` - the staging path a commit renames from.
pub fn tmpEntry(buf: []u8, prefix: []const u8, sha: []const u8) Error![]u8 {
    if (!isValidSha256(sha)) return Error.InvalidSha256;
    return std.fmt.bufPrint(buf, "{s}/tmp/{s}", .{ prefix, sha }) catch Error.PathTooLong;
}

const valid_sha = "a" ** 64;

test "formats both shapes for a valid key" {
    var buf: [entry_buf_len]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/opt/malt/store/" ++ valid_sha,
        try entry(&buf, "/opt/malt", valid_sha),
    );
    try std.testing.expectEqualStrings(
        "/opt/malt/tmp/" ++ valid_sha,
        try tmpEntry(&buf, "/opt/malt", valid_sha),
    );
}

test "rejects a key of the wrong length" {
    var buf: [entry_buf_len]u8 = undefined;
    try std.testing.expectError(Error.InvalidSha256, entry(&buf, "/opt/malt", "a" ** 63));
    try std.testing.expectError(Error.InvalidSha256, entry(&buf, "/opt/malt", "a" ** 65));
    try std.testing.expectError(Error.InvalidSha256, tmpEntry(&buf, "/opt/malt", "a" ** 63));
}

test "rejects the empty key instead of yielding the store root" {
    var buf: [entry_buf_len]u8 = undefined;
    try std.testing.expectError(Error.InvalidSha256, entry(&buf, "/opt/malt", ""));
    try std.testing.expectError(Error.InvalidSha256, tmpEntry(&buf, "/opt/malt", ""));
}

test "rejects out-of-charset keys, traversal included" {
    var buf: [entry_buf_len]u8 = undefined;
    const bad = [_][]const u8{
        "../../../etc/passwd" ++ "a" ** 45, // 64 chars, still hops out
        "/" ++ "a" ** 63,
        "." ++ "a" ** 63,
        "z" ++ "a" ** 63,
        "A" ** 64,
        "a" ** 63 ++ "\x00",
    };
    for (bad) |sha| {
        try std.testing.expectError(Error.InvalidSha256, entry(&buf, "/opt/malt", sha));
        try std.testing.expectError(Error.InvalidSha256, tmpEntry(&buf, "/opt/malt", sha));
    }
}

test "overflow is PathTooLong, not an allocation failure" {
    const formatted = "/opt/malt/store/".len + 64;
    var buf: [formatted - 1]u8 = undefined;
    try std.testing.expectError(Error.PathTooLong, entry(&buf, "/opt/malt", valid_sha));
}

test "tmpEntry overflows into PathTooLong too" {
    const formatted = "/opt/malt/tmp/".len + 64;
    var buf: [formatted - 1]u8 = undefined;
    try std.testing.expectError(Error.PathTooLong, tmpEntry(&buf, "/opt/malt", valid_sha));
}

test "entry_buf_len holds the longest prefix the tree accepts" {
    var buf: [entry_buf_len]u8 = undefined;
    const prefix = "/" ++ "p" ** (prefix_path.max_prefix_len - 1);
    const p = try entry(&buf, prefix, valid_sha);
    try std.testing.expectEqual(entry_buf_len, p.len);
}
