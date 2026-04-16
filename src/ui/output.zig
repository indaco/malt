//! malt — output module
//! Human + JSON output formatting.

const std = @import("std");
const color = @import("color.zig");
const io_mod = @import("io.zig");
const fs_compat = @import("../fs/compat.zig");

pub const OutputMode = enum {
    human,
    json,
};

var quiet: bool = false;
var verbose: bool = false;
var dry_run: bool = false;
var mode: OutputMode = .human;

pub fn setQuiet(q: bool) void {
    quiet = q;
}
pub fn setVerbose(v: bool) void {
    verbose = v;
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
pub fn isDryRun() bool {
    return dry_run;
}
pub fn isJson() bool {
    return mode == .json;
}

/// Shared implementation for info/warn/success/err. Takes an already-formatted
/// message slice so this function is concrete (non-generic) — a single copy
/// ends up in the binary regardless of how many call sites exist. Passing a
/// generic `anytype` body through here instead would monomorphize per caller
/// and roughly double the emitted code.
fn writePrefixedLine(
    msg: []const u8,
    style: color.Style,
    emoji_prefix: []const u8,
    plain_prefix: []const u8,
) void {
    const prefix: []const u8 = if (color.isEmojiEnabled()) emoji_prefix else plain_prefix;
    if (color.isColorEnabled()) {
        io_mod.stderrWriteAll(style.code());
        io_mod.stderrWriteAll(prefix);
        io_mod.stderrWriteAll(color.Style.reset.code());
    } else {
        io_mod.stderrWriteAll(prefix);
    }
    io_mod.stderrWriteAll(msg);
    io_mod.stderrWriteAll("\n");
}

/// Print info message: "==> {msg}" in cyan
pub fn info(comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writePrefixedLine(msg, color.Style.cyan, "  ▸ ", "  > ");
}

/// Print warning: "Warning: {msg}" in yellow
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writePrefixedLine(msg, color.Style.yellow, "  ⚠ ", "  ! ");
}

/// Print success: "ok {msg}" in green to stderr
pub fn success(comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writePrefixedLine(msg, color.Style.green, "  ✓ ", "  * ");
}

/// Print error: "Error: {msg}" in red to stderr
pub fn err(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writePrefixedLine(msg, color.Style.red, "  ✗ ", "  x ");
}

/// Internal: write a single styled line to stderr with no icon prefix.
/// `style` is `null` for plain text. Respects `--quiet`.
fn lineStyled(style: ?color.Style, comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    if (style != null and color.isColorEnabled()) {
        io_mod.stderrWriteAll(style.?.code());
        io_mod.stderrWriteAll(msg);
        io_mod.stderrWriteAll(color.Style.reset.code());
    } else {
        io_mod.stderrWriteAll(msg);
    }
    io_mod.stderrWriteAll("\n");
}

/// Yellow line with no prefix — for multi-line warning blocks (banners,
/// tables) where a repeated `⚠` icon is more noise than signal.
pub fn warnPlain(comptime fmt: []const u8, args: anytype) void {
    lineStyled(.yellow, fmt, args);
}

/// Plain (un-styled, un-prefixed) line — for body text in multi-line
/// output where color would compete with a warning block above it.
pub fn plain(comptime fmt: []const u8, args: anytype) void {
    lineStyled(null, fmt, args);
}

/// Dim/faint line with no prefix — for low-priority context lines.
pub fn dimPlain(comptime fmt: []const u8, args: anytype) void {
    lineStyled(.dim, fmt, args);
}

/// Bold line with no prefix — for headline values (totals, summaries).
pub fn boldPlain(comptime fmt: []const u8, args: anytype) void {
    lineStyled(.bold, fmt, args);
}

/// Print a dim/faint info message for low-priority status lines.
pub fn dim(comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    const prefix: []const u8 = if (color.isEmojiEnabled()) "  ▸ " else "  > ";
    if (color.isColorEnabled()) {
        io_mod.stderrWriteAll(color.Style.dim.code());
        io_mod.stderrWriteAll(prefix);
        io_mod.stderrWriteAll(msg);
        io_mod.stderrWriteAll(color.Style.reset.code());
    } else {
        io_mod.stderrWriteAll(prefix);
        io_mod.stderrWriteAll(msg);
    }
    io_mod.stderrWriteAll("\n");
}

/// Read a single line from stdin and return true iff the trimmed input
/// matches `expected` exactly.  Prints `prompt` to stderr first.
///
/// Returns false when stdin is not a TTY so that destructive commands
/// refuse to run unattended without an explicit `--yes` opt-in.
pub fn confirmTyped(expected: []const u8, prompt: []const u8) bool {
    if (!fs_compat.isatty(std.posix.STDIN_FILENO)) return false;

    if (color.isColorEnabled()) {
        io_mod.stderrWriteAll(color.Style.bold.code());
        io_mod.stderrWriteAll(prompt);
        io_mod.stderrWriteAll(color.Style.reset.code());
    } else {
        io_mod.stderrWriteAll(prompt);
    }

    var buf: [128]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return false;
    if (n == 0) return false;
    const input = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return std.mem.eql(u8, input, expected);
}

/// Write a dim `key:` prefix followed by padding so the value starts at
/// column `col`. Callers that need to emit a list (or any non-`bufPrint`
/// value) use this helper and then write the value themselves.
pub fn writeFieldKey(w: anytype, colorize: bool, col: usize, key: []const u8) !void {
    if (colorize) try w.writeAll(color.Style.dim.code());
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
    w: anytype,
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
///
/// Kept as `anytype` so it works with both the legacy `std.io.GenericWriter`
/// and the new `std.Io.Writer` interface; the common path is branch-free.
pub fn jsonStr(w: anytype, s: []const u8) !void {
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
            const hex = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{byte}) catch unreachable;
            try w.writeAll(hex);
            start = i + 1;
        }
    }
    if (start < s.len) try w.writeAll(s[start..]);
    try w.writeAll("\"");
}

/// Write JSON to stdout
pub fn jsonOutput(allocator: std.mem.Allocator, value: anytype) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.json.Stringify.value(value, .{}, &aw.writer);
    try aw.writer.writeByte('\n');
    io_mod.stdoutWriteAll(aw.written());
}
