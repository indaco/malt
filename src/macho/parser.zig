const std = @import("std");

pub const Header = struct {
    magic: u32,
    cputype: i32,
    filetype: u32,
};

pub const LoadCommand = struct {
    cmd: u32,
    cmdsize: u32,
    data: []const u8,
};

pub const MachOFile = struct {
    header: Header,
    load_commands: []const LoadCommand,
};

pub fn parse(allocator: std.mem.Allocator, path: []const u8) !MachOFile {
    _ = .{ allocator, path };
    return error.NotImplemented;
}
