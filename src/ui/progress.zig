//! malt — progress module
//! Terminal progress bar rendering.

const std = @import("std");
const output = @import("output.zig");
const color = @import("color.zig");

pub const ProgressBar = struct {
    label: []const u8,
    total: u64,
    current: u64,
    last_render_ns: i128,

    const render_interval_ns: i128 = 100 * std.time.ns_per_ms; // 10 Hz max

    pub fn init(label: []const u8, total: u64) ProgressBar {
        return .{
            .label = label,
            .total = total,
            .current = 0,
            .last_render_ns = 0,
        };
    }

    pub fn update(self: *ProgressBar, current: u64) void {
        self.current = current;
        if (output.isQuiet()) return;

        const now = std.time.nanoTimestamp();
        if (now - self.last_render_ns < render_interval_ns) return;
        self.last_render_ns = now;
        self.render();
    }

    pub fn finish(self: *ProgressBar) void {
        if (output.isQuiet()) return;
        self.current = self.total;
        self.render();
        std.fs.File.stderr().writeAll("\n") catch {};
    }

    fn render(self: *const ProgressBar) void {
        const pct: u64 = if (self.total > 0) (self.current * 100) / self.total else 0;
        const filled: u64 = if (self.total > 0) (self.current * 20) / self.total else 0;

        var buf: [256]u8 = undefined;
        var pos: usize = 0;

        // Carriage return
        buf[pos] = '\r';
        pos += 1;

        // Format the label part
        const label_part = std.fmt.bufPrint(buf[pos..], "==> {s}... ", .{self.label}) catch return;
        pos += label_part.len;

        // Bar
        for (0..20) |i| {
            if (i < filled) {
                buf[pos] = '#';
            } else {
                buf[pos] = '-';
            }
            pos += 1;
        }
        buf[pos] = ' ';
        pos += 1;

        // Percentage and size
        const size_mb = @as(f64, @floatFromInt(self.current)) / (1024.0 * 1024.0);
        const suffix = std.fmt.bufPrint(buf[pos..], "{d}% {d:.1} MB", .{ pct, size_mb }) catch return;
        pos += suffix.len;

        std.fs.File.stderr().writeAll(buf[0..pos]) catch {};
    }
};
