const std = @import("std");

pub const Cask = struct {
    token: []const u8,
    name: []const u8,
    version: []const u8,
    desc: []const u8,
    homepage: []const u8,
    url: []const u8,
    sha256: []const u8,
    auto_updates: bool,
};

pub fn parseCask(allocator: std.mem.Allocator, json_data: []const u8) !Cask {
    _ = .{ allocator, json_data };
    return error.NotImplemented;
}

pub fn installCask(allocator: std.mem.Allocator, cask: *const Cask) !void {
    _ = .{ allocator, cask };
    return error.NotImplemented;
}

pub fn uninstallCask(allocator: std.mem.Allocator, token: []const u8) !void {
    _ = .{ allocator, token };
    return error.NotImplemented;
}
