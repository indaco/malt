const std = @import("std");

pub const Keg = struct {
    name: []const u8,
    version: []const u8,
    path: []const u8,
};

pub fn materialize(allocator: std.mem.Allocator, store_sha256: []const u8, name: []const u8, version: []const u8) !Keg {
    _ = .{ allocator, store_sha256, name, version };
    return error.NotImplemented;
}

pub fn remove(name: []const u8, version: []const u8) !void {
    _ = .{ name, version };
    return error.NotImplemented;
}

pub fn getKeg(allocator: std.mem.Allocator, name: []const u8) !?Keg {
    _ = .{ allocator, name };
    return error.NotImplemented;
}
