//! malt — worker-local arena stress test (S7)
//!
//! Validates the invariant S7 introduced: each parallel worker in the
//! install / search paths owns its own `ArenaAllocator` on
//! `page_allocator`, never sharing a bump-pointer across threads.
//!
//! The test does not exercise `install.zig` / `search.zig` directly —
//! those pull in the full HTTP + DB stack. Instead it mirrors the
//! *shape* they use (per-worker context struct holding its own arena,
//! results duped back into a caller allocator after join) so a future
//! regression where someone re-introduces a shared arena would trip.

const std = @import("std");
const testing = std.testing;

const n_workers: usize = 32;
const allocs_per_worker: usize = 256;

/// Mirror of `install.FetchFormulaCtx` — per-worker arena plus a
/// result slice the caller dupes after join.
const Ctx = struct {
    arena: std.heap.ArenaAllocator,
    seed: u64,
    result: ?[]const u8 = null,

    fn run(self: *Ctx) void {
        const a = self.arena.allocator();
        var prng = std.Random.DefaultPrng.init(self.seed);
        const rng = prng.random();

        // Many small allocs → would thrash a shared bump-pointer
        // across threads.
        var i: usize = 0;
        while (i < allocs_per_worker) : (i += 1) {
            const sz = rng.intRangeAtMost(usize, 1, 4096);
            const buf = a.alloc(u8, sz) catch return;
            buf[0] = @as(u8, @intCast(self.seed & 0xff));
            buf[buf.len - 1] = @as(u8, @intCast(i & 0xff));
        }

        // One "result" the caller will dupe out — same handoff shape
        // the fetchFormula workers use.
        self.result = std.fmt.allocPrint(a, "worker-{d}-ok", .{self.seed}) catch null;
    }
};

test "each parallel worker has its own arena; results survive per-worker deinit" {
    const allocator = testing.allocator;

    const ctxs = try allocator.alloc(Ctx, n_workers);
    defer {
        for (ctxs) |*c| c.arena.deinit();
        allocator.free(ctxs);
    }
    for (ctxs, 0..) |*c, i| {
        c.* = .{
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .seed = @as(u64, i) + 1,
        };
    }

    const threads = try allocator.alloc(std.Thread, n_workers);
    defer allocator.free(threads);

    for (ctxs, 0..) |*c, i| {
        threads[i] = try std.Thread.spawn(.{}, Ctx.run, .{c});
    }
    for (threads) |t| t.join();

    // Dupe results out of each worker arena — same pattern the real
    // resolve path uses before deinit'ing per-worker arenas.
    const duped = try allocator.alloc(?[]const u8, n_workers);
    defer {
        for (duped) |d| if (d) |s| allocator.free(s);
        allocator.free(duped);
    }
    @memset(duped, null);
    for (ctxs, 0..) |*c, i| {
        if (c.result) |bytes| {
            duped[i] = try allocator.dupe(u8, bytes);
        }
    }

    // Sanity — every worker produced its expected payload.
    var got: usize = 0;
    var expect_buf: [32]u8 = undefined;
    for (duped, 0..) |d, i| {
        const s = d orelse continue;
        const expect = try std.fmt.bufPrint(&expect_buf, "worker-{d}-ok", .{i + 1});
        try testing.expectEqualStrings(expect, s);
        got += 1;
    }
    try testing.expectEqual(@as(usize, n_workers), got);
}

test "spawn-failure fallback path still runs the worker inline" {
    // Mirrors the `else |_| ctxs[i].run();` branch in install.zig: a
    // context's `run` must be callable on the caller thread and
    // produce the same result shape as the spawned variant.
    var ctx: Ctx = .{
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .seed = 42,
    };
    defer ctx.arena.deinit();

    ctx.run();
    try testing.expect(ctx.result != null);
    try testing.expectEqualStrings("worker-42-ok", ctx.result.?);
}
