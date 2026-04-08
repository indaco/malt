const std = @import("std");

pub const Response = struct {
    status: u16,
    body: []const u8,
    headers: []const u8,
};

pub const HttpClient = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HttpClient {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *HttpClient) void {
        _ = self;
    }

    pub fn get(self: *HttpClient, url: []const u8) !Response {
        _ = .{ self, url };
        return error.NotImplemented;
    }

    pub fn head(self: *HttpClient, url: []const u8) !u16 {
        _ = .{ self, url };
        return error.NotImplemented;
    }
};
