//! malt — end-to-end custom theme loading.
//!
//! Inline tests cover the pure pieces (path resolve, registry validation,
//! resolver gates). This file proves the boot wiring: a real file on disk, read
//! through the hardened `fs` path and installed into `ui/color`, recolours
//! *both* surfaces — a CLI line and a TUI frame — with no call-site change, and
//! a malformed file leaves the built-ins untouched.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");

const color = malt.color;
const output = malt.output;
const theme_file = malt.theme_file;
const tab_bar = malt.tui_tab_bar;

const base = "/tmp/malt_custom_theme_test";
const fixture = base ++ "/themes.json";
const dbg_io = std.Options.debug_io;

// Distinct truecolor values so the assertions cannot pass by coincidence.
const accent_sgr = "\x1b[38;2;189;147;249m"; // #bd93f9
const success_sgr = "\x1b[38;2;80;250;123m"; // #50fa7b

const valid_file =
    \\{"version":1,"default":"mine","themes":{
    \\  "mine":{"polarity":"dark",
    \\    "accent":"#bd93f9","secondary":"#8be9fd","success":"#50fa7b",
    \\    "warning":"#ffb86c","danger":"#ff5555","muted":"#6272a4"}
    \\}}
;

const titles: [tab_bar.count][]const u8 = .{ "Search", "Installed", "Outdated", "Services", "Doctor" };

fn cleanup() void {
    var tmp = std.Io.Dir.openDirAbsolute(dbg_io, "/tmp", .{}) catch return;
    defer tmp.close(dbg_io);
    tmp.deleteTree(dbg_io, "malt_custom_theme_test") catch {};
}

fn writeFixture(body: []const u8) !void {
    cleanup();
    try std.Io.Dir.createDirAbsolute(dbg_io, base, .default_dir);
    const f = try std.Io.Dir.createFileAbsolute(dbg_io, fixture, .{});
    defer f.close(dbg_io);
    try f.writeStreamingAll(dbg_io, body);
}

/// Seed environ (pointing MALT_THEMES_FILE at the fixture, MALT_THEME unset so
/// the file's `default` selects), force a truecolor tier, and boot-load the file
/// the way `main` does.
fn boot() color.InstallResult {
    const environ: std.process.Environ = .{ .block = .{ .slice = &[_:null]?[*:0]const u8{"MALT_THEMES_FILE=" ++ fixture} } };
    color.setRuntime(dbg_io, environ);
    color.setForTest(true, false); // colour on so CLI output emits SGR
    color.setTruecolorForTest(true);
    color.setBackgroundForTest(.unknown);

    var buf: [malt.custom_theme.max_file_bytes]u8 = undefined;
    const bytes = theme_file.read(dbg_io, environ, &buf);
    return color.installCustomThemes(testing.allocator, bytes);
}

fn reset() void {
    color.clearCustomForTest();
    color.setRuntime(dbg_io, .{ .block = .{ .slice = &[_:null]?[*:0]const u8{} } });
    color.setForTest(null, null);
    color.setTruecolorForTest(null);
    color.setBackgroundForTest(null);
    cleanup();
}

test "a valid themes file recolours both a CLI line and a TUI frame" {
    try writeFixture(valid_file);
    defer reset();
    try testing.expectEqual(color.InstallResult.loaded, boot());

    // TUI frame: the tab bar paints titles through color.roleCode(.accent).
    var fb: [256]u8 = undefined;
    const frame = tab_bar.render(&fb, .search, titles, 80);
    try testing.expect(std.mem.indexOf(u8, frame, accent_sgr) != null);

    // CLI line: a success line carries the custom success colour.
    var cap: std.ArrayList(u8) = .empty;
    defer cap.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &cap);
    output.success("installed", .{});
    output.endStderrCapture();
    try testing.expect(std.mem.indexOf(u8, cap.items, success_sgr) != null);
}

test "a malformed themes file leaves built-in output unchanged" {
    try writeFixture("{\"version\":1,\"themes\":{\"x\":{\"polarity\":\"dark\"}}}"); // missing roles
    defer reset();
    try testing.expectEqual(color.InstallResult.rejected, boot());

    // The TUI frame must carry the built-in default accent, not a custom one.
    const builtin_accent = color.resolveRole(.default, .accent, .unknown, true);
    var fb: [256]u8 = undefined;
    const frame = tab_bar.render(&fb, .search, titles, 80);
    try testing.expect(std.mem.indexOf(u8, frame, builtin_accent) != null);
    try testing.expect(std.mem.indexOf(u8, frame, accent_sgr) == null);
}
