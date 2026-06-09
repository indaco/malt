//! malt — Outdated tab for `mt tui`: the multi-select upgrade pane.
//!
//! Leaf module. Pure cores only: `step(state, key)` toggles the per-row checkbox
//! set and records an `upgrade` request for the impure shell to delegate to the
//! real `mt upgrade`; `render(state, frame, rect)` is a pure function of
//! `(state, rect)` so a resize is a re-render. The shell owns the row data and
//! the parallel `checked` buffer; the tab borrows both. Pinned rows are shown
//! greyed and can never enter the checked set — the wireframe holds them back
//! from a bulk upgrade. `space` toggles the cursor row, `a` checks all
//! non-pinned, `n` clears, and `u`/Enter with N>0 requests the upgrade; an empty
//! selection is a no-op surfaced by the action line.

const std = @import("std");
const tab = @import("tab.zig");
const scroll_list = @import("scroll_list.zig");
const outdated_json = @import("json/outdated.zig");
const color = @import("../ui/color.zig");

pub const Row = outdated_json.OutdatedRow;

/// An effect the pure `step` defers to the impure shell, which performs it and
/// resets the field. `step` never does I/O — this is the command channel.
pub const Request = enum { none, upgrade };

pub const State = struct {
    chrome: tab.Chrome = .{},
    /// Outdated rows, borrowed from shell-owned parse storage.
    items: []const Row = &.{},
    /// Per-row checkbox state, parallel to `items`, owned by the shell. A pinned
    /// row's slot is never set. The cores guard against a shorter slice so a
    /// not-yet-sized buffer (before the shell allocates it) never traps.
    checked: []bool = &.{},
    /// Pending effect for the shell to perform, then clear.
    request: Request = .none,
};

pub fn title() []const u8 {
    return "Outdated";
}

/// The tab's action keys, surfaced in the shared footer next to the global keys.
pub fn footerHint() []const u8 {
    return "space: toggle   a: all   n: none   u: upgrade";
}

/// Case-insensitive substring match of `filter` against `name`. An empty filter
/// matches everything.
pub fn matches(name: []const u8, filter: []const u8) bool {
    return filter.len == 0 or std.ascii.indexOfIgnoreCase(name, filter) != null;
}

fn filteredCount(items: []const Row, filter: []const u8) usize {
    var n: usize = 0;
    for (items) |p| {
        if (matches(p.name, filter)) n += 1;
    }
    return n;
}

/// The item index the cursor points at after applying the filter and clamping
/// the (shell-driven, unbounded) selection into the filtered list, or null when
/// the filtered list is empty.
pub fn selectedIndex(s: *const State) ?usize {
    const filter = s.chrome.filter.slice();
    const nf = filteredCount(s.items, filter);
    if (nf == 0) return null;
    const sel = @min(s.chrome.view.selected, nf - 1);
    var fi: usize = 0;
    for (s.items, 0..) |p, i| {
        if (!matches(p.name, filter)) continue;
        if (fi == sel) return i;
        fi += 1;
    }
    return null; // unreachable: sel < nf
}

/// Count of checked, non-pinned rows — the upgrade batch size.
pub fn selectedCount(s: *const State) usize {
    var n: usize = 0;
    for (s.items, 0..) |p, i| {
        if (i < s.checked.len and s.checked[i] and !p.pinned) n += 1;
    }
    return n;
}

/// Write the checked, non-pinned package names into `out` (caller sizes it to at
/// least `selectedCount`) in item order; returns the count written. The shell
/// turns this into `mt upgrade <names...>`. Pinned rows are excluded even if a
/// stray bit is set, so a held-back package can never reach the upgrade.
pub fn selectedNames(s: *const State, out: [][]const u8) usize {
    var n: usize = 0;
    for (s.items, 0..) |p, i| {
        if (i < s.checked.len and s.checked[i] and !p.pinned) {
            if (n < out.len) out[n] = p.name;
            n += 1;
        }
    }
    return n;
}

/// Pure transition: toggle the cursor row, bulk select/clear, or request the
/// upgrade. A pinned cursor row cannot be toggled.
pub fn step(s: *State, key: tab.Key) void {
    switch (key) {
        .space => toggleSelected(s),
        .enter => requestUpgrade(s),
        .char => |c| if (c.len == 1) switch (c.bytes[0]) {
            'u' => requestUpgrade(s),
            'a' => setAll(s, true),
            'n' => setAll(s, false),
            else => {},
        },
        else => {},
    }
}

fn toggleSelected(s: *State) void {
    const idx = selectedIndex(s) orelse return;
    if (idx >= s.checked.len or s.items[idx].pinned) return; // pinned rows are held back
    s.checked[idx] = !s.checked[idx];
}

/// Bulk set: `a` checks every non-pinned row, `n` (on=false) clears all. A pinned
/// row is never checked, so `a` leaves it untouched.
fn setAll(s: *State, on: bool) void {
    for (s.items, 0..) |p, i| {
        if (i >= s.checked.len) break;
        s.checked[i] = on and !p.pinned;
    }
}

fn requestUpgrade(s: *State) void {
    if (selectedCount(s) > 0) s.request = .upgrade; // empty selection is a no-op
}

/// Pure render: the filtered + scrolled checkbox list. The multi-select keys
/// live in the shared footer, so the list owns the whole rect; the `[x]`
/// checkboxes carry the selection. A pure function of `(state, rect)` so a
/// resize is a re-render.
pub fn render(s: *const State, f: *tab.Frame, r: tab.Rect) void {
    if (r.height == 0) return;
    renderList(s, f, r);
}

fn renderList(s: *const State, f: *tab.Frame, rect: tab.Rect) void {
    if (rect.height == 0) return;
    const filter = s.chrome.filter.slice();
    const nf = filteredCount(s.items, filter);
    if (nf == 0) return tab.renderHint(f, rect, if (filter.len != 0) "No matches." else "Everything is up to date.");
    const v = scroll_list.clamp(s.chrome.view, nf, rect.height);

    var fi: usize = 0;
    for (s.items, 0..) |p, i| {
        if (!matches(p.name, filter)) continue;
        defer fi += 1;
        if (fi < v.offset) continue;
        const screen = fi - v.offset;
        if (screen >= rect.height) break;
        f.moveTo(rect.row + @as(u16, @intCast(screen)), rect.col);
        const selected = fi == v.selected;
        // The cursor row wins over the pinned dim so the selection stays legible.
        if (selected) f.put(reverse) else if (p.pinned) f.put(color.roleCode(.muted));
        const is_checked = i < s.checked.len and s.checked[i];
        var rb: [256]u8 = undefined;
        f.putContent(scroll_list.truncate(formatRow(&rb, p, is_checked), rect.width));
        if (selected or p.pinned) f.put(color.Style.reset.code());
    }
}

// SGR reverse-video for the selection, matching the other tabs' convention.
const reverse = "\x1b[7m";

/// One list row: a checkbox (or a held-back marker for a pinned row), the name,
/// the current→latest versions, the source type, and a pinned tag. ASCII columns,
/// grapheme-naive like the rest; the arrow is width-aware via `truncate`.
fn formatRow(buf: []u8, p: Row, checked: bool) []const u8 {
    var len: usize = 0;
    if (p.pinned) append(buf, &len, " -  ") // pinned: held back, no checkbox
    else if (checked) append(buf, &len, "[x] ") else append(buf, &len, "[ ] ");
    appendPad(buf, &len, p.name, 22);
    append(buf, &len, " ");
    appendPad(buf, &len, p.installed, 12);
    append(buf, &len, "→ ");
    appendPad(buf, &len, p.latest, 12);
    append(buf, &len, " ");
    appendPad(buf, &len, kindLabel(p.kind), 8);
    if (p.pinned) append(buf, &len, "pinned");
    return buf[0..len];
}

fn kindLabel(k: outdated_json.Kind) []const u8 {
    return switch (k) {
        .formula => "formula",
        .cask => "cask",
    };
}

fn append(buf: []u8, len: *usize, s: []const u8) void {
    const n = @min(s.len, buf.len - len.*);
    @memcpy(buf[len.*..][0..n], s[0..n]);
    len.* += n;
}

fn appendPad(buf: []u8, len: *usize, s: []const u8, width: usize) void {
    append(buf, len, s);
    var i = s.len;
    while (i < width) : (i += 1) append(buf, len, " ");
}

// ─── tests ───────────────────────────────────────────────────────────

const testing = std.testing;

fn ch(c: u8) tab.Key {
    return .{ .char = .{ .bytes = .{ c, 0, 0, 0 }, .len = 1 } };
}

// Index 1 (curl) is pinned: shown but held back from any bulk upgrade.
const sample = [_]Row{
    .{ .name = "wget", .installed = "1.24.5", .latest = "1.25.0", .kind = .formula, .pinned = false, .tap = "" },
    .{ .name = "curl", .installed = "8.1.0", .latest = "8.2.0", .kind = .formula, .pinned = true, .tap = "" },
    .{ .name = "firefox", .installed = "120.0", .latest = "121.0", .kind = .cask, .pinned = false, .tap = "user/repo" },
    .{ .name = "ffmpeg", .installed = "8.0", .latest = "8.1", .kind = .formula, .pinned = false, .tap = "" },
};

test "matches is a case-insensitive substring; empty filter matches all" {
    try testing.expect(matches("firefox", ""));
    try testing.expect(matches("FireFox", "fox"));
    try testing.expect(!matches("wget", "zzz"));
}

test "space toggles the cursor row's checkbox" {
    var checked = [_]bool{false} ** 4;
    var s: State = .{ .items = &sample, .checked = &checked };
    s.chrome.view.selected = 0; // wget
    step(&s, .space);
    try testing.expect(checked[0]);
    step(&s, .space); // toggles back off
    try testing.expect(!checked[0]);
}

test "space on a pinned cursor row never checks it" {
    var checked = [_]bool{false} ** 4;
    var s: State = .{ .items = &sample, .checked = &checked };
    s.chrome.view.selected = 1; // curl (pinned)
    step(&s, .space);
    try testing.expect(!checked[1]);
}

test "a checks every non-pinned row and leaves pinned rows unchecked" {
    var checked = [_]bool{false} ** 4;
    var s: State = .{ .items = &sample, .checked = &checked };
    step(&s, ch('a'));
    try testing.expect(checked[0]); // wget
    try testing.expect(!checked[1]); // curl is pinned — excluded
    try testing.expect(checked[2]); // firefox
    try testing.expect(checked[3]); // ffmpeg
}

test "n clears every checkbox" {
    var checked = [_]bool{ true, false, true, true };
    var s: State = .{ .items = &sample, .checked = &checked };
    step(&s, ch('n'));
    for (checked) |b| try testing.expect(!b);
}

test "u requests the upgrade only when something is selected" {
    var checked = [_]bool{false} ** 4;
    var s: State = .{ .items = &sample, .checked = &checked };
    step(&s, ch('u')); // empty selection → no-op
    try testing.expectEqual(Request.none, s.request);
    checked[0] = true;
    step(&s, ch('u'));
    try testing.expectEqual(Request.upgrade, s.request);
}

test "Enter requests the upgrade like u" {
    var checked = [_]bool{ true, false, false, false };
    var s: State = .{ .items = &sample, .checked = &checked };
    step(&s, .enter);
    try testing.expectEqual(Request.upgrade, s.request);
}

test "selectedCount counts checked, non-pinned rows" {
    var checked = [_]bool{ true, true, false, true }; // curl(1) is pinned
    const s: State = .{ .items = &sample, .checked = &checked };
    try testing.expectEqual(@as(usize, 2), selectedCount(&s)); // wget + ffmpeg
}

test "selectedNames yields checked non-pinned names in item order, pinned never included" {
    var checked = [_]bool{ true, true, false, true }; // curl(1) pinned but bit set
    const s: State = .{ .items = &sample, .checked = &checked };
    var out: [4][]const u8 = undefined;
    const n = selectedNames(&s, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("wget", out[0]);
    try testing.expectEqualStrings("ffmpeg", out[1]); // curl skipped despite its bit
}

test "selectedIndex maps the cursor through the filter and clamps out-of-range" {
    var checked = [_]bool{false} ** 4;
    var s: State = .{ .items = &sample, .checked = &checked };
    s.chrome.view.selected = 0;
    try testing.expectEqual(@as(?usize, 0), selectedIndex(&s)); // wget
    s.chrome.filter.push("f"); // firefox + ffmpeg
    s.chrome.view.selected = 0;
    try testing.expectEqual(@as(?usize, 2), selectedIndex(&s)); // firefox
    s.chrome.view.selected = 99; // clamps to the last match
    try testing.expectEqual(@as(?usize, 3), selectedIndex(&s)); // ffmpeg
    s.chrome.filter.clear();
    s.chrome.filter.push("zzz");
    try testing.expectEqual(@as(?usize, null), selectedIndex(&s));
}

test "render lists checkboxes with current→latest and the type column" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var checked = [_]bool{ true, false, false, false };
    const s: State = .{ .items = &sample, .checked = &checked };
    render(&s, &f, .{ .row = 2, .col = 1, .width = 80, .height = 12 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "[x]") != null); // wget checked
    try testing.expect(std.mem.indexOf(u8, out, "[ ]") != null); // an unchecked box
    try testing.expect(std.mem.indexOf(u8, out, "→") != null); // current→latest
    try testing.expect(std.mem.indexOf(u8, out, "1.25.0") != null); // latest version
    try testing.expect(std.mem.indexOf(u8, out, "cask") != null); // type column
}

test "render greys a pinned row, gives it no checkbox, and marks it pinned" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var checked = [_]bool{false} ** 4;
    const s: State = .{ .items = &sample, .checked = &checked };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "pinned") != null); // curl marked
    try testing.expect(std.mem.indexOf(u8, out, color.Style.dim.code()) != null); // greyed: muted role == dim on the basic tier
}

test "render narrows to the filter" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var checked = [_]bool{false} ** 4;
    var s: State = .{ .items = &sample, .checked = &checked };
    s.chrome.filter.push("firefox");
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "firefox") != null);
    try testing.expect(std.mem.indexOf(u8, out, "wget") == null); // filtered out
}

test "render highlights the selected row" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var checked = [_]bool{false} ** 4;
    var s: State = .{ .items = &sample, .checked = &checked };
    s.chrome.view.selected = 0;
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    try testing.expect(std.mem.indexOf(u8, f.slice(), reverse) != null);
}

test "footerHint exposes the multi-select keys for the shared footer" {
    // The selection is carried by the row checkboxes; the keys live in the footer.
    try testing.expect(std.mem.indexOf(u8, footerHint(), "space") != null);
    try testing.expect(std.mem.indexOf(u8, footerHint(), "upgrade") != null);
}

test "render reflows: the same state at two widths differs" {
    var a: [8192]u8 = undefined;
    var b: [8192]u8 = undefined;
    var fa: tab.Frame = .{ .buf = &a };
    var fb: tab.Frame = .{ .buf = &b };
    var checked = [_]bool{false} ** 4;
    const s: State = .{ .items = &sample, .checked = &checked };
    render(&s, &fa, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    render(&s, &fb, .{ .row = 1, .col = 1, .width = 30, .height = 6 });
    try testing.expect(!std.mem.eql(u8, fa.slice(), fb.slice()));
}

test "render on an empty list shows the up-to-date placeholder, not a blank pane" {
    var buf: [1024]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &.{} };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 }); // must not trap
    try std.testing.expect(std.mem.indexOf(u8, f.slice(), "up to date") != null);
}

test "the cores tolerate a checked slice shorter than items without trapping" {
    // Before the shell sizes `checked`, the cores must not index out of bounds.
    var checked = [_]bool{false}; // len 1, items len 4
    var s: State = .{ .items = &sample, .checked = &checked };
    step(&s, ch('a')); // setAll must stop at the slice end
    step(&s, .space); // toggle the cursor row only if in range
    _ = selectedCount(&s);
    var out: [4][]const u8 = undefined;
    _ = selectedNames(&s, &out);
}

test "conforms to the tab contract" {
    comptime tab.verify(@This());
}
