//! malt — Search tab for `mt tui`: find and install new packages.
//!
//! Leaf module. Pure cores only: `step(state, key)` records an intent (re-run
//! the query, or install the selected hit) as a `request` for the impure shell
//! to delegate; `render(state, frame, rect)` is a pure function of `(state,
//! rect)` so a resize is a re-render.
//!
//! **Divergence from the other tabs.** Everywhere else `chrome.filter` narrows a
//! static, already-loaded list. Here the filter *doubles as the search box*: the
//! shell commits it on Enter and fires a remote `mt search <query> --json`, and
//! the parsed `items` are the server's ranked results — shown unfiltered, never
//! re-narrowed client-side. So this tab reads `chrome.filter` only as the query
//! (the shell owns that), and indexes the selection straight into `items`.
//!
//! Search is the dashboard's first remote read, so `phase` is first-class: the
//! shell flips it to `searching` and repaints before the blocking call, then to
//! `loaded` after the parse. Install is additive and rollbackable, so — like the
//! upgrade `u` decision — there is no in-TUI `[y/N]` guard; `i` on a not-yet
//! installed hit delegates straight to `mt install`.

const std = @import("std");
const testing = std.testing;

const color = @import("../ui/color.zig");
const search_json = @import("json/search.zig");
pub const Match = search_json.Match;
const Kind = search_json.Kind;
const scroll_list = @import("scroll_list.zig");
const tab = @import("tab.zig");

/// An effect the pure `step` defers to the impure shell, which performs it and
/// resets the field. `step` never does I/O — this is the command channel.
/// `search` (re)runs the committed query; `install` installs the selected hit.
pub const Request = enum { none, search, install };

/// The read lifecycle the render reflects. `idle` before any query is committed
/// (show guidance), `searching` while the blocking remote read runs (the shell
/// flips it and repaints first), `loaded` once results are parsed (the list, or
/// "no matches" when empty).
pub const Phase = enum { idle, searching, loaded };

pub const State = struct {
    chrome: tab.Chrome = .{},
    /// The server's ranked results, borrowed from shell-owned parse storage.
    items: []const Match = &.{},
    /// Pending effect for the shell to perform, then clear.
    request: Request = .none,
    /// Where the tab is in the read lifecycle; drives the render's status line.
    phase: Phase = .idle,
};

pub fn title() []const u8 {
    return "Search";
}

/// The hit the selection points at, clamping the (shell-driven, unbounded)
/// selection into the result list. No filter: the query already ran server-side,
/// so the selection indexes straight into `items`. The shell reads its `name`
/// and `kind` to build the install argv.
pub fn selectedMatch(s: *const State) ?Match {
    if (s.items.len == 0) return null;
    const sel = @min(s.chrome.view.selected, s.items.len - 1);
    return s.items[sel];
}

/// Pure transition. Enter (re)runs the committed query — the filter doubles as
/// the search box, so committing it is the search. `i` installs the selected hit
/// when it is not already installed; on an installed hit it is inert.
pub fn step(s: *State, key: tab.Key) void {
    switch (key) {
        .enter => s.request = .search,
        .char => |c| if (c.len == 1 and c.bytes[0] == 'i') {
            const m = selectedMatch(s) orelse return;
            if (!m.installed) s.request = .install; // inert on an already-installed hit
        },
        else => {},
    }
}

// A closed switch on the kind: a new variant is a compile error here, never a
// silent default — the glyph/colour must be chosen deliberately.
fn kindGlyph(k: Kind) []const u8 {
    return switch (k) {
        .formula => "◆",
        .cask => "▣",
    };
}

fn kindStyle(k: Kind) color.Role {
    return switch (k) {
        .formula => .accent,
        .cask => .secondary,
    };
}

/// Pure render: a dim action line, then — by phase — guidance, a "searching…"
/// status, "no matches", or the ranked result list. A pure function of `(state,
/// rect)` so a resize is a re-render.
pub fn render(s: *const State, f: *tab.Frame, r: tab.Rect) void {
    if (r.height == 0) return;
    renderActionLine(f, .{ .row = r.row, .col = r.col, .width = r.width, .height = 1 });
    const body: tab.Rect = .{ .row = r.row + 1, .col = r.col, .width = r.width, .height = r.height -| 1 };
    if (body.height == 0) return;
    switch (s.phase) {
        .searching => renderStatus(f, body, "searching…"),
        .idle => renderStatus(f, body, "Type a query, then Enter to search."),
        .loaded => if (s.items.len == 0)
            renderStatus(f, body, "No matches.")
        else
            renderList(s, f, body),
    }
}

/// The dim action line: the tab's keys, so they are discoverable (the global
/// footer carries only the shell-wide keys).
fn renderActionLine(f: *tab.Frame, rect: tab.Rect) void {
    f.moveTo(rect.row, rect.col);
    f.put(color.roleCode(.muted));
    f.putContent(scroll_list.truncate("enter: search   i: install", rect.width));
    f.put(color.Style.reset.code());
}

fn renderStatus(f: *tab.Frame, rect: tab.Rect, msg: []const u8) void {
    f.moveTo(rect.row, rect.col);
    f.put(color.roleCode(.muted));
    f.putContent(scroll_list.truncate(msg, rect.width));
    f.put(color.Style.reset.code());
}

fn renderList(s: *const State, f: *tab.Frame, rect: tab.Rect) void {
    if (rect.height == 0) return;
    const v = scroll_list.clamp(s.chrome.view, s.items.len, rect.height);
    for (s.items, 0..) |m, i| {
        if (i < v.offset) continue;
        const screen = i - v.offset;
        if (screen >= rect.height) break;
        f.moveTo(rect.row + @as(u16, @intCast(screen)), rect.col);
        // The kind glyph keeps its own colour regardless of selection; the
        // reverse-video selection wraps only the text columns so the two SGRs
        // never tangle.
        f.put(color.roleCode(kindStyle(m.kind)));
        f.put(kindGlyph(m.kind));
        f.put(color.Style.reset.code());
        f.put(" ");
        const selected = i == v.selected;
        if (selected) f.put(reverse);
        var rb: [256]u8 = undefined;
        f.putContent(scroll_list.truncate(formatRow(&rb, m), rect.width -| 2)); // 2 cols on the glyph
        if (selected) f.put(color.Style.reset.code());
    }
}

// SGR reverse-video for the selection, matching the other tabs' convention.
const reverse = "\x1b[7m";

/// One list row (after the glyph): the package name, then an "installed" marker
/// for a hit already on the system. ASCII columns, grapheme-naive like the rest.
fn formatRow(buf: []u8, m: Match) []const u8 {
    var len: usize = 0;
    appendPad(buf, &len, m.name, 32);
    append(buf, &len, " ");
    if (m.installed) append(buf, &len, "installed");
    return buf[0..len];
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

fn ch(c: u8) tab.Key {
    return .{ .char = .{ .bytes = .{ c, 0, 0, 0 }, .len = 1 } };
}

const sample = [_]Match{
    .{ .name = "wget", .kind = .formula, .installed = false },
    .{ .name = "firefox", .kind = .cask, .installed = true },
    .{ .name = "ripgrep", .kind = .formula, .installed = false },
};

test "selectedMatch clamps the unbounded cursor into the result list" {
    var s: State = .{ .items = &sample, .phase = .loaded };
    s.chrome.view.selected = 0;
    try testing.expectEqualStrings("wget", selectedMatch(&s).?.name);
    s.chrome.view.selected = 99; // clamps to the last hit
    try testing.expectEqualStrings("ripgrep", selectedMatch(&s).?.name);
}

test "selectedMatch on an empty list is null (the action becomes a no-op)" {
    const s: State = .{ .items = &.{} };
    try testing.expect(selectedMatch(&s) == null);
}

test "enter requests a search — committing the query is the search" {
    var s: State = .{ .items = &sample };
    step(&s, .enter);
    try testing.expectEqual(Request.search, s.request);
}

test "i on a not-installed hit requests install; on an installed hit it is inert" {
    var s: State = .{ .items = &sample, .phase = .loaded };
    s.chrome.view.selected = 0; // wget, not installed
    step(&s, ch('i'));
    try testing.expectEqual(Request.install, s.request);

    s.request = .none;
    s.chrome.view.selected = 1; // firefox, already installed
    step(&s, ch('i'));
    try testing.expectEqual(Request.none, s.request); // inert
}

test "i on an empty list is inert" {
    var s: State = .{ .items = &.{} };
    step(&s, ch('i'));
    try testing.expectEqual(Request.none, s.request);
}

test "an unrelated key leaves the request alone" {
    var s: State = .{ .items = &sample };
    step(&s, ch('z'));
    try testing.expectEqual(Request.none, s.request);
    step(&s, .down);
    try testing.expectEqual(Request.none, s.request);
}

test "render shows guidance in the idle phase before any query is committed" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .phase = .idle };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    try testing.expect(std.mem.indexOf(u8, f.slice(), "Type a query") != null);
}

test "render shows the searching status during the remote read" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .phase = .searching };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    try testing.expect(std.mem.indexOf(u8, f.slice(), "searching") != null);
}

test "render shows no-matches when a committed query returned zero results" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &.{}, .phase = .loaded };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    try testing.expect(std.mem.indexOf(u8, f.slice(), "No matches") != null);
}

test "render lists hits with a kind glyph and an installed marker" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample, .phase = .loaded };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "wget") != null);
    try testing.expect(std.mem.indexOf(u8, out, "firefox") != null);
    try testing.expect(std.mem.indexOf(u8, out, "◆") != null); // formula glyph
    try testing.expect(std.mem.indexOf(u8, out, "▣") != null); // cask glyph
    try testing.expect(std.mem.indexOf(u8, out, "installed") != null); // firefox marker
    try testing.expect(std.mem.indexOf(u8, out, color.Style.cyan.code()) != null); // a coloured glyph
}

test "render highlights the selected hit" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var s: State = .{ .items = &sample, .phase = .loaded };
    s.chrome.view.selected = 0;
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    try testing.expect(std.mem.indexOf(u8, f.slice(), reverse) != null);
}

test "render shows the action line keys so they are discoverable" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .phase = .idle };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "search") != null);
    try testing.expect(std.mem.indexOf(u8, out, "install") != null);
}

test "render reflows: the same state at two widths differs" {
    var a: [8192]u8 = undefined;
    var b: [8192]u8 = undefined;
    var fa: tab.Frame = .{ .buf = &a };
    var fb: tab.Frame = .{ .buf = &b };
    const s: State = .{ .items = &sample, .phase = .loaded };
    render(&s, &fa, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    render(&s, &fb, .{ .row = 1, .col = 1, .width = 30, .height = 6 });
    try testing.expect(!std.mem.eql(u8, fa.slice(), fb.slice()));
}

test "a hostile hit name cannot inject a control sequence into the frame" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const evil = [_]Match{.{ .name = "ev\x1b]0;pwn\x07il", .kind = .formula, .installed = false }};
    const s: State = .{ .items = &evil, .phase = .loaded };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    const out = f.slice();
    // The glyph legitimately emits its own SGR via `put`; the row *content* is
    // funnelled through `putContent`, so the name's OSC title-set and BEL die there.
    try testing.expect(std.mem.indexOf(u8, out, "\x1b]0;pwn") == null); // OSC introducer broken
    try testing.expect(std.mem.indexOfScalar(u8, out, 0x07) == null); // BEL dropped
}

test "render clamps to a height of one (action line only) without crashing" {
    var buf: [1024]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample, .phase = .loaded };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 1 }); // no body fits
}

test "render on a zero-height rect is a clean no-op" {
    var buf: [256]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample, .phase = .loaded };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 0 }); // must not trap
}

test "conforms to the tab contract" {
    comptime tab.verify(@This());
}
