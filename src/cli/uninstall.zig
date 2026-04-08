//! malt — uninstall command
//! Remove installed packages.

const std = @import("std");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = .{ allocator, args };
    return error.NotImplemented;
}
