const std = @import("std");

pub const LinkConflict = struct {
    path: []const u8,
    existing_target: []const u8,
};

pub fn checkConflicts(allocator: std.mem.Allocator, keg_path: []const u8) ![]LinkConflict {
    _ = .{ allocator, keg_path };
    return error.NotImplemented;
}

pub fn link(allocator: std.mem.Allocator, keg_path: []const u8, name: []const u8) !u32 {
    _ = .{ allocator, keg_path, name };
    return error.NotImplemented;
}

pub fn unlink(allocator: std.mem.Allocator, name: []const u8) !u32 {
    _ = .{ allocator, name };
    return error.NotImplemented;
}
