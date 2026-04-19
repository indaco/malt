//! malt - cleanup of self-update artefacts tests.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const cleanup = malt.update_cleanup;
const fs_compat = malt.fs_compat;

fn resetScratch(allocator: std.mem.Allocator, tag: []const u8) ![]u8 {
    const dir = try std.fmt.allocPrint(allocator, "/tmp/malt_cleanup_test_{s}", .{tag});
    fs_compat.deleteTreeAbsolute(dir) catch {};
    try fs_compat.makeDirAbsolute(dir);
    return dir;
}

fn writeFile(path: []const u8, content: []const u8) !void {
    const f = try fs_compat.createFileAbsolute(path, .{});
    defer f.close();
    try f.writeAll(content);
}

fn exists(path: []const u8) bool {
    fs_compat.accessAbsolute(path, .{}) catch return false;
    return true;
}

test "cleanUpdateArtefacts removes the .old sibling" {
    const dir = try resetScratch(testing.allocator, "old_only");
    defer testing.allocator.free(dir);
    defer fs_compat.deleteTreeAbsolute(dir) catch {};

    const target = try std.fmt.allocPrint(testing.allocator, "{s}/malt", .{dir});
    defer testing.allocator.free(target);
    const old = try std.fmt.allocPrint(testing.allocator, "{s}/malt.old", .{dir});
    defer testing.allocator.free(old);

    try writeFile(target, "live");
    try writeFile(old, "previous");

    const cleaned = try cleanup.cleanUpdateArtefacts(target);
    try testing.expectEqual(@as(u32, 1), cleaned.old);
    try testing.expectEqual(@as(u32, 0), cleaned.staging);
    try testing.expect(!exists(old));
    try testing.expect(exists(target)); // live binary must survive
}

test "cleanUpdateArtefacts removes all .malt-update-* staging files" {
    const dir = try resetScratch(testing.allocator, "staging_only");
    defer testing.allocator.free(dir);
    defer fs_compat.deleteTreeAbsolute(dir) catch {};

    const target = try std.fmt.allocPrint(testing.allocator, "{s}/malt", .{dir});
    defer testing.allocator.free(target);
    try writeFile(target, "live");

    const s1 = try std.fmt.allocPrint(testing.allocator, "{s}/.malt-update-111", .{dir});
    defer testing.allocator.free(s1);
    const s2 = try std.fmt.allocPrint(testing.allocator, "{s}/.malt-update-222", .{dir});
    defer testing.allocator.free(s2);
    try writeFile(s1, "orphan-1");
    try writeFile(s2, "orphan-2");

    const cleaned = try cleanup.cleanUpdateArtefacts(target);
    try testing.expectEqual(@as(u32, 2), cleaned.staging);
    try testing.expect(!exists(s1));
    try testing.expect(!exists(s2));
    try testing.expect(exists(target));
}

test "cleanUpdateArtefacts on an already-clean tree is a no-op" {
    const dir = try resetScratch(testing.allocator, "nothing");
    defer testing.allocator.free(dir);
    defer fs_compat.deleteTreeAbsolute(dir) catch {};

    const target = try std.fmt.allocPrint(testing.allocator, "{s}/malt", .{dir});
    defer testing.allocator.free(target);
    try writeFile(target, "live");

    const cleaned = try cleanup.cleanUpdateArtefacts(target);
    try testing.expectEqual(@as(u32, 0), cleaned.total());
    try testing.expect(exists(target));
}

test "cleanUpdateArtefacts does not touch unrelated hidden files" {
    // Defence against an over-broad glob - only files starting with the
    // exact prefix `.malt-update-` should be removed.
    const dir = try resetScratch(testing.allocator, "unrelated");
    defer testing.allocator.free(dir);
    defer fs_compat.deleteTreeAbsolute(dir) catch {};

    const target = try std.fmt.allocPrint(testing.allocator, "{s}/malt", .{dir});
    defer testing.allocator.free(target);
    try writeFile(target, "live");

    const bystander = try std.fmt.allocPrint(testing.allocator, "{s}/.malt-config", .{dir});
    defer testing.allocator.free(bystander);
    const also = try std.fmt.allocPrint(testing.allocator, "{s}/.DS_Store", .{dir});
    defer testing.allocator.free(also);
    try writeFile(bystander, "user");
    try writeFile(also, "mac");

    const cleaned = try cleanup.cleanUpdateArtefacts(target);
    try testing.expectEqual(@as(u32, 0), cleaned.total());
    try testing.expect(exists(bystander));
    try testing.expect(exists(also));
}
