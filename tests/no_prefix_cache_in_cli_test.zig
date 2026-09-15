//! Pin test: no `cli/*` or `core/*` file may build the cache directory from
//! the prefix.
//!
//! `atomic.maltCacheDir` is the one place that honours `MALT_CACHE`. A
//! hand-formatted `{prefix}/cache` at a call site reads and writes a
//! directory no other command touches: `mt update` cannot refresh it and
//! `MALT_OFFLINE` misses on documents a sibling command just cached. This
//! has crept back more than once; every cli/ caller must resolve through
//! the helper.

const std = @import("std");
const testing = std.testing;

const test_io = @import("test_io");

const scanned_roots = [_][]const u8{ "src/cli", "src/core" };
/// Every spelling of `{prefix}/cache`: the bare format literal, the
/// artefact-tier subdirectories, and the
/// `prefix_path.join(buf, prefix, "/cache")` suffix.
const forbidden = [_][]const u8{ "\"{s}/cache\"", "\"{s}/cache/Cask", "\"{s}/cache/Tap", ", \"/cache\")" };

test "no cli/ or core/ site formats the cache dir from the prefix" {
    var hits: usize = 0;
    for (scanned_roots) |root| hits += try scanTree(root);
    if (hits != 0) return error.PrefixCacheHardCoded;
}

fn scanTree(scanned_root: []const u8) !usize {
    const io = std.Options.debug_io;

    var dir = try test_io.cwd().openDir(io, scanned_root, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();

    var hits: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const file = try dir.openFile(io, entry.path, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        const content = try testing.allocator.alloc(u8, @intCast(stat.size));
        defer testing.allocator.free(content);
        _ = try file.readPositionalAll(io, content, 0);

        hits += scanContent(scanned_root, entry.path, content);
    }
    return hits;
}

/// Prints one line per hit and returns the count.
fn scanContent(scanned_root: []const u8, rel_path: []const u8, content: []const u8) usize {
    var hits: usize = 0;
    for (forbidden) |needle| {
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, content, cursor, needle)) |start| {
            cursor = start + needle.len;
            const line = 1 + std.mem.count(u8, content[0..start], "\n");
            std.debug.print("{s}/{s}:{d} builds the cache dir from the prefix; use atomic.maltCacheDir\n", .{ scanned_root, rel_path, line });
            hits += 1;
        }
    }
    return hits;
}

test "scanContent flags both hand-built spellings and ignores the helper call" {
    try testing.expectEqual(@as(usize, 0), scanContent("src/x", "ok.zig", "const d = atomic.maltCacheDir(allocator) catch return;\n"));
    try testing.expectEqual(@as(usize, 1), scanContent("src/x", "bad.zig", "const d = std.fmt.bufPrint(&buf, \"{s}/cache\", .{prefix});\n"));
    try testing.expectEqual(@as(usize, 1), scanContent("src/x", "cask.zig", "const d = std.fmt.bufPrint(&buf, \"{s}/cache/Cask/{s}\", .{ prefix, name });\n"));
    try testing.expectEqual(@as(usize, 1), scanContent("src/x", "tap.zig", "const d = std.fmt.bufPrint(&buf, \"{s}/cache/Tap\", .{prefix});\n"));
    try testing.expectEqual(@as(usize, 1), scanContent("src/x", "join.zig", "const d = prefix_path.join(&buf, prefix, \"/cache\") catch return;\n"));
}
