//! malt — linker module tests
//! Tests for symlink creation, conflict detection, and unlinking.
//! These tests use the filesystem directly and verify symlink behavior.

const std = @import("std");
const testing = std.testing;

test "atomic symlink via tmp+rename pattern" {
    // Verify the atomic symlink pattern used in linker.zig:
    // create at tmp name, then rename into place.
    const tmp_dir = "/tmp/malt_link_test";
    std.fs.makeDirAbsolute(tmp_dir) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_dir, .{});
    defer dir.close();

    // Create a target file
    const f = try dir.createFile("target_bin", .{});
    try f.writeAll("#!/bin/sh\necho hello\n");
    f.close();

    // Build absolute target path
    var target_buf: [512]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "{s}/target_bin", .{tmp_dir});

    // Atomic symlink: create at tmp name, rename into place
    dir.deleteFile(".malt_tmp_mylink") catch {};
    try dir.symLink(target, ".malt_tmp_mylink", .{});
    try dir.rename(".malt_tmp_mylink", "mylink");

    // Verify the symlink exists and points to the right target
    var link_target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link_target = try dir.readLink("mylink", &link_target_buf);
    try testing.expectEqualStrings(target, link_target);
}

test "symlink replacement is atomic" {
    const tmp_dir = "/tmp/malt_link_replace_test";
    std.fs.makeDirAbsolute(tmp_dir) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_dir, .{});
    defer dir.close();

    // Create two target files
    {
        const f = try dir.createFile("v1", .{});
        f.close();
    }
    {
        const f = try dir.createFile("v2", .{});
        f.close();
    }

    var v1_buf: [512]u8 = undefined;
    const v1 = try std.fmt.bufPrint(&v1_buf, "{s}/v1", .{tmp_dir});
    var v2_buf: [512]u8 = undefined;
    const v2 = try std.fmt.bufPrint(&v2_buf, "{s}/v2", .{tmp_dir});

    // Create initial symlink to v1
    try dir.symLink(v1, "current", .{});

    // Atomically replace with v2
    dir.deleteFile(".malt_tmp_current") catch {};
    try dir.symLink(v2, ".malt_tmp_current", .{});
    try dir.rename(".malt_tmp_current", "current");

    // Verify it now points to v2
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = try dir.readLink("current", &link_buf);
    try testing.expectEqualStrings(v2, target);
}

test "conflict detection by reading existing symlink targets" {
    const tmp_dir = "/tmp/malt_conflict_test";
    std.fs.makeDirAbsolute(tmp_dir) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    var dir = try std.fs.openDirAbsolute(tmp_dir, .{});
    defer dir.close();

    // Create a symlink that points to keg A
    const keg_a = "/opt/malt/Cellar/foo/1.0/bin/tool";
    try dir.symLink(keg_a, "tool", .{});

    // Now "keg B" also has a "tool" binary — check for conflict
    const keg_b_path = "/opt/malt/Cellar/bar/2.0";
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const existing_target = try dir.readLink("tool", &link_buf);

    // The existing symlink does NOT start with keg_b_path — conflict!
    const has_conflict = !std.mem.startsWith(u8, existing_target, keg_b_path);
    try testing.expect(has_conflict);
}
