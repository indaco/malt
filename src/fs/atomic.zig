const std = @import("std");

/// Atomically renames src to dst.
pub fn atomicRename(src: []const u8, dst: []const u8) !void {
    _ = .{ src, dst };
    return error.NotImplemented;
}

/// Creates a temporary directory with the given prefix.
pub fn createTempDir(prefix: []const u8) ![]const u8 {
    _ = prefix;
    return error.NotImplemented;
}

/// Cleans up (removes) a temporary directory at the given path.
pub fn cleanupTempDir(path: []const u8) !void {
    _ = path;
    return error.NotImplemented;
}
