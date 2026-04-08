//! malt — info command
//! Show package info.

const std = @import("std");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = .{ allocator, args };
    return error.NotImplemented;
}
