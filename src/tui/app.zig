//! malt — `mt tui` app shell: event loop, tab dispatch, filter, rendering.
//!
//! Leaf module. The pure cores — `step(app, key) -> app` and
//! `renderFrame(buf, app, cols, rows) -> bytes` — are The Elm Architecture and
//! are unit-tested without a PTY. `run` is the only impure part: it owns the
//! terminal lifecycle (raw mode + alt-screen + hidden cursor, each undone by an
//! `errdefer` restore), refuses to launch on a non-interactive terminal, and
//! drives the read→decode→step→repaint loop. A `SIGWINCH` re-renders from cached
//! state with no keypress. The TUI module is referenced only from the lazy
//! `mt tui` dispatch arm, so non-`tui` commands pay no cold-start cost.

const std = @import("std");
const color = @import("../ui/color.zig");
const term_sanitize = @import("../ui/term_sanitize.zig");
const spinner_frames = @import("../ui/spinner_frames.zig");
const tab = @import("tab.zig");
const tab_bar = @import("tab_bar.zig");
const header = @import("header.zig");
const filter_input = @import("filter_input.zig");
const keys = @import("keys.zig");
const term = @import("term.zig");
const layout = @import("layout.zig");
const scroll_list = @import("scroll_list.zig");
const text_wrap = @import("text_wrap.zig");

const spawn = @import("spawn.zig");
const list_json = @import("json/list.zig");
const info_json = @import("json/info.zig");
const outdated_json = @import("json/outdated.zig");
const services_json = @import("json/services.zig");
const doctor_json = @import("json/doctor.zig");
const search_json = @import("json/search.zig");

const installed = @import("installed_tab.zig");
const outdated = @import("outdated_tab.zig");
const services = @import("services_tab.zig");
const doctor = @import("doctor_tab.zig");
const search = @import("search_tab.zig");

const Tab = tab_bar.Tab;
const Key = keys.Key;

/// Every tab's state, all present at once so a tab switch preserves each one's
/// filter / scroll / data. Field names match `Tab` tags for `@field` dispatch.
const TabStates = struct {
    installed: installed.State = .{},
    outdated: outdated.State = .{},
    services: services.State = .{},
    doctor: doctor.State = .{},
    search: search.State = .{},
};

/// Map a tab tag to its module at comptime — the vtable-free dispatch core.
fn moduleFor(comptime t: Tab) type {
    return switch (t) {
        .installed => installed,
        .outdated => outdated,
        .services => services,
        .doctor => doctor,
        .search => search,
    };
}

// Every tab must satisfy the contract; a non-conforming one is a build error.
comptime {
    for (@typeInfo(Tab).@"enum".fields) |fld| {
        tab.verify(moduleFor(@field(Tab, fld.name)));
    }
}

/// A pure step jump for paging — the viewport height is unknown to a pure
/// `step`, so a fixed page is the data-agnostic approximation; the render's
/// `scroll_list.clamp` still bounds it to the real list.
const page_step = 10;

/// Cap on the recoverable-error banner. An op label + an error name fit well
/// inside this; the cap keeps the buffer fixed so the banner never allocates.
pub const banner_max = 160;

/// A transient banner for a recoverable backend failure, shown in the footer.
/// Fixed buffer, no allocation, like the filter. Set when a delegated op fails
/// recoverably, cleared on the next keypress (`step`). The message is run
/// through `term_sanitize` at set-time because the op label may carry a
/// child-derived package name — the leaf's untrusted-input rule.
pub const Banner = struct {
    buf: [banner_max]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Banner) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn isSet(self: *const Banner) bool {
        return self.len != 0;
    }

    pub fn clear(self: *Banner) void {
        self.len = 0;
    }

    /// Format "<op>: <reason>" into the fixed buffer, run through `term_sanitize`
    /// so a child-derived package name in `op` cannot inject escape sequences.
    /// Truncated at the cap; the footer render also strips line-breakers the
    /// sanitizer lets through (`putContent`).
    pub fn set(self: *Banner, op: []const u8, reason: []const u8) void {
        self.len = 0;
        var san = term_sanitize.Sanitizer.init();
        const sink: term_sanitize.Sink = .{ .ctx = self, .write_fn = appendSink };
        // The buffered sink never fails — it truncates at the cap — so the
        // sanitizer's propagated error cannot occur here; ignore it deliberately.
        san.feed(op, sink) catch {};
        san.feed(": ", sink) catch {};
        san.feed(reason, sink) catch {};
        san.flush(sink) catch {};
    }

    /// `term_sanitize.Sink` callback: append clean bytes, bounded by the cap.
    /// `@ptrCast` is the sink's `*anyopaque` → `*Banner` round-trip; the ctx was
    /// set from a `*Banner` just above, so the cast is sound.
    fn appendSink(ctx: *anyopaque, bytes: []const u8) term_sanitize.SinkError!void {
        const self: *Banner = @ptrCast(@alignCast(ctx));
        const n = @min(bytes.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], bytes[0..n]);
        self.len += n;
    }
};

pub const App = struct {
    active: Tab = .search,
    editing: bool = false,
    quit: bool = false,
    states: TabStates = .{},
    /// Tabs whose data may be stale after a delegated mutation. Lazy per-tab: a
    /// dirty tab refetches its `--json` only when entered (README open question
    /// #4), so an unrelated mutation never pays for a tab the user isn't viewing.
    dirty: std.EnumSet(Tab) = .initEmpty(),
    /// Resolved self-exe path injected by the `main.zig` bridge so the data and
    /// action tabs re-exec *this* `mt` (not whatever PATH resolves) for reads
    /// and mutations.
    mt_path: []const u8 = "",
    /// A transient banner for the last recoverable backend failure. Shown in the
    /// footer, dismissed on the next keypress (`step`); a successful action just
    /// leaves it cleared.
    banner: Banner = .{},
    /// Set while a lazy tab refetches so the footer shows the loading status.
    /// The polled read keeps it set across its poll loop and clears it after, so
    /// the spinner animates while the child runs and the result replaces it.
    loading: bool = false,
    /// Tabs whose payload is being fetched in the background, so the input loop
    /// stays live while a slow audit runs. Drives the working-indicator (spinner)
    /// on the header `outdated` slot and on the active tab's footer, instead of a
    /// frozen frame. Distinct from `loading` (a synchronous, blocking refetch).
    tab_loading: std.EnumSet(Tab) = .initEmpty(),
    /// Spinner animation index, advanced one frame per poll tick while a lazy
    /// read is in flight (mirrors `progress.zig`). Lives on `App` so `renderFrame`
    /// stays a pure function of `(state, cols, rows)`: the glyph is
    /// `frames[spinner_frame % count]`, deterministic per state, so a resize
    /// re-renders the same frame. Wraps freely (`+%=`); only its modulus matters.
    spinner_frame: u8 = 0,
    /// Header inputs. `version` (comptime) and `prefix` (env-resolved) are set
    /// once in `run`; the counts mirror the loaded stores and stay null until
    /// each store loads, so the header shows a placeholder rather than a wrong
    /// number.
    version: []const u8 = "",
    prefix: []const u8 = "",
    installed_count: ?usize = null,
    outdated_count: ?usize = null,
};

/// After a delegated mutation the active tab was just re-read inline, so it is
/// fresh; the others may now be stale. Mark them dirty — a dirty tab refetches
/// only when entered (`takeDirty`), so the cost is paid lazily, on view.
pub fn markStaleAfterMutation(a: *App) void {
    a.dirty = std.EnumSet(Tab).initFull();
    a.dirty.remove(a.active);
}

/// Mark every data tab dirty at launch so each loads lazily on first entry.
/// Search is the active tab and renders without data, so launch never blocks on
/// a child read — the load cost is paid on view, behind `paintLoading`.
fn initLaunchDirty(a: *App) void {
    a.dirty.insert(.installed);
    a.dirty.insert(.outdated);
    a.dirty.insert(.services);
    a.dirty.insert(.doctor);
}

/// Consume `t`'s dirty flag: true exactly once after it was marked, so the
/// caller refetches its `--json` at most once per staleness.
pub fn takeDirty(a: *App, t: Tab) bool {
    if (!a.dirty.contains(t)) return false;
    a.dirty.remove(t);
    return true;
}

fn activeChrome(a: *App) *tab.Chrome {
    switch (a.active) {
        inline else => |t| return &@field(a.states, @tagName(t)).chrome,
    }
}

fn activeFilterText(a: *const App) []const u8 {
    switch (a.active) {
        inline else => |t| return @field(a.states, @tagName(t)).chrome.filter.slice(),
    }
}

/// The input-box label for the active tab: on Search the box is the query, not a
/// filter over an already-loaded list, so it says so.
fn activeFilterLabel(a: *const App) []const u8 {
    return if (a.active == .search) "search: " else "filter: ";
}

fn routeToTab(a: *App, key: Key) void {
    switch (a.active) {
        inline else => |t| moduleFor(t).step(&@field(a.states, @tagName(t)), key),
    }
}

fn renderActive(a: *const App, f: *tab.Frame, rect: tab.Rect) void {
    switch (a.active) {
        inline else => |t| moduleFor(t).render(&@field(a.states, @tagName(t)), f, rect),
    }
}

fn activeFooterHint(a: *const App) []const u8 {
    switch (a.active) {
        inline else => |t| return moduleFor(t).footerHint(),
    }
}

fn activeTitle(a: *const App) []const u8 {
    switch (a.active) {
        inline else => |t| return moduleFor(t).title(),
    }
}

fn tabTitles() [tab_bar.count][]const u8 {
    var t: [tab_bar.count][]const u8 = undefined;
    inline for (@typeInfo(Tab).@"enum".fields, 0..) |fld, i| {
        t[i] = moduleFor(@field(Tab, fld.name)).title();
    }
    return t;
}

/// Pure transition: keys split between filter editing and normal navigation;
/// keys the shell does not own fall through to the active tab.
pub fn step(app: App, key: Key) App {
    var a = app;
    a.banner.clear(); // a keypress dismisses the prior transient error banner
    if (a.editing) stepFilter(&a, key) else stepNormal(&a, key);
    return a;
}

fn stepFilter(a: *App, key: Key) void {
    switch (key) {
        .char => |c| activeChrome(a).filter.push(c.slice()),
        .backspace => activeChrome(a).filter.backspace(),
        .enter => { // commit, keep the filter
            a.editing = false;
            // Search divergence: its filter doubles as the search box, so
            // committing the query *is* the search. Set the request directly
            // rather than routing Enter to the tab, whose Enter now means "open
            // info" — every other tab's filter just narrows a loaded list.
            if (a.active == .search) a.states.search.request = .search;
        },
        .esc => { // cancel: clear the filter
            activeChrome(a).filter.clear();
            a.editing = false;
        },
        .ctrl_c => a.quit = true, // always escapes, even mid-edit
        .up, .down, .left, .right, .space, .tab, .page_up, .page_down, .home, .end, .unknown => {},
    }
}

fn stepNormal(a: *App, key: Key) void {
    switch (key) {
        .ctrl_c => a.quit = true,
        .tab, .right => a.active = tab_bar.next(a.active),
        .left => a.active = tab_bar.prev(a.active),
        .up => activeChrome(a).view.selected -|= 1,
        .down => activeChrome(a).view.selected += 1,
        .page_up => activeChrome(a).view.selected -|= page_step,
        .page_down => activeChrome(a).view.selected += page_step,
        .home => activeChrome(a).view.selected = 0,
        .char => |c| {
            if (c.len == 1) switch (c.bytes[0]) {
                'q' => {
                    a.quit = true;
                    return;
                },
                '/' => {
                    a.editing = true;
                    return;
                },
                '1'...'5' => {
                    if (tab_bar.fromDigit(c.bytes[0])) |t| a.active = t;
                    return;
                },
                else => {},
            };
            routeToTab(a, key); // a domain key (e.g. u/f) belongs to the tab
        },
        .enter => {
            // On Search, Enter focuses the query box when there are no results
            // yet (so the user can type), and opens info for the active hit once
            // results are loaded. Every other tab uses Enter as a domain key.
            if (a.active == .search and a.states.search.items.len == 0) {
                a.editing = true;
            } else routeToTab(a, key);
        },
        .space, .end, .esc => routeToTab(a, key),
        // `end` needs the row count to land on the last row — deferred to the
        // data tab; Esc routes so a tab can close a pane / cancel its guard;
        // `backspace`/`unknown` are inert outside edit mode.
        .backspace, .unknown => {},
    }
}

/// Pure render: full-screen clear, then each region painted at its cursor
/// position. A frame carries no raw newline — positioning is by cursor moves —
/// so `(state, cols, rows)` fully determines the bytes and resize is a re-render.
pub fn renderFrame(buf: []u8, app: *const App, cols: u16, rows: u16) []const u8 {
    var f: tab.Frame = .{ .buf = buf };
    f.put("\x1b[2J"); // clear; every region then positions its own cursor
    switch (layout.compute(cols, rows)) {
        .too_small => renderTooSmall(&f, cols, rows),
        .ok => |r| {
            f.moveTo(r.header.row, 1);
            var hdb: [256]u8 = undefined;
            f.put(header.render(&hdb, .{
                .version = app.version,
                .prefix = app.prefix,
                .kegs = app.installed_count,
                .outdated = app.outdated_count,
                // While the outdated audit runs in the background, paint the
                // current spinner frame on the outdated slot. Same glyph source as
                // `loadingLine`, so the working-indicators can never drift;
                // deterministic per state.
                .outdated_spinner = if (app.tab_loading.contains(.outdated))
                    spinner_frames.frames[app.spinner_frame % spinner_frames.count]
                else
                    null,
            }, cols));
            f.put(color.Style.reset.code()); // a truncated muted segment must not bleed downward

            f.moveTo(r.tab_bar.row, 1);
            var tb: [256]u8 = undefined;
            f.put(tab_bar.render(&tb, app.active, tabTitles(), cols));
            f.put(color.Style.reset.code()); // a truncated active title must not bleed bold downward

            f.moveTo(r.filter.row, 1);
            var fb: [filter_input.max_len + 8]u8 = undefined;
            f.put(filter_input.render(&fb, activeFilterLabel(app), activeFilterText(app), app.editing, cols));

            // A dim rule below the filter sets the chrome off from the content on
            // the list tabs. Doctor paints its own rule at the band top, so it is
            // left out here and never shows a doubled rule; the rule costs the tab
            // one content row.
            var body = r.content;
            if (app.active != .doctor) {
                tab.renderSeparator(&f, r.content, r.content.row, true);
                body = .{ .row = r.content.row + 1, .col = r.content.col, .width = r.content.width, .height = r.content.height -| 1 };
            }
            renderActive(app, &f, body);

            // Footer: a rule line separating content, then — by priority — the
            // pre-read loading status, the transient error banner, or the help line.
            // Each wraps across the footer's text rows (below the separator) so a
            // long line keeps its tail on a narrow terminal instead of truncating.
            tab.renderSeparator(&f, r.footer, r.footer.row, false);
            const text_rows = r.footer.height -| 1;
            // The active tab's background fetch reads as Loading in the footer too,
            // so a tab the user navigated *into* mid-audit shows it is still
            // computing — not an empty list that looks done.
            if (app.loading or app.tab_loading.contains(app.active)) {
                var lb: [64]u8 = undefined;
                renderFooterText(&f, loadingLine(&lb, app), color.roleCode(.accent), r.footer.row + 1, text_rows, cols);
            } else if (app.banner.isSet()) {
                // Undimmed + yellow so a recoverable failure reads as a warning, not
                // chrome; the wrap paints through `putContent`, which drops the
                // line-breakers the sanitizer let through.
                renderFooterText(&f, app.banner.slice(), color.roleCode(.warning), r.footer.row + 1, text_rows, cols);
            } else {
                var hb: [256]u8 = undefined;
                renderFooterText(&f, footerLine(&hb, app), color.roleCode(.muted), r.footer.row + 1, text_rows, cols);
            }
        },
    }
    return f.slice();
}

/// The "terminal too small" fallback: the notice icon + message in the info
/// colour, wrapped across rows (positioned with cursor moves, no raw newline) so
/// it stays readable when the terminal is too narrow for one line. Trips on
/// width or height alone — `layout.fits` requires both axes.
fn renderTooSmall(f: *tab.Frame, cols: u16, rows: u16) void {
    if (cols == 0 or rows == 0) return;
    var mbuf: [64]u8 = undefined;
    var buf: [96]u8 = undefined;
    const icon: []const u8 = if (color.isEmojiEnabled()) "ⓘ " else "i ";
    const msg = std.fmt.bufPrint(&buf, "{s}{s}", .{ icon, layout.tooSmallMessage(&mbuf) }) catch "terminal too small";
    var rest = msg;
    var row: u16 = 1;
    while (rest.len > 0 and row <= rows) : (row += 1) {
        var take = @min(@as(usize, cols), rest.len);
        if (take < rest.len) {
            var i = take; // break at the last space that fits, so words stay whole
            while (i > 0) : (i -= 1) {
                if (rest[i - 1] == ' ') {
                    take = i;
                    break;
                }
            }
        }
        f.moveTo(row, 1);
        f.put(color.roleCode(.accent));
        f.putContent(rest[0..take]);
        f.put(color.Style.reset.code());
        rest = rest[take..];
        while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
    }
}

/// Paint `text` wrapped across at most `max_rows` rows from `start_row`, styled
/// with `role`. Each row is positioned by a cursor move (no raw newline) and
/// painted through `putContent` so a child-derived banner can't inject a frame
/// line. Rows past the cap are dropped — truncation only as the last resort
/// below the bound. Shares `text_wrap` with the detail pane, so one wrap rule.
fn renderFooterText(f: *tab.Frame, text: []const u8, role: []const u8, start_row: u16, max_rows: u16, cols: u16) void {
    if (cols == 0 or max_rows == 0) return;
    var it = text_wrap.iter(text, cols);
    var row: u16 = 0;
    while (it.next()) |chunk| : (row += 1) {
        if (row >= max_rows) break;
        f.moveTo(start_row + row, 1);
        f.put(role);
        f.putContent(chunk);
        f.put(color.Style.reset.code());
    }
}

fn loadingLine(buf: []u8, app: *const App) []const u8 {
    // The braille glyph for the current frame, ahead of the text, so a slow load
    // reads as working. Pure over `spinner_frame`, so the frame is deterministic.
    const glyph = spinner_frames.frames[app.spinner_frame % spinner_frames.count];
    return std.fmt.bufPrint(buf, "{s} Loading {s}…", .{ glyph, activeTitle(app) }) catch "Loading…";
}

/// The footer help line: while editing the filter, just the edit keys; otherwise
/// the shell-wide keys first (so quit/switch survive a narrow terminal) then the
/// active tab's action keys. Built into `buf`; falls back to the global keys
/// alone if it can't fit.
fn footerLine(buf: []u8, app: *const App) []const u8 {
    if (app.editing) return footerHelp(true);
    var hb: [96]u8 = undefined;
    const hint = if (app.active == .search)
        searchFooterHint(&hb, app.states.search.view, app.states.search.selected_count)
    else
        activeFooterHint(app);
    return std.fmt.bufPrint(buf, "{s}   ·   {s}", .{ footerHelp(false), hint }) catch footerHelp(false);
}

/// The Search footer hint for the active view, with the live basket count folded
/// in — the shell owns the basket, so it owns the count. `i: install N selected`
/// once a pick is in the basket (also signalling `i` acts on the basket, not the
/// cursor row); the bare view hint when empty. Built into `buf`.
fn searchFooterHint(buf: []u8, view: search.View, selected: usize) []const u8 {
    const base = search.footerHintFor(view);
    if (selected == 0) return base;
    return std.fmt.bufPrint(buf, "{s} {d} selected", .{ base, selected }) catch base;
}

fn footerHelp(editing: bool) []const u8 {
    return if (editing)
        "enter: accept   esc: clear"
    else
        "tab/arrows/1-5: switch   /: filter   q: quit";
}

pub const Refusal = enum { not_a_tty, no_color, ci };

/// Pure launch gate: refuse on a non-interactive terminal instead of degrading
/// (design doc Alt B "ANSI fallback cliff"). Order: a usable terminal first,
/// then the ANSI opt-outs.
pub fn refusalReason(stdin_tty: bool, stdout_tty: bool, no_color: bool, ci: bool) ?Refusal {
    if (!stdin_tty or !stdout_tty) return .not_a_tty;
    if (no_color) return .no_color;
    if (ci) return .ci;
    return null;
}

fn refusalMessage(r: Refusal) []const u8 {
    return switch (r) {
        .not_a_tty => "mt tui: refusing to launch — stdin and stdout must be a terminal.\n",
        .no_color => "mt tui: refusing to launch — NO_COLOR is set; the dashboard needs ANSI.\n",
        .ci => "mt tui: refusing to launch — CI environment detected.\n",
    };
}

pub const RunError = term.TermError || std.mem.Allocator.Error ||
    spawn.ReadError || spawn.InlineError || list_json.Error || info_json.Error ||
    outdated_json.Error || services_json.Error || doctor_json.Error ||
    search_json.Error || error{ReadFailed};

/// How the event loop treats a run-loop error: a `recoverable` backend fault
/// becomes an inline banner and the session keeps running; a `fatal` fault
/// restores the terminal and exits (the TUI-012 crash-safety guarantee).
pub const ErrorClass = enum { recoverable, fatal };

/// Pure, exhaustive classifier over `RunError`. A child-process or parse fault
/// is `recoverable` — proportionate to its cause, the dashboard keeps its tab,
/// selection, and filter. A terminal-integrity or out-of-memory fault is
/// `fatal`. No `else`, so a newly-added error is a compile error until it is
/// deliberately classified — the discipline the `Key`/`Tab` enums use. Note:
/// `ReadFailed` here is the child-pipe drain (recoverable); the controlling-tty
/// read failure never reaches this — it is a direct fatal return in the loop.
pub fn classify(err: RunError) ErrorClass {
    return switch (err) {
        error.SpawnFailed,
        error.WaitFailed,
        error.ChildFailed,
        error.EmptyOutput,
        error.ReadFailed,
        error.BadJson,
        => .recoverable,
        error.NotATty,
        error.WriteFailed,
        error.TermiosFailed,
        error.OutOfMemory,
        => .fatal,
    };
}

/// Mid-load repaint handle for the polled lazy reads: the controlling-tty fd and
/// the (resizable) frame buffer, threaded from `run` to wherever a lazy `loadX`
/// runs so its spinner can repaint without `spawn.zig` knowing about rendering.
const Painter = struct {
    fd: std.posix.fd_t,
    frame: *[]u8,
};

/// The `tick` callback `spawn.readJsonPolled` invokes on every poll timeout while
/// a lazy tab is loading: advance the spinner one frame and repaint. Closes over
/// the paint handle + `App`, so the animation lives here, not in the generic
/// leaf `spawn.zig`.
const LoadTicker = struct {
    p: Painter,
    allocator: std.mem.Allocator,
    app: *App,
    pub fn tick(self: LoadTicker) void {
        self.app.spinner_frame +%= 1;
        // A resize during the load is absorbed here: repaint reads currentSize so
        // it reflows; consume the flag so the loop's own resize check doesn't
        // redundantly repaint the same frame once the read returns.
        _ = term.takeResized();
        // Best-effort, like paintLoading/paintSearching: a dropped animation frame
        // is cosmetic, and a genuine OOM resurfaces on the next real allocation.
        repaint(self.p.fd, self.p.frame, self.allocator, self.app) catch {};
    }
};

/// The Search tab's cross-query selection ("basket"): the packages checked
/// across one or more queries, keyed by `(name, kind)` and owning its name bytes
/// so a pick outlives the per-query parse it was checked in. Shell-owned; the
/// pure leaf never sees it — only the projected `checked` slice.
const SearchSelection = struct {
    // The leaf's borrowed-row type, so the basket view reads `entries.items`
    // directly with no copy. The shell still owns and frees each `name`.
    const Entry = search.SelEntry;
    entries: std.ArrayList(Entry) = .empty,

    fn indexOf(self: *const SearchSelection, name: []const u8, kind: search_json.Kind) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (e.kind == kind and std.mem.eql(u8, e.name, name)) return i;
        }
        return null;
    }

    fn contains(self: *const SearchSelection, name: []const u8, kind: search_json.Kind) bool {
        return self.indexOf(name, kind) != null;
    }

    /// Add the pick if absent, remove it if present — the `space` toggle. Owns a
    /// copy of `name`, so the entry survives the parse storage `name` borrows.
    fn toggle(self: *SearchSelection, allocator: std.mem.Allocator, name: []const u8, kind: search_json.Kind) !void {
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
    fn remove(self: *SearchSelection, allocator: std.mem.Allocator, name: []const u8, kind: search_json.Kind) void {
        if (self.indexOf(name, kind)) |i| {
            allocator.free(self.entries.items[i].name);
            _ = self.entries.swapRemove(i); // order is irrelevant for a set
        }
    }

    /// Empty the basket, freeing every pick's bytes — the `n` escape hatch. Keeps
    /// the backing capacity for reuse; `deinit` releases that at teardown.
    fn clear(self: *SearchSelection, allocator: std.mem.Allocator) void {
        for (self.entries.items) |e| allocator.free(e.name);
        self.entries.clearRetainingCapacity();
    }

    fn deinit(self: *SearchSelection, allocator: std.mem.Allocator) void {
        for (self.entries.items) |e| allocator.free(e.name);
        self.entries.deinit(allocator);
    }
};

/// Project the persistent selection onto a result list: a row is checked iff it
/// is selected and not already installed. A pure function of `(items, selection)`
/// so it runs identically after a query parse and after a toggle.
fn projectChecked(items: []const search_json.Match, checked: []bool, sel: *const SearchSelection) void {
    for (items, checked) |m, *c| c.* = !m.installed and sel.contains(m.name, m.kind);
}

/// Fill the Search tab's shell-owned `checked` slice from the selection. No-op
/// before a query has loaded.
fn projectSearchChecked(store: *Store) void {
    const items = if (store.search) |p| p.items else return;
    projectChecked(items, store.search_checked, &store.search_selected);
}

/// Mirror the shell-owned basket onto the leaf: the count (so the core can gate
/// `i` and the footer can size `N selected`) and the entries slice the basket view
/// renders. The leaf holds no allocator and never owns the picks — it borrows this
/// slice, which the shell refreshes here after every basket mutation (an append
/// can move the backing buffer, so a stale slice would dangle).
fn syncSearchSelectedCount(app: *App, store: *const Store) void {
    app.states.search.selected_count = store.search_selected.entries.items.len;
    app.states.search.basket = store.search_selected.entries.items;
}

/// Owns the JSON parse results the tabs borrow from. Reads re-exec `mt … --json`
/// and reparse into here; the tab `State` slices point at this storage and the
/// pure `step`/`render` never free it. One per running dashboard.
const Store = struct {
    installed: ?list_json.Parsed = null,
    detail: ?info_json.Parsed = null,
    outdated: ?outdated_json.Parsed = null,
    /// The Outdated tab's checkbox state, parallel to `outdated.?.items`. Owned
    /// here, resized to the row count on each (re)load, borrowed by the tab.
    outdated_checked: []bool = &.{},
    services: ?services_json.Parsed = null,
    doctor: ?doctor_json.Parsed = null,
    search: ?search_json.Parsed = null,
    /// The Search tab's checkbox state, parallel to `search.?.items`. Owned here,
    /// resized to the result count on each query, borrowed by the tab. Now a
    /// projection of `search_selected`, not per-query state.
    search_checked: []bool = &.{},
    /// The Search tab's cross-query selection ("basket"), owned here; outlives
    /// every per-query parse. See `SearchSelection`.
    search_selected: SearchSelection = .{},
    /// Backing storage for the Search tab's open `mt info` pane (its own slot so
    /// it never clobbers the Installed tab's detail parse).
    search_detail: ?info_json.Parsed = null,

    fn deinit(self: *Store, allocator: std.mem.Allocator) void {
        if (self.installed) |p| p.deinit();
        if (self.detail) |p| p.deinit();
        if (self.outdated) |p| p.deinit();
        if (self.outdated_checked.len != 0) allocator.free(self.outdated_checked);
        if (self.services) |p| p.deinit();
        if (self.doctor) |p| p.deinit();
        if (self.search) |p| p.deinit();
        if (self.search_checked.len != 0) allocator.free(self.search_checked);
        self.search_selected.deinit(allocator);
        if (self.search_detail) |p| p.deinit();
    }
};

/// (Re)read `mt list --json --size --linked` and repoint the Installed tab's
/// rows at the fresh parse, freeing the previous one. The `--size`/`--linked`
/// keg-dir walk is paid only here — on the Installed tab, lazily.
fn loadInstalled(io: std.Io, allocator: std.mem.Allocator, app: *App, store: *Store) RunError!void {
    // Annotate any failure as a recoverable banner; the loop boundary decides
    // whether to keep looping (recoverable) or restore + exit (fatal). The store
    // is only swapped after a clean parse, so a failure keeps the last-good rows.
    errdefer |err| app.banner.set("list refresh failed", @errorName(err));
    const argv = try spawn.jsonArgv(allocator, app.mt_path, &.{ "list", "--size", "--linked" });
    defer allocator.free(argv);
    const bytes = (try spawn.readJsonAllowEmpty(io, allocator, argv)) orelse {
        // Fresh prefix: an empty Cellar, not a failure. Clear the rows.
        if (store.installed) |old| old.deinit();
        store.installed = null;
        app.states.installed.items = &.{};
        app.states.installed.detail = null;
        app.installed_count = 0; // empty Cellar is a known zero, not "unknown"
        return;
    };
    defer allocator.free(bytes);

    const parsed = try list_json.parse(allocator, bytes);
    if (store.installed) |old| old.deinit();
    store.installed = parsed;
    app.states.installed.items = parsed.items;
    app.states.installed.detail = null; // a refreshed list invalidates the old detail
    app.installed_count = parsed.items.len;
}

/// Argv for the cheap keg-count read: `mt list --json` with **no**
/// `--size --linked`, so it is a DB read, not the keg-dir size/symlink walk that
/// `loadInstalled` pays. Kept separate so a test can pin that the count path
/// stays cheap.
fn installedCountArgv(allocator: std.mem.Allocator, mt_path: []const u8) std.mem.Allocator.Error![]const []const u8 {
    return spawn.jsonArgv(allocator, mt_path, &.{"list"});
}

/// Refresh only the header keg count, cheaply (see `installedCountArgv`). The
/// full `--size --linked` Installed payload still loads lazily on tab entry; this
/// keeps `<n> kegs` live at launch and after a cross-tab install. A second writer
/// of `installed_count` beside `loadInstalled` — both compute `items.len`, so
/// they cannot diverge.
fn refreshInstalledCount(io: std.Io, allocator: std.mem.Allocator, app: *App) RunError!void {
    errdefer |err| app.banner.set("keg count refresh failed", @errorName(err));
    const argv = try installedCountArgv(allocator, app.mt_path);
    defer allocator.free(argv);
    const bytes = (try spawn.readJsonAllowEmpty(io, allocator, argv)) orelse {
        app.installed_count = 0; // empty Cellar is a known zero, not "unknown"
        return;
    };
    defer allocator.free(bytes);
    const parsed = try list_json.parse(allocator, bytes);
    defer parsed.deinit(); // count only — the lazy full load owns the rows
    app.installed_count = parsed.items.len;
}

// ── Background tab fetches ─────────────────────────────────────────────────
// The slow tabs (Outdated/Services/Doctor) each run a network/audit
// `mt … --json` that must not block the input loop. Each runs as a non-blocking
// child whose stdout the loop multiplexes with the tty, so the dashboard stays
// live and every tab fills in when its own fetch lands — navigation is never
// trapped behind a cold-cache audit.

/// Poll timeout between spinner ticks while any background fetch runs — short
/// enough to read as animation, long enough not to busy-spin.
const fetch_tick_ms: i32 = 80;

/// Cap on a background fetch's captured bytes, sized like the blocking drain's
/// `--json` shape with headroom.
const max_fetch_bytes: usize = 4 * 1024 * 1024;

/// Which fd a multiplexed wait found ready. The tty wins over any fetch when
/// both are ready, so a queued keypress is serviced before a fetch drains —
/// input is never starved by a chatty audit.
pub const MuxEvent = union(enum) { tty, fetch: usize, timeout };

/// One multiplexed wait over the controlling tty and every active fetch's
/// stdout. Bounds the wait at `timeout` ms so a spinner tick / resize reflow
/// lands even with nothing ready. `std.posix.poll` retries `EINTR` internally,
/// so a `SIGWINCH` mid-wait surfaces as `.timeout`, never an error. The `.fetch`
/// index is into `fetch_fds`; the tty is checked first so it wins ties.
pub fn pollMux(tty_fd: std.posix.fd_t, fetch_fds: []const std.posix.fd_t, timeout: i32) error{ReadFailed}!MuxEvent {
    var pfds_buf: [1 + tab_bar.count]std.posix.pollfd = undefined;
    const pfds = pfds_buf[0 .. 1 + fetch_fds.len];
    pfds[0] = .{ .fd = tty_fd, .events = std.posix.POLL.IN, .revents = 0 };
    for (fetch_fds, 0..) |fd, i| pfds[1 + i] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
    const ready = std.posix.poll(pfds, timeout) catch return error.ReadFailed;
    if (ready == 0) return .timeout;
    if (pfds[0].revents != 0) return .tty; // input wins; a HUP/ERR on the tty also reads here
    for (0..fetch_fds.len) |i| if (pfds[1 + i].revents != 0) return .{ .fetch = i };
    return .timeout; // defensive: poll reported ready but nothing matched
}

/// One in-flight background tab fetch: a non-blocking `mt <verb> --json` child
/// whose stdout the loop drains. `tab` routes the drained bytes to the owning
/// store; `max_ok_exit` tolerates Doctor's severity exits (≤2) where the others
/// require a clean 0.
const TabFetch = struct {
    tab: Tab,
    child: std.process.Child,
    fd: std.posix.fd_t, // the child's stdout, polled alongside the tty
    buf: std.ArrayList(u8) = .empty,
    max_ok_exit: u8,
};

/// At most one in-flight fetch per tab. Installed (a cheap DB read) and Search
/// (synchronous by design) never background-fetch, so their slots stay null.
const Fetches = std.EnumArray(Tab, ?TabFetch);

/// The `mt` subcommand + exit tolerance for a slow tab's `--json` audit, or null
/// for a tab that does not background-fetch. Doctor exits by severity while still
/// emitting findings, so it tolerates ≤2 where the others require 0.
fn fetchSpec(t: Tab) ?struct { verb: []const []const u8, max_ok_exit: u8 } {
    return switch (t) {
        .outdated => .{ .verb = &.{"outdated"}, .max_ok_exit = 0 },
        .services => .{ .verb = &.{ "services", "list" }, .max_ok_exit = 0 },
        .doctor => .{ .verb = &.{"doctor"}, .max_ok_exit = 2 },
        else => null,
    };
}

/// The banner op for a tab's failed background refresh — the same wording the
/// synchronous reload uses, so a failure reads the same either way.
fn tabRefreshOp(t: Tab) []const u8 {
    return switch (t) {
        .outdated => "outdated refresh failed",
        .services => "services refresh failed",
        .doctor => "doctor refresh failed",
        else => "refresh failed",
    };
}

/// True when any fetch is in flight — the loop only multiplexes then; with none
/// active it falls back to the lone blocking tty read, so an idle dashboard has
/// zero wakeups.
fn anyFetchActive(fetches: *const Fetches) bool {
    for (&fetches.values) |*v| if (v.* != null) return true;
    return false;
}

/// Kick off `t`'s background audit, flag it loading, and store the fetch. A
/// no-op when the tab has no fetch spec or one is already in flight. A spawn
/// fault is quiet: the tab stays unflagged so the entry path can retry, never a
/// nag banner.
fn startTabFetch(io: std.Io, allocator: std.mem.Allocator, fetches: *Fetches, app: *App, t: Tab) void {
    if (fetches.getPtr(t).* != null) return; // already auditing this tab
    const spec = fetchSpec(t) orelse return;
    const argv = spawn.jsonArgv(allocator, app.mt_path, spec.verb) catch return;
    defer allocator.free(argv);
    var child = std.process.spawn(io, .{ .argv = argv, .stdout = .pipe, .stderr = .ignore }) catch return;
    const out = child.stdout orelse {
        child.kill(io);
        _ = child.wait(io) catch {};
        return;
    };
    app.tab_loading.insert(t);
    fetches.set(t, .{ .tab = t, .child = child, .fd = out.handle, .max_ok_exit = spec.max_ok_exit });
}

/// Kill the child so it cannot outlive the TUI; `kill` also reaps it (no zombie)
/// and closes its stdout, so no separate `wait` — a second reap would abort on the
/// already-cleared pid. The shared child-teardown step; callers own the buffer.
fn killAndReap(io: std.Io, f: *TabFetch) void {
    f.child.kill(io);
}

/// Tear an in-flight fetch down completely: reap the child and free its buffer.
/// The teardown path when the user quit before the audit finished.
fn reapTabFetch(io: std.Io, allocator: std.mem.Allocator, f: *TabFetch) void {
    killAndReap(io, f);
    f.buf.deinit(allocator);
}

/// Reap every in-flight fetch at teardown so none outlives the TUI or zombies.
fn reapAllFetches(io: std.Io, allocator: std.mem.Allocator, fetches: *Fetches) void {
    var it = fetches.iterator();
    while (it.next()) |e| if (e.value.*) |*f| reapTabFetch(io, allocator, f);
}

/// A drained fetch's outcome, kept three-way so a *failed* audit (bad exit, read
/// fault) stays distinct from a *clean empty* one: empty clears the tab to a
/// known-zero state, failure keeps the last-good data behind a banner.
const FetchOutcome = union(enum) { bytes: []const u8, empty, failed: anyerror };

/// Route a drained payload to the owning tab's store. Pure dispatch over `tab`;
/// the per-tab `applyXBytes` own the empty-vs-document split and the swap.
fn applyTabBytes(allocator: std.mem.Allocator, app: *App, store: *Store, t: Tab, bytes: ?[]const u8) RunError!void {
    switch (t) {
        .outdated => try applyOutdatedBytes(allocator, app, store, bytes),
        .services => try applyServicesBytes(allocator, app, store, bytes),
        .doctor => try applyDoctorBytes(allocator, app, store, bytes),
        else => {},
    }
}

/// Land a completed fetch into its tab's store, then drop it and repaint. The
/// child must already be reaped. The bytes are applied *before* the buffer is
/// freed (the parse copies them); a parse/apply failure surfaces the same
/// recoverable banner the synchronous reload uses and keeps the last-good data —
/// never fatal, the loop keeps running.
fn finishTabFetch(allocator: std.mem.Allocator, painter: Painter, fetches: *Fetches, app: *App, store: *Store, t: Tab, outcome: FetchOutcome) void {
    switch (outcome) {
        .failed => |err| app.banner.set(tabRefreshOp(t), @errorName(err)),
        .empty => applyTabBytes(allocator, app, store, t, null) catch |e| app.banner.set(tabRefreshOp(t), @errorName(e)),
        .bytes => |b| applyTabBytes(allocator, app, store, t, b) catch |e| app.banner.set(tabRefreshOp(t), @errorName(e)),
    }
    if (fetches.getPtr(t).*) |*f| f.buf.deinit(allocator);
    fetches.set(t, null);
    app.tab_loading.remove(t);
    repaint(painter.fd, painter.frame, allocator, app) catch {};
}

/// Drain whatever a fetch's stdout has ready. On EOF, reap the child and route
/// the captured bytes (a clean exit's empty payload is `.empty`, a bad exit is
/// `.failed` — never parsed); on a read fault or overflow, kill the still-running
/// child first, then finish `.failed`. Bounded like the blocking drain; the
/// child is always reaped before the result lands so none leaks.
fn drainTabFetch(io: std.Io, allocator: std.mem.Allocator, painter: Painter, fetches: *Fetches, app: *App, store: *Store, t: Tab) void {
    const f = &fetches.getPtr(t).*.?;
    var chunk: [4096]u8 = undefined;
    const n = std.posix.read(f.fd, &chunk) catch return failLiveTabFetch(io, allocator, painter, fetches, app, store, t);
    if (n == 0) { // EOF: the audit closed stdout — reap the child here
        const status = f.child.wait(io) catch return finishTabFetch(allocator, painter, fetches, app, store, t, .{ .failed = error.WaitFailed });
        const ok = switch (status) {
            .exited => |code| code <= f.max_ok_exit,
            else => false, // signal/stopped/unknown: never parse a half-written doc
        };
        const outcome: FetchOutcome = if (!ok) .{ .failed = error.ChildFailed } else if (f.buf.items.len == 0) .empty else .{ .bytes = f.buf.items };
        return finishTabFetch(allocator, painter, fetches, app, store, t, outcome);
    }
    if (f.buf.items.len + n > max_fetch_bytes) return failLiveTabFetch(io, allocator, painter, fetches, app, store, t);
    // An append OOM is a failed refresh (last-good kept), not a TUI teardown.
    f.buf.appendSlice(allocator, chunk[0..n]) catch return failLiveTabFetch(io, allocator, painter, fetches, app, store, t);
}

/// Abandon a fetch whose child is still running (read fault, overflow, OOM):
/// kill+reap it, then finish `.failed`. The best-effort refresh contract —
/// last-good data behind the recoverable banner, never a TUI teardown.
fn failLiveTabFetch(io: std.Io, allocator: std.mem.Allocator, painter: Painter, fetches: *Fetches, app: *App, store: *Store, t: Tab) void {
    killAndReap(io, &fetches.getPtr(t).*.?);
    finishTabFetch(allocator, painter, fetches, app, store, t, .{ .failed = error.ReadFailed });
}

/// One loop turn while background fetches run: multiplex the tty with every
/// active fetch's stdout. On a timeout, advance + repaint the spinner(s) (and
/// absorb a resize) so the indicators animate; on a fetch ready, drain it;
/// return true only when the tty has input the caller must read this turn.
fn serviceFetches(io: std.Io, allocator: std.mem.Allocator, painter: Painter, fetches: *Fetches, app: *App, store: *Store) error{ReadFailed}!bool {
    var fds: [tab_bar.count]std.posix.fd_t = undefined;
    var tabs: [tab_bar.count]Tab = undefined;
    var n: usize = 0;
    var it = fetches.iterator();
    while (it.next()) |e| if (e.value.*) |*f| {
        fds[n] = f.fd;
        tabs[n] = e.key;
        n += 1;
    };
    switch (try pollMux(painter.fd, fds[0..n], fetch_tick_ms)) {
        .timeout => {
            app.spinner_frame +%= 1;
            _ = term.takeResized(); // a resize mid-fetch reflows here; consume so the loop top doesn't double it
            repaint(painter.fd, painter.frame, allocator, app) catch {};
            return false;
        },
        .fetch => |i| {
            drainTabFetch(io, allocator, painter, fetches, app, store, tabs[i]);
            return false;
        },
        .tty => return true,
    }
}

/// Read `mt info <pkg> --json` for the selected row into the detail pane.
fn openDetail(io: std.Io, allocator: std.mem.Allocator, app: *App, store: *Store) RunError!void {
    const sel = installed.selectedPkg(&app.states.installed) orelse return; // nothing selected
    // Name the package in a recoverable banner on any failure; the detail field
    // is only set after a clean parse, so a failure leaves the pane closed.
    errdefer |err| {
        var sb: [96]u8 = undefined;
        const op = std.fmt.bufPrint(&sb, "info for {s} failed", .{sel.name}) catch "info read failed";
        app.banner.set(op, @errorName(err));
    }
    const argv = try spawn.jsonArgv(allocator, app.mt_path, &.{ "info", sel.name });
    defer allocator.free(argv);
    const bytes = try spawn.readJson(io, allocator, argv);
    defer allocator.free(bytes);

    const parsed = try info_json.parse(allocator, bytes);
    if (store.detail) |old| old.deinit();
    store.detail = parsed;
    app.states.installed.detail = .{ .pkg = sel, .info = parsed.info };
}

/// Delegate uninstall to the real `mt` inline, then refresh the list. `sel.name`
/// is copied into the argv before the spawn; the post-spawn reload frees the
/// storage it borrowed from, so it is not read afterwards.
fn doUninstall(io: std.Io, allocator: std.mem.Allocator, t: *term.Term, app: *App, store: *Store) RunError!void {
    const sel = installed.selectedPkg(&app.states.installed) orelse return;
    const argv = try spawn.inlineArgv(allocator, app.mt_path, &.{ "uninstall", sel.name });
    defer allocator.free(argv);
    {
        // A non-zero `mt uninstall` re-enters the dashboard (the user still has
        // malt's real output in their scrollback) and surfaces the failure as a
        // recoverable banner — only a terminal fault is fatal. Scoped so the
        // post-mutation refresh below reports under its own op, not "uninstall".
        errdefer |err| app.banner.set("uninstall failed", @errorName(err));
        try spawn.runInlineReenter(t, argv);
    }
    try loadInstalled(io, allocator, app, store); // the keg is gone — refetch
    markStaleAfterMutation(app); // the other tabs may now be stale too
}

/// Perform any effect the pure `step` requested on the Installed tab, then clear
/// it. The only tab with effects today; reads/spawns live here, never in `step`.
fn serviceInstalled(io: std.Io, allocator: std.mem.Allocator, t: *term.Term, app: *App, store: *Store) RunError!void {
    const req = app.states.installed.request;
    app.states.installed.request = .none;
    switch (req) {
        .none => {},
        .open_detail => try openDetail(io, allocator, app, store),
        .uninstall => try doUninstall(io, allocator, t, app, store),
    }
    // Lazy per-tab refresh: a tab marked dirty by a mutation refetches on entry.
    if (app.active == .installed and takeDirty(app, .installed)) {
        try loadInstalled(io, allocator, app, store);
    }
}

/// (Re)read `mt outdated --json` and repoint the Outdated tab's rows at the fresh
/// parse, freeing the previous one. The checkbox buffer is resized to the new row
/// count and reset — an upgrade removes the upgraded rows, so a stale selection
/// would point at the wrong packages.
fn loadOutdated(io: std.Io, allocator: std.mem.Allocator, painter: Painter, app: *App, store: *Store) RunError!void {
    // Annotate any failure as a recoverable banner; the loop boundary decides
    // recoverable vs fatal. The store is swapped only after a clean parse, so a
    // failure keeps the last-good rows and their selection.
    errdefer |err| app.banner.set("outdated refresh failed", @errorName(err));
    const argv = try spawn.jsonArgv(allocator, app.mt_path, &.{"outdated"});
    defer allocator.free(argv);
    // Animate the spinner across the poll: `loading` stays set so each tick
    // paints it, cleared once the result (or the empty/banner state) replaces it.
    app.loading = true;
    defer app.loading = false;
    const ticker = LoadTicker{ .p = painter, .allocator = allocator, .app = app };
    const bytes = try spawn.readJsonPolled(io, allocator, argv, 0, ticker);
    defer if (bytes) |b| allocator.free(b);
    try applyOutdatedBytes(allocator, app, store, bytes);
}

/// Repoint the Outdated tab and the header count at a drained `--json` payload.
/// `null` (a fresh prefix's exit-0 no-output) clears to a known-zero tab; a parsed
/// document swaps in the rows and a fresh, all-clear checkbox buffer. Shared by
/// the synchronous reload and the background launch fetch, so both land the same
/// state. The store is swapped only after a clean parse — a failure keeps the
/// last-good rows for the caller's banner to explain.
fn applyOutdatedBytes(allocator: std.mem.Allocator, app: *App, store: *Store, bytes: ?[]const u8) RunError!void {
    const payload = bytes orelse {
        if (store.outdated) |old| old.deinit();
        if (store.outdated_checked.len != 0) allocator.free(store.outdated_checked);
        store.outdated = null;
        store.outdated_checked = &.{};
        app.states.outdated.items = &.{};
        app.states.outdated.checked = &.{};
        app.outdated_count = 0; // nothing outdated is a known zero, not "unknown"
        return;
    };
    const parsed = try outdated_json.parse(allocator, payload);
    errdefer parsed.deinit();
    // A fresh checkbox buffer, all clear: an upgrade removes the upgraded rows, so
    // carrying the old selection forward would point at the wrong packages.
    const checked = try allocator.alloc(bool, parsed.items.len);
    @memset(checked, false);

    if (store.outdated) |old| old.deinit();
    if (store.outdated_checked.len != 0) allocator.free(store.outdated_checked);
    store.outdated = parsed;
    store.outdated_checked = checked;
    app.states.outdated.items = parsed.items;
    app.states.outdated.checked = checked;
    app.outdated_count = parsed.items.len;
}

/// Build the `mt upgrade <names...>` argv for the checked Outdated rows. Pure
/// over the tab state: returns null when nothing is selected (the no-op), else an
/// owned argv whose name elements borrow from the parse storage. Caller frees the
/// returned slice (not its elements).
fn upgradeArgv(allocator: std.mem.Allocator, mt_path: []const u8, st: *const outdated.State) std.mem.Allocator.Error!?[]const []const u8 {
    const count = outdated.selectedCount(st);
    if (count == 0) return null; // empty selection: the upgrade is a no-op
    const rest = try allocator.alloc([]const u8, 1 + count);
    defer allocator.free(rest);
    rest[0] = "upgrade";
    _ = outdated.selectedNames(st, rest[1..]); // exactly `count` names, in item order
    return try spawn.inlineArgv(allocator, mt_path, rest);
}

/// Delegate the checked upgrades to the real `mt` inline, then refresh. The argv
/// names borrow from the current parse storage; the post-spawn reload frees that
/// storage, so the names are not read afterwards.
fn doUpgrade(allocator: std.mem.Allocator, t: *term.Term, app: *App, store: *Store) RunError!void {
    const argv = (try upgradeArgv(allocator, app.mt_path, &app.states.outdated)) orelse return; // empty selection: no-op
    defer allocator.free(argv);
    // Snapshot the upgraded rows (the checked, non-pinned ones — same rule as
    // `selectedNames`) while the selection is intact. `(name, kind)` so a
    // same-named formula/cask pair drops only the row that was actually checked.
    // Names borrow the parse arena, which `dropUpgradedRows` keeps alive.
    const st = &app.states.outdated;
    const upgraded = try allocator.alloc(UpgradedRef, outdated.selectedCount(st));
    defer allocator.free(upgraded);
    {
        var n: usize = 0;
        for (st.items, 0..) |row, i| {
            if (i < st.checked.len and st.checked[i] and !row.pinned) {
                upgraded[n] = .{ .name = row.name, .kind = row.kind };
                n += 1;
            }
        }
    }
    {
        // A non-zero `mt upgrade` re-enters the dashboard (the user keeps malt's
        // real output in their scrollback) and surfaces as a recoverable banner;
        // only a terminal fault is fatal. On failure the `try` below returns
        // before the row drop, so the list is left intact.
        errdefer |err| app.banner.set("upgrade failed", @errorName(err));
        try spawn.runInlineReenter(t, argv);
    }
    // Upgrading X can't make Y outdated, so the new outdated set is the old set
    // minus the upgraded tokens — drop them in place rather than re-walk.
    try dropUpgradedRows(allocator, app, store, upgraded);
    markStaleAfterMutation(app); // Installed sizes/versions changed too
}

/// One upgraded row, identified by `(name, kind)` so a formula and a cask that
/// share a name (e.g. `docker`) are never confused for one another.
const UpgradedRef = struct { name: []const u8, kind: outdated_json.Kind };

/// True when `row` is one of the upgraded rows (linear scan — a batch is small).
/// Matches on `(name, kind)`: `mt upgrade <name>` resolves formula-first, so a
/// same-named cask is left outdated and must not be dropped with the formula.
fn rowUpgraded(upgraded: []const UpgradedRef, row: outdated_json.OutdatedRow) bool {
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
    app: *App,
    store: *Store,
    upgraded: []const UpgradedRef,
) std.mem.Allocator.Error!void {
    if (store.outdated == null) return; // nothing loaded → nothing to drop
    const parsed = &store.outdated.?;
    const old_items = parsed.items;
    const old_checked = store.outdated_checked;

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
    store.outdated_checked = new_checked;
    app.states.outdated.items = new_items;
    app.states.outdated.checked = new_checked;
    app.outdated_count = new_items.len;
}

/// Perform any effect the pure `step` requested on the Outdated tab, then clear
/// it, and lazily (re)load on first entry or after a mutation marked it dirty.
fn serviceOutdated(io: std.Io, allocator: std.mem.Allocator, t: *term.Term, fetches: *Fetches, app: *App, store: *Store) RunError!void {
    const req = app.states.outdated.request;
    app.states.outdated.request = .none;
    switch (req) {
        .none => {},
        .upgrade => try doUpgrade(allocator, t, app, store),
    }
    // Lazy per-tab load: first activation and post-mutation staleness both arrive
    // as the dirty flag (set at init and by `markStaleAfterMutation`).
    // Background, non-blocking: spawn the audit and let the loop drain it so the
    // input stays live — a cold-cache outdated audit never traps the tab.
    if (app.active == .outdated and takeDirty(app, .outdated)) {
        startTabFetch(io, allocator, fetches, app, .outdated);
    }
}

/// (Re)read `mt services list --json` and repoint the Services tab's rows at the
/// fresh parse, freeing the previous one.
fn loadServices(io: std.Io, allocator: std.mem.Allocator, painter: Painter, app: *App, store: *Store) RunError!void {
    // Annotate any failure as a recoverable banner; the loop boundary decides
    // recoverable vs fatal. The store is swapped only after a clean parse, so a
    // failure keeps the last-good rows and their selection.
    errdefer |err| app.banner.set("services refresh failed", @errorName(err));
    const argv = try spawn.jsonArgv(allocator, app.mt_path, &.{ "services", "list" });
    defer allocator.free(argv);
    // Animate the spinner across the poll: `loading` stays set so each tick
    // paints it, cleared once the result (or the empty/banner state) replaces it.
    app.loading = true;
    defer app.loading = false;
    const ticker = LoadTicker{ .p = painter, .allocator = allocator, .app = app };
    const bytes = try spawn.readJsonPolled(io, allocator, argv, 0, ticker);
    defer if (bytes) |b| allocator.free(b);
    try applyServicesBytes(allocator, app, store, bytes);
}

/// Repoint the Services tab at a drained `--json` payload. `null` (a fresh prefix)
/// clears to an empty list; a parsed document swaps in the rows. Shared by the
/// synchronous reload and the background fetch; the store is swapped only after a
/// clean parse, so a failure keeps the last-good rows.
fn applyServicesBytes(allocator: std.mem.Allocator, app: *App, store: *Store, bytes: ?[]const u8) RunError!void {
    const payload = bytes orelse {
        if (store.services) |old| old.deinit();
        store.services = null;
        app.states.services.items = &.{};
        app.states.services.detail = null; // the old detail borrowed the freed rows
        return;
    };
    const parsed = try services_json.parse(allocator, payload);
    if (store.services) |old| old.deinit();
    store.services = parsed;
    app.states.services.items = parsed.items;
    app.states.services.detail = null; // a refreshed list invalidates the old detail
}

/// Build `mt services <action> <name>` for the selected service. Pure over the
/// tab state: null when nothing is selected (the no-op), else an owned argv whose
/// `name` element borrows from the parse storage. Caller frees the returned slice
/// (not its elements).
fn serviceActionArgv(allocator: std.mem.Allocator, mt_path: []const u8, action: []const u8, st: *const services.State) std.mem.Allocator.Error!?[]const []const u8 {
    const svc = services.selectedService(st) orelse return null; // empty list: no-op
    return try spawn.inlineArgv(allocator, mt_path, &.{ "services", action, svc.name });
}

/// Delegate a service lifecycle action to the real `mt` inline, then refresh. The
/// argv's `name` borrows from the current parse storage; the post-spawn reload
/// frees that storage, so the name is not read afterwards.
fn doServiceAction(io: std.Io, allocator: std.mem.Allocator, t: *term.Term, painter: Painter, app: *App, store: *Store, action: []const u8) RunError!void {
    const argv = (try serviceActionArgv(allocator, app.mt_path, action, &app.states.services)) orelse return; // nothing selected
    defer allocator.free(argv);
    {
        // A non-zero `mt services <action>` re-enters the dashboard (the user
        // keeps malt's real output in their scrollback) and surfaces as a
        // recoverable banner; only a terminal fault is fatal. Scoped so the
        // refresh below reports under its own op, not the action.
        errdefer |err| app.banner.set("service action failed", @errorName(err));
        try spawn.runInlineReenter(t, argv);
    }
    try loadServices(io, allocator, painter, app, store); // the state changed — refetch
    markStaleAfterMutation(app);
}

/// Perform any lifecycle effect the pure `step` requested on the Services tab,
/// then clear it, and lazily (re)load on first entry or after a mutation marked
/// it dirty.
fn serviceServices(io: std.Io, allocator: std.mem.Allocator, t: *term.Term, painter: Painter, fetches: *Fetches, app: *App, store: *Store) RunError!void {
    const req = app.states.services.request;
    app.states.services.request = .none;
    switch (req) {
        .none => {},
        .start => try doServiceAction(io, allocator, t, painter, app, store, "start"),
        .stop => try doServiceAction(io, allocator, t, painter, app, store, "stop"),
        .restart => try doServiceAction(io, allocator, t, painter, app, store, "restart"),
    }
    // Lazy per-tab load: first activation and post-mutation staleness both arrive
    // as the dirty flag (set at init and by `markStaleAfterMutation`).
    // Background, non-blocking — see `serviceOutdated`.
    if (app.active == .services and takeDirty(app, .services)) {
        startTabFetch(io, allocator, fetches, app, .services);
    }
}

/// (Re)read `mt doctor --json` and repoint the Doctor tab's findings at the fresh
/// parse, freeing the previous one.
fn loadDoctor(io: std.Io, allocator: std.mem.Allocator, painter: Painter, app: *App, store: *Store) RunError!void {
    // Annotate any failure as a recoverable banner; the loop boundary decides
    // recoverable vs fatal. The store is swapped only after a clean parse, so a
    // failure keeps the last-good findings and their selection.
    errdefer |err| app.banner.set("doctor refresh failed", @errorName(err));
    const argv = try spawn.jsonArgv(allocator, app.mt_path, &.{"doctor"});
    defer allocator.free(argv);
    // Animate the spinner across the poll: `loading` stays set so each tick
    // paints it, cleared once the result (or the empty/banner state) replaces it.
    app.loading = true;
    defer app.loading = false;
    const ticker = LoadTicker{ .p = painter, .allocator = allocator, .app = app };
    // `mt doctor` exits non-zero by severity (1 warn / 2 err) while still emitting
    // its findings JSON — exactly when the tab is most useful — so the doctor read
    // tolerates exits up to 2 (`max_ok_exit`) where the generic read rejects them.
    const bytes = try spawn.readJsonPolled(io, allocator, argv, 2, ticker);
    defer if (bytes) |b| allocator.free(b);
    try applyDoctorBytes(allocator, app, store, bytes);
}

/// Repoint the Doctor tab at a drained `--json` payload. `null` (a fresh prefix)
/// clears to no findings; a parsed document swaps in the rows + reclaimable stats.
/// Shared by the synchronous reload and the background fetch; the store is swapped
/// only after a clean parse, so a failure keeps the last-good findings.
fn applyDoctorBytes(allocator: std.mem.Allocator, app: *App, store: *Store, bytes: ?[]const u8) RunError!void {
    const payload = bytes orelse {
        if (store.doctor) |old| old.deinit();
        store.doctor = null;
        app.states.doctor.items = &.{};
        return;
    };
    const parsed = try doctor_json.parse(allocator, payload);
    applyDoctorParse(app, store, parsed);
}

/// Repoint the Doctor tab at a fresh parse, freeing the previous one. Split from
/// the spawn so the findings + reclaimable stats wiring is testable without a
/// child process.
fn applyDoctorParse(app: *App, store: *Store, parsed: doctor_json.Parsed) void {
    if (store.doctor) |old| old.deinit();
    store.doctor = parsed;
    app.states.doctor.items = parsed.items;
    app.states.doctor.stats = parsed.stats;
}

/// Build `mt doctor --fix <class>` for the selected finding. Pure over the tab
/// state: null when nothing is selected or the finding is not fixable (the
/// no-op), else an owned argv. The token is the finding's `fix_class` — the only
/// thing `mt doctor --fix` resolves — not its descriptive `id`. Caller frees the
/// returned slice (not its elements).
fn doctorFixArgv(allocator: std.mem.Allocator, mt_path: []const u8, st: *const doctor.State) std.mem.Allocator.Error!?[]const []const u8 {
    const fnd = doctor.selectedFinding(st) orelse return null; // empty list: no-op
    if (!fnd.fixable) return null; // a non-fixable finding has no fix target
    return try spawn.inlineArgv(allocator, mt_path, &.{ "doctor", "--fix", doctor_json.fixClassTag(fnd.fix_class) });
}

/// Delegate the selected finding's fix to the real `mt` inline, then refresh.
fn doDoctorFix(io: std.Io, allocator: std.mem.Allocator, t: *term.Term, painter: Painter, app: *App, store: *Store) RunError!void {
    const argv = (try doctorFixArgv(allocator, app.mt_path, &app.states.doctor)) orelse return; // nothing fixable selected
    defer allocator.free(argv);
    {
        // `mt doctor --fix` exits by severity (1 warn / 2 err), not pass/fail —
        // a clean sweep of a warning-class finding still exits 1 — so tolerate
        // exits up to 2 (symmetric with the doctor read's `max_ok_exit`). A real
        // fault (exit > 2, signal, terminal fault) still surfaces as a banner;
        // a severity exit re-enters cleanly and falls through to the refresh.
        // Scoped so the refresh below reports under its own op, not the fix.
        errdefer |err| app.banner.set("doctor fix failed", @errorName(err));
        try spawn.runInlineReenterTolerant(t, argv, 2);
    }
    try loadDoctor(io, allocator, painter, app, store); // exit can't say what remains — the refresh is the truth
    markStaleAfterMutation(app);
}

/// Perform any fix effect the pure `step` requested on the Doctor tab, then clear
/// it, and lazily (re)load on first entry or after a mutation marked it dirty.
fn serviceDoctor(io: std.Io, allocator: std.mem.Allocator, t: *term.Term, painter: Painter, fetches: *Fetches, app: *App, store: *Store) RunError!void {
    const req = app.states.doctor.request;
    app.states.doctor.request = .none;
    switch (req) {
        .none => {},
        .fix => try doDoctorFix(io, allocator, t, painter, app, store),
    }
    // Lazy per-tab load: first activation and post-mutation staleness both arrive
    // as the dirty flag (set at init and by `markStaleAfterMutation`).
    // Background, non-blocking — see `serviceOutdated`.
    if (app.active == .doctor and takeDirty(app, .doctor)) {
        startTabFetch(io, allocator, fetches, app, .doctor);
    }
}

/// Build `mt search <query> --json` for the committed query. Pure over the tab
/// state: null when the query is empty (the no-op — the view shows guidance, no
/// spawn), else an owned argv whose `query` element borrows the filter buffer.
/// Caller frees the returned slice (not its elements).
fn searchArgv(allocator: std.mem.Allocator, mt_path: []const u8, st: *const search.State) std.mem.Allocator.Error!?[]const []const u8 {
    const query = st.chrome.filter.slice();
    if (query.len == 0) return null; // empty query: no remote read
    return try spawn.jsonArgv(allocator, mt_path, &.{ "search", query });
}

/// Run the committed query's `mt search --json`, parse, and repoint the Search
/// tab's results at the fresh parse. Search is a remote read, so it goes through
/// `readJson` like the other reads (no alt-screen drop). The store is swapped
/// only after a clean parse, so a failure keeps the last-good results.
fn loadSearch(io: std.Io, allocator: std.mem.Allocator, app: *App, store: *Store) RunError!void {
    const argv = (try searchArgv(allocator, app.mt_path, &app.states.search)) orelse return; // empty query: no-op
    defer allocator.free(argv);
    // Annotate any failure as a recoverable banner; the loop boundary decides
    // recoverable vs fatal. A failed read must also leave the "searching…" phase
    // (set by the pre-spawn paint): fall back to the last-good results, or
    // guidance if none were ever loaded — never a stuck spinner behind the banner.
    errdefer |err| {
        app.banner.set("search failed", @errorName(err));
        app.states.search.phase = if (store.search != null) .loaded else .idle;
    }
    const bytes = try spawn.readJson(io, allocator, argv);
    defer allocator.free(bytes);

    const parsed = try search_json.parse(allocator, bytes);
    errdefer parsed.deinit();
    // `checked` is a projection of the persistent basket, not per-query state: a
    // pick survives a re-query and re-checks its row when the package returns.
    const checked = try allocator.alloc(bool, parsed.items.len);

    if (store.search) |old| old.deinit();
    if (store.search_checked.len != 0) allocator.free(store.search_checked);
    store.search = parsed;
    store.search_checked = checked;
    projectSearchChecked(store);
    app.states.search.items = parsed.items;
    app.states.search.checked = checked;
    syncSearchSelectedCount(app, store); // off-list picks count too, so refresh from the basket
    app.states.search.phase = .loaded;
    // A fresh query is a new result set, so an old cursor would point at an
    // unrelated row, and any open info pane is for a hit that may be gone.
    app.states.search.chrome.view = .{};
    app.states.search.detail = null;
    if (store.search_detail) |old| {
        old.deinit();
        store.search_detail = null;
    }
}

/// Build the `mt install …` argv for the Search tab from the cross-query basket.
/// The whole basket installs, so an off-screen pick installs too. Empty basket ⇒
/// fall back to the active row (the no-selection case); null when that row is
/// absent or already installed (the no-op). A single target keeps the explicit
/// `--formula`/`--cask` flag, because a name can exist as both and bare
/// `mt install <name>` silently picks the formula; a multi install passes bare
/// names and lets `mt` detect each one's kind. Basket names are owned, so the
/// argv outlives the parse it was checked in (the active-row fallback name
/// borrows the live parse, read before any re-search frees it). Caller frees the
/// returned slice, not its elements.
fn installArgv(allocator: std.mem.Allocator, mt_path: []const u8, sel: *const SearchSelection, st: *const search.State) std.mem.Allocator.Error!?[]const []const u8 {
    const entries = sel.entries.items;
    if (entries.len == 0) {
        // Empty basket: the active row, if it is installable.
        const i = search.selectedIndex(st) orelse return null;
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

/// The single-target disambiguation flag for a kind. A closed switch: a new kind
/// is a compile error, never a silent default.
fn kindFlag(k: search_json.Kind) []const u8 {
    return switch (k) {
        .formula => "--formula",
        .cask => "--cask",
    };
}

/// Post-install basket lifecycle: a clean install (exit 0) consumed the whole
/// basket, so clear it and re-project the now-empty checked slice; a failed
/// install retains the basket for retry. Pure over the store — the seam the
/// install path's clear-on-success / retain-on-failure policy is tested through.
fn applyInstallOutcome(store: *Store, allocator: std.mem.Allocator, ok: bool) void {
    if (!ok) return; // retain for retry
    store.search_selected.deinit(allocator);
    store.search_selected = .{};
    projectSearchChecked(store);
}

/// Delegate the basket's install to the real `mt` inline, then re-run the query
/// so installed markers flip. The argv's names are owned by the basket (the
/// active-row fallback name borrows the live parse, read before the re-search
/// frees it). A clean install clears the basket; a failed one keeps it.
fn doInstall(io: std.Io, allocator: std.mem.Allocator, t: *term.Term, app: *App, store: *Store) RunError!void {
    const argv = (try installArgv(allocator, app.mt_path, &store.search_selected, &app.states.search)) orelse return; // nothing installable selected
    defer allocator.free(argv);
    // A non-zero `mt install` re-enters the dashboard (the user keeps malt's real
    // output, including any prompt, in their scrollback) and surfaces as a
    // recoverable banner; only a terminal fault is fatal — the loop boundary
    // decides which on the re-raised error. The basket is retained either way.
    spawn.runInlineReenter(t, argv) catch |err| {
        app.banner.set("install failed", @errorName(err));
        applyInstallOutcome(store, allocator, false); // retain for retry
        return err;
    };
    applyInstallOutcome(store, allocator, true); // a clean install consumed the basket
    syncSearchSelectedCount(app, store); // basket now empty → leaf gate + footer reflect it
    // Re-run the same query so the freshly installed hit's marker flips — the
    // backend's install-aware `installed` flag does the rest (no `mt list` call).
    try loadSearch(io, allocator, app, store);
    markStaleAfterMutation(app); // Installed/Outdated/Services may have changed too
    // The keg set grew but we are on Search, so the lazy Installed reload won't
    // run until that tab is entered — refresh just the count now (cheaply) so the
    // header is live immediately, not stale until Installed is opened.
    try refreshInstalledCount(io, allocator, app);
}

/// Perform any effect the pure `step` requested on the Search tab, then clear it.
/// Unlike the other tabs there is no lazy dirty-load: Search has no initial data
/// (idle until the user commits a query), and a remote read on every tab-entry
/// after an unrelated mutation would be a surprising freeze, so a dirty flag set
/// by `markStaleAfterMutation` is deliberately never consumed here.
fn serviceSearch(io: std.Io, allocator: std.mem.Allocator, t: *term.Term, app: *App, store: *Store) RunError!void {
    const req = app.states.search.request;
    app.states.search.request = .none;
    switch (req) {
        .none => {},
        .search => try loadSearch(io, allocator, app, store),
        .install => try doInstall(io, allocator, t, app, store),
        .info => try openSearchInfo(io, allocator, app, store),
        // Add/remove the active hit in the persistent basket, then re-project the
        // `checked` slice so the row reflects it immediately. The leaf already
        // refused installed rows, so the match here is always selectable.
        .toggle => {
            const m = search.selectedMatch(&app.states.search) orelse return;
            try store.search_selected.toggle(allocator, m.name, m.kind);
            projectSearchChecked(store);
            syncSearchSelectedCount(app, store);
        },
        // Drop the highlighted basket pick (read its name/kind before freeing it),
        // then re-project so any on-screen row for it clears its checkmark.
        .remove => {
            const e = search.selectedBasketEntry(&app.states.search) orelse return;
            store.search_selected.remove(allocator, e.name, e.kind);
            projectSearchChecked(store);
            syncSearchSelectedCount(app, store);
        },
        // Empty the whole basket; the projection then clears every on-screen check.
        .clear => {
            store.search_selected.clear(allocator);
            projectSearchChecked(store);
            syncSearchSelectedCount(app, store);
        },
    }
}

/// Open the `mt info` pane for the active hit. `mt info` resolves installed and
/// uninstalled packages alike, so a search result can be inspected before any
/// install. A read (no alt-screen drop); failure names the package in a banner
/// and leaves the pane closed.
fn openSearchInfo(io: std.Io, allocator: std.mem.Allocator, app: *App, store: *Store) RunError!void {
    const m = search.selectedMatch(&app.states.search) orelse return; // empty list: no-op
    errdefer |err| {
        var sb: [96]u8 = undefined;
        const op = std.fmt.bufPrint(&sb, "info for {s} failed", .{m.name}) catch "info read failed";
        app.banner.set(op, @errorName(err));
    }
    const argv = try spawn.jsonArgv(allocator, app.mt_path, &.{ "info", m.name });
    defer allocator.free(argv);
    const bytes = try spawn.readJson(io, allocator, argv);
    defer allocator.free(bytes);

    const parsed = try info_json.parse(allocator, bytes);
    if (store.search_detail) |old| old.deinit();
    store.search_detail = parsed;
    app.states.search.detail = parsed.info;
}

/// Drain the active tab's pending effects after a keypress. Each tab's service is
/// a no-op unless that tab is active and has a request or is due a lazy refresh,
/// so calling each one each loop is cheap and keeps the dispatch flat.
fn service(io: std.Io, allocator: std.mem.Allocator, t: *term.Term, painter: Painter, fetches: *Fetches, app: *App, store: *Store) RunError!void {
    try serviceInstalled(io, allocator, t, app, store);
    try serviceOutdated(io, allocator, t, fetches, app, store);
    try serviceServices(io, allocator, t, painter, fetches, app, store);
    try serviceDoctor(io, allocator, t, painter, fetches, app, store);
    try serviceSearch(io, allocator, t, app, store);
}

fn isTty(io: std.Io, fd: std.posix.fd_t) bool {
    const f: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    return f.isTty(io) catch false;
}

fn ciSet(environ: std.process.Environ) bool {
    const v = std.process.Environ.getPosix(environ, "CI") orelse return false;
    return v.len != 0;
}

/// Frame byte capacity for a geometry: 4 bytes/cell (max UTF-8) + per-line
/// cursor/SGR overhead + clear/slack. Grown on resize, never per-frame.
fn frameCap(size: term.Size) usize {
    return @as(usize, size.cols) * size.rows * 4 + @as(usize, size.rows) * 48 + 256;
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) return; // best-effort: a vanished tty has nothing to draw
        off += @intCast(n);
    }
}

/// Launch the dashboard. Refuses (exit 2) on a non-interactive terminal rather
/// than degrading. Every fault path restores the terminal via `errdefer`.
pub fn run(io: std.Io, allocator: std.mem.Allocator, stderr: std.Io.File, environ: std.process.Environ, mt_path: []const u8, version: []const u8) RunError!void {
    const in_fd = std.posix.STDIN_FILENO;
    const out_fd = std.posix.STDOUT_FILENO;
    if (refusalReason(
        isTty(io, in_fd),
        isTty(io, out_fd),
        std.process.Environ.getPosix(environ, "NO_COLOR") != null,
        ciSet(environ),
    )) |r| {
        // exit(2) is the real signal; a closed stderr must not block it.
        stderr.writeStreamingAll(io, refusalMessage(r)) catch {};
        std.process.exit(2);
    }

    // The tty is read+write through one fd; the refusal guard proved it is one.
    const fd = in_fd;
    var t = term.Term.init(io, fd);
    try t.enterRaw();
    errdefer t.restore();
    try t.enterAltScreen();
    errdefer t.restore();
    try t.hideCursor();
    errdefer t.restore();
    term.installWinch(fd);

    // The prefix the dashboard acts on, resolved the way the rest of malt does.
    const prefix = std.process.Environ.getPosix(environ, "MALT_PREFIX") orelse "/opt/malt";
    var app: App = .{ .mt_path = mt_path, .version = version, .prefix = prefix }; // re-exec this mt for delegated mutations
    initLaunchDirty(&app); // every data tab loads lazily on first entry
    var store: Store = .{};
    defer store.deinit(allocator);
    var frame = try allocator.alloc(u8, frameCap(term.currentSize()));
    defer allocator.free(frame);
    // The paint handle the polled lazy reads tick against to animate the spinner.
    const painter: Painter = .{ .fd = fd, .frame = &frame };

    // Paint the data-free chrome first so the alt-screen never flashes blank,
    // then prime the cheap installed count (a single-digit-ms SQLite read) and
    // repaint — launch shows `<n> kegs` immediately. The outdated count is *not*
    // cheap: on a cold cache it is a live per-keg network audit, so it runs in the
    // background and the loop multiplexes its stdout (a header spinner, never a
    // freeze). Best-effort: a failed installed count leaves an em-dash, never
    // blocks the dashboard from opening.
    try repaint(fd, &frame, allocator, &app);
    refreshInstalledCount(io, allocator, &app) catch {};
    app.banner.clear(); // a failed startup installed count is an em-dash, not a nag

    // Per-tab background fetches: the slow tabs' `--json` audits run as children
    // the loop drains, so navigation is never trapped behind one. Reaped at
    // teardown so none outlives the TUI or leaves a zombie.
    var fetches: Fetches = .initFill(null);
    defer reapAllFetches(io, allocator, &fetches);
    // Outdated is fetched at launch so the header count fills in without entering
    // the tab; its dirty flag is consumed once the fetch owns the load, so the
    // first entry doesn't spawn a duplicate audit.
    startTabFetch(io, allocator, &fetches, &app, .outdated);
    if (app.tab_loading.contains(.outdated)) _ = takeDirty(&app, .outdated);
    try repaint(fd, &frame, allocator, &app); // first interactive frame: kegs + the outdated spinner

    var decoder: keys.Decoder = .{};
    var rbuf: [64]u8 = undefined;
    while (!app.quit) {
        if (term.takeResized()) try repaint(fd, &frame, allocator, &app);
        // While any background fetch runs, multiplex the tty with the fetch fds so
        // a keypress is serviced live; a ready tty falls through to the read below
        // (now non-blocking), else the turn was a spinner tick or a drain — loop.
        // With no fetch in flight this is the original lone blocking read.
        if (anyFetchActive(&fetches) and !try serviceFetches(io, allocator, painter, &fetches, &app, &store)) continue;
        const rc = std.c.read(fd, &rbuf, rbuf.len);
        if (rc < 0) {
            if (std.posix.errno(rc) == .INTR) continue; // SIGWINCH woke the read; loop re-checks resize
            return error.ReadFailed;
        }
        if (rc == 0) break; // EOF
        const bytes = rbuf[0..@intCast(rc)];
        var consumed: usize = 0;
        while (consumed < bytes.len) {
            switch (decoder.decode(bytes[consumed..])) {
                .incomplete => break,
                .key => |k| {
                    consumed += k.consumed;
                    app = step(app, k.key); // also clears any prior banner
                    if (app.quit) break;
                    paintSearching(fd, &frame, allocator, &app); // status before the blocking search
                    paintLoading(fd, &frame, allocator, &app); // "Loading…" before a blocking lazy refetch
                    // A recoverable backend fault becomes the banner the failing
                    // op already set and the loop continues; only a fatal fault
                    // (terminal/OOM) propagates to the errdefer restore + exit.
                    service(io, allocator, &t, painter, &fetches, &app, &store) catch |err| switch (classify(err)) {
                        .recoverable => {},
                        .fatal => return err,
                    };
                },
            }
        }
        try repaint(fd, &frame, allocator, &app);
    }
    t.restore();
}

/// Search is the dashboard's first remote read: when the user commits a query,
/// flip the phase and repaint a "searching…" status *before* the blocking call,
/// so the synchronous freeze isn't a dead terminal. The only tab-specific paint
/// in the otherwise tab-agnostic loop, earned by that first-remote-read cost.
/// Best-effort: a paint failure just means the real read's repaint follows.
fn paintSearching(fd: std.posix.fd_t, frame: *[]u8, allocator: std.mem.Allocator, app: *App) void {
    if (app.active != .search or app.states.search.request != .search) return;
    if (app.states.search.chrome.filter.slice().len == 0) return; // empty query: no spawn
    app.states.search.phase = .searching;
    repaint(fd, frame, allocator, app) catch {};
}

/// Before the active tab runs a blocking lazy refetch (it is dirty and will
/// refetch on entry), paint a "Loading…" footer so the synchronous read reads as
/// intentional, not a frozen or — before stderr was suppressed — garbled frame.
/// Best-effort, like `paintSearching`; the read's own repaint draws the result.
fn paintLoading(fd: std.posix.fd_t, frame: *[]u8, allocator: std.mem.Allocator, app: *App) void {
    if (!app.dirty.contains(app.active)) return; // nothing will refetch this turn
    app.loading = true;
    repaint(fd, frame, allocator, app) catch {};
    app.loading = false;
}

fn repaint(fd: std.posix.fd_t, frame: *[]u8, allocator: std.mem.Allocator, app: *App) std.mem.Allocator.Error!void {
    const size = term.currentSize();
    const need = frameCap(size);
    if (need > frame.len) frame.* = try allocator.realloc(frame.*, need);
    writeAll(fd, renderFrame(frame.*, app, size.cols, size.rows));
}

// ─── tests ───────────────────────────────────────────────────────────

fn ch(c: u8) Key {
    return .{ .char = .{ .bytes = .{ c, 0, 0, 0 }, .len = 1 } };
}

/// A no-op paint handle for unit tests that drive a lazy loader directly: the
/// test children all finish before the first poll timeout, so the tick never
/// fires and the fd/frame are never touched.
fn testPainter(frame: *[]u8) Painter {
    return .{ .fd = -1, .frame = frame };
}

test "a data-free App renders the full chrome so the skeleton paint is real" {
    var app: App = .{}; // active .search, empty Store, no counts loaded
    var buf: [8192]u8 = undefined;
    const out = renderFrame(&buf, &app, 80, 24);
    for ([_][]const u8{ "Search", "Installed", "Outdated", "Services", "Doctor" }) |title|
        try std.testing.expect(std.mem.indexOf(u8, out, title) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "quit") != null); // footer help present
}

test "tab cycles and 1-5 jump to a tab" {
    var a: App = .{};
    try std.testing.expectEqual(Tab.search, a.active); // the dashboard opens on Search
    a = step(a, .tab);
    try std.testing.expectEqual(Tab.installed, a.active);
    a = step(a, ch('3'));
    try std.testing.expectEqual(Tab.outdated, a.active);
    a = step(a, ch('1'));
    try std.testing.expectEqual(Tab.search, a.active);
}

test "left and right arrows switch tabs both directions and wrap" {
    var a: App = .{};
    a = step(a, .right);
    try std.testing.expectEqual(Tab.installed, a.active);
    a = step(a, .left);
    try std.testing.expectEqual(Tab.search, a.active);
    a = step(a, .left); // wrap backward to the last tab
    try std.testing.expectEqual(Tab.doctor, a.active);
}

test "a committed filter survives a tab round-trip" {
    var a: App = .{};
    a = step(a, ch('/')); // enter filter mode
    try std.testing.expect(a.editing);
    a = step(a, ch('w'));
    a = step(a, ch('g'));
    a = step(a, .enter); // commit
    try std.testing.expect(!a.editing);
    a = step(a, .tab); // leave the tab
    a = step(a, .tab);
    a = step(a, .tab);
    a = step(a, .tab);
    a = step(a, .tab); // and come back (five tabs now)
    try std.testing.expectEqualStrings("wg", activeFilterText(&a));
}

test "esc in normal mode routes to the active tab so it can cancel its guard" {
    var a: App = .{ .active = .installed };
    a.states.installed.confirm_uninstall = true;
    a = step(a, .esc); // not editing → must reach the tab, which lowers the guard
    try std.testing.expect(!a.states.installed.confirm_uninstall);
}

test "esc clears the filter and leaves edit mode" {
    var a: App = .{};
    a = step(a, ch('/'));
    a = step(a, ch('x'));
    a = step(a, .esc);
    try std.testing.expect(!a.editing);
    try std.testing.expectEqualStrings("", activeFilterText(&a));
}

test "backspace edits the active filter while typing" {
    var a: App = .{};
    a = step(a, ch('/'));
    a = step(a, ch('a'));
    a = step(a, ch('b'));
    a = step(a, .backspace);
    try std.testing.expectEqualStrings("a", activeFilterText(&a));
}

test "q and ctrl_c request quit" {
    const a: App = .{};
    try std.testing.expect(step(a, ch('q')).quit);
    try std.testing.expect(step(a, .ctrl_c).quit);
}

test "down increments the selection, up saturates at zero" {
    var a: App = .{};
    a = step(a, .down);
    a = step(a, .down);
    try std.testing.expectEqual(@as(usize, 2), activeChrome(&a).view.selected);
    a = step(a, .up);
    a = step(a, .up);
    a = step(a, .up);
    try std.testing.expectEqual(@as(usize, 0), activeChrome(&a).view.selected);
}

test "page keys jump by a page and saturate; home returns to the top" {
    var a: App = .{};
    a = step(a, .page_down);
    try std.testing.expectEqual(@as(usize, page_step), activeChrome(&a).view.selected);
    a = step(a, .page_up);
    a = step(a, .page_up); // already at 0 → saturates, no underflow
    try std.testing.expectEqual(@as(usize, 0), activeChrome(&a).view.selected);
    a = step(a, .down);
    a = step(a, .down);
    a = step(a, .home);
    try std.testing.expectEqual(@as(usize, 0), activeChrome(&a).view.selected);
}

test "a non-command printable key in normal mode is inert (routed, no state change)" {
    const a: App = .{};
    const b = step(a, ch('z')); // not q / 1-4 / /
    try std.testing.expectEqual(a.active, b.active);
    try std.testing.expect(!b.editing);
    try std.testing.expect(!b.quit);
}

test "per-tab filters are independent across tabs" {
    var a: App = .{};
    a = step(a, ch('/'));
    a = step(a, ch('a')); // installed filter = "a"
    a = step(a, .enter);
    a = step(a, .tab); // outdated
    try std.testing.expectEqualStrings("", activeFilterText(&a)); // its own empty filter
}

test "Enter on the Search tab focuses the query box rather than firing an empty search" {
    var a: App = .{ .active = .search };
    a = step(a, .enter);
    try std.testing.expect(a.editing); // the query box is now focused for typing
    try std.testing.expectEqual(search.Request.none, a.states.search.request); // no search fired yet
}

test "Enter on the Search tab opens info once results are loaded" {
    const items = [_]search.Match{.{ .name = "wget", .kind = .formula, .installed = false }};
    var a: App = .{ .active = .search };
    a.states.search.items = &items;
    a.states.search.phase = .loaded;
    a = step(a, .enter);
    try std.testing.expect(!a.editing); // a row is active, so Enter inspects it, not the box
    try std.testing.expectEqual(search.Request.info, a.states.search.request);
}

test "Enter on a data tab still routes as that tab's domain key, not a focus" {
    var a: App = .{ .active = .installed };
    a = step(a, .enter);
    try std.testing.expect(!a.editing);
    try std.testing.expectEqual(installed.Request.open_detail, a.states.installed.request);
}

test "renderFrame shows the committed filter and the editing footer" {
    var a: App = .{};
    a = step(a, ch('2')); // Installed tab: its box is a filter over the loaded list
    a = step(a, ch('/'));
    a = step(a, ch('j'));
    a = step(a, ch('q')); // 'q' is a literal char while editing, not quit
    try std.testing.expect(!a.quit);
    var buf: [8192]u8 = undefined;
    const out = renderFrame(&buf, &a, 80, 24);
    try std.testing.expect(std.mem.indexOf(u8, out, "filter: jq_") != null); // filter line with caret
    try std.testing.expect(std.mem.indexOf(u8, out, "accept") != null); // editing footer
}

test "the Search tab labels its input box as a query, not a filter" {
    var a: App = .{ .active = .search };
    a = step(a, ch('/'));
    a = step(a, ch('r'));
    a = step(a, ch('g'));
    var buf: [8192]u8 = undefined;
    const out = renderFrame(&buf, &a, 80, 24);
    try std.testing.expect(std.mem.indexOf(u8, out, "search: rg_") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "filter:") == null);
}

test "renderFrame draws a footer rule above a dimmed help line" {
    var a: App = .{};
    var buf: [8192]u8 = undefined;
    const out = renderFrame(&buf, &a, 80, 24);
    try std.testing.expect(std.mem.indexOf(u8, out, "─") != null); // horizontal rule
    try std.testing.expect(std.mem.indexOf(u8, out, color.Style.dim.code()) != null); // dimmed help: muted role == dim on the basic tier
    try std.testing.expect(std.mem.indexOf(u8, out, "quit") != null);
}

test "the footer carries the active tab's keys next to the global keys" {
    var a: App = .{ .active = .services };
    var buf: [8192]u8 = undefined;
    const out = renderFrame(&buf, &a, 100, 24);
    try std.testing.expect(std.mem.indexOf(u8, out, "s: start") != null); // the active tab's keys
    try std.testing.expect(std.mem.indexOf(u8, out, "switch") != null); // and the global keys
}

test "the Search footer folds in the basket count so i's batch is never a surprise" {
    const alloc = std.testing.allocator;
    var a: App = .{ .active = .search };
    var store: Store = .{};
    defer store.deinit(alloc);
    try store.search_selected.toggle(alloc, "bat", .formula);
    try store.search_selected.toggle(alloc, "redis", .formula);
    syncSearchSelectedCount(&a, &store); // the shell mirrors the basket onto the leaf
    var buf: [8192]u8 = undefined;
    const out = renderFrame(&buf, &a, 120, 24);
    try std.testing.expect(std.mem.indexOf(u8, out, "i: install 2 selected") != null);
}

test "the Search footer drops the count when the basket is empty" {
    var a: App = .{ .active = .search }; // empty basket → selected_count 0
    var buf: [8192]u8 = undefined;
    const out = renderFrame(&buf, &a, 120, 24);
    try std.testing.expect(std.mem.indexOf(u8, out, "i: install") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "selected") == null); // no count when empty
}

test "the footer wraps a long hint so the tab's action keys survive a narrow terminal" {
    var a: App = .{ .active = .outdated };
    var buf: [8192]u8 = undefined;
    // 70 cols is too narrow for the composed help+hint line on one row; truncating
    // would drop the tail (the tab's action keys), wrapping keeps them.
    const out = renderFrame(&buf, &a, 70, 24);
    try std.testing.expect(std.mem.indexOf(u8, out, "u: upgrade") != null); // the action key survives
    try std.testing.expect(std.mem.indexOf(u8, out, "switch") != null); // global keys still present
}

test "renderFooterText wraps into the row cap and drops any overflow below it" {
    var buf: [512]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    // Three rows' worth of text at width 8, but the cap is two: the third row
    // must not paint, or the footer would bleed into the content region.
    renderFooterText(&f, "aaaa bbbb cccc dddd eeee", color.roleCode(.muted), 6, 2, 8);
    const out = f.slice();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[6;1H") != null); // first text row
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[7;1H") != null); // second text row
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[8;1H") == null); // capped — no third row
}

test "a too-small terminal shows a wrapped, styled notice (width alone trips it)" {
    var a: App = .{};
    var buf: [8192]u8 = undefined;
    const out = renderFrame(&buf, &a, 10, 24); // width below the minimum, height fine
    try std.testing.expect(std.mem.indexOf(u8, out, "terminal") != null); // the notice shows
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[2;1H") != null); // wrapped onto a 2nd row
    try std.testing.expect(std.mem.indexOf(u8, out, color.Style.reset.code()) != null); // info colour applied + reset
}

test "the footer shows a per-tab loading status during a blocking refetch" {
    var a: App = .{ .active = .doctor, .loading = true };
    var buf: [8192]u8 = undefined;
    const out = renderFrame(&buf, &a, 100, 24);
    try std.testing.expect(std.mem.indexOf(u8, out, "Loading Doctor") != null);
    // Loading takes precedence over the help line so the freeze reads as intentional.
    try std.testing.expect(std.mem.indexOf(u8, out, "switch") == null);
}

test "the loading footer paints the spinner glyph ahead of the Loading text" {
    var a: App = .{ .active = .outdated, .loading = true, .spinner_frame = 0 };
    var buf: [8192]u8 = undefined;
    const out = renderFrame(&buf, &a, 100, 24);
    // The braille glyph for frame 0, immediately before the loading text.
    const expected = spinner_frames.frames[0] ++ " Loading Outdated";
    try std.testing.expect(std.mem.indexOf(u8, out, expected) != null);
}

test "a different spinner_frame paints a different glyph (the animation advances)" {
    var a: App = .{ .active = .services, .loading = true, .spinner_frame = 0 };
    var b: [8192]u8 = undefined;
    const f0 = try std.testing.allocator.dupe(u8, renderFrame(&b, &a, 100, 24));
    defer std.testing.allocator.free(f0);
    a.spinner_frame = 1;
    const f1 = renderFrame(&b, &a, 100, 24);
    // Distinct frames render distinct bytes, so a repaint per tick visibly ticks.
    try std.testing.expect(!std.mem.eql(u8, f0, f1));
    try std.testing.expect(std.mem.indexOf(u8, f1, spinner_frames.frames[1]) != null);
}

test "the loading glyph is deterministic per (state, cols, rows)" {
    var a: App = .{ .active = .doctor, .loading = true, .spinner_frame = 3 };
    var b1: [8192]u8 = undefined;
    var b2: [8192]u8 = undefined;
    // Same state + geometry → byte-identical frame, so a resize redraws the same
    // glyph rather than skipping or doubling the animation.
    try std.testing.expectEqualStrings(renderFrame(&b1, &a, 100, 24), renderFrame(&b2, &a, 100, 24));
}

test "the header paints a spinner on the outdated slot while the background audit runs" {
    // `tab_loading` is distinct from the footer `loading`: the header shows the
    // audit is computing, not frozen, while the input loop stays live.
    var a: App = .{ .active = .search, .spinner_frame = 0, .installed_count = 7 };
    a.tab_loading.insert(.outdated);
    var buf: [8192]u8 = undefined;
    const out = renderFrame(&buf, &a, 100, 24);
    const glyph = spinner_frames.frames[0];
    try std.testing.expect(std.mem.indexOf(u8, out, glyph ++ " outdated") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "7 kegs") != null); // the cheap count is live at launch
}

test "a tab entered mid-fetch reads as Loading in the footer, not an empty list" {
    // The freeze this whole feature removes: navigating *into* a slow tab while
    // its audit runs must show it is still computing, not a done-looking blank.
    var a: App = .{ .active = .doctor, .spinner_frame = 0 };
    a.tab_loading.insert(.doctor);
    var buf: [8192]u8 = undefined;
    const out = renderFrame(&buf, &a, 100, 24);
    try std.testing.expect(std.mem.indexOf(u8, out, "Loading Doctor") != null);
}

test "a background fetch on an inactive tab leaves the active footer alone" {
    // Doctor audits in the background while the user sits on a loaded Installed:
    // the footer must show Installed's help, not a spurious Loading.
    var a: App = .{ .active = .installed };
    a.tab_loading.insert(.doctor);
    var buf: [8192]u8 = undefined;
    const out = renderFrame(&buf, &a, 100, 24);
    try std.testing.expect(std.mem.indexOf(u8, out, "Loading") == null);
}

// A pipe stands in for an fd; a held-open write end is a "slow" source with no
// EOF, a closed one is EOF — enough to drive the multiplexed wait.
fn testPipe() ![2]std.c.fd_t {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    return fds;
}

test "pollMux services a queued keypress before a fetch child's EOF" {
    const tty = try testPipe();
    defer _ = std.c.close(tty[0]);
    defer _ = std.c.close(tty[1]);
    const child = try testPipe();
    defer _ = std.c.close(child[0]);
    defer _ = std.c.close(child[1]); // write end open == audit still in flight, no EOF

    _ = std.c.write(tty[1], "q", 1); // a keypress lands while the audit runs

    // The freeze bug: a loop that waits on the child blocks here. The fixed loop
    // reports the tty ready and the keypress is serviced live.
    try std.testing.expectEqual(MuxEvent.tty, try pollMux(tty[0], &.{child[0]}, 1000));
}

test "pollMux lets the tty win when both the tty and a fetch are ready" {
    const tty = try testPipe();
    defer _ = std.c.close(tty[0]);
    defer _ = std.c.close(tty[1]);
    const child = try testPipe();
    defer _ = std.c.close(child[0]);
    defer _ = std.c.close(child[1]);

    _ = std.c.write(tty[1], "x", 1);
    _ = std.c.write(child[1], "{}", 2);
    try std.testing.expectEqual(MuxEvent.tty, try pollMux(tty[0], &.{child[0]}, 1000)); // input never starved
}

test "pollMux reports the ready fetch by index, even among several" {
    const tty = try testPipe();
    defer _ = std.c.close(tty[0]);
    defer _ = std.c.close(tty[1]);
    const a = try testPipe(); // open: no EOF
    defer _ = std.c.close(a[0]);
    defer _ = std.c.close(a[1]);
    const b = try testPipe();
    defer _ = std.c.close(b[0]);
    _ = std.c.close(b[1]); // EOF on the middle fetch
    const c = try testPipe(); // open: no EOF
    defer _ = std.c.close(c[0]);
    defer _ = std.c.close(c[1]);
    switch (try pollMux(tty[0], &.{ a[0], b[0], c[0] }, 1000)) {
        .fetch => |i| try std.testing.expectEqual(@as(usize, 1), i), // the one at EOF, not the first slot
        else => return error.UnexpectedEvent,
    }
}

test "pollMux times out when nothing is ready, so the spinner can tick" {
    const tty = try testPipe();
    defer _ = std.c.close(tty[0]);
    defer _ = std.c.close(tty[1]);
    const child = try testPipe();
    defer _ = std.c.close(child[0]);
    defer _ = std.c.close(child[1]);
    try std.testing.expectEqual(MuxEvent.timeout, try pollMux(tty[0], &.{child[0]}, 1));
}

// Drive a started fetch to completion with no tty (fd −1 is ignored by `poll`),
// so the lifecycle — drain → reap → apply → repaint — runs against a real child
// exactly as the loop drives it, minus the keypress side.
fn driveFetchToEnd(io: std.Io, allocator: std.mem.Allocator, app: *App, store: *Store, fetches: *Fetches, t: Tab) !void {
    var frame: []u8 = try allocator.alloc(u8, 256);
    defer allocator.free(frame);
    const painter = testPainter(&frame); // repaint writes to fd −1 (a no-op); the buffer may grow
    while (fetches.getPtr(t).* != null) _ = try serviceFetches(io, allocator, painter, fetches, app, store);
}

test "startTabFetch kicks off the outdated audit, flags loading, and lands a known zero" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    var app: App = .{ .mt_path = "/usr/bin/true" }; // exit 0, no output == fresh prefix
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    var fetches: Fetches = .initFill(null);
    startTabFetch(t.io(), std.testing.allocator, &fetches, &app, .outdated);
    try std.testing.expect(fetches.getPtr(.outdated).* != null);
    try std.testing.expect(app.tab_loading.contains(.outdated)); // header spins from the first frame
    try driveFetchToEnd(t.io(), std.testing.allocator, &app, &store, &fetches, .outdated);
    try std.testing.expectEqual(@as(?usize, 0), app.outdated_count); // empty payload is a known zero
    try std.testing.expect(!app.tab_loading.contains(.outdated)); // cleared when the fetch lands
    try std.testing.expect(!app.banner.isSet());
}

test "startTabFetch is a quiet no-op on a spawn fault, never flagging loading" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    var app: App = .{ .mt_path = "/nonexistent/malt_outdated_probe" };
    var fetches: Fetches = .initFill(null);
    startTabFetch(t.io(), std.testing.allocator, &fetches, &app, .outdated);
    try std.testing.expect(fetches.getPtr(.outdated).* == null); // nothing to drive
    try std.testing.expect(!app.tab_loading.contains(.outdated)); // a failed kickoff stays unflagged
    try std.testing.expect(app.outdated_count == null);
    try std.testing.expect(!app.banner.isSet()); // launch-time, no nag
}

test "startTabFetch skips a tab whose audit is already in flight" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    var app: App = .{ .mt_path = "/usr/bin/true" };
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    var fetches: Fetches = .initFill(null);
    startTabFetch(t.io(), std.testing.allocator, &fetches, &app, .outdated);
    const fd_before = fetches.getPtr(.outdated).*.?.fd;
    startTabFetch(t.io(), std.testing.allocator, &fetches, &app, .outdated); // second call: no-op
    try std.testing.expectEqual(fd_before, fetches.getPtr(.outdated).*.?.fd); // same child, not respawned
    try driveFetchToEnd(t.io(), std.testing.allocator, &app, &store, &fetches, .outdated);
}

test "a background outdated fetch parses a real child's document into the tab" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    const child = try std.process.spawn(t.io(), .{
        .argv = &.{ "/bin/echo", "{\"outdated\":[{\"name\":\"wget\",\"installed\":\"1\",\"latest\":\"2\",\"type\":\"formula\",\"pinned\":false}]}" },
        .stdout = .pipe,
        .stderr = .ignore,
    });
    var app: App = .{};
    app.tab_loading.insert(.outdated);
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    var fetches: Fetches = .initFill(null);
    fetches.set(.outdated, .{ .tab = .outdated, .child = child, .fd = child.stdout.?.handle, .max_ok_exit = 0 });
    try driveFetchToEnd(t.io(), std.testing.allocator, &app, &store, &fetches, .outdated);
    try std.testing.expectEqual(@as(?usize, 1), app.outdated_count); // header count
    try std.testing.expectEqual(@as(usize, 1), app.states.outdated.items.len); // the tab body, too
    try std.testing.expect(!app.tab_loading.contains(.outdated));
}

test "a malformed payload banners and keeps the outdated count unknown, never zero" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    const child = try std.process.spawn(t.io(), .{ .argv = &.{ "/bin/echo", "garbage" }, .stdout = .pipe, .stderr = .ignore });
    var app: App = .{};
    app.tab_loading.insert(.outdated);
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    var fetches: Fetches = .initFill(null);
    fetches.set(.outdated, .{ .tab = .outdated, .child = child, .fd = child.stdout.?.handle, .max_ok_exit = 0 });
    try driveFetchToEnd(t.io(), std.testing.allocator, &app, &store, &fetches, .outdated);
    try std.testing.expect(app.outdated_count == null); // unknown (`—`), not 0
    try std.testing.expectEqualStrings("outdated refresh failed: BadJson", app.banner.slice());
}

test "dropUpgradedRows removes upgraded rows in place and preserves kept checked state" {
    var app: App = .{};
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    const json =
        \\{"outdated":[
        \\{"name":"a","installed":"1","latest":"2","type":"formula","pinned":false},
        \\{"name":"b","installed":"1","latest":"2","type":"formula","pinned":false},
        \\{"name":"c","installed":"1","latest":"2","type":"formula","pinned":false}
        \\]}
    ;
    try applyOutdatedBytes(std.testing.allocator, &app, &store, json);
    // Check a and c (b is the one being upgraded); the kept rows must stay checked.
    store.outdated_checked[0] = true;
    store.outdated_checked[2] = true;

    try dropUpgradedRows(std.testing.allocator, &app, &store, &.{.{ .name = "b", .kind = .formula }});

    try std.testing.expectEqual(@as(usize, 2), store.outdated.?.items.len);
    try std.testing.expectEqualStrings("a", store.outdated.?.items[0].name);
    try std.testing.expectEqualStrings("c", store.outdated.?.items[1].name);
    try std.testing.expectEqual(@as(?usize, 2), app.outdated_count);
    try std.testing.expectEqual(@as(usize, 2), app.states.outdated.items.len);
    // a and c stay checked in the rebuilt lockstep buffer.
    try std.testing.expect(app.states.outdated.checked[0]);
    try std.testing.expect(app.states.outdated.checked[1]);
}

test "dropUpgradedRows on an unloaded store is a no-op" {
    var app: App = .{};
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    try dropUpgradedRows(std.testing.allocator, &app, &store, &.{.{ .name = "anything", .kind = .formula }});
    try std.testing.expect(store.outdated == null);
}

test "dropUpgradedRows drops only the upgraded kind when a formula and cask share a name" {
    var app: App = .{};
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    const json =
        \\{"outdated":[
        \\{"name":"docker","installed":"1","latest":"2","type":"formula","pinned":false},
        \\{"name":"docker","installed":"1","latest":"2","type":"cask","pinned":false}
        \\]}
    ;
    try applyOutdatedBytes(std.testing.allocator, &app, &store, json);
    // Only the formula docker was upgraded; the same-named cask must remain.
    try dropUpgradedRows(std.testing.allocator, &app, &store, &.{.{ .name = "docker", .kind = .formula }});
    try std.testing.expectEqual(@as(usize, 1), store.outdated.?.items.len);
    try std.testing.expectEqual(outdated_json.Kind.cask, store.outdated.?.items[0].kind);
}

test "dropUpgradedRows keeps every row when no upgraded ref matches" {
    var app: App = .{};
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    const json =
        \\{"outdated":[
        \\{"name":"a","installed":"1","latest":"2","type":"formula","pinned":false},
        \\{"name":"b","installed":"1","latest":"2","type":"formula","pinned":false}
        \\]}
    ;
    try applyOutdatedBytes(std.testing.allocator, &app, &store, json);
    try dropUpgradedRows(std.testing.allocator, &app, &store, &.{.{ .name = "z", .kind = .formula }});
    try std.testing.expectEqual(@as(usize, 2), store.outdated.?.items.len);
}

test "dropUpgradedRows clears the list when every row was upgraded" {
    var app: App = .{};
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    const json =
        \\{"outdated":[
        \\{"name":"a","installed":"1","latest":"2","type":"formula","pinned":false},
        \\{"name":"b","installed":"1","latest":"2","type":"formula","pinned":false}
        \\]}
    ;
    try applyOutdatedBytes(std.testing.allocator, &app, &store, json);
    try dropUpgradedRows(std.testing.allocator, &app, &store, &.{ .{ .name = "a", .kind = .formula }, .{ .name = "b", .kind = .formula } });
    try std.testing.expectEqual(@as(usize, 0), store.outdated.?.items.len);
    try std.testing.expectEqual(@as(?usize, 0), app.outdated_count);
}

test "a non-zero child exit fails the fetch without parsing a half-written doc" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    const child = try std.process.spawn(t.io(), .{ .argv = &.{"/usr/bin/false"}, .stdout = .pipe, .stderr = .ignore });
    var app: App = .{ .outdated_count = 5 }; // a prior good count
    app.tab_loading.insert(.outdated);
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    var fetches: Fetches = .initFill(null);
    fetches.set(.outdated, .{ .tab = .outdated, .child = child, .fd = child.stdout.?.handle, .max_ok_exit = 0 });
    try driveFetchToEnd(t.io(), std.testing.allocator, &app, &store, &fetches, .outdated);
    try std.testing.expectEqual(@as(?usize, 5), app.outdated_count); // a bad exit keeps the last-good, never 0
    try std.testing.expect(app.banner.isSet());
}

test "the doctor fetch tolerates a severity exit (≤2) as success" {
    // `mt doctor` exits 1/2 by severity while still succeeding; a severity exit
    // (here exit 1, via `false`) with no findings must land as a clean empty tab,
    // not a failure banner — the same exit code that fails a max-0 tab. The fail
    // direction (max-0, exit 1 → banner) is covered by the non-zero-exit test.
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    const child = try std.process.spawn(t.io(), .{ .argv = &.{"/usr/bin/false"}, .stdout = .pipe, .stderr = .ignore });
    var app: App = .{};
    app.tab_loading.insert(.doctor);
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    var fetches: Fetches = .initFill(null);
    fetches.set(.doctor, .{ .tab = .doctor, .child = child, .fd = child.stdout.?.handle, .max_ok_exit = 2 });
    try driveFetchToEnd(t.io(), std.testing.allocator, &app, &store, &fetches, .doctor);
    try std.testing.expect(!app.banner.isSet()); // exit 1 ≤ 2 is OK for doctor
    try std.testing.expect(!app.tab_loading.contains(.doctor));
}

test "a background fetch accumulates a payload spanning multiple reads" {
    // A real outdated list exceeds one 4096-byte read; the drain must accumulate
    // across poll turns, not reset the buffer per read.
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(std.testing.allocator);
    try doc.appendSlice(std.testing.allocator, "{\"outdated\":[");
    const rows = 150;
    for (0..rows) |i| {
        if (i != 0) try doc.append(std.testing.allocator, ',');
        var rb: [128]u8 = undefined;
        const row = try std.fmt.bufPrint(&rb, "{{\"name\":\"pkg{d}\",\"installed\":\"1.0.0\",\"latest\":\"2.0.0\",\"type\":\"formula\",\"pinned\":false}}", .{i});
        try doc.appendSlice(std.testing.allocator, row);
    }
    try doc.appendSlice(std.testing.allocator, "]}");
    try std.testing.expect(doc.items.len > 4096); // genuinely spans more than one 4096-byte read
    const child = try std.process.spawn(t.io(), .{ .argv = &.{ "/bin/echo", doc.items }, .stdout = .pipe, .stderr = .ignore });
    var app: App = .{};
    app.tab_loading.insert(.outdated);
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    var fetches: Fetches = .initFill(null);
    fetches.set(.outdated, .{ .tab = .outdated, .child = child, .fd = child.stdout.?.handle, .max_ok_exit = 0 });
    try driveFetchToEnd(t.io(), std.testing.allocator, &app, &store, &fetches, .outdated);
    try std.testing.expectEqual(@as(?usize, rows), app.outdated_count); // every row across every chunk
}

test "an overflowing fetch kills the live child and fails to last-good" {
    // A child that never stops emitting (no EOF) must not grow the buffer without
    // bound: past the cap, kill the still-running child and finish failed, keeping
    // the last-good count rather than a partial parse.
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    const child = try std.process.spawn(t.io(), .{ .argv = &.{"/usr/bin/yes"}, .stdout = .pipe, .stderr = .ignore });
    var app: App = .{ .outdated_count = 5 }; // a prior good count
    app.tab_loading.insert(.outdated);
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    var fetches: Fetches = .initFill(null);
    fetches.set(.outdated, .{ .tab = .outdated, .child = child, .fd = child.stdout.?.handle, .max_ok_exit = 0 });
    try driveFetchToEnd(t.io(), std.testing.allocator, &app, &store, &fetches, .outdated);
    try std.testing.expectEqual(@as(?usize, 5), app.outdated_count); // last-good kept, not a partial
    try std.testing.expect(app.banner.isSet());
    try std.testing.expect(!app.tab_loading.contains(.outdated));
}

test "reapTabFetch tears down a still-running fetch without a hang or leak" {
    // The user quit before the audit finished: kill+reap the live child and free
    // the buffer. The value is no zombie + buf freed + no hang — the test
    // allocator catches a leaked buffer.
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    const child = try std.process.spawn(t.io(), .{ .argv = &.{ "/bin/sleep", "30" }, .stdout = .pipe, .stderr = .ignore });
    var f: TabFetch = .{ .tab = .doctor, .child = child, .fd = child.stdout.?.handle, .max_ok_exit = 2 };
    reapTabFetch(t.io(), std.testing.allocator, &f);
}

test "renderFrame uses cursor positioning and never emits a raw newline" {
    var a: App = .{};
    var buf: [8192]u8 = undefined;
    const out = renderFrame(&buf, &a, 80, 24);
    try std.testing.expect(std.mem.indexOfScalar(u8, out, '\n') == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Installed") != null);
}

test "a recoverable banner renders in the footer in place of the help line" {
    var a: App = .{};
    a.banner.set("info for jq failed", "BadJson");
    var buf: [8192]u8 = undefined;
    const out = renderFrame(&buf, &a, 80, 24);
    try std.testing.expect(std.mem.indexOf(u8, out, "info for jq failed: BadJson") != null);
    // The banner takes the help line's slot, so the help text is not shown.
    try std.testing.expect(std.mem.indexOf(u8, out, "q: quit") == null);
}

test "a banner truncates width-aware to the terminal columns" {
    var a: App = .{};
    a.banner.set("info for some-very-long-package-name failed", "ChildFailed");
    var buf: [8192]u8 = undefined;
    const out = renderFrame(&buf, &a, 24, 24); // narrow terminal
    // The full message cannot have been painted verbatim into 24 columns.
    try std.testing.expect(std.mem.indexOf(u8, out, "info for some-very-long-package-name failed: ChildFailed") == null);
}

test "any keypress clears a transient banner" {
    var a: App = .{};
    a.banner.set("uninstall failed", "ChildFailed");
    try std.testing.expect(a.banner.isSet());
    a = step(a, .down); // a navigation key dismisses the stale banner
    try std.testing.expect(!a.banner.isSet());
}

test "renderFrame falls back cleanly on a too-small terminal" {
    var a: App = .{};
    var buf: [8192]u8 = undefined;
    const out = renderFrame(&buf, &a, 80, 2); // wide enough to read the message, too few rows
    try std.testing.expect(std.mem.indexOf(u8, out, "too small") != null);
}

test "renderFrame reflows on resize from the same state" {
    var a: App = .{};
    var b1: [8192]u8 = undefined;
    var b2: [8192]u8 = undefined;
    const small = renderFrame(&b1, &a, 40, 10);
    const large = renderFrame(&b2, &a, 120, 40);
    try std.testing.expect(!std.mem.eql(u8, small, large));
}

test "a delegated mutation marks every other tab dirty and keeps the active tab fresh" {
    var a: App = .{ .active = .outdated };
    markStaleAfterMutation(&a);
    try std.testing.expect(!a.dirty.contains(.outdated)); // refreshed inline, still fresh
    try std.testing.expect(a.dirty.contains(.installed));
    try std.testing.expect(a.dirty.contains(.services));
    try std.testing.expect(a.dirty.contains(.doctor));
}

test "entering a dirty tab consumes the flag so its refetch runs at most once" {
    var a: App = .{ .active = .installed };
    markStaleAfterMutation(&a);
    try std.testing.expect(takeDirty(&a, .doctor)); // first entry → refetch
    try std.testing.expect(!takeDirty(&a, .doctor)); // now fresh → no refetch
}

test "a tab that was never marked dirty does not trigger a refetch" {
    var a: App = .{};
    try std.testing.expect(!takeDirty(&a, .outdated));
}

test "every data tab is dirty at launch so none blocks the first paint" {
    var a: App = .{}; // opens on Search
    initLaunchDirty(&a);
    // Installed joins the other three: no eager load, so launch never blocks input.
    try std.testing.expect(a.dirty.contains(.installed));
    try std.testing.expect(a.dirty.contains(.outdated));
    try std.testing.expect(a.dirty.contains(.services));
    try std.testing.expect(a.dirty.contains(.doctor));
    try std.testing.expect(!a.dirty.contains(.search)); // active tab renders without data
}

test "banner formats op + reason and reports set/clear" {
    var b: Banner = .{};
    try std.testing.expect(!b.isSet());
    b.set("info for jq failed", "BadJson");
    try std.testing.expect(b.isSet());
    try std.testing.expectEqualStrings("info for jq failed: BadJson", b.slice());
    b.clear();
    try std.testing.expect(!b.isSet());
    try std.testing.expectEqualStrings("", b.slice());
}

test "banner sanitizes a child-derived op so a package name cannot inject escapes" {
    var b: Banner = .{};
    // A hostile tap could name a package with an OSC title-set; it must be dropped.
    b.set("info for \x1b]0;pwn\x07evil failed", "BadJson");
    try std.testing.expect(std.mem.indexOfScalar(u8, b.slice(), 0x1b) == null); // no stray ESC
    try std.testing.expect(std.mem.indexOf(u8, b.slice(), "evil failed: BadJson") != null);
}

test "banner truncates an over-cap op to the fixed buffer without overflow" {
    var b: Banner = .{};
    var huge: [banner_max * 2]u8 = undefined;
    @memset(&huge, 'x');
    b.set(&huge, "BadJson");
    try std.testing.expect(b.isSet());
    try std.testing.expect(b.slice().len <= banner_max); // bounded, no overrun
}

test "a newline in a child-derived op cannot inject an extra footer frame line" {
    // term_sanitize lets \n through; the footer paints via putContent, which drops
    // it, so a package name with an embedded newline can't split the frame.
    var a: App = .{};
    a.banner.set("info for ev\nil failed", "BadJson");
    var buf: [8192]u8 = undefined;
    const out = renderFrame(&buf, &a, 80, 24);
    try std.testing.expect(std.mem.indexOfScalar(u8, out, '\n') == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "evil failed: BadJson") != null); // \n stripped, text joined
}

/// True when `out` paints a dim separator at `row`: the cursor move to that row,
/// the muted SGR, then a box-drawing rule. Matches the exact chrome signature so
/// Doctor's muted "No findings." hint at the same row doesn't read as a rule.
fn hasSeparatorAtRow(out: []const u8, comptime row: u16) bool {
    const cup = std.fmt.comptimePrint("\x1b[{d};1H", .{row});
    const at = std.mem.indexOf(u8, out, cup) orelse return false;
    const after = out[at + cup.len ..];
    const muted = color.roleCode(.muted);
    if (!std.mem.startsWith(u8, after, muted)) return false;
    return std.mem.startsWith(u8, after[muted.len..], "─");
}

test "a dim rule separates the filter from the content; Doctor keeps its own" {
    var buf: [8192]u8 = undefined;
    var a: App = .{}; // Search — a list-style tab
    const out = renderFrame(&buf, &a, 80, 24);
    // Content starts at row 4 (header 1, tab-bar 2, filter 3); the rule sits there.
    try std.testing.expect(hasSeparatorAtRow(out, 4));

    // Doctor paints its own band rule at the content top, so the shell must not
    // add one there — or the tab would show a doubled rule.
    var d: App = .{ .active = .doctor };
    const dout = renderFrame(&buf, &d, 80, 24);
    try std.testing.expect(!hasSeparatorAtRow(dout, 4));
}

test "classify splits recoverable backend faults from fatal terminal/OOM faults" {
    // Child-process + parse faults: survivable — show a banner, keep the session.
    try std.testing.expectEqual(ErrorClass.recoverable, classify(error.SpawnFailed));
    try std.testing.expectEqual(ErrorClass.recoverable, classify(error.WaitFailed));
    try std.testing.expectEqual(ErrorClass.recoverable, classify(error.ChildFailed));
    try std.testing.expectEqual(ErrorClass.recoverable, classify(error.EmptyOutput));
    try std.testing.expectEqual(ErrorClass.recoverable, classify(error.ReadFailed)); // child pipe
    try std.testing.expectEqual(ErrorClass.recoverable, classify(error.BadJson));
    // Terminal-integrity + OOM: fatal — restore and exit (the TUI-012 guarantee).
    try std.testing.expectEqual(ErrorClass.fatal, classify(error.NotATty));
    try std.testing.expectEqual(ErrorClass.fatal, classify(error.WriteFailed));
    try std.testing.expectEqual(ErrorClass.fatal, classify(error.TermiosFailed));
    try std.testing.expectEqual(ErrorClass.fatal, classify(error.OutOfMemory));
}

test "a failed list refresh names the op in the banner and keeps the last-good rows" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    var app: App = .{ .mt_path = "/bin/echo" }; // echo emits non-JSON → parse fails
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    try std.testing.expectError(error.BadJson, loadInstalled(t.io(), std.testing.allocator, &app, &store));
    try std.testing.expectEqualStrings("list refresh failed: BadJson", app.banner.slice());
    try std.testing.expectEqual(@as(usize, 0), app.states.installed.items.len); // last-good kept
}

// A fresh prefix (no db yet) makes every `mt … --json` read exit 0 with no
// output. That is an empty Cellar, not a failure — the dashboard must open and
// each tab show an empty list, never crash on `EmptyOutput`. `/usr/bin/true`
// reproduces it exactly: exit 0, zero bytes.
test "loadInstalled treats an exit-0 empty response (fresh prefix) as an empty tab" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    var app: App = .{ .mt_path = "/usr/bin/true" };
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    try loadInstalled(t.io(), std.testing.allocator, &app, &store);
    try std.testing.expectEqual(@as(usize, 0), app.states.installed.items.len);
    try std.testing.expect(!app.banner.isSet());
}

test "the keg-count read stays cheap — list --json, no --size/--linked walk" {
    const argv = try installedCountArgv(std.testing.allocator, "/opt/homebrew/bin/mt");
    defer std.testing.allocator.free(argv);
    try std.testing.expectEqual(@as(usize, 3), argv.len); // [mt, list, --json]
    try std.testing.expectEqualStrings("list", argv[1]);
    try std.testing.expectEqualStrings("--json", argv[2]);
    for (argv) |a| { // the keg-dir walk flags must never sneak into the count path
        try std.testing.expect(!std.mem.eql(u8, a, "--size"));
        try std.testing.expect(!std.mem.eql(u8, a, "--linked"));
    }
}

test "refreshInstalledCount populates the keg count on a fresh prefix (0, not unknown)" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    var app: App = .{ .mt_path = "/usr/bin/true" }; // exit 0, no output = empty Cellar
    try refreshInstalledCount(t.io(), std.testing.allocator, &app);
    try std.testing.expectEqual(@as(?usize, 0), app.installed_count); // populated, never null
    try std.testing.expect(!app.banner.isSet());
}

test "the post-install count refresh overwrites a stale count without entering Installed" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    // The cross-tab-install gap: a count from before the mutation, with Installed
    // marked dirty (its full --size --linked payload reloads only on entry).
    var app: App = .{ .mt_path = "/usr/bin/true", .active = .search, .installed_count = 6 };
    app.dirty.insert(.installed);
    try refreshInstalledCount(t.io(), std.testing.allocator, &app);
    try std.testing.expectEqual(@as(?usize, 0), app.installed_count); // live again, not the stale 6
    try std.testing.expect(app.dirty.contains(.installed)); // full payload still loads lazily on entry
}

test "a broken keg-count read banners and leaves the prior count untouched" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    var app: App = .{ .mt_path = "/bin/echo", .installed_count = 6 }; // echo emits non-JSON → parse fails
    try std.testing.expectError(error.BadJson, refreshInstalledCount(t.io(), std.testing.allocator, &app));
    try std.testing.expectEqualStrings("keg count refresh failed: BadJson", app.banner.slice());
    try std.testing.expectEqual(@as(?usize, 6), app.installed_count); // a failed read keeps the last-good count
}

test "loadOutdated treats an exit-0 empty response (fresh prefix) as an empty tab" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    var app: App = .{ .mt_path = "/usr/bin/true" };
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    var frame: []u8 = &.{};
    try loadOutdated(t.io(), std.testing.allocator, testPainter(&frame), &app, &store);
    try std.testing.expectEqual(@as(usize, 0), app.states.outdated.items.len);
    try std.testing.expect(!app.banner.isSet());
}

test "loadServices treats an exit-0 empty response (fresh prefix) as an empty tab" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    var app: App = .{ .mt_path = "/usr/bin/true" };
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    var frame: []u8 = &.{};
    try loadServices(t.io(), std.testing.allocator, testPainter(&frame), &app, &store);
    try std.testing.expectEqual(@as(usize, 0), app.states.services.items.len);
    try std.testing.expect(!app.banner.isSet());
}

test "loadDoctor treats an exit-0 empty response (fresh prefix) as an empty tab" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    var app: App = .{ .mt_path = "/usr/bin/true" };
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    var frame: []u8 = &.{};
    try loadDoctor(t.io(), std.testing.allocator, testPainter(&frame), &app, &store);
    try std.testing.expectEqual(@as(usize, 0), app.states.doctor.items.len);
    try std.testing.expect(!app.banner.isSet());
}

test "applyDoctorParse points the Doctor tab at the parsed findings and reclaimable stats" {
    var app: App = .{};
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    const bytes =
        \\{"checks":[{"id":"a","severity":"warn","title":"A","fixable":true,"fix_class":"stale_lock"}],
        \\"cask_history":{"retained_versions":3,"bytes":4096},"tap_cache":{"bytes":512}}
    ;
    const parsed = try doctor_json.parse(std.testing.allocator, bytes);
    applyDoctorParse(&app, &store, parsed);
    try std.testing.expectEqual(@as(usize, 1), app.states.doctor.items.len);
    // The reclaimable figures ride through to the tab so the band can show them.
    try std.testing.expectEqual(@as(u64, 4096), app.states.doctor.stats.cask_bytes);
    try std.testing.expectEqual(@as(u64, 512), app.states.doctor.stats.tap_cache_bytes);
    try std.testing.expectEqual(@as(usize, 3), app.states.doctor.stats.retained_versions);
}

test "a failed info read names the package in the banner and leaves the pane closed" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    var app: App = .{ .mt_path = "/bin/echo" };
    const items = [_]list_json.Pkg{.{ .name = "jq", .version = "1", .kind = .formula, .pinned = false, .size_bytes = null, .linked = null }};
    app.states.installed.items = &items;
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    try std.testing.expectError(error.BadJson, openDetail(t.io(), std.testing.allocator, &app, &store));
    try std.testing.expectEqualStrings("info for jq failed: BadJson", app.banner.slice());
    try std.testing.expect(app.states.installed.detail == null); // the pane never opened
}

test "upgradeArgv builds `mt upgrade <names...>` with exactly the checked names in order" {
    const items = [_]outdated.Row{
        .{ .name = "wget", .installed = "1", .latest = "2", .kind = .formula, .pinned = false, .tap = "" },
        .{ .name = "curl", .installed = "1", .latest = "2", .kind = .formula, .pinned = true, .tap = "" },
        .{ .name = "ffmpeg", .installed = "1", .latest = "2", .kind = .formula, .pinned = false, .tap = "" },
    };
    var checked = [_]bool{ true, true, true }; // curl is pinned → must be excluded
    var st: outdated.State = .{ .items = &items, .checked = &checked };
    const argv = (try upgradeArgv(std.testing.allocator, "/opt/homebrew/bin/mt", &st)).?;
    defer std.testing.allocator.free(argv);
    try std.testing.expectEqual(@as(usize, 4), argv.len); // mt, upgrade, two names
    try std.testing.expectEqualStrings("/opt/homebrew/bin/mt", argv[0]);
    try std.testing.expectEqualStrings("upgrade", argv[1]);
    try std.testing.expectEqualStrings("wget", argv[2]);
    try std.testing.expectEqualStrings("ffmpeg", argv[3]); // pinned curl skipped
}

test "upgradeArgv returns null for an empty selection so the upgrade is a no-op" {
    const items = [_]outdated.Row{
        .{ .name = "wget", .installed = "1", .latest = "2", .kind = .formula, .pinned = false, .tap = "" },
    };
    var checked = [_]bool{false};
    var st: outdated.State = .{ .items = &items, .checked = &checked };
    try std.testing.expect((try upgradeArgv(std.testing.allocator, "/bin/mt", &st)) == null);
}

test "a failed outdated refresh names the op in the banner and keeps the last-good rows" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    var app: App = .{ .mt_path = "/bin/echo" }; // echo emits non-JSON → parse fails
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    var frame: []u8 = &.{};
    try std.testing.expectError(error.BadJson, loadOutdated(t.io(), std.testing.allocator, testPainter(&frame), &app, &store));
    try std.testing.expectEqualStrings("outdated refresh failed: BadJson", app.banner.slice());
    try std.testing.expectEqual(@as(usize, 0), app.states.outdated.items.len); // last-good kept
}

test "serviceActionArgv builds `mt services <action> <name>` for the selected service" {
    const items = [_]services.Row{
        .{ .name = "redis", .state = "running", .auto_start = true, .keg_name = "redis" },
        .{ .name = "postgresql", .state = "stopped", .auto_start = false, .keg_name = "postgresql@16" },
    };
    var st: services.State = .{ .items = &items };
    st.chrome.view.selected = 1; // postgresql
    const argv = (try serviceActionArgv(std.testing.allocator, "/opt/homebrew/bin/mt", "restart", &st)).?;
    defer std.testing.allocator.free(argv);
    try std.testing.expectEqual(@as(usize, 4), argv.len);
    try std.testing.expectEqualStrings("/opt/homebrew/bin/mt", argv[0]);
    try std.testing.expectEqualStrings("services", argv[1]);
    try std.testing.expectEqualStrings("restart", argv[2]);
    try std.testing.expectEqualStrings("postgresql", argv[3]); // the selected row's name
}

test "serviceActionArgv returns null when nothing is selected so the action is a no-op" {
    const st: services.State = .{ .items = &.{} };
    try std.testing.expect((try serviceActionArgv(std.testing.allocator, "/bin/mt", "start", &st)) == null);
}

test "a failed services refresh names the op in the banner and keeps the last-good rows" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    var app: App = .{ .mt_path = "/bin/echo" }; // echo emits non-JSON → parse fails
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    var frame: []u8 = &.{};
    try std.testing.expectError(error.BadJson, loadServices(t.io(), std.testing.allocator, testPainter(&frame), &app, &store));
    try std.testing.expectEqualStrings("services refresh failed: BadJson", app.banner.slice());
    try std.testing.expectEqual(@as(usize, 0), app.states.services.items.len); // last-good kept
}

test "doctorFixArgv builds `mt doctor --fix <class>` from the finding's fix_class, not its id" {
    const items = [_]doctor.Row{
        .{ .id = "sqlite_integrity", .severity = .err, .title = "SQLite integrity", .fixable = false, .fix_class = .none },
        .{ .id = "orphaned_store_entries", .severity = .warn, .title = "Orphaned store entries", .fixable = true, .fix_class = .orphaned_store },
    };
    var st: doctor.State = .{ .items = &items };
    st.chrome.view.selected = 1; // the fixable finding (display order: err then warn)
    const argv = (try doctorFixArgv(std.testing.allocator, "/opt/homebrew/bin/mt", &st)).?;
    defer std.testing.allocator.free(argv);
    try std.testing.expectEqual(@as(usize, 4), argv.len);
    try std.testing.expectEqualStrings("/opt/homebrew/bin/mt", argv[0]);
    try std.testing.expectEqualStrings("doctor", argv[1]);
    try std.testing.expectEqualStrings("--fix", argv[2]);
    try std.testing.expectEqualStrings("orphaned_store", argv[3]); // the class, not "orphaned_store_entries"
}

test "doctorFixArgv returns null for a non-fixable selection so f is a no-op" {
    const items = [_]doctor.Row{
        .{ .id = "sqlite_integrity", .severity = .err, .title = "SQLite integrity", .fixable = false, .fix_class = .none },
    };
    const st: doctor.State = .{ .items = &items };
    try std.testing.expect((try doctorFixArgv(std.testing.allocator, "/bin/mt", &st)) == null);
}

test "doctorFixArgv returns null on an empty list" {
    const st: doctor.State = .{ .items = &.{} };
    try std.testing.expect((try doctorFixArgv(std.testing.allocator, "/bin/mt", &st)) == null);
}

test "a failed doctor refresh names the op in the banner and keeps the last-good findings" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    var app: App = .{ .mt_path = "/bin/echo" }; // echo emits non-JSON → parse fails
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    var frame: []u8 = &.{};
    try std.testing.expectError(error.BadJson, loadDoctor(t.io(), std.testing.allocator, testPainter(&frame), &app, &store));
    try std.testing.expectEqualStrings("doctor refresh failed: BadJson", app.banner.slice());
    try std.testing.expectEqual(@as(usize, 0), app.states.doctor.items.len); // last-good kept
}

test "searchArgv builds `mt search <query> --json` for the committed query" {
    var st: search.State = .{};
    st.chrome.filter.push("fire");
    const argv = (try searchArgv(std.testing.allocator, "/opt/homebrew/bin/mt", &st)).?;
    defer std.testing.allocator.free(argv);
    try std.testing.expectEqual(@as(usize, 4), argv.len); // mt, search, query, --json
    try std.testing.expectEqualStrings("/opt/homebrew/bin/mt", argv[0]);
    try std.testing.expectEqualStrings("search", argv[1]);
    try std.testing.expectEqualStrings("fire", argv[2]);
    try std.testing.expectEqualStrings("--json", argv[3]);
}

test "searchArgv returns null for an empty query so no remote read fires" {
    const st: search.State = .{};
    try std.testing.expect((try searchArgv(std.testing.allocator, "/bin/mt", &st)) == null);
}

test "installArgv installs the whole basket as bare names for a batch" {
    const alloc = std.testing.allocator;
    var sel: SearchSelection = .{};
    defer sel.deinit(alloc);
    try sel.toggle(alloc, "bat", .formula);
    try sel.toggle(alloc, "redis", .formula);
    const st: search.State = .{ .items = &.{} }; // basket-driven: no rows on screen
    const argv = (try installArgv(alloc, "/bin/mt", &sel, &st)).?;
    defer alloc.free(argv);
    // mt, install, bat, redis — a batch passes bare names (no global kind flag).
    try std.testing.expectEqual(@as(usize, 4), argv.len);
    try std.testing.expectEqualStrings("install", argv[1]);
    try std.testing.expectEqualStrings("bat", argv[2]);
    try std.testing.expectEqualStrings("redis", argv[3]);
}

test "installArgv keeps the entry's kind flag for a single-entry basket" {
    const alloc = std.testing.allocator;
    // The motivating collision: one name, two kinds. The basket entry's stored
    // kind picks the flag, so a single install can't silently default to the
    // formula when the user chose the cask — the reason the explicit flag exists.
    var sel: SearchSelection = .{};
    defer sel.deinit(alloc);
    try sel.toggle(alloc, "docker", .cask);
    const st: search.State = .{ .items = &.{} };
    const argv = (try installArgv(alloc, "/bin/mt", &sel, &st)).?;
    defer alloc.free(argv);
    try std.testing.expectEqual(@as(usize, 4), argv.len); // mt, install, --cask, name
    try std.testing.expectEqualStrings("--cask", argv[2]);
    try std.testing.expectEqualStrings("docker", argv[3]);
}

test "installArgv keeps a basket pick whose on-screen row reads installed (no per-package prune)" {
    const alloc = std.testing.allocator;
    var sel: SearchSelection = .{};
    defer sel.deinit(alloc);
    try sel.toggle(alloc, "git", .formula);
    // The same name is on screen and already installed, but the basket still
    // installs it: the post-install re-search only refreshes the current query,
    // so an off-list pick's `installed` flag can't be trusted — `mt install` is
    // idempotent instead. The basket path never consults the on-screen rows.
    const items = [_]search.Match{.{ .name = "git", .kind = .formula, .installed = true }};
    const st: search.State = .{ .items = &items };
    const argv = (try installArgv(alloc, "/bin/mt", &sel, &st)).?;
    defer alloc.free(argv);
    try std.testing.expectEqual(@as(usize, 4), argv.len); // single-entry basket → flag form
    try std.testing.expectEqualStrings("--formula", argv[2]); // and the formula flag, not just --cask
    try std.testing.expectEqualStrings("git", argv[3]);
}

test "installArgv over an empty basket falls back to the active row, keeping its kind flag" {
    const alloc = std.testing.allocator;
    const items = [_]search.Match{
        .{ .name = "firefox", .kind = .cask, .installed = false },
        .{ .name = "wget", .kind = .formula, .installed = false },
    };
    var sel: SearchSelection = .{}; // empty: never allocates, no free needed
    var st: search.State = .{ .items = &items };
    st.chrome.view.selected = 0; // firefox (cask)
    const argv = (try installArgv(alloc, "/bin/mt", &sel, &st)).?;
    defer alloc.free(argv);
    try std.testing.expectEqual(@as(usize, 4), argv.len); // single → mt, install, --cask, name
    try std.testing.expectEqualStrings("--cask", argv[2]);
    try std.testing.expectEqualStrings("firefox", argv[3]);
}

test "installArgv is null with an empty basket and no installable active row" {
    const alloc = std.testing.allocator;
    var sel: SearchSelection = .{};
    const on_system = [_]search.Match{.{ .name = "jq", .kind = .formula, .installed = true }};
    const st_installed: search.State = .{ .items = &on_system };
    try std.testing.expect((try installArgv(alloc, "/bin/mt", &sel, &st_installed)) == null); // active row already installed
    const empty: search.State = .{ .items = &.{} };
    try std.testing.expect((try installArgv(alloc, "/bin/mt", &sel, &empty)) == null); // nothing on screen, empty basket
}

test "a basket filled across two separate queries installs every pick in one argv" {
    const alloc = std.testing.allocator;
    var sel: SearchSelection = .{};
    defer sel.deinit(alloc);

    // Query A returns bat; the user checks it, then the query is re-run and A's
    // parse is freed — the pick must survive into the next query.
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

    // One `i` installs both, in a single argv, no matter which results are on
    // screen — the owned basket spans the two queries.
    const st: search.State = .{ .items = &.{} };
    const argv = (try installArgv(alloc, "/bin/mt", &sel, &st)).?;
    defer alloc.free(argv);
    try std.testing.expectEqual(@as(usize, 4), argv.len);
    try std.testing.expectEqualStrings("install", argv[1]);
    try std.testing.expectEqualStrings("bat", argv[2]);
    try std.testing.expectEqualStrings("redis", argv[3]);
}

test "installArgv reads names from the owned basket, not the freed parse it was checked in" {
    const alloc = std.testing.allocator;
    var sel: SearchSelection = .{};
    defer sel.deinit(alloc);
    // Check two hits out of a live parse, then free that parse — the basket owns
    // its name bytes, so the argv below must not read the released storage.
    {
        var parsed = try search_json.parse(alloc,
            \\{"results":[{"name":"bat","type":"formula","installed":false},{"name":"redis","type":"formula","installed":false}]}
        );
        try sel.toggle(alloc, parsed.items[0].name, parsed.items[0].kind);
        try sel.toggle(alloc, parsed.items[1].name, parsed.items[1].kind);
        parsed.deinit(); // the parse the names were borrowed from is gone
    }
    const st: search.State = .{ .items = &.{} };
    const argv = (try installArgv(alloc, "/bin/mt", &sel, &st)).?;
    defer alloc.free(argv);
    try std.testing.expectEqualStrings("bat", argv[2]); // owned bytes, not a dangling borrow
    try std.testing.expectEqualStrings("redis", argv[3]);
}

test "search selection toggles (name, kind) membership and owns its bytes" {
    const alloc = std.testing.allocator;
    var sel: SearchSelection = .{};
    defer sel.deinit(alloc);
    try std.testing.expect(!sel.contains("bat", .formula));
    try sel.toggle(alloc, "bat", .formula);
    try std.testing.expect(sel.contains("bat", .formula));
    try std.testing.expect(!sel.contains("bat", .cask)); // kind distinguishes the pick
    try sel.toggle(alloc, "bat", .formula); // a second toggle deselects
    try std.testing.expect(!sel.contains("bat", .formula));
}

test "search selection removes the right entry among several (swapRemove)" {
    const alloc = std.testing.allocator;
    var sel: SearchSelection = .{};
    defer sel.deinit(alloc);
    try sel.toggle(alloc, "a", .formula);
    try sel.toggle(alloc, "b", .formula);
    try sel.toggle(alloc, "c", .cask);
    try sel.toggle(alloc, "b", .formula); // remove the middle pick
    try std.testing.expect(sel.contains("a", .formula));
    try std.testing.expect(!sel.contains("b", .formula));
    try std.testing.expect(sel.contains("c", .cask));
    try std.testing.expectEqual(@as(usize, 2), sel.entries.items.len);
}

test "re-adding a removed pick yields a single entry, not a duplicate" {
    const alloc = std.testing.allocator;
    var sel: SearchSelection = .{};
    defer sel.deinit(alloc);
    try sel.toggle(alloc, "bat", .formula); // add
    try sel.toggle(alloc, "bat", .formula); // remove
    try sel.toggle(alloc, "bat", .formula); // add again
    try std.testing.expect(sel.contains("bat", .formula));
    try std.testing.expectEqual(@as(usize, 1), sel.entries.items.len);
}

test "search selection remove deletes exactly the named pick and frees it" {
    const alloc = std.testing.allocator; // a missed free shows up as a leak here
    var sel: SearchSelection = .{};
    defer sel.deinit(alloc);
    try sel.toggle(alloc, "bat", .formula);
    try sel.toggle(alloc, "redis", .formula);
    sel.remove(alloc, "bat", .formula);
    try std.testing.expect(!sel.contains("bat", .formula));
    try std.testing.expect(sel.contains("redis", .formula)); // the other pick is untouched
    try std.testing.expectEqual(@as(usize, 1), sel.entries.items.len);
    sel.remove(alloc, "ghost", .cask); // an absent pick is a harmless no-op
    try std.testing.expectEqual(@as(usize, 1), sel.entries.items.len);
}

test "search selection clear empties the basket and frees every pick" {
    const alloc = std.testing.allocator; // a missed free shows up as a leak here
    var sel: SearchSelection = .{};
    defer sel.deinit(alloc);
    try sel.toggle(alloc, "bat", .formula);
    try sel.toggle(alloc, "redis", .cask);
    sel.clear(alloc);
    try std.testing.expectEqual(@as(usize, 0), sel.entries.items.len);
    try std.testing.expect(!sel.contains("bat", .formula));
}

test "removing a basket pick re-projects its on-screen row to unchecked" {
    const alloc = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);
    store.search = try search_json.parse(alloc,
        \\{"results":[{"name":"bat","type":"formula","installed":false}]}
    );
    store.search_checked = try alloc.alloc(bool, 1);
    @memset(store.search_checked, false);
    try store.search_selected.toggle(alloc, "bat", .formula);
    projectSearchChecked(&store);
    try std.testing.expect(store.search_checked[0]); // checked before the remove
    store.search_selected.remove(alloc, "bat", .formula);
    projectSearchChecked(&store);
    try std.testing.expect(!store.search_checked[0]); // the row reflects the removal
}

test "the shell mirrors the basket entries onto the leaf for the basket view" {
    const alloc = std.testing.allocator;
    var a: App = .{ .active = .search };
    var store: Store = .{};
    defer store.deinit(alloc);
    try store.search_selected.toggle(alloc, "bat", .formula);
    syncSearchSelectedCount(&a, &store);
    try std.testing.expectEqual(@as(usize, 1), a.states.search.basket.len);
    try std.testing.expectEqualStrings("bat", a.states.search.basket[0].name);
}

test "removing a pick then installing builds an argv without the removed name" {
    const alloc = std.testing.allocator;
    var sel: SearchSelection = .{};
    defer sel.deinit(alloc);
    // Two picks gathered across queries (the cross-query basket); the user opens
    // the basket view, removes bat, then installs — only redis reaches the argv.
    try sel.toggle(alloc, "bat", .formula);
    try sel.toggle(alloc, "redis", .formula);
    sel.remove(alloc, "bat", .formula);
    const st: search.State = .{ .items = &.{} };
    const argv = (try installArgv(alloc, "/bin/mt", &sel, &st)).?;
    defer alloc.free(argv);
    try std.testing.expectEqual(@as(usize, 4), argv.len); // single → mt, install, --formula, name
    try std.testing.expectEqualStrings("redis", argv[3]);
    try std.testing.expect(std.mem.indexOf(u8, argv[3], "bat") == null);
}

test "the Search footer switches to the basket-view keys when the basket view is open" {
    var a: App = .{ .active = .search };
    a.states.search.view = .basket;
    var buf: [8192]u8 = undefined;
    const out = renderFrame(&buf, &a, 120, 24);
    try std.testing.expect(std.mem.indexOf(u8, out, "remove") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "l: results") != null);
}

test "projectChecked leaves every row unchecked for an empty selection" {
    const items = [_]search.Match{
        .{ .name = "wget", .kind = .formula, .installed = false },
        .{ .name = "ripgrep", .kind = .formula, .installed = false },
    };
    var sel: SearchSelection = .{}; // never touched: no allocation, no free needed
    var checked = [_]bool{ true, true }; // pre-dirtied to prove the projection clears
    projectChecked(&items, &checked, &sel);
    try std.testing.expect(!checked[0]);
    try std.testing.expect(!checked[1]);
}

test "projectChecked checks selected, not-installed rows only" {
    const items = [_]search.Match{
        .{ .name = "wget", .kind = .formula, .installed = false },
        .{ .name = "firefox", .kind = .cask, .installed = true },
        .{ .name = "ripgrep", .kind = .formula, .installed = false },
    };
    const alloc = std.testing.allocator;
    var sel: SearchSelection = .{};
    defer sel.deinit(alloc);
    try sel.toggle(alloc, "wget", .formula);
    try sel.toggle(alloc, "firefox", .cask); // selected but already installed
    var checked = [_]bool{ false, false, false };
    projectChecked(&items, &checked, &sel);
    try std.testing.expect(checked[0]); // selected + installable
    try std.testing.expect(!checked[1]); // installed → never checked
    try std.testing.expect(!checked[2]); // not selected
}

test "a Search selection survives a re-query" {
    const alloc = std.testing.allocator;
    var sel: SearchSelection = .{};
    defer sel.deinit(alloc);
    try sel.toggle(alloc, "wget", .formula); // checked under query A

    const b = [_]search.Match{.{ .name = "redis", .kind = .formula, .installed = false }};
    var cb = [_]bool{false};
    projectChecked(&b, &cb, &sel); // query B: wget is absent
    try std.testing.expect(!cb[0]);

    const a = [_]search.Match{.{ .name = "wget", .kind = .formula, .installed = false }};
    var ca = [_]bool{false};
    projectChecked(&a, &ca, &sel); // query A again: wget returns
    try std.testing.expect(ca[0]); // re-checked from the still-present selection
}

test "projectSearchChecked fills the store checked slice from the selection" {
    const alloc = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);
    store.search = try search_json.parse(alloc,
        \\{"results":[{"name":"wget","type":"formula","installed":false},{"name":"firefox","type":"cask","installed":true}]}
    );
    store.search_checked = try alloc.alloc(bool, 2);
    @memset(store.search_checked, false);
    try store.search_selected.toggle(alloc, "wget", .formula);
    projectSearchChecked(&store);
    try std.testing.expect(store.search_checked[0]); // selected, installable
    try std.testing.expect(!store.search_checked[1]); // installed → never checked
}

test "a clean install (exit 0) clears the basket and re-projects the checked slice" {
    const alloc = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);
    store.search = try search_json.parse(alloc,
        \\{"results":[{"name":"bat","type":"formula","installed":false}]}
    );
    store.search_checked = try alloc.alloc(bool, 1);
    @memset(store.search_checked, false);
    try store.search_selected.toggle(alloc, "bat", .formula);
    try store.search_selected.toggle(alloc, "redis", .formula); // an off-list pick too
    projectSearchChecked(&store);
    try std.testing.expect(store.search_checked[0]); // bat checked before the install

    applyInstallOutcome(&store, alloc, true);
    try std.testing.expectEqual(@as(usize, 0), store.search_selected.entries.items.len); // basket emptied
    try std.testing.expect(!store.search_checked[0]); // re-projected against the now-empty basket
}

test "a failed install (non-zero exit) retains the whole basket for retry" {
    const alloc = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);
    try store.search_selected.toggle(alloc, "bat", .formula);
    try store.search_selected.toggle(alloc, "redis", .formula);

    applyInstallOutcome(&store, alloc, false);
    try std.testing.expectEqual(@as(usize, 2), store.search_selected.entries.items.len); // untouched
    try std.testing.expect(store.search_selected.contains("bat", .formula));
    try std.testing.expect(store.search_selected.contains("redis", .formula));
}

test "a failed search names the op in the banner and leaves no stuck searching phase" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    var app: App = .{ .mt_path = "/bin/echo" }; // echo emits non-JSON → parse fails
    app.states.search.chrome.filter.push("fire");
    app.states.search.phase = .searching; // as the pre-spawn paint left it
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    try std.testing.expectError(error.BadJson, loadSearch(t.io(), std.testing.allocator, &app, &store));
    try std.testing.expectEqualStrings("search failed: BadJson", app.banner.slice());
    // No prior results → guidance, not a spinner frozen behind the banner.
    try std.testing.expectEqual(search.Phase.idle, app.states.search.phase);
    try std.testing.expectEqual(@as(usize, 0), app.states.search.items.len);
}

test "a failed search keeps the last-good results and selection, falling back to the list" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    var app: App = .{ .mt_path = "/bin/echo" }; // non-JSON → BadJson on the new query
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    // Prime a prior successful search: store + tab borrow these results.
    store.search = try search_json.parse(std.testing.allocator,
        \\{"results":[{"name":"jq","type":"formula","installed":true},{"name":"yq","type":"formula","installed":false}]}
    );
    app.states.search.items = store.search.?.items;
    app.states.search.chrome.filter.push("q");
    app.states.search.chrome.view.selected = 1; // cursor on yq
    app.states.search.phase = .searching; // as the pre-spawn paint left it

    try std.testing.expectError(error.BadJson, loadSearch(t.io(), std.testing.allocator, &app, &store));
    try std.testing.expectEqualStrings("search failed: BadJson", app.banner.slice());
    // Prior results exist → fall back to the list, not guidance; and the store is
    // swapped only after a clean parse, so the rows and the cursor both survive.
    try std.testing.expectEqual(search.Phase.loaded, app.states.search.phase);
    try std.testing.expectEqual(@as(usize, 2), app.states.search.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.states.search.chrome.view.selected);
}

test "committing the filter fires a search on the Search tab but no domain key elsewhere" {
    // On Search the filter doubles as the search box, so Enter commits *and*
    // requests the read — 'i' typed mid-edit is literal query text, not install.
    var a: App = .{ .active = .search };
    a = step(a, ch('/'));
    a = step(a, ch('f'));
    a = step(a, ch('i'));
    a = step(a, .enter);
    try std.testing.expect(!a.editing);
    try std.testing.expectEqual(search.Request.search, a.states.search.request);
    try std.testing.expectEqualStrings("fi", activeFilterText(&a));

    // The same commit on a non-search tab must not be routed to its domain key
    // (outdated's Enter would otherwise request an upgrade).
    var b: App = .{ .active = .outdated };
    b = step(b, ch('/'));
    b = step(b, ch('x'));
    b = step(b, .enter);
    try std.testing.expect(!b.editing);
    try std.testing.expectEqual(outdated.Request.none, b.states.outdated.request);
}

test "the 1 key jumps to the Search tab, the 5 key to Doctor" {
    var a: App = .{};
    a = step(a, .tab); // move off Search first
    a = step(a, ch('1'));
    try std.testing.expectEqual(Tab.search, a.active);
    a = step(a, ch('5'));
    try std.testing.expectEqual(Tab.doctor, a.active);
}

test "refusalReason refuses non-tty, NO_COLOR, and CI; allows a clean tty" {
    try std.testing.expectEqual(@as(?Refusal, .not_a_tty), refusalReason(false, true, false, false));
    try std.testing.expectEqual(@as(?Refusal, .not_a_tty), refusalReason(true, false, false, false));
    try std.testing.expectEqual(@as(?Refusal, .no_color), refusalReason(true, true, true, false));
    try std.testing.expectEqual(@as(?Refusal, .ci), refusalReason(true, true, false, true));
    try std.testing.expect(refusalReason(true, true, false, false) == null);
}
