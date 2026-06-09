//! malt — tab bar widget for `mt tui`.

const std = @import("std");
const color = @import("../ui/color.zig");
const scroll_list = @import("scroll_list.zig");

pub const Tab = enum { installed, outdated, services, doctor, search };
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

/// The single accent seam for tab titles. A theme system will resolve this
/// from a palette; today it is one fixed accent so the bar reads as intentional.
fn accentCode() []const u8 {
    return color.Style.cyan.code();
}

// SGR reverse-video: highlights the active tab as a filled block. `color.zig`
// owns named colours, not this attribute, so the code lives here.
const reverse_code = "\x1b[7m";

// Divider between tabs — a light vertical bar, one display column wide.
const sep = " │ ";

fn append(buf: []u8, len: *usize, s: []const u8) void {
    const n = @min(s.len, buf.len - len.*);
    @memcpy(buf[len.*..][0..n], s[0..n]);
    len.* += n;
}

/// Render the bar — titles separated by two spaces, the active one wrapped in
/// bold + reset. SGR is zero-width to `scroll_list.truncate`, so only the
/// visible runes are bounded by `cols`. Returns a prefix of `buf`.
pub fn render(buf: []u8, active: Tab, titles: [count][]const u8, cols: u16) []const u8 {
    var len: usize = 0;
    for (titles, 0..) |t, i| {
        if (i != 0) append(buf, &len, sep);
        append(buf, &len, accentCode()); // every title carries the accent
        if (i == @intFromEnum(active)) { // active is a reverse-video, bold block
            append(buf, &len, reverse_code);
            append(buf, &len, color.Style.bold.code());
        }
        append(buf, &len, t);
        append(buf, &len, color.Style.reset.code());
    }
    return scroll_list.truncate(buf[0..len], cols);
}

const test_titles: [count][]const u8 = .{ "Installed", "Outdated", "Services", "Doctor", "Search" };

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
    try std.testing.expectEqual(Tab.installed, fromDigit('1').?);
    try std.testing.expectEqual(Tab.doctor, fromDigit('4').?);
    try std.testing.expectEqual(Tab.search, fromDigit('5').?);
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
    const active = try std.fmt.bufPrint(&ab, "{s}{s}{s}Outdated{s}", .{ accentCode(), reverse_code, color.Style.bold.code(), color.Style.reset.code() });
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
