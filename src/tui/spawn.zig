//! malt — `mt tui` process delegation: re-exec the real `mt` for every mutation.
//!
//! Leaf module (imports only `std` + the sibling `term.zig`). Implements the
//! delegation principle: the TUI never reimplements a mutation. `runInline`
//! drops the alt-screen + raw mode, re-execs `mt <subcommand>` inheriting the
//! parent's stdio so its progress bars and typed-confirm prompts land in the
//! user's scrollback exactly as on the CLI, waits, then re-enters — every fault
//! path restoring the terminal via `errdefer` so a failed child can never wedge
//! it. `readJson` is the read side: capture `mt … --json` stdout for the tab
//! parsers. argv[0] is the resolved self-exe path injected from the `main.zig`
//! bridge, so the child is the *same* `mt`, not whatever PATH resolves.

const std = @import("std");
const term = @import("term.zig");

pub const SpawnError = error{ SpawnFailed, WaitFailed, ChildFailed };
pub const ReadError = SpawnError || error{ EmptyOutput, ReadFailed, OutOfMemory };
pub const InlineError = term.TermError || SpawnError;

/// Per-read cap on captured `--json` bytes. Sized for the largest read shape
/// (`mt list --json` over a full Cellar) with headroom.
const max_json_bytes: usize = 4 * 1024 * 1024;

/// Build `[mt, rest...]` — the argv for a delegated mutation (`mt <sub> [args]`).
/// `rest` is `subcommand` followed by its arguments. Strings are borrowed from
/// the caller; only the returned slice is owned (free it, not its elements).
pub fn inlineArgv(
    allocator: std.mem.Allocator,
    mt_path: []const u8,
    rest: []const []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    const argv = try allocator.alloc([]const u8, 1 + rest.len);
    argv[0] = mt_path;
    @memcpy(argv[1..], rest);
    return argv;
}

/// Build `[mt, rest..., "--json"]` — the read shape the tab parsers consume.
/// Same ownership contract as `inlineArgv`.
pub fn jsonArgv(
    allocator: std.mem.Allocator,
    mt_path: []const u8,
    rest: []const []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    const argv = try allocator.alloc([]const u8, 2 + rest.len);
    argv[0] = mt_path;
    @memcpy(argv[1 .. 1 + rest.len], rest);
    argv[argv.len - 1] = "--json";
    return argv;
}

/// Spawn `argv` inheriting the parent's stdio (so the child's prompts and
/// progress reach the user's scrollback) and map its exit to an error. A
/// non-zero exit, signal, or stop surfaces as `ChildFailed` — never swallowed.
pub fn runChild(io: std.Io, argv: []const []const u8) SpawnError!void {
    var child = std.process.spawn(io, .{ .argv = argv }) catch return error.SpawnFailed;
    const status = child.wait(io) catch return error.WaitFailed;
    switch (status) {
        .exited => |code| if (code != 0) return error.ChildFailed,
        .signal, .stopped, .unknown => return error.ChildFailed,
    }
}

/// Spawn `argv`, drain its stdout fully, then wait. Returns the captured bytes
/// (possibly empty) on an accepted exit. `max_ok_exit` is the highest exit code
/// that still counts as a successful read: most reads pass `0`, but `mt doctor`
/// passes `2` because its exit code is its severity, not a failure. A signal,
/// stop, or a code above `max_ok_exit` is `ChildFailed`. Caller frees the bytes.
fn captureJson(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    max_ok_exit: u8,
) ReadError![]u8 {
    // Discard the child's stderr: inside the alt-screen its status/progress lines
    // (e.g. `mt doctor`'s check log) would paint over the frame. A real failure is
    // surfaced by the caller's banner, not by leaking child stderr onto the TUI.
    var child = std.process.spawn(io, .{ .argv = argv, .stdout = .pipe, .stderr = .ignore }) catch return error.SpawnFailed;

    const bytes = drainStdout(io, allocator, child.stdout) catch |e| {
        // Kill so `wait` can't hang on a half-drained pipe, then surface.
        child.kill(io);
        return e;
    };
    errdefer allocator.free(bytes);

    const status = child.wait(io) catch return error.WaitFailed;
    switch (status) {
        .exited => |code| if (code > max_ok_exit) return error.ChildFailed,
        .signal, .stopped, .unknown => return error.ChildFailed,
    }
    return bytes;
}

/// Capture `mt … --json` stdout for a tab parser. stderr stays inherited so a
/// genuine failure is still visible. Errors on a non-zero exit or empty output
/// so a parser never sees a half-written document. Caller frees the bytes.
pub fn readJson(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) ReadError![]u8 {
    const bytes = try captureJson(io, allocator, argv, 0);
    errdefer allocator.free(bytes);
    if (bytes.len == 0) return error.EmptyOutput; // a parser must never see half a doc
    return bytes;
}

/// Capture `mt doctor --json`, whose exit code is its severity (0 ok / 1 warn /
/// 2 err), not a pass/fail — so a non-zero severity with a document is a
/// successful read, never `ChildFailed`. An exit-with-no-output (a fresh prefix)
/// maps to `null` like `readJsonAllowEmpty`. Caller frees the bytes.
pub fn readDoctorJson(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) ReadError!?[]u8 {
    const bytes = try captureJson(io, allocator, argv, 2);
    if (bytes.len == 0) {
        allocator.free(bytes);
        return null;
    }
    return bytes;
}

/// Like `readJson`, but an exit-0 response with no output — what every
/// `mt … --json` read emits against a fresh prefix (no db yet) — is `null`
/// rather than `error.EmptyOutput`. A genuine fault still surfaces as
/// `ChildFailed`/`ReadFailed`, so a caller renders an empty tab only when the
/// command truly succeeded with nothing to show. Caller frees the bytes.
pub fn readJsonAllowEmpty(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) ReadError!?[]u8 {
    return readJson(io, allocator, argv) catch |e| switch (e) {
        error.EmptyOutput => null,
        else => |err| err,
    };
}

/// Drain the child's stdout pipe fully before `wait`, bounded by
/// `max_json_bytes`. Mirrors `core/child.zig`'s drain; stdout-only because the
/// read commands keep stderr inherited.
fn drainStdout(io: std.Io, allocator: std.mem.Allocator, pipe: ?std.Io.File) ReadError![]u8 {
    const file = pipe orelse return error.ReadFailed;
    var read_buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buf);
    return reader.interface.allocRemaining(allocator, std.Io.Limit.limited(max_json_bytes)) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ReadFailed,
    };
}

/// Drop the dashboard, run `body`, re-enter. Generic over the controller and
/// the body so the leave → run → re-enter order — and that every error path
/// restores the terminal via `errdefer` — is provable with a fake (no PTY, no
/// runtime vtable; the production instantiation monomorphizes to one).
fn around(ctrl: anytype, body: anytype) !void {
    ctrl.leave(); // hand the terminal to the child
    errdefer ctrl.leave(); // a child or re-enter fault still leaves it restored
    try body.run();
    try ctrl.enter(); // back to the dashboard
}

/// Live controller over a `term.Term`: leave drops everything entered, enter
/// re-establishes raw + alt-screen + hidden cursor in the same order `run` does.
const TermCtrl = struct {
    t: *term.Term,
    fn leave(self: TermCtrl) void {
        self.t.restore();
    }
    fn enter(self: TermCtrl) term.TermError!void {
        try self.t.enterRaw();
        try self.t.enterAltScreen();
        try self.t.hideCursor();
    }
};

/// The mutation body: re-exec `mt` inheriting stdio.
const ChildBody = struct {
    io: std.Io,
    argv: []const []const u8,
    fn run(self: ChildBody) SpawnError!void {
        return runChild(self.io, self.argv);
    }
};

/// Run a delegated mutation inline: leave the alt-screen, re-exec `mt`, wait,
/// re-enter. On any fault the terminal is restored before the error propagates.
pub fn runInline(t: *term.Term, argv: []const []const u8) InlineError!void {
    return around(TermCtrl{ .t = t }, ChildBody{ .io = t.io, .argv = argv });
}

/// Like `around`, but a *child* failure re-enters the dashboard and surfaces the
/// non-zero exit as a value — the graceful (recoverable) inline path. Only a
/// terminal re-enter fault is fatal; then the terminal is left restored. The
/// child outcome is captured (not thrown) so re-entry happens regardless, then
/// returned, so a failed mutation lands the user back in the dashboard with
/// `mt`'s real output already in their scrollback.
fn aroundReenter(ctrl: anytype, body: anytype) !void {
    ctrl.leave(); // hand the terminal to the child
    const child = body.run(); // capture: the child's failure is data, not a throw
    ctrl.enter() catch |e| {
        ctrl.leave(); // a real terminal fault is fatal — leave it restored
        return e;
    };
    return child; // back in the dashboard; surface a non-zero child exit as a value
}

/// Run a delegated mutation inline on the graceful path: a non-zero child exit
/// re-enters the dashboard and is returned as a recoverable value.
pub fn runInlineReenter(t: *term.Term, argv: []const []const u8) InlineError!void {
    return aroundReenter(TermCtrl{ .t = t }, ChildBody{ .io = t.io, .argv = argv });
}

// ─── tests ───────────────────────────────────────────────────────────

const testing = std.testing;

fn threaded() std.Io.Threaded {
    return .init(testing.allocator, .{});
}

test "inlineArgv re-execs the resolved mt with the subcommand and its args" {
    const argv = try inlineArgv(testing.allocator, "/opt/homebrew/bin/mt", &.{ "upgrade", "ripgrep" });
    defer testing.allocator.free(argv);
    try testing.expectEqual(@as(usize, 3), argv.len);
    try testing.expectEqualStrings("/opt/homebrew/bin/mt", argv[0]); // the same mt, not PATH's
    try testing.expectEqualStrings("upgrade", argv[1]);
    try testing.expectEqualStrings("ripgrep", argv[2]);
}

test "jsonArgv appends --json after the command for the parsers" {
    const argv = try jsonArgv(testing.allocator, "/opt/homebrew/bin/mt", &.{"list"});
    defer testing.allocator.free(argv);
    try testing.expectEqual(@as(usize, 3), argv.len);
    try testing.expectEqualStrings("/opt/homebrew/bin/mt", argv[0]);
    try testing.expectEqualStrings("list", argv[1]);
    try testing.expectEqualStrings("--json", argv[2]);
}

test "argv builders hold at the empty-args boundary" {
    const a = try inlineArgv(testing.allocator, "/bin/mt", &.{});
    defer testing.allocator.free(a);
    try testing.expectEqual(@as(usize, 1), a.len);
    try testing.expectEqualStrings("/bin/mt", a[0]);

    const j = try jsonArgv(testing.allocator, "/bin/mt", &.{});
    defer testing.allocator.free(j);
    try testing.expectEqual(@as(usize, 2), j.len);
    try testing.expectEqualStrings("/bin/mt", j[0]);
    try testing.expectEqualStrings("--json", j[1]);
}

test "runChild returns void on a zero exit" {
    var t = threaded();
    defer t.deinit();
    try runChild(t.io(), &.{"/usr/bin/true"});
}

test "runChild surfaces a non-zero exit as ChildFailed, not swallowed" {
    var t = threaded();
    defer t.deinit();
    try testing.expectError(error.ChildFailed, runChild(t.io(), &.{"/usr/bin/false"}));
}

test "runChild surfaces a missing program as SpawnFailed" {
    var t = threaded();
    defer t.deinit();
    try testing.expectError(error.SpawnFailed, runChild(t.io(), &.{"/nonexistent/malt_tui_spawn_probe"}));
}

test "readJson captures the child's stdout for the parser" {
    var t = threaded();
    defer t.deinit();
    const out = try readJson(t.io(), testing.allocator, &.{ "/bin/echo", "hello-json" });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "hello-json") != null);
}

test "readJson errors on an empty document so a parser never sees half a doc" {
    var t = threaded();
    defer t.deinit();
    try testing.expectError(error.EmptyOutput, readJson(t.io(), testing.allocator, &.{"/usr/bin/true"}));
}

test "readJson errors on a non-zero exit" {
    var t = threaded();
    defer t.deinit();
    try testing.expectError(error.ChildFailed, readJson(t.io(), testing.allocator, &.{"/usr/bin/false"}));
}

test "readDoctorJson tolerates a severity exit where readJson would fail it" {
    var t = threaded();
    defer t.deinit();
    // `/usr/bin/false` exits 1 — a doctor "warnings" severity, not a fault — so
    // the doctor read keeps going where the generic read returns ChildFailed.
    // (A non-zero exit *with* a document is exercised in tests/tui_spawn_test.zig,
    // which may use a shell fixture the src/ argv-only invariant forbids here.)
    try testing.expect((try readDoctorJson(t.io(), testing.allocator, &.{"/usr/bin/false"})) == null);
    try testing.expectError(error.ChildFailed, readJson(t.io(), testing.allocator, &.{"/usr/bin/false"}));
}

test "readDoctorJson returns the captured document on a successful read" {
    var t = threaded();
    defer t.deinit();
    const out = (try readDoctorJson(t.io(), testing.allocator, &.{ "/bin/echo", "{\"checks\":[]}" })).?;
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "checks") != null);
}

test "readDoctorJson maps an exit-with-no-output to null (fresh prefix)" {
    var t = threaded();
    defer t.deinit();
    try testing.expect((try readDoctorJson(t.io(), testing.allocator, &.{"/usr/bin/true"})) == null);
}

test "readDoctorJson surfaces a missing program as SpawnFailed" {
    var t = threaded();
    defer t.deinit();
    try testing.expectError(error.SpawnFailed, readDoctorJson(t.io(), testing.allocator, &.{"/nonexistent/malt_doctor_probe"}));
}

// A fake terminal controller + body record the call order so the sequencing
// and errdefer-restore contract are provable without a PTY.
const FakeTerm = struct {
    entered: bool = true, // starts in the dashboard
    enter_fails: bool = false,
    log: *std.ArrayList(u8),
    fn leave(self: *FakeTerm) void {
        self.entered = false;
        self.log.append(testing.allocator, 'L') catch {};
    }
    fn enter(self: *FakeTerm) error{Reenter}!void {
        self.log.append(testing.allocator, 'E') catch {};
        if (self.enter_fails) return error.Reenter;
        self.entered = true;
    }
};

const FakeBody = struct {
    fails: bool,
    log: *std.ArrayList(u8),
    fn run(self: FakeBody) error{Spawn}!void {
        self.log.append(testing.allocator, 'S') catch {};
        if (self.fails) return error.Spawn;
    }
};

test "runInline order: leave → spawn → re-enter, ending in the dashboard" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);
    var ft: FakeTerm = .{ .log = &log };
    try around(&ft, FakeBody{ .fails = false, .log = &log });
    try testing.expectEqualStrings("LSE", log.items);
    try testing.expect(ft.entered);
}

test "a child failure restores the terminal and surfaces the error" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);
    var ft: FakeTerm = .{ .log = &log };
    try testing.expectError(error.Spawn, around(&ft, FakeBody{ .fails = true, .log = &log }));
    try testing.expectEqualStrings("LSL", log.items); // leave, spawn(fail), errdefer leave
    try testing.expect(!ft.entered);
}

test "a re-enter fault still restores the terminal" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);
    var ft: FakeTerm = .{ .log = &log, .enter_fails = true };
    try testing.expectError(error.Reenter, around(&ft, FakeBody{ .fails = false, .log = &log }));
    try testing.expectEqualStrings("LSEL", log.items); // leave, spawn, enter(fail), errdefer leave
    try testing.expect(!ft.entered);
}

// The graceful inline path: unlike `around`, a child failure re-enters the
// dashboard and hands the failure back as a value, so a recoverable mutation
// fault never tears the session down — only a terminal fault does.

test "aroundReenter re-enters the dashboard on a child failure and surfaces it" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);
    var ft: FakeTerm = .{ .log = &log };
    try testing.expectError(error.Spawn, aroundReenter(&ft, FakeBody{ .fails = true, .log = &log }));
    try testing.expectEqualStrings("LSE", log.items); // leave, spawn(fail), re-enter — no trailing leave
    try testing.expect(ft.entered); // ends IN the dashboard, unlike `around`
}

test "aroundReenter ends in the dashboard on a successful mutation" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);
    var ft: FakeTerm = .{ .log = &log };
    try aroundReenter(&ft, FakeBody{ .fails = false, .log = &log });
    try testing.expectEqualStrings("LSE", log.items);
    try testing.expect(ft.entered);
}

test "aroundReenter treats a re-enter fault as fatal and restores the terminal" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);
    var ft: FakeTerm = .{ .log = &log, .enter_fails = true };
    try testing.expectError(error.Reenter, aroundReenter(&ft, FakeBody{ .fails = false, .log = &log }));
    try testing.expectEqualStrings("LSEL", log.items); // leave, spawn, enter(fail), leave
    try testing.expect(!ft.entered);
}
