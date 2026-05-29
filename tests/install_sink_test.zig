//! malt — install OutputSink integration tests.
//! Proves `installAll` routes per-keg human output through the injected
//! sink instead of the global `ui/output`, so a non-terminal consumer (the
//! bundle runner) can quiet emission while the structured failure path —
//! the error returned to the caller — stays intact.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;

const install = malt.install;
const install_record = malt.install_record;
const install_sink = malt.install_sink;
const output = malt.output;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

/// Counts the human lines a sink receives so a test can assert routing
/// went through `ctx` and never touched the global stderr.
const RecordingSink = struct {
    infos: usize = 0,
    warns: usize = 0,
    successes: usize = 0,
    errs: usize = 0,

    fn writeInfo(ctx: ?*anyopaque, _: []const u8) void {
        cast(ctx).infos += 1;
    }
    fn writeWarn(ctx: ?*anyopaque, _: []const u8) void {
        cast(ctx).warns += 1;
    }
    fn writeSuccess(ctx: ?*anyopaque, _: []const u8) void {
        cast(ctx).successes += 1;
    }
    fn writeErr(ctx: ?*anyopaque, _: []const u8) void {
        cast(ctx).errs += 1;
    }
    fn cast(ctx: ?*anyopaque) *RecordingSink {
        return @ptrCast(@alignCast(ctx));
    }

    fn sink(self: *RecordingSink) install_sink.OutputSink {
        return .{
            .ctx = self,
            .writeInfo = writeInfo,
            .writeWarn = writeWarn,
            .writeSuccess = writeSuccess,
            .writeErr = writeErr,
            .show_progress = false,
        };
    }
};

test "installAll routes the per-keg failure line through the injected sink" {
    const prefix_z: [:0]const u8 = "/tmp/malt_install_sink_route";
    test_io.deleteTreeAbsolute(std.Options.debug_io, prefix_z) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix_z);
    _ = c.setenv("MALT_PREFIX", prefix_z.ptr, 1);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix_z) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    // Capture the global stderr so a leaked direct `output.*` write fails
    // the test rather than going unnoticed.
    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &out_buf);
    defer output.endStderrCapture();

    var rec: RecordingSink = .{};
    try testing.expectError(
        install_record.InstallError.PartialFailure,
        install.installAll(&ctx, arena.allocator(), &.{"zz_nonexistent_formula_xyz"}, .{ .sink = rec.sink() }),
    );

    // The unresolvable keg's error line is the structured "this keg failed"
    // surface bundle relies on — it must reach the sink, not the global.
    try testing.expect(rec.errs >= 1);
    try testing.expectEqual(@as(usize, 0), out_buf.items.len);
}

/// Run `installAll` for one unresolvable package under `sink`, capturing
/// the global stderr. Returns the captured bytes (caller frees) and the
/// install result so each test asserts its own contract.
fn runUnresolvable(
    sink: install_sink.OutputSink,
    suffix: []const u8,
    out_buf: *std.ArrayList(u8),
) anyerror!void {
    const prefix = try std.fmt.allocPrintSentinel(testing.allocator, "/tmp/malt_install_sink_{s}", .{suffix}, 0);
    defer testing.allocator.free(prefix);
    test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);
    _ = c.setenv("MALT_PREFIX", prefix.ptr, 1);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    output.beginStderrCapture(testing.allocator, out_buf);
    defer output.endStderrCapture();

    try testing.expectError(
        install_record.InstallError.PartialFailure,
        install.installAll(&ctx, arena.allocator(), &.{"zz_nonexistent_formula_xyz"}, .{ .sink = sink }),
    );
}

test "default sink routes the failure line to ui/output" {
    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(testing.allocator);
    // No sink supplied → InstallAllOpts defaults to the terminal sink, so
    // the per-keg error must land on the global stderr exactly as today.
    try runUnresolvable(install_sink.terminal, "default", &out_buf);
    try testing.expect(std.mem.indexOf(u8, out_buf.items, "zz_nonexistent_formula_xyz") != null);
}

test "silent sink quiets the failure line but the install still fails" {
    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(testing.allocator);
    // Bundle's sink: nothing reaches the global channel, yet the
    // PartialFailure return (which feeds the runner's Report) is unchanged.
    try runUnresolvable(install_sink.silent, "silent", &out_buf);
    try testing.expectEqual(@as(usize, 0), out_buf.items.len);
}
