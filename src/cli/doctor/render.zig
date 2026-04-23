//! malt — doctor row renderer.
//!
//! Pure rendering primitives for `mt doctor` check rows. Kept separate
//! from the walker so the glyph/colour invariants can be exercised
//! against a buffer writer in hermetic tests.

const std = @import("std");
const output = @import("../../ui/output.zig");
const color = @import("../../ui/color.zig");
const io_mod = @import("../../ui/io.zig");

pub const CheckStatus = enum { ok, warn_status, err_status };

pub const CheckStyle = struct {
    /// Emit ANSI colour codes. False for plain terminals and tests.
    color: bool,
    /// Use the ✓/⚠/✗ glyphs. False falls back to ASCII */!/x.
    emoji: bool,
};

fn glyphFor(status: CheckStatus, emoji: bool) []const u8 {
    return if (emoji) switch (status) {
        .ok => "✓",
        .warn_status => "⚠",
        .err_status => "✗",
    } else switch (status) {
        .ok => "*",
        .warn_status => "!",
        .err_status => "x",
    };
}

fn statusCode(status: CheckStatus) []const u8 {
    return switch (status) {
        .ok => color.SemanticStyle.success.code(),
        .warn_status => color.SemanticStyle.warn.code(),
        .err_status => color.SemanticStyle.err.code(),
    };
}

/// Render one check row. Pure (no stderr / global state), so tests
/// can drive it against a buffer writer and assert on the bytes.
pub fn renderCheckRow(
    writer: *std.Io.Writer,
    status: CheckStatus,
    name: []const u8,
    detail: ?[]const u8,
    style_opts: CheckStyle,
) !void {
    const glyph = glyphFor(status, style_opts.emoji);
    try writer.writeAll("  ");
    if (style_opts.color) {
        try writer.writeAll(statusCode(status));
        try writer.writeAll(glyph);
        try writer.writeAll(color.Style.reset.code());
    } else {
        try writer.writeAll(glyph);
    }
    try writer.writeAll(" ");
    try writer.writeAll(name);

    if (detail) |d| {
        if (style_opts.color) {
            try writer.writeAll(" ");
            try writer.writeAll(color.SemanticStyle.detail.code());
            try writer.writeAll("— ");
            try writer.writeAll(d);
            try writer.writeAll(color.Style.reset.code());
        } else {
            try writer.writeAll(" — ");
            try writer.writeAll(d);
        }
    }
    try writer.writeAll("\n");
}

pub fn printCheck(name: []const u8, status: CheckStatus, detail: ?[]const u8) void {
    if (output.isQuiet()) return;
    // `File.writer.flush` writes positionally from offset 0, overwriting
    // prior rows when stderr is a regular file; stream via `stderrWriteAll`.
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // Truncation of an oversized row is acceptable — `buffered()` still emits what fit.
    renderCheckRow(&w, status, name, detail, .{
        .color = color.isColorEnabled(),
        .emoji = color.isEmojiEnabled(),
    }) catch {};
    io_mod.stderrWriteAll(w.buffered());
}
