//! Caveat text helpers: Homebrew writes paths as placeholders, and the user
//! needs real paths to act on the note.

const std = @import("std");

pub const Token = struct {
    token: []const u8,
    value: []const u8,
};

/// Whitespace-only text carries nothing to show.
pub fn blankToNull(text: ?[]const u8) ?[]const u8 {
    const t = text orelse return null;
    return if (std.mem.trim(u8, t, " \t\r\n").len == 0) null else t;
}

/// Replace every occurrence of each token, in order. Caller owns the result.
pub fn expand(allocator: std.mem.Allocator, text: []const u8, tokens: []const Token) std.mem.Allocator.Error![]u8 {
    var cur = try allocator.dupe(u8, text);
    errdefer allocator.free(cur);
    for (tokens) |t| {
        const next = try allocator.alloc(u8, std.mem.replacementSize(u8, cur, t.token, t.value));
        _ = std.mem.replace(u8, cur, t.token, t.value, next);
        allocator.free(cur);
        cur = next;
    }
    return cur;
}

test "expand replaces every occurrence of every token" {
    const got = try expand(std.testing.allocator, "$A and $A and $B", &.{
        .{ .token = "$A", .value = "1" },
        .{ .token = "$B", .value = "22" },
    });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("1 and 1 and 22", got);
}

test "expand returns a copy when no token matches or the list is empty" {
    const got = try expand(std.testing.allocator, "plain", &.{.{ .token = "$A", .value = "x" }});
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("plain", got);

    const same = try expand(std.testing.allocator, "plain", &.{});
    defer std.testing.allocator.free(same);
    try std.testing.expectEqualStrings("plain", same);
}

test "blankToNull maps absent and whitespace-only text to null" {
    try std.testing.expect(blankToNull(null) == null);
    try std.testing.expect(blankToNull("") == null);
    try std.testing.expect(blankToNull(" \t\r\n") == null);
    try std.testing.expectEqualStrings("x", blankToNull("x").?);
}
