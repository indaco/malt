//! malt — Outdated tab for `mt tui`: the multi-select upgrade pane.
//!
//! Leaf module. Pure cores only: `step` toggles the per-row checkbox set (pure
//! state) or returns an upgrade `Cmd` for the real `mt upgrade`; `update` folds
//! the pump's result back — a finished pass drops its rows, then chains the cask
//! pass after the formula one (`mt upgrade <name>` is formula-first, so the kinds
//! run separately). The tab names effects as data and never imports the runner.
//! `render(state, frame, rect)` is a pure function of
//! `(state, rect)` so a resize is a re-render. The shell owns the row data and
//! the parallel `checked` buffer; the tab borrows both. Pinned rows are shown
//! greyed and can never enter the checked set — the wireframe holds them back
//! from a bulk upgrade. `space` toggles the cursor row, `a` checks all
//! non-pinned, `n` clears, and `u`/Enter with N>0 requests the upgrade; an empty
//! selection is a no-op surfaced by the action line.

const std = @import("std");
const cmd = @import("cmd.zig");
const ctx = @import("ctx.zig");
const tab = @import("tab.zig");
const scroll_list = @import("scroll_list.zig");
const outdated_json = @import("json/outdated.zig");
const color = @import("../ui/color.zig");

pub const Row = outdated_json.OutdatedRow;
const Kind = outdated_json.Kind;

pub const State = struct {
    chrome: tab.Chrome = .{},
    /// Outdated rows, borrowed from shell-owned parse storage.
    items: []const Row = &.{},
    /// Per-row checkbox state, parallel to `items`, owned by the shell. A pinned
    /// row's slot is never set. The cores guard against a shorter slice so a
    /// not-yet-sized buffer (before the shell allocates it) never traps.
    checked: []bool = &.{},
    /// The upgrade pass in flight, so `update` knows which kind's checked rows a
    /// finished `mt upgrade` covered. `mt upgrade <name>` is formula-first, so the
    /// two kinds run as separate passes; `null` when no upgrade is in flight.
    pending_kind: ?Kind = null,
};

/// Tab-private parse storage: the Outdated audit's parsed rows plus the parallel
/// checkbox buffer the tab borrows. Owned beside the tab so the parse arena's
/// lifetime lives here, not in a central store. `deinit` frees both.
pub const Storage = struct {
    outdated: ?outdated_json.Parsed = null,
    /// Per-row checkbox buffer, sized to the row count on each (re)load.
    checked: []bool = &.{},

    pub fn deinit(self: *Storage, allocator: std.mem.Allocator) void {
        if (self.outdated) |p| p.deinit();
        if (self.checked.len != 0) allocator.free(self.checked);
    }
};

/// Outdated audits in the background; a non-clean exit means a failed refresh.
pub const fetch_spec: ?tab.FetchSpec = .{ .verb = &.{"outdated"}, .max_ok_exit = 0, .refresh_op = "outdated refresh failed", .parse = cmd.parserFor(.outdated, outdated_json.parse) };

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
/// least `selectedCount`) in item order; returns the count written. Pinned rows
/// are excluded even if a stray bit is set, so a held-back package can never
/// reach an upgrade.
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

/// Pure transition: toggle the cursor row / bulk select / clear are pure state
/// (`Cmd.none`); `u`/Enter with a non-empty selection returns the upgrade `Cmd`.
/// A pinned cursor row cannot be toggled.
pub fn step(allocator: std.mem.Allocator, mt_path: []const u8, s: *State, storage: *Storage, key: tab.Key) cmd.Cmd {
    _ = storage;
    switch (key) {
        .space => toggleSelected(s),
        .enter => return upgradeCmd(allocator, mt_path, s),
        // Only the tab knows its filtered row count, so the shell defers End here.
        .end => s.chrome.view.selected = filteredCount(s.items, s.chrome.filter.slice()) -| 1,
        .char => |c| if (c.len == 1) switch (c.bytes[0]) {
            'u' => return upgradeCmd(allocator, mt_path, s),
            'a' => setAll(s, true),
            'n' => setAll(s, false),
            else => {},
        },
        else => {},
    }
    return .none;
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

/// Pure render: the filtered + scrolled checkbox list. The multi-select keys
/// live in the shared footer, so the list owns the whole rect; the `[✓]`
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
    // A fixed bold heading rides above the list and costs it one row.
    tab.renderHeading(f, rect, 4, &.{
        .{ .label = "NAME", .width = 22 },
        .{ .label = "CURRENT", .width = 12 },
        .{ .label = "AVAILABLE", .width = 12 },
        .{ .label = "KIND", .width = 8 },
    });
    const list: tab.Rect = .{ .row = rect.row + 1, .col = rect.col, .width = rect.width, .height = rect.height -| 1 };
    if (list.height == 0) return; // the heading took the only row
    const v = scroll_list.clamp(s.chrome.view, nf, list.height);

    var fi: usize = 0;
    for (s.items, 0..) |p, i| {
        if (!matches(p.name, filter)) continue;
        defer fi += 1;
        if (fi < v.offset) continue;
        const screen = fi - v.offset;
        if (screen >= list.height) break;
        f.moveTo(list.row + @as(u16, @intCast(screen)), list.col);
        // The checkbox carries its own colour; a pinned row is held back so it
        // shows the blocked box, never a check.
        const is_checked = i < s.checked.len and s.checked[i];
        tab.putCheckbox(f, if (p.pinned) .blocked else if (is_checked) tab.Check.on else .off);
        const selected = fi == v.selected;
        // The cursor row wins over the pinned dim so the selection stays legible;
        // under a theme the accent backgrounds it via reverse-video.
        if (selected) {
            f.put(color.selectionAccent());
            f.put(color.Style.reverse.code());
        } else if (p.pinned) f.put(color.roleCode(.muted));
        var rb: [256]u8 = undefined;
        f.putContent(scroll_list.truncate(formatRow(&rb, p), list.width -| 4)); // 4 cols on the checkbox
        if (selected or p.pinned) f.put(color.Style.reset.code());
    }
}

/// One list row after the checkbox: the name, the current and latest versions,
/// the source type, and a pinned tag. The CURRENT/AVAILABLE headings name the two
/// version columns, so they sit side by side with no arrow between them. ASCII
/// columns, grapheme-naive like the rest.
fn formatRow(buf: []u8, p: Row) []const u8 {
    var len: usize = 0;
    appendPad(buf, &len, p.name, 22);
    append(buf, &len, " ");
    appendPad(buf, &len, p.installed, 12);
    append(buf, &len, " ");
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

// ─── impure zone ───────────────────────────────────────────────────────
// The effect half of the tab, reunited beside its pure producer (`step` records
// the `upgrade` request; the code below drains it). Every decl here takes its I/O
// ports explicitly through the shared `ctx.Ctx` — never a global — so the
// pure/impure line is the function signature.

// ─── effect producers ───────────────────────────────────────────────────
// The tab names effects as `Cmd` values; the pump performs them and folds the
// result back through `update`. No I/O and no runner import here.

/// Banner op strings for a recoverable fault, parity with the pre-reify error
/// names so the dashboard shows the same banners it always has.
const upgrade_fail_op = "upgrade failed";
const refresh_fail_op = "outdated refresh failed";

/// One upgraded row, identified by `(name, kind)` so a formula and a cask that
/// share a name (e.g. `docker`) are never confused for one another.
const UpgradedRef = struct { name: []const u8, kind: Kind };

/// Count checked, non-pinned rows of one kind — a single upgrade pass's size.
fn countKind(s: *const State, kind: Kind) usize {
    var n: usize = 0;
    for (s.items, 0..) |row, i| {
        if (i < s.checked.len and s.checked[i] and !row.pinned and row.kind == kind) n += 1;
    }
    return n;
}

/// Collect one kind's checked, non-pinned rows into `out` (item order); returns
/// the count written. `out` must be sized to `countKind`.
fn collectKind(s: *const State, kind: Kind, out: []UpgradedRef) usize {
    var n: usize = 0;
    for (s.items, 0..) |row, i| {
        if (i < s.checked.len and s.checked[i] and !row.pinned and row.kind == kind and n < out.len) {
            out[n] = .{ .name = row.name, .kind = kind };
            n += 1;
        }
    }
    return n;
}

fn kindFlag(kind: Kind) []const u8 {
    return switch (kind) {
        .formula => "--formula",
        .cask => "--cask",
    };
}

/// Build `[mt, upgrade, <flag>, names...]` for a single-kind ref slice, or null
/// when the slice is empty. `flag` is `--formula` / `--cask` so the kind the
/// user picked is the kind upgraded (`mt upgrade <name>` is formula-first).
fn kindUpgradeArgv(
    allocator: std.mem.Allocator,
    mt_path: []const u8,
    refs: []const UpgradedRef,
    flag: []const u8,
) std.mem.Allocator.Error!?[]const []const u8 {
    if (refs.len == 0) return null;
    const rest = try allocator.alloc([]const u8, 2 + refs.len);
    defer allocator.free(rest);
    rest[0] = "upgrade";
    rest[1] = flag;
    for (refs, rest[2..]) |r, *slot| slot.* = r.name;
    return try cmd.inlineArgv(allocator, mt_path, rest);
}

/// Start the first upgrade pass for a non-empty selection: formula-first, since
/// `mt upgrade <name>` resolves formula-first so a checked cask must go through a
/// `--cask` pass, never folded into a formula one. Records the in-flight kind so
/// `update` knows which rows a finished pass covered.
fn upgradeCmd(allocator: std.mem.Allocator, mt_path: []const u8, s: *State) cmd.Cmd {
    if (selectedCount(s) == 0) return .none; // empty selection: no-op
    return startPass(allocator, mt_path, s, .formula) orelse
        startPass(allocator, mt_path, s, .cask) orelse .none;
}

/// Build one kind's upgrade `run_mutation` and mark it pending, or `null` when no
/// row of that kind is checked. An argv-build OOM drops the effect, not the TUI.
fn startPass(allocator: std.mem.Allocator, mt_path: []const u8, s: *State, kind: Kind) ?cmd.Cmd {
    const n = countKind(s, kind);
    if (n == 0) return null;
    const refs = allocator.alloc(UpgradedRef, n) catch return null;
    defer allocator.free(refs);
    _ = collectKind(s, kind, refs);
    const argv = (kindUpgradeArgv(allocator, mt_path, refs, kindFlag(kind)) catch return null) orelse return null;
    s.pending_kind = kind;
    return .{ .run_mutation = .{ .argv = argv, .tag = .outdated, .fail_op = upgrade_fail_op } };
}

/// Fold a completed effect back into the model. A finished upgrade pass drops its
/// upgraded rows on success (preserving other rows' checked state) or surfaces the
/// recoverable banner on failure, then chains the cask pass after the formula one.
/// A delivered read swaps in fresh rows + an all-clear checkbox set.
pub fn update(allocator: std.mem.Allocator, mt_path: []const u8, s: *State, storage: *Storage, shared: *ctx.SharedModel, msg: cmd.Msg) cmd.Cmd {
    switch (msg) {
        .mutated => |code| return foldUpgradePass(allocator, mt_path, s, storage, shared, code),
        .loaded => |parsed| {
            // `update` owns the delivered parse: store it, or free it if the
            // checkbox-buffer alloc fails, and keep the last-good rows behind a banner.
            applyOutdatedParse(allocator, s, storage, shared, parsed.outdated) catch |err| {
                parsed.outdated.deinit();
                shared.banner.set(refresh_fail_op, @errorName(err));
            };
            return .none;
        },
        .cleared => {
            clearRows(allocator, s, storage, shared); // exit-0 empty read: nothing outdated
            return .none;
        },
        .failed => return .none, // the pump set the banner; keep the last-good rows
    }
}

/// Fold one finished upgrade pass: drop its rows on success (exit 0), else banner;
/// then advance formula → cask so both kinds upgrade under the right flag.
fn foldUpgradePass(allocator: std.mem.Allocator, mt_path: []const u8, s: *State, storage: *Storage, shared: *ctx.SharedModel, code: u8) cmd.Cmd {
    const kind = s.pending_kind orelse return .none; // defensive: no pass in flight
    if (code == 0) {
        // A checkbox-buffer realloc OOM keeps the rows behind a banner, never traps.
        dropCheckedKind(allocator, s, storage, shared, kind) catch |err|
            shared.banner.set(upgrade_fail_op, @errorName(err));
        shared.markStaleAfter(.outdated); // Installed sizes/versions changed too
    } else {
        var dbuf: [96]u8 = undefined;
        shared.banner.set(upgrade_fail_op, failDetail(&dbuf, s, kind, code));
    }
    // Passes are independent: run the cask pass after the formula one regardless of
    // the formula outcome, so a failed formula pass still lets checked casks upgrade.
    if (kind == .formula) {
        if (startPass(allocator, mt_path, s, .cask)) |next| return next;
    }
    s.pending_kind = null;
    return .none;
}

/// The exit code `mt upgrade` returns when it refused a cask because the app is
/// still running. Mirrors `main.zig`'s `AppRunning` exit mapping — the mt→TUI
/// process contract, like the doctor severity cap the inline runner already knows.
const cask_app_running_exit: u8 = 3;

/// Banner detail for a failed upgrade pass: on the cask app-running refusal name
/// the live app (or "a selected app" when the pass carried several) so the banner
/// says *why*, not an opaque "ChildFailed". `buf` backs the single-cask name.
fn failDetail(buf: []u8, s: *const State, kind: Kind, code: u8) []const u8 {
    if (code != cask_app_running_exit) return "ChildFailed";
    if (countKind(s, kind) == 1) {
        var one: [1]UpgradedRef = undefined;
        _ = collectKind(s, kind, &one);
        return std.fmt.bufPrint(buf, "{s} is running", .{one[0].name}) catch "an app is running";
    }
    return "a selected app is running";
}

/// Drop the checked rows of one kind — the just-upgraded set — preserving the
/// kept rows' checked state. Collects the refs for `dropUpgradedRows`.
fn dropCheckedKind(allocator: std.mem.Allocator, s: *State, storage: *Storage, shared: *ctx.SharedModel, kind: Kind) std.mem.Allocator.Error!void {
    const n = countKind(s, kind);
    if (n == 0) return;
    const refs = try allocator.alloc(UpgradedRef, n);
    defer allocator.free(refs);
    _ = collectKind(s, kind, refs);
    try dropUpgradedRows(allocator, s, storage, shared, refs);
}

/// True when `row` is one of the upgraded rows (linear scan — a batch is small).
/// Matches on `(name, kind)`: `mt upgrade <name>` resolves formula-first, so a
/// same-named cask is left outdated and must not be dropped with the formula.
fn rowUpgraded(upgraded: []const UpgradedRef, row: Row) bool {
    for (upgraded) |u| {
        if (u.kind == row.kind and std.mem.eql(u8, u.name, row.name)) return true;
    }
    return false;
}

/// Drop the just-upgraded rows from the Outdated tab in place: the post-upgrade
/// outdated set is the pre-upgrade set minus the upgraded tokens, so a second
/// `mt outdated` walk is unnecessary. The parsed storage is kept alive (rows
/// borrow its arena) and `items` is re-pointed at the survivors within that
/// arena; only the checkbox buffer is reallocated, preserving each kept row's
/// checked state so a partial-selection upgrade survives.
fn dropUpgradedRows(
    allocator: std.mem.Allocator,
    st: *State,
    storage: *Storage,
    shared: *ctx.SharedModel,
    upgraded: []const UpgradedRef,
) std.mem.Allocator.Error!void {
    if (storage.outdated == null) return; // nothing loaded → nothing to drop
    const parsed = &storage.outdated.?;
    const old_items = parsed.items;
    const old_checked = storage.checked;

    var keep: usize = 0;
    for (old_items) |row| {
        if (!rowUpgraded(upgraded, row)) keep += 1;
    }

    // Survivors live in the parse arena alongside the strings they borrow, so
    // they free together on the next full reload. The checkbox buffer is shell-
    // owned, so it is reallocated and the old one freed.
    const arena = parsed.doc.arena.allocator();
    const new_items = try arena.alloc(outdated_json.OutdatedRow, keep);
    const new_checked = try allocator.alloc(bool, keep);
    errdefer allocator.free(new_checked);

    var j: usize = 0;
    for (old_items, 0..) |row, i| {
        if (rowUpgraded(upgraded, row)) continue;
        new_items[j] = row;
        new_checked[j] = i < old_checked.len and old_checked[i];
        j += 1;
    }

    if (old_checked.len != 0) allocator.free(old_checked);
    parsed.items = new_items;
    storage.checked = new_checked;
    st.items = new_items;
    st.checked = new_checked;
    shared.outdated_count = new_items.len;
}

/// Clear to the known-zero state, freeing the parse and the shell-owned checkbox
/// buffer. The `.cleared` fold — an exit-0 empty read, background or keypress.
fn clearRows(allocator: std.mem.Allocator, st: *State, storage: *Storage, shared: *ctx.SharedModel) void {
    if (storage.outdated) |old| old.deinit();
    if (storage.checked.len != 0) allocator.free(storage.checked);
    storage.outdated = null;
    storage.checked = &.{};
    st.items = &.{};
    st.checked = &.{};
    shared.outdated_count = 0; // nothing outdated is a known zero, not "unknown"
}

/// Repoint the Outdated tab + header count at a fresh parse, allocating a new
/// all-clear checkbox buffer (shell-owned) and freeing the previous parse/buffer.
/// An upgrade removes the upgraded rows, so carrying the old selection forward
/// would point at the wrong packages — the buffer starts clear. The `.loaded`
/// fold, from a background drain or a keypress reload alike. The swap runs only
/// after `checked` is allocated, so a fold OOM leaves `parsed` for `update` to free
/// behind the banner and never half-applies.
fn applyOutdatedParse(allocator: std.mem.Allocator, st: *State, storage: *Storage, shared: *ctx.SharedModel, parsed: outdated_json.Parsed) std.mem.Allocator.Error!void {
    const checked = try allocator.alloc(bool, parsed.items.len);
    @memset(checked, false);

    if (storage.outdated) |old| old.deinit();
    if (storage.checked.len != 0) allocator.free(storage.checked);
    storage.outdated = parsed;
    storage.checked = checked;
    st.items = parsed.items;
    st.checked = checked;
    shared.outdated_count = parsed.items.len;
}

// ─── tests ───────────────────────────────────────────────────────────

const testing = std.testing;

fn ch(c: u8) tab.Key {
    return .{ .char = .{ .bytes = .{ c, 0, 0, 0 }, .len = 1 } };
}

/// Fold a `--json` document into the tab exactly as the interpreter does: parse,
/// then deliver it as a `.loaded` `Msg` through `update`. The reified stand-in for
/// the old `applyOutdatedBytes`, so a test can seed rows the way the real drain does.
fn loadOutdated(st: *State, storage: *Storage, shared: *ctx.SharedModel, json: []const u8) !void {
    const parsed = try outdated_json.parse(testing.allocator, json);
    _ = update(testing.allocator, "/bin/mt", st, storage, shared, .{ .loaded = .{ .outdated = parsed } });
}

/// Drive `step` with a throwaway storage and a fixed mt path. Outdated's `step`
/// ignores storage, so this keeps the pure-behaviour tests readable.
fn stepKey(s: *State, key: tab.Key) cmd.Cmd {
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    return step(testing.allocator, "/opt/malt/bin/mt", s, &storage, key);
}

// Index 1 (curl) is pinned: shown but held back from any bulk upgrade.
const sample = [_]Row{
    .{ .name = "wget", .installed = "1.24.5", .latest = "1.25.0", .kind = .formula, .pinned = false, .tap = "" },
    .{ .name = "curl", .installed = "8.1.0", .latest = "8.2.0", .kind = .formula, .pinned = true, .tap = "" },
    .{ .name = "firefox", .installed = "120.0", .latest = "121.0", .kind = .cask, .pinned = false, .tap = "user/repo" },
    .{ .name = "ffmpeg", .installed = "8.0", .latest = "8.1", .kind = .formula, .pinned = false, .tap = "" },
};

test "End jumps to the last filtered row" {
    var s: State = .{ .items = &sample };
    _ = stepKey(&s, .end);
    try testing.expectEqual(@as(usize, 3), s.chrome.view.selected);

    s.chrome.filter.push("f"); // firefox, ffmpeg
    _ = stepKey(&s, .end);
    try testing.expectEqual(@as(usize, 1), s.chrome.view.selected);
}

test "matches is a case-insensitive substring; empty filter matches all" {
    try testing.expect(matches("firefox", ""));
    try testing.expect(matches("FireFox", "fox"));
    try testing.expect(!matches("wget", "zzz"));
}

test "space toggles the cursor row's checkbox" {
    var checked = [_]bool{false} ** 4;
    var s: State = .{ .items = &sample, .checked = &checked };
    s.chrome.view.selected = 0; // wget
    _ = stepKey(&s, .space);
    try testing.expect(checked[0]);
    _ = stepKey(&s, .space); // toggles back off
    try testing.expect(!checked[0]);
}

test "space on a pinned cursor row never checks it" {
    var checked = [_]bool{false} ** 4;
    var s: State = .{ .items = &sample, .checked = &checked };
    s.chrome.view.selected = 1; // curl (pinned)
    _ = stepKey(&s, .space);
    try testing.expect(!checked[1]);
}

test "a checks every non-pinned row and leaves pinned rows unchecked" {
    var checked = [_]bool{false} ** 4;
    var s: State = .{ .items = &sample, .checked = &checked };
    _ = stepKey(&s, ch('a'));
    try testing.expect(checked[0]); // wget
    try testing.expect(!checked[1]); // curl is pinned — excluded
    try testing.expect(checked[2]); // firefox
    try testing.expect(checked[3]); // ffmpeg
}

test "n clears every checkbox" {
    var checked = [_]bool{ true, false, true, true };
    var s: State = .{ .items = &sample, .checked = &checked };
    _ = stepKey(&s, ch('n'));
    for (checked) |b| try testing.expect(!b);
}

test "u returns the upgrade mutation only when something is selected" {
    var checked = [_]bool{false} ** 4;
    var s: State = .{ .items = &sample, .checked = &checked };
    try testing.expect(stepKey(&s, ch('u')) == .none); // empty selection → no-op
    checked[0] = true; // wget (formula)
    const eff = stepKey(&s, ch('u'));
    defer testing.allocator.free(eff.run_mutation.argv);
    try testing.expect(eff == .run_mutation);
    try testing.expectEqual(cmd.MsgTag.outdated, eff.run_mutation.tag);
    try testing.expectEqual(Kind.formula, s.pending_kind.?); // formula pass in flight
    const argv = eff.run_mutation.argv;
    try testing.expectEqualStrings("upgrade", argv[1]);
    try testing.expectEqualStrings("--formula", argv[2]);
    try testing.expectEqualStrings("wget", argv[3]);
}

test "Enter returns the upgrade mutation like u" {
    var checked = [_]bool{ true, false, false, false };
    var s: State = .{ .items = &sample, .checked = &checked };
    const eff = stepKey(&s, .enter);
    defer testing.allocator.free(eff.run_mutation.argv);
    try testing.expect(eff == .run_mutation);
}

test "a cask-only selection starts with the cask pass" {
    var checked = [_]bool{ false, false, true, false }; // firefox (cask)
    var s: State = .{ .items = &sample, .checked = &checked };
    const eff = stepKey(&s, ch('u'));
    defer testing.allocator.free(eff.run_mutation.argv);
    try testing.expectEqual(Kind.cask, s.pending_kind.?);
    try testing.expectEqualStrings("--cask", eff.run_mutation.argv[2]);
    try testing.expectEqualStrings("firefox", eff.run_mutation.argv[3]);
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

test "render heads the columns in bold, indented past the checkbox" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var checked = [_]bool{false} ** 4;
    const s: State = .{ .items = &sample, .checked = &checked };
    render(&s, &f, .{ .row = 3, .col = 1, .width = 80, .height = 12 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, color.Style.bold.code()) != null);
    // The 4-col checkbox indent plus exact padding aligns the labels over values.
    try testing.expect(std.mem.indexOf(u8, out, "    NAME" ++ " " ** 19 ++ "CURRENT" ++ " " ** 6 ++ "AVAILABLE" ++ " " ** 4 ++ "KIND") != null);
    try testing.expect(std.mem.indexOf(u8, out, "wget") != null); // the list still renders below
}

test "render lists checkboxes with the current and latest versions and the type column" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var checked = [_]bool{ true, false, false, false };
    const s: State = .{ .items = &sample, .checked = &checked };
    render(&s, &f, .{ .row = 2, .col = 1, .width = 80, .height = 12 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "✓") != null); // wget checked
    try testing.expect(std.mem.indexOf(u8, out, "[ ]") != null); // an unchecked box
    try testing.expect(std.mem.indexOf(u8, out, "→") == null); // the arrow is gone; the headings name the columns
    try testing.expect(std.mem.indexOf(u8, out, "1.24.5") != null); // current version
    try testing.expect(std.mem.indexOf(u8, out, "1.25.0") != null); // latest version
    try testing.expect(std.mem.indexOf(u8, out, "cask") != null); // type column
}

test "render greys a pinned row, shows the blocked box, and marks it pinned" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var checked = [_]bool{false} ** 4;
    const s: State = .{ .items = &sample, .checked = &checked };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "pinned") != null); // curl marked
    try testing.expect(std.mem.indexOf(u8, out, "[-]") != null); // a pinned row gets the blocked box, never a check
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
    try testing.expect(std.mem.indexOf(u8, f.slice(), color.Style.reverse.code()) != null);
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
    _ = stepKey(&s, ch('a')); // setAll must stop at the slice end
    _ = stepKey(&s, .space); // toggle the cursor row only if in range
    _ = selectedCount(&s);
    var out: [4][]const u8 = undefined;
    _ = selectedNames(&s, &out);
}

test "failDetail names the live app on the cask refusal code, else stays generic" {
    var buf: [96]u8 = undefined;
    const one = [_]Row{.{ .name = "flux-markdown", .installed = "1", .latest = "2", .kind = .cask, .pinned = false, .tap = "" }};
    var checked1 = [_]bool{true};
    const s1: State = .{ .items = &one, .checked = &checked1 };
    try testing.expectEqualStrings("flux-markdown is running", failDetail(&buf, &s1, .cask, cask_app_running_exit));

    const two = [_]Row{
        .{ .name = "a", .installed = "1", .latest = "2", .kind = .cask, .pinned = false, .tap = "" },
        .{ .name = "b", .installed = "1", .latest = "2", .kind = .cask, .pinned = false, .tap = "" },
    };
    var checked2 = [_]bool{ true, true };
    const s2: State = .{ .items = &two, .checked = &checked2 };
    try testing.expectEqualStrings("a selected app is running", failDetail(&buf, &s2, .cask, cask_app_running_exit));

    // Any other non-zero exit is the generic child failure, unnamed.
    try testing.expectEqualStrings("ChildFailed", failDetail(&buf, &s1, .cask, 1));
    // A name longer than the buffer falls back rather than truncating mid-name.
    var tiny: [4]u8 = undefined;
    try testing.expectEqualStrings("an app is running", failDetail(&tiny, &s1, .cask, cask_app_running_exit));
}

test "countKind and collectKind cover the checked, non-pinned rows of a kind" {
    const items = [_]Row{
        .{ .name = "firefox", .installed = "1", .latest = "2", .kind = .cask, .pinned = false, .tap = "" },
        .{ .name = "wget", .installed = "1", .latest = "2", .kind = .formula, .pinned = false, .tap = "" },
        .{ .name = "held", .installed = "1", .latest = "2", .kind = .formula, .pinned = true, .tap = "" },
    };
    var checked = [_]bool{ true, true, true }; // held is pinned → excluded
    const st: State = .{ .items = &items, .checked = &checked };
    try testing.expectEqual(@as(usize, 1), countKind(&st, .formula)); // wget (held pinned)
    try testing.expectEqual(@as(usize, 1), countKind(&st, .cask)); // firefox
    var out: [1]UpgradedRef = undefined;
    try testing.expectEqual(@as(usize, 1), collectKind(&st, .formula, &out));
    try testing.expectEqualStrings("wget", out[0].name);
    try testing.expectEqual(Kind.formula, out[0].kind);
}

test "kindUpgradeArgv builds `mt upgrade <flag> <names>`, null for no refs" {
    const refs = [_]UpgradedRef{ .{ .name = "firefox", .kind = .cask }, .{ .name = "vlc", .kind = .cask } };
    const maybe = try kindUpgradeArgv(testing.allocator, "/bin/mt", &refs, "--cask");
    try testing.expect(maybe != null);
    const argv = maybe.?;
    defer testing.allocator.free(argv);
    try testing.expectEqual(@as(usize, 5), argv.len);
    try testing.expectEqualStrings("upgrade", argv[1]);
    try testing.expectEqualStrings("--cask", argv[2]);
    try testing.expectEqualStrings("firefox", argv[3]);
    try testing.expectEqualStrings("vlc", argv[4]);
    try testing.expect((try kindUpgradeArgv(testing.allocator, "/bin/mt", &.{}, "--cask")) == null);
}

test "an upgrade runs a --formula pass, then chains a --cask pass, dropping each" {
    var st: State = .{};
    var storage: Storage = .{};
    var shared: ctx.SharedModel = .{};
    defer storage.deinit(testing.allocator);
    const json =
        \\{"outdated":[
        \\{"name":"wget","installed":"1","latest":"2","type":"formula","pinned":false},
        \\{"name":"firefox","installed":"1","latest":"2","type":"cask","pinned":false}
        \\]}
    ;
    try loadOutdated(&st, &storage, &shared, json);
    storage.checked[0] = true; // wget (formula)
    storage.checked[1] = true; // firefox (cask)
    st.checked = storage.checked;

    // step → formula pass in flight.
    const first = step(testing.allocator, "/bin/mt", &st, &storage, ch('u'));
    testing.allocator.free(first.run_mutation.argv);
    try testing.expectEqual(Kind.formula, st.pending_kind.?);

    // A successful formula pass drops wget and returns the cask pass.
    const second = update(testing.allocator, "/bin/mt", &st, &storage, &shared, .{ .mutated = 0 });
    defer testing.allocator.free(second.run_mutation.argv);
    try testing.expect(second == .run_mutation);
    try testing.expectEqualStrings("--cask", second.run_mutation.argv[2]);
    try testing.expectEqual(Kind.cask, st.pending_kind.?);
    try testing.expectEqual(@as(usize, 1), st.items.len); // wget dropped
    try testing.expectEqualStrings("firefox", st.items[0].name);

    // A successful cask pass drops firefox and ends the chain.
    const done = update(testing.allocator, "/bin/mt", &st, &storage, &shared, .{ .mutated = 0 });
    try testing.expect(done == .none);
    try testing.expectEqual(@as(usize, 0), st.items.len);
    try testing.expect(st.pending_kind == null);
}

test "a failed formula pass keeps its rows and still chains the cask pass" {
    var st: State = .{};
    var storage: Storage = .{};
    var shared: ctx.SharedModel = .{};
    defer storage.deinit(testing.allocator);
    const json =
        \\{"outdated":[
        \\{"name":"wget","installed":"1","latest":"2","type":"formula","pinned":false},
        \\{"name":"firefox","installed":"1","latest":"2","type":"cask","pinned":false}
        \\]}
    ;
    try loadOutdated(&st, &storage, &shared, json);
    storage.checked[0] = true;
    storage.checked[1] = true;
    st.checked = storage.checked;
    st.pending_kind = .formula; // a formula pass was in flight

    // A non-zero formula pass banners and keeps wget, but still returns the cask pass.
    const next = update(testing.allocator, "/bin/mt", &st, &storage, &shared, .{ .mutated = 1 });
    defer testing.allocator.free(next.run_mutation.argv);
    try testing.expect(next == .run_mutation);
    try testing.expectEqual(Kind.cask, st.pending_kind.?);
    try testing.expectEqual(@as(usize, 2), st.items.len); // nothing dropped
    try testing.expect(std.mem.startsWith(u8, shared.banner.slice(), "upgrade failed"));
}

test "dropUpgradedRows removes upgraded rows in place and preserves kept checked state" {
    var st: State = .{};
    var storage: Storage = .{};
    var shared: ctx.SharedModel = .{};
    defer storage.deinit(testing.allocator);
    const json =
        \\{"outdated":[
        \\{"name":"a","installed":"1","latest":"2","type":"formula","pinned":false},
        \\{"name":"b","installed":"1","latest":"2","type":"formula","pinned":false},
        \\{"name":"c","installed":"1","latest":"2","type":"formula","pinned":false}
        \\]}
    ;
    try loadOutdated(&st, &storage, &shared, json);
    // Check a and c (b is the one being upgraded); the kept rows must stay checked.
    storage.checked[0] = true;
    storage.checked[2] = true;

    try dropUpgradedRows(testing.allocator, &st, &storage, &shared, &.{.{ .name = "b", .kind = .formula }});

    try testing.expectEqual(@as(usize, 2), storage.outdated.?.items.len);
    try testing.expectEqualStrings("a", storage.outdated.?.items[0].name);
    try testing.expectEqualStrings("c", storage.outdated.?.items[1].name);
    try testing.expectEqual(@as(?usize, 2), shared.outdated_count);
    try testing.expectEqual(@as(usize, 2), st.items.len);
    // a and c stay checked in the rebuilt lockstep buffer.
    try testing.expect(st.checked[0]);
    try testing.expect(st.checked[1]);
}

test "a reloaded outdated read reallocs the checkbox buffer to the new row count" {
    var st: State = .{};
    var storage: Storage = .{};
    var shared: ctx.SharedModel = .{};
    defer storage.deinit(testing.allocator);
    // First parse (two rows). Its arena must be freed when the second lands, or the
    // test allocator trips — this pins that the arena lifetime moved into the tab's
    // own Storage, so a re-load frees the prior parse rather than leaking it.
    try loadOutdated(&st, &storage, &shared, "{\"outdated\":[{\"name\":\"a\",\"installed\":\"1\",\"latest\":\"2\",\"type\":\"formula\",\"pinned\":false},{\"name\":\"b\",\"installed\":\"1\",\"latest\":\"2\",\"type\":\"formula\",\"pinned\":false}]}");
    storage.checked[0] = true; // a stale selection the swap must not carry forward
    try testing.expectEqual(@as(usize, 2), storage.outdated.?.items.len);
    try testing.expectEqual(@as(usize, 2), storage.checked.len);
    // Second parse (one row) swaps in a fresh arena + an all-clear checkbox buffer.
    try loadOutdated(&st, &storage, &shared, "{\"outdated\":[{\"name\":\"z\",\"installed\":\"1\",\"latest\":\"9\",\"type\":\"cask\",\"pinned\":false}]}");
    // The survivor borrows the live arena: the name resolves and the count follows.
    try testing.expectEqual(@as(usize, 1), storage.outdated.?.items.len);
    try testing.expectEqual(@as(usize, 1), storage.checked.len); // buffer resized to the new row count
    try testing.expectEqualStrings("z", storage.outdated.?.items[0].name);
    try testing.expectEqual(@as(?usize, 1), shared.outdated_count);
    try testing.expect(!storage.checked[0]); // fresh buffer, all clear
}

test "dropUpgradedRows on an unloaded store is a no-op" {
    var st: State = .{};
    var storage: Storage = .{};
    var shared: ctx.SharedModel = .{};
    defer storage.deinit(testing.allocator);
    try dropUpgradedRows(testing.allocator, &st, &storage, &shared, &.{.{ .name = "anything", .kind = .formula }});
    try testing.expect(storage.outdated == null);
}

test "dropUpgradedRows drops only the upgraded kind when a formula and cask share a name" {
    var st: State = .{};
    var storage: Storage = .{};
    var shared: ctx.SharedModel = .{};
    defer storage.deinit(testing.allocator);
    const json =
        \\{"outdated":[
        \\{"name":"docker","installed":"1","latest":"2","type":"formula","pinned":false},
        \\{"name":"docker","installed":"1","latest":"2","type":"cask","pinned":false}
        \\]}
    ;
    try loadOutdated(&st, &storage, &shared, json);
    // Only the formula docker was upgraded; the same-named cask must remain.
    try dropUpgradedRows(testing.allocator, &st, &storage, &shared, &.{.{ .name = "docker", .kind = .formula }});
    try testing.expectEqual(@as(usize, 1), storage.outdated.?.items.len);
    try testing.expectEqual(outdated_json.Kind.cask, storage.outdated.?.items[0].kind);
}

test "dropUpgradedRows survives two sequential drops (the formula then cask passes)" {
    var st: State = .{};
    var storage: Storage = .{};
    var shared: ctx.SharedModel = .{};
    defer storage.deinit(testing.allocator);
    const json =
        \\{"outdated":[
        \\{"name":"wget","installed":"1","latest":"2","type":"formula","pinned":false},
        \\{"name":"firefox","installed":"1","latest":"2","type":"cask","pinned":false}
        \\]}
    ;
    try loadOutdated(&st, &storage, &shared, json);

    // Formula pass drops wget; the cask ref (still borrowing the live parse
    // arena) must survive the first drop's store mutation and rebuilt buffer.
    try dropUpgradedRows(testing.allocator, &st, &storage, &shared, &.{.{ .name = "wget", .kind = .formula }});
    try testing.expectEqual(@as(usize, 1), storage.outdated.?.items.len);
    try testing.expectEqual(outdated_json.Kind.cask, storage.outdated.?.items[0].kind);

    // Cask pass drops firefox → empty, no leak / use-after-free.
    try dropUpgradedRows(testing.allocator, &st, &storage, &shared, &.{.{ .name = "firefox", .kind = .cask }});
    try testing.expectEqual(@as(usize, 0), storage.outdated.?.items.len);
    try testing.expectEqual(@as(?usize, 0), shared.outdated_count);
}

test "dropUpgradedRows keeps every row when no upgraded ref matches" {
    var st: State = .{};
    var storage: Storage = .{};
    var shared: ctx.SharedModel = .{};
    defer storage.deinit(testing.allocator);
    const json =
        \\{"outdated":[
        \\{"name":"a","installed":"1","latest":"2","type":"formula","pinned":false},
        \\{"name":"b","installed":"1","latest":"2","type":"formula","pinned":false}
        \\]}
    ;
    try loadOutdated(&st, &storage, &shared, json);
    try dropUpgradedRows(testing.allocator, &st, &storage, &shared, &.{.{ .name = "z", .kind = .formula }});
    try testing.expectEqual(@as(usize, 2), storage.outdated.?.items.len);
}

test "dropUpgradedRows clears the list when every row was upgraded" {
    var st: State = .{};
    var storage: Storage = .{};
    var shared: ctx.SharedModel = .{};
    defer storage.deinit(testing.allocator);
    const json =
        \\{"outdated":[
        \\{"name":"a","installed":"1","latest":"2","type":"formula","pinned":false},
        \\{"name":"b","installed":"1","latest":"2","type":"formula","pinned":false}
        \\]}
    ;
    try loadOutdated(&st, &storage, &shared, json);
    try dropUpgradedRows(testing.allocator, &st, &storage, &shared, &.{ .{ .name = "a", .kind = .formula }, .{ .name = "b", .kind = .formula } });
    try testing.expectEqual(@as(usize, 0), storage.outdated.?.items.len);
    try testing.expectEqual(@as(?usize, 0), shared.outdated_count);
}

test "conforms to the tab contract" {
    comptime tab.verify(@This());
}

test "Storage.deinit frees the parsed rows and the checkbox buffer" {
    const allocator = std.testing.allocator;
    var storage: Storage = .{};
    storage.outdated = try outdated_json.parse(allocator, "{\"outdated\":[{\"name\":\"wget\",\"installed\":\"1\",\"latest\":\"2\",\"type\":\"formula\",\"pinned\":false}]}");
    storage.checked = try allocator.alloc(bool, storage.outdated.?.items.len);
    // A no-op deinit leaks both the parse arena and the buffer; `testing.allocator`
    // trips at scope end, pinning that deinit frees every owned resource.
    storage.deinit(allocator);
}
