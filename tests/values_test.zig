//! malt — DSL values module tests
//! Covers Value.isTruthy, Value.eql, and Value.asString across variants.

const std = @import("std");
const testing = std.testing;
const Value = @import("malt").dsl.Value;

test "isTruthy treats nil and false as falsy, everything else as truthy" {
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
    try testing.expect(!(Value{ .int = 1 }).eql(Value{ .string = "1" }));
    try testing.expect(!(Value{ .nil = {} }).eql(Value{ .bool = false }));
}

test "eql within the same tag compares value payloads" {
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
    // Empty arrays / hashes are structurally equal.
    try testing.expect((Value{ .array = &.{} }).eql(Value{ .array = &.{} }));
    try testing.expect((Value{ .hash = &.{} }).eql(Value{ .hash = &.{} }));

    // Element-wise comparison recurses through eql.
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
    try testing.expectEqualStrings("hi", try (Value{ .string = "hi" }).asString(testing.allocator));
    try testing.expectEqualStrings("/p", try (Value{ .pathname = "/p" }).asString(testing.allocator));
    try testing.expectEqualStrings(":s", try (Value{ .symbol = ":s" }).asString(testing.allocator));
}

test "asString formats ints and floats via allocPrint" {
    const s_int = try (Value{ .int = 42 }).asString(testing.allocator);
    defer testing.allocator.free(s_int);
    try testing.expectEqualStrings("42", s_int);

    const s_float = try (Value{ .float = 2.5 }).asString(testing.allocator);
    defer testing.allocator.free(s_float);
    try testing.expectEqualStrings("2.5", s_float);
}

test "asString returns canonical tokens for bool/nil/array/hash" {
    try testing.expectEqualStrings("true", try (Value{ .bool = true }).asString(testing.allocator));
    try testing.expectEqualStrings("false", try (Value{ .bool = false }).asString(testing.allocator));
    try testing.expectEqualStrings("", try (Value{ .nil = {} }).asString(testing.allocator));
    try testing.expectEqualStrings("[Array]", try (Value{ .array = &.{} }).asString(testing.allocator));
    try testing.expectEqualStrings("{Hash}", try (Value{ .hash = &.{} }).asString(testing.allocator));
}
