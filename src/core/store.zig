const std = @import("std");

pub const StoreEntry = struct {
    sha256: []const u8,
    path: []const u8,
};

pub fn commit(sha256: []const u8) !void {
    _ = sha256;
    return error.NotImplemented;
}

pub fn exists(sha256: []const u8) bool {
    _ = sha256;
    return false;
}

pub fn remove(sha256: []const u8) !void {
    _ = sha256;
    return error.NotImplemented;
}

pub fn getPath(allocator: std.mem.Allocator, sha256: []const u8) ![]const u8 {
    _ = .{ allocator, sha256 };
    return error.NotImplemented;
}
