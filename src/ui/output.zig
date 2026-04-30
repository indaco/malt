//! malt — output module
//! Human + JSON output formatting.

const std = @import("std");
const color = @import("color.zig");
const io_mod = @import("io.zig");

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

/// Process-wide io seeded once from `main` via `setIo`. Defaults to
/// `debug_io` so tests that don't seed see deterministic, allocation-
/// free behaviour.
var pkg_io: std.Io = std.Options.debug_io;
var pkg_environ: std.process.Environ = .{ .block = .{ .slice = &[_:null]?[*:0]const u8{} } };

/// Seed the io/environ used by writes, isatty probes, and timestamps.
/// Called by `main` after `AppCtx` is built.
pub fn setRuntime(io: std.Io, environ: std.process.Environ) void {
    pkg_io = io;
    pkg_environ = environ;
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

fn writeStderr(bytes: []const u8) void {
    io_mod.stderrWriteAll(bytes);
}

fn writeStdout(bytes: []const u8) void {
    io_mod.stdoutWriteAll(bytes);
}

/// Shared implementation for info/warn/success/err. One concrete
/// function so the binary carries a single copy regardless of how
/// many call sites route through it.
fn writePrefixedLine(
    msg: []const u8,
    role: color.SemanticStyle,
    emoji_prefix: []const u8,
    plain_prefix: []const u8,
) void {
    const prefix: []const u8 = if (color.isEmojiEnabled()) emoji_prefix else plain_prefix;
    if (color.isColorEnabled()) {
        writeStderr(role.code());
        writeStderr(prefix);
        writeStderr(color.Style.reset.code());
    } else {
        writeStderr(prefix);
    }
    writeStderr(msg);
    writeStderr("\n");
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

test "isNdjson defaults to false and setNdjson toggles it" {
    const prior = isNdjson();
    defer setNdjson(prior);

    setNdjson(false);
    try std.testing.expect(!isNdjson());
    setNdjson(true);
    try std.testing.expect(isNdjson());
}
