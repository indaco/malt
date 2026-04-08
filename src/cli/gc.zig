//! malt — gc command
//! Garbage collect store entries.

const std = @import("std");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = .{ allocator, args };
    return error.NotImplemented;
}
