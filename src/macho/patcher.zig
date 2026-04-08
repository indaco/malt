const std = @import("std");

pub fn patchPaths(allocator: std.mem.Allocator, path: []const u8, old_prefix: []const u8, new_prefix: []const u8) !u32 {
    _ = .{ allocator, path, old_prefix, new_prefix };
    return error.NotImplemented;
}

pub fn patchTextFiles(allocator: std.mem.Allocator, dir: []const u8, old_prefix: []const u8, new_prefix: []const u8) !u32 {
    _ = .{ allocator, dir, old_prefix, new_prefix };
    return error.NotImplemented;
}
