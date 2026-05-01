//! File-IO tests for the `cli/migrate/manifest.zig` module — exercise
//! the load/atomic-write loop against /tmp scratch paths. Pure parser
//! / encoder tests live inline in the module itself; anything that
//! touches the filesystem lives here.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const manifest = malt.cli_migrate_manifest;
const fs_compat = test_io;

fn scratchManifestPath(suffix: []const u8) ![:0]u8 {
    return std.fmt.allocPrintSentinel(
        testing.allocator,
        "/tmp/mt_manifest_{d}_{s}.json",
        .{ fs_compat.nanoTimestamp(
            std.Options.debug_io,
        ), suffix },
        0,
    );
}

test "loadFromPath returns an empty manifest when the file does not exist" {
    const path = try scratchManifestPath("missing");
    defer testing.allocator.free(path);
    fs_compat.deleteFileAbsolute(std.Options.debug_io, path) catch {};

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    var m = try manifest.loadFromPath(&ctx, testing.allocator, path);
    defer m.deinit();
    try testing.expectEqual(@as(usize, 0), m.entries.items.len);
}

test "writeAtomic + loadFromPath round-trip the completed list" {
    const path = try scratchManifestPath("roundtrip");
    defer testing.allocator.free(path);
    defer fs_compat.deleteFileAbsolute(std.Options.debug_io, path) catch {};

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const ctx: malt.app_ctx.AppCtx = .{ .io = io, .environ = .empty };

    var m = manifest.Manifest.init(testing.allocator);
    defer m.deinit();
    try m.add("foo");
    try m.add("bar");
    try m.writeAtomic(io, testing.allocator, path);

    var loaded = try manifest.loadFromPath(&ctx, testing.allocator, path);
    defer loaded.deinit();
    try testing.expect(loaded.contains("foo"));
    try testing.expect(loaded.contains("bar"));
    try testing.expect(!loaded.contains("baz"));
}

test "writeAtomic over an existing file replaces its contents" {
    const path = try scratchManifestPath("replace");
    defer testing.allocator.free(path);
    defer fs_compat.deleteFileAbsolute(std.Options.debug_io, path) catch {};

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const ctx: malt.app_ctx.AppCtx = .{ .io = io, .environ = .empty };

    var first = manifest.Manifest.init(testing.allocator);
    defer first.deinit();
    try first.add("only-first");
    try first.writeAtomic(io, testing.allocator, path);

    var second = manifest.Manifest.init(testing.allocator);
    defer second.deinit();
    try second.add("only-second");
    try second.writeAtomic(io, testing.allocator, path);

    var loaded = try manifest.loadFromPath(&ctx, testing.allocator, path);
    defer loaded.deinit();
    try testing.expect(!loaded.contains("only-first"));
    try testing.expect(loaded.contains("only-second"));
}
