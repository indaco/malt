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
const test_io = @import("test_io");

const color = malt.color;
const output = malt.output;
const theme_file = malt.theme_file;
const tab_bar = malt.tui_tab_bar;

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

/// Themes file under a process-unique base, so overlapping test runs cannot
/// wipe each other's fixtures. Owns the environ block that points at it.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    base: [:0]const u8,
    file: [:0]const u8,
    environ: std.process.Environ,

    fn init(tag: []const u8) !Fixture {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const unique = try test_io.uniqueTempPath(a, "custom_theme", tag);
        const base = try a.dupeZ(u8, unique);
        test_io.deleteTreeAbsolute(dbg_io, base) catch {};
        try std.Io.Dir.createDirAbsolute(dbg_io, base, .default_dir);
        const file = try std.fmt.allocPrintSentinel(a, "{s}/themes.json", .{base}, 0);
        const kv = try std.fmt.allocPrintSentinel(a, "MALT_THEMES_FILE={s}", .{file}, 0);
        const block = try a.allocSentinel(?[*:0]const u8, 1, null);
        block[0] = kv.ptr;
        return .{
            .arena = arena,
            .base = base,
            .file = file,
            .environ = .{ .block = .{ .slice = block } },
        };
    }

    fn write(self: *Fixture, body: []const u8) !void {
        const f = try std.Io.Dir.createFileAbsolute(dbg_io, self.file, .{});
        defer f.close(dbg_io);
        try f.writeStreamingAll(dbg_io, body);
    }

    fn deinit(self: *Fixture) void {
        test_io.deleteTreeAbsolute(dbg_io, self.base) catch {};
        self.arena.deinit();
    }
};

/// Seed environ (pointing MALT_THEMES_FILE at the fixture, MALT_THEME unset so
/// the file's `default` selects), force a truecolor tier, and boot-load the file
/// the way `main` does.
fn boot(fx: *Fixture) color.InstallResult {
    const environ = fx.environ;
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
}

test "a valid themes file recolours both a CLI line and a TUI frame" {
    var fx = try Fixture.init("valid");
    defer fx.deinit();
    try fx.write(valid_file);
    defer reset();
    try testing.expectEqual(color.InstallResult.loaded, boot(&fx));

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
    var fx = try Fixture.init("malformed");
    defer fx.deinit();
    try fx.write("{\"version\":1,\"themes\":{\"x\":{\"polarity\":\"dark\"}}}"); // missing roles
    defer reset();
    try testing.expectEqual(color.InstallResult.rejected, boot(&fx));

    // The TUI frame must carry the built-in default accent, not a custom one.
    const builtin_accent = color.resolveRole(.default, .accent, .unknown, true);
    var fb: [256]u8 = undefined;
    const frame = tab_bar.render(&fb, .search, titles, 80);
    try testing.expect(std.mem.indexOf(u8, frame, builtin_accent) != null);
    try testing.expect(std.mem.indexOf(u8, frame, accent_sgr) == null);
}
