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
const info_json = @import("json/info.zig");
const detail_pane = @import("detail_pane.zig");
const scroll_list = @import("scroll_list.zig");
const tab = @import("tab.zig");

/// An effect the pure `step` defers to the impure shell, which performs it and
/// resets the field. `step` never does I/O — this is the command channel.
/// `search` (re)runs the committed query; `install` installs the selection;
/// `info` opens `mt info` for the active hit (works for uninstalled hits too).
pub const Request = enum { none, search, install, info };

/// The read lifecycle the render reflects. `idle` before any query is committed
/// (show guidance), `searching` while the blocking remote read runs (the shell
/// flips it and repaints first), `loaded` once results are parsed (the list, or
/// "no matches" when empty).
pub const Phase = enum { idle, searching, loaded };

pub const State = struct {
    chrome: tab.Chrome = .{},
    /// The server's ranked results, borrowed from shell-owned parse storage.
    items: []const Match = &.{},
    /// Per-row multi-select state, parallel to `items`, owned + sized by the
    /// shell (like Outdated's). An already-installed hit is never checked.
    checked: []bool = &.{},
    /// The open info pane for the active hit, if Enter requested one. Borrows
    /// from shell-owned parse storage; cleared on Esc or a fresh query.
    detail: ?info_json.Info = null,
    /// Pending effect for the shell to perform, then clear.
    request: Request = .none,
    /// Where the tab is in the read lifecycle; drives the render's status line.
    phase: Phase = .idle,
};

pub fn title() []const u8 {
    return "Search";
}

/// The tab's action keys, surfaced in the shared footer next to the global keys.
pub fn footerHint() []const u8 {
    return "space: select   enter: info   i: install";
}

/// The hit the selection points at, clamping the (shell-driven, unbounded)
/// selection into the result list. No filter: the query already ran server-side,
/// so the selection indexes straight into `items`. The shell reads its `name`
/// and `kind` to build the install argv.
pub fn selectedMatch(s: *const State) ?Match {
    const i = selectedIndex(s) orelse return null;
    return s.items[i];
}

/// The index of the active row in `items`, clamping the unbounded cursor. No
/// filter, so the cursor indexes straight into `items`. Null on an empty list.
pub fn selectedIndex(s: *const State) ?usize {
    if (s.items.len == 0) return null;
    return @min(s.chrome.view.selected, s.items.len - 1);
}

/// Toggle the active row's checkbox. An already-installed hit is never selectable
/// (it would be a no-op install), mirroring how a pinned row is held back.
fn toggle(s: *State) void {
    const i = selectedIndex(s) orelse return;
    if (s.items[i].installed) return;
    if (i < s.checked.len) s.checked[i] = !s.checked[i];
}

/// Pure transition. Enter (re)runs the committed query — the filter doubles as
/// the search box, so committing it is the search. `i` installs the selected hit
/// when it is not already installed; on an installed hit it is inert.
pub fn step(s: *State, key: tab.Key) void {
    switch (key) {
        // Enter on a result opens `mt info` for it. Committing the query (the
        // other meaning of Enter) is driven by the shell on filter-commit, not
        // here, so the two never collide.
        .enter => if (selectedMatch(s) != null) {
            s.request = .info;
        },
        .space => toggle(s),
        // `i` installs the multi-selection (or the active row when nothing is
        // checked); inert when there is nothing installable to do.
        .char => |c| if (c.len == 1 and c.bytes[0] == 'i') {
            if (anyInstallable(s)) s.request = .install;
        },
        .esc => s.detail = null, // close the info pane
        else => {},
    }
}

/// True when `i` would install something: any checked, not-installed hit, or —
/// with nothing checked — an installable active row. Mirrors what the shell's
/// install argv resolves, so `i` stays inert when there is nothing to do.
fn anyInstallable(s: *const State) bool {
    var any_checked = false;
    for (s.items, 0..) |m, i| {
        if (i >= s.checked.len or !s.checked[i]) continue;
        any_checked = true;
        if (!m.installed) return true;
    }
    if (any_checked) return false; // only already-installed rows checked
    const m = selectedMatch(s) orelse return false;
    return !m.installed;
}

// A closed switch on the kind: a new variant is a compile error here, never a
// silent default — the label must be chosen deliberately.
fn kindLabel(k: Kind) []const u8 {
    return switch (k) {
        .formula => "formula",
        .cask => "cask",
    };
}

/// Pure render: by phase, guidance, a "searching…" status, "no matches", or the
/// ranked result list. A pure function of `(state, rect)` so a resize is a
/// re-render.
pub fn render(s: *const State, f: *tab.Frame, r: tab.Rect) void {
    if (r.height == 0) return;
    // Keys live in the shared footer now, so the body owns the whole rect.
    switch (s.phase) {
        .searching => renderStatus(f, r, "searching…"),
        .idle => renderStatus(f, r, "Press Enter or / to type a query, then Enter to search."),
        .loaded => if (s.items.len == 0)
            renderStatus(f, r, "No matches.")
        else
            renderLoaded(s, f, r),
    }
}

// Bottom-pane budget for the info pane; the split never takes more than half the
// content so the result list always survives.
const detail_rows: u16 = 3;

/// The results, with an `mt info` pane docked at the bottom when one is open.
fn renderLoaded(s: *const State, f: *tab.Frame, r: tab.Rect) void {
    var list_rect = r;
    if (s.detail) |info| {
        const dh = @min(@as(u16, detail_rows), r.height / 2);
        if (dh > 0 and dh < r.height) {
            list_rect.height = r.height - dh;
            renderDetail(info, f, .{ .row = r.row + list_rect.height, .col = r.col, .width = r.width, .height = dh });
        }
    }
    renderList(s, f, list_rect);
}

/// The `mt info` pane for the active hit — works for an uninstalled hit too,
/// which is why a search result can open it at all.
fn renderDetail(info: info_json.Info, f: *tab.Frame, rect: tab.Rect) void {
    var deps_buf: [512]u8 = undefined;
    const fields = [_]detail_pane.Field{
        .{ .label = "Version", .value = if (info.version.len != 0) info.version else "-" },
        .{ .label = "Tap", .value = if (info.tap.len != 0) info.tap else "-" },
        .{ .label = "Dependencies", .value = joinDeps(&deps_buf, info.dependencies) },
    };
    detail_pane.render(f, &fields, rect);
}

/// Comma-join a dependency list into `buf`; "none" when empty. Truncates if the
/// list overruns the buffer (the pane truncates to the column budget anyway).
fn joinDeps(buf: []u8, deps: []const []const u8) []const u8 {
    if (deps.len == 0) return "none";
    var len: usize = 0;
    for (deps, 0..) |d, i| {
        if (i != 0) append(buf, &len, ", ");
        append(buf, &len, d);
    }
    return buf[0..len];
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
        // Multi-select checkbox first (its own colour); the reverse-video
        // selection wraps only the text columns so the SGRs never tangle. An
        // installed hit can't be selected, so it shows the blocked box.
        const checked = i < s.checked.len and s.checked[i];
        tab.putCheckbox(f, if (m.installed) .blocked else if (checked) tab.Check.on else .off);
        const selected = i == v.selected;
        if (selected) f.put(reverse);
        var rb: [256]u8 = undefined;
        f.putContent(scroll_list.truncate(formatRow(&rb, m), rect.width -| 4)); // 4 cols on the checkbox
        if (selected) f.put(color.Style.reset.code());
    }
}

// SGR reverse-video for the selection, matching the other tabs' convention.
const reverse = "\x1b[7m";

/// One list row (after the checkbox): the package name, the kind (formula/cask),
/// then an "installed" marker for a hit already on the system. ASCII columns,
/// grapheme-naive like the rest.
fn formatRow(buf: []u8, m: Match) []const u8 {
    var len: usize = 0;
    appendPad(buf, &len, m.name, 28);
    append(buf, &len, " ");
    appendPad(buf, &len, kindLabel(m.kind), 8);
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

test "enter opens info for the active hit" {
    var s: State = .{ .items = &sample, .phase = .loaded };
    step(&s, .enter);
    try testing.expectEqual(Request.info, s.request);
}

test "enter is inert on an empty result list" {
    var s: State = .{ .items = &.{} };
    step(&s, .enter);
    try testing.expectEqual(Request.none, s.request);
}

test "esc closes the info pane" {
    const info: info_json.Info = .{ .name = "wget", .version = "1", .tap = "", .dependencies = &.{} };
    var s: State = .{ .items = &sample, .detail = info };
    step(&s, .esc);
    try testing.expect(s.detail == null);
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

test "space toggles the active row's checkbox; an installed hit is never selectable" {
    var checked = [_]bool{false} ** 3;
    var s: State = .{ .items = &sample, .checked = &checked, .phase = .loaded };
    s.chrome.view.selected = 0; // wget, not installed
    step(&s, .space);
    try testing.expect(checked[0]);
    step(&s, .space);
    try testing.expect(!checked[0]); // toggles back off

    s.chrome.view.selected = 1; // firefox, already installed
    step(&s, .space);
    try testing.expect(!checked[1]); // installed rows can't be checked
}

test "i installs a checked, not-installed hit even when the active row is installed" {
    var checked = [_]bool{ true, false, false }; // wget checked
    var s: State = .{ .items = &sample, .checked = &checked, .phase = .loaded };
    s.chrome.view.selected = 1; // active = firefox (installed)
    step(&s, ch('i'));
    try testing.expectEqual(Request.install, s.request);
}

test "i is inert when only already-installed rows are checked" {
    var checked = [_]bool{ false, true, false }; // firefox (installed) checked
    var s: State = .{ .items = &sample, .checked = &checked, .phase = .loaded };
    step(&s, ch('i'));
    try testing.expectEqual(Request.none, s.request);
}

test "render draws a multi-select checkbox per result row" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var checked = [_]bool{ true, false, false };
    const s: State = .{ .items = &sample, .checked = &checked, .phase = .loaded };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "✓") != null); // wget checked
    try testing.expect(std.mem.indexOf(u8, out, "[ ]") != null); // an unchecked box
    try testing.expect(std.mem.indexOf(u8, out, "[-]") != null); // firefox installed → blocked
}

test "render docks the info pane when one is open" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const info: info_json.Info = .{ .name = "wget", .version = "1.25.0", .tap = "homebrew/core", .dependencies = &.{"openssl@3"} };
    const s: State = .{ .items = &sample, .phase = .loaded, .detail = info };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 16 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "1.25.0") != null); // version field
    try testing.expect(std.mem.indexOf(u8, out, "openssl@3") != null); // a dependency
    try testing.expect(std.mem.indexOf(u8, out, "wget") != null); // the list still shows
}

test "render shows guidance in the idle phase before any query is committed" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .phase = .idle };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    try testing.expect(std.mem.indexOf(u8, f.slice(), "type a query") != null);
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

test "render lists hits with the kind label and an installed marker" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample, .phase = .loaded };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "wget") != null);
    try testing.expect(std.mem.indexOf(u8, out, "firefox") != null);
    try testing.expect(std.mem.indexOf(u8, out, "formula") != null); // kind as plain text, no glyph
    try testing.expect(std.mem.indexOf(u8, out, "cask") != null);
    try testing.expect(std.mem.indexOf(u8, out, "◆") == null); // the glyph is gone
    try testing.expect(std.mem.indexOf(u8, out, "installed") != null); // firefox marker
}

test "render highlights the selected hit" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var s: State = .{ .items = &sample, .phase = .loaded };
    s.chrome.view.selected = 0;
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    try testing.expect(std.mem.indexOf(u8, f.slice(), reverse) != null);
}

test "footerHint exposes the tab's action keys for the shared footer" {
    try testing.expect(std.mem.indexOf(u8, footerHint(), "select") != null);
    try testing.expect(std.mem.indexOf(u8, footerHint(), "install") != null);
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
