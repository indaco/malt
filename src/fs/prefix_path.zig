const std = @import("std");

/// 512 bytes: ~4× real Homebrew prefix length, still small enough that
/// anything past it is either a bug or overflow bait. Single source of
/// truth for the prefix bound; `fs/atomic.zig` re-exports it.
pub const max_prefix_len: usize = 512;

/// Longest fixed suffix any caller appends (`/cache/migrate.progress.json`
/// = 28 B today); 64 leaves ~2× headroom for new fixed suffixes.
pub const max_path_suffix: usize = 64;

/// Buffer size a call site must reserve so a validated prefix plus any
/// fixed suffix always fits without overflow.
pub const path_buf_len: usize = max_prefix_len + max_path_suffix;

comptime {
    std.debug.assert(max_prefix_len + max_path_suffix <= path_buf_len);
}

/// Format `base ++ suffix` into `buf`, returning the slice. Overflow maps to
/// a typed `error.NameTooLong` instead of truncating silently, so callers
/// fail loud. `suffix` is comptime so its length is checked against the
/// reserved headroom at build time.
pub fn join(buf: []u8, base: []const u8, comptime suffix: []const u8) error{NameTooLong}![]u8 {
    comptime std.debug.assert(suffix.len <= max_path_suffix);
    return std.fmt.bufPrint(buf, "{s}{s}", .{ base, suffix }) catch error.NameTooLong;
}

/// NUL-terminated variant of `join` for `sqlite.Database.open` sites that
/// need a `[:0]u8`. Overflow (including the sentinel byte) maps to
/// `error.NameTooLong`.
pub fn joinZ(buf: []u8, base: []const u8, comptime suffix: []const u8) error{NameTooLong}![:0]u8 {
    comptime std.debug.assert(suffix.len <= max_path_suffix);
    return std.fmt.bufPrintSentinel(buf, "{s}{s}", .{ base, suffix }, 0) catch error.NameTooLong;
}

test "join fits" {
    var buf: [8]u8 = undefined;
    const s = try join(&buf, "abc", "/x");
    try std.testing.expectEqualStrings("abc/x", s);
}

test "join overflows into error.NameTooLong" {
    var buf: [8]u8 = undefined;
    try std.testing.expectError(error.NameTooLong, join(&buf, "abcdef", "/xyz"));
}

test "join exact-fit boundary returns full slice" {
    var buf: [5]u8 = undefined;
    const s = try join(&buf, "abc", "/x");
    try std.testing.expectEqual(@as(usize, 5), s.len);
    try std.testing.expectEqualStrings("abc/x", s);
}

test "joinZ is NUL-terminated" {
    var buf: [8]u8 = undefined;
    const s = try joinZ(&buf, "abc", "/x");
    try std.testing.expectEqualStrings("abc/x", s);
    try std.testing.expect(buf[s.len] == 0);
}

test "joinZ overflows at the sentinel boundary" {
    // base+suffix == 5 fits a [5]u8, but the NUL needs a 6th byte.
    var buf: [5]u8 = undefined;
    try std.testing.expectError(error.NameTooLong, joinZ(&buf, "abc", "/x"));
}

test "joinZ exact-fit boundary returns full slice" {
    // content 5 + NUL 1 == 6: a [6]u8 must accept, not over-reject by one.
    var buf: [6]u8 = undefined;
    const s = try joinZ(&buf, "abc", "/x");
    try std.testing.expectEqualStrings("abc/x", s);
    try std.testing.expect(buf[s.len] == 0);
}

test "bound constants are consistent" {
    try std.testing.expectEqual(@as(usize, 512), max_prefix_len);
    try std.testing.expectEqual(max_prefix_len + max_path_suffix, path_buf_len);
}
