//! malt — integration tests for the `mt tui` app shell.
//!
//! Drives the public surface (`malt.tui_app`) the inline unit tests reach
//! privately: tab/filter state transitions, the pure resize re-render, the
//! non-interactive launch refusal, and that `tui` is wired into help and all
//! three completion shells. The live PTY launch + resize proof lands later.

const std = @import("std");
const testing = std.testing;

const app = @import("malt").tui_app;
const Tab = @import("malt").tui_tab_bar.Tab;
const Key = @import("malt").tui_keys.Key;
const term = @import("malt").tui_term;
const help = @import("malt").cli_help;
const completions = @import("malt").completions;

fn ch(c: u8) Key {
    return .{ .char = .{ .bytes = .{ c, 0, 0, 0 }, .len = 1 } };
}

test "tab and digit keys switch the active tab" {
    var a: app.App = .{};
    a = app.step(a, .tab);
    try testing.expectEqual(Tab.installed, a.active);
    a = app.step(a, ch('4'));
    try testing.expectEqual(Tab.services, a.active);
    a = app.step(a, ch('1'));
    try testing.expectEqual(Tab.search, a.active);
}

test "filter editing toggles edit mode and quit keys set quit" {
    var a: app.App = .{};
    a = app.step(a, ch('/'));
    try testing.expect(a.editing);
    a = app.step(a, .enter);
    try testing.expect(!a.editing);
    try testing.expect(app.step(a, ch('q')).quit);
    try testing.expect(app.step(a, .ctrl_c).quit);
}

test "renderFrame is a pure function of size — a resize re-renders from cached state" {
    var a: app.App = .{};
    var b1: [8192]u8 = undefined;
    var b2: [8192]u8 = undefined;
    const before = app.renderFrame(&b1, &a, 80, 24);
    const after = app.renderFrame(&b2, &a, 100, 40);
    // No key was fed; the same state reflows to a different frame on resize.
    try testing.expect(!std.mem.eql(u8, before, after));
    try testing.expect(std.mem.indexOfScalar(u8, after, '\n') == null);
}

test "the SIGWINCH resized flag is consumed exactly once" {
    const prior = term.takeResized(); // clear any residue
    _ = prior;
    term.setResizedForTest(true);
    try testing.expect(term.takeResized());
    try testing.expect(!term.takeResized()); // a second read sees nothing
}

test "classify keeps backend faults recoverable and terminal/OOM faults fatal" {
    // The whole point of the surface: a flaky child or bad JSON must not exit.
    try testing.expectEqual(app.ErrorClass.recoverable, app.classify(error.ChildFailed));
    try testing.expectEqual(app.ErrorClass.recoverable, app.classify(error.BadJson));
    try testing.expectEqual(app.ErrorClass.recoverable, app.classify(error.SpawnFailed));
    // Terminal integrity / OOM still tears down cleanly — the TUI-012 guarantee.
    try testing.expectEqual(app.ErrorClass.fatal, app.classify(error.WriteFailed));
    try testing.expectEqual(app.ErrorClass.fatal, app.classify(error.OutOfMemory));
}

test "a recoverable banner is painted in the footer and a keypress dismisses it" {
    var a: app.App = .{};
    a.banner.set("info for jq failed", "BadJson");
    var buf: [8192]u8 = undefined;
    const shown = app.renderFrame(&buf, &a, 80, 24);
    try testing.expect(std.mem.indexOf(u8, shown, "info for jq failed: BadJson") != null);

    a = app.step(a, .down); // any key clears the transient banner
    try testing.expect(!a.banner.isSet());
    const cleared = app.renderFrame(&buf, &a, 80, 24);
    try testing.expect(std.mem.indexOf(u8, cleared, "info for jq failed") == null);
    try testing.expect(std.mem.indexOf(u8, cleared, "quit") != null); // help line is back
}

test "refusalReason refuses a non-interactive terminal and allows a clean tty" {
    try testing.expectEqual(@as(?app.Refusal, .not_a_tty), app.refusalReason(false, true, false, false));
    try testing.expectEqual(@as(?app.Refusal, .no_color), app.refusalReason(true, true, true, false));
    try testing.expectEqual(@as(?app.Refusal, .ci), app.refusalReason(true, true, false, true));
    try testing.expect(app.refusalReason(true, true, false, false) == null);
}

test "tui is listed in help and in all three completion shells" {
    try testing.expect(!std.mem.eql(u8, help.helpFor("tui"), "No help available.\n"));
    try testing.expect(std.mem.indexOf(u8, help.helpFor("tui"), "dashboard") != null);

    try testing.expect(std.mem.indexOf(u8, completions.scriptFor(.bash), " tui ") != null);
    try testing.expect(std.mem.indexOf(u8, completions.scriptFor(.zsh), "'tui:") != null);
    try testing.expect(std.mem.indexOf(u8, completions.scriptFor(.fish), "-a tui") != null);
}
