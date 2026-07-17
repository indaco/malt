//! malt — Services tab for `mt tui`: the service lifecycle pane.
//!
//! Leaf module. Pure cores only: `step` maps a lifecycle key to a `Cmd`
//! (`start`/`stop`/`restart` → a `run_mutation` for the real `mt services
//! <action> <name>`); `update` folds the pump's result back (a finished mutation
//! asks for a fresh read, a delivered read swaps in the rows). The tab names
//! effects as data and never imports the runner. `render(state, frame, rect)` is
//! a pure function of `(state, rect)` so a resize is a re-render. The shell owns
//! the row
//! data; `items` borrow from that storage. Each row shows a state dot (running /
//! stopped / unknown) and the auto-start hint. The `state` string is bucketed,
//! not matched against an enum, so a future/unusual runtime state still renders.
//! No in-TUI confirm: the service actions are reversible, so the keystroke
//! delegates straight to `mt`, trusting any sudo/confirm prompt `mt` itself raises.

const std = @import("std");
const testing = std.testing;

const color = @import("../ui/color.zig");
const cmd = @import("cmd.zig");
const ctx = @import("ctx.zig");
const services_json = @import("json/services.zig");
pub const Row = services_json.ServiceRow;
const detail_pane = @import("detail_pane.zig");
const scroll_list = @import("scroll_list.zig");
const tab = @import("tab.zig");

pub const State = struct {
    chrome: tab.Chrome = .{},
    /// Service rows, borrowed from shell-owned parse storage.
    items: []const Row = &.{},
    /// The row whose detail pane is open (Enter), or null when closed (Esc).
    /// A copy of the selected Row — its slices borrow the same shell storage.
    detail: ?Row = null,
};

/// Tab-private parse storage: the `services list` rows the tab borrows. Owned
/// beside the tab so the parse arena's lifetime lives here, not in a central
/// store. `deinit` frees it.
pub const Storage = struct {
    services: ?services_json.Parsed = null,

    pub fn deinit(self: *Storage, allocator: std.mem.Allocator) void {
        _ = allocator; // the parse arena is self-freeing
        if (self.services) |p| p.deinit();
    }
};

/// Services audits in the background; a non-clean exit means a failed refresh.
pub const fetch_spec: ?tab.FetchSpec = .{ .verb = &.{ "services", "list" }, .max_ok_exit = 0, .refresh_op = "services refresh failed", .parse = cmd.parserFor(.services, services_json.parse) };

pub fn title() []const u8 {
    return "Services";
}

/// The tab's action keys, surfaced in the shared footer next to the global keys.
pub fn footerHint() []const u8 {
    return "enter: details   s: start   x: stop   r: restart";
}

/// Case-insensitive substring match of `filter` against `name`. An empty filter
/// matches everything.
pub fn matches(name: []const u8, filter: []const u8) bool {
    return filter.len == 0 or std.ascii.indexOfIgnoreCase(name, filter) != null;
}

fn filteredCount(items: []const Row, filter: []const u8) usize {
    var n: usize = 0;
    for (items) |s| {
        if (matches(s.name, filter)) n += 1;
    }
    return n;
}

/// The service the selection points at, after applying the filter and clamping
/// the (shell-driven, unbounded) selection into the filtered list. The shell
/// reads its `name` to build `mt services <action> <name>`.
pub fn selectedService(s: *const State) ?Row {
    const filter = s.chrome.filter.slice();
    const nf = filteredCount(s.items, filter);
    if (nf == 0) return null;
    const sel = @min(s.chrome.view.selected, nf - 1);
    var fi: usize = 0;
    for (s.items) |svc| {
        if (!matches(svc.name, filter)) continue;
        if (fi == sel) return svc;
        fi += 1;
    }
    return null; // unreachable: sel < nf
}

/// Pure transition: map a key to a `Cmd` for the pump to perform. `s` start,
/// `x`/`X` stop, `r` restart — reversible, so no confirm guard. Enter opens the
/// detail pane (all its fields are already on the Row, so no round-trip), Esc
/// closes it — both pure state, `Cmd.none`. The lifecycle keys return a
/// `run_mutation` carrying `mt services <action> <name>`.
pub fn step(allocator: std.mem.Allocator, mt_path: []const u8, s: *State, storage: *Storage, key: tab.Key) cmd.Cmd {
    _ = storage;
    switch (key) {
        .enter => s.detail = selectedService(s),
        .esc => s.detail = null,
        // Only the tab knows its filtered row count, so the shell defers End here.
        .end => s.chrome.view.selected = filteredCount(s.items, s.chrome.filter.slice()) -| 1,
        .char => |c| if (c.len == 1) switch (c.bytes[0]) {
            's' => return actionCmd(allocator, mt_path, s, "start"),
            'x', 'X' => return actionCmd(allocator, mt_path, s, "stop"),
            'r' => return actionCmd(allocator, mt_path, s, "restart"),
            else => {},
        },
        else => {},
    }
    return .none;
}

/// The state buckets the dot encodes. `state` is bucketed rather than matched
/// exhaustively, so any unrecognized value lands in `unknown`; only `errored`
/// is pulled out of that fallthrough so a failing service reads as danger.
const Status = enum { running, stopped, errored, unknown };

fn statusOf(state: []const u8) Status {
    if (std.mem.eql(u8, state, "running")) return .running;
    if (std.mem.eql(u8, state, "stopped") or std.mem.eql(u8, state, "not-loaded")) return .stopped;
    if (std.mem.eql(u8, state, "errored")) return .errored;
    return .unknown; // loaded / degraded / any future or unusual state
}

fn dotGlyph(st: Status) []const u8 {
    return switch (st) {
        .running => "●",
        .stopped => "○",
        .errored => "●", // shares the filled dot with running; the danger colour carries the failure
        .unknown => "◌",
    };
}

fn dotStyle(st: Status) color.Role {
    return switch (st) {
        .running => .success, // a live service reads as healthy
        .stopped => .muted,
        .errored => .danger, // at-a-glance failure signal
        .unknown => .muted,
    };
}

/// The detail pane's fields for the open row; the values borrow the row's slices.
fn detailFields(d: Row) [4]detail_pane.Field {
    return .{
        .{ .label = "Schedule", .value = if (d.schedule.len != 0) d.schedule else "-" },
        .{ .label = "Keg", .value = if (d.keg_name.len != 0) d.keg_name else "-" },
        .{ .label = "State", .value = d.state },
        .{ .label = "Auto-start", .value = if (d.auto_start) "yes" else "no" },
    };
}

/// The rect `renderList` paints into: the content minus the docked detail pane.
/// Shared with `hitTest` so a click lands on the row under the pointer even with a
/// pane open.
fn listContentRect(s: *const State, rect: tab.Rect) tab.Rect {
    var content = rect;
    if (s.detail) |d| {
        const fields = detailFields(d);
        content.height -|= detail_pane.dockHeight(&fields, rect.width, rect.height);
    }
    return content;
}

pub const Hit = tab.Hit;

/// The list's on-screen geometry: the sub-rect below the heading, the view
/// `clamp`ed to that height, and the filtered row `count`. The single source of
/// truth `renderList` and `hitTest` share, so paint and hit-test cannot drift.
fn listGeometry(s: *const State, rect: tab.Rect) struct { list: tab.Rect, view: scroll_list.View, count: usize } {
    const nf = filteredCount(s.items, s.chrome.filter.slice());
    // The bold heading rides row 0 and costs the list one row.
    const list: tab.Rect = .{ .row = rect.row + 1, .col = rect.col, .width = rect.width, .height = rect.height -| 1 };
    return .{ .list = list, .view = scroll_list.clamp(s.chrome.view, nf, list.height), .count = nf };
}

/// Map a click to the list row it lands on. A left-click uses `index` to move the
/// cursor; a right-click consumes `open` to show the row's detail pane. `click_col`
/// is accepted but unused — rows are full-width.
pub fn hitTest(s: *const State, rect: tab.Rect, click_row: u16, click_col: u16) ?Hit {
    _ = click_col; // full-width rows: the column carries no row identity
    const g = listGeometry(s, listContentRect(s, rect)); // the rect the list actually paints into
    const idx = scroll_list.rowAt(g.view, g.list.row, g.list.height, g.count, click_row) orelse return null;
    return .{ .index = idx, .open = true };
}

/// Pure render: the filtered + scrolled service list, with the detail pane docked
/// below it when open. A pure function of `(state, rect)` so a resize is a re-render.
pub fn render(s: *const State, f: *tab.Frame, r: tab.Rect) void {
    if (r.height == 0) return;
    const list_rect = listContentRect(s, r);
    if (s.detail) |d| if (list_rect.height < r.height) {
        const fields = detailFields(d);
        detail_pane.render(f, &fields, .{ .row = r.row + list_rect.height, .col = r.col, .width = r.width, .height = r.height - list_rect.height });
    };
    renderList(s, f, list_rect);
}

fn renderList(s: *const State, f: *tab.Frame, rect: tab.Rect) void {
    if (rect.height == 0) return;
    const filter = s.chrome.filter.slice();
    const g = listGeometry(s, rect);
    const nf = g.count;
    if (nf == 0) return tab.renderHint(f, rect, if (filter.len != 0) "No matches." else "No services registered.");
    // A fixed bold heading rides above the list and costs it one row.
    tab.renderHeading(f, rect, 2, &.{
        .{ .label = "NAME", .width = 24 },
        .{ .label = "STATE", .width = 12 },
        .{ .label = "START", .width = 8 },
        .{ .label = "KEG", .width = 3, .gap = 0 }, // formatRow appends the keg with no separator
    });
    const list = g.list;
    if (list.height == 0) return; // the heading took the only row
    const v = g.view;

    var fi: usize = 0;
    for (s.items) |svc| {
        if (!matches(svc.name, filter)) continue;
        defer fi += 1;
        if (fi < v.offset) continue;
        const screen = fi - v.offset;
        if (screen >= list.height) break;
        f.moveTo(list.row + @as(u16, @intCast(screen)), list.col);
        // The dot keeps its own colour regardless of selection; the reverse-video
        // selection wraps only the text columns so the two SGRs never tangle.
        const st = statusOf(svc.state);
        f.put(color.roleCode(dotStyle(st)));
        f.put(dotGlyph(st));
        f.put(color.Style.reset.code());
        f.put(" ");
        const selected = fi == v.selected;
        if (selected) { // the accent backgrounds the cursor row under a theme
            f.put(color.selectionAccent());
            f.put(color.Style.reverse.code());
        }
        var rb: [256]u8 = undefined;
        f.putContent(scroll_list.truncate(formatRow(&rb, svc), list.width -| 2)); // 2 cols spent on the dot
        if (selected) f.put(color.Style.reset.code());
    }
}

/// A single-cell clock marking a scheduled service. Same single-width family as
/// the status dots (`● ○ ◌`); the full label lives in the ENTER detail pane.
const sched_marker = "◷"; // U+25F7, 3 bytes, 1 display column

/// One list row (after the dot): the name (with a `◷` when scheduled), the
/// runtime state, the auto-start hint, then the owning keg. ASCII columns,
/// grapheme-naive like the rest.
fn formatRow(buf: []u8, s: Row) []const u8 {
    var len: usize = 0;
    appendName(buf, &len, s.name, s.schedule.len != 0, 24);
    append(buf, &len, " ");
    appendPad(buf, &len, s.state, 12);
    append(buf, &len, " ");
    appendPad(buf, &len, if (s.auto_start) "auto" else "manual", 8);
    append(buf, &len, s.keg_name);
    return buf[0..len];
}

/// Write the name, a ` ◷` marker when scheduled, then pad to `width` *display*
/// cells so the next column aligns regardless of the marker. The marker's extra
/// bytes (3-byte glyph, 1 cell) don't count toward the cell budget, so columns
/// never drift. A name too long to fit the marker simply doesn't get one.
fn appendName(buf: []u8, len: *usize, name: []const u8, scheduled: bool, width: usize) void {
    append(buf, len, name);
    var cells = name.len; // one byte ≈ one cell for the ASCII name
    if (scheduled and cells + 2 <= width) {
        append(buf, len, " ");
        append(buf, len, sched_marker);
        cells += 2; // a space plus the 1-cell clock
    }
    while (cells < width) : (cells += 1) append(buf, len, " ");
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
// The tab names effects as `Cmd` values; the pump performs them and folds the
// result back through `update`. No I/O and no runner import here — the
// file-level purity a structural grep for the runner pins.

/// Banner op strings for a recoverable fault, kept as parity with the pre-reify
/// error names so the dashboard shows the same banners it always has.
const action_fail_op = "service action failed";
const refresh_fail_op = "services refresh failed";

/// Build the `mt services <action> <name>` mutation for the selected service, or
/// `Cmd.none` when nothing is selected (the empty-list no-op). The argv's `name`
/// borrows the parse storage; the pump reads it before the post-mutation reload
/// frees that storage, and frees only the returned slice, not its elements.
fn actionCmd(allocator: std.mem.Allocator, mt_path: []const u8, s: *const State, action: []const u8) cmd.Cmd {
    const svc = selectedService(s) orelse return .none; // empty list: no-op
    // An argv-build OOM drops this keystroke's effect rather than the TUI; the
    // user retries. The pump owns runner faults and the recoverable banner.
    const argv = cmd.inlineArgv(allocator, mt_path, &.{ "services", action, svc.name }) catch return .none;
    return .{ .run_mutation = .{ .argv = argv, .tag = .services, .fail_op = action_fail_op } };
}

/// Fold a completed effect back into the model. A successful lifecycle mutation
/// (exit 0) marks the sibling tabs stale and asks for a fresh `mt services list
/// --json` read; a non-zero exit surfaces the recoverable banner and stops. A
/// delivered read swaps its rows into storage — the tab's Elm `update`.
pub fn update(allocator: std.mem.Allocator, mt_path: []const u8, s: *State, storage: *Storage, shared: *ctx.SharedModel, msg: cmd.Msg) cmd.Cmd {
    switch (msg) {
        .mutated => |code| {
            if (code != 0) {
                shared.banner.set(action_fail_op, "ChildFailed");
                return .none;
            }
            shared.markStaleAfter(.services); // this tab refreshes next; the others may be stale
            const argv = cmd.jsonArgv(allocator, mt_path, &.{ "services", "list" }) catch return .none;
            return .{ .read = .{ .argv = argv, .allow_empty = true, .mode = .polled, .parse = cmd.parserFor(.services, services_json.parse), .tag = .services, .fail_op = refresh_fail_op } };
        },
        .loaded => |parsed| {
            swapRows(s, storage, parsed.services);
            return .none;
        },
        .cleared => {
            clear(s, storage); // an exit-0 empty read: no services registered
            return .none;
        },
        .failed => return .none, // the pump set the banner; keep the last-good rows
    }
}

/// Repoint the rows at a fresh parse, freeing the previous one. The swap happens
/// only after a clean parse upstream, so a failed refresh keeps the last-good rows.
fn swapRows(s: *State, storage: *Storage, parsed: services_json.Parsed) void {
    if (storage.services) |old| old.deinit();
    storage.services = parsed;
    s.items = parsed.items;
    s.detail = null; // a refreshed list invalidates the old detail
}

/// Clear to the empty-list state, freeing any held parse. The `.cleared` fold —
/// an exit-0 empty read, background or keypress.
fn clear(s: *State, storage: *Storage) void {
    if (storage.services) |old| old.deinit();
    storage.services = null;
    s.items = &.{};
    s.detail = null; // the old detail borrowed the freed rows
}

// ─── tests ───────────────────────────────────────────────────────────

fn ch(c: u8) tab.Key {
    return .{ .char = .{ .bytes = .{ c, 0, 0, 0 }, .len = 1 } };
}

/// Drive `step` with a throwaway storage and a fixed mt path. Services' `step`
/// ignores storage, so this keeps the pure-behaviour tests readable.
fn stepKey(s: *State, key: tab.Key) cmd.Cmd {
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    return step(testing.allocator, "/opt/malt/bin/mt", s, &storage, key);
}

const sample = [_]Row{
    .{ .name = "redis", .state = "running", .auto_start = true, .keg_name = "redis" },
    .{ .name = "postgresql", .state = "stopped", .auto_start = false, .keg_name = "postgresql@16" },
    .{ .name = "dnsmasq", .state = "not-loaded", .auto_start = true, .keg_name = "dnsmasq" },
    .{ .name = "weird", .state = "degraded", .auto_start = false, .keg_name = "weird" },
};

test "footerHint advertises the details affordance alongside the lifecycle keys" {
    const h = footerHint();
    try testing.expect(std.mem.indexOf(u8, h, "enter: details") != null);
    try testing.expect(std.mem.indexOf(u8, h, "s: start") != null);
}

test "End jumps to the last filtered row" {
    var s: State = .{ .items = &sample };
    _ = stepKey(&s, .end);
    try testing.expectEqual(@as(usize, 3), s.chrome.view.selected);
}

test "matches is a case-insensitive substring; empty filter matches all" {
    try testing.expect(matches("redis", ""));
    try testing.expect(matches("Redis", "red"));
    try testing.expect(!matches("redis", "zzz"));
}

test "s/x/r return the run_mutation for `mt services <action> <selected>`" {
    var s: State = .{ .items = &sample }; // selection defaults to row 0 (redis)
    const cases = [_]struct { key: tab.Key, action: []const u8 }{
        .{ .key = ch('s'), .action = "start" },
        .{ .key = ch('x'), .action = "stop" },
        .{ .key = ch('X'), .action = "stop" },
        .{ .key = ch('r'), .action = "restart" },
    };
    for (cases) |c| {
        const eff = stepKey(&s, c.key);
        defer testing.allocator.free(eff.run_mutation.argv);
        try testing.expect(eff == .run_mutation);
        try testing.expectEqual(cmd.MsgTag.services, eff.run_mutation.tag);
        const argv = eff.run_mutation.argv;
        try testing.expectEqualStrings("services", argv[1]);
        try testing.expectEqualStrings(c.action, argv[2]);
        try testing.expectEqualStrings("redis", argv[3]);
    }
}

test "a lifecycle key on an empty list is a Cmd.none no-op — no effect" {
    var s: State = .{ .items = &.{} };
    try testing.expect(stepKey(&s, ch('s')) == .none);
}

test "an unrelated key returns Cmd.none; a pure-nav key changes state but stays none" {
    var s: State = .{ .items = &sample };
    try testing.expect(stepKey(&s, ch('z')) == .none);
    try testing.expect(stepKey(&s, .enter) == .none); // opens the detail pane…
    try testing.expect(s.detail != null); // …but that is pure state, not an effect
}

test "selectedService maps the cursor through the filter and clamps out-of-range" {
    var s: State = .{ .items = &sample };
    s.chrome.view.selected = 0;
    try testing.expectEqualStrings("redis", selectedService(&s).?.name);

    s.chrome.filter.push("d"); // redis, dnsmasq, weird (all contain 'd'; not postgresql)
    s.chrome.view.selected = 0;
    try testing.expectEqualStrings("redis", selectedService(&s).?.name);
    s.chrome.view.selected = 99; // clamps to the last match
    try testing.expectEqualStrings("weird", selectedService(&s).?.name);

    s.chrome.filter.clear();
    s.chrome.filter.push("zzz");
    try testing.expect(selectedService(&s) == null);
}

test "selectedService on an empty list is null (the action becomes a no-op)" {
    const s: State = .{ .items = &.{} };
    try testing.expect(selectedService(&s) == null);
}

test "statusOf buckets known states and treats anything else as unknown" {
    try testing.expectEqual(Status.running, statusOf("running"));
    try testing.expectEqual(Status.stopped, statusOf("stopped"));
    try testing.expectEqual(Status.stopped, statusOf("not-loaded"));
    try testing.expectEqual(Status.unknown, statusOf("loaded"));
    try testing.expectEqual(Status.unknown, statusOf("degraded"));
    try testing.expectEqual(Status.unknown, statusOf(""));
    // errored breaks out of the muted unknown bucket; the fallthrough is unchanged.
    try testing.expectEqual(Status.errored, statusOf("errored"));
}

test "dotStyle maps errored to the danger role, not the muted unknown style" {
    try testing.expectEqual(color.Role.danger, dotStyle(.errored));
    try testing.expectEqual(color.Role.muted, dotStyle(.unknown));
}

test "render heads the columns in bold, indented past the status dot" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample };
    render(&s, &f, .{ .row = 3, .col = 1, .width = 80, .height = 12 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, color.Style.bold.code()) != null);
    // The 2-col dot indent plus exact padding aligns the labels over values.
    try testing.expect(std.mem.indexOf(u8, out, "  NAME" ++ " " ** 21 ++ "STATE" ++ " " ** 8 ++ "START" ++ " " ** 3 ++ "KEG") != null);
    try testing.expect(std.mem.indexOf(u8, out, "redis") != null); // the list still renders below
}

test "formatRow marks a scheduled service with a clock and keeps STATE aligned" {
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    const scheduled = formatRow(&a, .{ .name = "backup", .state = "loaded", .auto_start = false, .keg_name = "backup", .schedule = "interval 300s" });
    const plain = formatRow(&b, .{ .name = "backup", .state = "loaded", .auto_start = false, .keg_name = "backup", .schedule = "" });
    // The clock marks only the scheduled row; the label itself stays out of the list.
    try testing.expect(std.mem.indexOf(u8, scheduled, "◷") != null);
    try testing.expect(std.mem.indexOf(u8, plain, "◷") == null);
    try testing.expect(std.mem.indexOf(u8, scheduled, "interval 300s") == null);
    // STATE lands at the same display column: the marker's only byte cost over the
    // plain row is the clock's 2 non-display bytes (3-byte glyph, 1 display cell).
    const i_plain = std.mem.indexOf(u8, plain, "loaded").?;
    const i_sched = std.mem.indexOf(u8, scheduled, "loaded").?;
    try testing.expectEqual(i_plain + 2, i_sched);
}

test "ENTER opens a detail pane showing the schedule label; ESC closes it" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const rows = [_]Row{
        .{ .name = "backup", .state = "loaded", .auto_start = false, .keg_name = "backup", .schedule = "interval 300s" },
    };
    var s: State = .{ .items = &rows };
    _ = stepKey(&s, .enter);
    try testing.expect(s.detail != null);

    render(&s, &f, .{ .row = 1, .col = 1, .width = 60, .height = 12 });
    const out = f.slice();
    // The label moved off the list into the pane, so this text can only be here.
    try testing.expect(std.mem.indexOf(u8, out, "Schedule") != null);
    try testing.expect(std.mem.indexOf(u8, out, "interval 300s") != null);

    _ = stepKey(&s, .esc);
    try testing.expect(s.detail == null);
}

test "detail pane shows no schedule label for a run-at-load service" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const rows = [_]Row{
        .{ .name = "redis", .state = "running", .auto_start = true, .keg_name = "redis", .schedule = "" },
    };
    var s: State = .{ .items = &rows };
    _ = stepKey(&s, .enter);
    render(&s, &f, .{ .row = 1, .col = 1, .width = 60, .height = 12 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "Schedule") != null);
    // An empty schedule must not surface a bogus interval/cron label.
    try testing.expect(std.mem.indexOf(u8, out, "interval") == null);
    try testing.expect(std.mem.indexOf(u8, out, "cron") == null);
}

test "render shows the schedule marker but not the label or a SCHED column" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const rows = [_]Row{
        .{ .name = "backup", .state = "loaded", .auto_start = false, .keg_name = "backup", .schedule = "interval 300s" },
    };
    const s: State = .{ .items = &rows };
    render(&s, &f, .{ .row = 2, .col = 1, .width = 80, .height = 12 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "◷") != null); // at-a-glance marker
    try testing.expect(std.mem.indexOf(u8, out, "SCHED") == null); // no 5th column heading
    try testing.expect(std.mem.indexOf(u8, out, "interval 300s") == null); // label lives in the detail pane
}

test "render lists services with a state dot, the state, and the auto-start hint" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample };
    render(&s, &f, .{ .row = 2, .col = 1, .width = 80, .height = 12 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "redis") != null);
    try testing.expect(std.mem.indexOf(u8, out, "running") != null);
    try testing.expect(std.mem.indexOf(u8, out, "auto") != null); // auto-start hint
    try testing.expect(std.mem.indexOf(u8, out, "manual") != null);
    try testing.expect(std.mem.indexOf(u8, out, "●") != null); // running dot
    try testing.expect(std.mem.indexOf(u8, out, color.Style.green.code()) != null); // coloured
}

test "render of an unusual state does not crash and uses the unknown dot" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    // Only the degraded (unknown) row, so the unknown glyph is unambiguous.
    const only = [_]Row{sample[3]};
    const s: State = .{ .items = &only };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "degraded") != null);
    try testing.expect(std.mem.indexOf(u8, out, "◌") != null); // unknown dot
}

test "render flags an errored service with the danger dot, not the muted unknown" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const only = [_]Row{.{ .name = "loopy", .state = "errored", .auto_start = true, .keg_name = "loopy" }};
    const s: State = .{ .items = &only };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "errored") != null);
    try testing.expect(std.mem.indexOf(u8, out, "●") != null); // filled dot, shared with running
    try testing.expect(std.mem.indexOf(u8, out, color.roleCode(.danger)) != null); // in danger red
    try testing.expect(std.mem.indexOf(u8, out, "◌") == null); // never the muted unknown dot
}

test "render narrows to the filter" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var s: State = .{ .items = &sample };
    s.chrome.filter.push("redis");
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "redis") != null);
    try testing.expect(std.mem.indexOf(u8, out, "postgresql") == null); // filtered out
}

test "render highlights the selected row" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var s: State = .{ .items = &sample };
    s.chrome.view.selected = 0;
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    try testing.expect(std.mem.indexOf(u8, f.slice(), color.Style.reverse.code()) != null);
}

test "footerHint exposes the lifecycle keys for the shared footer" {
    try testing.expect(std.mem.indexOf(u8, footerHint(), "start") != null);
    try testing.expect(std.mem.indexOf(u8, footerHint(), "restart") != null);
}

test "render reflows: the same state at two widths differs" {
    var a: [8192]u8 = undefined;
    var b: [8192]u8 = undefined;
    var fa: tab.Frame = .{ .buf = &a };
    var fb: tab.Frame = .{ .buf = &b };
    const s: State = .{ .items = &sample };
    render(&s, &fa, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    render(&s, &fb, .{ .row = 1, .col = 1, .width = 30, .height = 6 });
    try testing.expect(!std.mem.eql(u8, fa.slice(), fb.slice()));
}

test "a hostile service name cannot inject a control sequence into the frame" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const evil = [_]Row{.{ .name = "ev\x1b]0;pwn\x07il", .state = "running", .auto_start = false, .keg_name = "k" }};
    const s: State = .{ .items = &evil };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    const out = f.slice();
    // The dot legitimately emits its own SGR via `put`; the row *content* is funnelled
    // through `putContent`, so the name's OSC title-set and BEL are neutralized there.
    try testing.expect(std.mem.indexOf(u8, out, "\x1b]0;pwn") == null); // OSC introducer broken
    try testing.expect(std.mem.indexOfScalar(u8, out, 0x07) == null); // BEL dropped
}

test "render on an empty list shows the no-services placeholder, not a blank pane" {
    var buf: [1024]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &.{} };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 }); // must not trap
    try std.testing.expect(std.mem.indexOf(u8, f.slice(), "No services registered") != null);
}

test "render clamps to a height of one without crashing" {
    var buf: [1024]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 1 }); // one list row fits
}

test "the mutation targets the selected row's name" {
    const items = [_]Row{
        .{ .name = "redis", .state = "running", .auto_start = true, .keg_name = "redis" },
        .{ .name = "postgresql", .state = "stopped", .auto_start = false, .keg_name = "postgresql@16" },
    };
    var st: State = .{ .items = &items };
    st.chrome.view.selected = 1; // postgresql
    const eff = actionCmd(testing.allocator, "/opt/homebrew/bin/mt", &st, "restart");
    defer testing.allocator.free(eff.run_mutation.argv);
    const argv = eff.run_mutation.argv;
    try testing.expectEqual(@as(usize, 4), argv.len);
    try testing.expectEqualStrings("/opt/homebrew/bin/mt", argv[0]);
    try testing.expectEqualStrings("restart", argv[2]);
    try testing.expectEqualStrings("postgresql", argv[3]); // the selected row's name
}

test "update on a successful mutation marks siblings stale and asks for a fresh read" {
    var st: State = .{};
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    var shared: ctx.SharedModel = .{};
    const next = update(testing.allocator, "/bin/mt", &st, &storage, &shared, .{ .mutated = 0 });
    defer testing.allocator.free(next.read.argv);
    try testing.expect(next == .read);
    try testing.expectEqual(cmd.Cmd.Mode.polled, next.read.mode); // blocking, spinner-animated
    try testing.expectEqual(cmd.MsgTag.services, next.read.tag);
    try testing.expectEqualStrings("services", next.read.argv[1]);
    try testing.expectEqualStrings("list", next.read.argv[2]);
    try testing.expectEqualStrings("--json", next.read.argv[3]);
    try testing.expect(shared.takeDirty(.installed)); // siblings were marked stale
}

test "update on a failed mutation shows the recoverable banner and does not reload" {
    var st: State = .{};
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    var shared: ctx.SharedModel = .{};
    const next = update(testing.allocator, "/bin/mt", &st, &storage, &shared, .{ .mutated = 1 });
    try testing.expect(next == .none); // no reload on failure
    try testing.expect(std.mem.startsWith(u8, shared.banner.slice(), "service action failed"));
}

test "update on a loaded document swaps rows in, drops the stale detail, returns none" {
    var st: State = .{ .items = &sample, .detail = sample[0] };
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    var shared: ctx.SharedModel = .{};
    const parsed = try services_json.parse(testing.allocator, "{\"schema_version\":1,\"services\":[]}");
    const next = update(testing.allocator, "/bin/mt", &st, &storage, &shared, .{ .loaded = .{ .services = parsed } });
    try testing.expect(next == .none);
    try testing.expectEqual(@as(usize, 0), st.items.len); // swapped to the fresh (empty) parse
    try testing.expect(st.detail == null);
}

test "update on a cleared read (an exit-0 empty reload) empties the list" {
    var st: State = .{ .items = &sample, .detail = sample[0] };
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    var shared: ctx.SharedModel = .{};
    const next = update(testing.allocator, "/bin/mt", &st, &storage, &shared, .cleared);
    try testing.expect(next == .none);
    try testing.expectEqual(@as(usize, 0), st.items.len);
    try testing.expect(st.detail == null); // the stale detail borrowed the freed rows
}

test "a cleared services read (fresh prefix) drops to an empty list" {
    var st: State = .{ .items = &sample };
    var storage: Storage = .{};
    var shared: ctx.SharedModel = .{};
    defer storage.deinit(testing.allocator);
    // An exit-0 empty background/keypress read folds through `update` as `.cleared`.
    _ = update(testing.allocator, "/bin/mt", &st, &storage, &shared, .cleared);
    try testing.expectEqual(@as(usize, 0), st.items.len);
    try testing.expect(st.detail == null);
}

test "hitTest maps a click to the list row painted under it" {
    const s: State = .{ .items = &sample };
    const rect: tab.Rect = .{ .row = 2, .col = 1, .width = 80, .height = 12 };
    try testing.expectEqual(@as(usize, 0), hitTest(&s, rect, 3, 1).?.index); // first row, below the heading
    try testing.expect(hitTest(&s, rect, 3, 1).?.open); // right-click opens the pane
    try testing.expectEqual(@as(usize, 3), hitTest(&s, rect, 6, 1).?.index); // last row
    try testing.expect(hitTest(&s, rect, 2, 1) == null); // the heading row
    try testing.expect(hitTest(&s, rect, 1, 1) == null); // above the list
    try testing.expect(hitTest(&s, rect, 7, 1) == null); // blank row past the tail
}

test "hitTest resolves through the filter and the scroll offset" {
    var s: State = .{ .items = &sample };
    s.chrome.filter.push("d"); // redis, dnsmasq, weird
    const rect: tab.Rect = .{ .row = 2, .col = 1, .width = 80, .height = 12 };
    try testing.expectEqual(@as(usize, 1), hitTest(&s, rect, 4, 1).?.index); // 2nd *filtered* row

    s.chrome.filter.clear();
    s.chrome.view.selected = 3; // a 2-row list scrolls to offset 2
    const tight: tab.Rect = .{ .row = 2, .col = 1, .width = 80, .height = 3 };
    try testing.expectEqual(@as(usize, 2), hitTest(&s, tight, 3, 1).?.index); // offset followed
}

test "hitTest with the detail pane open lands on the shrunk list, never inside the pane" {
    var s: State = .{ .items = &sample };
    _ = stepKey(&s, .enter);
    const rect: tab.Rect = .{ .row = 2, .col = 1, .width = 60, .height = 12 };
    // The pane docks at the bottom; the list keeps the rows above it.
    try testing.expectEqual(@as(usize, 0), hitTest(&s, rect, 3, 1).?.index);
    try testing.expect(hitTest(&s, rect, 11, 1) == null); // inside the pane's region
}

test "hitTest on an empty list is null — the hint is not a row" {
    const s: State = .{ .items = &.{} };
    try testing.expect(hitTest(&s, .{ .row = 2, .col = 1, .width = 80, .height = 12 }, 3, 1) == null);
    // An open pane over an empty list still resolves to nothing, not to row 0.
    var open: State = .{ .items = &.{}, .detail = sample[0] };
    try testing.expect(hitTest(&open, .{ .row = 2, .col = 1, .width = 80, .height = 12 }, 3, 1) == null);
}

test "the pane's shrink cannot underflow the list rect at a degenerate size" {
    var buf: [4096]u8 = undefined;
    var s: State = .{ .items = &sample, .detail = sample[0] };
    // Heights around the pane's own footprint are where a shrink would go negative.
    for (0..6) |h| {
        for ([_]u16{ 0, 4, 60 }) |w| {
            const r: tab.Rect = .{ .row = 1, .col = 1, .width = w, .height = @intCast(h) };
            try testing.expect(listContentRect(&s, r).height <= r.height);
            _ = hitTest(&s, r, 2, 1); // must not trap
            var f: tab.Frame = .{ .buf = &buf };
            render(&s, &f, r); // must not trap
        }
    }
}

test "the row hitTest picks is the row selectedService opens — filtered, scrolled, paned" {
    var s: State = .{ .items = &sample };
    s.chrome.filter.push("d"); // redis, dnsmasq, weird
    s.chrome.view.selected = 2;
    _ = stepKey(&s, .enter); // dock the pane; the 3 filtered rows no longer fit, so it scrolls
    const rect: tab.Rect = .{ .row = 2, .col = 1, .width = 60, .height = 6 };
    // Both rows are resolved against the one frame the user is looking at: the offset is
    // derived from the current selection, so moving the cursor re-derives it.
    const first = hitTest(&s, rect, 3, 1).?.index; // first visible row — the offset, not row 0
    const second = hitTest(&s, rect, 4, 1).?.index;
    try testing.expectEqual(@as(usize, 1), first); // offset 1 followed
    try testing.expectEqual(@as(usize, 2), second);
    // The shell's right-click chain is exactly this: hitTest's index becomes the cursor,
    // and the pane opens whatever selectedService then resolves to. If the two ever
    // disagree, a click opens a row the user did not click.
    s.chrome.view.selected = first;
    try testing.expectEqualStrings("dnsmasq", selectedService(&s).?.name);
    s.chrome.view.selected = second;
    try testing.expectEqualStrings("weird", selectedService(&s).?.name);
}

test "conforms to the tab contract" {
    comptime tab.verify(@This());
}

test "Storage.deinit frees the parsed service rows" {
    const allocator = std.testing.allocator;
    var storage: Storage = .{};
    storage.services = try services_json.parse(allocator, "{\"schema_version\":1,\"services\":[]}");
    // A no-op deinit leaks the parse arena; `testing.allocator` trips at scope end.
    storage.deinit(allocator);
}
