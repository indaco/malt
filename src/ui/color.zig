//! malt — color module
//! Terminal color output (NO_COLOR aware).

const std = @import("std");

pub const Style = enum {
    reset,
    bold,
    dim,
    red,
    green,
    yellow,
    blue,
    cyan,
    white,
};

/// Returns styled text for terminal output. Stub: returns text as-is.
pub fn paint(style: Style, text: []const u8) []const u8 {
    _ = style;
    return text;
}

/// Checks whether color output is enabled by inspecting the NO_COLOR env var.
pub fn isColorEnabled() bool {
    const val = std.posix.getenv("NO_COLOR");
    return val == null;
}
