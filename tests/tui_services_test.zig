//! malt — integration tests for the `mt tui` Services tab.
//!
//! Inline tests in the leaf modules cover the parse/render/step shapes against
//! literal bytes; this file pins the assembled path against a **recorded**
//! `mt services list --json` fixture (`scripts/fixtures/`), never live `mt` —
//! proving the parser consumes the real versioned schema and that the selection
//! plus a lifecycle key map to the exact `mt services <action> <name>` argv with
//! the selected row's name.

const std = @import("std");
const testing = std.testing;

const malt = @import("malt");
const services_json = malt.tui_json_services;
const services = malt.tui_tab_services;
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

test "services parser consumes the recorded mt services list --json fixture" {
    const bytes = try readFixture(testing.allocator, "tui_services.json");
    defer testing.allocator.free(bytes);

    var parsed = try services_json.parse(testing.allocator, bytes);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 4), parsed.items.len);

    // A running, auto-start service carries its keg through.
    const redis = parsed.items[0];
    try testing.expectEqualStrings("redis", redis.name);
    try testing.expectEqualStrings("running", redis.state);
    try testing.expectEqual(true, redis.auto_start);
    try testing.expectEqualStrings("redis", redis.keg_name);

    // A stopped, manual service.
    const pg = parsed.items[1];
    try testing.expectEqualStrings("postgresql@16", pg.name);
    try testing.expectEqualStrings("stopped", pg.state);
    try testing.expectEqual(false, pg.auto_start);

    // An unusual runtime state parses verbatim — no enum to break against.
    const unbound = parsed.items[3];
    try testing.expectEqualStrings("unbound", unbound.name);
    try testing.expectEqualStrings("degraded", unbound.state);
}

test "a lifecycle key over the fixture targets the selected service" {
    const bytes = try readFixture(testing.allocator, "tui_services.json");
    defer testing.allocator.free(bytes);
    var parsed = try services_json.parse(testing.allocator, bytes);
    defer parsed.deinit();

    var st: services.State = .{ .items = parsed.items };
    var storage: services.Storage = .{};
    defer storage.deinit(testing.allocator);

    // Cursor on dnsmasq (index 2); `r` builds a restart mutation over exactly that row.
    st.chrome.view.selected = 2;
    const restart = services.step(testing.allocator, "/opt/malt/bin/mt", &st, &storage, .{ .char = .{ .bytes = .{ 'r', 0, 0, 0 }, .len = 1 } });
    defer testing.allocator.free(restart.run_mutation.argv);
    try testing.expectEqualStrings("restart", restart.run_mutation.argv[2]);
    try testing.expectEqualStrings("dnsmasq", restart.run_mutation.argv[3]);

    // `s` on postgresql@16 → `mt services start postgresql@16`.
    st.chrome.view.selected = 1;
    const start = services.step(testing.allocator, "/opt/malt/bin/mt", &st, &storage, .{ .char = .{ .bytes = .{ 's', 0, 0, 0 }, .len = 1 } });
    defer testing.allocator.free(start.run_mutation.argv);
    try testing.expectEqualStrings("start", start.run_mutation.argv[2]);
    try testing.expectEqualStrings("postgresql@16", start.run_mutation.argv[3]);
}

test "a filter narrows the lifecycle target to a matching service" {
    const bytes = try readFixture(testing.allocator, "tui_services.json");
    defer testing.allocator.free(bytes);
    var parsed = try services_json.parse(testing.allocator, bytes);
    defer parsed.deinit();

    var st: services.State = .{ .items = parsed.items };
    var storage: services.Storage = .{};
    defer storage.deinit(testing.allocator);
    st.chrome.filter.push("postgres"); // only postgresql@16 matches
    st.chrome.view.selected = 0;
    const stop = services.step(testing.allocator, "/opt/malt/bin/mt", &st, &storage, .{ .char = .{ .bytes = .{ 'x', 0, 0, 0 }, .len = 1 } });
    defer testing.allocator.free(stop.run_mutation.argv);
    try testing.expectEqualStrings("stop", stop.run_mutation.argv[2]);
    try testing.expectEqualStrings("postgresql@16", stop.run_mutation.argv[3]);
}
