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

/// Drive `step` in place for a nav/editing test. These keys produce `Cmd.none`
/// (no heap argv), so the discarded `Cmd` owns nothing to free.
fn stepA(a: *app.App, key: Key) void {
    _ = app.step(testing.allocator, a.mt_path, a, key);
}

test "tab and digit keys switch the active tab" {
    var a: app.App = .{};
    stepA(&a, .tab);
    try testing.expectEqual(Tab.installed, a.active);
    stepA(&a, ch('4'));
    try testing.expectEqual(Tab.services, a.active);
    stepA(&a, ch('1'));
    try testing.expectEqual(Tab.search, a.active);
}

test "filter editing toggles edit mode and quit keys set quit" {
    var a: app.App = .{};
    stepA(&a, ch('/'));
    try testing.expect(a.editing);
    stepA(&a, .enter);
    try testing.expect(!a.editing);
    stepA(&a, ch('q'));
    try testing.expect(a.quit);
    var b: app.App = .{};
    stepA(&b, .ctrl_c);
    try testing.expect(b.quit);
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
    a.shared.banner.set("info for jq failed", "BadJson");
    var buf: [8192]u8 = undefined;
    const shown = app.renderFrame(&buf, &a, 80, 24);
    try testing.expect(std.mem.indexOf(u8, shown, "info for jq failed: BadJson") != null);

    stepA(&a, .down); // any key clears the transient banner
    try testing.expect(!a.shared.banner.isSet());
    const cleared = app.renderFrame(&buf, &a, 80, 24);
    try testing.expect(std.mem.indexOf(u8, cleared, "info for jq failed") == null);
    try testing.expect(std.mem.indexOf(u8, cleared, "quit") != null); // help line is back
}

test "the header bar paints name, version and prefix on row 1 above the tab bar" {
    var a: app.App = .{ .version = "0.1.0", .prefix = "/opt/malt" };
    var buf: [8192]u8 = undefined;
    const out = app.renderFrame(&buf, &a, 80, 24);
    const hdr = std.mem.indexOf(u8, out, "mt 0.1.0").?;
    try testing.expect(std.mem.indexOf(u8, out, "/opt/malt") != null);
    // Painted before the tab bar, which moves the cursor to row 2.
    try testing.expect(hdr < std.mem.indexOf(u8, out, "\x1b[2;1H").?);
}

test "header counts are an em-dash before their stores load, the numbers after" {
    var a: app.App = .{ .version = "0.1.0", .prefix = "/opt/malt" };
    var buf: [8192]u8 = undefined;
    const empty = app.renderFrame(&buf, &a, 120, 24);
    try testing.expect(std.mem.indexOf(u8, empty, "\xe2\x80\x94 kegs") != null); // em-dash
    try testing.expect(std.mem.indexOf(u8, empty, "\xe2\x80\x94 outdated") != null);

    a.shared.installed_count = 192;
    a.shared.outdated_count = 17;
    const loaded = app.renderFrame(&buf, &a, 120, 24);
    try testing.expect(std.mem.indexOf(u8, loaded, "192 kegs") != null);
    try testing.expect(std.mem.indexOf(u8, loaded, "17 outdated") != null);
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
