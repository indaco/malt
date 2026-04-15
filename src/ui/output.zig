//! malt — output module
//! Human + JSON output formatting.

const std = @import("std");
const color = @import("color.zig");

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
    const f = std.fs.File.stderr();
    const prefix: []const u8 = if (color.isEmojiEnabled()) emoji_prefix else plain_prefix;
    if (color.isColorEnabled()) {
        f.writeAll(style.code()) catch {};
        f.writeAll(prefix) catch {};
        f.writeAll(color.Style.reset.code()) catch {};
    } else {
        f.writeAll(prefix) catch {};
    }
    f.writeAll(msg) catch {};
    f.writeAll("\n") catch {};
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
    const f = std.fs.File.stderr();
    if (style != null and color.isColorEnabled()) {
        f.writeAll(style.?.code()) catch {};
        f.writeAll(msg) catch {};
        f.writeAll(color.Style.reset.code()) catch {};
    } else {
        f.writeAll(msg) catch {};
    }
    f.writeAll("\n") catch {};
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
    const f = std.fs.File.stderr();
    const prefix: []const u8 = if (color.isEmojiEnabled()) "  ▸ " else "  > ";
    if (color.isColorEnabled()) {
        f.writeAll(color.Style.dim.code()) catch {};
        f.writeAll(prefix) catch {};
        f.writeAll(msg) catch {};
        f.writeAll(color.Style.reset.code()) catch {};
    } else {
        f.writeAll(prefix) catch {};
        f.writeAll(msg) catch {};
    }
    f.writeAll("\n") catch {};
}

/// Read a single line from stdin and return true iff the trimmed input
/// matches `expected` exactly.  Prints `prompt` to stderr first.
///
/// Returns false when stdin is not a TTY so that destructive commands
/// refuse to run unattended without an explicit `--yes` opt-in.
pub fn confirmTyped(expected: []const u8, prompt: []const u8) bool {
    if (!std.posix.isatty(std.posix.STDIN_FILENO)) return false;

    const f = std.fs.File.stderr();
    if (color.isColorEnabled()) {
        f.writeAll(color.Style.bold.code()) catch {};
        f.writeAll(prompt) catch {};
        f.writeAll(color.Style.reset.code()) catch {};
    } else {
        f.writeAll(prompt) catch {};
    }

    var buf: [128]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return false;
    if (n == 0) return false;
    const input = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return std.mem.eql(u8, input, expected);
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
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);
    std.json.stringify(value, .{}, list.writer(allocator)) catch |e| return e;
    list.append(allocator, '\n') catch |e| return e;
    const f = std.fs.File.stdout();
    f.writeAll(list.items) catch {};
}
