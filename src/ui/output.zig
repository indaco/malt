//! malt — output module
//! Human + JSON output formatting.

const std = @import("std");
/// Process-wide io seeded once from `main` via `setRuntime`. Defaults to
/// `debug_io` so tests that don't seed see deterministic, allocation-
/// free behaviour.
var pkg_io: std.Io = std.Options.debug_io;
const builtin = @import("builtin");

const color = @import("color.zig");

pub const OutputMode = enum {
    human,
    json,
};

/// Seeded by argv parsing in `main` before any worker thread spawns and
/// not flipped afterwards, so plain reads/writes stay race-free. Mutators
/// that need a runtime flip must migrate the flag (and every reader) to
/// `@atomicLoad`/`@atomicStore`, matching `post_install_emit` below.
var quiet: bool = false;
var verbose: bool = false;
var debug: bool = false;
var dry_run: bool = false;
var mode: OutputMode = .human;
/// Orthogonal to `mode`/`--json` so CI can stream per-step events
/// without losing the final summary.
var ndjson: bool = false;

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
/// `writePrefixLine` sequence (via `writeStderrUnlocked`).
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

fn writeStdout(bytes: []const u8) void {
    writeStdoutAll(bytes);
}

/// Closed vocabulary of the prefix-line variants. The comptime table
/// below drives one shared `writePrefixLine` body so the seven public
/// helpers each shrink to a tiny bufPrint + one call.
const PrefixLineKind = enum { info, warn, success, err, notice, dim, skip };

/// `.prefix_wrap` wraps only the glyph in role colour and leaves the
/// message bare (info/warn/success/err/notice). `.line_wrap` wraps the
/// whole `prefix + msg` in a single ANSI block so the line recedes
/// visually as a unit (dim/skip).
const PrefixLineShape = enum { prefix_wrap, line_wrap };

const PrefixLineSpec = struct {
    role: color.SemanticStyle,
    emoji_prefix: []const u8,
    plain_prefix: []const u8,
    shape: PrefixLineShape,
    /// Errors always print; everything else hides under `--quiet`.
    respect_quiet: bool,
};

fn prefixLineSpec(comptime kind: PrefixLineKind) PrefixLineSpec {
    return switch (kind) {
        .info => .{ .role = .info, .emoji_prefix = "  ▸ ", .plain_prefix = "  > ", .shape = .prefix_wrap, .respect_quiet = true },
        .warn => .{ .role = .warn, .emoji_prefix = "  ⚠ ", .plain_prefix = "  ! ", .shape = .prefix_wrap, .respect_quiet = true },
        .success => .{ .role = .success, .emoji_prefix = "  ✓ ", .plain_prefix = "  * ", .shape = .prefix_wrap, .respect_quiet = true },
        .err => .{ .role = .err, .emoji_prefix = "  ✗ ", .plain_prefix = "  x ", .shape = .prefix_wrap, .respect_quiet = false },
        .notice => .{ .role = .notice, .emoji_prefix = "  ⓘ ", .plain_prefix = "  i ", .shape = .prefix_wrap, .respect_quiet = true },
        .dim => .{ .role = .detail, .emoji_prefix = "  ▸ ", .plain_prefix = "  > ", .shape = .line_wrap, .respect_quiet = true },
        .skip => .{ .role = .detail, .emoji_prefix = "  · ", .plain_prefix = "  . ", .shape = .line_wrap, .respect_quiet = true },
    };
}

/// Single copy of the write sequence in the binary. Picks the emoji-
/// vs-plain prefix and the role colour here so each public wrapper
/// stays tiny. Locks once around the full multi-write so a concurrent
/// worker can't slot its own prefix between this line's prefix and
/// message.
fn writePrefixLine(
    role: color.SemanticStyle,
    emoji_prefix: []const u8,
    plain_prefix: []const u8,
    shape: PrefixLineShape,
    msg: []const u8,
) void {
    const prefix: []const u8 = if (color.isEmojiEnabled()) emoji_prefix else plain_prefix;
    const colorize = color.isColorEnabled();
    lockStderr();
    defer unlockStderr();
    switch (shape) {
        .prefix_wrap => {
            if (colorize) {
                writeStderrUnlocked(role.code());
                writeStderrUnlocked(prefix);
                writeStderrUnlocked(color.Style.reset.code());
            } else {
                writeStderrUnlocked(prefix);
            }
            writeStderrUnlocked(msg);
        },
        .line_wrap => {
            if (colorize) {
                writeStderrUnlocked(role.code());
                writeStderrUnlocked(prefix);
                writeStderrUnlocked(msg);
                writeStderrUnlocked(color.Style.reset.code());
            } else {
                writeStderrUnlocked(prefix);
                writeStderrUnlocked(msg);
            }
        },
    }
    writeStderrUnlocked("\n");
}

/// Comptime spec lookup + bufPrint specialised per `fmt`. The kind
/// resolves at comptime so each public wrapper compiles to a tiny
/// bufPrint + one call into `writePrefixLine`.
inline fn emitPrefixLine(
    comptime kind: PrefixLineKind,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const spec = comptime prefixLineSpec(kind);
    if (spec.respect_quiet and quiet) return;
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writePrefixLine(spec.role, spec.emoji_prefix, spec.plain_prefix, spec.shape, msg);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    emitPrefixLine(.info, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    emitPrefixLine(.warn, fmt, args);
}

pub fn success(comptime fmt: []const u8, args: anytype) void {
    emitPrefixLine(.success, fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    emitPrefixLine(.err, fmt, args);
}

/// "FYI / explanation" line — a passive heads-up that is neither a warning
/// nor a failure. The notice glyph (`ⓘ` / `i`) stays distinct from
/// `warn`'s `⚠`/`!` on every (color, emoji) combination, including
/// NO_COLOR + MALT_NO_EMOJI.
pub fn notice(comptime fmt: []const u8, args: anytype) void {
    emitPrefixLine(.notice, fmt, args);
}

/// Print a confirmation prompt: info-coloured `?` icon, bold message,
/// no trailing newline so the user's typed answer continues the line.
/// Bypasses `--quiet` — a silent prompt would deadlock interactive flows.
pub fn question(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    const prefix: []const u8 = if (color.isEmojiEnabled()) "  ? " else "  ? ";
    const colorize = color.isColorEnabled();
    lockStderr();
    defer unlockStderr();
    if (colorize) {
        writeStderrUnlocked(color.SemanticStyle.info.code());
        writeStderrUnlocked(prefix);
        writeStderrUnlocked(color.Style.reset.code());
        writeStderrUnlocked(color.Style.bold.code());
        writeStderrUnlocked(msg);
        writeStderrUnlocked(color.Style.reset.code());
    } else {
        writeStderrUnlocked(prefix);
        writeStderrUnlocked(msg);
    }
}

/// Write a single styled line (no icon prefix). Pass null `style_code`
/// for plain text. Respects `--quiet`.
fn lineStyled(style_code: ?[]const u8, comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    const colorize = color.isColorEnabled();
    lockStderr();
    defer unlockStderr();
    if (style_code) |code| {
        if (colorize) {
            writeStderrUnlocked(code);
            writeStderrUnlocked(msg);
            writeStderrUnlocked(color.Style.reset.code());
        } else {
            writeStderrUnlocked(msg);
        }
    } else {
        writeStderrUnlocked(msg);
    }
    writeStderrUnlocked("\n");
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
    emitPrefixLine(.dim, fmt, args);
}

/// Dim "nothing to do" status line (e.g. already-at-latest). The bullet
/// glyph makes it recede next to `▸` activity lines in bulk commands.
pub fn skip(comptime fmt: []const u8, args: anytype) void {
    emitPrefixLine(.skip, fmt, args);
}

/// True only when `file` is an interactive terminal. A probe error is
/// treated as non-interactive so an escalation gated on this refuses to
/// proceed unattended. Kept file-parameterised so tests can drive it
/// against a pipe without a real TTY.
fn isInteractive(file: std.Io.File, io: std.Io) bool {
    return file.isTty(io) catch false;
}

/// True when stdin is an interactive terminal. PKG-cask install probes this
/// before escalating to `sudo`, whose password read stalls off a TTY.
pub fn stdinIsInteractive() bool {
    const stdin_file: std.Io.File = .{ .handle = std.posix.STDIN_FILENO, .flags = .{ .nonblocking = false } };
    return isInteractive(stdin_file, pkg_io);
}

/// Read a single line from stdin and return true iff the trimmed input
/// matches `expected` exactly. Prints `prompt` via `question` first.
///
/// Returns false when stdin is not a TTY so that destructive commands
/// refuse to run unattended without an explicit `--yes` opt-in.
pub fn confirmTyped(expected: []const u8, prompt: []const u8) bool {
    const stdin_file: std.Io.File = .{ .handle = std.posix.STDIN_FILENO, .flags = .{ .nonblocking = false } };
    if (!isInteractive(stdin_file, pkg_io)) return false;

    question("{s}", .{prompt});
    return readMatchingLine(stdin_file, pkg_io, expected);
}

/// Helper kept separate so tests can drive the read path against a pipe
/// without needing a real TTY; routing the read through `io` matches the
/// `isTty` probe and lets `AppCtx.io` redirection observe stdin.
fn readMatchingLine(stdin_file: std.Io.File, io: std.Io, expected: []const u8) bool {
    var buf: [128]u8 = undefined;
    const n = stdin_file.readStreaming(io, &.{buf[0..]}) catch return false;
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

/// Version stamped on every read command's `--json` root (`list`, `info`,
/// `outdated`, `services`, `doctor`). Bump when a documented field shape
/// changes so consumers can refuse a shape they don't understand —
/// documented in `docs/json-schema.md`.
pub const json_schema_version: u32 = 1;

/// Write the opening `{"schema_version":N,` of a versioned `--json` root.
/// The caller appends its own fields and the closing `}`. Centralises the
/// version so a bump touches one constant, not every read command.
pub fn writeSchemaVersionPrefix(w: *std.Io.Writer) !void {
    try w.print("{{\"schema_version\":{d},", .{json_schema_version});
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
    // Bracketing pair for the `--download-only` warm-cache path. Distinct
    // from `.downloaded` so consumers (CI pipelines, Docker layer warmers)
    // can time per-bottle work without conflating it with the install-time
    // emit shape.
    download_started,
    download_complete,
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
pub fn emitNdjsonEvent(
    event: NdjsonEvent,
    name: []const u8,
    status: ?[]const u8,
) void {
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
// helper is a thin wrapper over the shared `emitPrefixLine`.
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

test "writeSchemaVersionPrefix opens a versioned object root" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeSchemaVersionPrefix(&aw.writer);
    try std.testing.expectEqualStrings("{\"schema_version\":1,", aw.written());
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

// Concurrent emit stress for `writePrefixLine`. Without serialisation
// the helper's 4-write sequence (ANSI prefix, glyph, reset, msg, newline)
// races the test capture's `appendSlice` and tears another worker's line
// in two — exactly the parallel-migrate symptom. 8 threads × 64 lines
// surfaces it on plain x86/arm64 within microseconds.
test "writePrefixLine serialises concurrent prefix+msg writes" {
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

// Sister coverage for the prefix-then-msg-then-reset shape that `dim`
// and `skip` (and via `lineStyled` the `*Plain` family) emit. A racing
// `appendSlice` on the test capture or a torn ANSI wrap was the same
// failure mode the prefixed-line test pins; this one exercises a
// different write order so an asymmetric regression can't slip past.
test "dim serialises concurrent prefix+msg+reset writes" {
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
                dim("t{d}-i{d}", .{ thread_id, i });
            }
        }
    };

    const thread_count: usize = 8;
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*th, idx| {
        th.* = try std.Thread.spawn(.{}, Worker.run, .{idx});
    }
    for (&threads) |th| th.join();

    const expected_open = "\x1b[2m  ▸ t";
    const expected_close = "\x1b[0m";
    var line_count: usize = 0;
    var it = std.mem.splitScalar(u8, buf.items, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        line_count += 1;
        try std.testing.expect(std.mem.startsWith(u8, line, expected_open));
        try std.testing.expect(std.mem.endsWith(u8, line, expected_close));
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

// Drives the read path through the seeded io against a pipe so the
// `confirmTyped` accept/reject contract — including EOF — is pinned
// without relying on a real TTY.
fn pipeForTest() ![2]std.c.fd_t {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    return fds;
}

test "readMatchingLine accepts trimmed input that matches expected" {
    const fds = try pipeForTest();
    defer _ = std.c.close(fds[0]);

    const msg = "yes\n";
    const written = std.c.write(fds[1], msg.ptr, msg.len);
    try std.testing.expectEqual(@as(isize, msg.len), written);
    _ = std.c.close(fds[1]);

    const stdin_file: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    try std.testing.expect(readMatchingLine(stdin_file, std.Options.debug_io, "yes"));
}

test "readMatchingLine rejects mismatched input" {
    const fds = try pipeForTest();
    defer _ = std.c.close(fds[0]);

    const msg = "no\n";
    _ = std.c.write(fds[1], msg.ptr, msg.len);
    _ = std.c.close(fds[1]);

    const stdin_file: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    try std.testing.expect(!readMatchingLine(stdin_file, std.Options.debug_io, "yes"));
}

test "readMatchingLine returns false when stdin is at EOF" {
    const fds = try pipeForTest();
    defer _ = std.c.close(fds[0]);
    _ = std.c.close(fds[1]);

    const stdin_file: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    try std.testing.expect(!readMatchingLine(stdin_file, std.Options.debug_io, "yes"));
}

// A pipe is never a terminal, so the PKG-cask sudo gate must classify it as
// non-interactive and refuse escalation — the safety-critical direction: a
// false positive here would let `sudo installer -target /` run unattended.
test "isInteractive treats a non-terminal stdin as non-interactive" {
    const fds = try pipeForTest();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    const stdin_file: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    try std.testing.expect(!isInteractive(stdin_file, std.Options.debug_io));
}

// A probe error (here: a closed fd) must fail safe to non-interactive so the
// sudo gate never proceeds on an ambiguous result.
test "isInteractive fails safe to non-interactive when the tty probe errors" {
    const fds = try pipeForTest();
    _ = std.c.close(fds[0]);
    _ = std.c.close(fds[1]);

    const closed_file: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    try std.testing.expect(!isInteractive(closed_file, std.Options.debug_io));
}

extern "c" fn openpty(amaster: *c_int, aslave: *c_int, name: ?[*]u8, termp: ?*anyopaque, winp: ?*anyopaque) c_int;

// The positive direction: a real terminal (a pty slave) must read as
// interactive. Without this only the refusal path is covered, so a probe
// broken to always report non-interactive would ship green yet make every
// PKG-cask install/upgrade/rollback impossible.
test "isInteractive treats a pty slave as interactive" {
    var master: c_int = undefined;
    var slave: c_int = undefined;
    if (openpty(&master, &slave, null, null, null) != 0) return error.SkipZigTest;
    defer _ = std.c.close(master);
    defer _ = std.c.close(slave);

    const slave_file: std.Io.File = .{ .handle = slave, .flags = .{ .nonblocking = false } };
    try std.testing.expect(isInteractive(slave_file, std.Options.debug_io));
}
