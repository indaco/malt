//! malt — Search tab for `mt tui`: find and install new packages.
//!
//! Leaf module. Pure cores only: `step` maps a key to a `Cmd` (`i` installs the
//! selection, Enter reads `mt info`) or performs a pure basket op in place; the
//! shell commits the filter-as-query via `searchCmd`. `update` folds the pump's
//! result back (a search parse becomes the results, an install refetches). The tab
//! names effects as data and never imports the runner. `render(state, frame, rect)`
//! is a pure function of `(state, rect)` so a resize is a re-render.
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
const cmd = @import("cmd.zig");
const ctx = @import("ctx.zig");
const detail_pane = @import("detail_pane.zig");
const info_json = @import("json/info.zig");
const search_json = @import("json/search.zig");
pub const Match = search_json.Match;
const Kind = search_json.Kind;
const scroll_list = @import("scroll_list.zig");
const tab = @import("tab.zig");

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

/// Search runs synchronously on demand; it never background-fetches.
pub const fetch_spec: ?tab.FetchSpec = null;

/// One basket row the shell hands the leaf: a borrowed `(name, kind)`. The bytes
/// are owned (and freed) by the shell-owned set; the leaf renders them (scrubbed)
/// and reads them to name a removal — never interprets or frees them.
pub const SelEntry = struct { name: []const u8, kind: Kind };

/// The cross-query selection ("basket"): the packages checked across one or more
/// queries, keyed by `(name, kind)` and owning its name bytes so a pick outlives
/// the per-query parse it was checked in. The pure leaf never sees it — only the
/// projected `checked` slice and the borrowed `entries`.
pub const Selection = struct {
    entries: std.ArrayList(SelEntry) = .empty,

    pub fn indexOf(self: *const Selection, name: []const u8, kind: Kind) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (e.kind == kind and std.mem.eql(u8, e.name, name)) return i;
        }
        return null;
    }

    pub fn contains(self: *const Selection, name: []const u8, kind: Kind) bool {
        return self.indexOf(name, kind) != null;
    }

    /// Add the pick if absent, remove it if present — the `space` toggle. Owns a
    /// copy of `name`, so the entry survives the parse storage `name` borrows.
    pub fn toggle(self: *Selection, allocator: std.mem.Allocator, name: []const u8, kind: Kind) !void {
        if (self.indexOf(name, kind)) |i| {
            allocator.free(self.entries.items[i].name);
            _ = self.entries.swapRemove(i); // order is irrelevant for a set
            return;
        }
        const owned = try allocator.dupe(u8, name);
        errdefer allocator.free(owned);
        try self.entries.append(allocator, .{ .name = owned, .kind = kind });
    }

    /// Drop the pick if present, freeing its bytes — the basket-view `d`/`space`.
    /// Absent is a no-op, so a stale removal can never trap.
    pub fn remove(self: *Selection, allocator: std.mem.Allocator, name: []const u8, kind: Kind) void {
        if (self.indexOf(name, kind)) |i| {
            allocator.free(self.entries.items[i].name);
            _ = self.entries.swapRemove(i); // order is irrelevant for a set
        }
    }

    /// Empty the basket, freeing every pick's bytes — the `n` escape hatch. Keeps
    /// the backing capacity for reuse; `deinit` releases that at teardown.
    pub fn clear(self: *Selection, allocator: std.mem.Allocator) void {
        for (self.entries.items) |e| allocator.free(e.name);
        self.entries.clearRetainingCapacity();
    }

    pub fn deinit(self: *Selection, allocator: std.mem.Allocator) void {
        for (self.entries.items) |e| allocator.free(e.name);
        self.entries.deinit(allocator);
    }
};

/// Tab-private parse storage: the query results the tab borrows, the parallel
/// checkbox buffer, the cross-query basket, and the open info pane's parse. Owned
/// beside the tab so each lifetime lives here, not in a central store. `deinit`
/// frees every owned buffer.
pub const Storage = struct {
    search: ?search_json.Parsed = null,
    checked: []bool = &.{},
    selected: Selection = .{},
    detail: ?info_json.Parsed = null,

    pub fn deinit(self: *Storage, allocator: std.mem.Allocator) void {
        if (self.search) |p| p.deinit();
        if (self.checked.len != 0) allocator.free(self.checked);
        self.selected.deinit(allocator);
        if (self.detail) |p| p.deinit();
    }
};

pub fn title() []const u8 {
    return "Search";
}

pub const Hit = tab.Hit;

/// One list view's on-screen geometry: the sub-rect the rows occupy, the `clamp`ed
/// view, and the row `count`. The single source of truth each `render` path shares
/// with `hitTest`, so a painted row and the hit-test can never disagree.
const Geometry = struct { list: tab.Rect, view: scroll_list.View, count: usize };

/// Results geometry: the bold heading rides row 0, so the list starts one row down.
/// Detail-pane docking is deliberately ignored here (as in Installed) — the shell
/// feeds `hitTest` the pre-dock rect.
fn resultsGeometry(s: *const State, rect: tab.Rect) Geometry {
    const list: tab.Rect = .{ .row = rect.row + 1, .col = rect.col, .width = rect.width, .height = rect.height -| 1 };
    return .{ .list = list, .view = scroll_list.clamp(s.chrome.view, s.items.len, list.height), .count = s.items.len };
}

/// Basket geometry: the dim count title and the heading each cost a row, so the
/// list starts two rows down.
fn basketGeometry(s: *const State, rect: tab.Rect) Geometry {
    const list: tab.Rect = .{ .row = rect.row + 2, .col = rect.col, .width = rect.width, .height = rect.height -| 2 };
    return .{ .list = list, .view = scroll_list.clamp(s.chrome.view, s.basket.len, list.height), .count = s.basket.len };
}

/// Map a click to the row it lands on, branching on the active view. `Hit.open` is
/// a capability flag the shell reads on a right-click: results rows open info
/// (parity with Enter), basket rows do not (their verb is remove), so a right-click
/// there is a no-op. A left-click uses only `index` to move the cursor. `click_col`
/// is unused — rows are full-width.
pub fn hitTest(s: *const State, rect: tab.Rect, click_row: u16, click_col: u16) ?Hit {
    _ = click_col; // full-width rows: the column carries no row identity
    const g = switch (s.view) {
        // The results list is painted only when loaded; while a re-query is
        // searching, stale items linger behind a status line, so map nothing. The
        // docked info pane shrinks the list, so hit-test against the painted rect.
        .results => if (s.phase == .loaded) resultsGeometry(s, resultsContentRect(s, rect)) else return null,
        .basket => basketGeometry(s, rect), // the basket is phase-independent
    };
    const idx = scroll_list.rowAt(g.view, g.list.row, g.list.height, g.count, click_row) orelse return null;
    return .{ .index = idx, .open = s.view == .results };
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
fn doToggle(allocator: std.mem.Allocator, s: *State, storage: *Storage) void {
    const m = selectedMatch(s) orelse return;
    if (m.installed) return; // an already-installed hit is never selectable
    // OOM drops the toggle, not the TUI; the user retries. The basket op is pure
    // state (no I/O), so it stays out of the effect path.
    storage.selected.toggle(allocator, m.name, m.kind) catch return;
    projectSearchChecked(storage);
    syncSelected(s, storage);
}

/// The basket pick the cursor points at, clamping the (shell-driven, unbounded)
/// selection into the basket. The shell reads its `name`/`kind` to resolve a
/// removal. Null on an empty basket.
pub fn selectedBasketEntry(s: *const State) ?SelEntry {
    if (s.basket.len == 0) return null;
    return s.basket[@min(s.chrome.view.selected, s.basket.len - 1)];
}

/// Drop the highlighted basket pick, then re-project; inert on an empty basket.
fn doRemove(allocator: std.mem.Allocator, s: *State, storage: *Storage) void {
    const e = selectedBasketEntry(s) orelse return;
    storage.selected.remove(allocator, e.name, e.kind);
    projectSearchChecked(storage);
    syncSelected(s, storage);
}

/// Empty the whole basket, then re-project; inert when it is already empty.
fn doClear(allocator: std.mem.Allocator, s: *State, storage: *Storage) void {
    if (s.selected_count == 0) return;
    storage.selected.clear(allocator);
    projectSearchChecked(storage);
    syncSelected(s, storage);
}

/// `space` selects in the results view and removes in the basket view — the one
/// key, its meaning set by the view.
fn selectKey(allocator: std.mem.Allocator, s: *State, storage: *Storage) void {
    switch (s.view) {
        .results => doToggle(allocator, s, storage),
        .basket => doRemove(allocator, s, storage),
    }
}

/// Pure transition. `i` returns the install `Cmd`; Enter opens `mt info`; the
/// basket ops (`space`/`d`/`n`) mutate the shell-owned selection in place (pure
/// state, `Cmd.none`) — they leave the effect path. Committing the query (Enter's
/// other meaning) is driven by the shell on filter-commit via `searchCmd`.
pub fn step(allocator: std.mem.Allocator, mt_path: []const u8, s: *State, storage: *Storage, key: tab.Key) cmd.Cmd {
    switch (key) {
        // Enter on a result opens `mt info` for it, or toggles the pane closed when it
        // is already open for that row (a second Enter / a right-click dismisses it).
        // Committing the query is driven by the shell on filter-commit, so they never collide.
        .enter => if (selectedMatch(s)) |m| {
            if (resultsDetailOpen(s, m)) s.detail = null else return openSearchInfoCmd(allocator, mt_path, s);
        },
        // `space` selects in the results view and removes in the basket view; `d`
        // is the basket-view remove alias and is inert in the results view.
        .space => selectKey(allocator, s, storage),
        .char => |c| if (c.len == 1) switch (c.bytes[0]) {
            // `i` installs the multi-selection (or the active row when nothing is
            // checked); inert when there is nothing installable to do.
            'i' => if (anyInstallable(s)) return installCmd(allocator, mt_path, s, storage),
            'l' => s.view = if (s.view == .results) .basket else .results,
            'n' => doClear(allocator, s, storage), // clears the whole basket; inert when empty
            'd' => if (s.view == .basket) doRemove(allocator, s, storage),
            else => {},
        },
        .esc => s.detail = null, // close the info pane
        // No narrowing filter here; the cursor indexes the active view's list.
        .end => s.chrome.view.selected = (switch (s.view) {
            .results => s.items.len,
            .basket => s.basket.len,
        }) -| 1,
        else => {},
    }
    return .none;
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
    // A dim title orients a fresh toggle-in and carries the count, so the row it
    // costs isn't pure decoration.
    var tb: [48]u8 = undefined;
    tab.renderHint(f, rect, std.fmt.bufPrint(&tb, "Basket - {d} selected", .{s.basket.len}) catch "Basket");
    const head: tab.Rect = .{ .row = rect.row + 1, .col = rect.col, .width = rect.width, .height = rect.height -| 1 };
    if (head.height == 0) return; // the title took the only row
    tab.renderHeading(f, head, 0, &.{
        .{ .label = "NAME", .width = 28 },
        .{ .label = "KIND", .width = 8 },
    });
    const g = basketGeometry(s, rect);
    const list = g.list;
    if (list.height == 0) return; // the heading took the only row
    const v = g.view;
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
        const fields = resultsFields(info, &deps_buf);
        const dh = detail_pane.dockHeight(&fields, r.width, r.height);
        if (dh > 0) {
            list_rect.height = r.height - dh;
            detail_pane.render(f, &fields, .{ .row = r.row + list_rect.height, .col = r.col, .width = r.width, .height = dh });
        }
    }
    renderList(s, f, list_rect);
}

/// The info pane's fields for the open result, borrowing the caller's scratch for
/// the joined deps.
fn resultsFields(info: info_json.Info, deps_buf: []u8) [3]detail_pane.Field {
    return .{
        .{ .label = "Version", .value = if (info.version.len != 0) info.version else "-" },
        .{ .label = "Tap", .value = if (info.tap.len != 0) info.tap else "-" },
        .{ .label = "Dependencies", .value = joinDeps(deps_buf, info.dependencies) },
    };
}

/// The results rect `renderLoaded` paints into: the content minus the docked info
/// pane. Shared with `hitTest` so a click lands on the painted result even with a
/// pane open.
fn resultsContentRect(s: *const State, rect: tab.Rect) tab.Rect {
    var list_rect = rect;
    if (s.detail) |info| {
        var deps_buf: [512]u8 = undefined;
        const fields = resultsFields(info, &deps_buf);
        list_rect.height -|= detail_pane.dockHeight(&fields, rect.width, rect.height);
    }
    return list_rect;
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
    const g = resultsGeometry(s, rect);
    const list = g.list;
    if (list.height == 0) return; // the heading took the only row
    const v = g.view;
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

// ─── effect producers ───────────────────────────────────────────────────
// The tab names reads/mutations as `Cmd` values; the pump performs them and folds
// the result back through `update`. The basket ops are pure state (done in `step`)
// and never appear here. No I/O and no runner import.

/// Banner op strings for a recoverable fault, parity with the pre-reify error names.
const search_fail_op = "search failed";
const install_fail_op = "install failed";
const info_fail_op = "info read failed";

/// Build `mt search <query> --json` for the committed query, null when the query is
/// empty (the no-op — the view shows guidance, no read). The `query` element borrows
/// the filter buffer; the pump frees the returned slice, not its elements.
fn searchArgv(allocator: std.mem.Allocator, mt_path: []const u8, st: *const State) std.mem.Allocator.Error!?[]const []const u8 {
    const query = st.chrome.filter.slice();
    if (query.len == 0) return null; // empty query: no remote read
    return try cmd.jsonArgv(allocator, mt_path, &.{ "search", query });
}

/// The committed query's `mt search --json` read, or `Cmd.none` for an empty query.
fn searchReadCmd(allocator: std.mem.Allocator, mt_path: []const u8, s: *const State) cmd.Cmd {
    const argv = (searchArgv(allocator, mt_path, s) catch return .none) orelse return .none;
    return .{ .read = .{ .argv = argv, .mode = .polled, .parse = cmd.parserFor(.search, search_json.parse), .tag = .search, .fail_op = search_fail_op } };
}

/// The shell commits the filter-as-query on Enter and asks for this. Flips `phase`
/// to `searching` before the polled read (the shell repaints first); the fold
/// resets it to `loaded`, and a failed read resets it via `update` on `.failed`.
pub fn searchCmd(allocator: std.mem.Allocator, mt_path: []const u8, s: *State) cmd.Cmd {
    const c = searchReadCmd(allocator, mt_path, s);
    if (c == .read) s.phase = .searching;
    return c;
}

/// The `mt info <pkg> --json` read for the active hit, or `Cmd.none` when nothing is
/// selected. `mt info` resolves uninstalled hits too, so a result is inspectable
/// before any install.
/// True when the info pane is open for the selected result — matched by name, since
/// the pane is opened for the selection.
fn resultsDetailOpen(s: *const State, sel: Match) bool {
    const d = s.detail orelse return false;
    return std.mem.eql(u8, d.name, sel.name);
}

fn openSearchInfoCmd(allocator: std.mem.Allocator, mt_path: []const u8, s: *const State) cmd.Cmd {
    const m = selectedMatch(s) orelse return .none; // empty list: no-op
    const argv = cmd.jsonArgv(allocator, mt_path, &.{ "info", m.name }) catch return .none;
    return .{ .read = .{ .argv = argv, .mode = .polled, .parse = cmd.parserFor(.info, info_json.parse), .tag = .search, .fail_op = info_fail_op } };
}

/// The basket's `mt install …` mutation, or `Cmd.none` when nothing installable is
/// selected. `update` re-runs the query on success so the installed markers flip.
fn installCmd(allocator: std.mem.Allocator, mt_path: []const u8, s: *const State, storage: *const Storage) cmd.Cmd {
    const argv = (installArgv(allocator, mt_path, &storage.selected, s) catch return .none) orelse return .none;
    return .{ .run_mutation = .{ .argv = argv, .tag = .search, .fail_op = install_fail_op } };
}

/// Project the persistent selection onto a result list: a row is checked iff it is
/// selected and not already installed. A pure function of `(items, selection)` so it
/// runs identically after a query parse and after a toggle.
fn projectChecked(items: []const Match, checked: []bool, sel: *const Selection) void {
    for (items, checked) |m, *c| c.* = !m.installed and sel.contains(m.name, m.kind);
}

/// Fill the tab-owned `checked` slice from the selection. No-op before a query has
/// loaded.
fn projectSearchChecked(storage: *Storage) void {
    const items = if (storage.search) |p| p.items else return;
    projectChecked(items, storage.checked, &storage.selected);
}

/// Mirror the tab-owned basket onto the leaf state: the count (so the core can gate
/// `i` and the footer can size `N selected`) and the entries slice the basket view
/// renders. The pure core never owns the picks — it borrows this slice, refreshed
/// after every basket mutation (an append can move the backing buffer).
pub fn syncSelected(s: *State, storage: *const Storage) void {
    s.selected_count = storage.selected.entries.items.len;
    s.basket = storage.selected.entries.items;
}

/// Fold a completed effect back into the model. A delivered `search` parse becomes
/// the ranked results; an `info` parse opens the pane; a finished install refetches;
/// a `.failed` read leaves the "searching…" phase behind its banner.
pub fn update(allocator: std.mem.Allocator, mt_path: []const u8, s: *State, storage: *Storage, shared: *ctx.SharedModel, msg: cmd.Msg) cmd.Cmd {
    switch (msg) {
        .loaded => |parsed| switch (parsed) {
            .search => |sp| {
                applySearchParse(allocator, s, storage, sp) catch |err| {
                    sp.deinit(); // the fold failed to take ownership; free the arena
                    shared.banner.set(search_fail_op, @errorName(err));
                    s.phase = if (storage.search != null) .loaded else .idle;
                };
                return .none;
            },
            .info => |ip| {
                setInfoDetail(s, storage, ip);
                return .none;
            },
            // Search only issues search/info reads; free any misrouted parse.
            inline else => |p| {
                p.deinit();
                return .none;
            },
        },
        .mutated => |code| return foldInstall(allocator, mt_path, s, storage, shared, code),
        // A 0-byte exit-0 read shouldn't reach search on the happy path, but if it
        // does it must reset the phase like `.failed`, never strand the spinner.
        .cleared, .failed => {
            // Fall back to the last good results, or guidance if none ever loaded.
            s.phase = if (storage.search != null) .loaded else .idle;
            return .none;
        },
    }
}

/// Repoint the results at a fresh `search` parse, projecting the persistent basket
/// onto the new `checked` slice. Swapped only after `checked` is allocated, so a
/// fold OOM leaves the parse for the caller to free and keeps the last-good results.
fn applySearchParse(allocator: std.mem.Allocator, s: *State, storage: *Storage, parsed: search_json.Parsed) std.mem.Allocator.Error!void {
    // `checked` is a projection of the persistent basket, not per-query state: a pick
    // survives a re-query and re-checks its row when the package returns.
    const checked = try allocator.alloc(bool, parsed.items.len);
    if (storage.search) |old| old.deinit();
    if (storage.checked.len != 0) allocator.free(storage.checked);
    storage.search = parsed;
    storage.checked = checked;
    projectSearchChecked(storage);
    s.items = parsed.items;
    s.checked = checked;
    syncSelected(s, storage); // off-list picks count too, so refresh from the basket
    s.phase = .loaded;
    // A fresh query is a new result set, so an old cursor would point at an unrelated
    // row, and any open info pane is for a hit that may be gone.
    s.chrome.view = .{};
    s.detail = null;
    if (storage.detail) |old| {
        old.deinit();
        storage.detail = null;
    }
}

/// Open the info pane over the delivered `mt info` parse, freeing the previous one.
fn setInfoDetail(s: *State, storage: *Storage, parsed: info_json.Parsed) void {
    if (storage.detail) |old| old.deinit();
    storage.detail = parsed;
    s.detail = parsed.info;
}

/// Fold a finished install: a clean exit consumed the basket (clear it, mark the
/// siblings stale, re-run the query so markers flip); a non-zero exit retains the
/// basket behind a recoverable banner.
fn foldInstall(allocator: std.mem.Allocator, mt_path: []const u8, s: *State, storage: *Storage, shared: *ctx.SharedModel, code: u8) cmd.Cmd {
    const ok = code == 0;
    applyInstallOutcome(storage, allocator, ok); // clear on success, retain on failure
    syncSelected(s, storage); // basket may now be empty → leaf gate + footer reflect it
    if (!ok) {
        shared.banner.set(install_fail_op, "ChildFailed");
        return .none;
    }
    shared.markStaleAfter(.search); // Installed/Outdated/Services may have changed too
    return searchReadCmd(allocator, mt_path, s); // re-run the query; markers flip
}

/// Build the `mt install …` argv from the cross-query basket. The whole basket
/// installs, so an off-screen pick installs too. Empty basket ⇒ fall back to the
/// active row (the no-selection case); null when that row is absent or already
/// installed (the no-op). A single target keeps the explicit `--formula`/`--cask`
/// flag, because a name can exist as both and bare `mt install <name>` silently picks
/// the formula; a multi install passes bare names and lets `mt` detect each one's
/// kind. Basket names are owned, so the argv outlives the parse it was checked in.
fn installArgv(allocator: std.mem.Allocator, mt_path: []const u8, sel: *const Selection, st: *const State) std.mem.Allocator.Error!?[]const []const u8 {
    const entries = sel.entries.items;
    if (entries.len == 0) {
        // Empty basket: the active row, if it is installable.
        const i = selectedIndex(st) orelse return null;
        const m = st.items[i];
        if (m.installed) return null;
        return try cmd.inlineArgv(allocator, mt_path, &.{ "install", kindFlag(m.kind), m.name });
    }
    if (entries.len == 1) {
        const e = entries[0];
        return try cmd.inlineArgv(allocator, mt_path, &.{ "install", kindFlag(e.kind), e.name });
    }
    const argv = try allocator.alloc([]const u8, 2 + entries.len);
    argv[0] = mt_path;
    argv[1] = "install";
    for (entries, 0..) |e, k| argv[2 + k] = e.name;
    return argv;
}

/// The single-target disambiguation flag for a kind. A closed switch: a new kind is
/// a compile error, never a silent default.
fn kindFlag(k: Kind) []const u8 {
    return switch (k) {
        .formula => "--formula",
        .cask => "--cask",
    };
}

/// Post-install basket lifecycle: a clean install (exit 0) consumed the whole basket,
/// so clear it and re-project the now-empty checked slice; a failed install retains
/// the basket for retry. Pure over the storage — the seam the install path's
/// clear-on-success / retain-on-failure policy is tested through.
fn applyInstallOutcome(storage: *Storage, allocator: std.mem.Allocator, ok: bool) void {
    if (!ok) return; // retain for retry
    storage.selected.deinit(allocator);
    storage.selected = .{};
    projectSearchChecked(storage);
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

/// Drive `step` with an explicit storage (basket ops mutate it) and a fixed mt path.
fn stepKey(s: *State, storage: *Storage, key: tab.Key) cmd.Cmd {
    return step(testing.allocator, "/opt/malt/bin/mt", s, storage, key);
}

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

test "enter returns the `mt info` read for the active hit" {
    var s: State = .{ .items = &sample, .phase = .loaded };
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    const eff = stepKey(&s, &storage, .enter);
    defer testing.allocator.free(eff.read.argv);
    try testing.expect(eff == .read);
    try testing.expectEqual(cmd.MsgTag.search, eff.read.tag);
    try testing.expectEqualStrings("info", eff.read.argv[1]);
    try testing.expectEqualStrings("wget", eff.read.argv[2]);
}

test "enter is inert on an empty result list" {
    var s: State = .{ .items = &.{} };
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    try testing.expect(stepKey(&s, &storage, .enter) == .none);
}

test "esc closes the info pane" {
    const info: info_json.Info = .{ .name = "wget", .version = "1", .tap = "", .dependencies = &.{} };
    var s: State = .{ .items = &sample, .detail = info };
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    try testing.expect(stepKey(&s, &storage, .esc) == .none);
    try testing.expect(s.detail == null);
}

test "i on a not-installed active row (empty basket) returns the install mutation" {
    var s: State = .{ .items = &sample, .phase = .loaded };
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    s.chrome.view.selected = 0; // wget, not installed
    const eff = stepKey(&s, &storage, ch('i'));
    defer testing.allocator.free(eff.run_mutation.argv);
    try testing.expect(eff == .run_mutation);
    try testing.expectEqual(cmd.MsgTag.search, eff.run_mutation.tag);
    try testing.expectEqualStrings("install", eff.run_mutation.argv[1]);
    try testing.expectEqualStrings("--formula", eff.run_mutation.argv[2]);
    try testing.expectEqualStrings("wget", eff.run_mutation.argv[3]);
}

test "i on an already-installed active row (empty basket) is inert" {
    var s: State = .{ .items = &sample, .phase = .loaded };
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    s.chrome.view.selected = 1; // firefox, already installed
    try testing.expect(stepKey(&s, &storage, ch('i')) == .none);
}

test "i on an empty list is inert" {
    var s: State = .{ .items = &.{} };
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    try testing.expect(stepKey(&s, &storage, ch('i')) == .none);
}

test "an unrelated key is inert" {
    var s: State = .{ .items = &sample };
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    try testing.expect(stepKey(&s, &storage, ch('z')) == .none);
    try testing.expect(stepKey(&s, &storage, .down) == .none);
}

test "space adds the active not-installed row to the basket in place, no effect" {
    var s: State = .{ .items = &sample, .phase = .loaded };
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    s.chrome.view.selected = 0; // wget, not installed
    try testing.expect(stepKey(&s, &storage, .space) == .none); // pure state, no Cmd
    try testing.expect(storage.selected.contains("wget", .formula)); // in the basket now
    try testing.expectEqual(@as(usize, 1), s.selected_count); // mirrored onto the leaf

    // A second space toggles it back out.
    try testing.expect(stepKey(&s, &storage, .space) == .none);
    try testing.expect(!storage.selected.contains("wget", .formula));
    try testing.expectEqual(@as(usize, 0), s.selected_count);
}

test "space is inert on an already-installed row (never selectable)" {
    var s: State = .{ .items = &sample, .phase = .loaded };
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    s.chrome.view.selected = 1; // firefox, already installed
    try testing.expect(stepKey(&s, &storage, .space) == .none);
    try testing.expectEqual(@as(usize, 0), s.selected_count); // nothing added
}

test "space is inert on an empty result list" {
    var s: State = .{ .items = &.{} };
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    try testing.expect(stepKey(&s, &storage, .space) == .none);
}

test "i installs the basket even when the active row is already installed" {
    var s: State = .{ .items = &sample, .phase = .loaded };
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    // Basket holds ripgrep; the active row is the installed firefox — the basket wins.
    s.chrome.view.selected = 2; // ripgrep, not installed
    _ = stepKey(&s, &storage, .space); // basket = {ripgrep}
    s.chrome.view.selected = 1; // active = firefox (installed)
    const eff = stepKey(&s, &storage, ch('i'));
    defer testing.allocator.free(eff.run_mutation.argv);
    try testing.expect(eff == .run_mutation);
    try testing.expectEqualStrings("ripgrep", eff.run_mutation.argv[3]); // the basket pick
}

test "i is inert only when the basket is empty and the active row is not installable" {
    var s: State = .{ .items = &sample, .phase = .loaded };
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    s.chrome.view.selected = 1; // empty basket + active firefox (installed) → nothing to do
    try testing.expect(stepKey(&s, &storage, ch('i')) == .none);
}

test "the cores tolerate a checked slice shorter than items without trapping" {
    // Before a search sizes `checked` it is empty; the basket op must not index past
    // it (projection is a no-op with no results), and install falls back to the row.
    var s: State = .{ .items = &sample, .checked = &.{}, .phase = .loaded };
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    _ = stepKey(&s, &storage, .space); // wget → basket, projection skipped (no results loaded)
    const eff = stepKey(&s, &storage, ch('i')); // resolves over the basket pick
    defer testing.allocator.free(eff.run_mutation.argv);
    try testing.expect(eff == .run_mutation);
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
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    try testing.expectEqual(View.results, s.view); // results by default
    _ = stepKey(&s, &storage, ch('l'));
    try testing.expectEqual(View.basket, s.view);
    _ = stepKey(&s, &storage, ch('l')); // and back
    try testing.expectEqual(View.results, s.view);
}

const basket_sample = [_]SelEntry{
    .{ .name = "bat", .kind = .formula },
    .{ .name = "firefox", .kind = .cask },
};

test "End jumps to the last row of the active view: results or basket" {
    var s: State = .{ .items = &sample, .phase = .loaded, .basket = &basket_sample };
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    _ = stepKey(&s, &storage, .end);
    try testing.expectEqual(@as(usize, 2), s.chrome.view.selected); // 3 hits

    s.view = .basket;
    _ = stepKey(&s, &storage, .end);
    try testing.expectEqual(@as(usize, 1), s.chrome.view.selected); // 2 picks

    var e: State = .{ .phase = .loaded }; // empty results: no underflow
    _ = stepKey(&e, &storage, .end);
    try testing.expectEqual(@as(usize, 0), e.chrome.view.selected);
}

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

test "the basket view heads the list with a dim selected-count title" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .phase = .loaded, .view = .basket, .basket = &basket_sample }; // 2 picks
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "Basket") != null);
    try testing.expect(std.mem.indexOf(u8, out, "2 selected") != null); // the live count
    try testing.expect(std.mem.indexOf(u8, out, color.roleCode(.muted)) != null); // dim
    try testing.expect(std.mem.indexOf(u8, out, "bat") != null); // the list still renders below
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

test "space in the basket view removes the highlighted pick in place" {
    var s: State = .{ .items = &sample, .phase = .loaded };
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    s.chrome.view.selected = 0;
    _ = stepKey(&s, &storage, .space); // wget → basket
    s.chrome.view.selected = 2;
    _ = stepKey(&s, &storage, .space); // ripgrep → basket
    s.view = .basket;
    s.chrome.view.selected = 0; // highlight the first pick
    try testing.expect(stepKey(&s, &storage, .space) == .none); // remove, pure state
    try testing.expect(!storage.selected.contains("wget", .formula)); // removed
    try testing.expect(storage.selected.contains("ripgrep", .formula)); // kept
}

test "d in the basket view also removes the highlighted pick" {
    var s: State = .{ .items = &sample, .phase = .loaded };
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    s.chrome.view.selected = 0;
    _ = stepKey(&s, &storage, .space); // wget → basket
    s.view = .basket;
    s.chrome.view.selected = 0;
    try testing.expect(stepKey(&s, &storage, ch('d')) == .none);
    try testing.expect(!storage.selected.contains("wget", .formula));
}

test "d in the results view is inert (remove is a basket-only key)" {
    var s: State = .{ .items = &sample, .phase = .loaded, .view = .results };
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    try testing.expect(stepKey(&s, &storage, ch('d')) == .none);
}

test "space in the basket view is inert when the basket is empty" {
    var s: State = .{ .view = .basket };
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    try testing.expect(stepKey(&s, &storage, .space) == .none);
}

test "n clears the basket from the results view when it holds picks" {
    var s: State = .{ .items = &sample, .phase = .loaded };
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    s.chrome.view.selected = 0;
    _ = stepKey(&s, &storage, .space); // wget
    s.chrome.view.selected = 2;
    _ = stepKey(&s, &storage, .space); // ripgrep
    try testing.expectEqual(@as(usize, 2), s.selected_count);
    try testing.expect(stepKey(&s, &storage, ch('n')) == .none); // clear, pure state
    try testing.expectEqual(@as(usize, 0), s.selected_count);
}

test "n on an empty basket is inert" {
    var s: State = .{ .items = &sample, .phase = .loaded };
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    try testing.expect(stepKey(&s, &storage, ch('n')) == .none);
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

test "Storage.deinit frees the results, checkbox buffer, basket, and detail parse" {
    const allocator = std.testing.allocator;
    var storage: Storage = .{};
    storage.search = try search_json.parse(allocator, "{\"schema_version\":1,\"query\":\"zzz\",\"results\":[]}");
    storage.checked = try allocator.alloc(bool, 0);
    try storage.selected.toggle(allocator, "wget", .formula); // one owned basket name
    storage.detail = try info_json.parse(allocator, "{\"name\":\"a\",\"dependencies\":[]}");
    // A no-op deinit leaks the parses, the buffer, and the basket's owned bytes;
    // `testing.allocator` trips at scope end, pinning that deinit frees them all.
    storage.deinit(allocator);
}

// ── Effect tests ─────────────────────────────────────────────────────────

test "Search declares no background fetch and no lazy on-entry reload" {
    // Search reads remotely but synchronously (no fetch spec), and unlike Installed
    // it exposes no `refreshCmd`: a remote read on every tab-entry would be a
    // surprising freeze, so entering never re-queries even when marked dirty.
    try testing.expect(fetch_spec == null);
    try testing.expect(!@hasDecl(@This(), "refreshCmd"));
}

test "space projects the basket toggle onto the on-screen checkbox row" {
    const alloc = testing.allocator;
    var storage: Storage = .{};
    defer storage.deinit(alloc);
    // A loaded result the cursor points at; the toggle re-projects `checked`.
    storage.search = try search_json.parse(alloc,
        \\{"results":[{"name":"bat","type":"formula","installed":false}]}
    );
    storage.checked = try alloc.alloc(bool, 1);
    @memset(storage.checked, false);
    var st: State = .{ .items = storage.search.?.items, .checked = storage.checked, .phase = .loaded };
    try testing.expect(stepKey(&st, &storage, .space) == .none); // pure state, no effect
    try testing.expect(storage.selected.contains("bat", .formula)); // added to the basket
    try testing.expectEqual(@as(usize, 1), st.selected_count); // mirrored onto the leaf
    try testing.expect(storage.checked[0]); // and re-projected onto the on-screen row
}

test "searchCmd flips to the searching phase and carries the query read" {
    var st: State = .{};
    st.chrome.filter.push("fire");
    const eff = searchCmd(testing.allocator, "/opt/homebrew/bin/mt", &st);
    defer testing.allocator.free(eff.read.argv);
    try testing.expect(eff == .read);
    try testing.expectEqual(Phase.searching, st.phase); // flipped before the blocking read
    try testing.expectEqual(cmd.MsgTag.search, eff.read.tag);
    try testing.expectEqualStrings("search", eff.read.argv[1]);
    try testing.expectEqualStrings("fire", eff.read.argv[2]);
}

test "searchCmd on an empty query is a no-op and leaves the phase alone" {
    var st: State = .{ .phase = .idle };
    try testing.expect(searchCmd(testing.allocator, "/bin/mt", &st) == .none);
    try testing.expectEqual(Phase.idle, st.phase);
}

test "searchReadCmd and openSearchInfoCmd build polled reads so the searching frame reflows on resize" {
    const alloc = testing.allocator;

    // The committed-query search runs polled, off the frozen blocking path, so a
    // SIGWINCH reflows the "searching…" frame on the next tick instead of after the read.
    var s: State = .{};
    s.chrome.filter.push("fire");
    const search_eff = searchReadCmd(alloc, "/opt/homebrew/bin/mt", &s);
    defer alloc.free(search_eff.read.argv);
    try testing.expectEqual(cmd.Cmd.Mode.polled, search_eff.read.mode);
    try testing.expectEqual(cmd.MsgTag.search, search_eff.read.tag);

    // The info read for the selected hit inherits the same polled path (same tag).
    var storage: Storage = .{};
    defer storage.deinit(alloc);
    storage.search = try search_json.parse(alloc,
        \\{"results":[{"name":"bat","type":"formula","installed":false}]}
    );
    var info_state: State = .{ .items = storage.search.?.items };
    const info_eff = openSearchInfoCmd(alloc, "/opt/homebrew/bin/mt", &info_state);
    defer alloc.free(info_eff.read.argv);
    try testing.expectEqual(cmd.Cmd.Mode.polled, info_eff.read.mode);
    try testing.expectEqual(cmd.MsgTag.search, info_eff.read.tag);
}

test "searchArgv builds `mt search <query> --json` for the committed query" {
    var st: State = .{};
    st.chrome.filter.push("fire");
    const argv = (try searchArgv(testing.allocator, "/opt/homebrew/bin/mt", &st)).?;
    defer testing.allocator.free(argv);
    try testing.expectEqual(@as(usize, 4), argv.len); // mt, search, query, --json
    try testing.expectEqualStrings("/opt/homebrew/bin/mt", argv[0]);
    try testing.expectEqualStrings("search", argv[1]);
    try testing.expectEqualStrings("fire", argv[2]);
    try testing.expectEqualStrings("--json", argv[3]);
}

test "searchArgv returns null for an empty query so no remote read fires" {
    const st: State = .{};
    try testing.expect((try searchArgv(testing.allocator, "/bin/mt", &st)) == null);
}

test "installArgv installs the whole basket as bare names for a batch" {
    const alloc = testing.allocator;
    var sel: Selection = .{};
    defer sel.deinit(alloc);
    try sel.toggle(alloc, "bat", .formula);
    try sel.toggle(alloc, "redis", .formula);
    const st: State = .{ .items = &.{} }; // basket-driven: no rows on screen
    const argv = (try installArgv(alloc, "/bin/mt", &sel, &st)).?;
    defer alloc.free(argv);
    // mt, install, bat, redis — a batch passes bare names (no global kind flag).
    try testing.expectEqual(@as(usize, 4), argv.len);
    try testing.expectEqualStrings("install", argv[1]);
    try testing.expectEqualStrings("bat", argv[2]);
    try testing.expectEqualStrings("redis", argv[3]);
}

test "installArgv keeps the entry's kind flag for a single-entry basket" {
    const alloc = testing.allocator;
    // The motivating collision: one name, two kinds. The basket entry's stored kind
    // picks the flag, so a single install can't silently default to the formula when
    // the user chose the cask — the reason the explicit flag exists.
    var sel: Selection = .{};
    defer sel.deinit(alloc);
    try sel.toggle(alloc, "docker", .cask);
    const st: State = .{ .items = &.{} };
    const argv = (try installArgv(alloc, "/bin/mt", &sel, &st)).?;
    defer alloc.free(argv);
    try testing.expectEqual(@as(usize, 4), argv.len); // mt, install, --cask, name
    try testing.expectEqualStrings("--cask", argv[2]);
    try testing.expectEqualStrings("docker", argv[3]);
}

test "installArgv keeps a basket pick whose on-screen row reads installed (no per-package prune)" {
    const alloc = testing.allocator;
    var sel: Selection = .{};
    defer sel.deinit(alloc);
    try sel.toggle(alloc, "git", .formula);
    // The same name is on screen and already installed, but the basket still installs
    // it: the post-install re-search only refreshes the current query, so an off-list
    // pick's `installed` flag can't be trusted — `mt install` is idempotent instead.
    // The basket path never consults the on-screen rows.
    const items = [_]Match{.{ .name = "git", .kind = .formula, .installed = true }};
    const st: State = .{ .items = &items };
    const argv = (try installArgv(alloc, "/bin/mt", &sel, &st)).?;
    defer alloc.free(argv);
    try testing.expectEqual(@as(usize, 4), argv.len); // single-entry basket → flag form
    try testing.expectEqualStrings("--formula", argv[2]); // and the formula flag, not just --cask
    try testing.expectEqualStrings("git", argv[3]);
}

test "installArgv over an empty basket falls back to the active row, keeping its kind flag" {
    const alloc = testing.allocator;
    const items = [_]Match{
        .{ .name = "firefox", .kind = .cask, .installed = false },
        .{ .name = "wget", .kind = .formula, .installed = false },
    };
    var sel: Selection = .{}; // empty: never allocates, no free needed
    var st: State = .{ .items = &items };
    st.chrome.view.selected = 0; // firefox (cask)
    const argv = (try installArgv(alloc, "/bin/mt", &sel, &st)).?;
    defer alloc.free(argv);
    try testing.expectEqual(@as(usize, 4), argv.len); // single → mt, install, --cask, name
    try testing.expectEqualStrings("--cask", argv[2]);
    try testing.expectEqualStrings("firefox", argv[3]);
}

test "installArgv is null with an empty basket and no installable active row" {
    const alloc = testing.allocator;
    var sel: Selection = .{};
    const on_system = [_]Match{.{ .name = "jq", .kind = .formula, .installed = true }};
    const st_installed: State = .{ .items = &on_system };
    try testing.expect((try installArgv(alloc, "/bin/mt", &sel, &st_installed)) == null); // active row already installed
    const empty: State = .{ .items = &.{} };
    try testing.expect((try installArgv(alloc, "/bin/mt", &sel, &empty)) == null); // nothing on screen, empty basket
}

test "a basket filled across two separate queries installs every pick in one argv" {
    const alloc = testing.allocator;
    var sel: Selection = .{};
    defer sel.deinit(alloc);

    // Query A returns bat; the user checks it, then the query is re-run and A's parse
    // is freed — the pick must survive into the next query.
    {
        var a = try search_json.parse(alloc,
            \\{"results":[{"name":"bat","type":"formula","installed":false}]}
        );
        try sel.toggle(alloc, a.items[0].name, a.items[0].kind);
        a.deinit();
    }
    // Query B returns redis; the user checks it too. bat is now off-list.
    {
        var b = try search_json.parse(alloc,
            \\{"results":[{"name":"redis","type":"formula","installed":false}]}
        );
        try sel.toggle(alloc, b.items[0].name, b.items[0].kind);
        b.deinit();
    }

    // One `i` installs both, in a single argv, no matter which results are on screen —
    // the owned basket spans the two queries.
    const st: State = .{ .items = &.{} };
    const argv = (try installArgv(alloc, "/bin/mt", &sel, &st)).?;
    defer alloc.free(argv);
    try testing.expectEqual(@as(usize, 4), argv.len);
    try testing.expectEqualStrings("install", argv[1]);
    try testing.expectEqualStrings("bat", argv[2]);
    try testing.expectEqualStrings("redis", argv[3]);
}

test "installArgv reads names from the owned basket, not the freed parse it was checked in" {
    const alloc = testing.allocator;
    var sel: Selection = .{};
    defer sel.deinit(alloc);
    // Check two hits out of a live parse, then free that parse — the basket owns its
    // name bytes, so the argv below must not read the released storage.
    {
        var parsed = try search_json.parse(alloc,
            \\{"results":[{"name":"bat","type":"formula","installed":false},{"name":"redis","type":"formula","installed":false}]}
        );
        try sel.toggle(alloc, parsed.items[0].name, parsed.items[0].kind);
        try sel.toggle(alloc, parsed.items[1].name, parsed.items[1].kind);
        parsed.deinit(); // the parse the names were borrowed from is gone
    }
    const st: State = .{ .items = &.{} };
    const argv = (try installArgv(alloc, "/bin/mt", &sel, &st)).?;
    defer alloc.free(argv);
    try testing.expectEqualStrings("bat", argv[2]); // owned bytes, not a dangling borrow
    try testing.expectEqualStrings("redis", argv[3]);
}

test "selection toggles (name, kind) membership and owns its bytes" {
    const alloc = testing.allocator;
    var sel: Selection = .{};
    defer sel.deinit(alloc);
    try testing.expect(!sel.contains("bat", .formula));
    try sel.toggle(alloc, "bat", .formula);
    try testing.expect(sel.contains("bat", .formula));
    try testing.expect(!sel.contains("bat", .cask)); // kind distinguishes the pick
    try sel.toggle(alloc, "bat", .formula); // a second toggle deselects
    try testing.expect(!sel.contains("bat", .formula));
}

test "selection removes the right entry among several (swapRemove)" {
    const alloc = testing.allocator;
    var sel: Selection = .{};
    defer sel.deinit(alloc);
    try sel.toggle(alloc, "a", .formula);
    try sel.toggle(alloc, "b", .formula);
    try sel.toggle(alloc, "c", .cask);
    try sel.toggle(alloc, "b", .formula); // remove the middle pick
    try testing.expect(sel.contains("a", .formula));
    try testing.expect(!sel.contains("b", .formula));
    try testing.expect(sel.contains("c", .cask));
    try testing.expectEqual(@as(usize, 2), sel.entries.items.len);
}

test "re-adding a removed pick yields a single entry, not a duplicate" {
    const alloc = testing.allocator;
    var sel: Selection = .{};
    defer sel.deinit(alloc);
    try sel.toggle(alloc, "bat", .formula); // add
    try sel.toggle(alloc, "bat", .formula); // remove
    try sel.toggle(alloc, "bat", .formula); // add again
    try testing.expect(sel.contains("bat", .formula));
    try testing.expectEqual(@as(usize, 1), sel.entries.items.len);
}

test "selection remove deletes exactly the named pick and frees it" {
    const alloc = testing.allocator; // a missed free shows up as a leak here
    var sel: Selection = .{};
    defer sel.deinit(alloc);
    try sel.toggle(alloc, "bat", .formula);
    try sel.toggle(alloc, "redis", .formula);
    sel.remove(alloc, "bat", .formula);
    try testing.expect(!sel.contains("bat", .formula));
    try testing.expect(sel.contains("redis", .formula)); // the other pick is untouched
    try testing.expectEqual(@as(usize, 1), sel.entries.items.len);
    sel.remove(alloc, "ghost", .cask); // an absent pick is a harmless no-op
    try testing.expectEqual(@as(usize, 1), sel.entries.items.len);
}

test "selection clear empties the basket and frees every pick" {
    const alloc = testing.allocator; // a missed free shows up as a leak here
    var sel: Selection = .{};
    defer sel.deinit(alloc);
    try sel.toggle(alloc, "bat", .formula);
    try sel.toggle(alloc, "redis", .cask);
    sel.clear(alloc);
    try testing.expectEqual(@as(usize, 0), sel.entries.items.len);
    try testing.expect(!sel.contains("bat", .formula));
}

test "removing a basket pick re-projects its on-screen row to unchecked" {
    const alloc = testing.allocator;
    var storage: Storage = .{};
    defer storage.deinit(alloc);
    storage.search = try search_json.parse(alloc,
        \\{"results":[{"name":"bat","type":"formula","installed":false}]}
    );
    storage.checked = try alloc.alloc(bool, 1);
    @memset(storage.checked, false);
    try storage.selected.toggle(alloc, "bat", .formula);
    projectSearchChecked(&storage);
    try testing.expect(storage.checked[0]); // checked before the remove
    storage.selected.remove(alloc, "bat", .formula);
    projectSearchChecked(&storage);
    try testing.expect(!storage.checked[0]); // the row reflects the removal
}

test "syncSelected mirrors the basket entries onto the leaf for the basket view" {
    const alloc = testing.allocator;
    var s: State = .{};
    var storage: Storage = .{};
    defer storage.deinit(alloc);
    try storage.selected.toggle(alloc, "bat", .formula);
    syncSelected(&s, &storage);
    try testing.expectEqual(@as(usize, 1), s.basket.len);
    try testing.expectEqualStrings("bat", s.basket[0].name);
}

test "removing a pick then installing builds an argv without the removed name" {
    const alloc = testing.allocator;
    var sel: Selection = .{};
    defer sel.deinit(alloc);
    // Two picks gathered across queries (the cross-query basket); the user opens the
    // basket view, removes bat, then installs — only redis reaches the argv.
    try sel.toggle(alloc, "bat", .formula);
    try sel.toggle(alloc, "redis", .formula);
    sel.remove(alloc, "bat", .formula);
    const st: State = .{ .items = &.{} };
    const argv = (try installArgv(alloc, "/bin/mt", &sel, &st)).?;
    defer alloc.free(argv);
    try testing.expectEqual(@as(usize, 4), argv.len); // single → mt, install, --formula, name
    try testing.expectEqualStrings("redis", argv[3]);
    try testing.expect(std.mem.indexOf(u8, argv[3], "bat") == null);
}

test "projectChecked leaves every row unchecked for an empty selection" {
    const items = [_]Match{
        .{ .name = "wget", .kind = .formula, .installed = false },
        .{ .name = "ripgrep", .kind = .formula, .installed = false },
    };
    var sel: Selection = .{}; // never touched: no allocation, no free needed
    var checked = [_]bool{ true, true }; // pre-dirtied to prove the projection clears
    projectChecked(&items, &checked, &sel);
    try testing.expect(!checked[0]);
    try testing.expect(!checked[1]);
}

test "projectChecked checks selected, not-installed rows only" {
    const items = [_]Match{
        .{ .name = "wget", .kind = .formula, .installed = false },
        .{ .name = "firefox", .kind = .cask, .installed = true },
        .{ .name = "ripgrep", .kind = .formula, .installed = false },
    };
    const alloc = testing.allocator;
    var sel: Selection = .{};
    defer sel.deinit(alloc);
    try sel.toggle(alloc, "wget", .formula);
    try sel.toggle(alloc, "firefox", .cask); // selected but already installed
    var checked = [_]bool{ false, false, false };
    projectChecked(&items, &checked, &sel);
    try testing.expect(checked[0]); // selected + installable
    try testing.expect(!checked[1]); // installed → never checked
    try testing.expect(!checked[2]); // not selected
}

test "a selection survives a re-query" {
    const alloc = testing.allocator;
    var sel: Selection = .{};
    defer sel.deinit(alloc);
    try sel.toggle(alloc, "wget", .formula); // checked under query A

    const b = [_]Match{.{ .name = "redis", .kind = .formula, .installed = false }};
    var cb = [_]bool{false};
    projectChecked(&b, &cb, &sel); // query B: wget is absent
    try testing.expect(!cb[0]);

    const a = [_]Match{.{ .name = "wget", .kind = .formula, .installed = false }};
    var ca = [_]bool{false};
    projectChecked(&a, &ca, &sel); // query A again: wget returns
    try testing.expect(ca[0]); // re-checked from the still-present selection
}

test "projectSearchChecked fills the storage checked slice from the selection" {
    const alloc = testing.allocator;
    var storage: Storage = .{};
    defer storage.deinit(alloc);
    storage.search = try search_json.parse(alloc,
        \\{"results":[{"name":"wget","type":"formula","installed":false},{"name":"firefox","type":"cask","installed":true}]}
    );
    storage.checked = try alloc.alloc(bool, 2);
    @memset(storage.checked, false);
    try storage.selected.toggle(alloc, "wget", .formula);
    projectSearchChecked(&storage);
    try testing.expect(storage.checked[0]); // selected, installable
    try testing.expect(!storage.checked[1]); // installed → never checked
}

test "a clean install (exit 0) clears the basket and re-projects the checked slice" {
    const alloc = testing.allocator;
    var storage: Storage = .{};
    defer storage.deinit(alloc);
    storage.search = try search_json.parse(alloc,
        \\{"results":[{"name":"bat","type":"formula","installed":false}]}
    );
    storage.checked = try alloc.alloc(bool, 1);
    @memset(storage.checked, false);
    try storage.selected.toggle(alloc, "bat", .formula);
    try storage.selected.toggle(alloc, "redis", .formula); // an off-list pick too
    projectSearchChecked(&storage);
    try testing.expect(storage.checked[0]); // bat checked before the install

    applyInstallOutcome(&storage, alloc, true);
    try testing.expectEqual(@as(usize, 0), storage.selected.entries.items.len); // basket emptied
    try testing.expect(!storage.checked[0]); // re-projected against the now-empty basket
}

test "a failed install (non-zero exit) retains the whole basket for retry" {
    const alloc = testing.allocator;
    var storage: Storage = .{};
    defer storage.deinit(alloc);
    try storage.selected.toggle(alloc, "bat", .formula);
    try storage.selected.toggle(alloc, "redis", .formula);

    applyInstallOutcome(&storage, alloc, false);
    try testing.expectEqual(@as(usize, 2), storage.selected.entries.items.len); // untouched
    try testing.expect(storage.selected.contains("bat", .formula));
    try testing.expect(storage.selected.contains("redis", .formula));
}

test "update on a failed search leaves no stuck searching phase (guidance when none loaded)" {
    var st: State = .{ .phase = .searching }; // as the pre-read paint left it
    var storage: Storage = .{};
    var shared: ctx.SharedModel = .{};
    defer storage.deinit(testing.allocator);
    const next = update(testing.allocator, "/bin/mt", &st, &storage, &shared, .failed);
    try testing.expect(next == .none);
    // No prior results → guidance, not a spinner frozen behind the (pump-set) banner.
    try testing.expectEqual(Phase.idle, st.phase);
}

test "update on a failed search falls back to the last-good results, keeping the cursor" {
    var storage: Storage = .{};
    var shared: ctx.SharedModel = .{};
    defer storage.deinit(testing.allocator);
    // Prime a prior successful search: storage + leaf borrow these results.
    storage.search = try search_json.parse(testing.allocator,
        \\{"results":[{"name":"jq","type":"formula","installed":true},{"name":"yq","type":"formula","installed":false}]}
    );
    var st: State = .{ .items = storage.search.?.items, .phase = .searching };
    st.chrome.view.selected = 1; // cursor on yq
    const next = update(testing.allocator, "/bin/mt", &st, &storage, &shared, .failed);
    try testing.expect(next == .none);
    // Prior results exist → fall back to the list, not guidance; the rows and cursor survive.
    try testing.expectEqual(Phase.loaded, st.phase);
    try testing.expectEqual(@as(usize, 2), st.items.len);
    try testing.expectEqual(@as(usize, 1), st.chrome.view.selected);
}

test "update on a cleared search (empty polled read) leaves no stuck searching phase" {
    var st: State = .{ .phase = .searching }; // as the pre-read paint left it
    var storage: Storage = .{};
    var shared: ctx.SharedModel = .{};
    defer storage.deinit(testing.allocator);
    const next = update(testing.allocator, "/bin/mt", &st, &storage, &shared, .cleared);
    try testing.expect(next == .none);
    // A 0-byte exit-0 read must reset the phase like `.failed` does, never strand
    // the body on the spinner.
    try testing.expectEqual(Phase.idle, st.phase);
}

test "update on a loaded search parse swaps in the ranked results and lands loaded" {
    var st: State = .{ .phase = .searching };
    var storage: Storage = .{};
    var shared: ctx.SharedModel = .{};
    defer storage.deinit(testing.allocator);
    try storage.selected.toggle(testing.allocator, "bat", .formula); // a prior pick
    const parsed = try search_json.parse(testing.allocator,
        \\{"results":[{"name":"bat","type":"formula","installed":false},{"name":"jq","type":"formula","installed":true}]}
    );
    const next = update(testing.allocator, "/bin/mt", &st, &storage, &shared, .{ .loaded = .{ .search = parsed } });
    try testing.expect(next == .none);
    try testing.expectEqual(Phase.loaded, st.phase);
    try testing.expectEqual(@as(usize, 2), st.items.len);
    try testing.expect(st.checked[0]); // bat re-checked from the persistent basket
    try testing.expect(!st.checked[1]); // jq installed → never checked
}

test "a successful install clears the basket, marks siblings stale, and re-runs the query" {
    var st: State = .{};
    st.chrome.filter.push("bat");
    var storage: Storage = .{};
    var shared: ctx.SharedModel = .{};
    defer storage.deinit(testing.allocator);
    try storage.selected.toggle(testing.allocator, "bat", .formula);
    syncSelected(&st, &storage);
    const next = update(testing.allocator, "/bin/mt", &st, &storage, &shared, .{ .mutated = 0 });
    defer testing.allocator.free(next.read.argv);
    try testing.expect(next == .read); // re-run the query so markers flip
    try testing.expectEqualStrings("search", next.read.argv[1]);
    try testing.expectEqual(@as(usize, 0), st.selected_count); // basket consumed
    try testing.expect(shared.takeDirty(.installed)); // siblings marked stale
}

test "a failed install retains the basket behind a recoverable banner and does not re-query" {
    var st: State = .{};
    var storage: Storage = .{};
    var shared: ctx.SharedModel = .{};
    defer storage.deinit(testing.allocator);
    try storage.selected.toggle(testing.allocator, "bat", .formula);
    syncSelected(&st, &storage);
    const next = update(testing.allocator, "/bin/mt", &st, &storage, &shared, .{ .mutated = 1 });
    try testing.expect(next == .none); // no re-query on failure
    try testing.expectEqual(@as(usize, 1), st.selected_count); // basket retained for retry
    try testing.expect(std.mem.startsWith(u8, shared.banner.slice(), "install failed"));
}

test "Enter toggles an open results pane closed for the selected row" {
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    var s: State = .{ .items = &sample, .phase = .loaded, .detail = .{ .name = "ripgrep" } };
    s.chrome.view.selected = 2; // ripgrep, the row the pane is open for
    try testing.expect(stepKey(&s, &storage, .enter) == .none); // toggled closed
    try testing.expect(s.detail == null);
}

test "Enter switches the results pane to a newly selected row instead of closing it" {
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    var s: State = .{ .items = &sample, .phase = .loaded, .detail = .{ .name = "ripgrep" } };
    s.chrome.view.selected = 0; // wget, while the pane belongs to ripgrep
    const eff = stepKey(&s, &storage, .enter);
    defer testing.allocator.free(eff.read.argv);
    try testing.expect(eff == .read); // opens wget's info
    try testing.expectEqualStrings("wget", eff.read.argv[2]);
}

// ── Hit-test tests ─────────────────────────────────────────────────────────

test "hitTest in the results view maps a click to the row it lands on, openable" {
    const s: State = .{ .items = &sample, .phase = .loaded };
    // rect.row = 1 → heading at 1, list starts at 2. Rows 2/3/4 map to 0/1/2.
    const rect: tab.Rect = .{ .row = 1, .col = 1, .width = 80, .height = 10 };
    try testing.expectEqual(@as(?usize, 0), hitTest(&s, rect, 2, 1).?.index);
    try testing.expectEqual(@as(?usize, 2), hitTest(&s, rect, 4, 1).?.index);
    try testing.expect(hitTest(&s, rect, 2, 1).?.open); // a results row opens info
}

test "hitTest results index lines up with selectedMatch for the same row" {
    var s: State = .{ .items = &sample, .phase = .loaded };
    const rect: tab.Rect = .{ .row = 1, .col = 1, .width = 80, .height = 10 };
    const hit = hitTest(&s, rect, 4, 1).?; // ripgrep's row
    s.chrome.view.selected = hit.index; // move the cursor there, as a left-click would
    try testing.expectEqualStrings("ripgrep", selectedMatch(&s).?.name); // Enter opens the same hit
}

// A results list taller than any docked layout, so a scrolled view exposes the
// offset difference between the full rect and the pane-shrunk rect.
const tall_results = blk: {
    var arr: [30]Match = undefined;
    for (&arr, 0..) |*m, i|
        m.* = .{ .name = std.fmt.comptimePrint("pkg{d:0>2}", .{i}), .kind = .formula, .installed = false };
    break :blk arr;
};

test "hitTest resolves against the shrunk results list when a detail pane is docked" {
    // rect height 10 → the pane caps at 4 rows (its 3 fields need 4), so the list
    // shrinks to rows 2..6. A click at row 8 lands in the pane, not on a result.
    const s: State = .{ .items = &tall_results, .phase = .loaded, .detail = .{} };
    const rect: tab.Rect = .{ .row = 1, .col = 1, .width = 80, .height = 10 };
    try testing.expectEqual(@as(?usize, 4), hitTest(&s, rect, 6, 1).?.index); // last shrunk row
    try testing.expect(hitTest(&s, rect, 8, 1) == null); // the docked pane, not a result
}

test "hitTest uses the shrunk-height scroll offset when a results pane is open" {
    var s: State = .{ .items = &tall_results, .phase = .loaded, .detail = .{} };
    s.chrome.view.selected = 20;
    const rect: tab.Rect = .{ .row = 1, .col = 1, .width = 80, .height = 10 };
    // shrunk results list height 5, selected 20 → offset 16; the top row (row 2) is item 16.
    try testing.expectEqual(@as(?usize, 16), hitTest(&s, rect, 2, 1).?.index);
}

test "hitTest rejects the results heading row and rows above the list" {
    const s: State = .{ .items = &sample, .phase = .loaded };
    const rect: tab.Rect = .{ .row = 5, .col = 1, .width = 80, .height = 10 };
    try testing.expect(hitTest(&s, rect, 5, 1) == null); // the heading row
    try testing.expect(hitTest(&s, rect, 4, 1) == null); // above the list
}

test "hitTest in the basket view maps a click to the row, select-only" {
    const s: State = .{ .phase = .loaded, .view = .basket, .basket = &basket_sample };
    // Basket adds a title row: title at 1, heading at 2, list starts at 3.
    const rect: tab.Rect = .{ .row = 1, .col = 1, .width = 80, .height = 10 };
    try testing.expectEqual(@as(?usize, 0), hitTest(&s, rect, 3, 1).?.index);
    try testing.expectEqual(@as(?usize, 1), hitTest(&s, rect, 4, 1).?.index);
    try testing.expect(!hitTest(&s, rect, 3, 1).?.open); // the basket has no info action
}

test "hitTest rejects the basket title and heading rows" {
    const s: State = .{ .phase = .loaded, .view = .basket, .basket = &basket_sample };
    const rect: tab.Rect = .{ .row = 1, .col = 1, .width = 80, .height = 10 };
    try testing.expect(hitTest(&s, rect, 1, 1) == null); // the title row
    try testing.expect(hitTest(&s, rect, 2, 1) == null); // the heading row
}

test "hitTest adds the scrolled view offset in each view" {
    var r: State = .{ .items = &sample, .phase = .loaded };
    r.chrome.view.selected = 2; // clamp scrolls the 2-tall results list to offset 1
    // rect.height 3 → results list height 2; the top list row (row 2) maps to the offset.
    try testing.expectEqual(@as(?usize, 1), hitTest(&r, .{ .row = 1, .col = 1, .width = 80, .height = 3 }, 2, 1).?.index);

    var b: State = .{ .phase = .loaded, .view = .basket, .basket = &basket_sample };
    b.chrome.view.selected = 1; // clamp scrolls the 1-tall basket list to offset 1
    // rect.height 3 → basket list height 1 (title+heading cost two); top row (row 3) maps to the offset.
    try testing.expectEqual(@as(?usize, 1), hitTest(&b, .{ .row = 1, .col = 1, .width = 80, .height = 3 }, 3, 1).?.index);
}

test "hitTest rejects a blank row past the populated tail in each view" {
    const r: State = .{ .items = &sample, .phase = .loaded }; // 3 hits
    const rect: tab.Rect = .{ .row = 1, .col = 1, .width = 80, .height = 10 };
    try testing.expectEqual(@as(?usize, 2), hitTest(&r, rect, 4, 1).?.index); // last hit
    try testing.expect(hitTest(&r, rect, 5, 1) == null); // blank tail

    const b: State = .{ .phase = .loaded, .view = .basket, .basket = &basket_sample }; // 2 picks
    try testing.expectEqual(@as(?usize, 1), hitTest(&b, rect, 4, 1).?.index); // last pick
    try testing.expect(hitTest(&b, rect, 5, 1) == null); // blank tail
}

test "hitTest hits nothing on an empty results list or empty basket" {
    const rect: tab.Rect = .{ .row = 1, .col = 1, .width = 80, .height = 10 };
    const r: State = .{ .items = &.{}, .phase = .loaded }; // count 0 must reach rowAt
    try testing.expect(hitTest(&r, rect, 2, 1) == null);
    const b: State = .{ .phase = .loaded, .view = .basket, .basket = &.{} };
    try testing.expect(hitTest(&b, rect, 3, 1) == null);
}

test "hitTest is inert in the results view while a re-query is searching" {
    // A re-query flips to `searching` but keeps the last results in `items`; the
    // screen shows "searching…", not the list, so a click must not resolve a stale row.
    const s: State = .{ .items = &sample, .phase = .searching };
    const rect: tab.Rect = .{ .row = 1, .col = 1, .width = 80, .height = 10 };
    try testing.expect(hitTest(&s, rect, 2, 1) == null);
}

test "hitTest hits nothing when the heading or title eats the only rows" {
    const r: State = .{ .items = &sample, .phase = .loaded };
    // Results height 1 → the heading takes the only row, no list band.
    try testing.expect(hitTest(&r, .{ .row = 1, .col = 1, .width = 80, .height = 1 }, 2, 1) == null);

    const b: State = .{ .phase = .loaded, .view = .basket, .basket = &basket_sample };
    // Basket height 2 → title + heading take both rows, no list band.
    try testing.expect(hitTest(&b, .{ .row = 1, .col = 1, .width = 80, .height = 2 }, 3, 1) == null);
    // Zero-height rect in either view is a clean null, never a trap.
    try testing.expect(hitTest(&r, .{ .row = 1, .col = 1, .width = 80, .height = 0 }, 1, 1) == null);
    try testing.expect(hitTest(&b, .{ .row = 1, .col = 1, .width = 80, .height = 0 }, 1, 1) == null);
}
