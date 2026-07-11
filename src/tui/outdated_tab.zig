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
const ctx = @import("ctx.zig");
const tab = @import("tab.zig");
const scroll_list = @import("scroll_list.zig");
const outdated_json = @import("json/outdated.zig");
const spawn = @import("spawn.zig");
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
pub const fetch_spec: ?tab.FetchSpec = .{ .verb = &.{"outdated"}, .max_ok_exit = 0, .refresh_op = "outdated refresh failed" };

/// Whether the pending request will spawn a DB-mutating child (`mt upgrade`). The
/// shell folds this over every tab before opening the DB so a live background
/// audit is drained first — the WAL single-writer invariant.
pub fn mutates(s: *const State) bool {
    return s.request == .upgrade;
}

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

/// Pure transition: toggle the cursor row, bulk select/clear, or request the
/// upgrade. A pinned cursor row cannot be toggled.
pub fn step(s: *State, key: tab.Key) void {
    switch (key) {
        .space => toggleSelected(s),
        .enter => requestUpgrade(s),
        // Only the tab knows its filtered row count, so the shell defers End here.
        .end => s.chrome.view.selected = filteredCount(s.items, s.chrome.filter.slice()) -| 1,
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

/// The effect chain's error set, composed from the source sets so it tracks them
/// automatically. A subset of the shell's `RunError`, which classifies each fault
/// recoverable-vs-fatal; naming it here keeps the public `service` explicit.
pub const Error = std.mem.Allocator.Error || spawn.ReadError || spawn.InlineError || outdated_json.Error;

/// Perform any upgrade effect the pure `step` requested, then clear it — the
/// consumer half of the `request` seam. The shell dispatches this only for the
/// active tab; the lazy (re)load on entry / after staleness stays loop machinery.
pub fn service(s: *State, storage: *Storage, c: *ctx.Ctx) Error!void {
    const req = s.request;
    s.request = .none;
    switch (req) {
        .none => {},
        .upgrade => try doUpgrade(s, storage, c),
    }
}

/// One upgraded row, identified by `(name, kind)` so a formula and a cask that
/// share a name (e.g. `docker`) are never confused for one another.
const UpgradedRef = struct { name: []const u8, kind: outdated_json.Kind };

/// Collect the checked, non-pinned rows into `out` as `(name, kind)` refs,
/// formula rows first then cask rows; returns the formula count (the split
/// index). `out` must be sized to `selectedCount`. Partitioning by kind lets
/// `doUpgrade` issue one `--formula` pass and one `--cask` pass.
fn collectUpgraded(s: *const State, out: []UpgradedRef) usize {
    // The two item-order passes below cover exactly `{formula, cask}`; a new
    // Kind variant would leave its rows uncollected. Lock it at compile time.
    comptime std.debug.assert(@typeInfo(outdated_json.Kind).@"enum".fields.len == 2);
    var n: usize = 0;
    var split: usize = 0;
    // Two item-order passes so each kind's names stay in display order and the
    // formula refs land in `out[0..split]`, casks in `out[split..]`.
    for ([_]outdated_json.Kind{ .formula, .cask }) |kind| {
        for (s.items, 0..) |row, i| {
            // Same rule as `selectedNames`: checked, non-pinned, this kind.
            if (i < s.checked.len and s.checked[i] and !row.pinned and row.kind == kind and n < out.len) {
                out[n] = .{ .name = row.name, .kind = row.kind };
                n += 1;
            }
        }
        if (kind == .formula) split = n;
    }
    return split;
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
    return try spawn.inlineArgv(allocator, mt_path, rest);
}

/// The exit code `mt upgrade` returns when it refused a cask because the app is
/// still running. Mirrors `main.zig`'s `AppRunning` exit mapping — the mt→TUI
/// process contract, like the doctor severity cap the inline runner already knows.
const cask_app_running_exit: u8 = 3;

/// Footer detail for a failed cask upgrade pass: on the app-running refusal name
/// the live app (or "a selected app" when the pass carried several) so the footer
/// says *why*, not an opaque "ChildFailed". `buf` backs the single-cask name;
/// `Banner.set` copies the result, so a stack buffer is enough.
fn upgradeFailDetail(buf: []u8, code: u8, refs: []const UpgradedRef) []const u8 {
    if (code != cask_app_running_exit) return "ChildFailed";
    if (refs.len == 1) return std.fmt.bufPrint(buf, "{s} is running", .{refs[0].name}) catch "an app is running";
    return "a selected app is running";
}

/// Delegate the checked upgrades to the real `mt` inline, then drop the upgraded
/// rows in place. Runs one pass per kind (`--formula`, `--cask`) so the row the
/// user checked is the row upgraded — `mt upgrade <name>` is formula-first, so a
/// checked cask would otherwise upgrade a same-named formula. Names borrow the
/// parse arena, which `dropUpgradedRows` keeps alive across both passes.
fn doUpgrade(s: *State, storage: *Storage, c: *ctx.Ctx) !void {
    const count = selectedCount(s);
    if (count == 0) return; // empty selection: no-op
    // Snapshot the selection (formula refs first, then cask) before any upgrade
    // or drop — the drop rebuilds the checkbox buffer, erasing the selection.
    const upgraded = try c.allocator.alloc(UpgradedRef, count);
    defer c.allocator.free(upgraded);
    const split = collectUpgraded(s, upgraded);

    const passes = [_]struct { refs: []const UpgradedRef, flag: []const u8 }{
        .{ .refs = upgraded[0..split], .flag = "--formula" },
        .{ .refs = upgraded[split..], .flag = "--cask" },
    };
    // Passes run independently: a failed formula pass still lets the cask pass
    // proceed, and only a succeeded pass's rows are dropped. A non-zero `mt
    // upgrade` re-enters the dashboard and surfaces as a recoverable banner.
    var dropped_any = false;
    for (passes) |pass| {
        const argv = (try kindUpgradeArgv(c.allocator, c.mt_path, pass.refs, pass.flag)) orelse continue;
        defer c.allocator.free(argv);
        if (spawn.runInlineReenterStatus(c.term, argv)) |code| {
            if (code == 0) {
                try dropUpgradedRows(c.allocator, s, storage, c.shared, pass.refs);
                dropped_any = true;
            } else {
                var dbuf: [96]u8 = undefined;
                c.shared.banner.set("upgrade failed", upgradeFailDetail(&dbuf, code, pass.refs));
            }
        } else |err| {
            c.shared.banner.set("upgrade failed", @errorName(err));
        }
    }
    if (dropped_any) c.shared.markStaleAfter(.outdated); // Installed sizes/versions changed too
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

/// Repoint the Outdated tab and the header count at a drained `--json` payload.
/// `null` (a fresh prefix's exit-0 no-output) clears to a known-zero tab; a parsed
/// document swaps in the rows and a fresh, all-clear checkbox buffer. Shared by
/// the synchronous reload and the background launch fetch, so both land the same
/// state. The storage is swapped only after a clean parse — a failure keeps the
/// last-good rows for the caller's banner to explain. Public because the shell's
/// fetch drain routes a background payload through it.
pub fn applyOutdatedBytes(allocator: std.mem.Allocator, st: *State, storage: *Storage, shared: *ctx.SharedModel, bytes: ?[]const u8) outdated_json.Error!void {
    const payload = bytes orelse {
        if (storage.outdated) |old| old.deinit();
        if (storage.checked.len != 0) allocator.free(storage.checked);
        storage.outdated = null;
        storage.checked = &.{};
        st.items = &.{};
        st.checked = &.{};
        shared.outdated_count = 0; // nothing outdated is a known zero, not "unknown"
        return;
    };
    const parsed = try outdated_json.parse(allocator, payload);
    errdefer parsed.deinit();
    // A fresh checkbox buffer, all clear: an upgrade removes the upgraded rows, so
    // carrying the old selection forward would point at the wrong packages.
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

// Index 1 (curl) is pinned: shown but held back from any bulk upgrade.
const sample = [_]Row{
    .{ .name = "wget", .installed = "1.24.5", .latest = "1.25.0", .kind = .formula, .pinned = false, .tap = "" },
    .{ .name = "curl", .installed = "8.1.0", .latest = "8.2.0", .kind = .formula, .pinned = true, .tap = "" },
    .{ .name = "firefox", .installed = "120.0", .latest = "121.0", .kind = .cask, .pinned = false, .tap = "user/repo" },
    .{ .name = "ffmpeg", .installed = "8.0", .latest = "8.1", .kind = .formula, .pinned = false, .tap = "" },
};

test "End jumps to the last filtered row" {
    var s: State = .{ .items = &sample };
    step(&s, .end);
    try testing.expectEqual(@as(usize, 3), s.chrome.view.selected);

    s.chrome.filter.push("f"); // firefox, ffmpeg
    step(&s, .end);
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

test "mutates is true only for a pending upgrade — the request that takes the WAL writer" {
    var s: State = .{};
    try testing.expect(!mutates(&s)); // .none never gates the pre-mutation drain
    s.request = .upgrade;
    try testing.expect(mutates(&s));
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
    step(&s, ch('a')); // setAll must stop at the slice end
    step(&s, .space); // toggle the cursor row only if in range
    _ = selectedCount(&s);
    var out: [4][]const u8 = undefined;
    _ = selectedNames(&s, &out);
}

test "upgradeFailDetail names the live app on the refusal code, else stays generic" {
    var buf: [96]u8 = undefined;
    const one = [_]UpgradedRef{.{ .name = "flux-markdown", .kind = .cask }};
    const many = [_]UpgradedRef{ .{ .name = "a", .kind = .cask }, .{ .name = "b", .kind = .cask } };

    // The refusal code names the one cask, or stays generic for a batch.
    try testing.expectEqualStrings("flux-markdown is running", upgradeFailDetail(&buf, cask_app_running_exit, &one));
    try testing.expectEqualStrings("a selected app is running", upgradeFailDetail(&buf, cask_app_running_exit, &many));
    // Any other non-zero exit is the generic child failure, unnamed.
    try testing.expectEqualStrings("ChildFailed", upgradeFailDetail(&buf, 1, &one));

    // Edge: a name longer than the buffer falls back rather than truncating mid-name.
    var tiny: [4]u8 = undefined;
    try testing.expectEqualStrings("an app is running", upgradeFailDetail(&tiny, cask_app_running_exit, &one));
}

test "collectUpgraded partitions checked rows formula-first, then cask, excluding pinned" {
    const items = [_]Row{
        .{ .name = "firefox", .installed = "1", .latest = "2", .kind = .cask, .pinned = false, .tap = "" },
        .{ .name = "wget", .installed = "1", .latest = "2", .kind = .formula, .pinned = false, .tap = "" },
        .{ .name = "held", .installed = "1", .latest = "2", .kind = .formula, .pinned = true, .tap = "" },
    };
    var checked = [_]bool{ true, true, true }; // held is pinned → excluded
    var st: State = .{ .items = &items, .checked = &checked };
    var buf: [3]UpgradedRef = undefined;
    const split = collectUpgraded(&st, buf[0..selectedCount(&st)]);
    try testing.expectEqual(@as(usize, 1), split); // one formula, before the cask
    try testing.expectEqualStrings("wget", buf[0].name);
    try testing.expectEqual(outdated_json.Kind.formula, buf[0].kind);
    try testing.expectEqualStrings("firefox", buf[1].name);
    try testing.expectEqual(outdated_json.Kind.cask, buf[1].kind);
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

test "a mixed selection yields a --formula pass and a --cask pass" {
    const items = [_]Row{
        .{ .name = "wget", .installed = "1", .latest = "2", .kind = .formula, .pinned = false, .tap = "" },
        .{ .name = "firefox", .installed = "1", .latest = "2", .kind = .cask, .pinned = false, .tap = "" },
    };
    var checked = [_]bool{ true, true };
    var st: State = .{ .items = &items, .checked = &checked };
    var buf: [2]UpgradedRef = undefined;
    const split = collectUpgraded(&st, buf[0..selectedCount(&st)]);

    const f = (try kindUpgradeArgv(testing.allocator, "/bin/mt", buf[0..split], "--formula")).?;
    defer testing.allocator.free(f);
    try testing.expectEqualStrings("--formula", f[2]);
    try testing.expectEqualStrings("wget", f[3]);

    const c = (try kindUpgradeArgv(testing.allocator, "/bin/mt", buf[split..], "--cask")).?;
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("--cask", c[2]);
    try testing.expectEqualStrings("firefox", c[3]);
}

test "a cask-only selection runs no formula pass and upgrades the cask" {
    const items = [_]Row{
        .{ .name = "wget", .installed = "1", .latest = "2", .kind = .formula, .pinned = false, .tap = "" },
        .{ .name = "firefox", .installed = "1", .latest = "2", .kind = .cask, .pinned = false, .tap = "" },
    };
    var checked = [_]bool{ false, true }; // only the cask is checked
    var st: State = .{ .items = &items, .checked = &checked };
    var buf: [1]UpgradedRef = undefined;
    const split = collectUpgraded(&st, buf[0..selectedCount(&st)]);
    try testing.expectEqual(@as(usize, 0), split); // no formula rows
    try testing.expect((try kindUpgradeArgv(testing.allocator, "/bin/mt", buf[0..split], "--formula")) == null);
    const c = (try kindUpgradeArgv(testing.allocator, "/bin/mt", buf[split..], "--cask")).?;
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("--cask", c[2]);
    try testing.expectEqualStrings("firefox", c[3]);
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
    try applyOutdatedBytes(testing.allocator, &st, &storage, &shared, json);
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

test "applyOutdatedBytes reallocs the checkbox buffer to the new row count" {
    var st: State = .{};
    var storage: Storage = .{};
    var shared: ctx.SharedModel = .{};
    defer storage.deinit(testing.allocator);
    // First parse (two rows). Its arena must be freed when the second lands, or the
    // test allocator trips — this pins that the arena lifetime moved into the tab's
    // own Storage, so a re-load frees the prior parse rather than leaking it.
    try applyOutdatedBytes(testing.allocator, &st, &storage, &shared, "{\"outdated\":[{\"name\":\"a\",\"installed\":\"1\",\"latest\":\"2\",\"type\":\"formula\",\"pinned\":false},{\"name\":\"b\",\"installed\":\"1\",\"latest\":\"2\",\"type\":\"formula\",\"pinned\":false}]}");
    storage.checked[0] = true; // a stale selection the swap must not carry forward
    try testing.expectEqual(@as(usize, 2), storage.outdated.?.items.len);
    try testing.expectEqual(@as(usize, 2), storage.checked.len);
    // Second parse (one row) swaps in a fresh arena + an all-clear checkbox buffer.
    try applyOutdatedBytes(testing.allocator, &st, &storage, &shared, "{\"outdated\":[{\"name\":\"z\",\"installed\":\"1\",\"latest\":\"9\",\"type\":\"cask\",\"pinned\":false}]}");
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
    try applyOutdatedBytes(testing.allocator, &st, &storage, &shared, json);
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
    try applyOutdatedBytes(testing.allocator, &st, &storage, &shared, json);

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
    try applyOutdatedBytes(testing.allocator, &st, &storage, &shared, json);
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
    try applyOutdatedBytes(testing.allocator, &st, &storage, &shared, json);
    try dropUpgradedRows(testing.allocator, &st, &storage, &shared, &.{ .{ .name = "a", .kind = .formula }, .{ .name = "b", .kind = .formula } });
    try testing.expectEqual(@as(usize, 0), storage.outdated.?.items.len);
    try testing.expectEqual(@as(?usize, 0), shared.outdated_count);
}

// Backing storage for a `ctx.Ctx` in an effect test: dummy term/fetches/shared,
// a no-op painter (fd = -1; the test children never reach a poll tick), and the
// synchronous-load flag.
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

test "service on a .none request is a clean no-op — no spawn, no banner" {
    var thr = std.Io.Threaded.init(testing.allocator, .{});
    defer thr.deinit();
    var env: TestEnv = .{ .term_h = ctx.Term.init(thr.io(), -1) };
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    var st: State = .{}; // .none: the pure `step` set nothing to perform
    var c = mkCtx(thr.io(), &env, "/bin/false"); // would fail if it ever spawned
    try service(&st, &storage, &c);
    try testing.expectEqual(Request.none, st.request);
    try testing.expect(!env.shared.banner.isSet());
}

test "service drains an upgrade request; an empty selection never spawns" {
    var thr = std.Io.Threaded.init(testing.allocator, .{});
    defer thr.deinit();
    var env: TestEnv = .{ .term_h = ctx.Term.init(thr.io(), -1) };
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    // An empty selection means `doUpgrade` resolves count == 0: the request drains
    // but no `mt upgrade` child runs, so `/bin/false` is never reached.
    var st: State = .{ .request = .upgrade };
    var c = mkCtx(thr.io(), &env, "/bin/false");
    try service(&st, &storage, &c);
    try testing.expectEqual(Request.none, st.request); // the producer/consumer seam drained it
    try testing.expect(!env.shared.banner.isSet()); // never spawned → no failure banner
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
