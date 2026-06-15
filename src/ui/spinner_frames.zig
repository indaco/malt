//! malt — shared braille spinner frames.
//!
//! One source of truth for the spinner animation, imported by both the CLI
//! progress UI (`ui/progress.zig`) and the `mt tui` leaf so the two surfaces can
//! never drift. Data only — no terminal I/O, no allocation — so the TUI leaf may
//! import it without breaking its leaf contract (it is whitelisted in the purity
//! guard alongside `ui/color` and `ui/termsize`).

/// Braille-pattern spinner frames, advanced one index per render tick. Each is a
/// single display glyph (3 UTF-8 bytes), so a caller paints one cell per frame.
pub const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

/// The frame count, exposed so callers index with `% spinner_frames.count`
/// without reaching into `frames.len` at every site.
pub const count = frames.len;

test "the frame table is non-empty and every entry is one braille glyph" {
    const std = @import("std");
    try std.testing.expect(count != 0);
    try std.testing.expectEqual(frames.len, count);
    for (frames) |f| {
        // Braille Pattern code points are 3 bytes in UTF-8; one glyph per frame
        // keeps the spinner a single fixed cell as it animates.
        try std.testing.expectEqual(@as(usize, 3), f.len);
    }
}
