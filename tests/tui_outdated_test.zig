//! malt — integration tests for the `mt tui` Outdated tab.
//!
//! Inline tests in the leaf modules cover the parse/render/step shapes against
//! literal bytes; this file pins the assembled path against a **recorded**
//! `mt outdated --json` fixture (`scripts/fixtures/`), never live `mt` — proving
//! the parser consumes the real unified schema and that the multi-select state
//! maps to the exact `mt upgrade <names...>` argument list, with pinned rows
//! always held back.

const std = @import("std");
const testing = std.testing;

const malt = @import("malt");
const outdated_json = malt.tui_json_outdated;
const outdated = malt.tui_tab_outdated;
const test_io = @import("test_io");

fn readFixture(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const io = std.Options.debug_io;
    var dir = try test_io.cwd().openDir(io, "scripts/fixtures", .{});
    defer dir.close(io);
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(buf);
    _ = try file.readPositionalAll(io, buf, 0);
    return buf;
}

test "outdated parser consumes the recorded mt outdated --json fixture" {
    const bytes = try readFixture(testing.allocator, "tui_outdated.json");
    defer testing.allocator.free(bytes);

    var parsed = try outdated_json.parse(testing.allocator, bytes);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 5), parsed.items.len);

    // A formula row carries its current→latest versions through.
    const wget = parsed.items[0];
    try testing.expectEqualStrings("wget", wget.name);
    try testing.expectEqualStrings("1.24.5", wget.installed);
    try testing.expectEqualStrings("1.25.0", wget.latest);
    try testing.expectEqual(outdated_json.Kind.formula, wget.kind);
    try testing.expectEqual(false, wget.pinned);

    // A pinned, outdated formula stays in the array with its tap.
    const curl = parsed.items[1];
    try testing.expectEqualStrings("curl", curl.name);
    try testing.expectEqual(true, curl.pinned);
    try testing.expectEqualStrings("homebrew/core", curl.tap);

    // A cask row parses as a cask.
    const firefox = parsed.items[3];
    try testing.expectEqualStrings("firefox", firefox.name);
    try testing.expectEqual(outdated_json.Kind.cask, firefox.kind);
}

test "select-all over the fixture upgrades every non-pinned row in order, holding the pinned one back" {
    const bytes = try readFixture(testing.allocator, "tui_outdated.json");
    defer testing.allocator.free(bytes);
    var parsed = try outdated_json.parse(testing.allocator, bytes);
    defer parsed.deinit();

    const checked = try testing.allocator.alloc(bool, parsed.items.len);
    defer testing.allocator.free(checked);
    @memset(checked, false);
    var st: outdated.State = .{ .items = parsed.items, .checked = checked };

    // `a` checks all non-pinned rows; curl (index 1) is pinned and stays clear.
    outdated.step(&st, .{ .char = .{ .bytes = .{ 'a', 0, 0, 0 }, .len = 1 } });
    try testing.expect(!checked[1]); // pinned curl
    try testing.expectEqual(@as(usize, 4), outdated.selectedCount(&st)); // 5 rows − 1 pinned

    var names: [8][]const u8 = undefined;
    const n = outdated.selectedNames(&st, &names);
    try testing.expectEqual(@as(usize, 4), n);
    // Exactly the non-pinned names, in item order — the argv `mt upgrade` receives.
    try testing.expectEqualStrings("wget", names[0]);
    try testing.expectEqualStrings("ffmpeg", names[1]);
    try testing.expectEqualStrings("firefox", names[2]);
    try testing.expectEqualStrings("visual-studio-code", names[3]);
}

test "toggling individual fixture rows selects exactly those, in item order" {
    const bytes = try readFixture(testing.allocator, "tui_outdated.json");
    defer testing.allocator.free(bytes);
    var parsed = try outdated_json.parse(testing.allocator, bytes);
    defer parsed.deinit();

    const checked = try testing.allocator.alloc(bool, parsed.items.len);
    defer testing.allocator.free(checked);
    @memset(checked, false);
    var st: outdated.State = .{ .items = parsed.items, .checked = checked };

    // Toggle ffmpeg (index 2) and visual-studio-code (index 4) via the cursor.
    st.chrome.view.selected = 2;
    outdated.step(&st, .space);
    st.chrome.view.selected = 4;
    outdated.step(&st, .space);

    var names: [8][]const u8 = undefined;
    const n = outdated.selectedNames(&st, &names);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("ffmpeg", names[0]);
    try testing.expectEqualStrings("visual-studio-code", names[1]);
}
