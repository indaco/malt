const std = @import("std");

pub const BottleResult = struct {
    sha256: []const u8,
    extract_path: []const u8,
};

pub fn download(allocator: std.mem.Allocator, url: []const u8, expected_sha256: []const u8) !BottleResult {
    _ = .{ allocator, url, expected_sha256 };
    return error.NotImplemented;
}

pub fn verify(path: []const u8, expected_sha256: []const u8) !bool {
    _ = .{ path, expected_sha256 };
    return error.NotImplemented;
}

pub fn extract(allocator: std.mem.Allocator, archive_path: []const u8, dest_dir: []const u8) !void {
    _ = .{ allocator, archive_path, dest_dir };
    return error.NotImplemented;
}
