//! malt — test-only allocator that fails a single allocation.

const std = @import("std");
const testing = std.testing;

/// Fails only the allocation at `at`. FailingAllocator keeps failing after its
/// index, so a path that drops one failure and carries on never runs under it.
pub const OneShotFail = struct {
    child: std.mem.Allocator,
    at: usize,
    n: usize = 0,

    pub fn allocator(self: *OneShotFail) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *OneShotFail = @ptrCast(@alignCast(ctx));
        defer self.n += 1;
        if (self.n == self.at) return null;
        return self.child.rawAlloc(len, a, ra);
    }

    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *OneShotFail = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(m, a, new_len, ra);
    }

    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *OneShotFail = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(m, a, new_len, ra);
    }

    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *OneShotFail = @ptrCast(@alignCast(ctx));
        self.child.rawFree(m, a, ra);
    }
};

/// Every run must end in OutOfMemory or pass `func`'s own value checks. Stops
/// at the first run that never reaches its failure index.
pub fn sweep(comptime func: anytype, args: anytype) !void {
    var at: usize = 0;
    while (true) : (at += 1) {
        var fa: OneShotFail = .{ .child = testing.allocator, .at = at };
        @call(.auto, func, .{fa.allocator()} ++ args) catch |e| {
            try testing.expectEqual(error.OutOfMemory, e);
            continue;
        };
        if (fa.n <= at) break;
    }
}

fn failsOnlyOnce(allocator: std.mem.Allocator, seen: *usize) !void {
    const a = allocator.alloc(u8, 1) catch null;
    defer if (a) |p| allocator.free(p);
    const b = try allocator.alloc(u8, 1);
    defer allocator.free(b);
    if (a != null) seen.* += 1;
}

test "OneShotFail fails one allocation and lets the next one through" {
    // Index 0 fails `a` only; a sticky allocator would fail `b` too.
    var seen: usize = 0;
    var fa: OneShotFail = .{ .child = testing.allocator, .at = 0 };
    try failsOnlyOnce(fa.allocator(), &seen);
    try testing.expectEqual(@as(usize, 0), seen);
}
