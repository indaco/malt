//! malt - text_replace integration tests.
//!
//! Inline tests in src/text_replace.zig pin the small-input branches.
//! These cases exercise the function past what fits inside the source
//! file: allocator-failure semantics, large multi-match haystacks, and
//! realistic .la / pkgconfig payloads of the kind mt migrate rewrites.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const text_replace = malt.text_replace;

test "replaceAll surfaces OOM when the result allocation fails" {
    // One alloc happens on the match path: the output buffer. fail_index=0
    // trips it. The function must surface OutOfMemory rather than panic or
    // hand back a partial slice.
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(
        error.OutOfMemory,
        text_replace.replaceAll(failing.allocator(), "abcXdef", "X", "YYYY"),
    );
}

test "replaceAll on a no-match input never touches the allocator" {
    // The fast path returns the input slice; even an allocator that fails
    // every request must not see a call.
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const haystack: []const u8 = "no needles in this hay";
    const out = try text_replace.replaceAll(failing.allocator(), haystack, "absent", "present");
    try testing.expectEqual(haystack.ptr, out.ptr);
    try testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "replaceAll on an empty-needle input never touches the allocator" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const haystack: []const u8 = "abc";
    const out = try text_replace.replaceAll(failing.allocator(), haystack, "", "Z");
    try testing.expectEqual(haystack.ptr, out.ptr);
    try testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "replaceAll on a 1000-match haystack produces the expected expansion" {
    // Synthesise "X<sep>X<sep>...X" where <sep> is a fixed 7-byte block, so
    // the matches are spaced widely enough to exercise findPos crossing
    // memchr boundaries on every iteration.
    const sep = "_______";
    const matches: usize = 1000;

    var hay = std.ArrayList(u8).empty;
    defer hay.deinit(testing.allocator);
    for (0..matches) |i| {
        try hay.appendSlice(testing.allocator, "X");
        if (i + 1 < matches) try hay.appendSlice(testing.allocator, sep);
    }

    const out = try text_replace.replaceAll(testing.allocator, hay.items, "X", "YY");
    defer if (out.ptr != hay.items.ptr) testing.allocator.free(out);

    // Byte-exact length check: 2*matches replacement bytes + (matches-1)*sep.
    try testing.expectEqual(matches * 2 + (matches - 1) * sep.len, out.len);
    // Each match site holds "YY"; each separator is preserved verbatim.
    try testing.expect(std.mem.startsWith(u8, out, "YY"));
    try testing.expect(std.mem.endsWith(u8, out, "YY"));
    try testing.expectEqual(@as(usize, matches), std.mem.count(u8, out, "YY"));
    try testing.expectEqual(matches - 1, std.mem.count(u8, out, sep));
}

test "replaceAll rewrites every prefix= line in a synthetic pkgconfig body" {
    // Representative of the .pc / .la rewrites mt migrate drives through
    // inreplace: many short fixed-prefix matches scattered across a body
    // that also contains tokens which must not be touched.
    const body =
        "prefix=/old/opt/foo\n" ++
        "exec_prefix=${prefix}\n" ++
        "libdir=/old/opt/foo/lib\n" ++
        "includedir=/old/opt/foo/include\n" ++
        "Name: foo\n" ++
        "Description: refers to /old/opt/foo at runtime\n" ++
        "Cflags: -I/old/opt/foo/include\n" ++
        "Libs: -L/old/opt/foo/lib -lfoo\n";

    const expected =
        "prefix=/new/cellar/foo\n" ++
        "exec_prefix=${prefix}\n" ++
        "libdir=/new/cellar/foo/lib\n" ++
        "includedir=/new/cellar/foo/include\n" ++
        "Name: foo\n" ++
        "Description: refers to /new/cellar/foo at runtime\n" ++
        "Cflags: -I/new/cellar/foo/include\n" ++
        "Libs: -L/new/cellar/foo/lib -lfoo\n";

    const out = try text_replace.replaceAll(testing.allocator, body, "/old/opt/foo", "/new/cellar/foo");
    defer if (out.ptr != body.ptr) testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

test "replaceAll preserves byte order across an alternating match/non-match pattern" {
    // Stress the segment-copy path: many small interleaved matches and
    // non-match runs of mixed length, so each iteration of the copy loop
    // hits a non-zero segment_len and a different tail size.
    const haystack =
        "aa<MATCH>bbb<MATCH>c<MATCH>dddd<MATCH>e<MATCH>ffffff";
    const expected =
        "aa[r]bbb[r]c[r]dddd[r]e[r]ffffff";

    const out = try text_replace.replaceAll(testing.allocator, haystack, "<MATCH>", "[r]");
    defer if (out.ptr != haystack.ptr) testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}
