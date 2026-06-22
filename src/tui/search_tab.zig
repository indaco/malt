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
/// `info` opens `mt info` for the active hit (works for uninstalled hits too);
/// `toggle` adds/removes the active hit in the shell-owned cross-query basket
/// (selection outlives the per-query result list, so the leaf cannot own it);
/// `remove` drops the highlighted basket pick; `clear` empties the whole basket.
pub const Request = enum { none, search, install, info, toggle, remove, clear };

/// The read lifecycle the render reflects. `idle` before any query is committed
/// (show guidance), `searching` while the blocking remote read runs (the shell
/// flips it and repaints first), `loaded` once results are parsed (the list, or
/// "no matches" when empty).
pub const Phase = enum { idle, searching, loaded };

/// Which list the body shows. `results` is the ranked query hits (default);
/// `basket` is the cross-query selection, so a pick made under an earlier query
/// stays visible — and removable — even when its row is off the current results.
pub const View = enum { results, basket };

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
    /// Cross-query basket size, mirrored from the shell-owned selection (no
    /// allocator here). Gates `i` (a non-empty basket installs even with no rows
    /// on screen) and sizes the footer's `N selected`.
    selected_count: usize = 0,
    /// The cross-query basket's entries, borrowed from the shell-owned set (no
    /// allocator here). Rendered in the `basket` view and indexed by the cursor
    /// there; the leaf reads names/kinds only — the shell owns and frees them.
    basket: []const SelEntry = &.{},
    /// Which list the body shows; `l` toggles it.
    view: View = .results,
};

/// One basket row the shell hands the leaf: a borrowed `(name, kind)`. The bytes
/// are owned (and freed) by the shell-owned set; the leaf renders them (scrubbed)
/// and reads them to name a removal — never interprets or frees them.
pub const SelEntry = struct { name: []const u8, kind: Kind };

pub fn title() []const u8 {
    return "Search";
}

/// The tab's action keys, surfaced in the shared footer next to the global keys.
/// The contract default is the results view; the shell calls `footerHintFor` with
/// the live view so the footer tracks `l`.
pub fn footerHint() []const u8 {
    return footerHintFor(.results);
}

/// The action keys for a given view. Both hints end in `i: install` so the shell
/// can fold the basket count straight onto the tail (`i: install N selected`).
pub fn footerHintFor(view: View) []const u8 {
    return switch (view) {
        .results => "space: select   enter: info   l: basket   i: install",
        .basket => "space/d: remove   l: results   n: clear   i: install",
    };
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

/// Request a basket toggle for the active row. An already-installed hit is never
/// selectable, so it is inert. The shell owns the cross-query basket and writes
/// the projected `checked` slice; the pure leaf only signals intent here.
fn requestToggle(s: *State) void {
    const m = selectedMatch(s) orelse return;
    if (m.installed) return;
    s.request = .toggle;
}

/// The basket pick the cursor points at, clamping the (shell-driven, unbounded)
/// selection into the basket. The shell reads its `name`/`kind` to resolve a
/// removal. Null on an empty basket.
pub fn selectedBasketEntry(s: *const State) ?SelEntry {
    if (s.basket.len == 0) return null;
    return s.basket[@min(s.chrome.view.selected, s.basket.len - 1)];
}

/// Request dropping the highlighted basket pick; inert on an empty basket.
fn requestRemove(s: *State) void {
    if (selectedBasketEntry(s) != null) s.request = .remove;
}

/// `space` selects in the results view and removes in the basket view — the one
/// key, its meaning set by the view.
fn selectKey(s: *State) void {
    switch (s.view) {
        .results => requestToggle(s),
        .basket => requestRemove(s),
    }
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
        // `space` selects in the results view and removes in the basket view; `d`
        // is the basket-view remove alias and is inert in the results view.
        .space => selectKey(s),
        .char => |c| if (c.len == 1) switch (c.bytes[0]) {
            // `i` installs the multi-selection (or the active row when nothing is
            // checked); inert when there is nothing installable to do.
            'i' => if (anyInstallable(s)) {
                s.request = .install;
            },
            'l' => s.view = if (s.view == .results) .basket else .results,
            // `n` clears the whole basket from either view; inert when it is empty.
            'n' => if (s.selected_count > 0) {
                s.request = .clear;
            },
            'd' => if (s.view == .basket) requestRemove(s),
            else => {},
        },
        .esc => s.detail = null, // close the info pane
        else => {},
    }
}

/// True when `i` would install something: a non-empty basket (which installs as a
/// whole, even off-screen picks), or — with an empty basket — an installable
/// active row. Mirrors what the shell's install argv resolves, so `i` stays inert
/// only when the basket is empty and the active row is not installable.
fn anyInstallable(s: *const State) bool {
    if (s.selected_count > 0) return true;
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
    // Keys live in the shared footer now, so the body owns the whole rect. The
    // basket view is phase-independent: it shows the cross-query picks, which
    // outlive any single query's lifecycle.
    switch (s.view) {
        .results => renderResults(s, f, r),
        .basket => renderBasket(s, f, r),
    }
}

fn renderResults(s: *const State, f: *tab.Frame, r: tab.Rect) void {
    switch (s.phase) {
        .searching => renderStatus(f, r, "searching…"),
        .idle => renderStatus(f, r, "Press Enter or / to type a query, then Enter to search."),
        .loaded => if (s.items.len == 0)
            renderStatus(f, r, "No matches.")
        else
            renderLoaded(s, f, r),
    }
}

/// The cross-query basket: every pick listed by `(name, kind)`, with the cursor
/// row highlighted. No checkbox — membership is the list — and the names go
/// through `putContent`, so a hostile pick name stays inert. A pure function of
/// `(basket, rect)` so a resize is a re-render.
fn renderBasket(s: *const State, f: *tab.Frame, rect: tab.Rect) void {
    if (s.basket.len == 0) return tab.renderHint(f, rect, "Nothing selected.");
    tab.renderHeading(f, rect, 0, &.{
        .{ .label = "NAME", .width = 28 },
        .{ .label = "KIND", .width = 8 },
    });
    const list: tab.Rect = .{ .row = rect.row + 1, .col = rect.col, .width = rect.width, .height = rect.height -| 1 };
    if (list.height == 0) return; // the heading took the only row
    const v = scroll_list.clamp(s.chrome.view, s.basket.len, list.height);
    for (s.basket, 0..) |e, i| {
        if (i < v.offset) continue;
        const screen = i - v.offset;
        if (screen >= list.height) break;
        f.moveTo(list.row + @as(u16, @intCast(screen)), list.col);
        const selected = i == v.selected;
        if (selected) {
            f.put(color.selectionAccent());
            f.put(color.Style.reverse.code());
        }
        var rb: [256]u8 = undefined;
        f.putContent(scroll_list.truncate(formatBasketRow(&rb, e), list.width));
        if (selected) f.put(color.Style.reset.code());
    }
}

/// One basket row: the package name and its kind, same column widths as a result
/// row's. ASCII columns, grapheme-naive like the rest.
fn formatBasketRow(buf: []u8, e: SelEntry) []const u8 {
    var len: usize = 0;
    appendPad(buf, &len, e.name, 28);
    append(buf, &len, " ");
    appendPad(buf, &len, kindLabel(e.kind), 8);
    return buf[0..len];
}

/// The results, with an `mt info` pane docked at the bottom when one is open.
/// The pane sizes to its (wrapped) content, capped at half the height so the
/// result list survives. The info pane works for an uninstalled hit too, which
/// is why a search result can open it at all.
fn renderLoaded(s: *const State, f: *tab.Frame, r: tab.Rect) void {
    var list_rect = r;
    if (s.detail) |info| {
        var deps_buf: [512]u8 = undefined;
        const fields = [_]detail_pane.Field{
            .{ .label = "Version", .value = if (info.version.len != 0) info.version else "-" },
            .{ .label = "Tap", .value = if (info.tap.len != 0) info.tap else "-" },
            .{ .label = "Dependencies", .value = joinDeps(&deps_buf, info.dependencies) },
        };
        const dh = @min(detail_pane.neededRows(&fields, r.width), r.height / 2);
        if (dh > 0 and dh < r.height) {
            list_rect.height = r.height - dh;
            detail_pane.render(f, &fields, .{ .row = r.row + list_rect.height, .col = r.col, .width = r.width, .height = dh });
        }
    }
    renderList(s, f, list_rect);
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
    // A fixed bold heading rides above the results and costs them one row, past
    // the 4-col checkbox.
    tab.renderHeading(f, rect, 4, &.{
        .{ .label = "NAME", .width = 28 },
        .{ .label = "KIND", .width = 8 },
    });
    const list: tab.Rect = .{ .row = rect.row + 1, .col = rect.col, .width = rect.width, .height = rect.height -| 1 };
    if (list.height == 0) return; // the heading took the only row
    const v = scroll_list.clamp(s.chrome.view, s.items.len, list.height);
    for (s.items, 0..) |m, i| {
        if (i < v.offset) continue;
        const screen = i - v.offset;
        if (screen >= list.height) break;
        f.moveTo(list.row + @as(u16, @intCast(screen)), list.col);
        // Multi-select checkbox first (its own colour); the reverse-video
        // selection wraps only the text columns so the SGRs never tangle. An
        // installed hit can't be selected, so it shows the blocked box.
        const checked = i < s.checked.len and s.checked[i];
        tab.putCheckbox(f, if (m.installed) .blocked else if (checked) tab.Check.on else .off);
        const selected = i == v.selected;
        if (selected) { // the accent backgrounds the cursor row under a theme
            f.put(color.selectionAccent());
            f.put(color.Style.reverse.code());
        }
        var rb: [256]u8 = undefined;
        f.putContent(scroll_list.truncate(formatRow(&rb, m), list.width -| 4)); // 4 cols on the checkbox
        if (selected) f.put(color.Style.reset.code());
    }
}

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

test "space requests a basket toggle for the active not-installed row" {
    var s: State = .{ .items = &sample, .phase = .loaded };
    s.chrome.view.selected = 0; // wget, not installed
    step(&s, .space);
    try testing.expectEqual(Request.toggle, s.request);
}

test "space is inert on an already-installed row (never selectable)" {
    var s: State = .{ .items = &sample, .phase = .loaded };
    s.chrome.view.selected = 1; // firefox, already installed
    step(&s, .space);
    try testing.expectEqual(Request.none, s.request);
}

test "space is inert on an empty result list" {
    var s: State = .{ .items = &.{} };
    step(&s, .space);
    try testing.expectEqual(Request.none, s.request);
}

test "i installs the basket even when the active row is already installed" {
    var s: State = .{ .items = &sample, .selected_count = 1, .phase = .loaded };
    s.chrome.view.selected = 1; // active = firefox (installed); the basket still wins
    step(&s, ch('i'));
    try testing.expectEqual(Request.install, s.request);
}

test "i installs the basket even when none of its picks are on screen" {
    // The cross-query case: the basket holds off-list picks, so `i` must fire even
    // though the current query returned nothing checkable.
    var s: State = .{ .items = &.{}, .selected_count = 2, .phase = .loaded };
    step(&s, ch('i'));
    try testing.expectEqual(Request.install, s.request);
}

test "i is inert only when the basket is empty and the active row is not installable" {
    var s: State = .{ .items = &sample, .selected_count = 0, .phase = .loaded };
    s.chrome.view.selected = 1; // empty basket + active firefox (installed) → nothing to do
    step(&s, ch('i'));
    try testing.expectEqual(Request.none, s.request);
}

test "the cores tolerate a checked slice shorter than items without trapping" {
    // Before the shell sizes `checked` it can be empty; the cores must not index
    // past it. Toggle is then inert and install falls back to the active row.
    var s: State = .{ .items = &sample, .checked = &.{}, .phase = .loaded };
    step(&s, .space); // no checked slot for the active row → inert, no trap
    step(&s, ch('i')); // resolves over the empty set + the active (installable) row
    try testing.expectEqual(Request.install, s.request);
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

test "render heads the result columns in bold, indented past the checkbox" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample, .phase = .loaded };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, color.Style.bold.code()) != null);
    // 4-col checkbox indent plus exact padding aligns NAME / KIND over their values.
    try testing.expect(std.mem.indexOf(u8, out, "    NAME" ++ " " ** 25 ++ "KIND") != null);
    try testing.expect(std.mem.indexOf(u8, out, "wget") != null); // the list still renders below
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
    try testing.expect(std.mem.indexOf(u8, f.slice(), color.Style.reverse.code()) != null);
}

test "footerHint exposes the tab's action keys for the shared footer" {
    try testing.expect(std.mem.indexOf(u8, footerHint(), "select") != null);
    try testing.expect(std.mem.indexOf(u8, footerHint(), "install") != null);
}

test "l flips the body between the results and basket views" {
    var s: State = .{ .items = &sample, .phase = .loaded };
    try testing.expectEqual(View.results, s.view); // results by default
    step(&s, ch('l'));
    try testing.expectEqual(View.basket, s.view);
    step(&s, ch('l')); // and back
    try testing.expectEqual(View.results, s.view);
}

const basket_sample = [_]SelEntry{
    .{ .name = "bat", .kind = .formula },
    .{ .name = "firefox", .kind = .cask },
};

test "the basket view lists every pick, including ones off the current results" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    // `sample` holds wget/firefox/ripgrep; the basket holds bat (off the results)
    // and firefox. The basket view must show bat even though no result row carries it.
    const s: State = .{ .items = &sample, .phase = .loaded, .view = .basket, .basket = &basket_sample };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "bat") != null); // an off-results pick is visible
    try testing.expect(std.mem.indexOf(u8, out, "firefox") != null);
    try testing.expect(std.mem.indexOf(u8, out, "formula") != null);
    try testing.expect(std.mem.indexOf(u8, out, "cask") != null);
}

test "the basket view shows a placeholder when nothing is selected, not a blank pane" {
    var buf: [1024]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample, .phase = .loaded, .view = .basket, .basket = &.{} };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    try testing.expect(std.mem.indexOf(u8, f.slice(), "Nothing selected") != null);
}

test "a hostile basket name cannot inject a control sequence into the frame" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const evil = [_]SelEntry{.{ .name = "ev\x1b]0;pwn\x07il", .kind = .formula }};
    const s: State = .{ .phase = .loaded, .view = .basket, .basket = &evil };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "\x1b]0;pwn") == null); // OSC introducer broken
    try testing.expect(std.mem.indexOfScalar(u8, out, 0x07) == null); // BEL dropped
}

test "the basket view on a zero-height rect is a clean no-op" {
    var buf: [256]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .phase = .loaded, .view = .basket, .basket = &basket_sample };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 0 }); // must not trap
    try testing.expectEqual(@as(usize, 0), f.slice().len);
}

test "selectedBasketEntry names the highlighted pick, clamping the cursor" {
    var s: State = .{ .view = .basket, .basket = &basket_sample };
    s.chrome.view.selected = 0;
    try testing.expectEqualStrings("bat", selectedBasketEntry(&s).?.name);
    s.chrome.view.selected = 99; // clamps to the last pick
    try testing.expectEqualStrings("firefox", selectedBasketEntry(&s).?.name);
}

test "selectedBasketEntry on an empty basket is null" {
    const s: State = .{ .view = .basket, .basket = &.{} };
    try testing.expect(selectedBasketEntry(&s) == null);
}

test "space in the basket view requests removing the highlighted pick" {
    var s: State = .{ .view = .basket, .basket = &basket_sample };
    s.chrome.view.selected = 0;
    step(&s, .space);
    try testing.expectEqual(Request.remove, s.request);
}

test "d in the basket view also requests a remove" {
    var s: State = .{ .view = .basket, .basket = &basket_sample };
    s.chrome.view.selected = 1;
    step(&s, ch('d'));
    try testing.expectEqual(Request.remove, s.request);
}

test "d in the results view is inert (remove is a basket-only key)" {
    var s: State = .{ .items = &sample, .phase = .loaded, .view = .results };
    step(&s, ch('d'));
    try testing.expectEqual(Request.none, s.request);
}

test "space in the basket view is inert when the basket is empty" {
    var s: State = .{ .view = .basket, .basket = &.{} };
    step(&s, .space);
    try testing.expectEqual(Request.none, s.request);
}

test "n requests clearing the basket from either view when it holds picks" {
    var s: State = .{ .items = &sample, .phase = .loaded, .selected_count = 2 };
    step(&s, ch('n')); // results view
    try testing.expectEqual(Request.clear, s.request);

    s.request = .none;
    s.view = .basket;
    step(&s, ch('n')); // basket view
    try testing.expectEqual(Request.clear, s.request);
}

test "n on an empty basket is inert" {
    var s: State = .{ .items = &sample, .phase = .loaded, .selected_count = 0 };
    step(&s, ch('n'));
    try testing.expectEqual(Request.none, s.request);
}

test "the footer hint reflects the active view" {
    // Results view: the select/install keys plus the basket toggle.
    try testing.expect(std.mem.indexOf(u8, footerHintFor(.results), "l: basket") != null);
    try testing.expect(std.mem.indexOf(u8, footerHintFor(.results), "install") != null);
    // Basket view: remove + the toggle back to results.
    try testing.expect(std.mem.indexOf(u8, footerHintFor(.basket), "remove") != null);
    try testing.expect(std.mem.indexOf(u8, footerHintFor(.basket), "l: results") != null);
    try testing.expect(std.mem.indexOf(u8, footerHintFor(.basket), "install") != null);
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
