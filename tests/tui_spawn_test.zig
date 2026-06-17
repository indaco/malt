//! malt — integration tests for `mt tui` process delegation + refresh policy.
//!
//! Drives the public surface (`malt.tui_spawn`, `malt.tui_app`): the argv
//! shapes that re-exec the same `mt`, the `--json` read capture and its error
//! gates, and the lazy per-tab refresh hook. The live spawn round-trip (drop
//! alt-screen → run → re-enter on a real PTY) is deferred to the TUI-016 e2e.

const std = @import("std");
const testing = std.testing;

const spawn = @import("malt").tui_spawn;
const app = @import("malt").tui_app;
const Tab = @import("malt").tui_tab_bar.Tab;

fn threaded() std.Io.Threaded {
    return .init(testing.allocator, .{});
}

test "inlineArgv re-execs the injected mt with the subcommand and its args" {
    const argv = try spawn.inlineArgv(testing.allocator, "/usr/local/bin/mt", &.{ "uninstall", "wget" });
    defer testing.allocator.free(argv);
    try testing.expectEqual(@as(usize, 3), argv.len);
    try testing.expectEqualStrings("/usr/local/bin/mt", argv[0]);
    try testing.expectEqualStrings("uninstall", argv[1]);
    try testing.expectEqualStrings("wget", argv[2]);
}

test "jsonArgv builds mt <cmd> --json for the tab parsers" {
    const argv = try spawn.jsonArgv(testing.allocator, "/usr/local/bin/mt", &.{"outdated"});
    defer testing.allocator.free(argv);
    try testing.expectEqual(@as(usize, 3), argv.len);
    try testing.expectEqualStrings("/usr/local/bin/mt", argv[0]);
    try testing.expectEqualStrings("outdated", argv[1]);
    try testing.expectEqualStrings("--json", argv[2]);
}

test "readJson captures stdout and errors on empty or non-zero output" {
    var t = threaded();
    defer t.deinit();
    const out = try spawn.readJson(t.io(), testing.allocator, &.{ "/bin/echo", "{\"ok\":true}" });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"ok\":true") != null);

    try testing.expectError(error.EmptyOutput, spawn.readJson(t.io(), testing.allocator, &.{"/usr/bin/true"}));
    try testing.expectError(error.ChildFailed, spawn.readJson(t.io(), testing.allocator, &.{"/usr/bin/false"}));
}

test "runChild surfaces a non-zero exit instead of swallowing it" {
    var t = threaded();
    defer t.deinit();
    try spawn.runChild(t.io(), &.{"/usr/bin/true"});
    try testing.expectError(error.ChildFailed, spawn.runChild(t.io(), &.{"/usr/bin/false"}));
}

// `runChildTolerant` is the mutation-side mirror of the doctor read's
// `max_ok_exit`: `mt doctor --fix` exits by severity (≤ 2) even on a clean
// sweep, so the inline runner must accept that yet still reject a genuine fault
// above the cap. The exit-above-cap case needs a non-zero exit from a known
// program, which only a shell fixture gives; the `src/` argv-only invariant
// keeps it here rather than inline.

test "runChildTolerant accepts a severity exit at the cap" {
    var t = threaded();
    defer t.deinit();
    try spawn.runChildTolerant(t.io(), &.{ "/bin/sh", "-c", "exit 2" }, 2);
}

test "runChildTolerant rejects an exit above the cap as ChildFailed" {
    var t = threaded();
    defer t.deinit();
    // Only 0/1/2 are doctor severities; a higher code is a genuine fault.
    try testing.expectError(error.ChildFailed, spawn.runChildTolerant(t.io(), &.{ "/bin/sh", "-c", "exit 3" }, 2));
}

test "runChildTolerant treats a signalled child as ChildFailed regardless of the cap" {
    var t = threaded();
    defer t.deinit();
    // A signal is a crash, not a severity — tolerance must never mask it, or a
    // doctor that segfaults mid-fix would read as a clean sweep.
    try testing.expectError(error.ChildFailed, spawn.runChildTolerant(t.io(), &.{ "/bin/sh", "-c", "kill -TERM $$" }, 2));
}

test "the refresh hook refetches the active tab and marks the rest dirty on view" {
    var a: app.App = .{ .active = .services };
    app.markStaleAfterMutation(&a);
    // The tab the user just acted on is refreshed inline, so it stays fresh.
    try testing.expect(!app.takeDirty(&a, .services));
    // Every other tab refetches once when entered, then is fresh again.
    try testing.expect(app.takeDirty(&a, .installed));
    try testing.expect(!app.takeDirty(&a, .installed));
    try testing.expect(app.takeDirty(&a, .doctor));
}

// `mt doctor --json` exits non-zero *by severity* (1 warn / 2 err) while still
// emitting its findings document — so the Doctor tab must read it as success,
// not ChildFailed. These need a process that exits non-zero with output, which
// only a shell fixture produces; the `src/` argv-only invariant forbids naming a
// shell there, so the with-output cases live here.

test "readDoctorJson keeps the document emitted alongside a severity exit (2)" {
    var t = threaded();
    defer t.deinit();
    const out = (try spawn.readDoctorJson(t.io(), testing.allocator, &.{
        "/bin/sh", "-c", "printf '{\"checks\":[]}'; exit 2",
    })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"checks\":[]}", out);
}

test "readDoctorJson still rejects an exit above the severity range" {
    var t = threaded();
    defer t.deinit();
    // Only 0/1/2 are doctor severities; a higher code is a genuine fault.
    try testing.expectError(error.ChildFailed, spawn.readDoctorJson(t.io(), testing.allocator, &.{
        "/bin/sh", "-c", "printf x; exit 3",
    }));
}

// A counting ticker stands in for the app's spinner-advancing closure: the
// polled read must invoke `tick()` while the child is still running so the
// dashboard can animate the spinner instead of freezing on one frame.
const CountTicker = struct {
    n: *usize,
    pub fn tick(self: CountTicker) void {
        self.n.* += 1;
    }
};

test "readJsonPolled ticks while a slow child runs and returns the same bytes a blocking read would" {
    var t = threaded();
    defer t.deinit();
    var ticks: usize = 0;
    // A child that outlives one poll timeout: the read must tick at least once
    // before its output arrives, proving the spinner animates mid-load.
    const out = (try spawn.readJsonPolled(t.io(), testing.allocator, &.{
        "/bin/sh", "-c", "sleep 0.25; printf '{\"ok\":true}'",
    }, 0, CountTicker{ .n = &ticks })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"ok\":true}", out);
    try testing.expect(ticks >= 1);
}

test "readJsonPolled maps an exit-0 empty response to null (fresh prefix), no tick needed" {
    var t = threaded();
    defer t.deinit();
    var ticks: usize = 0;
    try testing.expect((try spawn.readJsonPolled(t.io(), testing.allocator, &.{"/usr/bin/true"}, 0, CountTicker{ .n = &ticks })) == null);
}

test "readJsonPolled honours max_ok_exit like the doctor read (severity exit 2 with a document)" {
    var t = threaded();
    defer t.deinit();
    var ticks: usize = 0;
    const out = (try spawn.readJsonPolled(t.io(), testing.allocator, &.{
        "/bin/sh", "-c", "printf '{\"checks\":[]}'; exit 2",
    }, 2, CountTicker{ .n = &ticks })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"checks\":[]}", out);
}

test "readJsonPolled surfaces a non-zero exit above the cap as ChildFailed" {
    var t = threaded();
    defer t.deinit();
    var ticks: usize = 0;
    try testing.expectError(error.ChildFailed, spawn.readJsonPolled(t.io(), testing.allocator, &.{"/usr/bin/false"}, 0, CountTicker{ .n = &ticks }));
}
