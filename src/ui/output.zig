//! malt — output module
//! Human + JSON output formatting.

const std = @import("std");

pub const OutputMode = enum {
    human,
    json,
};

/// Prints an info line to stderr.
pub fn info(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const w = std.fs.File.stderr().writer(&buf);
    w.print("[INFO] " ++ fmt ++ "\n", args) catch {};
}

/// Prints a warning line to stderr.
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const w = std.fs.File.stderr().writer(&buf);
    w.print("[WARN] " ++ fmt ++ "\n", args) catch {};
}

/// Prints an error line to stderr.
pub fn err(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const w = std.fs.File.stderr().writer(&buf);
    w.print("[ERROR] " ++ fmt ++ "\n", args) catch {};
}

/// Serializes a value to JSON and writes it to stdout.
pub fn jsonOutput(value: anytype) !void {
    var buf: [4096]u8 = undefined;
    const w = std.fs.File.stdout().writer(&buf);
    try std.json.stringify(value, .{}, w);
    try w.writeByte('\n');
}
