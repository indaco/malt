//! malt — child module tests
//! Capture-and-replay contract for `core/child.zig`: success is silent,
//! failure replays the child's own stdout+stderr. Lives here because
//! the dual-stream driver argv embeds `/bin/sh -c`, which the
//! argv-only spawn invariant (tests/spawn_invariant_test.zig) bans
//! anywhere under `src/`.

const std = @import("std");
const malt = @import("malt");
const child = malt.child;

test "run captures the child's stderr and surfaces a non-zero exit code" {
    // Guards the "quiet on success, verbose on failure" contract.
    // The point: a subprocess whose stderr is noisy on the success path
    // (hdiutil, ditto, …) must not leak that noise into the user's
    // terminal — runOrFail() now consumes it. On failure the captured
    // bytes are the only diagnostic the user gets, so they must survive
    // intact through the wait+collect.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const argv = [_][]const u8{ "/bin/sh", "-c", "echo OUT; echo ERR-MSG >&2; exit 7" };
    var report = try child.run(threaded.io(), std.testing.allocator, &argv);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 7), report.code);
    try std.testing.expect(std.mem.indexOf(u8, report.stderr, "ERR-MSG") != null);
    try std.testing.expect(std.mem.indexOf(u8, report.stdout, "OUT") != null);
}

test "run on a successful child still returns the captured stdout" {
    // Belt-and-suspenders: even though runOrFail drops these on success,
    // the underlying `run` must expose what was emitted so we can wire
    // it into richer diagnostics later without rebuilding the seam.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const argv = [_][]const u8{ "/bin/sh", "-c", "echo silent-but-recorded" };
    var report = try child.run(threaded.io(), std.testing.allocator, &argv);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), report.code);
    try std.testing.expect(std.mem.indexOf(u8, report.stdout, "silent-but-recorded") != null);
}

test "run drains a stream that overflows the pipe buffer while the other stays open" {
    // Two-pipe deadlock guard: a child that floods one stream past the
    // kernel pipe buffer (~64 KiB on Darwin) blocks in write until that
    // pipe is read. Draining the streams sequentially never reads the
    // flooded one until the child exits, but the child cannot exit until
    // it is drained — so run must drain both concurrently. 200000 bytes
    // to stderr (well past one buffer) with stdout held open until exit.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const argv = [_][]const u8{ "/bin/sh", "-c", "yes | head -c 200000 1>&2" };
    var report = try child.run(threaded.io(), std.testing.allocator, &argv);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), report.code);
    try std.testing.expectEqual(@as(usize, 200000), report.stderr.len);
    try std.testing.expectEqual(@as(usize, 0), report.stdout.len);
}

test "run truncates an over-cap stream to the cap without hanging" {
    // A stream larger than the 256 KiB capture cap plus a pipe buffer would
    // deadlock if the drain stopped reading at the cap while the child kept
    // writing. The drain must keep consuming past the cap to EOF, retaining
    // only the first 256 KiB. 400000 bytes to stderr exceeds cap + buffer.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const argv = [_][]const u8{ "/bin/sh", "-c", "yes | head -c 400000 1>&2" };
    var report = try child.run(threaded.io(), std.testing.allocator, &argv);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), report.code);
    try std.testing.expectEqual(@as(usize, 256 * 1024), report.stderr.len);
    try std.testing.expectEqual(@as(usize, 0), report.stdout.len);
}
