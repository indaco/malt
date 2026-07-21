//! malt — run command integration tests
//!
//! Pure parsing and path-formatting tests live inline in `src/cli/run.zig`.
//! This file covers the `--keep` cache lookup against a real on-disk layout.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const cli_run = malt.cli_run;

/// Scratch tree under a process-unique base, so overlapping test runs cannot
/// wipe each other's fixtures.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    base: [:0]const u8,

    fn init(tag: []const u8) !Fixture {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const base = try test_io.uniqueTempPath(arena.allocator(), "run", tag);
        const base_z = try arena.allocator().dupeZ(u8, base);
        test_io.deleteTreeAbsolute(std.Options.debug_io, base_z) catch {};
        try test_io.cwd().createDirPath(std.Options.debug_io, base_z);
        return .{ .arena = arena, .base = base_z };
    }

    /// Absolute path to `sub` inside the fixture; valid until `deinit`.
    fn p(self: *Fixture, sub: []const u8) [:0]const u8 {
        return std.fmt.allocPrintSentinel(
            self.arena.allocator(),
            "{s}/{s}",
            .{ self.base, sub },
            0,
        ) catch @panic("OOM");
    }

    fn deinit(self: *Fixture) void {
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.base) catch {};
        self.arena.deinit();
    }
};

test "findCachedBinary returns the path when the cached binary exists" {
    var fx = try Fixture.init("keep_hit");
    defer fx.deinit();
    const base = fx.base;

    const sha = "abc123";
    const pkg = "jq";
    const ver = "1.7.1";

    const bin_dir = try std.fmt.allocPrint(testing.allocator, "{s}/run/{s}/{s}/{s}/bin", .{ base, sha, pkg, ver });
    defer testing.allocator.free(bin_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, bin_dir);

    const expected_bin = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ bin_dir, pkg });
    defer testing.allocator.free(expected_bin);
    const f = try test_io.createFileAbsolute(std.Options.debug_io, expected_bin, .{});
    f.close(std.Options.debug_io);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    var probe_buf: [512]u8 = undefined;
    const cached = try cli_run.findCachedBinary(&ctx, &probe_buf, base, sha, pkg, ver);
    try testing.expect(cached != null);
    try testing.expectEqualStrings(expected_bin, cached.?);
}

test "findCachedBinary reports miss when the cache is empty" {
    var fx = try Fixture.init("keep_miss");
    defer fx.deinit();
    const base = fx.base;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    var probe_buf: [512]u8 = undefined;
    const cached = try cli_run.findCachedBinary(&ctx, &probe_buf, base, "abc", "jq", "1.0");
    try testing.expect(cached == null);
}

// Locks down the property that a cached bottle for one SHA does NOT satisfy
// a probe for another SHA — guards against accidental cross-version reuse
// when an upstream rebuilds with the same `version` string.
test "findCachedBinary keys cache slot on sha256, not just pkg+version" {
    var fx = try Fixture.init("keep_sha_isolation");
    defer fx.deinit();
    const base = fx.base;

    const sha_a = "aaa111";
    const sha_b = "bbb222";
    const pkg = "jq";
    const ver = "1.7.1";

    const bin_dir = try std.fmt.allocPrint(testing.allocator, "{s}/run/{s}/{s}/{s}/bin", .{ base, sha_a, pkg, ver });
    defer testing.allocator.free(bin_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, bin_dir);
    const bin_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ bin_dir, pkg });
    defer testing.allocator.free(bin_path);
    const f = try test_io.createFileAbsolute(std.Options.debug_io, bin_path, .{});
    f.close(std.Options.debug_io);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    var probe_buf: [512]u8 = undefined;
    const same_sha = try cli_run.findCachedBinary(&ctx, &probe_buf, base, sha_a, pkg, ver);
    try testing.expect(same_sha != null);

    const other_sha = try cli_run.findCachedBinary(&ctx, &probe_buf, base, sha_b, pkg, ver);
    try testing.expect(other_sha == null);
}

test "findCachedBinary requires the version directory to match" {
    var fx = try Fixture.init("keep_ver_isolation");
    defer fx.deinit();
    const base = fx.base;

    const sha = "abc";
    const pkg = "jq";

    const bin_dir = try std.fmt.allocPrint(testing.allocator, "{s}/run/{s}/{s}/1.7.1/bin", .{ base, sha, pkg });
    defer testing.allocator.free(bin_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, bin_dir);
    const bin_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ bin_dir, pkg });
    defer testing.allocator.free(bin_path);
    const f = try test_io.createFileAbsolute(std.Options.debug_io, bin_path, .{});
    f.close(std.Options.debug_io);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    var probe_buf: [512]u8 = undefined;
    const wrong_ver = try cli_run.findCachedBinary(&ctx, &probe_buf, base, sha, pkg, "2.0");
    try testing.expect(wrong_ver == null);
}

// Acquiring the same lock from a second handle within one process must
// time out (flock is per-process on the SAME fd path here, but separate
// LockFile.acquire calls open new fds, which on macOS/Linux contend).
test "LockFile blocks a second acquire on the same path" {
    var fx = try Fixture.init("keep_lock_test");
    defer fx.deinit();
    const lock_path = fx.p("lock");

    const io = std.Options.debug_io;
    var first = try malt.lock.LockFile.acquire(io, lock_path, 1_000);
    defer first.release(io);

    // Second acquire must time out within 200 ms while the first is held.
    try testing.expectError(
        error.Timeout,
        malt.lock.LockFile.acquire(io, lock_path, 200),
    );
}
