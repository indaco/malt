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
};

pub fn title() []const u8 {
    return "Services";
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
/// `x`/`X` stop, `r` restart — reversible, so no confirm guard.
pub fn step(s: *State, key: tab.Key) void {
    switch (key) {
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

/// Pure render: a dim action line on top, then the filtered + scrolled service
/// list below. A pure function of `(state, rect)` so a resize is a re-render.
pub fn render(s: *const State, f: *tab.Frame, r: tab.Rect) void {
    if (r.height == 0) return;
    renderActionLine(f, .{ .row = r.row, .col = r.col, .width = r.width, .height = 1 });
    renderList(s, f, .{ .row = r.row + 1, .col = r.col, .width = r.width, .height = r.height -| 1 });
}

/// The dim action line: the lifecycle keys, so they are discoverable (the global
/// footer carries only the shell-wide keys).
fn renderActionLine(f: *tab.Frame, rect: tab.Rect) void {
    f.moveTo(rect.row, rect.col);
    f.put(color.roleCode(.muted));
    f.putContent(scroll_list.truncate("s: start   x: stop   r: restart", rect.width));
    f.put(color.Style.reset.code());
}

fn renderList(s: *const State, f: *tab.Frame, rect: tab.Rect) void {
    if (rect.height == 0) return;
    const filter = s.chrome.filter.slice();
    const nf = filteredCount(s.items, filter);
    const v = scroll_list.clamp(s.chrome.view, nf, rect.height);

    var fi: usize = 0;
    for (s.items) |svc| {
        if (!matches(svc.name, filter)) continue;
        defer fi += 1;
        if (fi < v.offset) continue;
        const screen = fi - v.offset;
        if (screen >= rect.height) break;
        f.moveTo(rect.row + @as(u16, @intCast(screen)), rect.col);
        // The dot keeps its own colour regardless of selection; the reverse-video
        // selection wraps only the text columns so the two SGRs never tangle.
        const st = statusOf(svc.state);
        f.put(color.roleCode(dotStyle(st)));
        f.put(dotGlyph(st));
        f.put(color.Style.reset.code());
        f.put(" ");
        const selected = fi == v.selected;
        if (selected) f.put(reverse);
        var rb: [256]u8 = undefined;
        f.putContent(scroll_list.truncate(formatRow(&rb, svc), rect.width -| 2)); // 2 cols spent on the dot
        if (selected) f.put(color.Style.reset.code());
    }
}

// SGR reverse-video for the selection, matching the other tabs' convention.
const reverse = "\x1b[7m";

/// One list row (after the dot): the name, the runtime state, the auto-start
/// hint, then the owning keg. ASCII columns, grapheme-naive like the rest.
fn formatRow(buf: []u8, s: Row) []const u8 {
    var len: usize = 0;
    appendPad(buf, &len, s.name, 24);
    append(buf, &len, " ");
    appendPad(buf, &len, s.state, 12);
    append(buf, &len, " ");
    appendPad(buf, &len, if (s.auto_start) "auto" else "manual", 8);
    append(buf, &len, s.keg_name);
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

const sample = [_]Row{
    .{ .name = "redis", .state = "running", .auto_start = true, .keg_name = "redis" },
    .{ .name = "postgresql", .state = "stopped", .auto_start = false, .keg_name = "postgresql@16" },
    .{ .name = "dnsmasq", .state = "not-loaded", .auto_start = true, .keg_name = "dnsmasq" },
    .{ .name = "weird", .state = "degraded", .auto_start = false, .keg_name = "weird" },
};

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
    try testing.expect(std.mem.indexOf(u8, f.slice(), reverse) != null);
}

test "render shows the lifecycle action line" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "start") != null);
    try testing.expect(std.mem.indexOf(u8, out, "restart") != null);
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

test "render on an empty list is a clean no-crash frame" {
    var buf: [1024]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &.{} };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 12 }); // must not trap
}

test "render clamps to a height of one (action line only) without crashing" {
    var buf: [1024]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 1 }); // no list rows fit
}

test "conforms to the tab contract" {
    comptime tab.verify(@This());
}
