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

    fn callback(ctx: *anyopaque, chunk: []const u8) fs.StreamError!void {
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

// ── callback-signature shape ─────────────────────────────────────────
//
// Pin that `StreamCallback.func` returns a closed error set, not
// `anyerror`. A closed set lets every caller switch exhaustively on the
// concrete tags; `anyerror` would swallow new tags silently.
test "StreamCallback.func declares a closed error set" {
    const FuncPtr = std.meta.fieldInfo(fs.StreamCallback, .func).type;
    const FnType = @typeInfo(FuncPtr).pointer.child;
    const RetT = @typeInfo(FnType).@"fn".return_type.?;
    const ErrSet = @typeInfo(RetT).error_union.error_set;
    try testing.expect(@typeInfo(ErrSet).error_set != null);
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

    fn callback(ctx: *anyopaque, chunk: []const u8) fs.StreamError!void {
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

// ── readToEndAlloc: allocator-contract safety on short reads ─────────

const TruncRacer = struct {
    path: []const u8,
    payload: []const u8,
    stop: std.atomic.Value(bool),

    fn run(self: *TruncRacer) void {
        // Bounce the file between "full payload" and "empty" as fast as
        // the kernel will let us. Any reader that stats BEFORE a truncate
        // and reads AFTER it observes stat.size > bytes-available — the
        // exact short-read race the fix has to survive.
        while (!self.stop.load(.acquire)) {
            const ft = fs.openFileAbsolute(self.path, .{ .mode = .read_write }) catch continue;
            _ = ft.setEndPos(0) catch {};
            ft.writeAll(self.payload) catch {};
            ft.close();
        }
    }
};

// ── randomBytes / randomInt: non-constant output ────────────────────
//
// Pin that the CSPRNG helpers actually fill the buffer. The underlying
// binding could silently return zeros on a future port; a hard-coded
// "all-zero" output would make `atomic.createTempDir` deterministic —
// the exact smell BUG-013 warns about.

test "randomBytes produces non-equal buffers on consecutive calls" {
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    fs.randomBytes(&a);
    fs.randomBytes(&b);
    try testing.expect(!std.mem.eql(u8, &a, &b));
    // Also rule out "returned zeros" — a broken impl could output a
    // different pair of constants; cheaper to just reject all-zero.
    const zero: [32]u8 = @splat(0);
    try testing.expect(!std.mem.eql(u8, &a, &zero));
}

test "randomInt produces non-equal values on consecutive calls" {
    const a = fs.randomInt(u64);
    const b = fs.randomInt(u64);
    try testing.expect(a != b);
}

test "readToEndAlloc honors allocator contract when the file shrinks between stat and read" {
    // Racy truncate reproduces BUG-002: the old code returned `buf[0..n]`
    // of an allocation sized to `stat.size`, so any short read (sparse
    // file, concurrent truncate, fs size drift) tripped testing.allocator's
    // length-mismatch trap on `free`. The fix informs the allocator via
    // `resize` before returning the trimmed slice.
    const alloc = testing.allocator;

    var path_buf: [128]u8 = undefined;
    const p = try tempFilePath("shortread", &path_buf);
    defer fs.cwd().deleteFile(p) catch {};

    const BIG: usize = 256 * 1024;
    const payload = try alloc.alloc(u8, BIG);
    defer alloc.free(payload);
    @memset(payload, 'A');

    try writeFile(p, payload);

    var racer = TruncRacer{
        .path = p,
        .payload = payload,
        .stop = std.atomic.Value(bool).init(false),
    };
    const thread = try std.Thread.spawn(.{}, TruncRacer.run, .{&racer});
    defer {
        racer.stop.store(true, .release);
        thread.join();
    }

    // Many iterations so the race has ample chance to interleave stat
    // before read. Under the buggy code a single short-read free traps
    // the whole process; under the fix every free is contract-safe.
    var iter: usize = 0;
    while (iter < 128) : (iter += 1) {
        const f = fs.openFileAbsolute(p, .{}) catch continue;
        const got = f.readToEndAlloc(alloc, BIG * 2) catch {
            f.close();
            continue;
        };
        f.close();
        // The canary: if the slice length disagrees with the tracked
        // allocation length, testing.allocator's DebugAllocator will
        // abort here.
        alloc.free(got);
    }
}
