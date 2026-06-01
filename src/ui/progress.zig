//! malt — progress module
//! Terminal progress bar rendering with multi-line support.
//!
//! Every stderr write in this file is best-effort: a draw failure must not
//! abort the work the bar is reporting on (download, install, migration).
//! Each print group assembles its bytes in a stack buffer and hits stderr
//! once so EPIPE surfaces at a single catch site instead of corrupting
//! mid-chain output.

const std = @import("std");
/// Process-wide io and stderr sink seeded once from `main` via
/// `setRuntime`. `pkg_stderr` defaults to fd `-1` so unconfigured tests
/// silently drop progress writes; `pkg_io` defaults to `debug_io`.
var pkg_io: std.Io = std.Options.debug_io;
const builtin = @import("builtin");

const color = @import("color.zig");
const output = @import("output.zig");

var pkg_stderr: std.Io.File = .{ .handle = -1, .flags = .{ .nonblocking = false } };

/// Selects how long-running mutators report progress. Resolved once at
/// process start from `MALT_PROGRESS` (and the CI auto-detection); every
/// bar/spinner reads this same value so install/upgrade/migrate behave
/// identically.
pub const ProgressMode = enum { tty, plain, none };

/// Default matches today's auto-detected TTY bar; `setMode` flips it
/// after `main` reads the env.
var pkg_mode: ProgressMode = .tty;

pub fn setRuntime(io: std.Io, stderr: std.Io.File) void {
    pkg_io = io;
    pkg_stderr = stderr;
}

pub fn setMode(m: ProgressMode) void {
    pkg_mode = m;
}

pub fn mode() ProgressMode {
    return pkg_mode;
}

/// Pure resolver — explicit `MALT_PROGRESS` value (or null), plus a
/// caller-computed `ci` boolean. Keeps env probing out so the table
/// stays unit-testable. The wire vocabulary matches `ProgressMode`'s
/// variant names by design, so `stringToEnum` is the single source of
/// truth — a new variant means no parser update.
pub fn resolveMode(explicit: ?[]const u8, ci: bool) ProgressMode {
    if (explicit) |v| {
        if (std.meta.stringToEnum(ProgressMode, v)) |m| return m;
        // Unknown value: fall through to the CI-aware default rather
        // than aborting — the env knob is opt-in convenience.
    }
    return if (ci) .plain else .tty;
}

/// Convenience wrapper: read `MALT_PROGRESS` / `CI` / `GITHUB_ACTIONS`
/// from the supplied environ and apply `resolveMode`. An empty value
/// (`CI=`) is treated as unset — matches the `[ -n "$CI" ]` convention
/// shell-based CI detection uses everywhere else.
pub fn resolveModeFromEnviron(environ: std.process.Environ) ProgressMode {
    const explicit: ?[]const u8 = std.process.Environ.getPosix(environ, "MALT_PROGRESS");
    const ci_set = envFlagSet(environ, "CI") or envFlagSet(environ, "GITHUB_ACTIONS");
    return resolveMode(explicit, ci_set);
}

fn envFlagSet(environ: std.process.Environ, name: []const u8) bool {
    const v = std.process.Environ.getPosix(environ, name) orelse return false;
    return v.len > 0;
}

/// Test-only override for the TTY probe so the `mode + TTY` ANSI gate
/// can be exercised without a real terminal. Pass `null` to release.
var supports_ansi_override: ?bool = null;

pub fn setSupportsAnsiForTest(v: ?bool) void {
    if (!builtin.is_test) return;
    supports_ansi_override = v;
}

fn supportsAnsi() bool {
    if (builtin.is_test) {
        if (supports_ansi_override) |v| return v;
    }
    return pkg_stderr.supportsAnsiEscapeCodes(pkg_io) catch false;
}

/// Test-only stderr capture mirror of `output.beginStderrCapture` —
/// tests run sequentially in a binary, so a single non-locked slot is
/// safe. Elided from release via `builtin.is_test`.
var capture_list: ?*std.ArrayList(u8) = null;
var capture_allocator: std.mem.Allocator = undefined;

pub fn beginStderrCapture(allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) void {
    if (!builtin.is_test) return;
    capture_list = buf;
    capture_allocator = allocator;
}

pub fn endStderrCapture() void {
    if (!builtin.is_test) return;
    capture_list = null;
}

fn writeStderrAll(bytes: []const u8) void {
    if (builtin.is_test) {
        if (capture_list) |list| {
            list.appendSlice(capture_allocator, bytes) catch {};
            return;
        }
    }
    pkg_stderr.writeStreamingAll(pkg_io, bytes) catch {};
}

fn nowMs() i64 {
    return std.Io.Clock.real.now(pkg_io).toMilliseconds();
}

fn nowNs() i128 {
    return std.Io.Clock.real.now(pkg_io).toNanoseconds();
}

/// Sleeps for `ns` nanoseconds against the package io. Returns false when
/// a cancellation request reached the io subsystem before the sleep
/// finished, so spin/poll callers can bail rather than swallow the signal.
fn sleepNs(ns: u64) bool {
    std.Io.sleep(pkg_io, std.Io.Duration.fromNanoseconds(@intCast(ns)), .awake) catch |e| switch (e) {
        error.Canceled => return false,
    };
    return true;
}

/// Braille-based spinner frames, shared by ProgressBar and Spinner.
const spinner_chars = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

/// Single-line plain-mode event: `<label>: <status>\n`. No colour, no
/// glyph, no rate-limited redraws — one byte stream that survives `tee`
/// and CI log scrapers without `term_sanitize` having to fight it.
/// Routed through `output.writeStderrAll` so the same mutex that
/// serialises info/warn/etc. lines also serialises plain progress
/// events when parallel workers finish their bars concurrently.
fn writePlainLine(label: []const u8, status: []const u8) void {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}: {s}\n", .{ label, status }) catch return;
    if (builtin.is_test) {
        if (capture_list) |list| {
            list.appendSlice(capture_allocator, line) catch {};
            return;
        }
    }
    output.writeStderrAll(line);
}

/// Best-effort restore of terminal state mutated by `MultiProgress.init`
/// or `Spinner.start`: re-enable autowrap, show the cursor, return to
/// column 0. Safe to call from a panic / signal handler — the bytes are
/// idempotent, and writes silently drop when stderr is unconfigured.
pub fn restoreTerminal() void {
    writeStderrAll("\x1b[?7h\x1b[?25h\r");
}

/// Coordinates multiple progress bars on separate terminal lines.
/// Reserves N lines upfront, then uses ANSI cursor movement so each
/// bar updates its own line without interfering with others.
pub const MultiProgress = struct {
    total_lines: u16,
    mutex: std.Io.Mutex,
    is_tty: bool,

    pub fn init(count: u16) MultiProgress {
        // `is_tty` here means "TTY-mode bar is active": the rendering
        // gate folds terminal capability and `MALT_PROGRESS` together so
        // plain/none never leaks DECSET/cursor-hide bytes into CI logs.
        const tty = supportsAnsi() and pkg_mode == .tty;

        // Hide cursor, disable autowrap, reserve lines by printing empty placeholders.
        // Autowrap disabled so an over-width bar clips instead of wrapping —
        // wrapping would break the ESC[NA cursor-up math each bar relies on.
        if (tty and !output.isQuiet()) {
            // 11-byte prefix; newlines emitted in 256-byte chunks so a u16-max
            // line count doesn't blow the stack frame.
            writeStderrAll("\x1b[?25l\x1b[?7l");
            const newline_chunk: [256]u8 = @splat('\n');
            var remaining: u16 = count;
            while (remaining > 0) {
                const n = @min(remaining, newline_chunk.len);
                writeStderrAll(newline_chunk[0..n]);
                remaining -= n;
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
            restoreTerminal();
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
    line_index: u16,
    /// Shared multi-progress state (null for standalone bars).
    multi: ?*MultiProgress,
    /// Plain-mode latches: one "starting" / one "done" line per bar, no
    /// matter how many `update` calls come from the worker.
    plain_started: bool,
    plain_finished: bool,

    const render_interval_ns: i128 = 100 * std.time.ns_per_ms; // 10 Hz max
    const bar_width: u64 = 30;

    pub fn init(label: []const u8, total: u64) ProgressBar {
        return .{
            .label = label,
            .total = total,
            .current = 0,
            .last_render_ns = 0,
            .start_time_ms = nowMs(),
            .spinner_frame = 0,
            .is_tty = supportsAnsi(),
            .label_width = 0,
            .line_index = 0,
            .multi = null,
            .plain_started = false,
            .plain_finished = false,
        };
    }

    pub fn update(self: *ProgressBar, current: u64) void {
        self.current = current;
        if (output.isQuiet()) return;
        switch (pkg_mode) {
            .none => return,
            .plain => self.emitPlainStart(),
            .tty => {
                if (!self.is_tty) return;
                const now = nowNs();
                if (now - self.last_render_ns < render_interval_ns) return;
                self.last_render_ns = now;
                self.render();
            },
        }
    }

    pub fn finish(self: *ProgressBar) void {
        if (output.isQuiet()) return;
        switch (pkg_mode) {
            .none => return,
            .plain => self.emitPlainDone(),
            .tty => {
                if (!self.is_tty) return;
                if (self.total > 0) {
                    self.current = self.total;
                }
                // Every bar belongs to a group that reserves its row up
                // front (`SingleBar` for the one-bar case), so the final
                // frame is an in-place redraw — no trailing newline.
                self.render();
            },
        }
    }

    fn emitPlainStart(self: *ProgressBar) void {
        if (self.plain_started) return;
        self.plain_started = true;
        writePlainLine(self.label, "starting");
    }

    fn emitPlainDone(self: *ProgressBar) void {
        if (self.plain_finished) return;
        self.plain_finished = true;
        writePlainLine(self.label, "done");
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
        const now_ms = nowMs();
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
            const c = if (done) color.SemanticStyle.success.code() else color.SemanticStyle.info.code();
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

        // Label — clip to leave headroom for label_width padding, the
        // trailing space, and the bar/percent/details/erase/cursor that the
        // caller appends next. Mirrors the Spinner.drawFrame clamp pattern.
        const tail_reserve: usize = 320;
        const remaining = if (buf.len > pos + tail_reserve) buf.len - pos - tail_reserve else 0;
        const label_len = @min(self.label.len, remaining);
        @memcpy(buf[pos .. pos + label_len], self.label[0..label_len]);
        pos += label_len;

        if (self.label_width > 0 and label_len < self.label_width) {
            const desired_pad: usize = self.label_width - label_len;
            const pad_room: usize = if (buf.len > pos + 1) buf.len - pos - 1 else 0;
            const pad = @min(desired_pad, pad_room);
            @memset(buf[pos .. pos + pad], ' ');
            pos += pad;
        }

        buf[pos] = ' ';
        pos += 1;

        return pos;
    }

    /// Write ANSI escape to move cursor up `n` lines.
    fn writeCursorUp(buf: []u8, pos: usize, n: u16) usize {
        if (n == 0) return pos;
        const seq = std.fmt.bufPrint(buf[pos..], "\x1b[{d}A", .{n}) catch return pos;
        return pos + seq.len;
    }

    /// Write ANSI escape to move cursor down `n` lines.
    fn writeCursorDown(buf: []u8, pos: usize, n: u16) usize {
        if (n == 0) return pos;
        const seq = std.fmt.bufPrint(buf[pos..], "\x1b[{d}B", .{n}) catch return pos;
        return pos + seq.len;
    }

    fn renderDeterminate(self: *const ProgressBar) void {
        const pct: u64 = if (self.total > 0) @min((self.current * 100) / self.total, 100) else 0;
        const filled: u64 = if (self.total > 0) @min((self.current * bar_width) / self.total, bar_width) else 0;
        const empty = bar_width - filled;

        // Lock mutex if part of a MultiProgress group
        if (self.multi) |mp| mp.mutex.lockUncancelable(pkg_io);
        defer if (self.multi) |mp| mp.mutex.unlock(pkg_io);

        var buf: [768]u8 = undefined;
        var pos: usize = 0;

        // For multi-progress: move cursor up to our line
        const move_up: u16 = if (self.multi) |mp| mp.total_lines - self.line_index else 0;
        pos = writeCursorUp(&buf, pos, move_up);

        // Carriage return
        buf[pos] = '\r';
        pos += 1;

        // Prefix + aligned label
        pos = self.writeLabel(&buf, pos);

        // Bar
        if (color.isColorEnabled()) {
            const cyan_code = color.SemanticStyle.info.code();
            const dim_code = color.SemanticStyle.detail.code();
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
        const dim_code = if (use_color) color.SemanticStyle.detail.code() else "";
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

        writeStderrAll(buf[0..pos]);
    }

    fn renderIndeterminate(self: *const ProgressBar) void {
        if (self.multi) |mp| mp.mutex.lockUncancelable(pkg_io);
        defer if (self.multi) |mp| mp.mutex.unlock(pkg_io);

        var buf: [512]u8 = undefined;
        var pos: usize = 0;

        const move_up: u16 = if (self.multi) |mp| mp.total_lines - self.line_index else 0;
        pos = writeCursorUp(&buf, pos, move_up);

        buf[pos] = '\r';
        pos += 1;

        // writeLabel already renders the animated spinner as the line glyph.
        pos = self.writeLabel(&buf, pos);

        const use_color = color.isColorEnabled();
        const dim_code = if (use_color) color.SemanticStyle.detail.code() else "";
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

        writeStderrAll(buf[0..pos]);
    }
};

/// A single download bar rendered as a group of one. Standalone callers
/// (single-package install, cask, single-keg migrate, upgrade) used to
/// hand-roll a setup-free `ProgressBar`, which never disabled autowrap —
/// so an over-width bar line wrapped and every redraw stacked a fresh row.
/// Routing them through `MultiProgress.init(1)` reuses the same
/// autowrap-off + cursor-hide + line-reservation + restore guarantees the
/// multi-package path already had, killing the divergence and the bug.
///
/// Self-referential: `bar.multi` points back into this struct, so it must
/// be pinned at its final address before use — `init` then `bind`.
pub const SingleBar = struct {
    multi: MultiProgress,
    bar: ProgressBar,

    pub fn init(label: []const u8, total: u64) SingleBar {
        return .{
            .multi = MultiProgress.init(1),
            .bar = ProgressBar.init(label, total),
        };
    }

    /// Attach the bar to its one-line group and hand back a stable pointer.
    /// Call once, after the struct is at its final stack address.
    pub fn bind(self: *SingleBar) *ProgressBar {
        self.bar.multi = &self.multi;
        self.bar.line_index = 0;
        return &self.bar;
    }

    /// Restore terminal state (autowrap, cursor). The bar's final frame is
    /// rendered by the caller's `bar.finish()`; this only tears down the
    /// group, mirroring `defer multi.finish()` on the multi-package path.
    pub fn finish(self: *SingleBar) void {
        self.multi.finish();
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
        return .{
            .message = message,
            .stop_flag = std.atomic.Value(bool).init(false),
            .thread = null,
            .is_tty = supportsAnsi(),
            .active = false,
        };
    }

    pub fn start(self: *Spinner) void {
        if (output.isQuiet()) return;

        if (!self.is_tty) {
            self.writeFallbackLine();
            return;
        }

        writeStderrAll("\x1b[?25l"); // hide cursor
        self.active = true;
        self.thread = std.Thread.spawn(.{}, spinLoop, .{self}) catch blk: {
            // Thread spawn failed: restore cursor and emit the static fallback line.
            self.active = false;
            writeStderrAll("\x1b[?25h");
            self.writeFallbackLine();
            break :blk null;
        };
    }

    /// Assemble one dim info line ("<detail>pfx message<reset>\n") in a
    /// stack buffer and write it once so EPIPE surfaces at a single site.
    fn writeFallbackLine(self: *const Spinner) void {
        var buf: [512]u8 = undefined;
        var pos: usize = 0;
        const use_color = color.isColorEnabled();

        if (use_color) {
            const detail = color.SemanticStyle.detail.code();
            @memcpy(buf[pos .. pos + detail.len], detail);
            pos += detail.len;
        }
        const pfx: []const u8 = if (color.isEmojiEnabled()) "  \xe2\x96\xb8 " else "  > ";
        @memcpy(buf[pos .. pos + pfx.len], pfx);
        pos += pfx.len;
        const reset_len = if (use_color) color.Style.reset.code().len else 0;
        const msg_len = @min(self.message.len, buf.len - pos - reset_len - 1);
        @memcpy(buf[pos .. pos + msg_len], self.message[0..msg_len]);
        pos += msg_len;
        if (use_color) {
            const reset_code = color.Style.reset.code();
            @memcpy(buf[pos .. pos + reset_code.len], reset_code);
            pos += reset_code.len;
        }
        buf[pos] = '\n';
        pos += 1;

        writeStderrAll(buf[0..pos]);
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
        // \r → col 0, ESC[K → clear line, ESC[?25h → show cursor
        writeStderrAll("\r\x1b[K\x1b[?25h");
        self.active = false;
    }

    fn spinLoop(self: *Spinner) void {
        var frame: u8 = 0;
        while (!self.stop_flag.load(.acquire)) {
            self.drawFrame(frame);
            frame +%= 1;
            if (!sleepNs(100 * std.time.ns_per_ms)) break;
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

        // Info-coloured spinner glyph.
        if (use_color) {
            const c = color.SemanticStyle.info.code();
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
            const d = color.SemanticStyle.detail.code();
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

        writeStderrAll(buf[0..pos]);
    }
};

test "MultiProgress accepts a line count beyond u8 without truncation" {
    output.setQuiet(true);
    defer output.setQuiet(false);

    const big: u16 = 300;
    var mp = MultiProgress.init(big);
    defer mp.finish();
    try std.testing.expectEqual(big, mp.total_lines);
}

test "ProgressBar.line_index past u8 round-trips through MultiProgress render" {
    output.setQuiet(true);
    defer output.setQuiet(false);

    var mp = MultiProgress.init(400);
    defer mp.finish();
    mp.is_tty = true;

    var bar = ProgressBar.init("late", 100);
    bar.is_tty = true;
    bar.multi = &mp;
    bar.line_index = 350; // would silently wrap to 94 under u8
    bar.update(50);
    bar.finish();

    try std.testing.expectEqual(@as(u16, 350), bar.line_index);
}

test "ProgressBar render survives label larger than the draw buffer" {
    // Long custom-tap labels must clip, not panic the @memcpy bound check
    // in safe builds (buf is 768 determinate / 512 indeterminate).
    const label: [600]u8 = @splat('x');

    var det = ProgressBar.init(&label, 100);
    det.is_tty = true;
    det.update(50);
    det.finish();

    var indet = ProgressBar.init(&label, 0);
    indet.is_tty = true;
    indet.update(0);
}

test "restoreTerminal is callable without an active MultiProgress" {
    // Panic / signal handlers may emit the restore sequence without ever
    // having paired it to an init: the call must be allocation-free,
    // re-entrant, and idempotent.
    restoreTerminal();
    restoreTerminal();
}

// Patches an inner Io's vtable so `sleep` reports cancellation on the
// configured call index; non-canceled sleeps return immediately so the
// 100 ms spinner cadence doesn't pad the test runtime.
const CancelSleepProbe = struct {
    var vtable: std.Io.VTable = undefined;
    var sleep_calls: usize = 0;
    var cancel_at: usize = 1;

    fn wrap(inner: std.Io, cancel_at_call: usize) std.Io {
        vtable = inner.vtable.*;
        vtable.sleep = sleepMaybeCanceled;
        sleep_calls = 0;
        cancel_at = cancel_at_call;
        return .{ .userdata = inner.userdata, .vtable = &vtable };
    }

    fn sleepMaybeCanceled(_: ?*anyopaque, _: std.Io.Timeout) std.Io.Cancelable!void {
        sleep_calls += 1;
        if (sleep_calls >= cancel_at) return error.Canceled;
    }
};

test "sleepNs returns true when the sleep completes normally" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const prev_io = pkg_io;
    pkg_io = threaded.io();
    defer pkg_io = prev_io;

    try std.testing.expect(sleepNs(0));
}

test "sleepNs returns false when sleep is cancelled" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const prev_io = pkg_io;
    pkg_io = CancelSleepProbe.wrap(threaded.io(), 1);
    defer pkg_io = prev_io;

    try std.testing.expect(!sleepNs(100));
    try std.testing.expectEqual(@as(usize, 1), CancelSleepProbe.sleep_calls);
}

test "sleepNs propagates cancellation when called repeatedly" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const prev_io = pkg_io;
    pkg_io = CancelSleepProbe.wrap(threaded.io(), 3);
    defer pkg_io = prev_io;

    // Two normal sleeps complete and report true; the third trips Canceled,
    // pinning that the helper isn't latched after the first non-cancelled
    // return and matches the spin-loop's per-tick break contract.
    try std.testing.expect(sleepNs(0));
    try std.testing.expect(sleepNs(0));
    try std.testing.expect(!sleepNs(0));
    try std.testing.expectEqual(@as(usize, 3), CancelSleepProbe.sleep_calls);
}

// `MALT_PROGRESS` contract: explicit env wins over CI auto-detect, an
// unrecognised value silently falls back to the CI-aware default. Pinning
// the full table keeps install/upgrade/migrate behaviour consistent.
test "resolveMode defaults to tty when nothing is set" {
    try std.testing.expectEqual(ProgressMode.tty, resolveMode(null, false));
}

test "resolveMode flips to plain when CI is detected" {
    try std.testing.expectEqual(ProgressMode.plain, resolveMode(null, true));
}

test "resolveMode honours explicit MALT_PROGRESS values" {
    try std.testing.expectEqual(ProgressMode.tty, resolveMode("tty", false));
    try std.testing.expectEqual(ProgressMode.plain, resolveMode("plain", false));
    try std.testing.expectEqual(ProgressMode.none, resolveMode("none", false));
}

test "resolveMode explicit value wins over CI detection" {
    try std.testing.expectEqual(ProgressMode.tty, resolveMode("tty", true));
    try std.testing.expectEqual(ProgressMode.none, resolveMode("none", true));
}

test "resolveMode falls back to the CI-aware default on unknown values" {
    try std.testing.expectEqual(ProgressMode.tty, resolveMode("bogus", false));
    try std.testing.expectEqual(ProgressMode.plain, resolveMode("bogus", true));
}

// Mode-aware ProgressBar behaviour: `.none` must not write a single byte
// of progress (TTY render included), `.plain` must emit one line per
// state transition with no escape sequences so CI logs stay readable.
test "ProgressBar in none mode writes no progress bytes" {
    const prior_mode = mode();
    setMode(.none);
    defer setMode(prior_mode);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    beginStderrCapture(std.testing.allocator, &buf);
    defer endStderrCapture();

    var bar = ProgressBar.init("tree", 1000);
    bar.is_tty = true; // force TTY render branch — must still be suppressed
    bar.update(0);
    bar.update(500);
    bar.finish();

    try std.testing.expectEqualStrings("", buf.items);
}

test "ProgressBar in plain mode emits one starting and one done line" {
    const prior_mode = mode();
    setMode(.plain);
    defer setMode(prior_mode);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    beginStderrCapture(std.testing.allocator, &buf);
    defer endStderrCapture();

    var bar = ProgressBar.init("tree", 1000);
    bar.update(0);
    bar.update(500); // intermediate updates do not spam new lines
    bar.finish();

    try std.testing.expectEqualStrings("tree: starting\ntree: done\n", buf.items);
}

test "MultiProgress in plain mode emits no ANSI setup sequences" {
    const prior_mode = mode();
    setMode(.plain);
    defer setMode(prior_mode);
    setSupportsAnsiForTest(true);
    defer setSupportsAnsiForTest(null);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    beginStderrCapture(std.testing.allocator, &buf);
    defer endStderrCapture();

    var mp = MultiProgress.init(3);
    mp.finish();

    try std.testing.expectEqualStrings("", buf.items);
}

// --quiet predates MALT_PROGRESS and stays the one knob that silences
// success messages too — `MALT_PROGRESS=plain` must not punch through it.
test "ProgressBar quiet trumps plain mode" {
    const prior_mode = mode();
    const prior_quiet = output.isQuiet();
    setMode(.plain);
    output.setQuiet(true);
    defer {
        setMode(prior_mode);
        output.setQuiet(prior_quiet);
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    beginStderrCapture(std.testing.allocator, &buf);
    defer endStderrCapture();

    var bar = ProgressBar.init("tree", 1000);
    bar.update(0);
    bar.finish();

    try std.testing.expectEqualStrings("", buf.items);
}

// Pins the env-name wiring (MALT_PROGRESS / CI / GITHUB_ACTIONS) so a
// future rename can't silently break the CI-friendly default.
test "resolveModeFromEnviron flips to plain when CI=true is set" {
    var buf: [64:0]u8 = undefined;
    const env_value = std.fmt.bufPrintZ(&buf, "CI=true", .{}) catch unreachable;
    const slice: [:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{env_value.ptr};
    const environ: std.process.Environ = .{ .block = .{ .slice = slice } };

    try std.testing.expectEqual(ProgressMode.plain, resolveModeFromEnviron(environ));
}

test "resolveModeFromEnviron honours an explicit MALT_PROGRESS=none even with CI=true" {
    var ci_buf: [64:0]u8 = undefined;
    var prog_buf: [64:0]u8 = undefined;
    const ci_value = std.fmt.bufPrintZ(&ci_buf, "CI=true", .{}) catch unreachable;
    const prog_value = std.fmt.bufPrintZ(&prog_buf, "MALT_PROGRESS=none", .{}) catch unreachable;
    const slice: [:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{ ci_value.ptr, prog_value.ptr };
    const environ: std.process.Environ = .{ .block = .{ .slice = slice } };

    try std.testing.expectEqual(ProgressMode.none, resolveModeFromEnviron(environ));
}

test "resolveModeFromEnviron flips to plain on GITHUB_ACTIONS=true" {
    var buf: [64:0]u8 = undefined;
    const v = std.fmt.bufPrintZ(&buf, "GITHUB_ACTIONS=true", .{}) catch unreachable;
    const slice: [:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{v.ptr};
    const environ: std.process.Environ = .{ .block = .{ .slice = slice } };

    try std.testing.expectEqual(ProgressMode.plain, resolveModeFromEnviron(environ));
}

test "resolveModeFromEnviron returns tty on an empty environ" {
    const environ: std.process.Environ = .empty;
    try std.testing.expectEqual(ProgressMode.tty, resolveModeFromEnviron(environ));
}

// `CI=` (empty value) is shorthand for "no CI" in shell scripts —
// pin that convention so a `CI=` parent override doesn't surprise
// users into the plain bar.
test "resolveModeFromEnviron treats empty CI value as unset" {
    var buf: [16:0]u8 = undefined;
    const v = std.fmt.bufPrintZ(&buf, "CI=", .{}) catch unreachable;
    const slice: [:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{v.ptr};
    const environ: std.process.Environ = .{ .block = .{ .slice = slice } };

    try std.testing.expectEqual(ProgressMode.tty, resolveModeFromEnviron(environ));
}

test "MultiProgress in none mode emits no ANSI setup sequences" {
    const prior_mode = mode();
    setMode(.none);
    defer setMode(prior_mode);
    setSupportsAnsiForTest(true);
    defer setSupportsAnsiForTest(null);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    beginStderrCapture(std.testing.allocator, &buf);
    defer endStderrCapture();

    var mp = MultiProgress.init(2);
    mp.finish();

    try std.testing.expectEqualStrings("", buf.items);
}

// MultiProgress on a real TTY with the default mode must still emit the
// DECSET/cursor-hide prelude — pins the positive case so the mode gate
// can't silently regress the existing bar.
test "MultiProgress in tty mode on a TTY emits the cursor-hide prelude" {
    const prior_mode = mode();
    setMode(.tty);
    defer setMode(prior_mode);
    setSupportsAnsiForTest(true);
    defer setSupportsAnsiForTest(null);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    beginStderrCapture(std.testing.allocator, &buf);
    defer endStderrCapture();

    var mp = MultiProgress.init(2);
    mp.finish();

    // Prelude + 2 reserved newlines + restore-on-finish (autowrap on,
    // cursor on, carriage return).
    try std.testing.expectEqualStrings("\x1b[?25l\x1b[?7l\n\n\x1b[?7h\x1b[?25h\r", buf.items);
}

// The single-bar entry point must inherit the same terminal setup as the
// multi-package path — a "group of one". Pinning the autowrap-disable
// prelude here is the regression guard: a future change that drops back to
// a setup-free standalone bar (the divergence that let over-width upgrade
// bars wrap and stack) fails this test.
test "SingleBar in tty mode emits the autowrap-disable prelude" {
    const prior_mode = mode();
    setMode(.tty);
    defer setMode(prior_mode);
    setSupportsAnsiForTest(true);
    defer setSupportsAnsiForTest(null);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    beginStderrCapture(std.testing.allocator, &buf);
    defer endStderrCapture();

    var sp = SingleBar.init("tree", 0);
    sp.finish();

    // Prelude + 1 reserved newline + restore-on-finish.
    try std.testing.expectEqualStrings("\x1b[?25l\x1b[?7l\n\x1b[?7h\x1b[?25h\r", buf.items);
}

// The unified single-bar path redraws in place via cursor moves; the only
// newline in its output is the one reserved row from MultiProgress(1).
// A per-tick or trailing `\n` would re-introduce the standalone bar's
// "stack a fresh row per redraw" symptom.
test "SingleBar renders one logical line with no stray newline" {
    const prior_mode = mode();
    setMode(.tty);
    defer setMode(prior_mode);
    setSupportsAnsiForTest(true);
    defer setSupportsAnsiForTest(null);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    beginStderrCapture(std.testing.allocator, &buf);
    defer endStderrCapture();

    var sp = SingleBar.init("tree", 100);
    const bar = sp.bind();
    bar.update(50);
    bar.finish();
    sp.finish();

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, buf.items, "\n"));
}

// Regression guard for AC3: routing the single-bar case through a group
// must not leak DECSET/cursor-hide setup into CI logs. In plain mode the
// bar still emits its one starting / one done line and nothing else.
test "SingleBar in plain mode emits plain lines and no ANSI setup" {
    const prior_mode = mode();
    setMode(.plain);
    defer setMode(prior_mode);
    setSupportsAnsiForTest(true);
    defer setSupportsAnsiForTest(null);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    beginStderrCapture(std.testing.allocator, &buf);
    defer endStderrCapture();

    var sp = SingleBar.init("tree", 1000);
    const bar = sp.bind();
    bar.update(0);
    bar.update(500); // intermediate updates do not spam new lines
    bar.finish();
    sp.finish();

    try std.testing.expectEqualStrings("tree: starting\ntree: done\n", buf.items);
}

// Regression guard for AC3: none mode through the single-bar primitive
// writes zero bytes, even with the TTY render branch forced.
test "SingleBar in none mode writes no bytes" {
    const prior_mode = mode();
    setMode(.none);
    defer setMode(prior_mode);
    setSupportsAnsiForTest(true);
    defer setSupportsAnsiForTest(null);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    beginStderrCapture(std.testing.allocator, &buf);
    defer endStderrCapture();

    var sp = SingleBar.init("tree", 1000);
    const bar = sp.bind();
    bar.update(500);
    bar.finish();
    sp.finish();

    try std.testing.expectEqualStrings("", buf.items);
}

// A standalone bar that's `finish`-ed without any prior `update` still
// needs to emit a `done` line in plain mode — `migrate` short-circuits
// on a manifest hit before the first byte is downloaded but the bar
// already exists, and CI logs should still see the row close.
test "ProgressBar in plain mode emits done even without a prior update" {
    const prior_mode = mode();
    setMode(.plain);
    defer setMode(prior_mode);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    beginStderrCapture(std.testing.allocator, &buf);
    defer endStderrCapture();

    var bar = ProgressBar.init("yazi", 0);
    bar.finish();

    try std.testing.expectEqualStrings("yazi: done\n", buf.items);
}

// Quiet must trump `.none` too: with both set, the early-return at the
// top of update/finish takes precedence over the mode switch. Pins the
// `output.isQuiet()` short-circuit so a refactor can't drop it without
// breaking a test.
test "ProgressBar quiet trumps none mode" {
    const prior_mode = mode();
    const prior_quiet = output.isQuiet();
    setMode(.none);
    output.setQuiet(true);
    defer {
        setMode(prior_mode);
        output.setQuiet(prior_quiet);
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    beginStderrCapture(std.testing.allocator, &buf);
    defer endStderrCapture();

    var bar = ProgressBar.init("tree", 1000);
    bar.is_tty = true;
    bar.update(0);
    bar.finish();

    try std.testing.expectEqualStrings("", buf.items);
}
