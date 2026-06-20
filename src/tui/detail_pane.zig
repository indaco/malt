//! malt — reusable detail pane for `mt tui`.
//!
//! Leaf module. A pure renderer over a *generic* field list — `{label, value}`
//! pairs — so every tab (Installed now; Outdated / Services / Doctor later)
//! feeds it whatever fields it has instead of a list-specific shape. Paints one
//! `label: value` line per field into its rectangle, width-truncated and clipped
//! to the rect height, through `Frame.putContent` so untrusted child values
//! can't break the frame. Pure function of `(fields, rect)` → reflows on resize.

const std = @import("std");
const color = @import("../ui/color.zig");
const tab = @import("tab.zig");
const text_wrap = @import("text_wrap.zig");

/// One labelled row. `value` is a single logical line; a multi-valued field
/// (e.g. a dependency list) is pre-joined by the caller so the pane stays
/// generic. A long value wraps across rows rather than being truncated.
pub const Field = struct {
    label: []const u8,
    value: []const u8,
};

// One dim rule sits at the top of the pane, marking where the list ends and the
// detail begins so the pane doesn't read as overlapping the list.
const separator_rows: u16 = 1;

/// Rows the pane needs to show its separator plus every field at `width` with
/// values wrapped, so a caller can size the split to the content.
pub fn neededRows(fields: []const Field, width: u16) u16 {
    var rows: u16 = separator_rows;
    for (fields) |field| {
        var it = wrapIter(field, width);
        var n: u16 = 0;
        while (it.next()) |_| n += 1;
        rows += @max(@as(u16, 1), n); // an empty value still takes the label row
    }
    return rows;
}

/// Paint a dim separator rule, then `fields`: a dim `label:` then its value, the
/// value wrapped across rows (continuations indented under it) so a long message
/// stays readable on a narrow pane instead of being cut off. Clipped to
/// `rect.height`, painted through `Frame.putContent` so untrusted child values
/// can't break the frame. Pure function of `(fields, rect)` → reflows on resize.
pub fn render(f: *tab.Frame, fields: []const Field, rect: tab.Rect) void {
    if (rect.width == 0 or rect.height == 0) return;
    tab.renderSeparator(f, rect, rect.row, true);
    renderFields(f, fields, .{ .row = rect.row + separator_rows, .col = rect.col, .width = rect.width, .height = rect.height -| separator_rows });
}

fn renderFields(f: *tab.Frame, fields: []const Field, rect: tab.Rect) void {
    var row: u16 = 0;
    for (fields) |field| {
        if (row >= rect.height) break;
        const indent = labelWidth(field);
        // The dim `label: ` sits on the field's first row; the value flows after.
        f.moveTo(rect.row + row, rect.col);
        f.put(color.roleCode(.muted));
        f.putContent(field.label);
        f.putContent(": ");
        f.put(color.Style.reset.code());

        var it = wrapIter(field, rect.width);
        var first = true;
        var painted = false;
        while (it.next()) |chunk| {
            if (row >= rect.height) return;
            // First chunk continues on the label's row; later chunks align under
            // the value via the label-width indent.
            if (!first) f.moveTo(rect.row + row, rect.col + indent);
            f.putContent(chunk);
            row += 1;
            first = false;
            painted = true;
        }
        if (!painted) row += 1; // empty value: the label row still consumed one
    }
}

fn labelWidth(field: Field) u16 {
    return @intCast(field.label.len + 2); // "label: "
}

/// Width available for the value, after the `label: ` prefix; at least one
/// column so wrapping always makes progress on a very narrow pane.
fn valueWidth(field: Field, width: u16) usize {
    const prefix = labelWidth(field);
    return if (width > prefix) width - prefix else 1;
}

// The value wraps through the shared `text_wrap` leaf, so the footer and the
// detail pane share one wrapping rule rather than two that drift.
fn wrapIter(field: Field, width: u16) text_wrap.Iter {
    return text_wrap.iter(field.value, valueWidth(field, width));
}

// ─── tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "render dims the label and shows the value on its row" {
    var fb: [512]u8 = undefined;
    var f: tab.Frame = .{ .buf = &fb };
    const fields = [_]Field{
        .{ .label = "Tap", .value = "homebrew/core" },
        .{ .label = "Pinned", .value = "yes" },
    };
    render(&f, &fields, .{ .row = 3, .col = 1, .width = 40, .height = 10 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "Tap") != null);
    try testing.expect(std.mem.indexOf(u8, out, "homebrew/core") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Pinned") != null);
    try testing.expect(std.mem.indexOf(u8, out, "yes") != null);
    // The label is dimmed (muted role == dim on the basic tier under test).
    try testing.expect(std.mem.indexOf(u8, out, color.Style.dim.code()) != null);
    try testing.expect(std.mem.indexOf(u8, out, "─") != null); // the separator rule
    // The rule is on the pane's first row; the fields follow below it.
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[4;1H") != null); // first field row
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[5;1H") != null); // second field row
}

test "render wraps a long value across rows instead of cutting it off" {
    var fb: [1024]u8 = undefined;
    var f: tab.Frame = .{ .buf = &fb };
    const fields = [_]Field{.{ .label = "Detail", .value = "the prefix bin dir is not on PATH so installed commands will not be found" }};
    render(&f, &fields, .{ .row = 1, .col = 1, .width = 24, .height = 10 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "found") != null); // the tail survives on a wrapped row
    try testing.expect(std.mem.indexOf(u8, out, ";9H") != null); // a continuation row aligned under the value
}

test "neededRows grows with a wrapped value and counts at least one row per field" {
    const short = [_]Field{.{ .label = "A", .value = "x" }};
    try testing.expectEqual(@as(u16, 2), neededRows(&short, 40)); // separator + one field row
    const long = [_]Field{.{ .label = "Detail", .value = "one two three four five six seven eight nine ten" }};
    try testing.expect(neededRows(&long, 20) > 2); // wraps to several rows at width 20
    const empty = [_]Field{.{ .label = "Deps", .value = "" }};
    try testing.expectEqual(@as(u16, 2), neededRows(&empty, 40)); // separator + the label row
}

test "render clips fields past the pane height" {
    var fb: [512]u8 = undefined;
    var f: tab.Frame = .{ .buf = &fb };
    const fields = [_]Field{
        .{ .label = "A", .value = "alpha" },
        .{ .label = "B", .value = "beta" },
        .{ .label = "C", .value = "gamma" },
    };
    render(&f, &fields, .{ .row = 1, .col = 1, .width = 40, .height = 3 }); // separator + 2 field rows
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "alpha") != null);
    try testing.expect(std.mem.indexOf(u8, out, "beta") != null);
    try testing.expect(std.mem.indexOf(u8, out, "gamma") == null); // third field clipped past the height
}

test "render hard-breaks a single word longer than the line so its tail survives" {
    var fb: [1024]u8 = undefined;
    var f: tab.Frame = .{ .buf = &fb };
    // A long no-space token (a path) has no space to break at, so it wraps by a
    // hard break — the end must still appear, not be cut off.
    const fields = [_]Field{.{ .label = "Detail", .value = "/tmp/malt-test/bin/a/very/long/path/with/no/spaces/anywhere/at/all" }};
    render(&f, &fields, .{ .row = 1, .col = 1, .width = 20, .height = 8 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "all") != null); // the tail is reached
    try testing.expect(std.mem.indexOf(u8, out, ";9H") != null); // wrapped onto an aligned continuation row
}

test "render and neededRows survive a pane narrower than the label" {
    var fb: [256]u8 = undefined;
    var f: tab.Frame = .{ .buf = &fb };
    const fields = [_]Field{.{ .label = "Dependencies", .value = "brotli, zstd" }};
    _ = neededRows(&fields, 4); // a degenerate width must not loop forever
    render(&f, &fields, .{ .row = 1, .col = 1, .width = 4, .height = 6 }); // must not trap
}

test "render of an embedded newline value cannot inject a frame line" {
    var fb: [512]u8 = undefined;
    var f: tab.Frame = .{ .buf = &fb };
    const fields = [_]Field{.{ .label = "X", .value = "a\nb" }};
    render(&f, &fields, .{ .row = 1, .col = 1, .width = 40, .height = 4 });
    const out = f.slice();
    try testing.expect(std.mem.indexOfScalar(u8, out, '\n') == null); // no raw newline in the frame
    try testing.expect(std.mem.indexOf(u8, out, "ab") != null); // the newline collapsed to inert text
}
