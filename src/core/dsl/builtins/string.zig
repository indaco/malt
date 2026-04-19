//! malt — DSL builtin: String operations
//! Maps Ruby String methods to std.mem operations.

const std = @import("std");
const values = @import("../values.zig");
const pathname = @import("pathname.zig");

const Value = values.Value;
const BuiltinError = pathname.BuiltinError;
const ExecCtx = pathname.ExecCtx;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Extract the receiver as a string slice.
fn receiverStr(allocator: std.mem.Allocator, receiver: ?Value) BuiltinError![]const u8 {
    const recv = receiver orelse return BuiltinError.UnknownMethod;
    return switch (recv) {
        .string => |s| s,
        .pathname => |p| p,
        else => recv.asString(allocator) catch return BuiltinError.OutOfMemory,
    };
}

/// Replace all occurrences of `needle` with `replacement` in `haystack`.
fn replaceAll(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) BuiltinError![]const u8 {
    if (needle.len == 0) return allocator.dupe(u8, haystack) catch return BuiltinError.OutOfMemory;

    // Count occurrences to compute result size.
    var count: usize = 0;
    var pos: usize = 0;
    while (pos <= haystack.len -| needle.len) {
        if (std.mem.startsWith(u8, haystack[pos..], needle)) {
            count += 1;
            pos += needle.len;
        } else {
            pos += 1;
        }
    }

    if (count == 0) return allocator.dupe(u8, haystack) catch return BuiltinError.OutOfMemory;

    const new_len = haystack.len - (count * needle.len) + (count * replacement.len);
    const buf = allocator.alloc(u8, new_len) catch return BuiltinError.OutOfMemory;

    var src: usize = 0;
    var dst: usize = 0;
    while (src <= haystack.len -| needle.len) {
        if (std.mem.startsWith(u8, haystack[src..], needle)) {
            @memcpy(buf[dst..][0..replacement.len], replacement);
            dst += replacement.len;
            src += needle.len;
        } else {
            buf[dst] = haystack[src];
            dst += 1;
            src += 1;
        }
    }
    // Copy remaining tail bytes (less than needle.len).
    if (src < haystack.len) {
        @memcpy(buf[dst..][0 .. haystack.len - src], haystack[src..]);
    }

    return buf;
}

/// Replace only the first occurrence of `needle` with `replacement`.
fn replaceFirst(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) BuiltinError![]const u8 {
    if (needle.len == 0) return allocator.dupe(u8, haystack) catch return BuiltinError.OutOfMemory;

    const before, const after = std.mem.cut(u8, haystack, needle) orelse {
        return allocator.dupe(u8, haystack) catch return BuiltinError.OutOfMemory;
    };

    const buf = allocator.alloc(u8, before.len + replacement.len + after.len) catch
        return BuiltinError.OutOfMemory;
    @memcpy(buf[0..before.len], before);
    @memcpy(buf[before.len..][0..replacement.len], replacement);
    @memcpy(buf[before.len + replacement.len ..], after);
    return buf;
}

// ---------------------------------------------------------------------------
// Public builtins — all follow the (ExecCtx, ?Value, []const Value) signature
// ---------------------------------------------------------------------------

/// gsub(pattern, replacement) — replace all occurrences
pub fn gsub(ctx: ExecCtx, receiver: ?Value, args: []const Value) BuiltinError!Value {
    const s = try receiverStr(ctx.allocator, receiver);
    if (args.len < 2) return Value{ .string = s };
    const pattern = try args[0].asString(ctx.allocator);
    const replacement = try args[1].asString(ctx.allocator);
    return Value{ .string = try replaceAll(ctx.allocator, s, pattern, replacement) };
}

/// gsub!(pattern, replacement) — in-place gsub (same as gsub for immutable strings)
pub fn gsubBang(ctx: ExecCtx, receiver: ?Value, args: []const Value) BuiltinError!Value {
    return gsub(ctx, receiver, args);
}

/// sub(pattern, replacement) — replace first occurrence
pub fn sub(ctx: ExecCtx, receiver: ?Value, args: []const Value) BuiltinError!Value {
    const s = try receiverStr(ctx.allocator, receiver);
    if (args.len < 2) return Value{ .string = s };
    const pattern = try args[0].asString(ctx.allocator);
    const replacement = try args[1].asString(ctx.allocator);
    return Value{ .string = try replaceFirst(ctx.allocator, s, pattern, replacement) };
}

/// sub!(pattern, replacement) — in-place sub (same as sub for immutable strings)
pub fn subBang(ctx: ExecCtx, receiver: ?Value, args: []const Value) BuiltinError!Value {
    return sub(ctx, receiver, args);
}

/// chomp — remove trailing newline characters
pub fn chomp(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const s = try receiverStr(ctx.allocator, receiver);
    const trimmed = std.mem.trimEnd(u8, s, "\n\r");
    return Value{ .string = trimmed };
}

/// strip — remove leading and trailing whitespace
pub fn strip(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const s = try receiverStr(ctx.allocator, receiver);
    const trimmed = std.mem.trim(u8, s, " \t\n\r");
    return Value{ .string = trimmed };
}

/// split(delimiter?) — split string into array
pub fn split(ctx: ExecCtx, receiver: ?Value, args: []const Value) BuiltinError!Value {
    const s = try receiverStr(ctx.allocator, receiver);

    var results: std.ArrayList(Value) = .empty;

    if (args.len > 0) {
        // Split on explicit delimiter
        const delim = try args[0].asString(ctx.allocator);
        if (delim.len == 0) {
            // Empty delimiter: return array of single chars
            for (s) |c| {
                const ch = ctx.allocator.alloc(u8, 1) catch return BuiltinError.OutOfMemory;
                ch[0] = c;
                results.append(ctx.allocator, Value{ .string = ch }) catch return BuiltinError.OutOfMemory;
            }
        } else if (delim.len == 1) {
            var iter = std.mem.splitScalar(u8, s, delim[0]);
            while (iter.next()) |part| {
                results.append(ctx.allocator, Value{ .string = part }) catch return BuiltinError.OutOfMemory;
            }
        } else {
            var iter = std.mem.splitSequence(u8, s, delim);
            while (iter.next()) |part| {
                results.append(ctx.allocator, Value{ .string = part }) catch return BuiltinError.OutOfMemory;
            }
        }
    } else {
        // Split on whitespace (skip consecutive whitespace, like Ruby's default split)
        var i: usize = 0;
        while (i < s.len) {
            // Skip whitespace
            while (i < s.len and isWhitespace(s[i])) : (i += 1) {}
            if (i >= s.len) break;
            // Find end of token
            const start = i;
            while (i < s.len and !isWhitespace(s[i])) : (i += 1) {}
            results.append(ctx.allocator, Value{ .string = s[start..i] }) catch return BuiltinError.OutOfMemory;
        }
    }

    const slice = results.toOwnedSlice(ctx.allocator) catch return BuiltinError.OutOfMemory;
    return Value{ .array = slice };
}

/// include?(substring) — check if string contains substring
pub fn includeQ(ctx: ExecCtx, receiver: ?Value, args: []const Value) BuiltinError!Value {
    const s = try receiverStr(ctx.allocator, receiver);
    if (args.len == 0) return Value{ .bool = false };
    const sub_str = try args[0].asString(ctx.allocator);
    return Value{ .bool = std.mem.indexOf(u8, s, sub_str) != null };
}

/// start_with?(prefix) — check if string starts with prefix
pub fn startWithQ(ctx: ExecCtx, receiver: ?Value, args: []const Value) BuiltinError!Value {
    const s = try receiverStr(ctx.allocator, receiver);
    if (args.len == 0) return Value{ .bool = false };
    const prefix = try args[0].asString(ctx.allocator);
    return Value{ .bool = std.mem.startsWith(u8, s, prefix) };
}

/// end_with?(suffix) — check if string ends with suffix
pub fn endWithQ(ctx: ExecCtx, receiver: ?Value, args: []const Value) BuiltinError!Value {
    const s = try receiverStr(ctx.allocator, receiver);
    if (args.len == 0) return Value{ .bool = false };
    const suffix = try args[0].asString(ctx.allocator);
    return Value{ .bool = std.mem.endsWith(u8, s, suffix) };
}

/// to_s — identity (return self as string)
pub fn toS(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const s = try receiverStr(ctx.allocator, receiver);
    return Value{ .string = s };
}

/// empty? — check if string is empty
pub fn emptyQ(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const s = try receiverStr(ctx.allocator, receiver);
    return Value{ .bool = s.len == 0 };
}

/// length / size — return string length
pub fn length(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const s = try receiverStr(ctx.allocator, receiver);
    return Value{ .int = @intCast(s.len) };
}

/// + (concatenation) — concatenate two strings
pub fn concat(ctx: ExecCtx, receiver: ?Value, args: []const Value) BuiltinError!Value {
    const s = try receiverStr(ctx.allocator, receiver);
    if (args.len == 0) return Value{ .string = s };
    const other = try args[0].asString(ctx.allocator);
    const result = std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ s, other }) catch return BuiltinError.OutOfMemory;
    return Value{ .string = result };
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

// ---------------------------------------------------------------------------
// Version-style accessors — Homebrew routinely chains `x.major` on string
// results from `OS.kernel_version` / `MacOS.version` / `Version.new(x)`.
// Faithful to Ruby's Version contract: strip an optional leading `v`, split
// on `.`, yield the Nth numeric segment as an Int, missing/non-numeric
// segments degrade to `0` (same policy as `"".to_i`).
// ---------------------------------------------------------------------------

/// `.major` — first numeric segment of a version string.
pub fn major(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    return Value{ .int = versionSegment(try receiverStr(ctx.allocator, receiver), 0) };
}

/// `.minor` — second numeric segment; 0 if absent.
pub fn minor(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    return Value{ .int = versionSegment(try receiverStr(ctx.allocator, receiver), 1) };
}

/// `.patch` — third numeric segment; 0 if absent.
pub fn patch(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    return Value{ .int = versionSegment(try receiverStr(ctx.allocator, receiver), 2) };
}

/// `.to_i` — Ruby's leading-integer parse: reads an optional sign then as
/// many digits as possible; junk at the tail is ignored. Empty / no-digit
/// input yields 0.
pub fn toI(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const s = std.mem.trim(u8, try receiverStr(ctx.allocator, receiver), " \t\r\n");
    if (s.len == 0) return Value{ .int = 0 };

    var i: usize = 0;
    var negative = false;
    if (s[0] == '-' or s[0] == '+') {
        negative = s[0] == '-';
        i = 1;
    }
    var n: i64 = 0;
    var saw_digit = false;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
        n = n *% 10 +% @as(i64, s[i] - '0');
        saw_digit = true;
    }
    if (!saw_digit) return Value{ .int = 0 };
    return Value{ .int = if (negative) -n else n };
}

/// Return the `index`-th numeric segment of a dotted version string, or 0
/// when the segment is missing or non-numeric.
fn versionSegment(raw: []const u8, index: usize) i64 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const stripped = if (trimmed.len > 0 and (trimmed[0] == 'v' or trimmed[0] == 'V'))
        trimmed[1..]
    else
        trimmed;

    var it = std.mem.splitScalar(u8, stripped, '.');
    var seen: usize = 0;
    while (it.next()) |segment| : (seen += 1) {
        if (seen == index) return parseLeadingInt(segment);
    }
    return 0;
}

/// Read as many leading digits as possible and return them as i64. Used by
/// both `versionSegment` and `.to_i`. Non-digit-led input yields 0.
fn parseLeadingInt(s: []const u8) i64 {
    var n: i64 = 0;
    var saw_digit = false;
    for (s) |b| {
        if (!std.ascii.isDigit(b)) break;
        n = n *% 10 +% @as(i64, b - '0');
        saw_digit = true;
    }
    return if (saw_digit) n else 0;
}
