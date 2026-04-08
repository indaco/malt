const std = @import("std");

/// Tries to clone a file using APFS clonefile; falls back to a regular copy.
pub fn cloneFile(src: []const u8, dst: []const u8) !void {
    _ = .{ src, dst };
    return error.NotImplemented;
}

/// Returns whether the given path resides on an APFS volume.
pub fn isApfsVolume(path: []const u8) !bool {
    _ = path;
    return error.NotImplemented;
}
