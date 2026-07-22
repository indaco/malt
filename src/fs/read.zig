//! malt — read an entire file at an absolute path into an owned buffer.
//!
//! Shared leaf: the self-update trust layer, the notifier cache, and the DSL
//! builtins all slurp whole small files this way. `max_bytes` is a per-call
//! cap so an oversized or hostile file cannot exhaust memory — bytes past the
//! cap are dropped silently, matching every historical call site.

const std = @import("std");

/// Read up to `max_bytes` of `abs_path` into a freshly-allocated slice the
/// caller owns and frees. Files larger than `max_bytes` are truncated to the
/// cap. The slice is shrunk to the bytes actually read.
pub fn readFileAllAbsolute(io: std.Io, allocator: std.mem.Allocator, abs_path: []const u8, max_bytes: usize) ![]u8 {
    const f = try std.Io.Dir.openFileAbsolute(io, abs_path, .{});
    defer f.close(io);
    const st = try f.stat(io);
    const size = @min(@as(u64, max_bytes), st.size);
    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);
    const n = try f.readPositionalAll(io, buf, 0);
    if (n == buf.len) return buf;
    if (allocator.resize(buf, n)) return buf[0..n];
    const shrunk = try allocator.alloc(u8, n);
    @memcpy(shrunk, buf[0..n]);
    allocator.free(buf);
    return shrunk;
}

// ── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// Blocking debug IO drives the real syscalls each test needs.
const test_io = std.Options.debug_io;

fn rmrf(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(test_io, path) catch {};
}

var scratch_seq: std.atomic.Value(u32) = .init(0);

/// Scratch path under a process- and call-unique base: overlapping test runs
/// share /tmp and would otherwise delete each other's fixtures.
const Scratch = struct {
    arena: std.heap.ArenaAllocator,
    base: [:0]const u8,

    fn init(comptime tag: []const u8) !Scratch {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const base = try std.fmt.allocPrintSentinel(
            arena.allocator(),
            "/tmp/malt_read_" ++ tag ++ "_{d}_{d}",
            .{ std.c.getpid(), scratch_seq.fetchAdd(1, .monotonic) },
            0,
        );
        rmrf(base);
        return .{ .arena = arena, .base = base };
    }

    fn deinit(self: *Scratch) void {
        rmrf(self.base);
        self.arena.deinit();
    }
};

fn writeTmp(path: []const u8, bytes: []const u8) !void {
    const f = try std.Io.Dir.cwd().createFile(test_io, path, .{ .truncate = true });
    defer f.close(test_io);
    try f.writeStreamingAll(test_io, bytes);
}

test "empty file returns a zero-length slice" {
    var s = try Scratch.init("empty");
    defer s.deinit();
    const path = s.base;
    try writeTmp(path, "");

    const out = try readFileAllAbsolute(test_io, testing.allocator, path, 1024);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "file smaller than the cap returns full contents" {
    var s = try Scratch.init("small");
    defer s.deinit();
    const path = s.base;
    try writeTmp(path, "hello");

    const out = try readFileAllAbsolute(test_io, testing.allocator, path, 1024);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello", out);
}

test "file exactly at the cap returns full contents" {
    var s = try Scratch.init("exact");
    defer s.deinit();
    const path = s.base;
    try writeTmp(path, "abcdefgh");

    const out = try readFileAllAbsolute(test_io, testing.allocator, path, 8);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("abcdefgh", out);
}

test "file larger than the cap is silently truncated to the cap" {
    var s = try Scratch.init("trunc");
    defer s.deinit();
    const path = s.base;
    try writeTmp(path, "0123456789ABCDEFGHIJ"); // 20 bytes

    const out = try readFileAllAbsolute(test_io, testing.allocator, path, 8);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("01234567", out);
}

// Shrinks the target file the instant its read buffer is allocated — i.e.
// between the stat and the read inside readFileAllAbsolute — so the read
// comes up short, then refuses `resize` so the helper takes its
// @memcpy-into-fresh-alloc fallback. Alloc/free delegate to a real allocator
// so std.testing's leak check still guards that fallback's free.
const ShrinkTrigger = struct {
    parent: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    truncate_to: u64,
    fired: bool = false,

    fn allocator(self: *ShrinkTrigger) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    // ctx is always a *ShrinkTrigger we handed to the vtable; the cast is the
    // standard type-erased-allocator round-trip.
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *ShrinkTrigger = @ptrCast(@alignCast(ctx));
        if (!self.fired) {
            self.fired = true;
            const f = std.Io.Dir.openFileAbsolute(self.io, self.path, .{ .mode = .read_write }) catch return null;
            defer f.close(self.io);
            f.setLength(self.io, self.truncate_to) catch return null;
        }
        return self.parent.rawAlloc(len, alignment, ra);
    }

    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false; // force the shrink fallback, not an in-place resize
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null; // no remap → the alloc-and-copy fallback is exercised
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *ShrinkTrigger = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(memory, alignment, ra);
    }
};

test "a missing file surfaces error.FileNotFound" {
    // readCache switches on exactly this error to mean "no cache yet", so the
    // helper must keep surfacing it rather than mapping it to something else.
    // Unique but deliberately never created.
    var s = try Scratch.init("absent");
    defer s.deinit();
    const path = s.base;
    try testing.expectError(
        error.FileNotFound,
        readFileAllAbsolute(test_io, testing.allocator, path, 1024),
    );
}

test "short read falls back to a fresh allocation when resize fails" {
    var s = try Scratch.init("shrink");
    defer s.deinit();
    const path = s.base;
    try writeTmp(path, "0123456789"); // 10 bytes; buffer sized to 10

    var trigger = ShrinkTrigger{
        .parent = testing.allocator,
        .io = test_io,
        .path = path,
        .truncate_to = 4, // read comes back short: 4 < 10
    };
    const out = try readFileAllAbsolute(test_io, trigger.allocator(), path, 1024);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("0123", out);
}
