//! malt — the `mt tui` effect interpreter: one domain-agnostic `perform`.
//!
//! Leaf module. A pure `step`/`update` returns a `cmd.Cmd`; this runs it and hands
//! back a `cmd.Msg`. `perform` covers every read mode (blocking, polled, background)
//! and the self-classifying `run_mutation`: it spawns the argv, captures bytes,
//! calls the `Cmd`'s **carried** parser (`cmd.ParseFn`), and routes the `Parsed` /
//! exit code back as a `Msg`. The WAL single-writer drain is a scheduler rule keyed
//! on the mutation's own `.run_mutation` variant — no fold over foreign tab state.
//!
//! It imports `spawn` and `term` and the `cmd`/`ctx` sink leaves — and **no** tab
//! module and **no** `json/*`. That is the property a file-level check pins: the
//! interpreter knows nothing about any tab, so the hub owns tab routing (`moduleFor`
//! → `update`) and whole-dashboard rendering (only the hub can render every tab, so
//! a mid-load repaint fires through the injected `Painter` closure). Child-derived
//! bytes reach the frame only through the two sanitization choke points the hub
//! keeps (`ctx.Banner.set`, `tab.Frame.putContent`) — this file routes to them, not
//! around them.

const std = @import("std");
const cmd = @import("cmd.zig");
const ctx = @import("ctx.zig");
const spawn = @import("spawn.zig");
const tab_bar = @import("tab_bar.zig");
const term = @import("term.zig");

const Painter = ctx.Painter;
const Fetches = ctx.Fetches;
const SharedModel = ctx.SharedModel;
const TabFetch = ctx.TabFetch;

// The terminal/loop/spawn faults `perform` and the hub's count-read can raise. A
// tab parser's own errors flow back through the interpreter as a `.failed` `Msg`
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

/// Poll timeout between spinner ticks while any background fetch runs — short
/// enough to read as animation, long enough not to busy-spin.
pub const fetch_tick_ms: i32 = 80;

/// Cap on a background fetch's captured bytes, sized like the blocking drain's
/// `--json` shape with headroom.
pub const max_fetch_bytes: usize = 4 * 1024 * 1024;

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

/// True when any fetch is in flight — the loop only multiplexes then; with none
/// active it falls back to the lone blocking tty read, so an idle dashboard has
/// zero wakeups.
pub fn anyFetchActive(fetches: *const Fetches) bool {
    for (&fetches.values) |*v| if (v.* != null) return true;
    return false;
}

/// Free a `Cmd`'s heap argv once it is performed — the ownership contract: the tab
/// (in `step`/`update`) builds the argv, the interpreter frees the slice (never its
/// elements, which borrow parse storage).
pub fn freeCmdArgv(allocator: std.mem.Allocator, c: cmd.Cmd) void {
    switch (c) {
        .read => |r| allocator.free(r.argv),
        .run_mutation => |m| allocator.free(m.argv),
        .none => {},
    }
}

/// Kill the child so it cannot outlive the TUI; `kill` also reaps it (no zombie)
/// and closes its stdout, so no separate `wait` — a second reap would abort on the
/// already-cleared pid. The shared child-teardown step; callers own the buffer.
pub fn killAndReap(io: std.Io, f: *TabFetch) void {
    f.child.kill(io);
}

/// Tear an in-flight fetch down completely: reap the child and free its buffer.
/// The teardown path when the user quit before the audit finished.
pub fn reapTabFetch(io: std.Io, allocator: std.mem.Allocator, f: *TabFetch) void {
    killAndReap(io, f);
    f.buf.deinit(allocator);
}

/// Reap every in-flight fetch at teardown so none outlives the TUI or zombies.
pub fn reapAllFetches(io: std.Io, allocator: std.mem.Allocator, fetches: *Fetches) void {
    var it = fetches.iterator();
    while (it.next()) |e| if (e.value.*) |*f| reapTabFetch(io, allocator, f);
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
/// the mutation acts on exactly the rows the user saw. Reaches only the shared
/// read-model, never a tab's `Storage`.
pub fn quiesceFetches(io: std.Io, allocator: std.mem.Allocator, fetches: *Fetches, shared: *SharedModel) void {
    var it = fetches.iterator();
    while (it.next()) |e| if (e.value.*) |*f| {
        reapTabFetch(io, allocator, f); // kill + reap (closes the DB connection) + free the buffer
        e.value.* = null;
        shared.tab_loading.remove(e.key);
        shared.dirty.insert(e.key); // re-audit after the mutation, off the intact storage
    };
}

/// The interpreter's `.read{.background}` arm: spawn the read's child and register
/// the fetch carrying the `Cmd`'s parser/tag/tolerance/`fail_op`, so the loop drains
/// it and folds the result through `update` knowing no tab. A no-op when this tab's
/// audit is already in flight; a spawn fault is quiet — the tab stays unflagged so
/// the entry path can retry, never a launch-time nag banner. The argv is the pump's
/// to free (the child copies it on spawn), like every performed `Cmd`.
pub fn startBackground(io: std.Io, fetches: *Fetches, shared: *SharedModel, r: cmd.Cmd.Read) void {
    if (fetches.getPtr(r.tag).* != null) return; // already auditing this tab
    var child = std.process.spawn(io, .{ .argv = r.argv, .stdout = .pipe, .stderr = .ignore }) catch return;
    const out = child.stdout orelse {
        child.kill(io);
        _ = child.wait(io) catch {}; // best-effort reap of a pipe-less child; there is nothing to drain
        return;
    };
    shared.tab_loading.insert(r.tag);
    fetches.set(r.tag, .{ .tab = r.tag, .child = child, .fd = out.handle, .max_ok_exit = r.max_ok_exit, .parse = r.parse, .fail_op = r.fail_op });
}

/// A drained fetch's outcome, kept three-way so a *failed* audit (bad exit, read
/// fault) stays distinct from a *clean empty* one: empty clears the tab to a
/// known-zero state, failure keeps the last-good data behind a banner.
pub const FetchOutcome = union(enum) { bytes: []const u8, empty, failed: anyerror };

/// Turn a completed background drain into a `Msg` with the fetch's **carried**
/// parser — the same interpreter path a blocking read takes (`performRead`), so the
/// drain needs no tab. A bad exit / read fault / recoverable parse error sets the
/// recoverable banner from the fetch's `fail_op` and is `.failed` (the tab keeps its
/// last-good data); a clean empty read is `.cleared`; a parsed document is `.loaded`.
/// A parse-time OOM is *fatal*: the process is out of memory, so it propagates to the
/// terminal-restore-and-exit path exactly as a blocking read's parse OOM does, rather
/// than being masked as a recoverable refresh failure while allocation is broken. The
/// hub routes a returned `Msg` to the owning tab's `update`.
pub fn foldOutcome(allocator: std.mem.Allocator, shared: *SharedModel, parse: cmd.ParseFn, fail_op: []const u8, outcome: FetchOutcome) RunError!cmd.Msg {
    switch (outcome) {
        .failed => |err| {
            shared.banner.set(fail_op, @errorName(err));
            return .failed;
        },
        .empty => return .cleared,
        .bytes => |b| if (parse(allocator, b)) |parsed|
            return .{ .loaded = parsed }
        else |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory; // fatal, like performRead
            shared.banner.set(fail_op, @errorName(err));
            return .failed;
        },
    }
}

/// Perform one synchronous `Cmd`, returning the `Msg` to fold back. A recoverable
/// fault sets the banner from the `Cmd`'s `fail_op` and returns `.failed`/`.mutated`;
/// only a fatal (terminal/OOM) fault propagates. `.none` never reaches here, and a
/// background `.read` is enqueued by the pump (`startBackground`) before this.
pub fn perform(io: std.Io, allocator: std.mem.Allocator, t: *term.Term, painter: Painter, fetches: *Fetches, shared: *SharedModel, loading: *bool, c: cmd.Cmd) RunError!cmd.Msg {
    switch (c) {
        .none => unreachable, // the pump loops while `c != .none`, so it never performs it
        .read => |r| return performRead(io, allocator, painter, shared, loading, r),
        .run_mutation => |m| return performMutation(io, allocator, t, fetches, shared, m),
    }
}

/// Perform a `read`: paint the pre-read status, capture `mt … --json`, and parse it
/// with the `Cmd`'s carried parser. An `allow_empty` empty read is `.cleared`; a
/// recoverable read/parse fault banners and is `.failed`; a fatal fault propagates.
pub fn performRead(io: std.Io, allocator: std.mem.Allocator, painter: Painter, shared: *SharedModel, loading: *bool, r: cmd.Cmd.Read) RunError!cmd.Msg {
    // Paint before the blocking freeze so it reads as intentional (through the hub's
    // injected whole-dashboard repaint). A plain repaint, not `tick`: a blocking read
    // is a single frozen frame, so it must not advance the spinner animation. Search
    // shows its own "searching…" via `phase`; the others get the "Loading…" footer.
    const show_loading = r.tag != .search;
    if (show_loading) loading.* = true;
    painter.repaint();
    if (show_loading) loading.* = false;

    const bytes: ?[]u8 = readBytes(io, allocator, painter, loading, r) catch |err| switch (classify(err)) {
        .fatal => return err,
        .recoverable => {
            shared.banner.set(r.fail_op, @errorName(err));
            return .failed;
        },
    };
    const payload = bytes orelse return .cleared; // an exit-0 empty read
    defer allocator.free(payload);
    const parsed = r.parse(allocator, payload) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory; // fatal
        shared.banner.set(r.fail_op, @errorName(err));
        return .failed;
    };
    return .{ .loaded = parsed };
}

/// The read-mode dispatch over the phase-1 `spawn` readers. Blocking non-empty is
/// `readJson`; blocking empty-ok is `readJsonAllowEmpty`; polled is spinner-animated
/// via the painter. `background` never reaches here — the pump enqueues those through
/// `startBackground` before `perform` is called.
fn readBytes(io: std.Io, allocator: std.mem.Allocator, painter: Painter, loading: *bool, r: cmd.Cmd.Read) spawn.ReadError!?[]u8 {
    return switch (r.mode) {
        .blocking => if (r.allow_empty) spawn.readJsonAllowEmpty(io, allocator, r.argv) else @as(?[]u8, try spawn.readJson(io, allocator, r.argv)),
        .polled => blk: {
            // Keep `loading` set across the poll so each tick paints the footer spinner —
            // except search, which owns its own body "searching…" indicator (mirrors the
            // `r.tag != .search` gate `performRead` uses for the pre-read paint).
            const light = r.tag != .search;
            if (light) loading.* = true;
            defer if (light) {
                loading.* = false;
            };
            break :blk try spawn.readJsonPolled(io, allocator, r.argv, r.max_ok_exit, painter);
        },
        .background => unreachable,
    };
}

/// Perform a `run_mutation`: quiesce background audits (the WAL single-writer
/// invariant, keyed on this `.run_mutation` variant), re-exec `mt` inline, and return
/// the child's exit code as `.mutated` for the tab's `update` to judge. A spawn/
/// re-enter fault banners and is `.failed`; a terminal fault propagates.
pub fn performMutation(io: std.Io, allocator: std.mem.Allocator, t: *term.Term, fetches: *Fetches, shared: *SharedModel, m: cmd.Cmd.Mutation) RunError!cmd.Msg {
    // Sole-orchestrator invariant: a live `mt … --json` child holds the WAL writer,
    // so a mutating child spawned alongside it races and fails `Busy`. Quiesce first.
    if (anyFetchActive(fetches)) quiesceFetches(io, allocator, fetches, shared);
    const code = spawn.runInlineReenterStatus(t, m.argv) catch |err| switch (classify(err)) {
        .fatal => return err,
        .recoverable => {
            shared.banner.set(m.fail_op, @errorName(err));
            return .failed;
        },
    };
    return .{ .mutated = code };
}

// ─── tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "the interpreter imports no tab module and no json parser" {
    // The structural invariant AC2 pins: `perform` is domain-agnostic, so this
    // source must name neither a `*_tab.zig` nor a `json/*` parser. The type system
    // can't express it, so scan the source. The needles are split so this test's own
    // bytes never contain the contiguous marker it searches for.
    const src = @embedFile("perform.zig");
    try testing.expect(std.mem.indexOf(u8, src, "@import(\"" ++ "json/") == null);
    try testing.expect(std.mem.indexOf(u8, src, "_tab.zig" ++ "\")") == null);
}

test "classify splits recoverable backend faults from fatal terminal/OOM faults" {
    // Child-process + parse faults: survivable — show a banner, keep the session.
    try testing.expectEqual(ErrorClass.recoverable, classify(error.SpawnFailed));
    try testing.expectEqual(ErrorClass.recoverable, classify(error.WaitFailed));
    try testing.expectEqual(ErrorClass.recoverable, classify(error.ChildFailed));
    try testing.expectEqual(ErrorClass.recoverable, classify(error.EmptyOutput));
    try testing.expectEqual(ErrorClass.recoverable, classify(error.ReadFailed)); // child pipe
    try testing.expectEqual(ErrorClass.recoverable, classify(error.BadJson));
    // Terminal-integrity + OOM: fatal — restore and exit (the crash-safety guarantee).
    try testing.expectEqual(ErrorClass.fatal, classify(error.NotATty));
    try testing.expectEqual(ErrorClass.fatal, classify(error.WriteFailed));
    try testing.expectEqual(ErrorClass.fatal, classify(error.TermiosFailed));
    try testing.expectEqual(ErrorClass.fatal, classify(error.OutOfMemory));
}

// A `ParseFn` the fetch-lifecycle tests below never invoke — `anyFetchActive` only
// reads slot occupancy and `reapAllFetches` only kills children, so no parse runs.
fn unusedParse(_: std.mem.Allocator, _: []const u8) anyerror!cmd.Parsed {
    return error.Unused;
}

// Parsers that fail deterministically, to drive `foldOutcome`'s two error arms.
fn oomParse(_: std.mem.Allocator, _: []const u8) anyerror!cmd.Parsed {
    return error.OutOfMemory;
}
fn badJsonParse(_: std.mem.Allocator, _: []const u8) anyerror!cmd.Parsed {
    return error.BadJson;
}

test "foldOutcome propagates a parse OOM as fatal and sets no recoverable banner" {
    // Allocation failure during parse means the process is out of memory: it must
    // reach the terminal-restore-and-exit path (as a blocking read's parse OOM does),
    // not be masked as a recoverable refresh banner.
    var shared: SharedModel = .{};
    try testing.expectError(error.OutOfMemory, foldOutcome(testing.allocator, &shared, oomParse, "outdated refresh failed", .{ .bytes = "{}" }));
    try testing.expect(!shared.banner.isSet());
}

test "foldOutcome banners a non-OOM parse error as a recoverable .failed" {
    // A malformed document keeps the tab's last-good data behind the fail_op banner
    // and stays recoverable — only OOM escalates to fatal.
    var shared: SharedModel = .{};
    const msg = try foldOutcome(testing.allocator, &shared, badJsonParse, "outdated refresh failed", .{ .bytes = "garbage" });
    try testing.expect(msg == .failed);
    try testing.expectEqualStrings("outdated refresh failed: BadJson", shared.banner.slice());
}

test "foldOutcome maps a clean empty read to .cleared and a drain fault to .failed" {
    // The non-parse arms: an exit-0 empty payload clears to known-zero (no banner),
    // and a drain-side fault (bad exit / read error) banners and keeps last-good.
    var shared: SharedModel = .{};
    try testing.expect(try foldOutcome(testing.allocator, &shared, unusedParse, "x", .empty) == .cleared);
    try testing.expect(!shared.banner.isSet());
    try testing.expect(try foldOutcome(testing.allocator, &shared, unusedParse, "outdated refresh failed", .{ .failed = error.ChildFailed }) == .failed);
    try testing.expectEqualStrings("outdated refresh failed: ChildFailed", shared.banner.slice());
}

test "anyFetchActive tracks slot occupancy, not payload" {
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    var fetches: Fetches = .initFill(null);
    try testing.expect(!anyFetchActive(&fetches)); // an idle pool has zero wakeups

    const child = try std.process.spawn(t.io(), .{ .argv = &.{ "/bin/sleep", "30" }, .stdout = .pipe, .stderr = .ignore });
    fetches.set(.outdated, .{ .tab = .outdated, .child = child, .fd = child.stdout.?.handle, .max_ok_exit = 0, .parse = unusedParse, .fail_op = "x" });
    try testing.expect(anyFetchActive(&fetches)); // one in flight → the loop multiplexes

    reapTabFetch(t.io(), testing.allocator, &fetches.getPtr(.outdated).*.?); // reap the live child + free its buf
}

// Observe `loading` from inside a poll tick: the polled reader fires `on_tick` on
// every ≤80 ms timeout, so a child that outlives one timeout lets the test see
// whether the footer spinner flag was raised while the read was in flight.
const LoadWatch = struct {
    loading: *const bool,
    ticks: usize = 0,
    seen_true: bool = false,
    fn tick(ctx_ptr: *anyopaque) void {
        const self: *LoadWatch = @ptrCast(@alignCast(ctx_ptr)); // Painter's ctx round-trip, set from a *LoadWatch just below
        self.ticks += 1;
        if (self.loading.*) self.seen_true = true;
    }
};

test "a polled search read keeps the footer clean while any other tag lights it" {
    // Search owns its body "searching…" indicator, so the footer "Loading…" flag must
    // stay dark on the polled arm — every other polled read still raises it per tick.
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    var frame: []u8 = &.{};
    var loading = false;

    // `/bin/sleep` holds stdout open past one poll timeout (no output, exit 0), so a
    // tick fires mid-read and the read then resolves to an empty document (null).
    var search_watch: LoadWatch = .{ .loading = &loading };
    const search_painter: Painter = .{ .fd = 0, .frame = &frame, .on_tick = .{ .ctx = &search_watch, .call = LoadWatch.tick } };
    const search_read: cmd.Cmd.Read = .{ .argv = &.{ "/bin/sleep", "0.2" }, .mode = .polled, .parse = unusedParse, .tag = .search };
    try testing.expect((try readBytes(t.io(), testing.allocator, search_painter, &loading, search_read)) == null);
    try testing.expect(search_watch.ticks > 0); // the poll actually ticked mid-read
    try testing.expect(!search_watch.seen_true); // …and the footer stayed clean throughout
    try testing.expect(!loading); // false after the call

    var outdated_watch: LoadWatch = .{ .loading = &loading };
    const outdated_painter: Painter = .{ .fd = 0, .frame = &frame, .on_tick = .{ .ctx = &outdated_watch, .call = LoadWatch.tick } };
    const outdated_read: cmd.Cmd.Read = .{ .argv = &.{ "/bin/sleep", "0.2" }, .mode = .polled, .parse = unusedParse, .tag = .outdated };
    try testing.expect((try readBytes(t.io(), testing.allocator, outdated_painter, &loading, outdated_read)) == null);
    try testing.expect(outdated_watch.seen_true); // the footer spinner lit across the poll
    try testing.expect(!loading); // deferred back to false after the call
}

test "reapAllFetches tears down every in-flight fetch (no leak, no zombie)" {
    // The teardown path (`defer reapAllFetches` at exit): with two audits still
    // running, both children must be reaped and both buffers freed — the test
    // allocator trips on a leaked buffer, and a missed reap would leave a zombie.
    var t = std.Io.Threaded.init(testing.allocator, .{});
    defer t.deinit();
    var fetches: Fetches = .initFill(null);
    inline for ([_]tab_bar.Tab{ .outdated, .services }) |tag| {
        const child = try std.process.spawn(t.io(), .{ .argv = &.{ "/bin/sleep", "30" }, .stdout = .pipe, .stderr = .ignore });
        fetches.set(tag, .{ .tab = tag, .child = child, .fd = child.stdout.?.handle, .max_ok_exit = 0, .parse = unusedParse, .fail_op = "x" });
    }
    reapAllFetches(t.io(), testing.allocator, &fetches);
}
