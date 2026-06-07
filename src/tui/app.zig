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
const tab = @import("tab.zig");
const tab_bar = @import("tab_bar.zig");
const filter_input = @import("filter_input.zig");
const keys = @import("keys.zig");
const term = @import("term.zig");
const layout = @import("layout.zig");
const scroll_list = @import("scroll_list.zig");

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
    active: Tab = .installed,
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
};

/// After a delegated mutation the active tab was just re-read inline, so it is
/// fresh; the others may now be stale. Mark them dirty — a dirty tab refetches
/// only when entered (`takeDirty`), so the cost is paid lazily, on view.
pub fn markStaleAfterMutation(a: *App) void {
    a.dirty = std.EnumSet(Tab).initFull();
    a.dirty.remove(a.active);
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
            // committing the query *is* the search. Only the Search tab claims
            // the commit — every other tab's filter merely narrows an already
            // loaded list, so routing Enter there would mis-fire their domain key.
            if (a.active == .search) routeToTab(a, .enter);
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
        .enter, .space, .end, .esc => routeToTab(a, key),
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
        .too_small => {
            f.moveTo(1, 1);
            var tmp: [80]u8 = undefined;
            f.put(layout.render(&tmp, .{ .rows = &.{} }, cols, rows));
        },
        .ok => |r| {
            f.moveTo(r.tab_bar.row, 1);
            var tb: [256]u8 = undefined;
            f.put(tab_bar.render(&tb, app.active, tabTitles(), cols));
            f.put(color.Style.reset.code()); // a truncated active title must not bleed bold downward

            f.moveTo(r.filter.row, 1);
            var fb: [filter_input.max_len + 8]u8 = undefined;
            f.put(filter_input.render(&fb, activeFilterText(app), app.editing, cols));

            renderActive(app, &f, r.content);

            // Footer: a rule line separating content, then either the transient
            // recoverable-error banner or the dimmed help line on the row below.
            f.moveTo(r.footer.row, 1);
            putRule(&f, cols);
            f.moveTo(r.footer.row + 1, 1);
            if (app.banner.isSet()) {
                // Undimmed + yellow so a recoverable failure reads as a warning,
                // not chrome; `putContent` drops line-breakers the sanitizer let
                // through, `truncate` keeps it within the column budget.
                f.put(color.Style.yellow.code());
                f.putContent(scroll_list.truncate(app.banner.slice(), cols));
                f.put(color.Style.reset.code());
            } else {
                f.put(color.Style.dim.code());
                f.put(scroll_list.truncate(footerHelp(app.editing), cols));
                f.put(color.Style.reset.code());
            }
        },
    }
    return f.slice();
}

fn putRule(f: *tab.Frame, cols: u16) void {
    var i: u16 = 0;
    while (i < cols) : (i += 1) f.put("─");
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

    fn deinit(self: *Store, allocator: std.mem.Allocator) void {
        if (self.installed) |p| p.deinit();
        if (self.detail) |p| p.deinit();
        if (self.outdated) |p| p.deinit();
        if (self.outdated_checked.len != 0) allocator.free(self.outdated_checked);
        if (self.services) |p| p.deinit();
        if (self.doctor) |p| p.deinit();
        if (self.search) |p| p.deinit();
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
    const bytes = try spawn.readJson(io, allocator, argv);
    defer allocator.free(bytes);

    const parsed = try list_json.parse(allocator, bytes);
    if (store.installed) |old| old.deinit();
    store.installed = parsed;
    app.states.installed.items = parsed.items;
    app.states.installed.detail = null; // a refreshed list invalidates the old detail
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
fn loadOutdated(io: std.Io, allocator: std.mem.Allocator, app: *App, store: *Store) RunError!void {
    // Annotate any failure as a recoverable banner; the loop boundary decides
    // recoverable vs fatal. The store is swapped only after a clean parse, so a
    // failure keeps the last-good rows and their selection.
    errdefer |err| app.banner.set("outdated refresh failed", @errorName(err));
    const argv = try spawn.jsonArgv(allocator, app.mt_path, &.{"outdated"});
    defer allocator.free(argv);
    const bytes = try spawn.readJson(io, allocator, argv);
    defer allocator.free(bytes);

    const parsed = try outdated_json.parse(allocator, bytes);
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
fn doUpgrade(io: std.Io, allocator: std.mem.Allocator, t: *term.Term, app: *App, store: *Store) RunError!void {
    const argv = (try upgradeArgv(allocator, app.mt_path, &app.states.outdated)) orelse return; // empty selection: no-op
    defer allocator.free(argv);
    {
        // A non-zero `mt upgrade` re-enters the dashboard (the user keeps malt's
        // real output in their scrollback) and surfaces as a recoverable banner;
        // only a terminal fault is fatal. Scoped so the refresh below reports
        // under its own op, not "upgrade".
        errdefer |err| app.banner.set("upgrade failed", @errorName(err));
        try spawn.runInlineReenter(t, argv);
    }
    try loadOutdated(io, allocator, app, store); // the upgraded rows are gone — refetch
    markStaleAfterMutation(app); // Installed sizes/versions changed too
}

/// Perform any effect the pure `step` requested on the Outdated tab, then clear
/// it, and lazily (re)load on first entry or after a mutation marked it dirty.
fn serviceOutdated(io: std.Io, allocator: std.mem.Allocator, t: *term.Term, app: *App, store: *Store) RunError!void {
    const req = app.states.outdated.request;
    app.states.outdated.request = .none;
    switch (req) {
        .none => {},
        .upgrade => try doUpgrade(io, allocator, t, app, store),
    }
    // Lazy per-tab load: first activation and post-mutation staleness both arrive
    // as the dirty flag (set at init and by `markStaleAfterMutation`).
    if (app.active == .outdated and takeDirty(app, .outdated)) {
        try loadOutdated(io, allocator, app, store);
    }
}

/// (Re)read `mt services list --json` and repoint the Services tab's rows at the
/// fresh parse, freeing the previous one.
fn loadServices(io: std.Io, allocator: std.mem.Allocator, app: *App, store: *Store) RunError!void {
    // Annotate any failure as a recoverable banner; the loop boundary decides
    // recoverable vs fatal. The store is swapped only after a clean parse, so a
    // failure keeps the last-good rows and their selection.
    errdefer |err| app.banner.set("services refresh failed", @errorName(err));
    const argv = try spawn.jsonArgv(allocator, app.mt_path, &.{ "services", "list" });
    defer allocator.free(argv);
    const bytes = try spawn.readJson(io, allocator, argv);
    defer allocator.free(bytes);

    const parsed = try services_json.parse(allocator, bytes);
    if (store.services) |old| old.deinit();
    store.services = parsed;
    app.states.services.items = parsed.items;
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
fn doServiceAction(io: std.Io, allocator: std.mem.Allocator, t: *term.Term, app: *App, store: *Store, action: []const u8) RunError!void {
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
    try loadServices(io, allocator, app, store); // the state changed — refetch
    markStaleAfterMutation(app);
}

/// Perform any lifecycle effect the pure `step` requested on the Services tab,
/// then clear it, and lazily (re)load on first entry or after a mutation marked
/// it dirty.
fn serviceServices(io: std.Io, allocator: std.mem.Allocator, t: *term.Term, app: *App, store: *Store) RunError!void {
    const req = app.states.services.request;
    app.states.services.request = .none;
    switch (req) {
        .none => {},
        .start => try doServiceAction(io, allocator, t, app, store, "start"),
        .stop => try doServiceAction(io, allocator, t, app, store, "stop"),
        .restart => try doServiceAction(io, allocator, t, app, store, "restart"),
    }
    // Lazy per-tab load: first activation and post-mutation staleness both arrive
    // as the dirty flag (set at init and by `markStaleAfterMutation`).
    if (app.active == .services and takeDirty(app, .services)) {
        try loadServices(io, allocator, app, store);
    }
}

/// (Re)read `mt doctor --json` and repoint the Doctor tab's findings at the fresh
/// parse, freeing the previous one.
fn loadDoctor(io: std.Io, allocator: std.mem.Allocator, app: *App, store: *Store) RunError!void {
    // Annotate any failure as a recoverable banner; the loop boundary decides
    // recoverable vs fatal. The store is swapped only after a clean parse, so a
    // failure keeps the last-good findings and their selection.
    errdefer |err| app.banner.set("doctor refresh failed", @errorName(err));
    const argv = try spawn.jsonArgv(allocator, app.mt_path, &.{"doctor"});
    defer allocator.free(argv);
    const bytes = try spawn.readJson(io, allocator, argv);
    defer allocator.free(bytes);

    const parsed = try doctor_json.parse(allocator, bytes);
    if (store.doctor) |old| old.deinit();
    store.doctor = parsed;
    app.states.doctor.items = parsed.items;
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
fn doDoctorFix(io: std.Io, allocator: std.mem.Allocator, t: *term.Term, app: *App, store: *Store) RunError!void {
    const argv = (try doctorFixArgv(allocator, app.mt_path, &app.states.doctor)) orelse return; // nothing fixable selected
    defer allocator.free(argv);
    {
        // A non-zero `mt doctor --fix` re-enters the dashboard (the user keeps
        // malt's real output, including any typed-confirm, in their scrollback)
        // and surfaces as a recoverable banner; only a terminal fault is fatal.
        // Scoped so the refresh below reports under its own op, not the fix.
        errdefer |err| app.banner.set("doctor fix failed", @errorName(err));
        try spawn.runInlineReenter(t, argv);
    }
    try loadDoctor(io, allocator, app, store); // the finding may be resolved — refetch
    markStaleAfterMutation(app);
}

/// Perform any fix effect the pure `step` requested on the Doctor tab, then clear
/// it, and lazily (re)load on first entry or after a mutation marked it dirty.
fn serviceDoctor(io: std.Io, allocator: std.mem.Allocator, t: *term.Term, app: *App, store: *Store) RunError!void {
    const req = app.states.doctor.request;
    app.states.doctor.request = .none;
    switch (req) {
        .none => {},
        .fix => try doDoctorFix(io, allocator, t, app, store),
    }
    // Lazy per-tab load: first activation and post-mutation staleness both arrive
    // as the dirty flag (set at init and by `markStaleAfterMutation`).
    if (app.active == .doctor and takeDirty(app, .doctor)) {
        try loadDoctor(io, allocator, app, store);
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
    if (store.search) |old| old.deinit();
    store.search = parsed;
    app.states.search.items = parsed.items;
    app.states.search.phase = .loaded;
    // A fresh query is a new result set, so an old cursor would point at an
    // unrelated row; reset to the top.
    app.states.search.chrome.view = .{};
}

/// Build `mt install [--formula|--cask] <name>` for the selected hit. Pure over
/// the tab state: null when nothing installable is selected (the no-op), else an
/// owned argv whose `name` element borrows from the parse storage. Caller frees
/// the returned slice (not its elements).
fn installArgv(allocator: std.mem.Allocator, mt_path: []const u8, st: *const search.State) std.mem.Allocator.Error!?[]const []const u8 {
    const m = search.selectedMatch(st) orelse return null; // empty list: no-op
    if (m.installed) return null; // already installed: inert
    // The search result's kind is authoritative, so disambiguate the install
    // explicitly: a name can exist as both a formula and a cask, where bare
    // `mt install <name>` silently picks the formula. Exhaustive switch — a new
    // kind is a compile error, never a silent default.
    const kind_flag: []const u8 = switch (m.kind) {
        .formula => "--formula",
        .cask => "--cask",
    };
    return try spawn.inlineArgv(allocator, mt_path, &.{ "install", kind_flag, m.name });
}

/// Delegate the selected hit's install to the real `mt` inline, then re-run the
/// query so its marker flips. The argv's `name` borrows from the current parse
/// storage; the post-spawn re-search frees that storage, so the name is not read
/// afterwards.
fn doInstall(io: std.Io, allocator: std.mem.Allocator, t: *term.Term, app: *App, store: *Store) RunError!void {
    const argv = (try installArgv(allocator, app.mt_path, &app.states.search)) orelse return; // nothing installable selected
    defer allocator.free(argv);
    {
        // A non-zero `mt install` re-enters the dashboard (the user keeps malt's
        // real output, including any prompt, in their scrollback) and surfaces as
        // a recoverable banner; only a terminal fault is fatal. Scoped so the
        // re-search below reports under its own op, not "install".
        errdefer |err| app.banner.set("install failed", @errorName(err));
        try spawn.runInlineReenter(t, argv);
    }
    // Re-run the same query so the freshly installed hit's marker flips — the
    // backend's install-aware `installed` flag does the rest (no `mt list` call).
    try loadSearch(io, allocator, app, store);
    markStaleAfterMutation(app); // Installed/Outdated/Services may have changed too
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
    }
}

/// Drain the active tab's pending effects after a keypress. Each tab's service is
/// a no-op unless that tab is active and has a request or is due a lazy refresh,
/// so calling each one each loop is cheap and keeps the dispatch flat.
fn service(io: std.Io, allocator: std.mem.Allocator, t: *term.Term, app: *App, store: *Store) RunError!void {
    try serviceInstalled(io, allocator, t, app, store);
    try serviceOutdated(io, allocator, t, app, store);
    try serviceServices(io, allocator, t, app, store);
    try serviceDoctor(io, allocator, t, app, store);
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
pub fn run(io: std.Io, allocator: std.mem.Allocator, stderr: std.Io.File, environ: std.process.Environ, mt_path: []const u8) RunError!void {
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

    var app: App = .{ .mt_path = mt_path }; // re-exec this mt for delegated mutations
    app.dirty.insert(.outdated); // lazy: load `mt outdated --json` on first activation
    app.dirty.insert(.services); // lazy: load `mt services list --json` on first activation
    app.dirty.insert(.doctor); // lazy: load `mt doctor --json` on first activation
    var store: Store = .{};
    defer store.deinit(allocator);
    var frame = try allocator.alloc(u8, frameCap(term.currentSize()));
    defer allocator.free(frame);

    try loadInstalled(io, allocator, &app, &store); // the default tab's data, before first paint
    try repaint(fd, &frame, allocator, &app);

    var decoder: keys.Decoder = .{};
    var rbuf: [64]u8 = undefined;
    while (!app.quit) {
        if (term.takeResized()) try repaint(fd, &frame, allocator, &app);
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
                    // A recoverable backend fault becomes the banner the failing
                    // op already set and the loop continues; only a fatal fault
                    // (terminal/OOM) propagates to the errdefer restore + exit.
                    service(io, allocator, &t, &app, &store) catch |err| switch (classify(err)) {
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

test "tab cycles and 1-4 jump to a tab" {
    var a: App = .{};
    a = step(a, .tab);
    try std.testing.expectEqual(Tab.outdated, a.active);
    a = step(a, ch('3'));
    try std.testing.expectEqual(Tab.services, a.active);
    a = step(a, ch('1'));
    try std.testing.expectEqual(Tab.installed, a.active);
}

test "left and right arrows switch tabs both directions and wrap" {
    var a: App = .{};
    a = step(a, .right);
    try std.testing.expectEqual(Tab.outdated, a.active);
    a = step(a, .left);
    try std.testing.expectEqual(Tab.installed, a.active);
    a = step(a, .left); // wrap backward to the last tab
    try std.testing.expectEqual(Tab.search, a.active);
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
    var a: App = .{};
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

test "renderFrame shows the committed filter and the editing footer" {
    var a: App = .{};
    a = step(a, ch('/'));
    a = step(a, ch('j'));
    a = step(a, ch('q')); // 'q' is a literal char while editing, not quit
    try std.testing.expect(!a.quit);
    var buf: [8192]u8 = undefined;
    const out = renderFrame(&buf, &a, 80, 24);
    try std.testing.expect(std.mem.indexOf(u8, out, "filter: jq_") != null); // filter line with caret
    try std.testing.expect(std.mem.indexOf(u8, out, "accept") != null); // editing footer
}

test "renderFrame draws a footer rule above a dimmed help line" {
    var a: App = .{};
    var buf: [8192]u8 = undefined;
    const out = renderFrame(&buf, &a, 80, 24);
    try std.testing.expect(std.mem.indexOf(u8, out, "─") != null); // horizontal rule
    try std.testing.expect(std.mem.indexOf(u8, out, color.Style.dim.code()) != null); // dimmed help
    try std.testing.expect(std.mem.indexOf(u8, out, "quit") != null);
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
    try std.testing.expectError(error.BadJson, loadOutdated(t.io(), std.testing.allocator, &app, &store));
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
    try std.testing.expectError(error.BadJson, loadServices(t.io(), std.testing.allocator, &app, &store));
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
    try std.testing.expectError(error.BadJson, loadDoctor(t.io(), std.testing.allocator, &app, &store));
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

test "installArgv disambiguates by kind: --cask for a cask hit, --formula for a formula" {
    const items = [_]search.Match{
        .{ .name = "firefox", .kind = .cask, .installed = false },
        .{ .name = "wget", .kind = .formula, .installed = false },
    };
    var st: search.State = .{ .items = &items };
    st.chrome.view.selected = 0; // firefox (cask)
    {
        const argv = (try installArgv(std.testing.allocator, "/opt/homebrew/bin/mt", &st)).?;
        defer std.testing.allocator.free(argv);
        try std.testing.expectEqual(@as(usize, 4), argv.len); // mt, install, --cask, name
        try std.testing.expectEqualStrings("install", argv[1]);
        try std.testing.expectEqualStrings("--cask", argv[2]);
        try std.testing.expectEqualStrings("firefox", argv[3]);
    }
    st.chrome.view.selected = 1; // wget (formula)
    {
        const argv = (try installArgv(std.testing.allocator, "/opt/homebrew/bin/mt", &st)).?;
        defer std.testing.allocator.free(argv);
        try std.testing.expectEqualStrings("--formula", argv[2]);
        try std.testing.expectEqualStrings("wget", argv[3]);
    }
}

test "installArgv returns null on an already-installed hit and on an empty list" {
    const items = [_]search.Match{.{ .name = "jq", .kind = .formula, .installed = true }};
    const st: search.State = .{ .items = &items };
    try std.testing.expect((try installArgv(std.testing.allocator, "/bin/mt", &st)) == null); // already installed
    const empty: search.State = .{ .items = &.{} };
    try std.testing.expect((try installArgv(std.testing.allocator, "/bin/mt", &empty)) == null); // nothing selected
}

test "installArgv disambiguates a name that exists as both a formula and a cask" {
    // The motivating collision: one name, two kinds. The selected hit's kind
    // picks the flag, so the install can't silently default to the formula when
    // the user chose the cask — the reason the explicit flag exists.
    const items = [_]search.Match{
        .{ .name = "docker", .kind = .formula, .installed = false },
        .{ .name = "docker", .kind = .cask, .installed = false },
    };
    var st: search.State = .{ .items = &items };
    st.chrome.view.selected = 1; // the cask, not the formula above it
    const argv = (try installArgv(std.testing.allocator, "/bin/mt", &st)).?;
    defer std.testing.allocator.free(argv);
    try std.testing.expectEqualStrings("--cask", argv[2]);
    try std.testing.expectEqualStrings("docker", argv[3]);
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

test "the 5 key jumps to the Search tab" {
    var a: App = .{};
    a = step(a, ch('5'));
    try std.testing.expectEqual(Tab.search, a.active);
}

test "refusalReason refuses non-tty, NO_COLOR, and CI; allows a clean tty" {
    try std.testing.expectEqual(@as(?Refusal, .not_a_tty), refusalReason(false, true, false, false));
    try std.testing.expectEqual(@as(?Refusal, .not_a_tty), refusalReason(true, false, false, false));
    try std.testing.expectEqual(@as(?Refusal, .no_color), refusalReason(true, true, true, false));
    try std.testing.expectEqual(@as(?Refusal, .ci), refusalReason(true, true, false, true));
    try std.testing.expect(refusalReason(true, true, false, false) == null);
}
