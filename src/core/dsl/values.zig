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

test "isTruthy treats nil and false as falsy, everything else as truthy" {
    const testing = std.testing;
    try testing.expect(!(Value{ .nil = {} }).isTruthy());
    try testing.expect(!(Value{ .bool = false }).isTruthy());
    try testing.expect((Value{ .bool = true }).isTruthy());
    try testing.expect((Value{ .int = 0 }).isTruthy()); // 0 is truthy in Ruby
    try testing.expect((Value{ .string = "" }).isTruthy());
    try testing.expect((Value{ .pathname = "/x" }).isTruthy());
    try testing.expect((Value{ .symbol = "s" }).isTruthy());
    try testing.expect((Value{ .array = &.{} }).isTruthy());
    try testing.expect((Value{ .hash = &.{} }).isTruthy());
}

test "eql across differing tags is false" {
    const testing = std.testing;
    try testing.expect(!(Value{ .int = 1 }).eql(Value{ .string = "1" }));
    try testing.expect(!(Value{ .nil = {} }).eql(Value{ .bool = false }));
}

test "eql within the same tag compares value payloads" {
    const testing = std.testing;
    try testing.expect((Value{ .string = "x" }).eql(Value{ .string = "x" }));
    try testing.expect(!(Value{ .string = "x" }).eql(Value{ .string = "y" }));
    try testing.expect((Value{ .int = 3 }).eql(Value{ .int = 3 }));
    try testing.expect(!(Value{ .int = 3 }).eql(Value{ .int = 4 }));
    try testing.expect((Value{ .float = 1.5 }).eql(Value{ .float = 1.5 }));
    try testing.expect((Value{ .bool = true }).eql(Value{ .bool = true }));
    try testing.expect((Value{ .nil = {} }).eql(Value{ .nil = {} }));
    try testing.expect((Value{ .pathname = "/x" }).eql(Value{ .pathname = "/x" }));
    try testing.expect(!(Value{ .pathname = "/x" }).eql(Value{ .pathname = "/y" }));
    try testing.expect((Value{ .symbol = "k" }).eql(Value{ .symbol = "k" }));
}

test "eql performs structural equality on arrays and hashes" {
    const testing = std.testing;
    try testing.expect((Value{ .array = &.{} }).eql(Value{ .array = &.{} }));
    try testing.expect((Value{ .hash = &.{} }).eql(Value{ .hash = &.{} }));

    const a1 = [_]Value{ .{ .int = 1 }, .{ .string = "x" } };
    const a2 = [_]Value{ .{ .int = 1 }, .{ .string = "x" } };
    const a3 = [_]Value{ .{ .int = 1 }, .{ .string = "y" } };
    try testing.expect((Value{ .array = &a1 }).eql(Value{ .array = &a2 }));
    try testing.expect(!(Value{ .array = &a1 }).eql(Value{ .array = &a3 }));

    const h1 = [_]Value.HashPair{.{ .key = .{ .symbol = "k" }, .value = .{ .int = 1 } }};
    const h2 = [_]Value.HashPair{.{ .key = .{ .symbol = "k" }, .value = .{ .int = 1 } }};
    const h3 = [_]Value.HashPair{.{ .key = .{ .symbol = "k" }, .value = .{ .int = 2 } }};
    try testing.expect((Value{ .hash = &h1 }).eql(Value{ .hash = &h2 }));
    try testing.expect(!(Value{ .hash = &h1 }).eql(Value{ .hash = &h3 }));
}

test "asString returns raw bytes for string/pathname/symbol" {
    const testing = std.testing;
    try testing.expectEqualStrings("hi", try (Value{ .string = "hi" }).asString(testing.allocator));
    try testing.expectEqualStrings("/p", try (Value{ .pathname = "/p" }).asString(testing.allocator));
    try testing.expectEqualStrings(":s", try (Value{ .symbol = ":s" }).asString(testing.allocator));
}

test "asString formats ints and floats via allocPrint" {
    const testing = std.testing;
    const s_int = try (Value{ .int = 42 }).asString(testing.allocator);
    defer testing.allocator.free(s_int);
    try testing.expectEqualStrings("42", s_int);

    const s_float = try (Value{ .float = 2.5 }).asString(testing.allocator);
    defer testing.allocator.free(s_float);
    try testing.expectEqualStrings("2.5", s_float);
}

test "asString returns canonical tokens for bool/nil/array/hash" {
    const testing = std.testing;
    try testing.expectEqualStrings("true", try (Value{ .bool = true }).asString(testing.allocator));
    try testing.expectEqualStrings("false", try (Value{ .bool = false }).asString(testing.allocator));
    try testing.expectEqualStrings("", try (Value{ .nil = {} }).asString(testing.allocator));
    try testing.expectEqualStrings("[Array]", try (Value{ .array = &.{} }).asString(testing.allocator));
    try testing.expectEqualStrings("{Hash}", try (Value{ .hash = &.{} }).asString(testing.allocator));
}
