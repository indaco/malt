//! malt — reusable detail pane for `mt tui`.
//!
//! Leaf module. A pure renderer over a *generic* field list — `{label, value}`
//! pairs — so every tab (Installed now; Outdated / Services / Doctor later)
//! feeds it whatever fields it has instead of a list-specific shape. Paints one
//! `label: value` line per field into its rectangle, width-truncated and clipped
//! to the rect height, through `Frame.putContent` so untrusted child values
//! can't break the frame. Pure function of `(fields, rect)` → reflows on resize.

const std = @import("std");
const tab = @import("tab.zig");
const scroll_list = @import("scroll_list.zig");

/// One labelled row. `value` is a single line; a multi-valued field (e.g. a
/// dependency list) is pre-joined by the caller so the pane stays generic.
pub const Field = struct {
    label: []const u8,
    value: []const u8,
};

/// Paint `fields` into `rect`, one `label: value` line each, top-aligned. Lines
/// past `rect.height` are clipped; each line is width-truncated to `rect.width`.
pub fn render(f: *tab.Frame, fields: []const Field, rect: tab.Rect) void {
    for (fields, 0..) |field, i| {
        if (i >= rect.height) break; // clip to the pane height
        f.moveTo(rect.row + @as(u16, @intCast(i)), rect.col);
        var buf: [256]u8 = undefined;
        f.putContent(scroll_list.truncate(line(&buf, field), rect.width));
    }
}

/// Compose `"label: value"` into `buf`, bounded — a value longer than the
/// scratch is cut, never overflowed (the pane re-truncates to width anyway).
fn line(buf: []u8, field: Field) []const u8 {
    var len: usize = 0;
    appendInto(buf, &len, field.label);
    appendInto(buf, &len, ": ");
    appendInto(buf, &len, field.value);
    return buf[0..len];
}

fn appendInto(buf: []u8, len: *usize, s: []const u8) void {
    const n = @min(s.len, buf.len - len.*);
    @memcpy(buf[len.*..][0..n], s[0..n]);
    len.* += n;
}

// ─── tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "render paints one label: value line per field at its row" {
    var fb: [512]u8 = undefined;
    var f: tab.Frame = .{ .buf = &fb };
    const fields = [_]Field{
        .{ .label = "Tap", .value = "homebrew/core" },
        .{ .label = "Pinned", .value = "yes" },
    };
    render(&f, &fields, .{ .row = 3, .col = 1, .width = 40, .height = 10 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "Tap: homebrew/core") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Pinned: yes") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[3;1H") != null); // first field row
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[4;1H") != null); // second field row
}

test "render clips fields past the pane height" {
    var fb: [512]u8 = undefined;
    var f: tab.Frame = .{ .buf = &fb };
    const fields = [_]Field{
        .{ .label = "A", .value = "1" },
        .{ .label = "B", .value = "2" },
        .{ .label = "C", .value = "3" },
    };
    render(&f, &fields, .{ .row = 1, .col = 1, .width = 40, .height = 2 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "A: 1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "B: 2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "C: 3") == null); // clipped
}

test "render width-truncates a long value to the pane width" {
    var fb: [512]u8 = undefined;
    var f: tab.Frame = .{ .buf = &fb };
    const fields = [_]Field{.{ .label = "Deps", .value = "brotli, zstd, openssl@3, libssh2" }};
    render(&f, &fields, .{ .row = 1, .col = 1, .width = 10, .height = 1 });
    // "Deps: brot" — 10 visible columns, no more.
    try testing.expect(std.mem.indexOf(u8, f.slice(), "Deps: brot") != null);
    try testing.expect(std.mem.indexOf(u8, f.slice(), "openssl") == null);
}

test "render of an embedded newline value cannot inject a frame line" {
    var fb: [512]u8 = undefined;
    var f: tab.Frame = .{ .buf = &fb };
    const fields = [_]Field{.{ .label = "X", .value = "a\nb" }};
    render(&f, &fields, .{ .row = 1, .col = 1, .width = 40, .height = 4 });
    // The newline is dropped by putContent, so the value collapses to one line.
    try testing.expect(std.mem.indexOf(u8, f.slice(), "X: ab") != null);
}
