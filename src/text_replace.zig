//! malt - shared byte-string replace.
//!
//! `mt migrate` rewrites and Mach-O text patching both walk large bodies of
//! `.la` / pkgconfig / dylib bytes; the hot path is dominated by the inner
//! match loop. `std.mem.indexOf` / `std.mem.findPos` go through memchr,
//! which beats a hand-rolled `mem.eqlBytes` byte scan by an order of
//! magnitude on small needles.

const std = @import("std");

/// Replace every occurrence of `needle` in `haystack` with `replacement`.
/// Returns the original slice (same pointer) when `needle` is empty or has
/// no match - callers must compare pointers before freeing if they own
/// `haystack`. Otherwise the result is a caller-owned allocation.
pub fn replaceAll(
    allocator: std.mem.Allocator,
    haystack: []const u8,
    needle: []const u8,
    replacement: []const u8,
) ![]const u8 {
    if (needle.len == 0) return haystack;

    // Fast path: no matches at all -> hand back the original slice.
    const first = std.mem.indexOf(u8, haystack, needle) orelse return haystack;

    // Count remaining matches in a single linear pass so the output
    // allocation is sized exactly.
    var match_count: usize = 1;
    var probe = first + needle.len;
    while (std.mem.findPos(u8, haystack, probe, needle)) |p| {
        match_count += 1;
        probe = p + needle.len;
    }

    const rep_len = replacement.len;
    const ndl_len = needle.len;
    const new_len = haystack.len + match_count * rep_len - match_count * ndl_len;
    const buf = try allocator.alloc(u8, new_len);
    errdefer allocator.free(buf);

    var src: usize = 0;
    var dst: usize = 0;
    var match = first;
    while (true) {
        const segment_len = match - src;
        if (segment_len > 0) {
            @memcpy(buf[dst .. dst + segment_len], haystack[src..match]);
            dst += segment_len;
        }
        @memcpy(buf[dst .. dst + rep_len], replacement);
        dst += rep_len;
        src = match + ndl_len;

        match = std.mem.findPos(u8, haystack, src, needle) orelse break;
    }

    if (src < haystack.len) {
        @memcpy(buf[dst .. dst + (haystack.len - src)], haystack[src..]);
        dst += haystack.len - src;
    }

    std.debug.assert(dst == new_len);
    return buf;
}

test "replaceAll on multi-match expanding replacement rewrites every occurrence" {
    const haystack = "aXbXc";
    const out = try replaceAll(std.testing.allocator, haystack, "X", "YYY");
    defer if (out.ptr != haystack.ptr) std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("aYYYbYYYc", out);
}

test "replaceAll on contracting replacement keeps tail bytes intact" {
    const haystack = "header /OLD/path/to/lib /OLD/other tail";
    const out = try replaceAll(std.testing.allocator, haystack, "/OLD", "/N");
    defer if (out.ptr != haystack.ptr) std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("header /N/path/to/lib /N/other tail", out);
}

test "replaceAll with no match returns the input slice unchanged" {
    const haystack: []const u8 = "no needles here";
    const out = try replaceAll(std.testing.allocator, haystack, "absent", "present");
    try std.testing.expectEqual(haystack.ptr, out.ptr);
    try std.testing.expectEqual(haystack.len, out.len);
}

test "replaceAll with empty needle returns the input slice unchanged" {
    const haystack: []const u8 = "abc";
    const out = try replaceAll(std.testing.allocator, haystack, "", "Z");
    try std.testing.expectEqual(haystack.ptr, out.ptr);
}

test "replaceAll handles overlapping-prefix needles without skipping matches" {
    // "aaa" with needle "aa" should yield exactly two non-overlapping matches.
    const haystack = "aaaa";
    const out = try replaceAll(std.testing.allocator, haystack, "aa", "B");
    defer if (out.ptr != haystack.ptr) std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("BB", out);
}

test "replaceAll deletes matches when replacement is empty" {
    const haystack = "remove-X-and-X-everything";
    const out = try replaceAll(std.testing.allocator, haystack, "X-", "");
    defer if (out.ptr != haystack.ptr) std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("remove-and-everything", out);
}

test "replaceAll on adjacent matches walks past each one cleanly" {
    const haystack = "AAAA";
    const out = try replaceAll(std.testing.allocator, haystack, "A", "ZZ");
    defer if (out.ptr != haystack.ptr) std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("ZZZZZZZZ", out);
}
