//! malt — Brewfile emitter (Manifest → Brewfile text)

const std = @import("std");
const manifest_mod = @import("manifest.zig");

/// Write `s` as a double-quoted Ruby string. Brewfile is line-based, so `"`,
/// `\` and the whitespace controls `\n`/`\r`/`\t` are escaped — `\n`/`\r` must
/// be, to keep the value on one line, and `\t` is for clean output; the parser's
/// `expectString` decodes exactly these back. Rarer control bytes still
/// round-trip as raw bytes through the line parser, so they are left as-is.
fn writeRubyString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    var start: usize = 0;
    for (s, 0..) |byte, i| {
        const esc: ?[]const u8 = switch (byte) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => null,
        };
        if (esc) |e| {
            if (i > start) try w.writeAll(s[start..i]);
            try w.writeAll(e);
            start = i + 1;
        }
    }
    if (start < s.len) try w.writeAll(s[start..]);
    try w.writeByte('"');
}

pub fn emit(manifest: manifest_mod.Manifest, writer: *std.Io.Writer) !void {
    for (manifest.taps) |t| {
        try writer.writeAll("tap ");
        try writeRubyString(writer, t);
        try writer.writeAll("\n");
    }
    for (manifest.formulas) |f| {
        try writer.writeAll("brew ");
        try writeRubyString(writer, f.name);
        if (f.version) |v| {
            try writer.writeAll(", version: ");
            try writeRubyString(writer, v);
        }
        if (f.restart_service) try writer.writeAll(", restart_service: true");
        try writer.writeAll("\n");
    }
    for (manifest.casks) |c| {
        try writer.writeAll("cask ");
        try writeRubyString(writer, c.name);
        try writer.writeAll("\n");
    }
}
