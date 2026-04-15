//! malt — progress module
//! Terminal progress bar rendering with multi-line support.

const std = @import("std");
const fs_compat = @import("../fs/compat.zig");
const io_mod = @import("io.zig");

const color = @import("color.zig");
const output = @import("output.zig");

/// Braille-based spinner frames, shared by ProgressBar and Spinner.
const spinner_chars = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

/// Coordinates multiple progress bars on separate terminal lines.
/// Reserves N lines upfront, then uses ANSI cursor movement so each
/// bar updates its own line without interfering with others.
pub const MultiProgress = struct {
    total_lines: u8,
    mutex: std.Io.Mutex,
    is_tty: bool,

    pub fn init(count: u8) MultiProgress {
        const stderr = fs_compat.stderrFile();
        const tty = stderr.supportsAnsiEscapeCodes();

        // Hide cursor, disable autowrap, reserve lines by printing empty placeholders.
        // Autowrap is disabled so that if a bar row exceeds the terminal width, the
        // overflow is clipped at the right edge instead of flowing onto a second
        // visual line — wrapping would break the ESC[NA cursor-up math that each
        // bar uses to update its dedicated line.
        if (tty and !output.isQuiet()) {
            stderr.writeAll("\x1b[?25l") catch {}; // hide cursor
            stderr.writeAll("\x1b[?7l") catch {}; // disable autowrap
            var i: u8 = 0;
            while (i < count) : (i += 1) {
                stderr.writeAll("\n") catch {};
            }
        }

        return .{
            .total_lines = count,
            .mutex = .init,
            .is_tty = tty,
        };
    }

    /// Restore cursor, autowrap, and reset to column 0 after all bars are done.
    /// Must be called after all download threads have joined.
    pub fn finish(self: *MultiProgress) void {
        if (self.is_tty and !output.isQuiet()) {
            const stderr = fs_compat.stderrFile();
            stderr.writeAll("\x1b[?7h") catch {}; // re-enable autowrap
            stderr.writeAll("\x1b[?25h\r") catch {}; // show cursor + column 0
        }
    }
};

pub const ProgressBar = struct {
    label: []const u8,
    total: u64,
    current: u64,
    last_render_ns: i128,
    start_time_ms: i64,
    spinner_frame: u8,
    is_tty: bool,
    /// Minimum label column width for alignment across multiple bars.
    label_width: u8,
    /// Line index within a MultiProgress group (0 = topmost bar).
    line_index: u8,
    /// Shared multi-progress state (null for standalone bars).
    multi: ?*MultiProgress,

    const render_interval_ns: i128 = 100 * std.time.ns_per_ms; // 10 Hz max
    const bar_width: u64 = 30;

    pub fn init(label: []const u8, total: u64) ProgressBar {
        const stderr = fs_compat.stderrFile();
        return .{
            .label = label,
            .total = total,
            .current = 0,
            .last_render_ns = 0,
            .start_time_ms = fs_compat.milliTimestamp(),
            .spinner_frame = 0,
            .is_tty = stderr.supportsAnsiEscapeCodes(),
            .label_width = 0,
            .line_index = 0,
            .multi = null,
        };
    }

    pub fn update(self: *ProgressBar, current: u64) void {
        self.current = current;
        if (output.isQuiet() or !self.is_tty) return;

        const now = fs_compat.nanoTimestamp();
        if (now - self.last_render_ns < render_interval_ns) return;
        self.last_render_ns = now;

        self.render();
    }

    pub fn finish(self: *ProgressBar) void {
        if (output.isQuiet() or !self.is_tty) return;
        if (self.total > 0) {
            self.current = self.total;
        }
        self.render();
        // For standalone bars (no multi), emit a newline
        if (self.multi == null) {
            fs_compat.stderrFile().writeAll("\n") catch {};
        }
    }

    fn render(self: *ProgressBar) void {
        // Advance the animation frame on every render tick. Both determinate
        // and indeterminate bars use this to animate the spinner glyph in
        // front of the label.
        self.spinner_frame +%= 1;

        if (self.total > 0) {
            self.renderDeterminate();
        } else {
            self.renderIndeterminate();
        }
    }

    /// Return the glyph shown in front of the label: a spinner frame while
    /// work is in progress, or a checkmark once the bar has reached 100%.
    /// The spinner uses Braille Pattern chars (not emoji); only the done
    /// glyph has an ASCII fallback to match `output.success()` in no-emoji mode.
    fn glyph(self: *const ProgressBar) []const u8 {
        const done = self.total > 0 and self.current >= self.total;
        if (done) {
            return if (color.isEmojiEnabled()) "\xe2\x9c\x93" else "*"; // ✓
        }
        return spinner_chars[self.spinner_frame % spinner_chars.len];
    }

    fn computeRate(self: *const ProgressBar) f64 {
        const now_ms = fs_compat.milliTimestamp();
        const elapsed_ms = now_ms - self.start_time_ms;
        if (elapsed_ms <= 0) return 0;
        return @as(f64, @floatFromInt(self.current)) / (@as(f64, @floatFromInt(elapsed_ms)) / 1000.0);
    }

    pub fn formatRate(buf: []u8, rate: f64) []const u8 {
        if (rate <= 0) return "--";
        const rate_kb = rate / 1024.0;
        if (rate_kb >= 1024.0) {
            return std.fmt.bufPrint(buf, "{d:.1} MB/s", .{rate_kb / 1024.0}) catch return "--";
        }
        return std.fmt.bufPrint(buf, "{d:.0} KB/s", .{rate_kb}) catch return "--";
    }

    pub fn formatEta(buf: []u8, remaining_bytes: u64, rate: f64) []const u8 {
        if (rate <= 0) return "";
        const eta_secs: u64 = @intFromFloat(@as(f64, @floatFromInt(remaining_bytes)) / rate);
        if (eta_secs > 3600) return "";
        if (eta_secs >= 60) {
            return std.fmt.bufPrint(buf, "ETA {d}m{d:0>2}s", .{ eta_secs / 60, eta_secs % 60 }) catch return "";
        }
        return std.fmt.bufPrint(buf, "ETA {d}s", .{eta_secs}) catch return "";
    }

    fn writeLabel(self: *const ProgressBar, buf: []u8, start_pos: usize) usize {
        var pos = start_pos;

        // "  " indent to align with output.info() style
        buf[pos] = ' ';
        pos += 1;
        buf[pos] = ' ';
        pos += 1;

        // Glyph: animated spinner while in progress, green ✓ when done.
        const done = self.total > 0 and self.current >= self.total;
        const use_color = color.isColorEnabled();
        const g = self.glyph();

        if (use_color) {
            const c = if (done) color.Style.green.code() else color.Style.cyan.code();
            @memcpy(buf[pos .. pos + c.len], c);
            pos += c.len;
        }
        @memcpy(buf[pos .. pos + g.len], g);
        pos += g.len;
        if (use_color) {
            const reset_code = color.Style.reset.code();
            @memcpy(buf[pos .. pos + reset_code.len], reset_code);
            pos += reset_code.len;
        }
        buf[pos] = ' ';
        pos += 1;

        // Label
        const label_len = self.label.len;
        @memcpy(buf[pos .. pos + label_len], self.label);
        pos += label_len;

        if (self.label_width > 0 and label_len < self.label_width) {
            const pad = self.label_width - @as(u8, @intCast(@min(label_len, 255)));
            @memset(buf[pos .. pos + pad], ' ');
            pos += pad;
        }

        buf[pos] = ' ';
        pos += 1;

        return pos;
    }

    /// Write ANSI escape to move cursor up `n` lines.
    fn writeCursorUp(buf: []u8, pos: usize, n: u8) usize {
        if (n == 0) return pos;
        const seq = std.fmt.bufPrint(buf[pos..], "\x1b[{d}A", .{n}) catch return pos;
        return pos + seq.len;
    }

    /// Write ANSI escape to move cursor down `n` lines.
    fn writeCursorDown(buf: []u8, pos: usize, n: u8) usize {
        if (n == 0) return pos;
        const seq = std.fmt.bufPrint(buf[pos..], "\x1b[{d}B", .{n}) catch return pos;
        return pos + seq.len;
    }

    fn renderDeterminate(self: *const ProgressBar) void {
        const f = fs_compat.stderrFile();
        const pct: u64 = if (self.total > 0) @min((self.current * 100) / self.total, 100) else 0;
        const filled: u64 = if (self.total > 0) @min((self.current * bar_width) / self.total, bar_width) else 0;
        const empty = bar_width - filled;

        // Lock mutex if part of a MultiProgress group
        if (self.multi) |mp| mp.mutex.lockUncancelable(io_mod.ctx());
        defer if (self.multi) |mp| mp.mutex.unlock(io_mod.ctx());

        var buf: [768]u8 = undefined;
        var pos: usize = 0;

        // For multi-progress: move cursor up to our line
        const move_up: u8 = if (self.multi) |mp| mp.total_lines - self.line_index else 0;
        pos = writeCursorUp(&buf, pos, move_up);

        // Carriage return
        buf[pos] = '\r';
        pos += 1;

        // Prefix + aligned label
        pos = self.writeLabel(&buf, pos);

        // Bar
        if (color.isColorEnabled()) {
            const cyan_code = color.Style.cyan.code();
            const dim_code = color.Style.dim.code();
            const reset_code = color.Style.reset.code();

            @memcpy(buf[pos .. pos + cyan_code.len], cyan_code);
            pos += cyan_code.len;

            var i: u64 = 0;
            while (i < filled) : (i += 1) {
                const ch = "\xe2\x94\x81"; // ━
                @memcpy(buf[pos .. pos + 3], ch);
                pos += 3;
            }

            @memcpy(buf[pos .. pos + reset_code.len], reset_code);
            pos += reset_code.len;

            @memcpy(buf[pos .. pos + dim_code.len], dim_code);
            pos += dim_code.len;

            i = 0;
            while (i < empty) : (i += 1) {
                const ch = "\xe2\x94\x80"; // ─
                @memcpy(buf[pos .. pos + 3], ch);
                pos += 3;
            }

            @memcpy(buf[pos .. pos + reset_code.len], reset_code);
            pos += reset_code.len;
        } else {
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

        // Percentage (outside parens, normal color)
        const pct_part = std.fmt.bufPrint(buf[pos..], " {d: >3}%", .{pct}) catch "";
        pos += pct_part.len;

        // Details in dim color: (64/64 KB | 42 KB/s | ETA 2s)
        const use_color = color.isColorEnabled();
        const dim_code = if (use_color) color.Style.dim.code() else "";
        const reset_code2 = if (use_color) color.Style.reset.code() else "";

        @memcpy(buf[pos .. pos + dim_code.len], dim_code);
        pos += dim_code.len;

        const open = std.fmt.bufPrint(buf[pos..], " (", .{}) catch "";
        pos += open.len;

        const size_kb = self.current / 1024;
        const total_kb = self.total / 1024;
        const size_part = if (total_kb > 1024)
            std.fmt.bufPrint(buf[pos..], "{d:.1}/{d:.1} MB", .{
                @as(f64, @floatFromInt(size_kb)) / 1024.0,
                @as(f64, @floatFromInt(total_kb)) / 1024.0,
            }) catch ""
        else
            std.fmt.bufPrint(buf[pos..], "{d}/{d} KB", .{ size_kb, total_kb }) catch "";
        pos += size_part.len;

        const rate = self.computeRate();
        var rate_buf: [32]u8 = undefined;
        const rate_str = formatRate(&rate_buf, rate);
        if (self.current > 0) {
            const rate_part = std.fmt.bufPrint(buf[pos..], " | {s}", .{rate_str}) catch "";
            pos += rate_part.len;
        }

        if (self.total > 0 and self.current < self.total and rate > 0) {
            var eta_buf: [32]u8 = undefined;
            const eta_str = formatEta(&eta_buf, self.total - self.current, rate);
            if (eta_str.len > 0) {
                const eta_part = std.fmt.bufPrint(buf[pos..], " | {s}", .{eta_str}) catch "";
                pos += eta_part.len;
            }
        }

        buf[pos] = ')';
        pos += 1;
        @memcpy(buf[pos .. pos + reset_code2.len], reset_code2);
        pos += reset_code2.len;

        // Erase from cursor to end of line. This clears any leftover chars
        // from a previously longer render (e.g. "ETA 10m03s" → "ETA 5s") and,
        // crucially, keeps the visible row narrow so it doesn't wrap on
        // standard-width terminals — wrap would break the cursor-up math.
        const erase = "\x1b[K";
        @memcpy(buf[pos .. pos + erase.len], erase);
        pos += erase.len;

        // For multi-progress: move cursor back down and reset to column 0
        pos = writeCursorDown(&buf, pos, move_up);
        if (move_up > 0) {
            buf[pos] = '\r';
            pos += 1;
        }

        f.writeAll(buf[0..pos]) catch {};
    }

    fn renderIndeterminate(self: *const ProgressBar) void {
        const f = fs_compat.stderrFile();

        if (self.multi) |mp| mp.mutex.lockUncancelable(io_mod.ctx());
        defer if (self.multi) |mp| mp.mutex.unlock(io_mod.ctx());

        var buf: [512]u8 = undefined;
        var pos: usize = 0;

        const move_up: u8 = if (self.multi) |mp| mp.total_lines - self.line_index else 0;
        pos = writeCursorUp(&buf, pos, move_up);

        buf[pos] = '\r';
        pos += 1;

        // writeLabel already renders the animated spinner as the line glyph.
        pos = self.writeLabel(&buf, pos);

        const use_color = color.isColorEnabled();
        const dim_code = if (use_color) color.Style.dim.code() else "";
        const reset_code = if (use_color) color.Style.reset.code() else "";

        @memcpy(buf[pos .. pos + dim_code.len], dim_code);
        pos += dim_code.len;
        buf[pos] = '(';
        pos += 1;

        const size_kb = self.current / 1024;
        const rate = self.computeRate();
        var rate_buf: [32]u8 = undefined;
        const rate_str = formatRate(&rate_buf, rate);

        const info = if (size_kb > 1024)
            std.fmt.bufPrint(buf[pos..], "{d:.1} MB | {s}", .{
                @as(f64, @floatFromInt(size_kb)) / 1024.0,
                rate_str,
            }) catch ""
        else
            std.fmt.bufPrint(buf[pos..], "{d} KB | {s}", .{ size_kb, rate_str }) catch "";
        pos += info.len;

        buf[pos] = ')';
        pos += 1;
        @memcpy(buf[pos .. pos + reset_code.len], reset_code);
        pos += reset_code.len;

        // Erase to end of line (see renderDeterminate for rationale).
        const erase = "\x1b[K";
        @memcpy(buf[pos .. pos + erase.len], erase);
        pos += erase.len;

        pos = writeCursorDown(&buf, pos, move_up);
        if (move_up > 0) {
            buf[pos] = '\r';
            pos += 1;
        }

        f.writeAll(buf[0..pos]) catch {};
    }
};

/// Single-line animated spinner for blocking operations.
///
/// Unlike ProgressBar, the Spinner owns a background thread that redraws the
/// current frame at 10 Hz while the caller does synchronous work. Typical use:
///
///     var s = Spinner.init("Materializing ansible to cellar...");
///     s.start();
///     // ... long synchronous work ...
///     s.stop();
///     output.success("ansible installed", .{});
///
/// On non-TTY or quiet mode, `start()` falls back to a single info-style
/// line and `stop()` is a no-op, so callers don't need to special-case.
pub const Spinner = struct {
    message: []const u8,
    stop_flag: std.atomic.Value(bool),
    thread: ?std.Thread,
    is_tty: bool,
    active: bool,

    pub fn init(message: []const u8) Spinner {
        const stderr = fs_compat.stderrFile();
        return .{
            .message = message,
            .stop_flag = std.atomic.Value(bool).init(false),
            .thread = null,
            .is_tty = stderr.supportsAnsiEscapeCodes(),
            .active = false,
        };
    }

    pub fn start(self: *Spinner) void {
        if (output.isQuiet()) return;

        if (!self.is_tty) {
            // Non-TTY: emit a single dim info line and return. No animation.
            const f = fs_compat.stderrFile();
            const pfx: []const u8 = if (color.isEmojiEnabled()) "  \xe2\x96\xb8 " else "  > ";
            if (color.isColorEnabled()) f.writeAll(color.Style.dim.code()) catch {};
            f.writeAll(pfx) catch {};
            f.writeAll(self.message) catch {};
            if (color.isColorEnabled()) f.writeAll(color.Style.reset.code()) catch {};
            f.writeAll("\n") catch {};
            return;
        }

        const f = fs_compat.stderrFile();
        f.writeAll("\x1b[?25l") catch {}; // hide cursor
        self.active = true;
        self.thread = std.Thread.spawn(.{}, spinLoop, .{self}) catch blk: {
            // Thread spawn failed: fall back to a single static line.
            self.active = false;
            f.writeAll("\x1b[?25h") catch {};
            const pfx: []const u8 = if (color.isEmojiEnabled()) "  \xe2\x96\xb8 " else "  > ";
            if (color.isColorEnabled()) f.writeAll(color.Style.dim.code()) catch {};
            f.writeAll(pfx) catch {};
            f.writeAll(self.message) catch {};
            if (color.isColorEnabled()) f.writeAll(color.Style.reset.code()) catch {};
            f.writeAll("\n") catch {};
            break :blk null;
        };
    }

    /// Signal the background thread to exit, join it, then clear the line
    /// and restore the cursor. Safe to call even if `start()` took the
    /// non-TTY fallback path.
    pub fn stop(self: *Spinner) void {
        if (!self.active) return;
        self.stop_flag.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        const f = fs_compat.stderrFile();
        // \r → col 0, ESC[K → clear line, ESC[?25h → show cursor
        f.writeAll("\r\x1b[K\x1b[?25h") catch {};
        self.active = false;
    }

    fn spinLoop(self: *Spinner) void {
        var frame: u8 = 0;
        while (!self.stop_flag.load(.acquire)) {
            self.drawFrame(frame);
            frame +%= 1;
            fs_compat.sleepNanos(100 * std.time.ns_per_ms);
        }
    }

    fn drawFrame(self: *const Spinner, frame: u8) void {
        var buf: [512]u8 = undefined;
        var pos: usize = 0;

        // \r to col 0
        buf[pos] = '\r';
        pos += 1;

        // "  " indent matching output.info style
        buf[pos] = ' ';
        pos += 1;
        buf[pos] = ' ';
        pos += 1;

        const use_color = color.isColorEnabled();

        // Cyan spinner glyph
        if (use_color) {
            const c = color.Style.cyan.code();
            @memcpy(buf[pos .. pos + c.len], c);
            pos += c.len;
        }
        const g = spinner_chars[frame % spinner_chars.len];
        @memcpy(buf[pos .. pos + g.len], g);
        pos += g.len;
        if (use_color) {
            const r = color.Style.reset.code();
            @memcpy(buf[pos .. pos + r.len], r);
            pos += r.len;
        }
        buf[pos] = ' ';
        pos += 1;

        // Dim message text
        if (use_color) {
            const d = color.Style.dim.code();
            @memcpy(buf[pos .. pos + d.len], d);
            pos += d.len;
        }
        const msg_len = @min(self.message.len, buf.len - pos - 16);
        @memcpy(buf[pos .. pos + msg_len], self.message[0..msg_len]);
        pos += msg_len;
        if (use_color) {
            const r = color.Style.reset.code();
            @memcpy(buf[pos .. pos + r.len], r);
            pos += r.len;
        }

        // Erase to end of line
        const erase = "\x1b[K";
        @memcpy(buf[pos .. pos + erase.len], erase);
        pos += erase.len;

        const f = fs_compat.stderrFile();
        f.writeAll(buf[0..pos]) catch {};
    }
};
