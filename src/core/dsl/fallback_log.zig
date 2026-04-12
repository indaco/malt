//! malt — DSL fallback log
//! Structured telemetry for operations the interpreter cannot handle.

const std = @import("std");
const ast = @import("ast.zig");

pub const FallbackReason = enum {
    unknown_method,
    unsupported_node,
    sandbox_violation,
    system_command_failed,
};

pub const FallbackEntry = struct {
    formula: []const u8,
    reason: FallbackReason,
    detail: []const u8,
    loc: ?ast.SourceLoc,
};

pub const FallbackLog = struct {
    entries: std.ArrayList(FallbackEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FallbackLog {
        return .{
            .entries = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FallbackLog) void {
        self.entries.deinit(self.allocator);
    }

    pub fn log(self: *FallbackLog, entry: FallbackEntry) void {
        self.entries.append(self.allocator, entry) catch {};
    }

    pub fn hasErrors(self: *const FallbackLog) bool {
        return self.entries.items.len > 0;
    }

    pub fn hasFatal(self: *const FallbackLog) bool {
        for (self.entries.items) |entry| {
            switch (entry.reason) {
                .sandbox_violation => return true,
                .system_command_failed => return true,
                else => {},
            }
        }
        return false;
    }

    /// Serialize to JSON for telemetry reporting.
    pub fn toJson(self: *const FallbackLog, allocator: std.mem.Allocator) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        const writer = buf.writer(allocator);

        try writer.writeAll("[");
        for (self.entries.items, 0..) |entry, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{\"formula\":\"");
            try writer.writeAll(entry.formula);
            try writer.writeAll("\",\"reason\":\"");
            try writer.writeAll(@tagName(entry.reason));
            try writer.writeAll("\",\"detail\":\"");
            try writer.writeAll(entry.detail);
            try writer.writeAll("\"");
            if (entry.loc) |loc| {
                try writer.print(",\"line\":{d},\"col\":{d}", .{ loc.line, loc.col });
            }
            try writer.writeAll("}");
        }
        try writer.writeAll("]");

        return buf.toOwnedSlice(allocator);
    }
};
