const std = @import("std");

pub const Formula = struct {
    name: []const u8,
    full_name: []const u8,
    version: []const u8,
    revision: u32,
    desc: []const u8,
    license: []const u8,
    homepage: []const u8,
    tap: []const u8,
    dependencies: []const []const u8,
    keg_only: bool,
    post_install_defined: bool,
};

pub const BottleInfo = struct {
    url: []const u8,
    sha256: []const u8,
    cellar: []const u8,
};

pub fn parseFormula(allocator: std.mem.Allocator, json_data: []const u8) !Formula {
    _ = .{ allocator, json_data };
    return error.NotImplemented;
}

pub fn resolveBottle(allocator: std.mem.Allocator, formula: *const Formula) !BottleInfo {
    _ = .{ allocator, formula };
    return error.NotImplemented;
}

pub fn resolveAlias(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    _ = .{ allocator, name };
    return error.NotImplemented;
}
