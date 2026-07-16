//! malt — tab bar widget for `mt tui`.

const std = @import("std");
const color = @import("../ui/color.zig");
const scroll_list = @import("scroll_list.zig");

pub const Tab = enum { search, installed, outdated, services, doctor };
pub const count = @typeInfo(Tab).@"enum".fields.len;

/// Cycle to the next tab, wrapping after the last so `tab` is a closed loop.
pub fn next(t: Tab) Tab {
    return @enumFromInt((@as(usize, @intFromEnum(t)) + 1) % count);
}

/// Cycle to the previous tab, wrapping before the first — the reverse of `next`.
pub fn prev(t: Tab) Tab {
    return @enumFromInt((@as(usize, @intFromEnum(t)) + count - 1) % count);
}

/// `'1'`–`'5'` jump straight to a tab; any other byte is not a jump.
pub fn fromDigit(b: u8) ?Tab {
    if (b < '1' or b >= '1' + count) return null;
    return @enumFromInt(b - '1');
}

/// The single accent seam for tab titles. Resolved through the active theme so
/// every title recolours together when MALT_THEME changes.
fn accentCode() []const u8 {
    return color.roleCode(.accent);
}

// Divider between tabs — a light vertical bar, one display column wide.
const sep = " │ ";

fn append(buf: []u8, len: *usize, s: []const u8) void {
    const n = @min(s.len, buf.len - len.*);
    @memcpy(buf[len.*..][0..n], s[0..n]);
    len.* += n;
}

/// Display columns `s` occupies: one per rune, zero for SGR — the same model
/// `scroll_list.truncate` bounds the bar by.
fn visibleWidth(s: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) { // skip the SGR escape, it is zero-width
            i += 1;
            if (i < s.len and s[i] == '[') {
                i += 1;
                while (i < s.len and !(s[i] >= 0x40 and s[i] <= 0x7e)) i += 1;
            }
            if (i < s.len) i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i += @min(@as(usize, n), s.len - i);
        w += 1;
    }
    return w;
}

/// Bytes a caller's render buffer must hold. `append` clamps at capacity, so a
/// buffer this size keeps `cols` the *only* thing that truncates the bar — a
/// capacity cut would drop titles `tabAt` still maps, and a click could switch to
/// a tab that was never drawn. The app's title/theme sweep pins the bound.
pub const buf_cap: usize = 256;

/// Render the bar — titles separated by `sep`, the active one wrapped in accent +
/// reverse + bold. SGR is zero-width to `scroll_list.truncate`, so only the visible
/// runes are bounded by `cols`. Returns a prefix of `buf`.
pub fn render(buf: []u8, active: Tab, titles: [count][]const u8, cols: u16) []const u8 {
    var len: usize = 0;
    for (titles, 0..) |t, i| {
        if (i != 0) append(buf, &len, sep);
        append(buf, &len, accentCode()); // every title carries the accent
        if (i == @intFromEnum(active)) { // active is a reverse-video, bold block
            append(buf, &len, color.Style.reverse.code());
            append(buf, &len, color.Style.bold.code());
        }
        append(buf, &len, t);
        append(buf, &len, color.Style.reset.code());
    }
    return scroll_list.truncate(buf[0..len], cols);
}

/// The tab whose title covers 1-based `click_col`; null for a divider, past the last
/// title, or one truncated away at `cols`. Walks the layout `render` draws, so the
/// click target can't drift from what is on screen. Pure — the source of truth for
/// click→tab.
pub fn tabAt(titles: [count][]const u8, cols: u16, click_col: u16) ?Tab {
    if (click_col == 0 or click_col > cols) return null;
    const sep_w = comptime visibleWidth(sep);
    var first: usize = 1; // 1-based, matching the bar's origin at layout col 1
    for (titles, 0..) |t, i| {
        const w = visibleWidth(t);
        if (click_col < first) return null; // landed in the divider before this title
        if (click_col < first + w) return @enumFromInt(i);
        first += w + sep_w;
    }
    return null; // past the last title
}

const test_titles: [count][]const u8 = .{ "Search", "Installed", "Outdated", "Services", "Doctor" };

// The spans `render` lays out for `test_titles`: each title follows the earlier
// ones plus a three-column divider.
const search_span = .{ .first = 1, .last = 6 };
const installed_span = .{ .first = 10, .last = 18 };
const doctor_span = .{ .first = 44, .last = 49 };

test "tabAt maps the first and last column of every title to that tab" {
    var first: u16 = 1;
    for (test_titles, 0..) |t, i| {
        const w: u16 = @intCast(visibleWidth(t));
        const want: Tab = @enumFromInt(i);
        try std.testing.expectEqual(want, tabAt(test_titles, 80, first).?);
        try std.testing.expectEqual(want, tabAt(test_titles, 80, first + w - 1).?); // span boundary
        first += w + @as(u16, @intCast(visibleWidth(sep)));
    }
    try std.testing.expectEqual(Tab.search, tabAt(test_titles, 80, search_span.first).?);
    try std.testing.expectEqual(Tab.doctor, tabAt(test_titles, 80, doctor_span.last).?);
}

test "tabAt returns null for a divider, a column past the last title, and col 0" {
    try std.testing.expect(tabAt(test_titles, 80, search_span.last + 1) == null); // the divider
    try std.testing.expect(tabAt(test_titles, 80, installed_span.first - 1) == null);
    try std.testing.expect(tabAt(test_titles, 80, doctor_span.last + 1) == null); // past the bar
    try std.testing.expect(tabAt(test_titles, 80, 0) == null); // columns are 1-based
}

test "tabAt hits nothing past cols, where render truncated the title away" {
    // cols 12 shows Search, the divider and the first three runes of Installed only.
    try std.testing.expectEqual(Tab.installed, tabAt(test_titles, 12, installed_span.first).?);
    try std.testing.expect(tabAt(test_titles, 12, installed_span.last) == null); // cut off
    try std.testing.expect(tabAt(test_titles, 12, doctor_span.first) == null); // never drawn
    try std.testing.expect(tabAt(test_titles, 0, 1) == null); // nothing visible at all
}

test "tabAt agrees with the column render actually draws, whichever tab is active" {
    // Styling is zero-width, so no span shifts. Read the column back out of render's
    // own output — the two must not drift.
    for ([_]Tab{ .search, .installed, .doctor }) |active| {
        var buf: [256]u8 = undefined;
        const out = render(&buf, active, test_titles, 80);
        const at = std.mem.indexOf(u8, out, "Installed").?;
        const col: u16 = @intCast(visibleWidth(out[0..at]) + 1);
        try std.testing.expectEqual(installed_span.first, col);
        try std.testing.expectEqual(Tab.installed, tabAt(test_titles, 80, col).?);
    }
}

test "next cycles through every tab and wraps" {
    try std.testing.expectEqual(Tab.outdated, next(.installed));
    try std.testing.expectEqual(Tab.services, next(.outdated));
    try std.testing.expectEqual(Tab.doctor, next(.services));
    try std.testing.expectEqual(Tab.search, next(.doctor));
    try std.testing.expectEqual(Tab.installed, next(.search));
}

test "prev cycles backward through every tab and wraps" {
    try std.testing.expectEqual(Tab.search, prev(.installed));
    try std.testing.expectEqual(Tab.installed, prev(.outdated));
    try std.testing.expectEqual(Tab.services, prev(.doctor));
    try std.testing.expectEqual(Tab.doctor, prev(.search));
}

test "fromDigit maps 1-5 and rejects everything else" {
    try std.testing.expectEqual(Tab.search, fromDigit('1').?);
    try std.testing.expectEqual(Tab.services, fromDigit('4').?);
    try std.testing.expectEqual(Tab.doctor, fromDigit('5').?);
    try std.testing.expect(fromDigit('0') == null);
    try std.testing.expect(fromDigit('6') == null);
    try std.testing.expect(fromDigit('a') == null);
}

test "render divides tabs, reverse+bolds the active, accents the rest" {
    var buf: [256]u8 = undefined;
    const out = render(&buf, .outdated, test_titles, 80);
    try std.testing.expect(std.mem.indexOf(u8, out, sep) != null); // a divider between tabs
    // active: accent + reverse + bold + title + reset
    var ab: [64]u8 = undefined;
    const active = try std.fmt.bufPrint(&ab, "{s}{s}{s}Outdated{s}", .{ accentCode(), color.Style.reverse.code(), color.Style.bold.code(), color.Style.reset.code() });
    try std.testing.expect(std.mem.indexOf(u8, out, active) != null);
    // inactive: accent + title (no reverse/bold) + reset
    var ib: [64]u8 = undefined;
    const inactive = try std.fmt.bufPrint(&ib, "{s}Installed{s}", .{ accentCode(), color.Style.reset.code() });
    try std.testing.expect(std.mem.indexOf(u8, out, inactive) != null);
}

test "render truncates to the column budget without counting SGR escapes" {
    var buf: [256]u8 = undefined;
    const out = render(&buf, .installed, test_titles, 4);
    // Styling is zero-width, so only the visible runes are bounded by cols.
    try std.testing.expect(visibleWidth(out) <= 4);
}
