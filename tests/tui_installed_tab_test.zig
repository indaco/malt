//! malt — integration tests for the `mt tui` Installed tab.
//!
//! Inline tests in the leaf modules cover the parse/render/step shapes against
//! literal bytes; this file pins the assembled path against **recorded**
//! `mt list --json --size --linked` and `mt info <pkg> --json` fixtures
//! (`scripts/fixtures/`), never live `mt` — proving the parsers consume the real
//! schema and the view/detail render is a pure function of `(state, cols, rows)`.

const std = @import("std");
const testing = std.testing;

const malt = @import("malt");
const list_json = malt.tui_json_list;
const info_json = malt.tui_json_info;
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

test "list parser consumes the recorded mt list --json --size --linked fixture" {
    const bytes = try readFixture(testing.allocator, "tui_list.json");
    defer testing.allocator.free(bytes);

    var parsed = try list_json.parse(testing.allocator, bytes);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 4), parsed.items.len);

    // A pinned, unlinked formula carries every column through.
    const curl = parsed.items[1];
    try testing.expectEqualStrings("curl", curl.name);
    try testing.expectEqual(list_json.Kind.formula, curl.kind);
    try testing.expectEqual(true, curl.pinned);
    try testing.expectEqual(@as(?bool, false), curl.linked);
    try testing.expectEqual(@as(?u64, 4734154), curl.size_bytes);

    // The cask row parses as a cask.
    const cask = parsed.items[3];
    try testing.expectEqualStrings("flux-markdown", cask.name);
    try testing.expectEqual(list_json.Kind.cask, cask.kind);
}

test "info parser consumes the recorded mt info <pkg> --json fixture" {
    const bytes = try readFixture(testing.allocator, "tui_info.json");
    defer testing.allocator.free(bytes);

    var parsed = try info_json.parse(testing.allocator, bytes);
    defer parsed.deinit();

    try testing.expectEqualStrings("curl", parsed.info.name);
    try testing.expectEqualStrings("homebrew/core", parsed.info.tap);
    try testing.expectEqual(true, parsed.info.pinned);
    try testing.expectEqual(@as(usize, 7), parsed.info.dependencies.len);
    try testing.expectEqualStrings("brotli", parsed.info.dependencies[0]);
    try testing.expectEqualStrings("zstd", parsed.info.dependencies[6]);
}
