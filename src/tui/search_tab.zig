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
const ctx = @import("ctx.zig");
const spawn = @import("spawn.zig");
const detail_pane = @import("detail_pane.zig");
const info_json = @import("json/info.zig");
const search_json = @import("json/search.zig");
pub const Match = search_json.Match;
const Kind = search_json.Kind;
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

/// Search runs synchronously on demand; it never background-fetches.
pub const fetch_spec: ?tab.FetchSpec = null;

/// Whether the pending request will spawn a DB-mutating child (`mt install`). The
/// shell folds this over every tab before opening the DB so a live background audit
/// is drained first — the WAL single-writer invariant. The read-only requests
/// (search/info) and the pure basket ops (toggle/remove/clear) never gate.
pub fn mutates(s: *const State) bool {
    return s.request == .install;
}

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
        // No narrowing filter here; the cursor indexes the active view's list.
        .end => s.chrome.view.selected = (switch (s.view) {
            .results => s.items.len,
            .basket => s.basket.len,
        }) -| 1,
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
    const list: tab.Rect = .{ .row = head.row + 1, .col = head.col, .width = head.width, .height = head.height -| 1 };
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

// ── Impure zone ────────────────────────────────────────────────────────────
// The effects the pure `step` requested. Each carries its I/O ports explicitly
// through the shared `ctx.Ctx` — never a global — so the pure/impure line lands at
// the signature: these take `io`/`allocator`, the pure functions above do not.

/// The effect chain's error set, composed from the source sets so it tracks them
/// automatically. A subset of the shell's `RunError`, which classifies each fault
/// recoverable-vs-fatal; naming it here keeps the public `service` explicit.
pub const Error = std.mem.Allocator.Error || spawn.ReadError || spawn.InlineError || search_json.Error || info_json.Error;

/// Build `mt search <query> --json` for the committed query. Pure over the tab
/// state: null when the query is empty (the no-op — the view shows guidance, no
/// spawn), else an owned argv whose `query` element borrows the filter buffer.
/// Caller frees the returned slice (not its elements).
fn searchArgv(allocator: std.mem.Allocator, mt_path: []const u8, st: *const State) std.mem.Allocator.Error!?[]const []const u8 {
    const query = st.chrome.filter.slice();
    if (query.len == 0) return null; // empty query: no remote read
    return try spawn.jsonArgv(allocator, mt_path, &.{ "search", query });
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
/// renders. The pure core holds no allocator and never owns the picks — it borrows
/// this slice, refreshed after every basket mutation (an append can move the backing
/// buffer, so a stale slice would dangle).
pub fn syncSelected(s: *State, storage: *const Storage) void {
    s.selected_count = storage.selected.entries.items.len;
    s.basket = storage.selected.entries.items;
}

/// Run the committed query's `mt search --json`, parse, and repoint the results at
/// the fresh parse. Search is a remote read, so it goes through `readJson` like the
/// other reads (no alt-screen drop). The storage is swapped only after a clean parse,
/// so a failure keeps the last-good results.
fn loadSearch(s: *State, storage: *Storage, c: *ctx.Ctx) !void {
    const argv = (try searchArgv(c.allocator, c.mt_path, s)) orelse return; // empty query: no-op
    defer c.allocator.free(argv);
    // Annotate any failure as a recoverable banner; the loop boundary decides
    // recoverable vs fatal. A failed read must also leave the "searching…" phase
    // (set by the pre-spawn paint): fall back to the last-good results, or guidance
    // if none were ever loaded — never a stuck spinner behind the banner.
    errdefer |err| {
        c.shared.banner.set("search failed", @errorName(err));
        s.phase = if (storage.search != null) .loaded else .idle;
    }
    const bytes = try spawn.readJson(c.io, c.allocator, argv);
    defer c.allocator.free(bytes);

    const parsed = try search_json.parse(c.allocator, bytes);
    errdefer parsed.deinit();
    // `checked` is a projection of the persistent basket, not per-query state: a pick
    // survives a re-query and re-checks its row when the package returns.
    const checked = try c.allocator.alloc(bool, parsed.items.len);

    if (storage.search) |old| old.deinit();
    if (storage.checked.len != 0) c.allocator.free(storage.checked);
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

/// Build the `mt install …` argv from the cross-query basket. The whole basket
/// installs, so an off-screen pick installs too. Empty basket ⇒ fall back to the
/// active row (the no-selection case); null when that row is absent or already
/// installed (the no-op). A single target keeps the explicit `--formula`/`--cask`
/// flag, because a name can exist as both and bare `mt install <name>` silently picks
/// the formula; a multi install passes bare names and lets `mt` detect each one's
/// kind. Basket names are owned, so the argv outlives the parse it was checked in (the
/// active-row fallback name borrows the live parse, read before any re-search frees
/// it). Caller frees the returned slice, not its elements.
fn installArgv(allocator: std.mem.Allocator, mt_path: []const u8, sel: *const Selection, st: *const State) std.mem.Allocator.Error!?[]const []const u8 {
    const entries = sel.entries.items;
    if (entries.len == 0) {
        // Empty basket: the active row, if it is installable.
        const i = selectedIndex(st) orelse return null;
        const m = st.items[i];
        if (m.installed) return null;
        return try spawn.inlineArgv(allocator, mt_path, &.{ "install", kindFlag(m.kind), m.name });
    }
    if (entries.len == 1) {
        const e = entries[0];
        return try spawn.inlineArgv(allocator, mt_path, &.{ "install", kindFlag(e.kind), e.name });
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

/// Delegate the basket's install to the real `mt` inline, then re-run the query so
/// installed markers flip. The argv's names are owned by the basket (the active-row
/// fallback name borrows the live parse, read before the re-search frees it). A clean
/// install clears the basket; a failed one keeps it.
fn doInstall(s: *State, storage: *Storage, c: *ctx.Ctx) !void {
    const argv = (try installArgv(c.allocator, c.mt_path, &storage.selected, s)) orelse return; // nothing installable selected
    defer c.allocator.free(argv);
    // A non-zero `mt install` re-enters the dashboard (the user keeps malt's real
    // output, including any prompt, in their scrollback) and surfaces as a recoverable
    // banner; only a terminal fault is fatal — the loop boundary decides which on the
    // re-raised error. The basket is retained either way.
    spawn.runInlineReenter(c.term, argv) catch |err| {
        c.shared.banner.set("install failed", @errorName(err));
        applyInstallOutcome(storage, c.allocator, false); // retain for retry
        return err;
    };
    applyInstallOutcome(storage, c.allocator, true); // a clean install consumed the basket
    syncSelected(s, storage); // basket now empty → leaf gate + footer reflect it
    // Re-run the same query so the freshly installed hit's marker flips — the
    // backend's install-aware `installed` flag does the rest (no `mt list` call).
    try loadSearch(s, storage, c);
    c.shared.markStaleAfter(.search); // Installed/Outdated/Services may have changed too
    // The keg set grew but we are on Search, so the lazy Installed reload won't run
    // until that tab is entered — refresh just the count now (cheaply, through the
    // hub-owned port) so the header is live immediately, not stale until Installed.
    c.refreshInstalledCount();
}

/// Open the `mt info` pane for the active hit. `mt info` resolves installed and
/// uninstalled packages alike, so a search result can be inspected before any
/// install. A read (no alt-screen drop); failure names the package in a banner and
/// leaves the pane closed.
fn openSearchInfo(s: *State, storage: *Storage, c: *ctx.Ctx) !void {
    const m = selectedMatch(s) orelse return; // empty list: no-op
    errdefer |err| {
        var sb: [96]u8 = undefined;
        const op = std.fmt.bufPrint(&sb, "info for {s} failed", .{m.name}) catch "info read failed";
        c.shared.banner.set(op, @errorName(err));
    }
    const argv = try spawn.jsonArgv(c.allocator, c.mt_path, &.{ "info", m.name });
    defer c.allocator.free(argv);
    const bytes = try spawn.readJson(c.io, c.allocator, argv);
    defer c.allocator.free(bytes);

    const parsed = try info_json.parse(c.allocator, bytes);
    if (storage.detail) |old| old.deinit();
    storage.detail = parsed;
    s.detail = parsed.info;
}

/// Perform any effect the pure `step` requested, then clear it — the consumer half of
/// the `request` seam. Unlike the other tabs there is no lazy dirty-load: Search is
/// idle until the user commits a query, and a remote read on every tab-entry after an
/// unrelated mutation would be a surprising freeze, so the dirty flag `markStaleAfter`
/// may set for Search is deliberately never consumed on entry.
pub fn service(s: *State, storage: *Storage, c: *ctx.Ctx) Error!void {
    const req = s.request;
    s.request = .none;
    switch (req) {
        .none => {},
        .search => try loadSearch(s, storage, c),
        .install => try doInstall(s, storage, c),
        .info => try openSearchInfo(s, storage, c),
        // Add/remove the active hit in the persistent basket, then re-project the
        // `checked` slice so the row reflects it immediately. The leaf already refused
        // installed rows, so the match here is always selectable.
        .toggle => {
            const m = selectedMatch(s) orelse return;
            try storage.selected.toggle(c.allocator, m.name, m.kind);
            projectSearchChecked(storage);
            syncSelected(s, storage);
        },
        // Drop the highlighted basket pick (read its name/kind before freeing it),
        // then re-project so any on-screen row for it clears its checkmark.
        .remove => {
            const e = selectedBasketEntry(s) orelse return;
            storage.selected.remove(c.allocator, e.name, e.kind);
            projectSearchChecked(storage);
            syncSelected(s, storage);
        },
        // Empty the whole basket; the projection then clears every on-screen check.
        .clear => {
            storage.selected.clear(c.allocator);
            projectSearchChecked(storage);
            syncSelected(s, storage);
        },
    }
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

test "End jumps to the last row of the active view: results or basket" {
    var s: State = .{ .items = &sample, .phase = .loaded, .basket = &basket_sample };
    step(&s, .end);
    try testing.expectEqual(@as(usize, 2), s.chrome.view.selected); // 3 hits

    s.view = .basket;
    step(&s, .end);
    try testing.expectEqual(@as(usize, 1), s.chrome.view.selected); // 2 picks

    var e: State = .{ .phase = .loaded }; // empty results: no underflow
    step(&e, .end);
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

test "mutates gates only on the install request" {
    var s: State = .{};
    try testing.expect(!mutates(&s)); // .none never takes the WAL writer
    s.request = .info;
    try testing.expect(!mutates(&s)); // a read-only info request does not gate
    s.request = .toggle;
    try testing.expect(!mutates(&s)); // a pure basket op does not gate
    s.request = .install;
    try testing.expect(mutates(&s)); // the one DB-mutating request
}

// Backing storage for a `ctx.Ctx` in an effect test: dummy term/fetches/shared, a
// no-op painter (fd = -1; these reads never reach a poll tick), and the loading flag.
const TestEnv = struct {
    term_h: ctx.Term,
    fetches: ctx.Fetches = ctx.Fetches.initFill(null),
    shared: ctx.SharedModel = .{},
    frame: []u8 = &.{},
    loading: bool = false,
};

fn mkCtx(io: std.Io, e: *TestEnv, mt_path: []const u8) ctx.Ctx {
    return .{
        .io = io,
        .allocator = testing.allocator,
        .term = &e.term_h,
        .painter = .{ .fd = -1, .frame = &e.frame },
        .fetches = &e.fetches,
        .shared = &e.shared,
        .mt_path = mt_path,
        .loading = &e.loading,
    };
}

test "service on the synchronous read path never starts a background fetch" {
    // Search reads remotely but synchronously; it declares no fetch spec, so no
    // branch of its service may spawn a background audit.
    try testing.expect(fetch_spec == null);
    var thr = std.Io.Threaded.init(testing.allocator, .{});
    defer thr.deinit();
    var env: TestEnv = .{ .term_h = ctx.Term.init(thr.io(), -1) };
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    var st: State = .{}; // .none
    var c = mkCtx(thr.io(), &env, "/bin/false"); // would fail if it ever spawned
    try service(&st, &storage, &c);
    for (&env.fetches.values) |v| try testing.expect(v == null);
    try testing.expect(!env.shared.banner.isSet());
}

test "service consumes a toggle request into the basket and mirrors it onto the leaf" {
    const alloc = testing.allocator;
    var thr = std.Io.Threaded.init(alloc, .{});
    defer thr.deinit();
    var env: TestEnv = .{ .term_h = ctx.Term.init(thr.io(), -1) };
    var storage: Storage = .{};
    defer storage.deinit(alloc);
    // A loaded result the cursor points at; a basket op is pure — no spawn.
    storage.search = try search_json.parse(alloc,
        \\{"results":[{"name":"bat","type":"formula","installed":false}]}
    );
    storage.checked = try alloc.alloc(bool, 1);
    @memset(storage.checked, false);
    var st: State = .{ .items = storage.search.?.items, .request = .toggle };
    var c = mkCtx(thr.io(), &env, "/bin/false"); // would fail if the pure op ever spawned
    try service(&st, &storage, &c);
    try testing.expectEqual(Request.none, st.request); // consumed
    try testing.expect(storage.selected.contains("bat", .formula)); // added to the basket
    try testing.expectEqual(@as(usize, 1), st.selected_count); // mirrored onto the leaf
    try testing.expect(storage.checked[0]); // and re-projected onto the on-screen row
    try testing.expect(!env.shared.banner.isSet());
}

test "entering the tab does not trigger a remote read even when marked dirty" {
    // Search diverges from the other tabs: no lazy dirty-load on entry. A mutation
    // elsewhere marks it dirty, but entering must stay idle — a surprise remote read
    // on a tab switch would freeze the frame. `/bin/false` would fail if ever spawned.
    var thr = std.Io.Threaded.init(testing.allocator, .{});
    defer thr.deinit();
    var env: TestEnv = .{ .term_h = ctx.Term.init(thr.io(), -1) };
    env.shared.dirty.insert(.search);
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    var st: State = .{}; // .none request, idle phase
    st.chrome.filter.push("firefox"); // a committed query exists, yet entry must not read it
    var c = mkCtx(thr.io(), &env, "/bin/false");
    try service(&st, &storage, &c);
    try testing.expectEqual(Phase.idle, st.phase); // never searched on entry
    try testing.expectEqual(@as(usize, 0), st.items.len);
    try testing.expect(!env.shared.banner.isSet());
    try testing.expect(env.shared.dirty.contains(.search)); // flag left unconsumed
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

test "a failed search names the op in the banner and leaves no stuck searching phase" {
    var thr = std.Io.Threaded.init(testing.allocator, .{});
    defer thr.deinit();
    var env: TestEnv = .{ .term_h = ctx.Term.init(thr.io(), -1) };
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    var st: State = .{};
    st.chrome.filter.push("fire");
    st.phase = .searching; // as the pre-spawn paint left it
    var c = mkCtx(thr.io(), &env, "/bin/echo"); // echo emits non-JSON → parse fails
    try testing.expectError(error.BadJson, loadSearch(&st, &storage, &c));
    try testing.expectEqualStrings("search failed: BadJson", env.shared.banner.slice());
    // No prior results → guidance, not a spinner frozen behind the banner.
    try testing.expectEqual(Phase.idle, st.phase);
    try testing.expectEqual(@as(usize, 0), st.items.len);
}

test "a failed search keeps the last-good results and selection, falling back to the list" {
    var thr = std.Io.Threaded.init(testing.allocator, .{});
    defer thr.deinit();
    var env: TestEnv = .{ .term_h = ctx.Term.init(thr.io(), -1) };
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    // Prime a prior successful search: storage + leaf borrow these results.
    storage.search = try search_json.parse(testing.allocator,
        \\{"results":[{"name":"jq","type":"formula","installed":true},{"name":"yq","type":"formula","installed":false}]}
    );
    var st: State = .{};
    st.items = storage.search.?.items;
    st.chrome.filter.push("q");
    st.chrome.view.selected = 1; // cursor on yq
    st.phase = .searching; // as the pre-spawn paint left it
    var c = mkCtx(thr.io(), &env, "/bin/echo"); // non-JSON → BadJson on the new query

    try testing.expectError(error.BadJson, loadSearch(&st, &storage, &c));
    try testing.expectEqualStrings("search failed: BadJson", env.shared.banner.slice());
    // Prior results exist → fall back to the list, not guidance; and the storage is
    // swapped only after a clean parse, so the rows and the cursor both survive.
    try testing.expectEqual(Phase.loaded, st.phase);
    try testing.expectEqual(@as(usize, 2), st.items.len);
    try testing.expectEqual(@as(usize, 1), st.chrome.view.selected);
}
