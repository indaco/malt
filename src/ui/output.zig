//! malt — output module
//! Human + JSON output formatting.

const std = @import("std");
const builtin = @import("builtin");
const color = @import("color.zig");

pub const OutputMode = enum {
    human,
    json,
};

var quiet: bool = false;
var verbose: bool = false;
var debug: bool = false;
var dry_run: bool = false;
var mode: OutputMode = .human;
/// Orthogonal to `mode`/`--json` so CI can stream per-step events
/// without losing the final summary.
var ndjson: bool = false;

/// Process-wide io seeded once from `main` via `setRuntime`. Defaults to
/// `debug_io` so tests that don't seed see deterministic, allocation-
/// free behaviour.
var pkg_io: std.Io = std.Options.debug_io;
var pkg_environ: std.process.Environ = .{ .block = .{ .slice = &[_:null]?[*:0]const u8{} } };
/// Stdio sinks seeded by `main`. Default `-1` so unconfigured tests
/// silently drop writes (BadFileDescriptor) instead of leaking onto fd 1
/// or 2 — keeps `zig build test` quiet by default.
var pkg_stdout: std.Io.File = .{ .handle = -1, .flags = .{ .nonblocking = false } };
var pkg_stderr: std.Io.File = .{ .handle = -1, .flags = .{ .nonblocking = false } };

/// Seed the io/environ used by writes, isatty probes, and timestamps.
/// Called by `main` after `AppCtx` is built.
pub fn setRuntime(io: std.Io, environ: std.process.Environ, stdout: std.Io.File, stderr: std.Io.File) void {
    pkg_io = io;
    pkg_environ = environ;
    pkg_stdout = stdout;
    pkg_stderr = stderr;
}

pub fn setQuiet(q: bool) void {
    quiet = q;
}
pub fn setVerbose(v: bool) void {
    verbose = v;
}
/// Enable debug mode — prints every logged diagnostic the CLI collects,
/// so users filing issues can attach a single transcript that captures
/// what the DSL/interpreter saw. Implies verbose.
pub fn setDebug(d: bool) void {
    debug = d;
    if (d) verbose = true;
}
pub fn setDryRun(d: bool) void {
    dry_run = d;
}
pub fn setMode(m: OutputMode) void {
    mode = m;
}
pub fn isQuiet() bool {
    return quiet;
}
pub fn isVerbose() bool {
    return verbose;
}
pub fn isDebug() bool {
    return debug;
}
pub fn isDryRun() bool {
    return dry_run;
}
pub fn isJson() bool {
    return mode == .json;
}
pub fn setNdjson(b: bool) void {
    ndjson = b;
}
pub fn isNdjson() bool {
    return ndjson;
}

/// `.embed` lets a `--json` command collect per-keg post_install
/// events and embed them in its final summary doc instead of
/// streaming each as a JSONL line. `--ndjson` always streams.
pub const PostInstallEmit = enum { stream, embed };
var post_install_emit: PostInstallEmit = .stream;
var post_install_buffer: std.ArrayList([]const u8) = .empty;
var post_install_buffer_alloc: ?std.mem.Allocator = null;
/// Parallel workers call `pushPostInstallEvent` concurrently; without
/// serialisation the ArrayList append races and crashes. `std.Io.Mutex`
/// would drag an io context through this io-free module.
var post_install_mutex: std.atomic.Mutex = .unlocked;

fn lockBuffer() void {
    while (!post_install_mutex.tryLock()) std.Thread.yield() catch {};
}
fn unlockBuffer() void {
    post_install_mutex.unlock();
}

/// `.embed` requires a long-lived allocator: parallel workers' arenas
/// die before drain runs, so the buffer copies into its own allocator.
/// The mode itself is `@atomicStore`d so worker readers don't need the
/// buffer mutex on every routing decision.
pub fn setPostInstallEmit(m: PostInstallEmit, allocator: ?std.mem.Allocator) void {
    lockBuffer();
    defer unlockBuffer();
    @atomicStore(PostInstallEmit, &post_install_emit, m, .release);
    if (m == .embed) post_install_buffer_alloc = allocator;
}
/// Hot path — every post_install routing call hits this. Acquire pairs
/// with the setter's release so the allocator pointer is visible to
/// any worker that observes `.embed`.
pub fn postInstallEmit() PostInstallEmit {
    return @atomicLoad(PostInstallEmit, &post_install_emit, .acquire);
}

/// Copy `inner_json` (a `{...}` body, no trailing newline) into the
/// buffer's owning allocator. Safe under concurrent producers.
pub fn pushPostInstallEvent(inner_json: []const u8) !void {
    lockBuffer();
    defer unlockBuffer();
    const a = post_install_buffer_alloc orelse return error.PostInstallBufferNotInitialised;
    const owned = try a.dupe(u8, inner_json);
    errdefer a.free(owned);
    try post_install_buffer.append(a, owned);
}

/// Borrows the buffered slice; valid until the next reset/push.
/// Callers must drain after all workers have joined.
pub fn drainPostInstallEvents() []const []const u8 {
    lockBuffer();
    defer unlockBuffer();
    return post_install_buffer.items;
}

/// Free every buffered entry and reset the list. Safe to call when the
/// buffer is empty (no allocator was ever set).
pub fn resetPostInstallEvents() void {
    lockBuffer();
    defer unlockBuffer();
    if (post_install_buffer_alloc) |a| {
        for (post_install_buffer.items) |item| a.free(item);
        post_install_buffer.deinit(a);
        post_install_buffer = .empty;
        post_install_buffer_alloc = null;
    }
    @atomicStore(PostInstallEmit, &post_install_emit, .stream, .release);
}

/// Test-only stderr / stdout capture. Tests run sequentially in a binary,
/// so no lock; elided from release via `builtin.is_test` guards.
var capture_list: ?*std.ArrayList(u8) = null;
var capture_allocator: std.mem.Allocator = undefined;
var stdout_capture_list: ?*std.ArrayList(u8) = null;
var stdout_capture_allocator: std.mem.Allocator = undefined;

/// Test-only: redirect stderr writes into `buf`. Pair with `endStderrCapture`.
pub fn beginStderrCapture(allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) void {
    if (!builtin.is_test) return;
    capture_list = buf;
    capture_allocator = allocator;
}

/// Test-only: stop redirecting stderr writes.
pub fn endStderrCapture() void {
    if (!builtin.is_test) return;
    capture_list = null;
}

/// Test-only: redirect stdout writes into `buf`. Pair with `endStdoutCapture`.
/// Needed for asserting JSON-mode payloads that land on stdout.
pub fn beginStdoutCapture(allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) void {
    if (!builtin.is_test) return;
    stdout_capture_list = buf;
    stdout_capture_allocator = allocator;
}

pub fn endStdoutCapture() void {
    if (!builtin.is_test) return;
    stdout_capture_list = null;
}

/// Serialises stderr writes so parallel migrate workers can't tear an
/// ANSI prefix across a sibling's message body. Held over each
/// `writeStderrAll` call individually and over the full multi-write
/// `writePrefixedLine` sequence (via `writeStderrUnlocked`).
var stderr_mutex: std.atomic.Mutex = .unlocked;

fn lockStderr() void {
    while (!stderr_mutex.tryLock()) std.Thread.yield() catch {};
}
fn unlockStderr() void {
    stderr_mutex.unlock();
}

/// Lock-free body of `writeStderrAll`. Helpers that already hold
/// `stderr_mutex` for a multi-write sequence call this directly to
/// avoid a self-deadlock on the outer lock.
fn writeStderrUnlocked(bytes: []const u8) void {
    if (builtin.is_test) {
        if (capture_list) |list| {
            list.appendSlice(capture_allocator, bytes) catch {};
            return;
        }
    }
    pkg_stderr.writeStreamingAll(pkg_io, bytes) catch return;
}

/// Capture-aware stderr write. Tests that have set up a capture buffer
/// see writes there; everything else goes to the seeded `pkg_stderr`.
pub fn writeStderrAll(bytes: []const u8) void {
    lockStderr();
    defer unlockStderr();
    writeStderrUnlocked(bytes);
}

/// Capture-aware stdout write. Tests with a stdout capture buffer see
/// writes there; everything else goes to the seeded `pkg_stdout`.
pub fn writeStdoutAll(bytes: []const u8) void {
    if (builtin.is_test) {
        if (stdout_capture_list) |list| {
            list.appendSlice(stdout_capture_allocator, bytes) catch {};
            return;
        }
    }
    pkg_stdout.writeStreamingAll(pkg_io, bytes) catch return;
}

fn writeStderr(bytes: []const u8) void {
    writeStderrAll(bytes);
}

fn writeStdout(bytes: []const u8) void {
    writeStdoutAll(bytes);
}

/// Shared implementation for info/warn/success/err. One concrete
/// function so the binary carries a single copy regardless of how
/// many call sites route through it. Locks once around the whole
/// 4-write sequence so a concurrent worker can't slot its own prefix
/// between this line's prefix and message.
fn writePrefixedLine(
    msg: []const u8,
    role: color.SemanticStyle,
    emoji_prefix: []const u8,
    plain_prefix: []const u8,
) void {
    const prefix: []const u8 = if (color.isEmojiEnabled()) emoji_prefix else plain_prefix;
    const colorize = color.isColorEnabled();
    lockStderr();
    defer unlockStderr();
    if (colorize) {
        writeStderrUnlocked(role.code());
        writeStderrUnlocked(prefix);
        writeStderrUnlocked(color.Style.reset.code());
    } else {
        writeStderrUnlocked(prefix);
    }
    writeStderrUnlocked(msg);
    writeStderrUnlocked("\n");
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writePrefixedLine(msg, .info, "  ▸ ", "  > ");
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writePrefixedLine(msg, .warn, "  ⚠ ", "  ! ");
}

pub fn success(comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writePrefixedLine(msg, .success, "  ✓ ", "  * ");
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writePrefixedLine(msg, .err, "  ✗ ", "  x ");
}

/// "FYI / explanation" line — a passive heads-up that is neither a warning
/// nor a failure. Each tier picks an info-shaped glyph (`ⓘ` / `i`) so the
/// line reads distinctly from `warn`'s `⚠`/`!` on every (color, emoji)
/// combination, including NO_COLOR + MALT_NO_EMOJI.
pub fn notice(comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writePrefixedLine(msg, .notice, "  ⓘ ", "  i ");
}

/// Print a confirmation prompt: info-coloured `?` icon, bold message,
/// no trailing newline so the user's typed answer continues the line.
/// Bypasses `--quiet` — a silent prompt would deadlock interactive flows.
pub fn question(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    const prefix: []const u8 = if (color.isEmojiEnabled()) "  ? " else "  ? ";
    if (color.isColorEnabled()) {
        writeStderr(color.SemanticStyle.info.code());
        writeStderr(prefix);
        writeStderr(color.Style.reset.code());
        writeStderr(color.Style.bold.code());
        writeStderr(msg);
        writeStderr(color.Style.reset.code());
    } else {
        writeStderr(prefix);
        writeStderr(msg);
    }
}

/// Write a single styled line (no icon prefix). Pass null `style_code`
/// for plain text. Respects `--quiet`.
fn lineStyled(style_code: ?[]const u8, comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    if (style_code) |code| {
        if (color.isColorEnabled()) {
            writeStderr(code);
            writeStderr(msg);
            writeStderr(color.Style.reset.code());
        } else {
            writeStderr(msg);
        }
    } else {
        writeStderr(msg);
    }
    writeStderr("\n");
}

/// Warn-coloured line with no icon — for multi-line warning blocks.
pub fn warnPlain(comptime fmt: []const u8, args: anytype) void {
    lineStyled(color.SemanticStyle.warn.code(), fmt, args);
}

/// Plain un-styled line.
pub fn plain(comptime fmt: []const u8, args: anytype) void {
    lineStyled(null, fmt, args);
}

/// Faded detail line — legible on both palettes.
pub fn dimPlain(comptime fmt: []const u8, args: anytype) void {
    lineStyled(color.SemanticStyle.detail.code(), fmt, args);
}

/// Bold headline line (totals, summaries).
pub fn boldPlain(comptime fmt: []const u8, args: anytype) void {
    lineStyled(color.Style.bold.code(), fmt, args);
}

/// Print a dim/faint info message for low-priority status lines.
pub fn dim(comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    const prefix: []const u8 = if (color.isEmojiEnabled()) "  ▸ " else "  > ";
    if (color.isColorEnabled()) {
        writeStderr(color.SemanticStyle.detail.code());
        writeStderr(prefix);
        writeStderr(msg);
        writeStderr(color.Style.reset.code());
    } else {
        writeStderr(prefix);
        writeStderr(msg);
    }
    writeStderr("\n");
}

/// Dim "nothing to do" status line (e.g. already-at-latest). The bullet
/// glyph makes it recede next to `▸` activity lines in bulk commands.
pub fn skip(comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    const prefix: []const u8 = if (color.isEmojiEnabled()) "  · " else "  . ";
    if (color.isColorEnabled()) {
        writeStderr(color.SemanticStyle.detail.code());
        writeStderr(prefix);
        writeStderr(msg);
        writeStderr(color.Style.reset.code());
    } else {
        writeStderr(prefix);
        writeStderr(msg);
    }
    writeStderr("\n");
}

/// Read a single line from stdin and return true iff the trimmed input
/// matches `expected` exactly. Prints `prompt` via `question` first.
///
/// Returns false when stdin is not a TTY so that destructive commands
/// refuse to run unattended without an explicit `--yes` opt-in.
pub fn confirmTyped(expected: []const u8, prompt: []const u8) bool {
    const stdin_file: std.Io.File = .{ .handle = std.posix.STDIN_FILENO, .flags = .{ .nonblocking = false } };
    const is_tty = stdin_file.isTty(pkg_io) catch false;
    if (!is_tty) return false;

    question("{s}", .{prompt});

    var buf: [128]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return false;
    if (n == 0) return false;
    const input = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return std.mem.eql(u8, input, expected);
}

/// Write a dim `key:` prefix followed by padding so the value starts at
/// column `col`. Callers that need to emit a list (or any non-`bufPrint`
/// value) use this helper and then write the value themselves.
pub fn writeFieldKey(w: *std.Io.Writer, colorize: bool, col: usize, key: []const u8) !void {
    if (colorize) try w.writeAll(color.SemanticStyle.detail.code());
    try w.writeAll(key);
    try w.writeAll(":");
    if (colorize) try w.writeAll(color.Style.reset.code());
    const consumed = key.len + 1;
    const pad: usize = if (col > consumed) col - consumed else 1;
    var i: usize = 0;
    while (i < pad) : (i += 1) try w.writeAll(" ");
}

/// Write a `key: value` row where the value starts at column `col`.
/// When `colorize` is true the key and its colon are wrapped in dim
/// ANSI codes so the value stands out against aligned-key prefixes.
pub fn writeField(
    w: *std.Io.Writer,
    scratch: []u8,
    colorize: bool,
    col: usize,
    key: []const u8,
    comptime value_fmt: []const u8,
    args: anytype,
) !void {
    try writeFieldKey(w, colorize, col, key);
    const value = std.fmt.bufPrint(scratch, value_fmt, args) catch {
        try w.writeAll("\n");
        return;
    };
    try w.writeAll(value);
    try w.writeAll("\n");
}

/// Write `s` to `w` as a JSON string literal — surrounding quotes plus RFC 8259
/// escapes for `"`, `\`, and control characters. Use this wherever handwritten
/// JSON output embeds an identifier, tap name, version string, file path, or
/// anything else that might contain special characters.
pub fn jsonStr(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeAll("\"");
    var start: usize = 0;
    for (s, 0..) |byte, i| {
        const escape: ?[]const u8 = switch (byte) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x08 => "\\b",
            0x0c => "\\f",
            else => null,
        };
        if (escape) |esc| {
            if (i > start) try w.writeAll(s[start..i]);
            try w.writeAll(esc);
            start = i + 1;
        } else if (byte < 0x20) {
            if (i > start) try w.writeAll(s[start..i]);
            var hex_buf: [6]u8 = undefined;
            // `\u` + 4 hex digits = 6 bytes exactly; bufPrint cannot overflow a 6-byte buffer.
            const hex = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{byte}) catch unreachable;
            try w.writeAll(hex);
            start = i + 1;
        }
    }
    if (start < s.len) try w.writeAll(s[start..]);
    try w.writeAll("\"");
}

/// Write a `["a","b",...]` JSON array of RFC-8259-escaped strings to `w`.
pub fn jsonStringArray(w: *std.Io.Writer, items: []const []const u8) !void {
    try w.writeAll("[");
    for (items, 0..) |item, i| {
        if (i != 0) try w.writeAll(",");
        try jsonStr(w, item);
    }
    try w.writeAll("]");
}

/// Write the `,"time_ms":N` suffix used by `--json` commands; `start_ts` is a `milliTimestamp()`.
pub fn jsonTimeSuffix(w: *std.Io.Writer, start_ts: i64) !void {
    const elapsed = std.Io.Clock.real.now(pkg_io).toMilliseconds() - start_ts;
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, ",\"time_ms\":{d}", .{elapsed}) catch return;
    try w.writeAll(s);
}

/// Write JSON to stdout
pub fn jsonOutput(allocator: std.mem.Allocator, value: anytype) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.json.Stringify.value(value, .{}, &aw.writer);
    try aw.writer.writeByte('\n');
    writeStdout(aw.written());
}

/// Closed vocabulary so call-site typos fail to compile. `@tagName` is
/// the wire-format string; `snake_case` matches the existing post_install
/// line so consumers can reuse one parser.
pub const NdjsonEvent = enum {
    // 9-step protocol on the bottle install path.
    lock_acquired,
    resolved,
    downloaded,
    extracted,
    stored,
    materialized,
    linked,
    recorded,
    install_complete,
    // Shared with --json's existing post_install summary line.
    post_install,
    // No-transition outcomes.
    would_install,
    already_installed,
    up_to_date,
    pinned,
};

/// Write one `{"event":...}\n` per state transition. No-op when ndjson
/// is off so the default and `--json` paths pay nothing.
///
/// `name` is omitted when empty (lock_acquired et al. are command-level);
/// `status` is omitted when null so consumers skip a `null` vs `missing`
/// branch. Overflowing events drop silently rather than fail the install.
/// `allocator` is unused — kept for parity with the other JSON helpers.
pub fn emitNdjsonEvent(
    allocator: std.mem.Allocator,
    event: NdjsonEvent,
    name: []const u8,
    status: ?[]const u8,
) void {
    _ = allocator;
    if (!ndjson) return;
    // Worst-case adversarial-escape name still fits in 1 KiB.
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(buf[0..]);
    w.writeAll("{\"event\":") catch return;
    jsonStr(&w, @tagName(event)) catch return;
    if (name.len > 0) {
        w.writeAll(",\"name\":") catch return;
        jsonStr(&w, name) catch return;
    }
    if (status) |s| {
        w.writeAll(",\"status\":") catch return;
        jsonStr(&w, s) catch return;
    }
    w.writeAll("}\n") catch return;
    writeStdout(w.buffered());
}

// `notice` is the "FYI / explanation" role — the prefix-only ANSI wrap
// matches info/warn/etc., the glyph is `!` (purple/violet via .notice),
// and `--quiet` suppresses it like every other informational line.
// Sister tests for the other prefix-line helpers live alongside the public
// API surface in tests/output_test.zig; these are kept inline because the
// helper is a thin wrapper over the already-tested writePrefixedLine.
test "notice wraps the magenta prefix and uses the circled-i glyph (dark + basic)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const prior_quiet = isQuiet();
    color.setForTest(true, true);
    color.setBackgroundForTest(color.Background.dark);
    color.setTruecolorForTest(false);
    setQuiet(false);
    beginStderrCapture(std.testing.allocator, &buf);
    defer {
        endStderrCapture();
        color.setForTest(null, null);
        color.setBackgroundForTest(null);
        color.setTruecolorForTest(null);
        setQuiet(prior_quiet);
    }

    notice("heads up", .{});
    try std.testing.expectEqualStrings("\x1b[35m  ⓘ \x1b[0mheads up\n", buf.items);
}

test "notice falls back to an info-style ASCII glyph when emoji and color are off" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const prior_quiet = isQuiet();
    color.setForTest(false, false);
    setQuiet(false);
    beginStderrCapture(std.testing.allocator, &buf);
    defer {
        endStderrCapture();
        color.setForTest(null, null);
        setQuiet(prior_quiet);
    }

    notice("plain notice", .{});
    try std.testing.expectEqualStrings("  i plain notice\n", buf.items);
}

// Regression: with NO_COLOR + MALT_NO_EMOJI both lines used to render
// bytewise-identical `  ! <msg>` — pinning the divergence keeps CI logs
// and minimalist terminals able to tell a passive notice from a warning.
test "notice and warn render bytewise-distinct lines with color and emoji off" {
    const prior_quiet = isQuiet();
    color.setForTest(false, false);
    setQuiet(false);
    defer {
        color.setForTest(null, null);
        setQuiet(prior_quiet);
    }

    var notice_buf: std.ArrayList(u8) = .empty;
    defer notice_buf.deinit(std.testing.allocator);
    beginStderrCapture(std.testing.allocator, &notice_buf);
    notice("same message", .{});
    endStderrCapture();

    var warn_buf: std.ArrayList(u8) = .empty;
    defer warn_buf.deinit(std.testing.allocator);
    beginStderrCapture(std.testing.allocator, &warn_buf);
    warn("same message", .{});
    endStderrCapture();

    try std.testing.expect(!std.mem.eql(u8, notice_buf.items, warn_buf.items));
}

test "notice is suppressed by --quiet" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const prior_quiet = isQuiet();
    color.setForTest(true, true);
    setQuiet(true);
    beginStderrCapture(std.testing.allocator, &buf);
    defer {
        endStderrCapture();
        color.setForTest(null, null);
        setQuiet(prior_quiet);
    }

    notice("hidden", .{});
    try std.testing.expectEqualStrings("", buf.items);
}

test "isNdjson defaults to false and setNdjson toggles it" {
    const prior = isNdjson();
    defer setNdjson(prior);

    setNdjson(false);
    try std.testing.expect(!isNdjson());
    setNdjson(true);
    try std.testing.expect(isNdjson());
}

// Concurrent producers stress: a missing lock around the buffer's
// `ArrayList.append` raced two simultaneous workers and tripped an
// allocator assertion. 8 threads × 64 events is enough to surface
// it on plain x86/arm64 within microseconds.
test "pushPostInstallEvent serialises concurrent producers" {
    resetPostInstallEvents();
    setPostInstallEmit(.embed, std.testing.allocator);
    defer resetPostInstallEvents();

    const Worker = struct {
        const events_per_thread: usize = 64;
        fn run(thread_id: usize) void {
            var buf: [64]u8 = undefined;
            var i: usize = 0;
            while (i < events_per_thread) : (i += 1) {
                const json = std.fmt.bufPrint(
                    &buf,
                    "{{\"name\":\"t{d}-{d}\",\"status\":\"completed\",\"entries\":[]}}",
                    .{ thread_id, i },
                ) catch return;
                pushPostInstallEvent(json) catch return;
            }
        }
    };

    const thread_count: usize = 8;
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*th, idx| {
        th.* = try std.Thread.spawn(.{}, Worker.run, .{idx});
    }
    for (&threads) |th| th.join();

    const drained = drainPostInstallEvents();
    try std.testing.expectEqual(thread_count * Worker.events_per_thread, drained.len);
}

// Concurrent emit stress for `writePrefixedLine`. Without serialisation
// the helper's 4-write sequence (ANSI prefix, glyph, reset, msg, newline)
// races the test capture's `appendSlice` and tears another worker's line
// in two — exactly the parallel-migrate symptom. 8 threads × 64 lines
// surfaces it on plain x86/arm64 within microseconds.
test "writePrefixedLine serialises concurrent prefix+msg writes" {
    const prior_quiet = isQuiet();
    color.setForTest(true, true);
    color.setBackgroundForTest(color.Background.dark);
    color.setTruecolorForTest(false);
    setQuiet(false);
    defer {
        color.setForTest(null, null);
        color.setBackgroundForTest(null);
        color.setTruecolorForTest(null);
        setQuiet(prior_quiet);
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    beginStderrCapture(std.testing.allocator, &buf);
    defer endStderrCapture();

    const Worker = struct {
        const events_per_thread: usize = 64;
        fn run(thread_id: usize) void {
            var i: usize = 0;
            while (i < events_per_thread) : (i += 1) {
                warn("t{d}-i{d}", .{ thread_id, i });
            }
        }
    };

    const thread_count: usize = 8;
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*th, idx| {
        th.* = try std.Thread.spawn(.{}, Worker.run, .{idx});
    }
    for (&threads) |th| th.join();

    const expected_prefix = "\x1b[33m  ⚠ \x1b[0mt";
    var line_count: usize = 0;
    var it = std.mem.splitScalar(u8, buf.items, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        line_count += 1;
        try std.testing.expect(std.mem.startsWith(u8, line, expected_prefix));
    }
    try std.testing.expectEqual(thread_count * Worker.events_per_thread, line_count);
}

// Pins the public mode contract so the @atomicLoad/@atomicStore pair
// can't silently revert to a plain read: workers in routePostInstallOutcome
// query this on every keg, and a stale read before reset would leak
// post_install lines into stdout outside the summary doc.
test "postInstallEmit reflects the most recent setPostInstallEmit value" {
    resetPostInstallEvents();
    defer resetPostInstallEvents();

    try std.testing.expectEqual(PostInstallEmit.stream, postInstallEmit());

    setPostInstallEmit(.embed, std.testing.allocator);
    try std.testing.expectEqual(PostInstallEmit.embed, postInstallEmit());

    resetPostInstallEvents();
    try std.testing.expectEqual(PostInstallEmit.stream, postInstallEmit());
}
