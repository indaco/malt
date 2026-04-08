const std = @import("std");

pub fn fetchFormula(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    _ = .{ allocator, name };
    return error.NotImplemented;
}

pub fn fetchCask(allocator: std.mem.Allocator, token: []const u8) ![]const u8 {
    _ = .{ allocator, token };
    return error.NotImplemented;
}

pub fn searchFormulas(allocator: std.mem.Allocator, query: []const u8) ![]const u8 {
    _ = .{ allocator, query };
    return error.NotImplemented;
}

pub fn searchCasks(allocator: std.mem.Allocator, query: []const u8) ![]const u8 {
    _ = .{ allocator, query };
    return error.NotImplemented;
}

pub fn invalidateCache() !void {
    return error.NotImplemented;
}
