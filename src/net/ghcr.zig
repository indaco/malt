const std = @import("std");

pub const TokenCache = struct {
    token: []const u8,
    expires_at: i64,
};

pub fn fetchToken(allocator: std.mem.Allocator, repo: []const u8) ![]const u8 {
    _ = .{ allocator, repo };
    return error.NotImplemented;
}

pub fn downloadBlob(allocator: std.mem.Allocator, repo: []const u8, digest: []const u8, writer: anytype) !void {
    _ = .{ allocator, repo, digest, writer };
    return error.NotImplemented;
}
