//! malt — DSL runtime values
//! Runtime value enum for the tree-walking interpreter.

const std = @import("std");

pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    bool: bool,
    nil: void,
    pathname: []const u8,
    array: []const Value,
    hash: []const HashPair,
    symbol: []const u8,

    pub const HashPair = struct {
        key: Value,
        value: Value,
    };

    /// Truthiness: nil and false are falsy, everything else is truthy.
    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .nil => false,
            .bool => |b| b,
            else => true,
        };
    }

    /// Equality for if/unless comparisons.
    pub fn eql(self: Value, other: Value) bool {
        const Tag = std.meta.Tag(Value);
        const self_tag: Tag = self;
        const other_tag: Tag = other;
        if (self_tag != other_tag) return false;

        return switch (self) {
            .string => |s| std.mem.eql(u8, s, other.string),
            .int => |i| i == other.int,
            .float => |f| f == other.float,
            .bool => |b| b == other.bool,
            .nil => true,
            .pathname => |p| std.mem.eql(u8, p, other.pathname),
            .symbol => |s| std.mem.eql(u8, s, other.symbol),
            .array => false, // Reference equality only
            .hash => false,
        };
    }

    /// Coerce to string for interpolation and path operations.
    pub fn asString(self: Value, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .string => |s| s,
            .pathname => |p| p,
            .symbol => |s| s,
            .int => |i| std.fmt.allocPrint(allocator, "{d}", .{i}),
            .float => |f| std.fmt.allocPrint(allocator, "{d}", .{f}),
            .bool => |b| if (b) "true" else "false",
            .nil => "",
            .array => "[Array]",
            .hash => "{Hash}",
        };
    }
};
