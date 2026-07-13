//! malt — `mt tui` app shell: event loop, tab dispatch, filter, rendering.
//!
//! Leaf module. `step(app, key) -> Cmd` maps a key to the active tab's effect
//! (pure over `(app, key)`; nav/editing mutate `app` in place) and
//! `renderFrame(buf, app, cols, rows) -> bytes` paints — The Elm Architecture,
//! unit-tested without a PTY. The `perform`/`update` pump in `serviceKey` runs the
//! `Cmd`, folds the `Msg` back, and repaints. `run` is the only impure part: it owns the
//! terminal lifecycle (raw mode + alt-screen + hidden cursor, each undone by an
//! `errdefer` restore; panics and termination signals restore through the
//! `ui/term_restore` crash registry), refuses to launch on a non-interactive
//! terminal, and drives the read→decode→step→repaint loop. A `SIGWINCH` re-renders from cached
//! state with no keypress. The TUI module is referenced only from the lazy
//! `mt tui` dispatch arm, so non-`tui` commands pay no cold-start cost.

const std = @import("std");

const color = @import("../ui/color.zig");
const spinner_frames = @import("../ui/spinner_frames.zig");
const cmd = @import("cmd.zig");
const ctx = @import("ctx.zig");
const doctor = @import("doctor_tab.zig");
const filter_input = @import("filter_input.zig");
const header = @import("header.zig");
const installed = @import("installed_tab.zig");
const keys = @import("keys.zig");
const Key = keys.Key;
const layout = @import("layout.zig");
const outdated = @import("outdated_tab.zig");
const scroll_list = @import("scroll_list.zig");
const search = @import("search_tab.zig");
const services = @import("services_tab.zig");
const spawn = @import("spawn.zig");
const tab = @import("tab.zig");
const tab_bar = @import("tab_bar.zig");
const Tab = tab_bar.Tab;
const term = @import("term.zig");
const text_wrap = @import("text_wrap.zig");

// Shared read-model + effect-port handles now live in the `ctx.zig` sink leaf;
// the hub references them downward instead of owning their definitions.
const Painter = ctx.Painter;
const TabFetch = ctx.TabFetch;
const Fetches = ctx.Fetches;
const SharedModel = ctx.SharedModel;

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

pub const App = struct {
    active: Tab = .search,
    editing: bool = false,
    quit: bool = false,
    states: TabStates = .{},
    /// Per-tab parse storage, one `Storage` per tab, owned here. Each tab's rows
    /// borrow from its own slot; the arena lifetimes live with the tab, not a
    /// central store.
    storages: Storages = .{},
    /// The genuinely shared read-model: header counts, the cross-tab `dirty` set,
    /// and the recoverable-failure banner. Passed by pointer to the cross-tab
    /// writers so they touch only these scalars, never another tab's `Storage`.
    shared: SharedModel = .{},
    /// Resolved self-exe path injected by the `main.zig` bridge so the data and
    /// action tabs re-exec *this* `mt` (not whatever PATH resolves) for reads
    /// and mutations.
    mt_path: []const u8 = "",
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
    /// once in `run`.
    version: []const u8 = "",
    prefix: []const u8 = "",
};

/// Mark every data tab dirty at launch so each loads lazily on first entry.
/// Search is the active tab and renders without data, so launch never blocks on
/// a child read — the load cost is paid on view, behind `paintLoading`.
fn initLaunchDirty(a: *App) void {
    a.shared.dirty.insert(.installed);
    a.shared.dirty.insert(.outdated);
    a.shared.dirty.insert(.services);
    a.shared.dirty.insert(.doctor);
}

/// Consume `t`'s dirty flag: true exactly once after it was marked, so the
/// caller refetches its `--json` at most once per staleness.
pub fn takeDirty(a: *App, t: Tab) bool {
    return a.shared.takeDirty(t);
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

/// Route a key to the active tab's `step`, returning the `Cmd` it produces. The
/// tab's pure state changes land in place; the effect (if any) is the return.
fn routeToTab(allocator: std.mem.Allocator, mt_path: []const u8, a: *App, key: Key) cmd.Cmd {
    switch (a.active) {
        inline else => |t| return moduleFor(t).step(allocator, mt_path, &@field(a.states, @tagName(t)), &@field(a.storages, @tagName(t)), key),
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

/// Transition: keys split between filter editing and normal navigation; keys the
/// shell does not own fall through to the active tab. Nav/editing mutate `app` in
/// place; the return is the active tab's effect `Cmd` (`none` for a pure key), which
/// the `serviceKey` pump performs. Not a value-returning `App -> App` anymore because
/// a `Cmd` carries a heap argv the pump owns.
pub fn step(allocator: std.mem.Allocator, mt_path: []const u8, app: *App, key: Key) cmd.Cmd {
    app.shared.banner.clear(); // a keypress dismisses the prior transient error banner
    return if (app.editing) stepFilter(allocator, mt_path, app, key) else stepNormal(allocator, mt_path, app, key);
}

fn stepFilter(allocator: std.mem.Allocator, mt_path: []const u8, a: *App, key: Key) cmd.Cmd {
    switch (key) {
        .char => |c| activeChrome(a).filter.push(c.slice()),
        .backspace => activeChrome(a).filter.backspace(),
        .enter => { // commit, keep the filter
            a.editing = false;
            // Search divergence: its filter doubles as the search box, so committing
            // the query *is* the search — ask the tab for the query `Cmd` rather than
            // routing Enter (whose tab meaning is "open info"). Every other tab's
            // filter just narrows a loaded list, so their commit is a pure no-op.
            if (a.active == .search) return search.searchCmd(allocator, mt_path, &a.states.search);
        },
        .esc => { // cancel: clear the filter
            activeChrome(a).filter.clear();
            a.editing = false;
        },
        .ctrl_c => a.quit = true, // always escapes, even mid-edit
        .up, .down, .left, .right, .space, .tab, .page_up, .page_down, .home, .end, .unknown => {},
    }
    return .none;
}

fn stepNormal(allocator: std.mem.Allocator, mt_path: []const u8, a: *App, key: Key) cmd.Cmd {
    // The Installed uninstall guard is modal: while it is up, route every key
    // to the tab so its one-key resolve sees keys this switch would otherwise
    // consume — navigation, tab switches, digits, and `/` then cancel the
    // guard instead of bypassing it.
    if (a.active == .installed and a.states.installed.confirm_uninstall != null) {
        switch (key) {
            .ctrl_c => {
                a.quit = true;
                return .none;
            },
            else => return routeToTab(allocator, mt_path, a, key),
        }
    }
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
                    return .none;
                },
                '/' => {
                    a.editing = true;
                    return .none;
                },
                '1'...'5' => {
                    if (tab_bar.fromDigit(c.bytes[0])) |t| a.active = t;
                    return .none;
                },
                else => {},
            };
            return routeToTab(allocator, mt_path, a, key); // a domain key (e.g. u/f) belongs to the tab
        },
        .enter => {
            // On Search, Enter focuses the query box when there are no results
            // yet (so the user can type), and opens info for the active hit once
            // results are loaded. Every other tab uses Enter as a domain key.
            if (a.active == .search and a.states.search.items.len == 0) {
                a.editing = true;
            } else return routeToTab(allocator, mt_path, a, key);
        },
        .space, .end, .esc => return routeToTab(allocator, mt_path, a, key),
        // `end` needs the row count to land on the last row — deferred to the
        // data tab; Esc routes so a tab can close a pane / cancel its guard;
        // `backspace`/`unknown` are inert outside edit mode.
        .backspace, .unknown => {},
    }
    return .none;
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
                .kegs = app.shared.installed_count,
                .outdated = app.shared.outdated_count,
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
            } else if (app.shared.banner.isSet()) {
                // Undimmed + yellow so a recoverable failure reads as a warning, not
                // chrome; the wrap paints through `putContent`, which drops the
                // line-breakers the sanitizer let through.
                renderFooterText(&f, app.shared.banner.slice(), color.roleCode(.warning), r.footer.row + 1, text_rows, cols);
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

// The terminal/loop/spawn faults the pump and the header count-read can raise.
// A tab parser's own errors flow back through the interpreter as a `.failed` `Msg`
// (recoverable, bannered from the `Cmd`'s `fail_op`), never up here — only the
// count-read's `BadJson` still surfaces directly. `classify` stays exhaustive over
// these concrete tags.
pub const RunError = term.TermError || std.mem.Allocator.Error ||
    spawn.ReadError || spawn.InlineError ||
    error{ ReadFailed, BadJson };

/// How the event loop treats a run-loop error: a `recoverable` backend fault
/// becomes an inline banner and the session keeps running; a `fatal` fault
/// restores the terminal and exits (the crash-safety guarantee for
/// error returns; panics and termination signals restore via the
/// `ui/term_restore` crash registry instead).
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

/// Binds the whole-dashboard repaint for a migrated tab's synchronous polled load
/// (the Doctor reload after a fix, and the Services reload after a lifecycle
/// action). Type-erased into `Painter.on_tick` so the tab animates its spinner
/// without importing the hub — only the hub can render every tab.
const TickBind = struct {
    allocator: std.mem.Allocator,
    app: *App,
    fd: std.posix.fd_t,
    frame: *[]u8,
    fn call(p: *anyopaque) void {
        // `p` was set from a `*TickBind` (`&tick_bind` in `run`), so the round-trip is sound.
        const b: *TickBind = @ptrCast(@alignCast(p));
        b.app.spinner_frame +%= 1;
        // A resize during the load reflows here (repaint reads currentSize); consume
        // the flag so the loop's own resize check doesn't redundantly repaint.
        _ = term.takeResized();
        // Best-effort, like paintLoading: a dropped animation frame is cosmetic.
        repaint(b.fd, b.frame, b.allocator, b.app) catch {};
    }
};

/// Bundles the per-tab parse storage, one `Storage` per tab. Each tab defines and
/// owns its own `Storage` (parse arenas + checkbox/basket buffers) beside its pure
/// core; the hub only aggregates them here so `run` can hold and free the set. The
/// old central `Store` is gone — no field here reaches across tabs.
const Storages = struct {
    installed: installed.Storage = .{},
    outdated: outdated.Storage = .{},
    services: services.Storage = .{},
    doctor: doctor.Storage = .{},
    search: search.Storage = .{},

    fn deinit(self: *Storages, allocator: std.mem.Allocator) void {
        self.installed.deinit(allocator);
        self.outdated.deinit(allocator);
        self.services.deinit(allocator);
        self.doctor.deinit(allocator);
        self.search.deinit(allocator);
    }
};

/// Argv for the cheap keg-count read: `mt list --json` with **no**
/// `--size --linked`, so it is a DB read, not the keg-dir size/symlink walk the
/// Installed tab's full load pays. Kept separate so a test can pin that the count
/// path stays cheap.
fn installedCountArgv(allocator: std.mem.Allocator, mt_path: []const u8) std.mem.Allocator.Error![]const []const u8 {
    return spawn.jsonArgv(allocator, mt_path, &.{"list"});
}

/// Refresh only the header keg count, cheaply (see `installedCountArgv`). The
/// full `--size --linked` Installed payload still loads lazily on tab entry; this
/// keeps `<n> kegs` live at launch and after a cross-tab install. A second writer
/// of `installed_count` beside the Installed tab's own load — both count the same
/// `mt list` rows, so they cannot diverge. Takes the shared read-model by pointer, not the whole
/// `App`: it is a cross-tab writer, so it reaches only these shared scalars and
/// structurally cannot touch a tab's `Storage`. The parse+count is delegated to
/// `installed.countFromJson` so the hub need not import the list parser.
fn refreshInstalledCount(io: std.Io, allocator: std.mem.Allocator, mt_path: []const u8, shared: *SharedModel) RunError!void {
    errdefer |err| shared.banner.set("keg count refresh failed", @errorName(err));
    const argv = try installedCountArgv(allocator, mt_path);
    defer allocator.free(argv);
    const bytes = (try spawn.readJsonAllowEmpty(io, allocator, argv)) orelse {
        shared.installed_count = 0; // empty Cellar is a known zero, not "unknown"
        return;
    };
    defer allocator.free(bytes);
    shared.installed_count = try installed.countFromJson(allocator, bytes);
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

/// The tab's background-fetch descriptor, read from its module — runtime `t`
/// bridged to the comptime `moduleFor` dispatch the render path already uses.
/// Null for a tab that does not background-fetch (installed, search).
fn fetchSpec(t: Tab) ?tab.FetchSpec {
    return switch (t) {
        inline else => |ct| moduleFor(ct).fetch_spec,
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
fn applyTabBytes(allocator: std.mem.Allocator, app: *App, store: *Storages, t: Tab, bytes: ?[]const u8) RunError!void {
    switch (t) {
        .outdated => try outdated.applyOutdatedBytes(allocator, &app.states.outdated, &store.outdated, &app.shared, bytes),
        .services => try services.applyServicesBytes(allocator, &app.states.services, &store.services, bytes),
        .doctor => try doctor.applyDoctorBytes(allocator, &app.states.doctor, &store.doctor, bytes),
        else => {},
    }
}

/// Land a completed fetch into its tab's store, then drop it and repaint. The
/// child must already be reaped. The bytes are applied *before* the buffer is
/// freed (the parse copies them); a parse/apply failure surfaces the same
/// recoverable banner the synchronous reload uses and keeps the last-good data —
/// never fatal, the loop keeps running.
fn finishTabFetch(allocator: std.mem.Allocator, painter: Painter, fetches: *Fetches, app: *App, store: *Storages, t: Tab, outcome: FetchOutcome) void {
    // Only reached for a tab with an active fetch, so the spec is present; the
    // fallback matches the old switch's default for a would-be non-fetch tab.
    const refresh_op = if (fetchSpec(t)) |s| s.refresh_op else "refresh failed";
    switch (outcome) {
        .failed => |err| app.shared.banner.set(refresh_op, @errorName(err)),
        .empty => applyTabBytes(allocator, app, store, t, null) catch |e| app.shared.banner.set(refresh_op, @errorName(e)),
        .bytes => |b| applyTabBytes(allocator, app, store, t, b) catch |e| app.shared.banner.set(refresh_op, @errorName(e)),
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
fn drainTabFetch(io: std.Io, allocator: std.mem.Allocator, painter: Painter, fetches: *Fetches, app: *App, store: *Storages, t: Tab) void {
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
fn failLiveTabFetch(io: std.Io, allocator: std.mem.Allocator, painter: Painter, fetches: *Fetches, app: *App, store: *Storages, t: Tab) void {
    killAndReap(io, &fetches.getPtr(t).*.?);
    finishTabFetch(allocator, painter, fetches, app, store, t, .{ .failed = error.ReadFailed });
}

/// One loop turn while background fetches run: multiplex the tty with every
/// active fetch's stdout. On a timeout, advance + repaint the spinner(s) (and
/// absorb a resize) so the indicators animate; on a fetch ready, drain it;
/// return true only when the tty has input the caller must read this turn.
fn serviceFetches(io: std.Io, allocator: std.mem.Allocator, painter: Painter, fetches: *Fetches, app: *App, store: *Storages) error{ReadFailed}!bool {
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

/// Quiesce every in-flight background audit before an inline mutation opens the
/// DB. The TUI is the sole DB orchestrator: a live `mt … --json` child holds the
/// WAL writer on each open (`initSchema` writes on connect), so a mutating child
/// spawned alongside it races the single writer and fails with `Busy`.
///
/// Crucially this *kills* each audit without applying its payload, rather than
/// waiting for it and swapping in the result: the pending mutation's argv borrows
/// the active tab's parse storage (the checked rows / selected name), which an
/// apply-swap would free while the argv still points into it. Killing also avoids
/// blocking the mutation behind a slow cold-cache audit. Each reaped tab is
/// re-marked dirty so its audit re-runs afterwards; the storage is left intact, so
/// the mutation acts on exactly the rows the user saw.
fn quiesceFetches(io: std.Io, allocator: std.mem.Allocator, fetches: *Fetches, app: *App) void {
    var it = fetches.iterator();
    while (it.next()) |e| if (e.value.*) |*f| {
        reapTabFetch(io, allocator, f); // kill + reap (closes the DB connection) + free the buffer
        e.value.* = null;
        app.tab_loading.remove(e.key);
        app.shared.dirty.insert(e.key); // re-audit after the mutation, off the intact storage
    };
}

// ── The Cmd/Msg pump (temporary shim over the phase-1 spawn/mux machinery) ──
// `step` → `Cmd` → `perform` → `Msg` → `update` → `Cmd`, until `Cmd.none`. A later
// pass generalizes this into one domain-agnostic `perform(cmd)` and folds it into
// the loop; for now it performs each variant with the existing `spawn` helpers and
// routes the result to the active tab's `update`.

/// Free a `Cmd`'s heap argv once it is performed — the ownership contract: the tab
/// (in `step`/`update`) builds the argv, the interpreter frees the slice (never its
/// elements, which borrow parse storage).
fn freeCmdArgv(allocator: std.mem.Allocator, c: cmd.Cmd) void {
    switch (c) {
        .read => |r| allocator.free(r.argv),
        .run_mutation => |m| allocator.free(m.argv),
        .none, .batch => {},
    }
}

/// Route a `Msg` to the active tab's `update` — the same comptime `moduleFor`
/// switch the render path uses. The active tab is stable across a synchronous pump
/// cycle (no input is read mid-chain), and every pump `Cmd` was produced for it, so
/// the `Parsed` member always matches the tab.
fn updateActive(allocator: std.mem.Allocator, app: *App, store: *Storages, msg: cmd.Msg) cmd.Cmd {
    switch (app.active) {
        inline else => |t| return moduleFor(t).update(allocator, app.mt_path, &@field(app.states, @tagName(t)), &@field(store, @tagName(t)), &app.shared, msg),
    }
}

/// Perform one `Cmd`, returning the `Msg` to fold back. A recoverable fault sets the
/// banner from the `Cmd`'s `fail_op` and returns `.failed`/`.mutated`; only a fatal
/// (terminal/OOM) fault propagates. `.none`/`.batch` never reach here.
fn perform(io: std.Io, allocator: std.mem.Allocator, t: *term.Term, painter: Painter, fetches: *Fetches, app: *App, c: cmd.Cmd) RunError!cmd.Msg {
    switch (c) {
        .none, .batch => unreachable, // the pump never performs these; no tab emits a batch
        .read => |r| return performRead(io, allocator, painter, app, r),
        .run_mutation => |m| return performMutation(io, allocator, t, fetches, app, m),
    }
}

/// Perform a `read`: paint the pre-read status, capture `mt … --json`, and parse it
/// with the `Cmd`'s carried parser. An `allow_empty` empty read is `.cleared`; a
/// recoverable read/parse fault banners and is `.failed`; a fatal fault propagates.
fn performRead(io: std.Io, allocator: std.mem.Allocator, painter: Painter, app: *App, r: cmd.Cmd.Read) RunError!cmd.Msg {
    // Paint before the blocking freeze so it reads as intentional. Search shows its
    // own "searching…" via `phase`; the others get the "Loading…" footer.
    const show_loading = r.tag != .search;
    if (show_loading) app.loading = true;
    repaint(painter.fd, painter.frame, allocator, app) catch {};
    if (show_loading) app.loading = false;

    const bytes: ?[]u8 = readBytes(io, allocator, painter, app, r) catch |err| switch (classify(err)) {
        .fatal => return err,
        .recoverable => {
            app.shared.banner.set(r.fail_op, @errorName(err));
            return .failed;
        },
    };
    const payload = bytes orelse return .cleared; // an exit-0 empty read
    defer allocator.free(payload);
    const parsed = r.parse(allocator, payload) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory; // fatal
        app.shared.banner.set(r.fail_op, @errorName(err));
        return .failed;
    };
    return .{ .loaded = parsed };
}

/// The read-mode dispatch over the phase-1 `spawn` readers. Blocking non-empty is
/// `readJson`; blocking empty-ok is `readJsonAllowEmpty`; polled is spinner-animated
/// via the painter. `background` never reaches here — those go through `startTabFetch`.
fn readBytes(io: std.Io, allocator: std.mem.Allocator, painter: Painter, app: *App, r: cmd.Cmd.Read) spawn.ReadError!?[]u8 {
    return switch (r.mode) {
        .blocking => if (r.allow_empty) spawn.readJsonAllowEmpty(io, allocator, r.argv) else @as(?[]u8, try spawn.readJson(io, allocator, r.argv)),
        .polled => blk: {
            // Keep `loading` set across the poll so each tick paints the spinner.
            app.loading = true;
            defer app.loading = false;
            break :blk try spawn.readJsonPolled(io, allocator, r.argv, r.max_ok_exit, painter);
        },
        .background => unreachable,
    };
}

/// Perform a `run_mutation`: quiesce background audits (the WAL single-writer
/// invariant), re-exec `mt` inline, and return the child's exit code as `.mutated`
/// for the tab's `update` to judge. A spawn/re-enter fault banners and is `.failed`;
/// a terminal fault propagates.
fn performMutation(io: std.Io, allocator: std.mem.Allocator, t: *term.Term, fetches: *Fetches, app: *App, m: cmd.Cmd.Mutation) RunError!cmd.Msg {
    // Sole-orchestrator invariant: a live `mt … --json` child holds the WAL writer,
    // so a mutating child spawned alongside it races and fails `Busy`. Quiesce first.
    if (anyFetchActive(fetches)) quiesceFetches(io, allocator, fetches, app);
    const code = spawn.runInlineReenterStatus(t, m.argv) catch |err| switch (classify(err)) {
        .fatal => return err,
        .recoverable => {
            app.shared.banner.set(m.fail_op, @errorName(err));
            return .failed;
        },
    };
    return .{ .mutated = code };
}

/// Drive one `Cmd` chain to completion: perform → fold → repeat until `Cmd.none`.
/// The interpreter frees each performed argv; a successful Search-tab mutation grows
/// the keg set while Installed is off-tab, so the header count is refreshed eagerly.
fn pump(io: std.Io, allocator: std.mem.Allocator, t: *term.Term, painter: Painter, fetches: *Fetches, app: *App, store: *Storages, initial: cmd.Cmd) RunError!void {
    var c = initial;
    while (c != .none) {
        const performed = c;
        const msg = perform(io, allocator, t, painter, fetches, app, performed) catch |err| {
            freeCmdArgv(allocator, performed);
            return err;
        };
        if (performed == .run_mutation and performed.run_mutation.tag == .search)
            // Installed won't lazy-reload while off-tab, so keep `<n> kegs` live now.
            refreshInstalledCount(io, allocator, app.mt_path, &app.shared) catch {};
        freeCmdArgv(allocator, performed);
        c = updateActive(allocator, app, store, msg);
    }
}

/// After the keypress chain, the active tab's lazy on-entry (re)load if it is dirty:
/// a background-fetch tab kicks its audit (loop machinery); a synchronous tab that
/// exposes `refreshCmd` (Installed) pumps its read now. Search declares neither, so
/// entering it never triggers a surprise remote read.
fn onEntryReload(io: std.Io, allocator: std.mem.Allocator, t: *term.Term, painter: Painter, fetches: *Fetches, app: *App, store: *Storages) RunError!void {
    switch (app.active) {
        inline else => |tag| {
            const M = moduleFor(tag);
            if (M.fetch_spec != null) {
                if (takeDirty(app, tag)) startTabFetch(io, allocator, fetches, app, tag);
            } else if (@hasDecl(M, "refreshCmd")) {
                if (takeDirty(app, tag)) try pump(io, allocator, t, painter, fetches, app, store, M.refreshCmd(allocator, app.mt_path));
            }
        },
    }
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
    // SIGTERM/SIGHUP/SIGQUIT restore the terminal then re-raise; errdefers
    // cover error returns but never a signal death. Installed before raw
    // entry so no signal can land in between — with an empty registry the
    // handler is a no-op that just dies. SIGINT stays untouched: raw mode
    // delivers Ctrl-C as a byte that quits cleanly.
    term.installCrashSignals();
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
    defer app.storages.deinit(allocator); // app owns the per-tab parse storage
    var frame = try allocator.alloc(u8, frameCap(term.currentSize()));
    defer allocator.free(frame);
    // The paint handle the polled lazy reads tick against to animate the spinner. A
    // migrated tab repaints through `on_tick` (only the hub can render every tab).
    var tick_bind: TickBind = .{ .allocator = allocator, .app = &app, .fd = fd, .frame = &frame };
    const painter: Painter = .{ .fd = fd, .frame = &frame, .on_tick = .{ .ctx = &tick_bind, .call = TickBind.call } };

    // Paint the data-free chrome first so the alt-screen never flashes blank,
    // then prime the cheap installed count (a single-digit-ms SQLite read) and
    // repaint — launch shows `<n> kegs` immediately. The outdated count is *not*
    // cheap: on a cold cache it is a live per-keg network audit, so it runs in the
    // background and the loop multiplexes its stdout (a header spinner, never a
    // freeze). Best-effort: a failed installed count leaves an em-dash, never
    // blocks the dashboard from opening.
    try repaint(fd, &frame, allocator, &app);
    refreshInstalledCount(io, allocator, app.mt_path, &app.shared) catch {};
    app.shared.banner.clear(); // a failed startup installed count is an em-dash, not a nag

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
        if (anyFetchActive(&fetches) and !try serviceFetches(io, allocator, painter, &fetches, &app, &app.storages)) continue;
        const rc = std.c.read(fd, &rbuf, rbuf.len);
        if (rc < 0) {
            if (std.posix.errno(rc) == .INTR) continue; // SIGWINCH woke the read; loop re-checks resize
            return error.ReadFailed;
        }
        if (rc == 0) break; // EOF
        const bytes = rbuf[0..@intCast(rc)];
        var consumed: usize = 0;
        var partial = false;
        while (consumed < bytes.len) {
            switch (decoder.decode(bytes[consumed..])) {
                .incomplete => {
                    partial = true;
                    break;
                },
                .key => |k| {
                    consumed += k.consumed;
                    try serviceKey(io, allocator, &t, painter, &fetches, &app, &app.storages, k.key);
                    if (app.quit) break;
                },
            }
        }
        // A buffered tail can be a lone Esc, which the blocking read would sit
        // on until the next keypress. Give the rest of a genuine sequence one
        // short window to arrive; silence resolves the tail through flush().
        if (partial and !app.quit and !ttyReadable(fd, esc_resolve_ms)) {
            if (decoder.flush()) |k| try serviceKey(io, allocator, &t, painter, &fetches, &app, &app.storages, k);
        }
        try repaint(fd, &frame, allocator, &app);
    }
    t.restore();
}

/// How long a buffered partial escape sequence may wait for its next byte
/// before the tail resolves as a lone Esc. A genuine CSI arrives in one
/// write, so this much tty silence means no more bytes are coming.
const esc_resolve_ms: i32 = 40;

/// True when `fd` has readable bytes within `timeout_ms`. `std.posix.poll`
/// retries EINTR internally, so a SIGWINCH mid-wait reads as a timeout — the
/// flush is safe and the resize is consumed on the next loop turn.
fn ttyReadable(fd: std.posix.fd_t, timeout_ms: i32) bool {
    var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const n = std.posix.poll(&pfd, timeout_ms) catch return false;
    return n > 0;
}

/// One decoded key's full turn: `step` yields the active tab's `Cmd`, the pump
/// performs it and folds the `Msg` chain back, then the tab's lazy on-entry reload
/// runs. Shared by the streaming decode path and the timeout-flushed lone Esc so
/// both behave identically. A recoverable fault is already a banner (set by the
/// interpreter from the `Cmd`'s `fail_op`); only a fatal fault propagates to the
/// errdefer restore + exit.
fn serviceKey(io: std.Io, allocator: std.mem.Allocator, t: *term.Term, painter: Painter, fetches: *Fetches, app: *App, store: *Storages, key: Key) RunError!void {
    const c = step(allocator, app.mt_path, app, key); // mutates nav/editing in place; clears the banner
    if (app.quit) {
        freeCmdArgv(allocator, c); // a quit key can still return a stray Cmd (it won't)
        return;
    }
    try pump(io, allocator, t, painter, fetches, app, store, c);
    try onEntryReload(io, allocator, t, painter, fetches, app, store);
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

/// Drive `step` in place for a nav/editing test and free any effect argv it
/// produces — these tests assert on the resulting `App` state, not the `Cmd`.
fn stepA(a: *App, key: Key) void {
    freeCmdArgv(std.testing.allocator, step(std.testing.allocator, a.mt_path, a, key));
}

/// A no-op paint handle for unit tests that drive a lazy loader directly: the
/// test children all finish before the first poll timeout, so the tick never
/// fires and the fd/frame are never touched.
fn testPainter(frame: *[]u8) Painter {
    return .{ .fd = -1, .frame = frame };
}

test "a data-free App renders the full chrome so the skeleton paint is real" {
    var app: App = .{}; // active .search, empty storage, no counts loaded
    var buf: [8192]u8 = undefined;
    const out = renderFrame(&buf, &app, 80, 24);
    for ([_][]const u8{ "Search", "Installed", "Outdated", "Services", "Doctor" }) |title|
        try std.testing.expect(std.mem.indexOf(u8, out, title) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "quit") != null); // footer help present
}

test "tab cycles and 1-5 jump to a tab" {
    var a: App = .{};
    try std.testing.expectEqual(Tab.search, a.active); // the dashboard opens on Search
    stepA(&a, .tab);
    try std.testing.expectEqual(Tab.installed, a.active);
    stepA(&a, ch('3'));
    try std.testing.expectEqual(Tab.outdated, a.active);
    stepA(&a, ch('1'));
    try std.testing.expectEqual(Tab.search, a.active);
}

test "left and right arrows switch tabs both directions and wrap" {
    var a: App = .{};
    stepA(&a, .right);
    try std.testing.expectEqual(Tab.installed, a.active);
    stepA(&a, .left);
    try std.testing.expectEqual(Tab.search, a.active);
    stepA(&a, .left); // wrap backward to the last tab
    try std.testing.expectEqual(Tab.doctor, a.active);
}

test "a committed filter survives a tab round-trip" {
    var a: App = .{};
    stepA(&a, ch('/')); // enter filter mode
    try std.testing.expect(a.editing);
    stepA(&a, ch('w'));
    stepA(&a, ch('g'));
    stepA(&a, .enter); // commit
    try std.testing.expect(!a.editing);
    stepA(&a, .tab); // leave the tab
    stepA(&a, .tab);
    stepA(&a, .tab);
    stepA(&a, .tab);
    stepA(&a, .tab); // and come back (five tabs now)
    try std.testing.expectEqualStrings("wg", activeFilterText(&a));
}

test "esc in normal mode routes to the active tab so it can cancel its guard" {
    var a: App = .{ .active = .installed };
    a.states.installed.confirm_uninstall = installed.ConfirmTarget.init("curl");
    stepA(&a, .esc); // not editing → must reach the tab, which lowers the guard
    try std.testing.expect(a.states.installed.confirm_uninstall == null);
}

test "ttyReadable sees a buffered byte and times out on silence" {
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    try std.testing.expect(!ttyReadable(fds[0], 1)); // silent pipe: the window elapses
    try std.testing.expectEqual(@as(isize, 1), std.c.write(fds[1], "x", 1));
    try std.testing.expect(ttyReadable(fds[0], 1)); // a byte is waiting: ready
}

test "fetch_spec declares each tab's background audit, byte-identical to the old switches" {
    // Read generically through the same `moduleFor` dispatch the render path uses.
    const outdated_spec = fetchSpec(.outdated).?;
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"outdated"}), outdated_spec.verb);
    try std.testing.expectEqual(@as(u8, 0), outdated_spec.max_ok_exit);
    try std.testing.expectEqualStrings("outdated refresh failed", outdated_spec.refresh_op);

    const services_spec = fetchSpec(.services).?;
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "services", "list" }), services_spec.verb);
    try std.testing.expectEqual(@as(u8, 0), services_spec.max_ok_exit);
    try std.testing.expectEqualStrings("services refresh failed", services_spec.refresh_op);

    // Doctor tolerates its severity exit (≤2) where the others require a clean 0.
    const doctor_spec = fetchSpec(.doctor).?;
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"doctor"}), doctor_spec.verb);
    try std.testing.expectEqual(@as(u8, 2), doctor_spec.max_ok_exit);
    try std.testing.expectEqualStrings("doctor refresh failed", doctor_spec.refresh_op);

    // Synchronous tabs never background-fetch.
    try std.testing.expectEqual(@as(?tab.FetchSpec, null), fetchSpec(.installed));
    try std.testing.expectEqual(@as(?tab.FetchSpec, null), fetchSpec(.search));
}

const guard_pkgs = [_]installed.Pkg{
    .{ .name = "pkga", .version = "1", .kind = .formula, .pinned = false, .size_bytes = null, .linked = null },
    .{ .name = "pkgb", .version = "1", .kind = .formula, .pinned = false, .size_bytes = null, .linked = null },
};

test "navigation while the uninstall guard is up cancels it instead of retargeting" {
    var a: App = .{ .active = .installed };
    a.states.installed.items = &guard_pkgs;
    stepA(&a, ch('x')); // arm on pkga (row 0)
    try std.testing.expect(a.states.installed.confirm_uninstall != null);
    stepA(&a, .down); // modal: the key resolves the guard (cancel), not the list
    try std.testing.expect(a.states.installed.confirm_uninstall == null);
    stepA(&a, ch('y')); // no longer a confirmation — must not spawn an uninstall
    try std.testing.expect(a.states.installed.pending_uninstall == null);
    try std.testing.expectEqual(@as(usize, 0), a.states.installed.chrome.view.selected);
}

test "q while the uninstall guard is up cancels it instead of quitting" {
    var a: App = .{ .active = .installed };
    a.states.installed.items = &guard_pkgs;
    stepA(&a, ch('x'));
    stepA(&a, ch('q'));
    try std.testing.expect(!a.quit); // the guard consumed the key
    try std.testing.expect(a.states.installed.confirm_uninstall == null);
}

test "slash while the uninstall guard is up cancels it instead of opening the filter" {
    var a: App = .{ .active = .installed };
    a.states.installed.items = &guard_pkgs;
    stepA(&a, ch('x'));
    stepA(&a, ch('/'));
    try std.testing.expect(!a.editing);
    try std.testing.expect(a.states.installed.confirm_uninstall == null);
}

test "tab switch while the uninstall guard is up resolves the guard, not the tab bar" {
    var a: App = .{ .active = .installed };
    a.states.installed.items = &guard_pkgs;
    stepA(&a, ch('x'));
    stepA(&a, .tab);
    try std.testing.expect(a.states.installed.confirm_uninstall == null); // never left armed
    try std.testing.expectEqual(Tab.installed, a.active); // the key was consumed by the guard
}

test "esc clears the filter and leaves edit mode" {
    var a: App = .{};
    stepA(&a, ch('/'));
    stepA(&a, ch('x'));
    stepA(&a, .esc);
    try std.testing.expect(!a.editing);
    try std.testing.expectEqualStrings("", activeFilterText(&a));
}

test "backspace edits the active filter while typing" {
    var a: App = .{};
    stepA(&a, ch('/'));
    stepA(&a, ch('a'));
    stepA(&a, ch('b'));
    stepA(&a, .backspace);
    try std.testing.expectEqualStrings("a", activeFilterText(&a));
}

test "q and ctrl_c request quit" {
    var a: App = .{};
    stepA(&a, ch('q'));
    try std.testing.expect(a.quit);
    var b: App = .{};
    stepA(&b, .ctrl_c);
    try std.testing.expect(b.quit);
}

test "down increments the selection, up saturates at zero" {
    var a: App = .{};
    stepA(&a, .down);
    stepA(&a, .down);
    try std.testing.expectEqual(@as(usize, 2), activeChrome(&a).view.selected);
    stepA(&a, .up);
    stepA(&a, .up);
    stepA(&a, .up);
    try std.testing.expectEqual(@as(usize, 0), activeChrome(&a).view.selected);
}

test "page keys jump by a page and saturate; home returns to the top" {
    var a: App = .{};
    stepA(&a, .page_down);
    try std.testing.expectEqual(@as(usize, page_step), activeChrome(&a).view.selected);
    stepA(&a, .page_up);
    stepA(&a, .page_up); // already at 0 → saturates, no underflow
    try std.testing.expectEqual(@as(usize, 0), activeChrome(&a).view.selected);
    stepA(&a, .down);
    stepA(&a, .down);
    stepA(&a, .home);
    try std.testing.expectEqual(@as(usize, 0), activeChrome(&a).view.selected);
}

test "a non-command printable key in normal mode is inert (routed, no state change)" {
    var b: App = .{};
    stepA(&b, ch('z')); // not q / 1-4 / /
    try std.testing.expectEqual(Tab.search, b.active);
    try std.testing.expect(!b.editing);
    try std.testing.expect(!b.quit);
}

test "per-tab filters are independent across tabs" {
    var a: App = .{};
    stepA(&a, ch('/'));
    stepA(&a, ch('a')); // installed filter = "a"
    stepA(&a, .enter);
    stepA(&a, .tab); // outdated
    try std.testing.expectEqualStrings("", activeFilterText(&a)); // its own empty filter
}

test "Enter on the Search tab focuses the query box rather than firing an empty search" {
    var a: App = .{ .active = .search };
    const c = step(std.testing.allocator, a.mt_path, &a, .enter);
    defer freeCmdArgv(std.testing.allocator, c);
    try std.testing.expect(a.editing); // the query box is now focused for typing
    try std.testing.expect(c == .none); // no search fired yet
}

test "Enter on the Search tab opens info once results are loaded" {
    const items = [_]search.Match{.{ .name = "wget", .kind = .formula, .installed = false }};
    var a: App = .{ .active = .search };
    a.states.search.items = &items;
    a.states.search.phase = .loaded;
    const c = step(std.testing.allocator, a.mt_path, &a, .enter);
    defer freeCmdArgv(std.testing.allocator, c);
    try std.testing.expect(!a.editing); // a row is active, so Enter inspects it, not the box
    try std.testing.expect(c == .read); // the `mt info` read for the active hit
    try std.testing.expectEqualStrings("info", c.read.argv[1]);
}

test "Enter on a data tab still routes as that tab's domain key, not a focus" {
    var a: App = .{ .active = .installed };
    a.states.installed.items = &guard_pkgs;
    const c = step(std.testing.allocator, a.mt_path, &a, .enter);
    defer freeCmdArgv(std.testing.allocator, c);
    try std.testing.expect(!a.editing);
    try std.testing.expect(c == .read); // installed Enter opens the `mt info` detail read
}

test "renderFrame shows the committed filter and the editing footer" {
    var a: App = .{};
    stepA(&a, ch('2')); // Installed tab: its box is a filter over the loaded list
    stepA(&a, ch('/'));
    stepA(&a, ch('j'));
    stepA(&a, ch('q')); // 'q' is a literal char while editing, not quit
    try std.testing.expect(!a.quit);
    var buf: [8192]u8 = undefined;
    const out = renderFrame(&buf, &a, 80, 24);
    try std.testing.expect(std.mem.indexOf(u8, out, "filter: jq_") != null); // filter line with caret
    try std.testing.expect(std.mem.indexOf(u8, out, "accept") != null); // editing footer
}

test "the Search tab labels its input box as a query, not a filter" {
    var a: App = .{ .active = .search };
    stepA(&a, ch('/'));
    stepA(&a, ch('r'));
    stepA(&a, ch('g'));
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
    var store: Storages = .{};
    defer store.deinit(alloc);
    try store.search.selected.toggle(alloc, "bat", .formula);
    try store.search.selected.toggle(alloc, "redis", .formula);
    search.syncSelected(&a.states.search, &store.search); // mirror the basket onto the leaf
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
    var a: App = .{ .active = .search, .spinner_frame = 0, .shared = .{ .installed_count = 7 } };
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
fn driveFetchToEnd(io: std.Io, allocator: std.mem.Allocator, app: *App, store: *Storages, fetches: *Fetches, t: Tab) !void {
    var frame: []u8 = try allocator.alloc(u8, 256);
    defer allocator.free(frame);
    const painter = testPainter(&frame); // repaint writes to fd −1 (a no-op); the buffer may grow
    while (fetches.getPtr(t).* != null) _ = try serviceFetches(io, allocator, painter, fetches, app, store);
}

test "startTabFetch kicks off the outdated audit, flags loading, and lands a known zero" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    var app: App = .{ .mt_path = "/usr/bin/true" }; // exit 0, no output == fresh prefix
    var store: Storages = .{};
    defer store.deinit(std.testing.allocator);
    var fetches: Fetches = .initFill(null);
    startTabFetch(t.io(), std.testing.allocator, &fetches, &app, .outdated);
    try std.testing.expect(fetches.getPtr(.outdated).* != null);
    try std.testing.expect(app.tab_loading.contains(.outdated)); // header spins from the first frame
    try driveFetchToEnd(t.io(), std.testing.allocator, &app, &store, &fetches, .outdated);
    try std.testing.expectEqual(@as(?usize, 0), app.shared.outdated_count); // empty payload is a known zero
    try std.testing.expect(!app.tab_loading.contains(.outdated)); // cleared when the fetch lands
    try std.testing.expect(!app.shared.banner.isSet());
}

test "startTabFetch is a quiet no-op on a spawn fault, never flagging loading" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    var app: App = .{ .mt_path = "/nonexistent/malt_outdated_probe" };
    var fetches: Fetches = .initFill(null);
    startTabFetch(t.io(), std.testing.allocator, &fetches, &app, .outdated);
    try std.testing.expect(fetches.getPtr(.outdated).* == null); // nothing to drive
    try std.testing.expect(!app.tab_loading.contains(.outdated)); // a failed kickoff stays unflagged
    try std.testing.expect(app.shared.outdated_count == null);
    try std.testing.expect(!app.shared.banner.isSet()); // launch-time, no nag
}

test "startTabFetch skips a tab whose audit is already in flight" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    var app: App = .{ .mt_path = "/usr/bin/true" };
    var store: Storages = .{};
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
    var store: Storages = .{};
    defer store.deinit(std.testing.allocator);
    var fetches: Fetches = .initFill(null);
    fetches.set(.outdated, .{ .tab = .outdated, .child = child, .fd = child.stdout.?.handle, .max_ok_exit = 0 });
    try driveFetchToEnd(t.io(), std.testing.allocator, &app, &store, &fetches, .outdated);
    try std.testing.expectEqual(@as(?usize, 1), app.shared.outdated_count); // header count
    try std.testing.expectEqual(@as(usize, 1), app.states.outdated.items.len); // the tab body, too
    try std.testing.expect(!app.tab_loading.contains(.outdated));
}

test "a malformed payload banners and keeps the outdated count unknown, never zero" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    const child = try std.process.spawn(t.io(), .{ .argv = &.{ "/bin/echo", "garbage" }, .stdout = .pipe, .stderr = .ignore });
    var app: App = .{};
    app.tab_loading.insert(.outdated);
    var store: Storages = .{};
    defer store.deinit(std.testing.allocator);
    var fetches: Fetches = .initFill(null);
    fetches.set(.outdated, .{ .tab = .outdated, .child = child, .fd = child.stdout.?.handle, .max_ok_exit = 0 });
    try driveFetchToEnd(t.io(), std.testing.allocator, &app, &store, &fetches, .outdated);
    try std.testing.expect(app.shared.outdated_count == null); // unknown (`—`), not 0
    try std.testing.expectEqualStrings("outdated refresh failed: BadJson", app.shared.banner.slice());
}

test "quiesceFetches kills an in-flight audit and re-marks it dirty, leaving storage intact" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    // A slow child so the audit is genuinely in flight (never drained) when killed —
    // the case where the pending mutation's argv still borrows the live storage.
    const child = try std.process.spawn(t.io(), .{ .argv = &.{ "/bin/sleep", "5" }, .stdout = .pipe, .stderr = .ignore });
    var app: App = .{ .shared = .{ .outdated_count = 7 } }; // a prior good count
    app.tab_loading.insert(.outdated);
    var fetches: Fetches = .initFill(null);
    fetches.set(.outdated, .{ .tab = .outdated, .child = child, .fd = child.stdout.?.handle, .max_ok_exit = 0 });

    quiesceFetches(t.io(), std.testing.allocator, &fetches, &app);

    try std.testing.expect(!anyFetchActive(&fetches)); // the writer is released for the mutation
    try std.testing.expect(!app.tab_loading.contains(.outdated)); // no longer flagged loading
    try std.testing.expect(app.shared.dirty.contains(.outdated)); // re-audit after the mutation
    // The audit is *not* applied: storage is untouched, so the mutation's argv (which
    // borrows those rows) cannot dangle. A wait-and-apply drain would swap it to 1.
    try std.testing.expectEqual(@as(?usize, 7), app.shared.outdated_count);
}

// The sole-orchestrator guard is a straight-line call in `performMutation` (quiesce,
// then re-exec). A read-only turn produces no `run_mutation` `Cmd`, so it never
// reaches the quiesce; only a mutation does.
test "service quiesces an in-flight audit before a mutating dispatch" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    const child = try std.process.spawn(t.io(), .{ .argv = &.{ "/bin/sleep", "5" }, .stdout = .pipe, .stderr = .ignore });
    var app: App = .{};
    app.tab_loading.insert(.outdated);
    var fetches: Fetches = .initFill(null);
    fetches.set(.outdated, .{ .tab = .outdated, .child = child, .fd = child.stdout.?.handle, .max_ok_exit = 0 });
    var tm = term.Term.init(t.io(), -1);

    // The re-exec re-enter faults on the headless (-1) term, but the quiesce runs
    // *first*; assert the audit was killed regardless of the mutation's outcome.
    const m: cmd.Cmd.Mutation = .{ .argv = &.{"/usr/bin/true"}, .tag = .outdated };
    _ = performMutation(t.io(), std.testing.allocator, &tm, &fetches, &app, m) catch {};

    try std.testing.expect(!anyFetchActive(&fetches)); // quiesced before the dispatch
}

test "a non-zero child exit fails the fetch without parsing a half-written doc" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    const child = try std.process.spawn(t.io(), .{ .argv = &.{"/usr/bin/false"}, .stdout = .pipe, .stderr = .ignore });
    var app: App = .{ .shared = .{ .outdated_count = 5 } }; // a prior good count
    app.tab_loading.insert(.outdated);
    var store: Storages = .{};
    defer store.deinit(std.testing.allocator);
    var fetches: Fetches = .initFill(null);
    fetches.set(.outdated, .{ .tab = .outdated, .child = child, .fd = child.stdout.?.handle, .max_ok_exit = 0 });
    try driveFetchToEnd(t.io(), std.testing.allocator, &app, &store, &fetches, .outdated);
    try std.testing.expectEqual(@as(?usize, 5), app.shared.outdated_count); // a bad exit keeps the last-good, never 0
    try std.testing.expect(app.shared.banner.isSet());
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
    var store: Storages = .{};
    defer store.deinit(std.testing.allocator);
    var fetches: Fetches = .initFill(null);
    fetches.set(.doctor, .{ .tab = .doctor, .child = child, .fd = child.stdout.?.handle, .max_ok_exit = 2 });
    try driveFetchToEnd(t.io(), std.testing.allocator, &app, &store, &fetches, .doctor);
    try std.testing.expect(!app.shared.banner.isSet()); // exit 1 ≤ 2 is OK for doctor
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
    var store: Storages = .{};
    defer store.deinit(std.testing.allocator);
    var fetches: Fetches = .initFill(null);
    fetches.set(.outdated, .{ .tab = .outdated, .child = child, .fd = child.stdout.?.handle, .max_ok_exit = 0 });
    try driveFetchToEnd(t.io(), std.testing.allocator, &app, &store, &fetches, .outdated);
    try std.testing.expectEqual(@as(?usize, rows), app.shared.outdated_count); // every row across every chunk
}

test "an overflowing fetch kills the live child and fails to last-good" {
    // A child that never stops emitting (no EOF) must not grow the buffer without
    // bound: past the cap, kill the still-running child and finish failed, keeping
    // the last-good count rather than a partial parse.
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    const child = try std.process.spawn(t.io(), .{ .argv = &.{"/usr/bin/yes"}, .stdout = .pipe, .stderr = .ignore });
    var app: App = .{ .shared = .{ .outdated_count = 5 } }; // a prior good count
    app.tab_loading.insert(.outdated);
    var store: Storages = .{};
    defer store.deinit(std.testing.allocator);
    var fetches: Fetches = .initFill(null);
    fetches.set(.outdated, .{ .tab = .outdated, .child = child, .fd = child.stdout.?.handle, .max_ok_exit = 0 });
    try driveFetchToEnd(t.io(), std.testing.allocator, &app, &store, &fetches, .outdated);
    try std.testing.expectEqual(@as(?usize, 5), app.shared.outdated_count); // last-good kept, not a partial
    try std.testing.expect(app.shared.banner.isSet());
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
    a.shared.banner.set("info for jq failed", "BadJson");
    var buf: [8192]u8 = undefined;
    const out = renderFrame(&buf, &a, 80, 24);
    try std.testing.expect(std.mem.indexOf(u8, out, "info for jq failed: BadJson") != null);
    // The banner takes the help line's slot, so the help text is not shown.
    try std.testing.expect(std.mem.indexOf(u8, out, "q: quit") == null);
}

test "a banner truncates width-aware to the terminal columns" {
    var a: App = .{};
    a.shared.banner.set("info for some-very-long-package-name failed", "ChildFailed");
    var buf: [8192]u8 = undefined;
    const out = renderFrame(&buf, &a, 24, 24); // narrow terminal
    // The full message cannot have been painted verbatim into 24 columns.
    try std.testing.expect(std.mem.indexOf(u8, out, "info for some-very-long-package-name failed: ChildFailed") == null);
}

test "any keypress clears a transient banner" {
    var a: App = .{};
    a.shared.banner.set("uninstall failed", "ChildFailed");
    try std.testing.expect(a.shared.banner.isSet());
    stepA(&a, .down); // a navigation key dismisses the stale banner
    try std.testing.expect(!a.shared.banner.isSet());
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
    a.shared.markStaleAfter(a.active);
    try std.testing.expect(!a.shared.dirty.contains(.outdated)); // refreshed inline, still fresh
    try std.testing.expect(a.shared.dirty.contains(.installed));
    try std.testing.expect(a.shared.dirty.contains(.services));
    try std.testing.expect(a.shared.dirty.contains(.doctor));
}

test "markStaleAfter is scalar-mediated: only the shared model, only dirty" {
    // The cross-tab staleness channel takes the shared read-model by pointer, not
    // an `App` — so it structurally cannot reach a tab's private `Storage`. Prove
    // it runs against a standalone `SharedModel` and touches nothing but `dirty`.
    var shared: SharedModel = .{ .installed_count = 3, .outdated_count = 1 };
    shared.banner.set("prior op", "PriorReason");
    shared.markStaleAfter(.services);
    // Every tab but the (freshly re-read) active one is now dirty.
    try std.testing.expect(!shared.dirty.contains(.services));
    try std.testing.expect(shared.dirty.contains(.installed));
    try std.testing.expect(shared.dirty.contains(.outdated));
    try std.testing.expect(shared.dirty.contains(.doctor));
    try std.testing.expect(shared.dirty.contains(.search));
    // The other shared scalars are left exactly as they were — no bleed into the
    // counts or the banner, so the writer touches only the staleness set.
    try std.testing.expectEqual(@as(?usize, 3), shared.installed_count);
    try std.testing.expectEqual(@as(?usize, 1), shared.outdated_count);
    try std.testing.expectEqualStrings("prior op: PriorReason", shared.banner.slice());
}

test "entering a dirty tab consumes the flag so its refetch runs at most once" {
    var a: App = .{ .active = .installed };
    a.shared.markStaleAfter(a.active);
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
    try std.testing.expect(a.shared.dirty.contains(.installed));
    try std.testing.expect(a.shared.dirty.contains(.outdated));
    try std.testing.expect(a.shared.dirty.contains(.services));
    try std.testing.expect(a.shared.dirty.contains(.doctor));
    try std.testing.expect(!a.shared.dirty.contains(.search)); // active tab renders without data
}

test "a newline in a child-derived op cannot inject an extra footer frame line" {
    // term_sanitize lets \n through; the footer paints via putContent, which drops
    // it, so a package name with an embedded newline can't split the frame.
    var a: App = .{};
    a.shared.banner.set("info for ev\nil failed", "BadJson");
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
    // Terminal-integrity + OOM: fatal — restore and exit (the crash-safety guarantee).
    try std.testing.expectEqual(ErrorClass.fatal, classify(error.NotATty));
    try std.testing.expectEqual(ErrorClass.fatal, classify(error.WriteFailed));
    try std.testing.expectEqual(ErrorClass.fatal, classify(error.TermiosFailed));
    try std.testing.expectEqual(ErrorClass.fatal, classify(error.OutOfMemory));
}

test "the hub imports no json/* parser — the dissolved-hub invariant" {
    // Each tab imports its own parser for render; the hub carried those imports only
    // as duplicates for effect functions now moved beside the tabs. Scan this source
    // to pin that no parser-import edge regresses back into the hub — a structural
    // invariant the type system can't express. The needle is split so this test's own
    // source never contains the contiguous marker it searches for.
    const src = @embedFile("app.zig");
    const needle = "@import(\"" ++ "json/";
    try std.testing.expect(std.mem.indexOf(u8, src, needle) == null);
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
    try refreshInstalledCount(t.io(), std.testing.allocator, app.mt_path, &app.shared);
    try std.testing.expectEqual(@as(?usize, 0), app.shared.installed_count); // populated, never null
    try std.testing.expect(!app.shared.banner.isSet());
}

test "the post-install count refresh overwrites a stale count without entering Installed" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    // The cross-tab-install gap: a count from before the mutation, with Installed
    // marked dirty (its full --size --linked payload reloads only on entry).
    var app: App = .{ .mt_path = "/usr/bin/true", .active = .search, .shared = .{ .installed_count = 6 } };
    app.shared.dirty.insert(.installed);
    try refreshInstalledCount(t.io(), std.testing.allocator, app.mt_path, &app.shared);
    try std.testing.expectEqual(@as(?usize, 0), app.shared.installed_count); // live again, not the stale 6
    try std.testing.expect(app.shared.dirty.contains(.installed)); // full payload still loads lazily on entry
}

test "a broken keg-count read banners and leaves the prior count untouched" {
    var t = std.Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    var app: App = .{ .mt_path = "/bin/echo", .shared = .{ .installed_count = 6 } }; // echo emits non-JSON → parse fails
    try std.testing.expectError(error.BadJson, refreshInstalledCount(t.io(), std.testing.allocator, app.mt_path, &app.shared));
    try std.testing.expectEqualStrings("keg count refresh failed: BadJson", app.shared.banner.slice());
    try std.testing.expectEqual(@as(?usize, 6), app.shared.installed_count); // a failed read keeps the last-good count
}

test "the Search footer switches to the basket-view keys when the basket view is open" {
    var a: App = .{ .active = .search };
    a.states.search.view = .basket;
    var buf: [8192]u8 = undefined;
    const out = renderFrame(&buf, &a, 120, 24);
    try std.testing.expect(std.mem.indexOf(u8, out, "remove") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "l: results") != null);
}

test "committing the filter fires a search on the Search tab but no domain key elsewhere" {
    // On Search the filter doubles as the search box, so Enter commits *and*
    // requests the read — 'i' typed mid-edit is literal query text, not install.
    var a: App = .{ .active = .search };
    stepA(&a, ch('/'));
    stepA(&a, ch('f'));
    stepA(&a, ch('i'));
    const c = step(std.testing.allocator, a.mt_path, &a, .enter); // commit → the search read
    defer freeCmdArgv(std.testing.allocator, c);
    try std.testing.expect(!a.editing);
    try std.testing.expect(c == .read); // committing the query *is* the search
    try std.testing.expectEqualStrings("search", c.read.argv[1]);
    try std.testing.expectEqual(search.Phase.searching, a.states.search.phase); // flipped for the paint
    try std.testing.expectEqualStrings("fi", activeFilterText(&a));

    // The same commit on a non-search tab must not be routed to its domain key
    // (outdated's Enter would otherwise fire an upgrade); the commit is a pure no-op.
    var b: App = .{ .active = .outdated };
    stepA(&b, ch('/'));
    stepA(&b, ch('x'));
    const bc = step(std.testing.allocator, b.mt_path, &b, .enter);
    defer freeCmdArgv(std.testing.allocator, bc);
    try std.testing.expect(!b.editing);
    try std.testing.expect(bc == .none); // no effect from committing a filter
}

test "the 1 key jumps to the Search tab, the 5 key to Doctor" {
    var a: App = .{};
    stepA(&a, .tab); // move off Search first
    stepA(&a, ch('1'));
    try std.testing.expectEqual(Tab.search, a.active);
    stepA(&a, ch('5'));
    try std.testing.expectEqual(Tab.doctor, a.active);
}

test "refusalReason refuses non-tty, NO_COLOR, and CI; allows a clean tty" {
    try std.testing.expectEqual(@as(?Refusal, .not_a_tty), refusalReason(false, true, false, false));
    try std.testing.expectEqual(@as(?Refusal, .not_a_tty), refusalReason(true, false, false, false));
    try std.testing.expectEqual(@as(?Refusal, .no_color), refusalReason(true, true, true, false));
    try std.testing.expectEqual(@as(?Refusal, .ci), refusalReason(true, true, false, true));
    try std.testing.expect(refusalReason(true, true, false, false) == null);
}
