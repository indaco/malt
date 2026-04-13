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
            .array => |a| arraysEqual(a, other.array),
            .hash => |h| hashesEqual(h, other.hash),
        };
    }

    fn arraysEqual(a: []const Value, b: []const Value) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            if (!x.eql(y)) return false;
        }
        return true;
    }

    fn hashesEqual(a: []const HashPair, b: []const HashPair) bool {
        if (a.len != b.len) return false;
        // Order-sensitive compare. Ruby hashes are order-preserving, and
        // the parser emits pairs in source order, so structural equality
        // on the underlying slice matches user expectations for if/unless.
        for (a, b) |pa, pb| {
            if (!pa.key.eql(pb.key)) return false;
            if (!pa.value.eql(pb.value)) return false;
        }
        return true;
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
