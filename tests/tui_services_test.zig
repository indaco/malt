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

    // Cursor on dnsmasq (index 2); `r` requests a restart of exactly that row.
    st.chrome.view.selected = 2;
    services.step(&st, .{ .char = .{ .bytes = .{ 'r', 0, 0, 0 }, .len = 1 } });
    try testing.expectEqual(services.Request.restart, st.request);
    try testing.expectEqualStrings("dnsmasq", services.selectedService(&st).?.name);

    // `s` on postgresql@16 requests a start of that row — the argv `mt services`
    // would receive is `start postgresql@16`.
    st.chrome.view.selected = 1;
    services.step(&st, .{ .char = .{ .bytes = .{ 's', 0, 0, 0 }, .len = 1 } });
    try testing.expectEqual(services.Request.start, st.request);
    try testing.expectEqualStrings("postgresql@16", services.selectedService(&st).?.name);
}

test "a filter narrows the lifecycle target to a matching service" {
    const bytes = try readFixture(testing.allocator, "tui_services.json");
    defer testing.allocator.free(bytes);
    var parsed = try services_json.parse(testing.allocator, bytes);
    defer parsed.deinit();

    var st: services.State = .{ .items = parsed.items };
    st.chrome.filter.push("postgres"); // only postgresql@16 matches
    st.chrome.view.selected = 0;
    services.step(&st, .{ .char = .{ .bytes = .{ 'x', 0, 0, 0 }, .len = 1 } });
    try testing.expectEqual(services.Request.stop, st.request);
    try testing.expectEqualStrings("postgresql@16", services.selectedService(&st).?.name);
}
