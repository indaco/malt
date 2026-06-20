//! malt — Services tab for `mt tui`: the service lifecycle pane.
//!
//! Leaf module. Pure cores only: `step(state, key)` records a lifecycle intent
//! (`start`/`stop`/`restart`) as a `request` for the impure shell to delegate to
//! the real `mt services <action> <name>`; `render(state, frame, rect)` is a pure
//! function of `(state, rect)` so a resize is a re-render. The shell owns the row
//! data; `items` borrow from that storage. Each row shows a state dot (running /
//! stopped / unknown) and the auto-start hint. The `state` string is bucketed,
//! not matched against an enum, so a future/unusual runtime state still renders.
//! No in-TUI confirm: the service actions are reversible, so the keystroke
//! delegates straight to `mt`, trusting any sudo/confirm prompt `mt` itself raises.

const std = @import("std");
const testing = std.testing;

const color = @import("../ui/color.zig");
const services_json = @import("json/services.zig");
pub const Row = services_json.ServiceRow;
const detail_pane = @import("detail_pane.zig");
const scroll_list = @import("scroll_list.zig");
const tab = @import("tab.zig");

/// A lifecycle effect the pure `step` defers to the impure shell, which performs
/// it and resets the field. `step` never does I/O — this is the command channel.
pub const Request = enum { none, start, stop, restart };

pub const State = struct {
    chrome: tab.Chrome = .{},
    /// Service rows, borrowed from shell-owned parse storage.
    items: []const Row = &.{},
    /// Pending lifecycle effect for the shell to perform, then clear.
    request: Request = .none,
    /// The row whose detail pane is open (Enter), or null when closed (Esc).
    /// A copy of the selected Row — its slices borrow the same shell storage.
    detail: ?Row = null,
};

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

/// Pure transition: record a lifecycle intent for the shell to act on. `s` start,
/// `x`/`X` stop, `r` restart — reversible, so no confirm guard. Enter opens the
/// detail pane (all its fields are already on the Row, so no shell round-trip),
/// Esc closes it.
pub fn step(s: *State, key: tab.Key) void {
    switch (key) {
        .enter => s.detail = selectedService(s),
        .esc => s.detail = null,
        .char => |c| if (c.len == 1) switch (c.bytes[0]) {
            's' => s.request = .start,
            'x', 'X' => s.request = .stop,
            'r' => s.request = .restart,
            else => {},
        },
        else => {},
    }
}

/// The three state buckets the dot encodes. `state` is bucketed rather than
/// matched exhaustively, so any unrecognized value lands in `unknown`.
const Status = enum { running, stopped, unknown };

fn statusOf(state: []const u8) Status {
    if (std.mem.eql(u8, state, "running")) return .running;
    if (std.mem.eql(u8, state, "stopped") or std.mem.eql(u8, state, "not-loaded")) return .stopped;
    return .unknown; // loaded / degraded / any future or unusual state
}

fn dotGlyph(st: Status) []const u8 {
    return switch (st) {
        .running => "●",
        .stopped => "○",
        .unknown => "◌",
    };
}

fn dotStyle(st: Status) color.Role {
    return switch (st) {
        .running => .success, // a live service reads as healthy
        .stopped => .muted,
        .unknown => .muted,
    };
}

/// Pure render: the filtered + scrolled service list. The lifecycle keys live in
/// the shared footer, so the list owns the whole rect. A pure function of
/// `(state, rect)` so a resize is a re-render.
pub fn render(s: *const State, f: *tab.Frame, r: tab.Rect) void {
    if (r.height == 0) return;
    var list_rect = r;
    if (s.detail) |d| {
        const fields = [_]detail_pane.Field{
            .{ .label = "Schedule", .value = if (d.schedule.len != 0) d.schedule else "-" },
            .{ .label = "Keg", .value = if (d.keg_name.len != 0) d.keg_name else "-" },
            .{ .label = "State", .value = d.state },
            .{ .label = "Auto-start", .value = if (d.auto_start) "yes" else "no" },
        };
        const dh = @min(detail_pane.neededRows(&fields, r.width), r.height / 2);
        if (dh > 0 and dh < r.height) {
            list_rect.height = r.height - dh;
            detail_pane.render(f, &fields, .{ .row = r.row + list_rect.height, .col = r.col, .width = r.width, .height = dh });
        }
    }
    renderList(s, f, list_rect);
}

fn renderList(s: *const State, f: *tab.Frame, rect: tab.Rect) void {
    if (rect.height == 0) return;
    const filter = s.chrome.filter.slice();
    const nf = filteredCount(s.items, filter);
    if (nf == 0) return tab.renderHint(f, rect, if (filter.len != 0) "No matches." else "No services registered.");
    // A fixed bold heading rides above the list and costs it one row.
    tab.renderHeading(f, rect, 2, &.{
        .{ .label = "NAME", .width = 24 },
        .{ .label = "STATE", .width = 12 },
        .{ .label = "START", .width = 8 },
        .{ .label = "KEG", .width = 3, .gap = 0 }, // formatRow appends the keg with no separator
    });
    const list: tab.Rect = .{ .row = rect.row + 1, .col = rect.col, .width = rect.width, .height = rect.height -| 1 };
    if (list.height == 0) return; // the heading took the only row
    const v = scroll_list.clamp(s.chrome.view, nf, list.height);

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

// ─── tests ───────────────────────────────────────────────────────────

fn ch(c: u8) tab.Key {
    return .{ .char = .{ .bytes = .{ c, 0, 0, 0 }, .len = 1 } };
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

test "matches is a case-insensitive substring; empty filter matches all" {
    try testing.expect(matches("redis", ""));
    try testing.expect(matches("Redis", "red"));
    try testing.expect(!matches("redis", "zzz"));
}

test "s requests start, x and X request stop, r requests restart" {
    var s: State = .{ .items = &sample };
    step(&s, ch('s'));
    try testing.expectEqual(Request.start, s.request);
    step(&s, ch('x'));
    try testing.expectEqual(Request.stop, s.request);
    step(&s, ch('X'));
    try testing.expectEqual(Request.stop, s.request);
    step(&s, ch('r'));
    try testing.expectEqual(Request.restart, s.request);
}

test "an unrelated key leaves the request alone" {
    var s: State = .{ .items = &sample };
    step(&s, ch('z'));
    try testing.expectEqual(Request.none, s.request);
    step(&s, .enter);
    try testing.expectEqual(Request.none, s.request);
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
    step(&s, .enter);
    try testing.expect(s.detail != null);

    render(&s, &f, .{ .row = 1, .col = 1, .width = 60, .height = 12 });
    const out = f.slice();
    // The label moved off the list into the pane, so this text can only be here.
    try testing.expect(std.mem.indexOf(u8, out, "Schedule") != null);
    try testing.expect(std.mem.indexOf(u8, out, "interval 300s") != null);

    step(&s, .esc);
    try testing.expect(s.detail == null);
}

test "detail pane shows no schedule label for a run-at-load service" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const rows = [_]Row{
        .{ .name = "redis", .state = "running", .auto_start = true, .keg_name = "redis", .schedule = "" },
    };
    var s: State = .{ .items = &rows };
    step(&s, .enter);
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

test "conforms to the tab contract" {
    comptime tab.verify(@This());
}
