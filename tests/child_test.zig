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
