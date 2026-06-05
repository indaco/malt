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
