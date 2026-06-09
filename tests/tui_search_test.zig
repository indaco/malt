//! malt — integration tests for the `mt tui` Search tab.
//!
//! Inline tests in the leaf modules cover the parse/render/step shapes against
//! literal bytes; this file pins the assembled path against a **recorded**
//! `mt search <query> --json` fixture (`scripts/fixtures/`), never live `mt` —
//! proving the parser consumes the real versioned, install-aware schema and that
//! the selection plus `i` map to installing exactly the selected, not-yet
//! installed hit (the name the install argv would carry), while Enter over a
//! result opens its info pane.

const std = @import("std");
const testing = std.testing;

const malt = @import("malt");
const search_json = malt.tui_json_search;
const search = malt.tui_tab_search;
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

fn ch(c: u8) malt.tui_keys.Key {
    return .{ .char = .{ .bytes = .{ c, 0, 0, 0 }, .len = 1 } };
}

test "search parser consumes the recorded mt search --json fixture" {
    const bytes = try readFixture(testing.allocator, "tui_search.json");
    defer testing.allocator.free(bytes);

    var parsed = try search_json.parse(testing.allocator, bytes);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 4), parsed.items.len);

    // A cask hit already on the system carries its installed marker.
    const firefox = parsed.items[0];
    try testing.expectEqualStrings("firefox", firefox.name);
    try testing.expectEqual(search_json.Kind.cask, firefox.kind);
    try testing.expectEqual(true, firefox.installed);

    // A formula hit not yet installed.
    const firewalld = parsed.items[2];
    try testing.expectEqualStrings("firewalld", firewalld.name);
    try testing.expectEqual(search_json.Kind.formula, firewalld.kind);
    try testing.expectEqual(false, firewalld.installed);

    // A formula hit already installed — mixed kind and mixed install-state.
    const firejail = parsed.items[3];
    try testing.expectEqualStrings("firejail", firejail.name);
    try testing.expectEqual(search_json.Kind.formula, firejail.kind);
    try testing.expectEqual(true, firejail.installed);
}

test "i over the fixture installs the selected not-yet-installed hit and is inert on an installed one" {
    const bytes = try readFixture(testing.allocator, "tui_search.json");
    defer testing.allocator.free(bytes);
    var parsed = try search_json.parse(testing.allocator, bytes);
    defer parsed.deinit();

    var st: search.State = .{ .items = parsed.items, .phase = .loaded };

    // Cursor on firefox (index 0, already installed): `i` is inert.
    st.chrome.view.selected = 0;
    search.step(&st, ch('i'));
    try testing.expectEqual(search.Request.none, st.request);

    // Cursor on firefox@developer-edition (index 1, not installed): `i` installs
    // exactly that hit — the name the `mt install <name>` argv would carry.
    st.chrome.view.selected = 1;
    search.step(&st, ch('i'));
    try testing.expectEqual(search.Request.install, st.request);
    try testing.expectEqualStrings("firefox@developer-edition", search.selectedMatch(&st).?.name);
    try testing.expectEqual(search_json.Kind.cask, search.selectedMatch(&st).?.kind);
}

test "Enter over a result requests its info (committing the query is the shell's job)" {
    const bytes = try readFixture(testing.allocator, "tui_search.json");
    defer testing.allocator.free(bytes);
    var parsed = try search_json.parse(testing.allocator, bytes);
    defer parsed.deinit();

    // Enter over a loaded result opens `mt info` for it; the query-commit path
    // (filter editing → search) is driven by the app shell, not the tab core.
    var st: search.State = .{ .items = parsed.items, .phase = .loaded };
    search.step(&st, .enter);
    try testing.expectEqual(search.Request.info, st.request);
}
