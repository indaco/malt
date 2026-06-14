//! malt — integration tests for the themed TUI selection highlight.
//!
//! The selected-row highlight and the active-tab block emit the active theme's
//! `accent` immediately before reverse-video, so reverse-video paints the accent
//! as the highlight background. Under `.default` the highlight stays plain
//! reverse-video, leaving the out-of-box TUI unchanged. These pin the assembled
//! render bytes; the per-tier resolver is unit-tested inline in `ui/color.zig`.

const std = @import("std");
const testing = std.testing;

const malt = @import("malt");
const color = malt.color;
const tab = malt.tui_tab;
const installed = malt.tui_tab_installed;
const tab_bar = malt.tui_tab_bar;
const test_io = @import("test_io");

const reverse = "\x1b[7m";
// dracula accent — the same RGB the rest of the TUI paints under MALT_THEME=dracula.
const dracula_accent = "\x1b[38;2;189;147;249m";

const sample = [_]installed.Pkg{
    .{ .name = "brotli", .version = "1.2.0", .kind = .formula, .pinned = false, .size_bytes = 1902690, .linked = true },
    .{ .name = "curl", .version = "8.20.0", .kind = .formula, .pinned = true, .size_bytes = 4734154, .linked = false },
};

fn forceTheme(t: color.Theme) void {
    color.setThemeForTest(t);
    color.setTruecolorForTest(true);
    color.setBackgroundForTest(.unknown);
}

fn clearTheme() void {
    color.setThemeForTest(null);
    color.setTruecolorForTest(null);
    color.setBackgroundForTest(null);
}

test "a named theme paints the selected row's accent right before reverse-video" {
    forceTheme(.dracula);
    defer clearTheme();

    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var s: installed.State = .{ .items = &sample };
    s.chrome.view.selected = 1; // curl
    installed.render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 10 });

    // The accent SGR lands immediately before the reverse-video that backgrounds it.
    try testing.expect(std.mem.indexOf(u8, f.slice(), dracula_accent ++ reverse) != null);
}

test "the default theme keeps the selection plain reverse-video (no accent prefix)" {
    forceTheme(.default);
    defer clearTheme();

    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var s: installed.State = .{ .items = &sample };
    s.chrome.view.selected = 1;
    installed.render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 10 });

    try testing.expect(std.mem.indexOf(u8, f.slice(), reverse) != null); // still highlighted
    try testing.expect(std.mem.indexOf(u8, f.slice(), dracula_accent ++ reverse) == null); // but no accent bg
}

test "a named theme paints the active tab block's accent right before reverse-video" {
    forceTheme(.dracula);
    defer clearTheme();

    var buf: [256]u8 = undefined;
    const titles: [tab_bar.count][]const u8 = .{ "Search", "Installed", "Outdated", "Services", "Doctor" };
    const out = tab_bar.render(&buf, .outdated, titles, 80);

    try testing.expect(std.mem.indexOf(u8, out, dracula_accent ++ reverse) != null);
}

// Acceptance: all five tabs and the tab bar share the one reverse-video seam in
// `ui/color`, so no raw `\x1b[7m` literal is left under `src/tui/`.
test "no reverse-video literal remains under src/tui" {
    const io = std.Options.debug_io;
    var dir = try test_io.cwd().openDir(io, "src/tui", .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const file = try dir.openFile(io, entry.path, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        const content = try testing.allocator.alloc(u8, @intCast(stat.size));
        defer testing.allocator.free(content);
        _ = try file.readPositionalAll(io, content, 0);

        // The needle is the *source* spelling of the escape (a backslash, then
        // `x1b[7m`), not the rendered ESC byte the assertions above match.
        if (std.mem.indexOf(u8, content, "\\x1b[7m") != null) {
            std.debug.print("src/tui/{s} still contains a raw reverse-video literal\n", .{entry.path});
            return error.RawReverseLiteral;
        }
    }
}
