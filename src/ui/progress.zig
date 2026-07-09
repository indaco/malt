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
const termsize = @import("termsize.zig");
const term_restore = @import("term_restore.zig");
const spinner_frames = @import("spinner_frames.zig");

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
/// When the TUI registered a raw terminal, its crash restore (alt-screen
/// leave + `tcsetattr`) runs first, so a panic message lands on a readable
/// cooked screen instead of trapping inside the alt buffer.
pub fn restoreTerminal() void {
    term_restore.crashRestore();
    writeStderrAll("\x1b[?7h\x1b[?25h\r");
}

/// Widest the download bar ever draws — keeps the happy-path line
/// byte-identical to the historical fixed bar; only narrow terminals shrink.
const bar_cap: u16 = 30;
/// Narrowest usable stub bar on a cramped terminal.
const bar_floor: u16 = 4;

/// Columns the line spends on everything but the bar: indent (2) + glyph and
/// its trailing space (2) + label + a space (1) + percent (5) + a nominal
/// detail readout (~40). The bar gets whatever is left.
fn barOverhead(label_width: u8) u16 {
    return 2 + 2 + @as(u16, label_width) + 1 + 5 + 40;
}

/// Cells the bar may occupy at terminal width `cols`. Clamped to
/// `[bar_floor, bar_cap]` so a wide terminal is byte-identical to the old
/// fixed bar and a narrow one shrinks smoothly without ever dipping below the
/// floor.
fn barCells(cols: u16, label_width: u8) u16 {
    const overhead = barOverhead(label_width);
    if (cols < overhead + bar_floor) return bar_floor;
    return @min(bar_cap, cols - overhead);
}

/// How a bar draws at a given width: a sized bar, or — when the terminal is
/// too narrow for even a floor bar beside the detail — a bare counter
/// (glyph + label + percent/bytes), mirroring the TUI's "readable text over a
/// corrupt frame" fallback.
const BarLayout = union(enum) { counter, bar: u16 };

/// Resolve the layout for terminal width `cols` (`null` = not a TTY, so keep
/// the historical fixed bar and never query again).
fn barLayout(cols: ?u16, label_width: u8) BarLayout {
    const c = cols orelse return .{ .bar = bar_cap };
    if (c < barOverhead(label_width) + bar_floor) return .counter;
    return .{ .bar = barCells(c, label_width) };
}

/// Test-only injected terminal width. `null` reproduces the non-TTY path
/// (`winsize` → `NotATty`), so existing render tests keep the fixed 30-cell
/// bar without a real terminal.
var cols_override: ?u16 = null;

pub fn setColsForTest(v: ?u16) void {
    if (!builtin.is_test) return;
    cols_override = v;
}

/// Live terminal width for the draw, read from the stderr handle the bars
/// write to. `null` on a non-TTY (piped / redirected) so the caller keeps the
/// fixed bar. Stderr, not stdin: stderr can be a TTY while stdin is not.
fn queryCols() ?u16 {
    if (builtin.is_test) return cols_override;
    const size = termsize.winsize(pkg_stderr.handle) catch return null;
    return size.cols;
}

/// Coordinates multiple progress bars on separate terminal lines.
/// Reserves N lines upfront, then uses ANSI cursor movement so each
/// bar updates its own line without interfering with others.
pub const MultiProgress = struct {
    total_lines: u16,
    mutex: std.Io.Mutex,
    is_tty: bool,
    /// Bars in row order, so the first worker to see a resize can repaint the
    /// whole group at the new width. Empty for groups whose caller never
    /// registers its bars (the resize path is then a no-op).
    bars: []ProgressBar = &.{},

    pub fn init(count: u16) MultiProgress {
        // `is_tty` here means "TTY-mode bar is active": the rendering
        // gate folds terminal capability and `MALT_PROGRESS` together so
        // plain/none never leaks DECSET/cursor-hide bytes into CI logs.
        const tty = supportsAnsi() and pkg_mode == .tty;

        // Hide cursor, disable autowrap, reserve lines by printing empty placeholders.
        // Autowrap disabled so an over-width bar clips instead of wrapping —
        // wrapping would break the ESC[NA cursor-up math each bar relies on.
        if (tty and !output.isQuiet()) {
            // Arm SIGWINCH so a mid-render resize repaints the group on the
            // next tick. Flag-only handler: the repaint owner queries the new
            // width in normal context, no syscall in signal context.
            termsize.installWinchFlagOnly();
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

    /// First worker to observe a `SIGWINCH` repaints the whole group at the
    /// new width; later workers this tick see the consumed flag and skip it.
    /// Caller holds the group mutex, so the repaint serialises against
    /// in-flight single-line draws. No-op without a pending resize.
    fn repaintIfResized(self: *MultiProgress) void {
        if (!termsize.takeResized()) return;
        // Some emulators re-enable DECAWM on resize: re-assert autowrap-off so
        // a reflowed over-width bar clips instead of wrapping and desyncing the
        // cursor-up math. Each bar's draw re-queries the live width and keeps
        // its own `\x1b[K`, so a narrowing redraw erases the stale wider tail.
        writeStderrAll("\x1b[?7l");
        for (self.bars) |*bar| bar.drawLine();
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
    /// Atomic: the owning worker stores lock-free on every `update` while a
    /// sibling holding the group mutex reads it during a resize repaint.
    current: std.atomic.Value(u64),
    last_render_ns: i128,
    start_time_ms: i64,
    /// Atomic for the same reason as `current` — sibling repaints read it.
    spinner_frame: std.atomic.Value(u8),
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

    pub fn init(label: []const u8, total: u64) ProgressBar {
        return .{
            .label = label,
            .total = total,
            .current = .init(0),
            .last_render_ns = 0,
            .start_time_ms = nowMs(),
            .spinner_frame = .init(0),
            .is_tty = supportsAnsi(),
            .label_width = 0,
            .line_index = 0,
            .multi = null,
            .plain_started = false,
            .plain_finished = false,
        };
    }

    pub fn update(self: *ProgressBar, current: u64) void {
        self.current.store(current, .monotonic);
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
                    self.current.store(self.total, .monotonic);
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
        _ = self.spinner_frame.fetchAdd(1, .monotonic);

        // The group mutex guards every multi-bar draw; hold it across the
        // resize check + draw so a resize repaints the whole group atomically
        // against in-flight worker draws.
        if (self.multi) |mp| {
            mp.mutex.lockUncancelable(pkg_io);
            defer mp.mutex.unlock(pkg_io);
            mp.repaintIfResized();
            self.drawLine();
        } else {
            self.drawLine();
        }
    }

    /// Monotonic read of the shared byte counter: draws run under the group
    /// mutex, but the owning worker stores lock-free, so a repaint may see a
    /// value one tick stale — never a torn one.
    fn cur(self: *const ProgressBar) u64 {
        return self.current.load(.monotonic);
    }

    /// Draw this bar's single line in place — no locking, so the group mutex
    /// is held by the caller (`render`) and by `repaintIfResized`. Determinacy
    /// selects the body; both honour the group's cursor-up/down math.
    fn drawLine(self: *const ProgressBar) void {
        if (self.total > 0) self.drawDeterminate() else self.drawIndeterminate();
    }

    /// Return the glyph shown in front of the label: a spinner frame while
    /// work is in progress, or a checkmark once the bar has reached 100%.
    /// The spinner uses Braille Pattern chars (not emoji); only the done
    /// glyph has an ASCII fallback to match `output.success()` in no-emoji mode.
    fn glyph(self: *const ProgressBar) []const u8 {
        const done = self.total > 0 and self.cur() >= self.total;
        if (done) {
            return if (color.isEmojiEnabled()) "\xe2\x9c\x93" else "*"; // ✓
        }
        return spinner_frames.frames[self.spinner_frame.load(.monotonic) % spinner_frames.count];
    }

    fn computeRate(self: *const ProgressBar) f64 {
        const now_ms = nowMs();
        const elapsed_ms = now_ms - self.start_time_ms;
        if (elapsed_ms <= 0) return 0;
        return @as(f64, @floatFromInt(self.cur())) / (@as(f64, @floatFromInt(elapsed_ms)) / 1000.0);
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
        const done = self.total > 0 and self.cur() >= self.total;
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

    /// Visible columns `writeLabel` emits: indent (2) + glyph (1) + space (1)
    /// + label (padded to `label_width`) + a trailing space. Used to budget the
    /// detail readout against the live terminal width.
    fn prefixCols(self: *const ProgressBar) usize {
        const drawn = @max(self.label.len, @as(usize, self.label_width));
        return 2 + 1 + 1 + drawn + 1;
    }

    /// The collapsed counter line — `  <glyph> <label> <value>` — for terminals
    /// too narrow for even a floor-width bar. The label is truncated so the
    /// visible line never exceeds `cols`; `value` is the percent (determinate)
    /// or the bytes-so-far (indeterminate). Mirrors the TUI's readable-text
    /// fallback over a corrupt frame.
    fn writeCounterLine(self: *const ProgressBar, buf: []u8, start_pos: usize, cols: u16, value: []const u8) usize {
        var pos = start_pos;
        const done = self.total > 0 and self.cur() >= self.total;
        const use_color = color.isColorEnabled();

        buf[pos] = ' ';
        pos += 1;
        buf[pos] = ' ';
        pos += 1;

        const g = self.glyph();
        if (use_color) {
            const c = if (done) color.SemanticStyle.success.code() else color.SemanticStyle.info.code();
            @memcpy(buf[pos .. pos + c.len], c);
            pos += c.len;
        }
        @memcpy(buf[pos .. pos + g.len], g);
        pos += g.len;
        if (use_color) {
            const r = color.Style.reset.code();
            @memcpy(buf[pos .. pos + r.len], r);
            pos += r.len;
        }
        buf[pos] = ' ';
        pos += 1;

        // Columns already spent (indent + glyph + space) plus the space and
        // value still to come; the label takes whatever is left.
        const fixed: usize = 2 + 1 + 1 + 1 + value.len;
        const budget: usize = if (cols > fixed) cols - fixed else 0;
        const label_len = @min(self.label.len, budget);
        @memcpy(buf[pos .. pos + label_len], self.label[0..label_len]);
        pos += label_len;

        buf[pos] = ' ';
        pos += 1;
        @memcpy(buf[pos .. pos + value.len], value);
        pos += value.len;
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

    fn drawDeterminate(self: *const ProgressBar) void {
        const cols = queryCols();
        const layout = barLayout(cols, self.label_width);
        const pct: u64 = if (self.total > 0) @min((self.cur() * 100) / self.total, 100) else 0;

        var buf: [768]u8 = undefined;
        var pos: usize = 0;

        // For multi-progress: move cursor up to our line
        const move_up: u16 = if (self.multi) |mp| mp.total_lines - self.line_index else 0;
        pos = writeCursorUp(&buf, pos, move_up);

        // Carriage return
        buf[pos] = '\r';
        pos += 1;

        switch (layout) {
            .counter => {
                // Too narrow for a bar: drop to "  <glyph> <label> NN%".
                var pct_buf: [8]u8 = undefined;
                const pct_str = std.fmt.bufPrint(&pct_buf, "{d}%", .{pct}) catch "%";
                pos = self.writeCounterLine(&buf, pos, cols.?, pct_str);
            },
            .bar => |bw_u16| {
                const bw: u64 = bw_u16;

                // Prefix + aligned label
                pos = self.writeLabel(&buf, pos);

                // Bar
                const filled: u64 = if (self.total > 0) @min((self.cur() * bw) / self.total, bw) else 0;
                const empty = bw - filled;
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

                pos = self.writeDetail(&buf, pos, cols, bw);
            },
        }

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

    /// Append the dim `(size | rate | ETA)` detail. When `cols` is known, ETA
    /// then rate are dropped (in that order) if the assembled line would
    /// overflow — so the verbose readout gives way before the bar does. `bw` is
    /// the bar width already drawn; the budget is measured against it.
    fn writeDetail(self: *const ProgressBar, buf: []u8, start_pos: usize, cols: ?u16, bw: u64) usize {
        var pos = start_pos;
        const use_color = color.isColorEnabled();
        const dim_code = if (use_color) color.SemanticStyle.detail.code() else "";
        const reset_code = if (use_color) color.Style.reset.code() else "";

        // One snapshot for the whole detail so size/rate/ETA agree.
        const current = self.cur();
        var size_buf: [48]u8 = undefined;
        const size_kb = current / 1024;
        const total_kb = self.total / 1024;
        const size_str = if (total_kb > 1024)
            std.fmt.bufPrint(&size_buf, "{d:.1}/{d:.1} MB", .{
                @as(f64, @floatFromInt(size_kb)) / 1024.0,
                @as(f64, @floatFromInt(total_kb)) / 1024.0,
            }) catch ""
        else
            std.fmt.bufPrint(&size_buf, "{d}/{d} KB", .{ size_kb, total_kb }) catch "";

        const rate = self.computeRate();
        var rate_buf: [32]u8 = undefined;
        const rate_str = formatRate(&rate_buf, rate);

        var eta_buf: [32]u8 = undefined;
        const eta_str = if (self.total > 0 and current < self.total and rate > 0)
            formatEta(&eta_buf, self.total - current, rate)
        else
            "";

        var show_rate = current > 0;
        var show_eta = eta_str.len > 0;
        if (cols) |c| {
            const budget: usize = c;
            // Columns through the closing paren of "(size)": prefix + bar +
            // percent (5) + " (" (2) + size + ")" (1).
            const base = self.prefixCols() + @as(usize, @intCast(bw)) + 5 + 2 + size_str.len + 1;
            if (show_rate and base + 3 + rate_str.len > budget) show_rate = false;
            const after_rate = base + (if (show_rate) 3 + rate_str.len else 0);
            if (show_eta and (!show_rate or after_rate + 3 + eta_str.len > budget)) show_eta = false;
        }

        @memcpy(buf[pos .. pos + dim_code.len], dim_code);
        pos += dim_code.len;

        const open = std.fmt.bufPrint(buf[pos..], " (", .{}) catch "";
        pos += open.len;
        @memcpy(buf[pos .. pos + size_str.len], size_str);
        pos += size_str.len;

        if (show_rate) {
            const rate_part = std.fmt.bufPrint(buf[pos..], " | {s}", .{rate_str}) catch "";
            pos += rate_part.len;
        }
        if (show_eta) {
            const eta_part = std.fmt.bufPrint(buf[pos..], " | {s}", .{eta_str}) catch "";
            pos += eta_part.len;
        }

        buf[pos] = ')';
        pos += 1;
        @memcpy(buf[pos .. pos + reset_code.len], reset_code);
        pos += reset_code.len;
        return pos;
    }

    fn drawIndeterminate(self: *const ProgressBar) void {
        const cols = queryCols();

        var buf: [512]u8 = undefined;
        var pos: usize = 0;

        const move_up: u16 = if (self.multi) |mp| mp.total_lines - self.line_index else 0;
        pos = writeCursorUp(&buf, pos, move_up);

        buf[pos] = '\r';
        pos += 1;

        const size_kb = self.cur() / 1024;
        var size_buf: [32]u8 = undefined;
        const size_str = if (size_kb > 1024)
            std.fmt.bufPrint(&size_buf, "{d:.1} MB", .{@as(f64, @floatFromInt(size_kb)) / 1024.0}) catch ""
        else
            std.fmt.bufPrint(&size_buf, "{d} KB", .{size_kb}) catch "";

        const rate = self.computeRate();
        var rate_buf: [32]u8 = undefined;
        const rate_str = formatRate(&rate_buf, rate);

        // Indeterminate bars carry no bar to shrink; instead, when the full
        // "(size | rate)" detail won't fit the live width, collapse to the bare
        // "  <glyph> <label> <bytes>" counter (drop the rate + parens).
        const full_width = self.prefixCols() + 1 + size_str.len + 3 + rate_str.len + 1;
        const collapse = if (cols) |c| full_width > @as(usize, c) else false;

        if (collapse) {
            pos = self.writeCounterLine(&buf, pos, cols.?, size_str);
        } else {
            // writeLabel already renders the animated spinner as the line glyph.
            pos = self.writeLabel(&buf, pos);

            const use_color = color.isColorEnabled();
            const dim_code = if (use_color) color.SemanticStyle.detail.code() else "";
            const reset_code = if (use_color) color.Style.reset.code() else "";

            @memcpy(buf[pos .. pos + dim_code.len], dim_code);
            pos += dim_code.len;
            buf[pos] = '(';
            pos += 1;

            const info = std.fmt.bufPrint(buf[pos..], "{s} | {s}", .{ size_str, rate_str }) catch "";
            pos += info.len;

            buf[pos] = ')';
            pos += 1;
            @memcpy(buf[pos .. pos + reset_code.len], reset_code);
            pos += reset_code.len;
        }

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
        const g = spinner_frames.frames[frame % spinner_frames.count];
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

// A TTY-mode group arms SIGWINCH so a mid-render resize is observed without
// a keypress; plain/none never install a handler (next test). The handler is
// the flag-only variant — no syscall in signal context.
test "MultiProgress in tty mode installs the flag-only winch handler" {
    const prior_mode = mode();
    setMode(.tty);
    defer setMode(prior_mode);
    setSupportsAnsiForTest(true);
    defer setSupportsAnsiForTest(null);
    termsize.setWinchInstalledForTest(false);
    defer termsize.setWinchInstalledForTest(false);

    var mp = MultiProgress.init(2);
    mp.finish();

    try std.testing.expect(termsize.winchInstalled());
}

test "MultiProgress in plain mode installs no winch handler" {
    const prior_mode = mode();
    setMode(.plain);
    defer setMode(prior_mode);
    setSupportsAnsiForTest(true);
    defer setSupportsAnsiForTest(null);
    termsize.setWinchInstalledForTest(false);
    defer termsize.setWinchInstalledForTest(false);

    var mp = MultiProgress.init(2);
    mp.finish();

    try std.testing.expect(!termsize.winchInstalled());
}

// AC: a resize mid-render repaints the whole group at the new width — the
// autowrap-disable prelude is re-asserted and every bar's line is redrawn, not
// just the worker that happened to tick. The flag is consumed once, so a burst
// of resizes collapses to a single repaint per tick.
test "a resize repaints the whole group with autowrap re-asserted" {
    const prior_mode = mode();
    setMode(.tty);
    defer setMode(prior_mode);
    setSupportsAnsiForTest(true);
    defer setSupportsAnsiForTest(null);
    color.setForTest(false, false);
    defer color.setForTest(null, null);
    setColsForTest(100);
    defer setColsForTest(null);
    termsize.setWinchInstalledForTest(true); // skip the real sigaction
    defer termsize.setWinchInstalledForTest(false);
    termsize.setResizedForTest(false);
    defer termsize.setResizedForTest(false);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    beginStderrCapture(std.testing.allocator, &buf);
    defer endStderrCapture();

    var mp = MultiProgress.init(2);
    mp.is_tty = true;

    var bars = [_]ProgressBar{
        ProgressBar.init("alpha", 100),
        ProgressBar.init("bravo", 100),
    };
    for (&bars, 0..) |*b, i| {
        b.is_tty = true;
        b.multi = &mp;
        b.line_index = @intCast(i);
    }
    mp.bars = &bars;

    // Isolate the repaint from the init prelude + reserved newlines.
    buf.clearRetainingCapacity();

    // A resize lands; the next worker to tick repaints the whole group.
    termsize.setResizedForTest(true);
    bars[1].update(50);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\x1b[?7l") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "bravo") != null);
    // The flag is consumed — a burst can't trigger a second repaint this tick.
    try std.testing.expect(!termsize.takeResized());

    // A later tick with no pending resize redraws only the worker's own line.
    buf.clearRetainingCapacity();
    bars[0].last_render_ns = 0; // bypass the 10 Hz throttle
    bars[0].update(60);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "bravo") == null);
}

// AC: migrate's indeterminate bars inherit the repaint with no bespoke code —
// the generic `drawLine` dispatch repaints a sibling spinner row too.
test "a resize repaints indeterminate (migrate) bars" {
    const prior_mode = mode();
    setMode(.tty);
    defer setMode(prior_mode);
    setSupportsAnsiForTest(true);
    defer setSupportsAnsiForTest(null);
    color.setForTest(false, false);
    defer color.setForTest(null, null);
    setColsForTest(100);
    defer setColsForTest(null);
    termsize.setWinchInstalledForTest(true);
    defer termsize.setWinchInstalledForTest(false);
    termsize.setResizedForTest(false);
    defer termsize.setResizedForTest(false);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    beginStderrCapture(std.testing.allocator, &buf);
    defer endStderrCapture();

    var mp = MultiProgress.init(2);
    mp.is_tty = true;
    var bars = [_]ProgressBar{
        ProgressBar.init("redis", 0), // total 0 → indeterminate
        ProgressBar.init("kafka", 0),
    };
    for (&bars, 0..) |*b, i| {
        b.is_tty = true;
        b.multi = &mp;
        b.line_index = @intCast(i);
    }
    mp.bars = &bars;
    buf.clearRetainingCapacity();

    termsize.setResizedForTest(true);
    bars[0].update(4096);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\x1b[?7l") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "redis") != null);
    // The sibling bar, whose worker did not tick, was repainted too.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "kafka") != null);
}

// AC headline: the repaint re-derives the live width. A terminal that narrows
// below the floor collapses the repainted bars to bare counters — proof the
// repaint reads the new width, not the width the bars were first drawn at.
test "a resize repaints at the new width, collapsing to counters when it narrows" {
    const prior_mode = mode();
    setMode(.tty);
    defer setMode(prior_mode);
    setSupportsAnsiForTest(true);
    defer setSupportsAnsiForTest(null);
    color.setForTest(true, true);
    defer color.setForTest(null, null);
    setColsForTest(120); // wide: full bars
    defer setColsForTest(null);
    termsize.setWinchInstalledForTest(true);
    defer termsize.setWinchInstalledForTest(false);
    termsize.setResizedForTest(false);
    defer termsize.setResizedForTest(false);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    beginStderrCapture(std.testing.allocator, &buf);
    defer endStderrCapture();

    var mp = MultiProgress.init(2);
    mp.is_tty = true;
    var bars = [_]ProgressBar{
        ProgressBar.init("alpha", 1000),
        ProgressBar.init("bravo", 1000),
    };
    for (&bars, 0..) |*b, i| {
        b.is_tty = true;
        b.multi = &mp;
        b.line_index = @intCast(i);
    }
    mp.bars = &bars;
    bars[0].update(500);
    try std.testing.expect(barCellCount(buf.items) > 0); // wide draw has bars
    buf.clearRetainingCapacity();

    // The terminal shrinks hard, then a resize lands.
    setColsForTest(20);
    termsize.setResizedForTest(true);
    bars[0].last_render_ns = 0;
    bars[0].update(600);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\x1b[?7l") != null);
    try std.testing.expectEqual(@as(usize, 0), barCellCount(buf.items)); // counters at new width
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "bravo") != null);
}

// Edge: a resize before the caller registers its bars must not crash on the
// empty slice — the repaint still re-asserts autowrap and the ticking worker
// draws its own line.
test "a resize with no registered bars re-asserts autowrap without crashing" {
    const prior_mode = mode();
    setMode(.tty);
    defer setMode(prior_mode);
    setSupportsAnsiForTest(true);
    defer setSupportsAnsiForTest(null);
    color.setForTest(false, false);
    defer color.setForTest(null, null);
    setColsForTest(80);
    defer setColsForTest(null);
    termsize.setWinchInstalledForTest(true);
    defer termsize.setWinchInstalledForTest(false);
    termsize.setResizedForTest(false);
    defer termsize.setResizedForTest(false);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    beginStderrCapture(std.testing.allocator, &buf);
    defer endStderrCapture();

    var mp = MultiProgress.init(1);
    mp.is_tty = true;
    var bar = ProgressBar.init("solo", 100);
    bar.is_tty = true;
    bar.multi = &mp;
    bar.line_index = 0;
    // mp.bars deliberately left empty — caller never registered it.
    buf.clearRetainingCapacity();

    termsize.setResizedForTest(true);
    bar.update(50);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\x1b[?7l") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "solo") != null);
}

// AC: single-package `upgrade` draws through SingleBar — a group of one. A
// resize must repaint that bar at the new width too: wide bar collapses to a
// counter, autowrap re-asserted. Proves the upgrade path inherits the fix
// with no bespoke wiring (the bar repaints itself on its next tick).
test "a resize repaints the single-bar (upgrade) group at the new width" {
    const prior_mode = mode();
    setMode(.tty);
    defer setMode(prior_mode);
    setSupportsAnsiForTest(true);
    defer setSupportsAnsiForTest(null);
    color.setForTest(true, true);
    defer color.setForTest(null, null);
    setColsForTest(100); // wide: a real bar
    defer setColsForTest(null);
    termsize.setWinchInstalledForTest(true);
    defer termsize.setWinchInstalledForTest(false);
    termsize.setResizedForTest(false);
    defer termsize.setResizedForTest(false);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    beginStderrCapture(std.testing.allocator, &buf);
    defer endStderrCapture();

    var sp = SingleBar.init("ffmpeg", 1000);
    const bar = sp.bind();
    bar.is_tty = true;
    bar.update(400);
    try std.testing.expect(barCellCount(buf.items) > 0); // wide bar present
    buf.clearRetainingCapacity();

    setColsForTest(20); // narrow, then a resize
    termsize.setResizedForTest(true);
    bar.last_render_ns = 0;
    bar.update(500);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\x1b[?7l") != null);
    try std.testing.expectEqual(@as(usize, 0), barCellCount(buf.items)); // counter at new width
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "ffmpeg") != null);
    sp.finish();
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

// `barCells` is the width-aware replacement for the old fixed `bar_width`.
// A terminal at least as wide as the full line keeps the historical 30-cell
// bar so existing output is byte-identical; only narrow terminals shrink it.
test "barCells caps at the historical 30 on a wide terminal" {
    try std.testing.expectEqual(@as(u16, 30), barCells(200, 10));
    try std.testing.expectEqual(@as(u16, 30), barCells(120, 0));
}

// The bar must give way smoothly as the terminal narrows — no jump from full
// width to floor.
test "barCells shrinks monotonically as the terminal narrows" {
    var prev: u16 = barCells(120, 10);
    var cols: u16 = 115;
    while (cols >= 40) : (cols -= 1) {
        const cur = barCells(cols, 10);
        try std.testing.expect(cur <= prev);
        prev = cur;
    }
}

// Even a pathologically narrow terminal leaves a usable stub bar rather than
// a zero-width one that would read as "no bar".
test "barCells never returns below the 4-cell floor" {
    try std.testing.expectEqual(@as(u16, 4), barCells(10, 10));
    try std.testing.expectEqual(@as(u16, 4), barCells(0, 0));
    var cols: u16 = 0;
    while (cols < 300) : (cols += 1) {
        try std.testing.expect(barCells(cols, 20) >= bar_floor);
    }
}

// A longer label eats into the budget, so the bar must reserve room for it —
// a wider label at the same width yields a narrower bar.
test "barCells reserves room for a wider label" {
    try std.testing.expect(barCells(80, 30) < barCells(80, 0));
}

// Counts on-screen columns: strips CSI escapes and CR/LF, then tallies one
// column per remaining UTF-8 codepoint (the bar/glyph chars are 1 column each).
fn visibleColumns(s: []const u8) usize {
    var i: usize = 0;
    var cols: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b == 0x1b) {
            i += 1;
            if (i < s.len and s[i] == '[') {
                i += 1;
                while (i < s.len and (s[i] < 0x40 or s[i] > 0x7e)) i += 1; // params
                if (i < s.len) i += 1; // final byte
            }
            continue;
        }
        if (b == '\r' or b == '\n') {
            i += 1;
            continue;
        }
        i += std.unicode.utf8ByteSequenceLength(b) catch 1;
        cols += 1;
    }
    return cols;
}

fn barCellCount(s: []const u8) usize {
    return std.mem.count(u8, s, "\xe2\x94\x81") + std.mem.count(u8, s, "\xe2\x94\x80"); // ━ + ─
}

// AC: on a narrow terminal the assembled line must not exceed the column
// budget — the bar shrinks and detail drops until it fits.
test "determinate render fits within a narrow terminal width" {
    const prior_mode = mode();
    setMode(.tty);
    defer setMode(prior_mode);
    setSupportsAnsiForTest(true);
    defer setSupportsAnsiForTest(null);
    color.setForTest(true, true);
    defer color.setForTest(null, null);
    setColsForTest(60);
    defer setColsForTest(null);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    beginStderrCapture(std.testing.allocator, &buf);
    defer endStderrCapture();

    var bar = ProgressBar.init("tree", 10 * 1024 * 1024);
    bar.is_tty = true;
    bar.update(6 * 1024 * 1024);

    try std.testing.expect(visibleColumns(buf.items) <= 60);
}

// AC: ETA/rate drop *before* the bar collapses — at a width where the bar is
// still full but the verbose MB detail would overflow, ETA is dropped while
// the bar stays at 30 cells.
test "determinate render drops ETA before shrinking the bar" {
    const prior_mode = mode();
    setMode(.tty);
    defer setMode(prior_mode);
    setSupportsAnsiForTest(true);
    defer setSupportsAnsiForTest(null);
    color.setForTest(true, true);
    defer color.setForTest(null, null);
    setColsForTest(80);
    defer setColsForTest(null);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    beginStderrCapture(std.testing.allocator, &buf);
    defer endStderrCapture();

    var bar = ProgressBar.init("a", 2000 * 1024 * 1024);
    bar.is_tty = true;
    bar.start_time_ms = nowMs() - 5000; // 5s elapsed → a real rate + ETA
    bar.update(100 * 1024 * 1024);

    try std.testing.expect(visibleColumns(buf.items) <= 80);
    try std.testing.expectEqual(@as(usize, 30), barCellCount(buf.items)); // bar not collapsed
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "ETA") == null); // ETA dropped
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "MB") != null); // size kept
}

// AC: below the floor-bar threshold the bar is dropped entirely for a bare
// counter — glyph + label + percent, no bar cells — mirroring the TUI fallback.
test "determinate render collapses to a bare counter on a very narrow terminal" {
    const prior_mode = mode();
    setMode(.tty);
    defer setMode(prior_mode);
    setSupportsAnsiForTest(true);
    defer setSupportsAnsiForTest(null);
    color.setForTest(true, true);
    defer color.setForTest(null, null);
    setColsForTest(20);
    defer setColsForTest(null);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    beginStderrCapture(std.testing.allocator, &buf);
    defer endStderrCapture();

    var bar = ProgressBar.init("tree", 1000);
    bar.is_tty = true;
    bar.update(750);

    try std.testing.expect(visibleColumns(buf.items) <= 20);
    try std.testing.expectEqual(@as(usize, 0), barCellCount(buf.items)); // no bar
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "tree") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "75%") != null); // counter
}

// AC: a non-TTY (winsize → NotATty, modelled by a null override) keeps the
// historical fixed 30-cell bar — piped install output is unchanged.
test "determinate render keeps the fixed 30-cell bar on a non-tty" {
    const prior_mode = mode();
    setMode(.tty);
    defer setMode(prior_mode);
    setSupportsAnsiForTest(true);
    defer setSupportsAnsiForTest(null);
    color.setForTest(true, true);
    defer color.setForTest(null, null);
    setColsForTest(null);
    defer setColsForTest(null);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    beginStderrCapture(std.testing.allocator, &buf);
    defer endStderrCapture();

    var bar = ProgressBar.init("tree", 1000);
    bar.is_tty = true;
    bar.update(500);

    try std.testing.expectEqual(@as(usize, 30), barCellCount(buf.items));
}

// AC: the indeterminate (migrate) path collapses to glyph + label + bytes on a
// very narrow terminal, dropping the parenthesised rate detail.
test "indeterminate render collapses to label + bytes on a very narrow terminal" {
    const prior_mode = mode();
    setMode(.tty);
    defer setMode(prior_mode);
    setSupportsAnsiForTest(true);
    defer setSupportsAnsiForTest(null);
    color.setForTest(true, true);
    defer color.setForTest(null, null);
    setColsForTest(18);
    defer setColsForTest(null);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    beginStderrCapture(std.testing.allocator, &buf);
    defer endStderrCapture();

    var bar = ProgressBar.init("kafka", 0); // total 0 → indeterminate
    bar.is_tty = true;
    bar.update(12 * 1024 * 1024);

    try std.testing.expect(visibleColumns(buf.items) <= 18);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "kafka") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "MB") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "(") == null); // no detail parens
}

test "update publishes the byte count through the atomic counter" {
    const prior_mode = mode();
    setMode(.none); // no rendering — this pins the store, not the draw
    defer setMode(prior_mode);

    var bar = ProgressBar.init("tree", 1000);
    bar.update(42);
    try std.testing.expectEqual(@as(u64, 42), bar.cur());
}

test "finish clamps the counter to total through the atomic" {
    const prior_mode = mode();
    setMode(.tty);
    defer setMode(prior_mode);
    setSupportsAnsiForTest(true);
    defer setSupportsAnsiForTest(null);
    setColsForTest(80);
    defer setColsForTest(null);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    beginStderrCapture(std.testing.allocator, &buf);
    defer endStderrCapture();

    var bar = ProgressBar.init("tree", 1000);
    bar.is_tty = true;
    bar.update(400);
    bar.finish();

    try std.testing.expectEqual(@as(u64, 1000), bar.cur());
}

test "render advances the spinner frame and wraps at u8 overflow" {
    const prior_mode = mode();
    setMode(.tty);
    defer setMode(prior_mode);
    setSupportsAnsiForTest(true);
    defer setSupportsAnsiForTest(null);
    setColsForTest(80);
    defer setColsForTest(null);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    beginStderrCapture(std.testing.allocator, &buf);
    defer endStderrCapture();

    var bar = ProgressBar.init("tree", 1000);
    bar.is_tty = true;
    bar.spinner_frame.store(255, .monotonic);
    bar.update(1); // first render tick: 255 +% 1 wraps to 0
    try std.testing.expectEqual(@as(u8, 0), bar.spinner_frame.load(.monotonic));
}
