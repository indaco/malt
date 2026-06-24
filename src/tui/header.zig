//! malt — header bar widget for `mt tui`.
//!
//! Leaf module: `std` + `ui/color` + `scroll_list` only. A pure function of its
//! inputs and `cols`, modelled on `tab_bar.render` — the left segment
//! (`mt <version>  •  <prefix>`) is always present; the right segment
//! (`<n> kegs  •  <m> outdated`) is right-justified and dropped whole before the
//! left is clipped, so name + version survive a narrow terminal longest.

const std = @import("std");
const color = @import("../ui/color.zig");
const scroll_list = @import("scroll_list.zig");

const name = "mt";
const sep = "  •  ";
const unknown = "—";

/// Header inputs. `version` and `prefix` are always known; each count is null
/// until its store loads, so an unloaded count renders as `unknown` rather than
/// a stale or wrong number.
pub const Fields = struct {
    version: []const u8,
    prefix: []const u8,
    kegs: ?usize = null,
    outdated: ?usize = null,
    outdated_spinner: ?[]const u8 = null,
};

/// Render the muted header into `buf`, truncated to `cols`. The right segment is
/// shown only when it fits with a column of gap; otherwise it is dropped whole
/// so name + version survive a narrow terminal.
pub fn render(buf: []u8, fields: Fields, cols: u16) []const u8 {
    var lbuf: [192]u8 = undefined;
    var rbuf: [64]u8 = undefined;
    const left = leftSegment(&lbuf, fields);
    const right = rightSegment(&rbuf, fields);
    const lw = visibleWidth(left);
    const rw = visibleWidth(right);

    var len: usize = 0;
    append(buf, &len, color.roleCode(.muted)); // chrome, like the footer
    append(buf, &len, left);
    // Right-justify the counts; keep at least one column of gap. When they can't
    // fit, drop them whole rather than clip the left.
    if (lw + rw < cols) {
        var pad = cols - lw - rw;
        while (pad > 0) : (pad -= 1) append(buf, &len, " ");
        append(buf, &len, right);
    }
    append(buf, &len, color.Style.reset.code());
    return scroll_list.truncate(buf[0..len], cols);
}

fn leftSegment(buf: []u8, fields: Fields) []const u8 {
    return std.fmt.bufPrint(buf, "{s} {s}{s}{s}", .{ name, fields.version, sep, fields.prefix }) catch buf[0..0];
}

fn rightSegment(buf: []u8, fields: Fields) []const u8 {
    var kb: [20]u8 = undefined;
    var ob: [20]u8 = undefined;
    // The spinner glyph stands in for the count while the launch audit runs.
    const od = fields.outdated_spinner orelse countStr(&ob, fields.outdated);
    return std.fmt.bufPrint(buf, "{s} kegs{s}{s} outdated", .{
        countStr(&kb, fields.kegs), sep, od,
    }) catch buf[0..0];
}

/// A loaded count is its number; an unloaded one is `unknown`, never a stale value.
fn countStr(buf: []u8, v: ?usize) []const u8 {
    const n = v orelse return unknown;
    return std.fmt.bufPrint(buf, "{d}", .{n}) catch unknown;
}

fn append(buf: []u8, len: *usize, s: []const u8) void {
    const n = @min(s.len, buf.len - len.*);
    @memcpy(buf[len.*..][0..n], s[0..n]);
    len.* += n;
}

// ─── tests ───────────────────────────────────────────────────────────

fn visibleWidth(s: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
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

test "render shows the name, version and prefix on the left" {
    var buf: [256]u8 = undefined;
    const out = render(&buf, .{ .version = "0.1.0", .prefix = "/opt/malt" }, 80);
    try std.testing.expect(std.mem.indexOf(u8, out, "mt 0.1.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/opt/malt") != null);
}

test "render right-justifies both counts and fills the line" {
    var buf: [256]u8 = undefined;
    const out = render(&buf, .{ .version = "0.1.0", .prefix = "/opt/malt", .kegs = 192, .outdated = 17 }, 80);
    try std.testing.expect(std.mem.indexOf(u8, out, "192 kegs") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "17 outdated") != null);
    // Right-justified: the last visible text is the right segment (the trailing
    // reset SGR rides along after it).
    var visible = out;
    const reset = color.Style.reset.code();
    if (std.mem.endsWith(u8, visible, reset)) visible = visible[0 .. visible.len - reset.len];
    try std.testing.expect(std.mem.endsWith(u8, visible, "17 outdated"));
    try std.testing.expectEqual(@as(usize, 80), visibleWidth(out));
}

test "render shows an em-dash for a count whose store has not loaded" {
    var buf: [256]u8 = undefined;
    const out = render(&buf, .{ .version = "0.1.0", .prefix = "/opt/malt", .outdated = 17 }, 80);
    try std.testing.expect(std.mem.indexOf(u8, out, unknown ++ " kegs") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "17 outdated") != null);
}

test "render shows em-dashes for both counts before anything loads" {
    var buf: [256]u8 = undefined;
    const out = render(&buf, .{ .version = "0.1.0", .prefix = "/opt/malt" }, 80);
    try std.testing.expect(std.mem.indexOf(u8, out, unknown ++ " kegs") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, unknown ++ " outdated") != null);
}

test "render shows the spinner glyph on the outdated slot while the launch audit runs" {
    var buf: [256]u8 = undefined;
    // Loading: the glyph replaces the count, so the slot reads as computing.
    const out = render(&buf, .{ .version = "0.1.0", .prefix = "/opt/malt", .kegs = 192, .outdated_spinner = "⠋" }, 80);
    try std.testing.expect(std.mem.indexOf(u8, out, "192 kegs") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "⠋ outdated") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, unknown ++ " outdated") == null); // not a frozen em-dash
}

test "render drops the right segment before clipping the left on a narrow terminal" {
    var buf: [256]u8 = undefined;
    const out = render(&buf, .{ .version = "0.1.0", .prefix = "/opt/malt", .kegs = 192, .outdated = 17 }, 20);
    try std.testing.expect(std.mem.indexOf(u8, out, "mt 0.1.0") != null); // name+version survive
    try std.testing.expect(std.mem.indexOf(u8, out, "kegs") == null); // counts dropped whole
    try std.testing.expect(visibleWidth(out) <= 20);
}

test "render bounds the visible width to cols without counting SGR" {
    var buf: [256]u8 = undefined;
    const out = render(&buf, .{ .version = "0.1.0", .prefix = "/opt/malt", .kegs = 192, .outdated = 17 }, 8);
    try std.testing.expect(visibleWidth(out) <= 8);
}
