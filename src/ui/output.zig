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

/// Print info message: "==> {msg}" in cyan
pub fn info(comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    const f = std.fs.File.stderr();
    const prefix: []const u8 = if (color.isEmojiEnabled()) "  ▸ " else "  > ";
    if (color.isColorEnabled()) {
        f.writeAll(color.Style.cyan.code()) catch {};
        f.writeAll(prefix) catch {};
        f.writeAll(color.Style.reset.code()) catch {};
    } else {
        f.writeAll(prefix) catch {};
    }
    f.writeAll(msg) catch {};
    f.writeAll("\n") catch {};
}

/// Print warning: "Warning: {msg}" in yellow
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    const f = std.fs.File.stderr();
    const prefix: []const u8 = if (color.isEmojiEnabled()) "  ⚠ " else "  ! ";
    if (color.isColorEnabled()) {
        f.writeAll(color.Style.yellow.code()) catch {};
        f.writeAll(prefix) catch {};
        f.writeAll(color.Style.reset.code()) catch {};
    } else {
        f.writeAll(prefix) catch {};
    }
    f.writeAll(msg) catch {};
    f.writeAll("\n") catch {};
}

/// Print success: "ok {msg}" in green to stderr
pub fn success(comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    const f = std.fs.File.stderr();
    const prefix: []const u8 = if (color.isEmojiEnabled()) "  ✓ " else "  * ";
    if (color.isColorEnabled()) {
        f.writeAll(color.Style.green.code()) catch {};
        f.writeAll(prefix) catch {};
        f.writeAll(color.Style.reset.code()) catch {};
    } else {
        f.writeAll(prefix) catch {};
    }
    f.writeAll(msg) catch {};
    f.writeAll("\n") catch {};
}

/// Print error: "Error: {msg}" in red to stderr
pub fn err(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    const f = std.fs.File.stderr();
    const prefix: []const u8 = if (color.isEmojiEnabled()) "  ✗ " else "  x ";
    if (color.isColorEnabled()) {
        f.writeAll(color.Style.red.code()) catch {};
        f.writeAll(prefix) catch {};
        f.writeAll(color.Style.reset.code()) catch {};
    } else {
        f.writeAll(prefix) catch {};
    }
    f.writeAll(msg) catch {};
    f.writeAll("\n") catch {};
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
