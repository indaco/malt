//! malt — Doctor tab for `mt tui`: the health-check pane.
//!
//! Leaf module. Pure cores only: `step(state, key)` records a fix intent as a
//! `request` for the impure shell to delegate to the real `mt doctor --fix
//! <class>`; `render(state, frame, rect)` is a pure function of `(state, rect)`
//! so a resize is a re-render. The shell owns the finding data; `items` borrow
//! from that storage. Findings are shown severity-first (errors, then warnings,
//! then ok) for scan-ability, each with a local `✓`/`⚠`/`✗` glyph — the mapping
//! is **replicated** here, never imported from `cli/doctor/render.zig` (the leaf
//! rule). `f` fixes the selected finding, but **only** when it is `fixable`; the
//! token sent is its `fix_class`, the only thing `mt doctor --fix` resolves.

const std = @import("std");
const testing = std.testing;

const color = @import("../ui/color.zig");
const doctor_json = @import("json/doctor.zig");
pub const Row = doctor_json.Finding;
const Severity = doctor_json.Severity;
const detail_pane = @import("detail_pane.zig");
const scroll_list = @import("scroll_list.zig");
const tab = @import("tab.zig");

/// A fix effect the pure `step` defers to the impure shell, which performs it and
/// resets the field. `step` never does I/O — this is the command channel.
pub const Request = enum { none, fix };

pub const State = struct {
    chrome: tab.Chrome = .{},
    /// Findings, borrowed from shell-owned parse storage.
    items: []const Row = &.{},
    /// Pending fix effect for the shell to perform, then clear.
    request: Request = .none,
};

pub fn title() []const u8 {
    return "Doctor";
}

/// The tab's action keys, surfaced in the shared footer next to the global keys.
pub fn footerHint() []const u8 {
    return "f: fix";
}

/// Case-insensitive substring match of `filter` against a finding `title`. An
/// empty filter matches everything.
pub fn matches(name: []const u8, filter: []const u8) bool {
    return filter.len == 0 or std.ascii.indexOfIgnoreCase(name, filter) != null;
}

/// Display order: errors first, then warnings, then ok — the scan-ability sort.
/// Both the selection mapping and the renderer walk findings in this order so a
/// cursor lands on exactly the row painted at that screen position.
const severity_order = [_]Severity{ .err, .warn, .ok };

fn filteredCount(items: []const Row, filter: []const u8) usize {
    var n: usize = 0;
    for (items) |fnd| {
        if (matches(fnd.title, filter)) n += 1;
    }
    return n;
}

/// The `n`-th finding in filtered, severity-ordered display order, or null when
/// `n` is past the end. The single source of the display order, shared by the
/// selection and the renderer.
fn orderedNth(items: []const Row, filter: []const u8, n: usize) ?Row {
    var i: usize = 0;
    for (severity_order) |sev| {
        for (items) |fnd| {
            if (fnd.severity != sev) continue;
            if (!matches(fnd.title, filter)) continue;
            if (i == n) return fnd;
            i += 1;
        }
    }
    return null;
}

/// The finding the selection points at, after applying the filter and clamping
/// the (shell-driven, unbounded) selection into the filtered, severity-ordered
/// list. The shell reads its `fix_class` to build `mt doctor --fix <class>`.
pub fn selectedFinding(s: *const State) ?Row {
    const filter = s.chrome.filter.slice();
    const nf = filteredCount(s.items, filter);
    if (nf == 0) return null;
    const sel = @min(s.chrome.view.selected, nf - 1);
    return orderedNth(s.items, filter, sel);
}

/// Pure transition: `f` records a fix intent for the shell — but only when the
/// selected finding is `fixable`. A non-fixable finding's `f` is inert.
pub fn step(s: *State, key: tab.Key) void {
    switch (key) {
        .char => |c| if (c.len == 1 and c.bytes[0] == 'f') {
            const sel = selectedFinding(s) orelse return;
            if (sel.fixable) s.request = .fix;
        },
        else => {},
    }
}

/// Local severity → glyph mapping, replicated from the CLI doctor renderer (the
/// leaf rule forbids importing it). Exhaustive `switch`, no `else`, so a new
/// `Severity` is a compile error here.
fn glyph(sev: Severity) []const u8 {
    return switch (sev) {
        .ok => "✓",
        .warn => "⚠",
        .err => "✗",
    };
}

fn glyphStyle(sev: Severity) color.Role {
    return switch (sev) {
        .ok => .success,
        .warn => .warning,
        .err => .danger,
    };
}

fn severityLabel(sev: Severity) []const u8 {
    return switch (sev) {
        .ok => "ok",
        .warn => "warning",
        .err => "error",
    };
}

// Bottom-pane budget: severity + fix + detail fit in three rows; the split never
// takes more than half the content so the list always survives.
const detail_rows: u16 = 3;

// SGR reverse-video for the selection, matching the other tabs' convention.
const reverse = "\x1b[7m";

/// Pure render: the severity-ordered finding list and a detail pane for the
/// selected finding. The `f: fix` key lives in the shared footer (the detail
/// pane still shows whether the selected finding is fixable). A pure function of
/// `(state, rect)` so a resize is a re-render.
pub fn render(s: *const State, f: *tab.Frame, r: tab.Rect) void {
    if (r.height == 0) return;
    const sel = selectedFinding(s);
    var content: tab.Rect = r;
    if (sel) |fnd| {
        const dh = @min(@as(u16, detail_rows), content.height / 2);
        if (dh > 0 and dh < content.height) {
            content.height -= dh;
            renderDetail(fnd, f, .{ .row = content.row + content.height, .col = content.col, .width = content.width, .height = dh });
        }
    }
    renderList(s, f, content);
}

fn renderList(s: *const State, f: *tab.Frame, rect: tab.Rect) void {
    if (rect.height == 0) return;
    const filter = s.chrome.filter.slice();
    const nf = filteredCount(s.items, filter);
    if (nf == 0) return tab.renderHint(f, rect, if (filter.len != 0) "No matches." else "No findings.");
    const v = scroll_list.clamp(s.chrome.view, nf, rect.height);

    var di: usize = 0;
    for (severity_order) |sev| {
        for (s.items) |fnd| {
            if (fnd.severity != sev) continue;
            if (!matches(fnd.title, filter)) continue;
            defer di += 1;
            if (di < v.offset) continue;
            const screen = di - v.offset;
            if (screen >= rect.height) return; // viewport full
            f.moveTo(rect.row + @as(u16, @intCast(screen)), rect.col);
            // The glyph keeps its own colour regardless of selection; the
            // reverse-video selection wraps only the title so the SGRs don't tangle.
            f.put(color.roleCode(glyphStyle(fnd.severity)));
            f.put(glyph(fnd.severity));
            f.put(color.Style.reset.code());
            f.put(" ");
            const selected = di == v.selected;
            if (selected) f.put(reverse);
            f.putContent(scroll_list.truncate(fnd.title, rect.width -| 2)); // 2 cols spent on the glyph
            if (selected) f.put(color.Style.reset.code());
        }
    }
}

fn renderDetail(fnd: Row, f: *tab.Frame, rect: tab.Rect) void {
    var fix_buf: [96]u8 = undefined;
    const fix_value = if (fnd.fixable)
        std.fmt.bufPrint(&fix_buf, "f → mt doctor --fix {s}", .{doctor_json.fixClassTag(fnd.fix_class)}) catch "f: fix"
    else
        "not auto-fixable";
    const fields = [_]detail_pane.Field{
        .{ .label = "Severity", .value = severityLabel(fnd.severity) },
        .{ .label = "Fix", .value = fix_value },
        .{ .label = "Detail", .value = if (fnd.detail.len != 0) fnd.detail else "-" },
    };
    detail_pane.render(f, &fields, rect);
}

// ─── tests ───────────────────────────────────────────────────────────

fn ch(c: u8) tab.Key {
    return .{ .char = .{ .bytes = .{ c, 0, 0, 0 }, .len = 1 } };
}

const sample = [_]Row{
    .{ .id = "malt_prefix", .severity = .ok, .title = "MALT_PREFIX", .detail = "/opt/malt (default)", .fixable = false, .fix_class = .none },
    .{ .id = "orphaned_store_entries", .severity = .warn, .title = "Orphaned store entries", .detail = "3 orphaned entries", .fixable = true, .fix_class = .orphaned_store },
    .{ .id = "sqlite_integrity", .severity = .err, .title = "SQLite integrity", .detail = "database malformed", .fixable = false, .fix_class = .none },
    .{ .id = "stale_lock", .severity = .warn, .title = "Stale lock", .detail = "dead PID 42", .fixable = true, .fix_class = .stale_lock },
};

test "matches is a case-insensitive substring; empty filter matches all" {
    try testing.expect(matches("SQLite integrity", ""));
    try testing.expect(matches("SQLite integrity", "sqlite"));
    try testing.expect(!matches("Stale lock", "zzz"));
}

test "selectedFinding orders by severity (err, then warn, then ok) and clamps" {
    var s: State = .{ .items = &sample };
    // Display order: sqlite (err), orphaned (warn), stale_lock (warn), malt_prefix (ok).
    s.chrome.view.selected = 0;
    try testing.expectEqualStrings("sqlite_integrity", selectedFinding(&s).?.id);
    s.chrome.view.selected = 1;
    try testing.expectEqualStrings("orphaned_store_entries", selectedFinding(&s).?.id);
    s.chrome.view.selected = 3;
    try testing.expectEqualStrings("malt_prefix", selectedFinding(&s).?.id);
    s.chrome.view.selected = 99; // clamps to the last ordered row
    try testing.expectEqualStrings("malt_prefix", selectedFinding(&s).?.id);
}

test "selectedFinding keeps input order within a severity bucket (stable sort)" {
    var s: State = .{ .items = &sample };
    // The two warnings keep their input order: orphaned (idx 1) before stale_lock (idx 3).
    s.chrome.view.selected = 1;
    try testing.expectEqualStrings("orphaned_store_entries", selectedFinding(&s).?.id);
    s.chrome.view.selected = 2;
    try testing.expectEqualStrings("stale_lock", selectedFinding(&s).?.id);
}

test "selectedFinding maps the cursor through the filter" {
    var s: State = .{ .items = &sample };
    s.chrome.filter.push("lock"); // only "Stale lock" matches
    s.chrome.view.selected = 0;
    try testing.expectEqualStrings("stale_lock", selectedFinding(&s).?.id);
}

test "selectedFinding on an empty list is null" {
    const s: State = .{ .items = &.{} };
    try testing.expect(selectedFinding(&s) == null);
}

test "f on a fixable finding requests a fix" {
    var s: State = .{ .items = &sample };
    s.chrome.view.selected = 1; // orphaned_store_entries — fixable
    step(&s, ch('f'));
    try testing.expectEqual(Request.fix, s.request);
}

test "f on a non-fixable finding is inert" {
    var s: State = .{ .items = &sample };
    s.chrome.view.selected = 0; // sqlite_integrity — not fixable
    step(&s, ch('f'));
    try testing.expectEqual(Request.none, s.request);
}

test "an unrelated key leaves the request alone" {
    var s: State = .{ .items = &sample };
    s.chrome.view.selected = 1;
    step(&s, ch('z'));
    try testing.expectEqual(Request.none, s.request);
    step(&s, .enter);
    try testing.expectEqual(Request.none, s.request);
}

test "render lists findings with a severity glyph and title" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample };
    render(&s, &f, .{ .row = 2, .col = 1, .width = 80, .height = 16 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "SQLite integrity") != null);
    try testing.expect(std.mem.indexOf(u8, out, "✗") != null); // err glyph
    try testing.expect(std.mem.indexOf(u8, out, "⚠") != null); // warn glyph
    try testing.expect(std.mem.indexOf(u8, out, "✓") != null); // ok glyph
    try testing.expect(std.mem.indexOf(u8, out, color.Style.red.code()) != null);
    try testing.expect(std.mem.indexOf(u8, out, color.Style.yellow.code()) != null);
    try testing.expect(std.mem.indexOf(u8, out, color.Style.green.code()) != null);
}

test "render groups errors above ok findings for scan-ability" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 16 });
    const out = f.slice();
    const err_at = std.mem.indexOf(u8, out, "SQLite integrity").?;
    const ok_at = std.mem.indexOf(u8, out, "MALT_PREFIX").?;
    try testing.expect(err_at < ok_at); // the err finding paints before the ok one
}

test "selecting a finding shows its detail" {
    var buf: [8192]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var s: State = .{ .items = &sample };
    s.chrome.view.selected = 1; // orphaned_store_entries
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 20 });
    try testing.expect(std.mem.indexOf(u8, f.slice(), "3 orphaned entries") != null);
}

test "a fixable selection spells out the delegated fix in the detail pane" {
    var buf: [8192]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var s: State = .{ .items = &sample };
    s.chrome.view.selected = 1; // fixable
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 20 });
    // The detail pane names the exact delegated command, with the class token;
    // the `f` key itself now lives in the shared footer, not the tab body.
    try testing.expect(std.mem.indexOf(u8, f.slice(), "mt doctor --fix orphaned_store") != null);
}

test "footerHint exposes the fix key for the shared footer" {
    try testing.expect(std.mem.indexOf(u8, footerHint(), "f: fix") != null);
}

test "a non-fixable selection shows guidance, not the f key" {
    var buf: [8192]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var s: State = .{ .items = &sample };
    s.chrome.view.selected = 0; // sqlite_integrity — not fixable
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 20 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "f: fix") == null); // no fix key
    try testing.expect(std.mem.indexOf(u8, out, "not auto-fixable") != null); // guidance
}

test "render highlights the selected row" {
    var buf: [8192]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var s: State = .{ .items = &sample };
    s.chrome.view.selected = 0;
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 16 });
    try testing.expect(std.mem.indexOf(u8, f.slice(), reverse) != null);
}

test "render narrows to the filter" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var s: State = .{ .items = &sample };
    s.chrome.filter.push("lock");
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 16 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "Stale lock") != null);
    try testing.expect(std.mem.indexOf(u8, out, "SQLite integrity") == null); // filtered out
}

test "render reflows: the same state at two widths differs" {
    var a: [8192]u8 = undefined;
    var b: [8192]u8 = undefined;
    var fa: tab.Frame = .{ .buf = &a };
    var fb: tab.Frame = .{ .buf = &b };
    const s: State = .{ .items = &sample };
    render(&s, &fa, .{ .row = 1, .col = 1, .width = 80, .height = 16 });
    render(&s, &fb, .{ .row = 1, .col = 1, .width = 30, .height = 6 });
    try testing.expect(!std.mem.eql(u8, fa.slice(), fb.slice()));
}

test "a hostile finding title cannot inject a control sequence into the frame" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const evil = [_]Row{.{ .id = "x", .severity = .err, .title = "ev\x1b]0;pwn\x07il", .detail = "d" }};
    const s: State = .{ .items = &evil };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 16 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "\x1b]0;pwn") == null); // OSC introducer broken
    try testing.expect(std.mem.indexOfScalar(u8, out, 0x07) == null); // BEL dropped
}

test "render on an empty list shows the no-findings placeholder, not a blank pane" {
    var buf: [1024]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &.{} };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 16 }); // must not trap
    try std.testing.expect(std.mem.indexOf(u8, f.slice(), "No findings") != null);
}

test "render clamps to a height of one without crashing" {
    var buf: [1024]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 1 }); // no list rows fit
}

test "conforms to the tab contract" {
    comptime tab.verify(@This());
}
