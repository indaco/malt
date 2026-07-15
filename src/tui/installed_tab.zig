//! malt — Installed tab for `mt tui`: the first data-bearing pane.
//!
//! Leaf module. Pure cores only: `step(...)` maps a key to a `Cmd` (Enter reads
//! `mt info`, a confirmed `x` re-execs `mt uninstall`), and `update` folds the
//! pump's result back (an info read opens the pane, a list read swaps rows, a
//! finished uninstall refetches). The tab names effects as data and never imports
//! the runner. `render(state, frame, rect)` is a pure function of
//! `(state, rect)` so a resize is a re-render. The shell owns the I/O and the
//! row data's lifetime; `items` and `detail` borrow from that storage. Rows are
//! filtered by the shared filter, the selection is highlighted, and a selected
//! row's detail (deps / tap / size / linked / pinned) renders through the
//! reusable `detail_pane`. `x` raises a one-key `[y/N]` guard — the app's single
//! TUI-side confirm, justified only because `mt uninstall` has no prompt of its
//! own. Arming latches the target's name by copy, so the confirm always acts on
//! the package the guard was raised over — a moved selection or a reloaded list
//! cannot retarget it; `y` then delegates to the real `mt uninstall`, unweakened.

const std = @import("std");
const tab = @import("tab.zig");
const cmd = @import("cmd.zig");
const ctx = @import("ctx.zig");
const detail_pane = @import("detail_pane.zig");
const scroll_list = @import("scroll_list.zig");
const list_json = @import("json/list.zig");
const info_json = @import("json/info.zig");
const color = @import("../ui/color.zig");
const bytes = @import("../ui/bytes.zig");

pub const Pkg = list_json.Pkg;

/// Scratch bound shared by a formatted row, the guard banner, and the latched
/// target name, so none of the three can silently outgrow the others.
const row_buf_len = 256;

/// The uninstall guard's target, latched at arm time. The name is copied — not
/// borrowed — because `items` borrows shell-owned parse storage that a reload
/// can free while the guard is up.
pub const ConfirmTarget = struct {
    buf: [row_buf_len]u8 = undefined,
    len: usize = 0,

    pub fn init(pkg_name: []const u8) ConfirmTarget {
        var t: ConfirmTarget = .{};
        t.len = @min(pkg_name.len, t.buf.len);
        @memcpy(t.buf[0..t.len], pkg_name[0..t.len]);
        return t;
    }

    pub fn name(self: *const ConfirmTarget) []const u8 {
        return self.buf[0..self.len];
    }
};

/// The selected row's detail: the `list` row (size/linked/pinned) plus the
/// `mt info` payload (deps/tap). Both borrow from shell-owned storage.
pub const Detail = struct {
    pkg: Pkg,
    info: info_json.Info,
};

pub const State = struct {
    chrome: tab.Chrome = .{},
    /// Installed rows, borrowed from shell-owned parse storage.
    items: []const Pkg = &.{},
    /// The open detail pane, if a row was selected with Enter.
    detail: ?Detail = null,
    /// The `[y/N]` uninstall guard, latched on the package it was armed over.
    confirm_uninstall: ?ConfirmTarget = null,
    /// The target of an uninstall in flight, latched out of the guard so its name
    /// (borrowed by the `run_mutation` argv) outlives the guard banner clearing and
    /// the synchronous re-enter. `update` clears it when the mutation lands.
    pending_uninstall: ?ConfirmTarget = null,
};

/// Tab-private parse storage: the `list` rows the tab borrows and the open detail
/// pane's `info` parse. Owned beside the tab so each arena's lifetime lives here,
/// not in a central store. `deinit` frees both.
pub const Storage = struct {
    installed: ?list_json.Parsed = null,
    detail: ?info_json.Parsed = null,

    pub fn deinit(self: *Storage, allocator: std.mem.Allocator) void {
        _ = allocator; // both fields own self-freeing parse arenas
        if (self.installed) |p| p.deinit();
        if (self.detail) |p| p.deinit();
    }
};

/// Installed reads synchronously from the DB; it never background-fetches.
pub const fetch_spec: ?tab.FetchSpec = null;

pub fn title() []const u8 {
    return "Installed";
}

/// The tab's action keys, surfaced in the shared footer next to the global keys.
pub fn footerHint() []const u8 {
    return "enter: details   x: uninstall";
}

/// Case-insensitive substring match of `filter` against `name`. An empty filter
/// matches everything.
pub fn matches(name: []const u8, filter: []const u8) bool {
    return filter.len == 0 or std.ascii.indexOfIgnoreCase(name, filter) != null;
}

fn filteredCount(items: []const Pkg, filter: []const u8) usize {
    var n: usize = 0;
    for (items) |p| {
        if (matches(p.name, filter)) n += 1;
    }
    return n;
}

/// The package the selection currently points at, after applying the filter and
/// clamping the (shell-driven, unbounded) selection into the filtered list.
pub fn selectedPkg(s: *const State) ?Pkg {
    const filter = s.chrome.filter.slice();
    const nf = filteredCount(s.items, filter);
    if (nf == 0) return null;
    const sel = @min(s.chrome.view.selected, nf - 1);
    var fi: usize = 0;
    for (s.items) |p| {
        if (!matches(p.name, filter)) continue;
        if (fi == sel) return p;
        fi += 1;
    }
    return null; // unreachable: sel < nf
}

/// Pure transition: map a key to a `Cmd`. Enter reads the selected row's `mt info`
/// into the detail pane; `x` arms the fat-finger uninstall guard (pure state);
/// Esc/End are pure. While the guard is up, the next key resolves it.
pub fn step(allocator: std.mem.Allocator, mt_path: []const u8, s: *State, storage: *Storage, key: tab.Key) cmd.Cmd {
    _ = storage;
    if (s.confirm_uninstall != null) return resolveGuard(allocator, mt_path, s, key);
    switch (key) {
        .enter => return openDetailCmd(allocator, mt_path, s),
        .esc => s.detail = null, // close the detail pane
        // Only the tab knows its filtered row count, so the shell defers End here.
        .end => s.chrome.view.selected = filteredCount(s.items, s.chrome.filter.slice()) -| 1,
        .char => |c| if (c.len == 1 and c.bytes[0] == 'x') {
            // Fat-finger guard before delegating uninstall. Latch the target at
            // arm time; an empty or filtered-out list has nothing to guard.
            if (selectedPkg(s)) |p| s.confirm_uninstall = ConfirmTarget.init(p.name);
        },
        else => {},
    }
    return .none;
}

/// `y` confirms (the real `mt uninstall` of the latched target); every other key —
/// `n`, Esc, Enter — cancels. A fat-finger gate, not a typed-confirm. The guard is
/// cleared here regardless of outcome so a failed uninstall never leaves it stuck;
/// the target moves to `pending_uninstall` so its name outlives the guard for the
/// argv the mutation borrows.
fn resolveGuard(allocator: std.mem.Allocator, mt_path: []const u8, s: *State, key: tab.Key) cmd.Cmd {
    defer s.confirm_uninstall = null;
    switch (key) {
        .char => |c| if (c.len == 1 and (c.bytes[0] == 'y' or c.bytes[0] == 'Y')) {
            s.pending_uninstall = s.confirm_uninstall.?;
            return uninstallCmd(allocator, mt_path, &s.pending_uninstall.?);
        },
        else => {},
    }
    return .none;
}

pub const Hit = tab.Hit;

/// The list's on-screen geometry: the sub-rect below the heading, the view
/// `clamp`ed to that height, and the filtered row `count`. The single source of
/// truth `render` and `hitTest` share, so the painted rows and the hit-test can
/// never disagree about where a row is.
fn listGeometry(s: *const State, rect: tab.Rect) struct { list: tab.Rect, view: scroll_list.View, count: usize } {
    const nf = filteredCount(s.items, s.chrome.filter.slice());
    // The bold heading rides row 0 and costs the list one row.
    const list: tab.Rect = .{ .row = rect.row + 1, .col = rect.col, .width = rect.width, .height = rect.height -| 1 };
    return .{ .list = list, .view = scroll_list.clamp(s.chrome.view, nf, list.height), .count = nf };
}

/// Map a click to the list row it lands on. The shell consumes `Hit.open` on a
/// right-click (a detail pane exists); a left-click just uses `index` to move the
/// cursor. `click_col` is accepted but unused — rows are full-width.
pub fn hitTest(s: *const State, rect: tab.Rect, click_row: u16, click_col: u16) ?Hit {
    _ = click_col; // full-width rows: the column carries no row identity
    const g = listGeometry(s, rect);
    const idx = scroll_list.rowAt(g.view, g.list.row, g.list.height, g.count, click_row) orelse return null;
    return .{ .index = idx, .open = true }; // Installed rows open their detail pane
}

/// Pure render: an optional guard banner on top, an optional detail pane at the
/// bottom, the filtered + scrolled list in between. A pure function of
/// `(state, rect)` so a resize is a re-render.
pub fn render(s: *const State, f: *tab.Frame, r: tab.Rect) void {
    var content = r;
    if (s.confirm_uninstall) |*target| {
        renderGuard(target.name(), f, .{ .row = content.row, .col = content.col, .width = content.width, .height = 1 });
        content = .{ .row = content.row + 1, .col = content.col, .width = content.width, .height = content.height -| 1 };
    }
    var list_rect = content;
    if (s.detail) |d| {
        var size_buf: [16]u8 = undefined;
        var deps_buf: [512]u8 = undefined;
        const fields = [_]detail_pane.Field{
            .{ .label = "Tap", .value = if (d.info.tap.len != 0) d.info.tap else "-" },
            .{ .label = "Size", .value = bytes.humanizeOpt(d.pkg.size_bytes, &size_buf) },
            .{ .label = "Linked", .value = yesNo(d.pkg.linked) },
            .{ .label = "Pinned", .value = if (d.pkg.pinned) "yes" else "no" },
            .{ .label = "Dependencies", .value = joinDeps(&deps_buf, d.info.dependencies) },
        };
        const dh = @min(detail_pane.neededRows(&fields, content.width), content.height / 2);
        if (dh > 0 and dh < content.height) {
            list_rect.height = content.height - dh;
            detail_pane.render(f, &fields, .{ .row = content.row + list_rect.height, .col = content.col, .width = content.width, .height = dh });
        }
    }
    renderList(s, f, list_rect);
}

fn renderList(s: *const State, f: *tab.Frame, rect: tab.Rect) void {
    if (rect.height == 0) return;
    const filter = s.chrome.filter.slice();
    const g = listGeometry(s, rect);
    if (g.count == 0) return tab.renderHint(f, rect, if (filter.len != 0) "No matches." else "No packages installed yet.");
    // A fixed bold heading rides above the list and costs it one row.
    tab.renderHeading(f, rect, 0, &.{
        .{ .label = "NAME", .width = 22 },
        .{ .label = "VERSION", .width = 14 },
        .{ .label = "SIZE", .width = 10 },
    });
    const list = g.list;
    if (list.height == 0) return; // the heading took the only row
    const v = g.view;

    var fi: usize = 0;
    for (s.items) |p| {
        if (!matches(p.name, filter)) continue;
        defer fi += 1;
        if (fi < v.offset) continue;
        const screen = fi - v.offset;
        if (screen >= list.height) break;
        f.moveTo(list.row + @as(u16, @intCast(screen)), list.col);
        const selected = fi == v.selected;
        if (selected) { // mark the cursor row; the accent backgrounds it under a theme
            f.put(color.selectionAccent());
            f.put(color.Style.reverse.code());
        }
        var rb: [row_buf_len]u8 = undefined;
        f.putContent(scroll_list.truncate(formatRow(&rb, p), list.width));
        if (selected) f.put(color.Style.reset.code());
    }
}

/// The banner names the latched target, never the live selection — what it
/// shows is exactly what `y` will uninstall.
fn renderGuard(name: []const u8, f: *tab.Frame, rect: tab.Rect) void {
    f.moveTo(rect.row, rect.col);
    f.put(color.Style.reverse.code());
    var b: [row_buf_len]u8 = undefined;
    const line = std.fmt.bufPrint(&b, "Uninstall {s}? [y/N]", .{name}) catch "Uninstall? [y/N]";
    f.putContent(scroll_list.truncate(line, rect.width));
    f.put(color.Style.reset.code());
}

/// One list row: name and version in fixed columns, the shared humanized size
/// (`"-"` when unknown), then the pinned / unlinked markers. ASCII columns,
/// grapheme-naive like the rest.
fn formatRow(buf: []u8, p: Pkg) []const u8 {
    var len: usize = 0;
    appendPad(buf, &len, p.name, 22);
    append(buf, &len, " ");
    appendPad(buf, &len, p.version, 14);
    append(buf, &len, " ");
    var size_buf: [16]u8 = undefined;
    appendPad(buf, &len, bytes.humanizeOpt(p.size_bytes, &size_buf), 10);
    if (p.pinned) append(buf, &len, " pinned");
    if (p.linked) |l| {
        if (!l) append(buf, &len, " unlinked");
    }
    return buf[0..len];
}

fn yesNo(b: ?bool) []const u8 {
    return if (b) |v| (if (v) "yes" else "no") else "-";
}

/// Comma-join dependency names, bounded by `buf`; empty → "none".
fn joinDeps(buf: []u8, deps: []const []const u8) []const u8 {
    if (deps.len == 0) return "none";
    var len: usize = 0;
    for (deps, 0..) |dep, i| {
        if (i != 0) append(buf, &len, ", ");
        append(buf, &len, dep);
    }
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

// ─── effect producers ───────────────────────────────────────────────────
// The tab names effects as `Cmd` values; the pump performs them and folds the
// result back through `update`. No I/O and no runner import here.

/// Cheap keg count from `mt list --json` bytes (no `--size --linked` walk). Header
/// infrastructure: parses to a temporary and returns only the count, touching no
/// `Storage` — the shared `installed_count` writer (app/header-side) sources its
/// number here so the hub need not import the list parser.
pub fn countFromJson(allocator: std.mem.Allocator, json: []const u8) list_json.Error!usize {
    const parsed = try list_json.parse(allocator, json);
    defer parsed.deinit();
    return parsed.items.len;
}

/// Build the `mt info <pkg> --json` read for the selected row (a blocking read, no
/// alt-screen drop), or `Cmd.none` when nothing is selected. `update` folds the
/// info into the detail pane.
fn openDetailCmd(allocator: std.mem.Allocator, mt_path: []const u8, s: *const State) cmd.Cmd {
    const sel = selectedPkg(s) orelse return .none; // nothing selected
    const argv = cmd.jsonArgv(allocator, mt_path, &.{ "info", sel.name }) catch return .none;
    return .{ .read = .{ .argv = argv, .mode = .blocking, .parse = cmd.parserFor(.info, info_json.parse), .tag = .installed, .fail_op = "info read failed" } };
}

/// Build the `mt uninstall <name>` mutation for the guard's latched target. The
/// name borrows `pending_uninstall`, which outlives the guard and the re-enter.
fn uninstallCmd(allocator: std.mem.Allocator, mt_path: []const u8, target: *const ConfirmTarget) cmd.Cmd {
    const argv = cmd.inlineArgv(allocator, mt_path, &.{ "uninstall", target.name() }) catch return .none;
    return .{ .run_mutation = .{ .argv = argv, .tag = .installed, .fail_op = "uninstall failed" } };
}

/// The `mt list --json --size --linked` read: the `--size`/`--linked` keg-dir walk
/// is paid only here, lazily. Blocking, empty-ok (a fresh prefix's empty Cellar).
fn listReadCmd(allocator: std.mem.Allocator, mt_path: []const u8) cmd.Cmd {
    const argv = cmd.jsonArgv(allocator, mt_path, &.{ "list", "--size", "--linked" }) catch return .none;
    return .{ .read = .{ .argv = argv, .allow_empty = true, .mode = .blocking, .parse = cmd.parserFor(.list, list_json.parse), .tag = .installed, .fail_op = "list refresh failed" } };
}

/// The lazy on-entry reload: Installed has no background fetch, so the pump asks
/// for this `list` read when the tab is entered dirty (a cross-tab mutation, or
/// launch). Distinct from the post-uninstall reload `update` returns.
pub fn refreshCmd(allocator: std.mem.Allocator, mt_path: []const u8) cmd.Cmd {
    return listReadCmd(allocator, mt_path);
}

/// Fold a completed effect back into the model. A delivered `info` read opens the
/// detail pane; a delivered `list` read swaps in the rows; an empty `list` read
/// clears the Cellar; a finished uninstall (exit 0) refetches the list, else banners.
pub fn update(allocator: std.mem.Allocator, mt_path: []const u8, s: *State, storage: *Storage, shared: *ctx.SharedModel, msg: cmd.Msg) cmd.Cmd {
    switch (msg) {
        .loaded => |parsed| {
            switch (parsed) {
                .info => |info_p| setDetail(s, storage, info_p),
                .list => |list_p| swapRows(s, storage, shared, list_p),
                // Installed only issues info/list reads; free any misrouted parse.
                inline else => |p| p.deinit(),
            }
            return .none;
        },
        .failed => return .none, // the pump set the banner; keep the last-good rows
        .cleared => {
            clear(s, storage, shared); // an empty `mt list` read: a fresh, empty Cellar
            return .none;
        },
        .mutated => |code| {
            s.pending_uninstall = null; // the in-flight target is spent
            if (code != 0) {
                shared.banner.set("uninstall failed", "ChildFailed");
                return .none;
            }
            shared.markStaleAfter(.installed); // the keg is gone; the siblings may be stale
            return listReadCmd(allocator, mt_path); // the keg is gone — refetch
        },
    }
}

/// Open the detail pane over the delivered `mt info` parse, freeing the previous.
/// If the selection vanished between the read and the fold, drop the parse.
fn setDetail(s: *State, storage: *Storage, parsed: info_json.Parsed) void {
    const sel = selectedPkg(s) orelse {
        parsed.deinit();
        return;
    };
    if (storage.detail) |old| old.deinit();
    storage.detail = parsed;
    s.detail = .{ .pkg = sel, .info = parsed.info };
}

/// Repoint the rows at a fresh `list` parse, freeing the previous one. Swapped only
/// after a clean parse upstream, so a failed refresh keeps the last-good rows.
fn swapRows(s: *State, storage: *Storage, shared: *ctx.SharedModel, parsed: list_json.Parsed) void {
    if (storage.installed) |old| old.deinit();
    storage.installed = parsed;
    s.items = parsed.items;
    s.detail = null; // a refreshed list invalidates the old detail
    shared.installed_count = parsed.items.len;
}

/// Clear to an empty Cellar (a fresh prefix), freeing any held list parse.
fn clear(s: *State, storage: *Storage, shared: *ctx.SharedModel) void {
    if (storage.installed) |old| old.deinit();
    storage.installed = null;
    s.items = &.{};
    s.detail = null;
    shared.installed_count = 0; // empty Cellar is a known zero, not "unknown"
}

const testing = std.testing;

fn ch(c: u8) tab.Key {
    return .{ .char = .{ .bytes = .{ c, 0, 0, 0 }, .len = 1 } };
}

/// Drive `step` with a throwaway storage and a fixed mt path. Installed's `step`
/// ignores storage, so this keeps the pure-behaviour tests readable.
fn stepKey(s: *State, key: tab.Key) cmd.Cmd {
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    return step(testing.allocator, "/opt/malt/bin/mt", s, &storage, key);
}

const sample = [_]Pkg{
    .{ .name = "brotli", .version = "1.2.0", .kind = .formula, .pinned = false, .size_bytes = 1902690, .linked = true },
    .{ .name = "curl", .version = "8.20.0", .kind = .formula, .pinned = true, .size_bytes = 4734154, .linked = false },
    .{ .name = "ffmpeg", .version = "8.1.1", .kind = .formula, .pinned = false, .size_bytes = 53481917, .linked = true },
    .{ .name = "flux", .version = "1.0", .kind = .cask, .pinned = false, .size_bytes = 21835970, .linked = null },
};

test "matches is a case-insensitive substring; empty filter matches all" {
    try testing.expect(matches("ffmpeg", ""));
    try testing.expect(matches("ffmpeg", "ff"));
    try testing.expect(matches("FFmpeg", "ff")); // case-insensitive
    try testing.expect(matches("curl", "URL"));
    try testing.expect(!matches("curl", "zzz"));
}

test "selectedPkg applies the filter and clamps an out-of-range selection" {
    var s: State = .{ .items = &sample };
    s.chrome.view.selected = 0;
    try testing.expectEqualStrings("brotli", selectedPkg(&s).?.name);

    // Filter to the two 'f' names; selection clamps into the filtered list.
    s.chrome.filter.push("f");
    s.chrome.view.selected = 0;
    try testing.expectEqualStrings("ffmpeg", selectedPkg(&s).?.name);
    s.chrome.view.selected = 99; // way past the end → clamps to the last match
    try testing.expectEqualStrings("flux", selectedPkg(&s).?.name);

    // A filter that matches nothing yields no selection.
    s.chrome.filter.clear();
    s.chrome.filter.push("zzz");
    try testing.expect(selectedPkg(&s) == null);
}

test "End jumps to the last filtered row; an empty list stays at zero" {
    var s: State = .{ .items = &sample };
    _ = stepKey(&s, .end);
    try testing.expectEqual(@as(usize, 3), s.chrome.view.selected);

    s.chrome.filter.push("f"); // ffmpeg, flux
    _ = stepKey(&s, .end);
    try testing.expectEqual(@as(usize, 1), s.chrome.view.selected);

    var e: State = .{ .items = &.{} };
    _ = stepKey(&e, .end);
    try testing.expectEqual(@as(usize, 0), e.chrome.view.selected);
}

test "Enter returns the `mt info` read for the selected row" {
    var s: State = .{ .items = &sample };
    const eff = stepKey(&s, .enter);
    defer testing.allocator.free(eff.read.argv);
    try testing.expect(eff == .read);
    try testing.expectEqual(cmd.MsgTag.installed, eff.read.tag);
    try testing.expectEqualStrings("info", eff.read.argv[1]);
    try testing.expectEqualStrings("brotli", eff.read.argv[2]); // the selected row
}

test "Esc closes an open detail pane" {
    var s: State = .{ .items = &sample, .detail = .{ .pkg = sample[0], .info = .{} } };
    try testing.expect(stepKey(&s, .esc) == .none);
    try testing.expect(s.detail == null);
}

test "x raises the uninstall guard, producing no effect yet" {
    var s: State = .{ .items = &sample };
    try testing.expect(stepKey(&s, ch('x')) == .none); // no effect yet
    try testing.expect(s.confirm_uninstall != null);
    try testing.expectEqualStrings("brotli", s.confirm_uninstall.?.name()); // latched at arm time
}

test "y confirms the guard: returns the uninstall of the latched name and lowers the guard" {
    var s: State = .{ .items = &sample };
    _ = stepKey(&s, ch('x'));
    const eff = stepKey(&s, ch('y'));
    defer testing.allocator.free(eff.run_mutation.argv);
    try testing.expect(eff == .run_mutation);
    try testing.expectEqualStrings("uninstall", eff.run_mutation.argv[1]);
    try testing.expectEqualStrings("brotli", eff.run_mutation.argv[2]);
    try testing.expect(s.confirm_uninstall == null); // guard lowered
    try testing.expectEqualStrings("brotli", s.pending_uninstall.?.name()); // latched for the argv
}

test "n and Esc cancel the guard with no effect" {
    var s: State = .{ .items = &sample };
    _ = stepKey(&s, ch('x'));
    try testing.expect(stepKey(&s, ch('n')) == .none);
    try testing.expect(s.confirm_uninstall == null);

    _ = stepKey(&s, ch('x'));
    try testing.expect(stepKey(&s, .esc) == .none);
    try testing.expect(s.confirm_uninstall == null);
}

test "arming latches the target: moving the selection cannot retarget the confirm" {
    var s: State = .{ .items = &sample };
    _ = stepKey(&s, ch('x')); // arm on brotli (row 0)
    s.chrome.view.selected = 2; // the shell moved the selection to ffmpeg
    const eff = stepKey(&s, ch('y'));
    defer testing.allocator.free(eff.run_mutation.argv);
    try testing.expectEqualStrings("brotli", eff.run_mutation.argv[2]); // still brotli
}

test "a list reloaded while the guard is up cannot retarget the latched confirm" {
    var s: State = .{ .items = &sample };
    _ = stepKey(&s, ch('x')); // arm on brotli (row 0)
    // A dirty-tab refetch swaps the rows with no keypress; the latch must hold.
    const reloaded = [_]Pkg{sample[2]}; // ffmpeg is now row 0
    s.items = &reloaded;
    const eff = stepKey(&s, ch('y'));
    defer testing.allocator.free(eff.run_mutation.argv);
    try testing.expectEqualStrings("brotli", eff.run_mutation.argv[2]);
}

test "uppercase Y confirms the guard like y" {
    var s: State = .{ .items = &sample };
    _ = stepKey(&s, ch('x'));
    const eff = stepKey(&s, ch('Y'));
    defer testing.allocator.free(eff.run_mutation.argv);
    try testing.expect(eff == .run_mutation);
    try testing.expect(s.confirm_uninstall == null);
}

test "the latch truncates an oversized name instead of overflowing" {
    const long = "n" ** (row_buf_len + 44);
    const t = ConfirmTarget.init(long);
    try testing.expectEqual(@as(usize, row_buf_len), t.name().len);
    try testing.expectEqualStrings(long[0..row_buf_len], t.name());
}

test "x on an empty or fully filtered-out list does not arm a targetless guard" {
    var s: State = .{ .items = &.{} };
    try testing.expect(stepKey(&s, ch('x')) == .none);
    try testing.expect(s.confirm_uninstall == null);

    var t: State = .{ .items = &sample };
    t.chrome.filter.push("zzznomatch");
    try testing.expect(stepKey(&t, ch('x')) == .none);
    try testing.expect(t.confirm_uninstall == null);
}

test "the guard banner names the latched package even after the selection moved" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var s: State = .{ .items = &sample };
    s.chrome.view.selected = 1; // curl
    _ = stepKey(&s, ch('x')); // arm on curl
    s.chrome.view.selected = 2; // selection moved to ffmpeg
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 10 });
    try testing.expect(std.mem.indexOf(u8, f.slice(), "Uninstall curl? [y/N]") != null);
}

test "while the guard is up, Enter cancels it and does not open a detail read" {
    var s: State = .{ .items = &sample };
    _ = stepKey(&s, ch('x'));
    try testing.expect(stepKey(&s, .enter) == .none); // Enter is "default No" — cancels
    try testing.expect(s.confirm_uninstall == null);
}

test "render heads the columns in bold, aligned over their values" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample };
    render(&s, &f, .{ .row = 3, .col = 1, .width = 80, .height = 10 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, color.Style.bold.code()) != null);
    // Exact padding proves NAME / VERSION / SIZE sit over their value columns.
    try testing.expect(std.mem.indexOf(u8, out, "NAME" ++ " " ** 19 ++ "VERSION" ++ " " ** 8 ++ "SIZE") != null);
    try testing.expect(std.mem.indexOf(u8, out, "brotli") != null); // the list still renders below
}

test "the heading sits at the top row and shifts the first list row down one" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample };
    render(&s, &f, .{ .row = 5, .col = 1, .width = 80, .height = 10 });
    const out = f.slice();
    const head = std.mem.indexOf(u8, out, "\x1b[5;1H").?; // heading at the content top row
    const first = std.mem.indexOf(u8, out, "\x1b[6;1H").?; // first item one row below
    try testing.expect(head < first);
    try testing.expect(std.mem.indexOf(u8, out[head..first], "NAME") != null); // heading on the top row
    try testing.expect(std.mem.indexOf(u8, out[first..], "brotli") != null); // first item below it
}

test "render at height one shows only the heading and never traps" {
    var buf: [1024]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 1 }); // the heading eats the only row
    try testing.expect(std.mem.indexOf(u8, f.slice(), "NAME") != null);
}

test "render lists rows with name, version, and a humanized size" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample };
    render(&s, &f, .{ .row = 3, .col = 1, .width = 80, .height = 10 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "brotli") != null);
    try testing.expect(std.mem.indexOf(u8, out, "8.20.0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "MB") != null); // size humanized
}

test "installed row renders a sub-KB size with the canonical decimal shape" {
    var buf: [row_buf_len]u8 = undefined;
    // The convergence: sub-KB sizes now carry the decimal like every other surface.
    const small = Pkg{ .name = "a", .version = "1", .kind = .formula, .pinned = false, .size_bytes = 512, .linked = true };
    try testing.expect(std.mem.indexOf(u8, formatRow(&buf, small), "512.0 B") != null);
    const zero = Pkg{ .name = "a", .version = "1", .kind = .formula, .pinned = false, .size_bytes = 0, .linked = true };
    try testing.expect(std.mem.indexOf(u8, formatRow(&buf, zero), "0.0 B") != null);
}

test "the sub-KB size field stays padded to the width-10 column" {
    var buf: [row_buf_len]u8 = undefined;
    // name(22)+" "+version(14)+" " = 38; the widest sub-KB string "1023.0 B" (8) fits the pad.
    const widest = Pkg{ .name = "a", .version = "1", .kind = .formula, .pinned = false, .size_bytes = 1023, .linked = true };
    try testing.expectEqualStrings("1023.0 B  ", formatRow(&buf, widest)[38..48]);
}

test "an unknown size still renders as a dash, padded to the width-10 column" {
    var buf: [row_buf_len]u8 = undefined;
    // Nullable behaviour is preserved across the switch to the shared humanizer.
    const unknown = Pkg{ .name = "a", .version = "1", .kind = .formula, .pinned = false, .size_bytes = null, .linked = true };
    try testing.expectEqualStrings("-         ", formatRow(&buf, unknown)[38..48]);
}

test "the detail pane renders a sub-KB size with the canonical decimal shape" {
    var buf: [8192]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const pkg = Pkg{ .name = "a", .version = "1", .kind = .formula, .pinned = false, .size_bytes = 512, .linked = true };
    const s: State = .{ .items = &.{pkg}, .detail = .{ .pkg = pkg, .info = .{} } };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 20 });
    try testing.expect(std.mem.indexOf(u8, f.slice(), "512.0 B") != null);
}

test "render shows pinned and unlinked markers" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 10 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "pinned") != null); // curl is pinned
    try testing.expect(std.mem.indexOf(u8, out, "unlinked") != null); // curl is unlinked
}

test "render narrows to the filter" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var s: State = .{ .items = &sample };
    s.chrome.filter.push("curl");
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 10 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "curl") != null);
    try testing.expect(std.mem.indexOf(u8, out, "brotli") == null); // filtered out
    try testing.expect(std.mem.indexOf(u8, out, "ffmpeg") == null);
}

test "render highlights the selected row" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var s: State = .{ .items = &sample };
    s.chrome.view.selected = 1; // curl
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 10 });
    // The reverse-video SGR marks the cursor row.
    try testing.expect(std.mem.indexOf(u8, f.slice(), color.Style.reverse.code()) != null);
}

test "render shows the detail pane with the dependency list when open" {
    var buf: [8192]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const deps = [_][]const u8{ "brotli", "zstd" };
    const s: State = .{
        .items = &sample,
        .detail = .{ .pkg = sample[1], .info = .{ .name = "curl", .tap = "homebrew/core", .dependencies = &deps } },
    };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 20 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "homebrew/core") != null); // tap
    try testing.expect(std.mem.indexOf(u8, out, "zstd") != null); // a dep that is not a list row
}

test "render draws the [y/N] guard banner naming the package when confirming" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var s: State = .{ .items = &sample };
    s.chrome.view.selected = 1; // curl
    _ = stepKey(&s, ch('x')); // arm through the real transition so the target latches
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 10 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "curl") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[y/N]") != null);
}

test "render reflows: the same state at two widths differs" {
    var a: [8192]u8 = undefined;
    var b: [8192]u8 = undefined;
    var fa: tab.Frame = .{ .buf = &a };
    var fb: tab.Frame = .{ .buf = &b };
    const s: State = .{ .items = &sample };
    render(&s, &fa, .{ .row = 1, .col = 1, .width = 80, .height = 10 });
    render(&s, &fb, .{ .row = 1, .col = 1, .width = 24, .height = 6 });
    try testing.expect(!std.mem.eql(u8, fa.slice(), fb.slice()));
}

test "render on an empty list shows the empty-state placeholder, not a blank pane" {
    var buf: [1024]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &.{} };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 10 }); // must not trap
    try testing.expect(std.mem.indexOf(u8, f.slice(), "No packages installed") != null);
}

test "a filter that excludes every row shows the no-matches placeholder" {
    var buf: [1024]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var s: State = .{ .items = &sample };
    s.chrome.filter.push("zzznomatch");
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 10 });
    try testing.expect(std.mem.indexOf(u8, f.slice(), "No matches") != null);
}

test "hitTest maps a click on the first list row to filtered index 0" {
    const s: State = .{ .items = &sample };
    // rect.row = 5 → heading at 5, list starts at 6. Clicking row 6 hits index 0.
    const hit = hitTest(&s, .{ .row = 5, .col = 1, .width = 80, .height = 10 }, 6, 1);
    try testing.expectEqual(@as(?usize, 0), if (hit) |h| h.index else null);
    try testing.expect(hit.?.open); // an Installed row opens its detail pane
}

test "hitTest rejects the heading row and rows above the list" {
    const s: State = .{ .items = &sample };
    const rect: tab.Rect = .{ .row = 5, .col = 1, .width = 80, .height = 10 };
    try testing.expect(hitTest(&s, rect, 5, 1) == null); // the heading row
    try testing.expect(hitTest(&s, rect, 4, 1) == null); // above the list
}

test "hitTest resolves against the filtered list, not the raw items" {
    var s: State = .{ .items = &sample };
    s.chrome.filter.push("f"); // ffmpeg, flux
    const rect: tab.Rect = .{ .row = 1, .col = 1, .width = 80, .height = 10 };
    try testing.expectEqual(@as(?usize, 0), hitTest(&s, rect, 2, 1).?.index); // first filtered row
    try testing.expectEqual(@as(?usize, 1), hitTest(&s, rect, 3, 1).?.index); // second filtered row
    try testing.expect(hitTest(&s, rect, 4, 1) == null); // past the two matches
}

test "hitTest adds the scrolled view offset" {
    var s: State = .{ .items = &sample };
    s.chrome.view.selected = 3; // forces clamp to scroll a 2-tall list to offset 2
    // rect.height 3 → list height 2; the top list row (row 2) maps to the offset.
    const hit = hitTest(&s, .{ .row = 1, .col = 1, .width = 80, .height = 3 }, 2, 1);
    try testing.expectEqual(@as(?usize, 2), hit.?.index);
}

test "hitTest rejects a blank row past the populated tail" {
    var s: State = .{ .items = &sample };
    s.chrome.filter.push("curl"); // one match
    // Tall list, one row: the second list row (row 3) is blank tail.
    const rect: tab.Rect = .{ .row = 1, .col = 1, .width = 80, .height = 10 };
    try testing.expectEqual(@as(?usize, 0), hitTest(&s, rect, 2, 1).?.index); // the one match
    try testing.expect(hitTest(&s, rect, 3, 1) == null); // blank tail
}

test "hitTest on an empty list hits nothing" {
    const s: State = .{ .items = &.{} }; // count 0 must reach rowAt, not a stray index
    const rect: tab.Rect = .{ .row = 1, .col = 1, .width = 80, .height = 10 };
    try testing.expect(hitTest(&s, rect, 2, 1) == null);
}

test "hitTest when the heading ate the only row hits nothing" {
    const s: State = .{ .items = &sample };
    // height 1 → list.height 0. Clicking the first would-be list row (row 2) must
    // resolve to null: the list height (0), not the rect height (1), drives the hit.
    try testing.expect(hitTest(&s, .{ .row = 1, .col = 1, .width = 80, .height = 1 }, 2, 1) == null);
}

test "conforms to the tab contract" {
    comptime tab.verify(@This());
}

test "Storage.deinit frees the installed and detail parses" {
    const allocator = std.testing.allocator;
    var storage: Storage = .{};
    storage.installed = try list_json.parse(allocator, "{\"installed\":[]}");
    storage.detail = try info_json.parse(allocator, "{\"name\":\"a\",\"dependencies\":[]}");
    // A no-op deinit leaks both parse arenas; `testing.allocator` trips at scope
    // end, pinning that deinit frees every owned resource.
    storage.deinit(allocator);
}

test "countFromJson returns the row count without retaining the parse" {
    const allocator = std.testing.allocator;
    // A leaked parse arena would trip `testing.allocator` at scope end, so this
    // also pins that the count read frees its temporary.
    const n = try countFromJson(allocator,
        \\{"installed":[{"name":"jq","version":"1","type":"formula","pinned":false},{"name":"wget","version":"2","type":"formula","pinned":false}]}
    );
    try testing.expectEqual(@as(usize, 2), n);
}

test "countFromJson reports zero for an empty Cellar" {
    // The edge the header renders as `0 kegs`, distinct from an unknown count.
    const n = try countFromJson(std.testing.allocator, "{\"installed\":[]}");
    try testing.expectEqual(@as(usize, 0), n);
}

test "Installed declares no background fetch — its reads are synchronous" {
    try testing.expect(fetch_spec == null);
}

test "update on a loaded info parse opens the detail pane over the selected row" {
    var st: State = .{ .items = &sample };
    var storage: Storage = .{};
    var shared: ctx.SharedModel = .{};
    defer storage.deinit(testing.allocator);
    const info = try info_json.parse(testing.allocator, "{\"name\":\"brotli\",\"dependencies\":[]}");
    const next = update(testing.allocator, "/bin/mt", &st, &storage, &shared, .{ .loaded = .{ .info = info } });
    try testing.expect(next == .none);
    try testing.expect(st.detail != null);
}

test "update on a loaded list parse swaps rows in and sets the keg count" {
    var st: State = .{};
    var storage: Storage = .{};
    var shared: ctx.SharedModel = .{};
    defer storage.deinit(testing.allocator);
    const list = try list_json.parse(testing.allocator, "{\"installed\":[{\"name\":\"jq\",\"version\":\"1\",\"type\":\"formula\",\"pinned\":false}]}");
    const next = update(testing.allocator, "/bin/mt", &st, &storage, &shared, .{ .loaded = .{ .list = list } });
    try testing.expect(next == .none);
    try testing.expectEqual(@as(usize, 1), st.items.len);
    try testing.expectEqual(@as(?usize, 1), shared.installed_count);
}

test "update on a cleared read empties the Cellar to a known zero" {
    var st: State = .{ .items = &sample };
    var storage: Storage = .{};
    var shared: ctx.SharedModel = .{};
    defer storage.deinit(testing.allocator);
    const next = update(testing.allocator, "/bin/mt", &st, &storage, &shared, .cleared);
    try testing.expect(next == .none);
    try testing.expectEqual(@as(usize, 0), st.items.len);
    try testing.expectEqual(@as(?usize, 0), shared.installed_count);
}

test "a successful uninstall clears the pending target, marks siblings stale, refetches" {
    var st: State = .{ .pending_uninstall = ConfirmTarget.init("brotli") };
    var storage: Storage = .{};
    var shared: ctx.SharedModel = .{};
    defer storage.deinit(testing.allocator);
    const next = update(testing.allocator, "/bin/mt", &st, &storage, &shared, .{ .mutated = 0 });
    defer testing.allocator.free(next.read.argv);
    try testing.expect(next == .read);
    try testing.expectEqualStrings("list", next.read.argv[1]); // refetch the list
    try testing.expect(st.pending_uninstall == null);
    try testing.expect(shared.takeDirty(.outdated)); // siblings marked stale
}

test "a failed uninstall banners and does not refetch" {
    var st: State = .{ .pending_uninstall = ConfirmTarget.init("brotli") };
    var storage: Storage = .{};
    var shared: ctx.SharedModel = .{};
    defer storage.deinit(testing.allocator);
    const next = update(testing.allocator, "/bin/mt", &st, &storage, &shared, .{ .mutated = 1 });
    try testing.expect(next == .none);
    try testing.expect(st.pending_uninstall == null);
    try testing.expect(std.mem.startsWith(u8, shared.banner.slice(), "uninstall failed"));
}

test "refreshCmd is the `mt list --size --linked` read for the lazy on-entry reload" {
    const eff = refreshCmd(testing.allocator, "/bin/mt");
    defer testing.allocator.free(eff.read.argv);
    try testing.expect(eff == .read);
    try testing.expect(eff.read.allow_empty); // a fresh prefix reads empty
    try testing.expectEqualStrings("list", eff.read.argv[1]);
    try testing.expectEqualStrings("--size", eff.read.argv[2]);
    try testing.expectEqualStrings("--linked", eff.read.argv[3]);
    try testing.expectEqualStrings("--json", eff.read.argv[4]);
}
