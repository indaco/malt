//! malt — fs_compat.streamFile tests
//!
//! streamFile is the future-proof "walk a file in chunks" helper —
//! every multi-chunk consumer (hashing, scanning, checksumming) should
//! reach for it instead of hand-rolling a `readAll` loop that silently
//! reads the first chunk over and over.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const fs = malt.fs_compat;

// Any chunk size the helper accepts must work at both sides of the
// boundary. The tests below use a small buffer on purpose so "more
// than one chunk" is cheap to provoke.
const TEST_CHUNK: usize = 64;

fn tempFilePath(tag: []const u8, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "/tmp/malt_stream_{s}_{d}", .{ tag, fs.nanoTimestamp() });
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    const f = try fs.createFileAbsolute(path, .{});
    defer f.close();
    try f.writeAll(bytes);
}

// Collector callback — appends every chunk into an ArrayList so the
// test can assert the full byte sequence the helper surfaced.
const Collector = struct {
    list: *std.ArrayList(u8),

    fn callback(ctx: *anyopaque, chunk: []const u8) anyerror!void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        try self.list.appendSlice(testing.allocator, chunk);
    }
};

fn runStream(path: []const u8) !std.ArrayList(u8) {
    const f = try fs.openFileAbsolute(path, .{});
    defer f.close();
    var collected: std.ArrayList(u8) = .empty;
    errdefer collected.deinit(testing.allocator);
    var c = Collector{ .list = &collected };
    var buf: [TEST_CHUNK]u8 = undefined;
    try fs.streamFile(f, &buf, .{ .context = @ptrCast(&c), .func = &Collector.callback });
    return collected;
}

// ── size sweep: every boundary vs the chunk size ─────────────────────

fn assertRoundTrip(tag: []const u8, size: usize) !void {
    const payload = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @intCast((i *% 131 +% 7) & 0xFF);

    var path_buf: [128]u8 = undefined;
    const p = try tempFilePath(tag, &path_buf);
    try writeFile(p, payload);
    defer fs.cwd().deleteFile(p) catch {};

    var got = try runStream(p);
    defer got.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, payload, got.items);
}

test "streamFile surfaces nothing for an empty file" {
    try assertRoundTrip("empty", 0);
}

test "streamFile surfaces a 1-byte file" {
    try assertRoundTrip("one", 1);
}

test "streamFile surfaces a sub-chunk file" {
    try assertRoundTrip("sub", TEST_CHUNK - 3);
}

test "streamFile surfaces a file exactly one chunk long" {
    try assertRoundTrip("eq", TEST_CHUNK);
}

test "streamFile surfaces a file that straddles the chunk boundary" {
    try assertRoundTrip("straddle", TEST_CHUNK + 1);
}

test "streamFile surfaces a multi-chunk file without losing bytes" {
    try assertRoundTrip("multi", TEST_CHUNK * 4 + 17);
}

test "streamFile keeps bytes in order across chunks" {
    // Sanity check beyond "lengths match" — if the helper ever starts
    // re-reading the first chunk the bytes will be wrong even though
    // the count could still line up.
    const size = TEST_CHUNK * 3 + 5;
    const payload = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @intCast(i & 0xFF);

    var path_buf: [128]u8 = undefined;
    const p = try tempFilePath("order", &path_buf);
    try writeFile(p, payload);
    defer fs.cwd().deleteFile(p) catch {};

    var got = try runStream(p);
    defer got.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, payload, got.items);
}

// ── callback-error propagation ───────────────────────────────────────

const AbortCtx = struct {
    seen: usize = 0,
    abort_after: usize,

    fn callback(ctx: *anyopaque, chunk: []const u8) anyerror!void {
        const self: *AbortCtx = @ptrCast(@alignCast(ctx));
        self.seen += chunk.len;
        if (self.seen > self.abort_after) return error.CallbackAborted;
    }
};

test "streamFile propagates a callback error and stops reading" {
    const payload = try testing.allocator.alloc(u8, TEST_CHUNK * 4);
    defer testing.allocator.free(payload);
    @memset(payload, 'x');

    var path_buf: [128]u8 = undefined;
    const p = try tempFilePath("abort", &path_buf);
    try writeFile(p, payload);
    defer fs.cwd().deleteFile(p) catch {};

    const f = try fs.openFileAbsolute(p, .{});
    defer f.close();

    var buf: [TEST_CHUNK]u8 = undefined;
    var ctx = AbortCtx{ .abort_after = TEST_CHUNK }; // stop after the first chunk
    try testing.expectError(
        error.CallbackAborted,
        fs.streamFile(f, &buf, .{ .context = @ptrCast(&ctx), .func = &AbortCtx.callback }),
    );
    // Only one chunk (or maybe two, depending on chunk size boundary)
    // was delivered — definitely not the full file.
    try testing.expect(ctx.seen < payload.len);
}

test "streamFile rejects a zero-length buffer" {
    // A zero-sized chunk buffer would silently loop forever (readAllAt
    // on an empty slice returns 0 and the guard can't distinguish EOF
    // from no-progress). Fail loud instead.
    var path_buf: [128]u8 = undefined;
    const p = try tempFilePath("zerobuf", &path_buf);
    try writeFile(p, "hello");
    defer fs.cwd().deleteFile(p) catch {};

    const f = try fs.openFileAbsolute(p, .{});
    defer f.close();

    var empty: [0]u8 = undefined;
    var ctx = AbortCtx{ .abort_after = 1 };
    try testing.expectError(
        error.InvalidArgument,
        fs.streamFile(f, &empty, .{ .context = @ptrCast(&ctx), .func = &AbortCtx.callback }),
    );
}
