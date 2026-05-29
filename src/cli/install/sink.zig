//! malt — install output sink.
//!
//! Injected emission seam for the install pipeline. The bundle runner's
//! `Dispatcher` calls `installAll`, but the global `ui/output` quiet/mode
//! flags are set once before workers spawn and must not be flipped at
//! runtime — so a non-terminal consumer cannot quiet per-keg output by
//! toggling the global. A sink threaded through `InstallAllOpts` lets it.
//!
//! Mirrors `core/bundle/runner.zig`'s `Dispatcher`: `ctx` + runtime
//! function pointers, so a future headless consumer injects its own sink
//! rather than picking from a closed mode enum. The built-in `terminal`
//! sink forwards to `ui/output` (behaviour identical to today); `silent`
//! swallows the human lines so bundle's structured `Report` is the only
//! channel. ndjson events and `--dry-run`/`--json` queries stay on the
//! global on purpose — they are an always-on machine channel and run
//! configuration, not suppressible human output.

const std = @import("std");

const output = @import("../../ui/output.zig");

pub const OutputSink = struct {
    ctx: ?*anyopaque = null,
    writeInfo: *const fn (ctx: ?*anyopaque, msg: []const u8) void,
    writeWarn: *const fn (ctx: ?*anyopaque, msg: []const u8) void,
    writeSuccess: *const fn (ctx: ?*anyopaque, msg: []const u8) void,
    writeErr: *const fn (ctx: ?*anyopaque, msg: []const u8) void,
    /// Whether long-running steps render progress bars. Bars also self-gate
    /// on the global progress mode, but bundle can't flip that mid-run, so
    /// the silent sink clears this and the construction sites skip the bar.
    show_progress: bool = true,

    /// Comptime format wrappers mirror `output.emitPrefixLine`'s 4096-byte
    /// `bufPrint` so an over-long message is dropped identically to today;
    /// the rendered bytes then dispatch through the runtime vtable.
    pub fn info(self: *const OutputSink, comptime fmt: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.writeInfo(self.ctx, msg);
    }
    pub fn warn(self: *const OutputSink, comptime fmt: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.writeWarn(self.ctx, msg);
    }
    pub fn success(self: *const OutputSink, comptime fmt: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.writeSuccess(self.ctx, msg);
    }
    pub fn err(self: *const OutputSink, comptime fmt: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.writeErr(self.ctx, msg);
    }
};

// `"{s}"` re-format keeps `output`'s prefix/colour/quiet handling intact;
// the message bytes are identical regardless of the formatting round-trip.
fn termInfo(_: ?*anyopaque, msg: []const u8) void {
    output.info("{s}", .{msg});
}
fn termWarn(_: ?*anyopaque, msg: []const u8) void {
    output.warn("{s}", .{msg});
}
fn termSuccess(_: ?*anyopaque, msg: []const u8) void {
    output.success("{s}", .{msg});
}
fn termErr(_: ?*anyopaque, msg: []const u8) void {
    output.err("{s}", .{msg});
}

fn swallow(_: ?*anyopaque, _: []const u8) void {}

/// Default sink: behaviour identical to calling `ui/output.*` directly.
pub const terminal: OutputSink = .{
    .writeInfo = termInfo,
    .writeWarn = termWarn,
    .writeSuccess = termSuccess,
    .writeErr = termErr,
    .show_progress = true,
};

/// Non-terminal sink: human lines are dropped so a structured consumer
/// (the bundle runner's `Report`) owns reporting. ndjson still flows.
pub const silent: OutputSink = .{
    .writeInfo = swallow,
    .writeWarn = swallow,
    .writeSuccess = swallow,
    .writeErr = swallow,
    .show_progress = false,
};

test "terminal sink forwards human lines to ui/output" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    output.beginStderrCapture(std.testing.allocator, &buf);
    defer output.endStderrCapture();

    terminal.info("hello {d}", .{7});
    terminal.err("boom", .{});

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "hello 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "boom") != null);
}

test "silent sink swallows every human line" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    output.beginStderrCapture(std.testing.allocator, &buf);
    defer output.endStderrCapture();

    silent.info("x", .{});
    silent.warn("y", .{});
    silent.success("z", .{});
    silent.err("w", .{});

    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "silent sink disables progress; terminal enables it" {
    try std.testing.expect(terminal.show_progress);
    try std.testing.expect(!silent.show_progress);
}

const RecordingSink = struct {
    infos: usize = 0,
    errs: usize = 0,

    fn writeInfo(ctx: ?*anyopaque, _: []const u8) void {
        const self: *RecordingSink = @ptrCast(@alignCast(ctx));
        self.infos += 1;
    }
    fn writeErr(ctx: ?*anyopaque, _: []const u8) void {
        const self: *RecordingSink = @ptrCast(@alignCast(ctx));
        self.errs += 1;
    }
    fn writeNoop(_: ?*anyopaque, _: []const u8) void {}

    fn sink(self: *RecordingSink) OutputSink {
        return .{
            .ctx = self,
            .writeInfo = writeInfo,
            .writeWarn = writeNoop,
            .writeSuccess = writeNoop,
            .writeErr = writeErr,
        };
    }
};

test "injected sink routes through ctx, not the global output" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    output.beginStderrCapture(std.testing.allocator, &buf);
    defer output.endStderrCapture();

    var rec: RecordingSink = .{};
    const s = rec.sink();
    s.info("a", .{});
    s.info("b", .{});
    s.err("c", .{});

    try std.testing.expectEqual(@as(usize, 2), rec.infos);
    try std.testing.expectEqual(@as(usize, 1), rec.errs);
    // A custom sink must not leak onto the global stderr channel.
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}
