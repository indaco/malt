//! malt — Installed tab for `mt tui`: the first data-bearing pane.
//!
//! Leaf module. Pure cores only: `step(state, key)` records the user's intent as
//! a `request` for the impure shell to perform (read `mt info`, re-exec
//! `mt uninstall`), and `render(state, frame, rect)` is a pure function of
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
const detail_pane = @import("detail_pane.zig");
const scroll_list = @import("scroll_list.zig");
const list_json = @import("json/list.zig");
const info_json = @import("json/info.zig");
const color = @import("../ui/color.zig");

pub const Pkg = list_json.Pkg;

/// An effect the pure `step` defers to the impure shell, which performs it and
/// resets the field. `step` never does I/O — this is the command channel.
/// `uninstall` carries the guard's latched target so the shell never re-derives
/// it from a selection that may have moved since the guard was armed.
pub const Request = union(enum) { none, open_detail, uninstall: ConfirmTarget };

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
    /// Pending effect for the shell to perform, then clear.
    request: Request = .none,
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

/// Pure transition: record the user's intent for the shell to act on. While the
/// guard is up, the next key resolves it.
pub fn step(s: *State, key: tab.Key) void {
    if (s.confirm_uninstall != null) return resolveGuard(s, key);
    switch (key) {
        .enter => s.request = .open_detail,
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
}

/// `y` confirms (request the real `mt uninstall` of the latched target); every
/// other key — `n`, Esc, Enter — cancels. A fat-finger gate, not a typed-confirm.
fn resolveGuard(s: *State, key: tab.Key) void {
    switch (key) {
        .char => |c| if (c.len == 1 and (c.bytes[0] == 'y' or c.bytes[0] == 'Y')) {
            s.request = .{ .uninstall = s.confirm_uninstall.? };
        },
        else => {},
    }
    s.confirm_uninstall = null;
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
            .{ .label = "Size", .value = humanSize(&size_buf, d.pkg.size_bytes) },
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
    const nf = filteredCount(s.items, filter);
    if (nf == 0) return tab.renderHint(f, rect, if (filter.len != 0) "No matches." else "No packages installed yet.");
    // A fixed bold heading rides above the list and costs it one row.
    tab.renderHeading(f, rect, 0, &.{
        .{ .label = "NAME", .width = 22 },
        .{ .label = "VERSION", .width = 14 },
        .{ .label = "SIZE", .width = 10 },
    });
    const list: tab.Rect = .{ .row = rect.row + 1, .col = rect.col, .width = rect.width, .height = rect.height -| 1 };
    if (list.height == 0) return; // the heading took the only row
    const v = scroll_list.clamp(s.chrome.view, nf, list.height);

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

/// One list row: name and version in fixed columns, a humanized size, then the
/// pinned / unlinked markers. ASCII columns, grapheme-naive like the rest.
fn formatRow(buf: []u8, p: Pkg) []const u8 {
    var len: usize = 0;
    appendPad(buf, &len, p.name, 22);
    append(buf, &len, " ");
    appendPad(buf, &len, p.version, 14);
    append(buf, &len, " ");
    var size_buf: [16]u8 = undefined;
    appendPad(buf, &len, humanSize(&size_buf, p.size_bytes), 10);
    if (p.pinned) append(buf, &len, " pinned");
    if (p.linked) |l| {
        if (!l) append(buf, &len, " unlinked");
    }
    return buf[0..len];
}

/// Bytes → "1.8 MB". Null (no `--size`) renders as "-".
fn humanSize(buf: []u8, bytes: ?u64) []const u8 {
    const b = bytes orelse return "-";
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var v: f64 = @floatFromInt(b);
    var u: usize = 0;
    while (v >= 1024.0 and u + 1 < units.len) : (u += 1) v /= 1024.0;
    if (u == 0) return std.fmt.bufPrint(buf, "{d} B", .{b}) catch "-";
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[u] }) catch "-";
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

const testing = std.testing;

fn ch(c: u8) tab.Key {
    return .{ .char = .{ .bytes = .{ c, 0, 0, 0 }, .len = 1 } };
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
    step(&s, .end);
    try testing.expectEqual(@as(usize, 3), s.chrome.view.selected);

    s.chrome.filter.push("f"); // ffmpeg, flux
    step(&s, .end);
    try testing.expectEqual(@as(usize, 1), s.chrome.view.selected);

    var e: State = .{ .items = &.{} };
    step(&e, .end);
    try testing.expectEqual(@as(usize, 0), e.chrome.view.selected);
}

test "Enter requests the detail effect for the shell to perform" {
    var s: State = .{ .items = &sample };
    step(&s, .enter);
    try testing.expect(s.request == .open_detail);
}

test "Esc closes an open detail pane" {
    var s: State = .{ .items = &sample, .detail = .{ .pkg = sample[0], .info = .{} } };
    step(&s, .esc);
    try testing.expect(s.detail == null);
}

test "x raises the uninstall guard without spawning anything" {
    var s: State = .{ .items = &sample };
    step(&s, ch('x'));
    try testing.expect(s.confirm_uninstall != null);
    try testing.expectEqualStrings("brotli", s.confirm_uninstall.?.name()); // latched at arm time
    try testing.expect(s.request == .none); // no spawn yet
}

test "y confirms the guard: requests uninstall of the latched name and lowers the guard" {
    var s: State = .{ .items = &sample };
    step(&s, ch('x'));
    step(&s, ch('y'));
    try testing.expect(s.request == .uninstall);
    try testing.expectEqualStrings("brotli", s.request.uninstall.name());
    try testing.expect(s.confirm_uninstall == null);
}

test "n and Esc cancel the guard with no request" {
    var s: State = .{ .items = &sample };
    step(&s, ch('x'));
    step(&s, ch('n'));
    try testing.expect(s.confirm_uninstall == null);
    try testing.expect(s.request == .none);

    step(&s, ch('x'));
    step(&s, .esc);
    try testing.expect(s.confirm_uninstall == null);
    try testing.expect(s.request == .none);
}

test "arming latches the target: moving the selection cannot retarget the confirm" {
    var s: State = .{ .items = &sample };
    step(&s, ch('x')); // arm on brotli (row 0)
    s.chrome.view.selected = 2; // the shell moved the selection to ffmpeg
    step(&s, ch('y'));
    try testing.expect(s.request == .uninstall);
    try testing.expectEqualStrings("brotli", s.request.uninstall.name());
}

test "a list reloaded while the guard is up cannot retarget the latched confirm" {
    var s: State = .{ .items = &sample };
    step(&s, ch('x')); // arm on brotli (row 0)
    // A dirty-tab refetch swaps the rows with no keypress; the latch must hold.
    const reloaded = [_]Pkg{sample[2]}; // ffmpeg is now row 0
    s.items = &reloaded;
    step(&s, ch('y'));
    try testing.expect(s.request == .uninstall);
    try testing.expectEqualStrings("brotli", s.request.uninstall.name());
}

test "uppercase Y confirms the guard like y" {
    var s: State = .{ .items = &sample };
    step(&s, ch('x'));
    step(&s, ch('Y'));
    try testing.expect(s.request == .uninstall);
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
    step(&s, ch('x'));
    try testing.expect(s.confirm_uninstall == null);

    var t: State = .{ .items = &sample };
    t.chrome.filter.push("zzznomatch");
    step(&t, ch('x'));
    try testing.expect(t.confirm_uninstall == null);
}

test "the guard banner names the latched package even after the selection moved" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var s: State = .{ .items = &sample };
    s.chrome.view.selected = 1; // curl
    step(&s, ch('x')); // arm on curl
    s.chrome.view.selected = 2; // selection moved to ffmpeg
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 10 });
    try testing.expect(std.mem.indexOf(u8, f.slice(), "Uninstall curl? [y/N]") != null);
}

test "while the guard is up, x's domain keys do not re-arm or leak" {
    var s: State = .{ .items = &sample };
    step(&s, ch('x'));
    step(&s, .enter); // Enter is "default No" — cancels, no detail request
    try testing.expect(s.confirm_uninstall == null);
    try testing.expect(s.request == .none);
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
    step(&s, ch('x')); // arm through the real transition so the target latches
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
