const std = @import("std");

pub const Tap = struct {
    name: []const u8,
    url: []const u8,
};

pub fn add(allocator: std.mem.Allocator, name: []const u8) !void {
    _ = .{ allocator, name };
    return error.NotImplemented;
}

pub fn remove(allocator: std.mem.Allocator, name: []const u8) !void {
    _ = .{ allocator, name };
    return error.NotImplemented;
}

pub fn list(allocator: std.mem.Allocator) ![]Tap {
    _ = allocator;
    return error.NotImplemented;
}

pub fn resolveFormula(allocator: std.mem.Allocator, user: []const u8, repo: []const u8, formula: []const u8) ![]const u8 {
    _ = .{ allocator, user, repo, formula };
    return error.NotImplemented;
}
