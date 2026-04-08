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
    const bar_width: u64 = 30;

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
        const f = std.fs.File.stderr();
        const pct: u64 = if (self.total > 0) @min((self.current * 100) / self.total, 100) else 0;
        const filled: u64 = if (self.total > 0) @min((self.current * bar_width) / self.total, bar_width) else 0;
        const empty = bar_width - filled;

        var buf: [512]u8 = undefined;
        var pos: usize = 0;

        // Carriage return to overwrite line
        buf[pos] = '\r';
        pos += 1;

        // Label
        const label_part = std.fmt.bufPrint(buf[pos..], "  {s} ", .{self.label}) catch return;
        pos += label_part.len;

        // Bar: ████████░░░░░░
        // Use colored output if available
        if (color.isColorEnabled()) {
            const cyan_code = color.Style.cyan.code();
            const dim_code = color.Style.dim.code();
            const reset_code = color.Style.reset.code();

            @memcpy(buf[pos .. pos + cyan_code.len], cyan_code);
            pos += cyan_code.len;

            // Filled portion: solid blocks
            var i: u64 = 0;
            while (i < filled) : (i += 1) {
                // "━" is 3 bytes in UTF-8
                const ch = "\xe2\x94\x81"; // ━
                @memcpy(buf[pos .. pos + 3], ch);
                pos += 3;
            }

            @memcpy(buf[pos .. pos + reset_code.len], reset_code);
            pos += reset_code.len;

            @memcpy(buf[pos .. pos + dim_code.len], dim_code);
            pos += dim_code.len;

            // Empty portion: thin line
            i = 0;
            while (i < empty) : (i += 1) {
                const ch = "\xe2\x94\x80"; // ─
                @memcpy(buf[pos .. pos + 3], ch);
                pos += 3;
            }

            @memcpy(buf[pos .. pos + reset_code.len], reset_code);
            pos += reset_code.len;
        } else {
            // No color: ASCII fallback
            var i: u64 = 0;
            while (i < filled) : (i += 1) {
                buf[pos] = '=';
                pos += 1;
            }
            i = 0;
            while (i < empty) : (i += 1) {
                buf[pos] = ' ';
                pos += 1;
            }
        }

        // Percentage + size
        const size_kb = self.current / 1024;
        const total_kb = self.total / 1024;
        const suffix = if (total_kb > 1024)
            std.fmt.bufPrint(buf[pos..], " {d: >3}% {d:.1}/{d:.1} MB", .{
                pct,
                @as(f64, @floatFromInt(size_kb)) / 1024.0,
                @as(f64, @floatFromInt(total_kb)) / 1024.0,
            }) catch return
        else
            std.fmt.bufPrint(buf[pos..], " {d: >3}% {d}/{d} KB", .{ pct, size_kb, total_kb }) catch return;
        pos += suffix.len;

        f.writeAll(buf[0..pos]) catch {};
    }
};
