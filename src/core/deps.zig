const std = @import("std");

pub const DepNode = struct {
    name: []const u8,
    deps: []const []const u8,
};

pub fn resolve(allocator: std.mem.Allocator, root: []const u8) ![]const []const u8 {
    _ = .{ allocator, root };
    return error.NotImplemented;
}

pub fn detectCycles(allocator: std.mem.Allocator, root: []const u8) !?[]const []const u8 {
    _ = .{ allocator, root };
    return error.NotImplemented;
}

pub fn findOrphans(allocator: std.mem.Allocator) ![]const []const u8 {
    _ = allocator;
    return error.NotImplemented;
}
