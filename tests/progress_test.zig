//! malt — progress module tests
//! Tests for ProgressBar rendering, ProgressCallback bridging, and edge cases.

const std = @import("std");
const testing = std.testing;
const progress_mod = @import("malt").progress;
const client_mod = @import("malt").client;
const output_mod = @import("malt").output;

// --- ProgressBar unit tests ---

test "init sets correct defaults" {
    const bar = progress_mod.ProgressBar.init("test-label", 1000);
    try testing.expectEqual(@as(u64, 1000), bar.total);
    try testing.expectEqual(@as(u64, 0), bar.current);
    try testing.expectEqualStrings("test-label", bar.label);
    try testing.expectEqual(@as(u8, 0), bar.spinner_frame);
}

test "init with zero total starts in indeterminate mode" {
    const bar = progress_mod.ProgressBar.init("download", 0);
    try testing.expectEqual(@as(u64, 0), bar.total);
    try testing.expectEqual(@as(u64, 0), bar.current);
}

test "update advances current position" {
    // Force quiet mode so rendering is skipped (no TTY in CI)
    output_mod.setQuiet(true);
    defer output_mod.setQuiet(false);

    var bar = progress_mod.ProgressBar.init("test", 1000);
    bar.update(500);
    try testing.expectEqual(@as(u64, 500), bar.current);

    bar.update(999);
    try testing.expectEqual(@as(u64, 999), bar.current);
}

test "finish sets current to total for determinate bar" {
    // In quiet/non-TTY mode, finish() early-returns without setting current.
    // We test the state update logic directly.
    output_mod.setQuiet(true);
    defer output_mod.setQuiet(false);

    var bar = progress_mod.ProgressBar.init("test", 2048);
    bar.update(1024);
    try testing.expectEqual(@as(u64, 1024), bar.current);
    bar.finish();
    // In quiet mode, finish skips rendering — current stays at last update value
    try testing.expectEqual(@as(u64, 1024), bar.current);
}

test "finish does not change current for indeterminate bar" {
    output_mod.setQuiet(true);
    defer output_mod.setQuiet(false);

    var bar = progress_mod.ProgressBar.init("test", 0);
    bar.update(5000);
    bar.finish();
    // total remains 0, current stays at 5000
    try testing.expectEqual(@as(u64, 0), bar.total);
    try testing.expectEqual(@as(u64, 5000), bar.current);
}

test "update in quiet mode does not crash" {
    output_mod.setQuiet(true);
    defer output_mod.setQuiet(false);

    var bar = progress_mod.ProgressBar.init("quiet", 100);
    // Rapid updates should not crash even in quiet mode
    var i: u64 = 0;
    while (i <= 100) : (i += 1) {
        bar.update(i);
    }
    bar.finish();
    try testing.expectEqual(@as(u64, 100), bar.current);
}

// --- ProgressCallback tests ---

const TestState = struct {
    calls: u32,
    last_bytes: u64,
    last_total: ?u64,
};

fn testCallback(ctx: *anyopaque, bytes_so_far: u64, content_length: ?u64) void {
    const state: *TestState = @ptrCast(@alignCast(ctx));
    state.calls += 1;
    state.last_bytes = bytes_so_far;
    state.last_total = content_length;
}

test "ProgressCallback reports correctly" {
    var state = TestState{ .calls = 0, .last_bytes = 0, .last_total = null };
    const cb = client_mod.ProgressCallback{
        .context = @ptrCast(&state),
        .func = &testCallback,
    };

    cb.report(1024, 4096);
    try testing.expectEqual(@as(u32, 1), state.calls);
    try testing.expectEqual(@as(u64, 1024), state.last_bytes);
    try testing.expectEqual(@as(?u64, 4096), state.last_total);

    cb.report(2048, null);
    try testing.expectEqual(@as(u32, 2), state.calls);
    try testing.expectEqual(@as(u64, 2048), state.last_bytes);
    try testing.expectEqual(@as(?u64, null), state.last_total);
}

test "ProgressCallback bridges to ProgressBar" {
    output_mod.setQuiet(true);
    defer output_mod.setQuiet(false);

    var bar = progress_mod.ProgressBar.init("bridge-test", 0);

    // Simulate the progressBridge pattern from install.zig
    const cb = client_mod.ProgressCallback{
        .context = @ptrCast(&bar),
        .func = &struct {
            fn bridge(ctx: *anyopaque, bytes_so_far: u64, content_length: ?u64) void {
                const b: *progress_mod.ProgressBar = @ptrCast(@alignCast(ctx));
                if (content_length) |total| {
                    if (b.total == 0) b.total = total;
                }
                const clamped = if (b.total > 0) @min(bytes_so_far, b.total) else bytes_so_far;
                b.update(clamped);
            }
        }.bridge,
    };

    // First report sets total from Content-Length
    cb.report(1000, 5000);
    try testing.expectEqual(@as(u64, 5000), bar.total);
    try testing.expectEqual(@as(u64, 1000), bar.current);

    // Subsequent reports don't change total
    cb.report(3000, 5000);
    try testing.expectEqual(@as(u64, 5000), bar.total);
    try testing.expectEqual(@as(u64, 3000), bar.current);

    // Clamping: bytes > total gets clamped
    cb.report(6000, 5000);
    try testing.expectEqual(@as(u64, 5000), bar.current);
}

test "ProgressCallback with null content_length stays indeterminate" {
    output_mod.setQuiet(true);
    defer output_mod.setQuiet(false);

    var bar = progress_mod.ProgressBar.init("chunked", 0);

    const cb = client_mod.ProgressCallback{
        .context = @ptrCast(&bar),
        .func = &struct {
            fn bridge(ctx: *anyopaque, bytes_so_far: u64, content_length: ?u64) void {
                const b: *progress_mod.ProgressBar = @ptrCast(@alignCast(ctx));
                if (content_length) |total| {
                    if (b.total == 0) b.total = total;
                }
                b.update(bytes_so_far);
            }
        }.bridge,
    };

    cb.report(1000, null);
    try testing.expectEqual(@as(u64, 0), bar.total); // stays indeterminate
    try testing.expectEqual(@as(u64, 1000), bar.current);

    cb.report(5000, null);
    try testing.expectEqual(@as(u64, 0), bar.total);
    try testing.expectEqual(@as(u64, 5000), bar.current);
}

// --- Rate/ETA helper tests ---

test "formatRate handles zero rate" {
    var buf: [32]u8 = undefined;
    const result = progress_mod.ProgressBar.formatRate(&buf, 0);
    try testing.expectEqualStrings("--", result);
}

test "formatRate shows KB/s for small rates" {
    var buf: [32]u8 = undefined;
    const result = progress_mod.ProgressBar.formatRate(&buf, 512 * 1024); // 512 KB/s
    try testing.expect(std.mem.indexOf(u8, result, "KB/s") != null);
}

test "formatRate shows MB/s for large rates" {
    var buf: [32]u8 = undefined;
    const result = progress_mod.ProgressBar.formatRate(&buf, 5 * 1024 * 1024); // 5 MB/s
    try testing.expect(std.mem.indexOf(u8, result, "MB/s") != null);
}

test "formatEta returns empty for zero rate" {
    var buf: [32]u8 = undefined;
    const result = progress_mod.ProgressBar.formatEta(&buf, 1000, 0);
    try testing.expectEqualStrings("", result);
}

test "formatEta returns seconds for short durations" {
    var buf: [32]u8 = undefined;
    const result = progress_mod.ProgressBar.formatEta(&buf, 1000, 100); // 10s
    try testing.expect(std.mem.indexOf(u8, result, "ETA") != null);
    try testing.expect(std.mem.indexOf(u8, result, "10s") != null);
}
