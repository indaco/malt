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

    pub fn code(self: Style) []const u8 {
        return switch (self) {
            .reset => "\x1b[0m",
            .bold => "\x1b[1m",
            .dim => "\x1b[2m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .blue => "\x1b[34m",
            .cyan => "\x1b[36m",
            .white => "\x1b[37m",
        };
    }
};

var color_enabled: ?bool = null;
var emoji_enabled: ?bool = null;

pub fn isColorEnabled() bool {
    if (color_enabled) |v| return v;
    // Check NO_COLOR env var AND whether stderr is a tty
    const no_color = std.posix.getenv("NO_COLOR");
    const is_tty = std.posix.isatty(std.posix.STDERR_FILENO);
    const result = no_color == null and is_tty;
    color_enabled = result;
    return result;
}

pub fn isEmojiEnabled() bool {
    if (emoji_enabled) |v| return v;
    const no_emoji = std.posix.getenv("MALT_NO_EMOJI");
    const result = no_emoji == null;
    emoji_enabled = result;
    return result;
}

/// Write styled text to stderr. If colors disabled, writes text only.
pub fn styled(style: Style, text: []const u8) void {
    const f = std.fs.File.stderr();
    if (isColorEnabled()) {
        f.writeAll(style.code()) catch {};
        f.writeAll(text) catch {};
        f.writeAll(Style.reset.code()) catch {};
    } else {
        f.writeAll(text) catch {};
    }
}
