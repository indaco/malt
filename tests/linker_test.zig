//! malt — linker module tests
//! Tests for symlink creation, conflict detection, and unlinking.
//! These tests use the filesystem directly and verify symlink behavior.

const std = @import("std");
const malt = @import("malt");
const testing = std.testing;

test "atomic symlink via tmp+rename pattern" {
    // Verify the atomic symlink pattern used in linker.zig:
    // create at tmp name, then rename into place.
    const tmp_dir = "/tmp/malt_link_test";
    malt.fs_compat.makeDirAbsolute(tmp_dir) catch {};
    defer malt.fs_compat.deleteTreeAbsolute(tmp_dir) catch {};

    var dir = try malt.fs_compat.openDirAbsolute(tmp_dir, .{});
    defer dir.close(malt.io_mod.ctx());

    // Create a target file
    const f = try dir.createFile(malt.io_mod.ctx(), "target_bin", .{});
    try f.writeStreamingAll(malt.io_mod.ctx(), "#!/bin/sh\necho hello\n");
    f.close(malt.io_mod.ctx());

    // Build absolute target path
    var target_buf: [512]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "{s}/target_bin", .{tmp_dir});

    // Atomic symlink: create at tmp name, rename into place
    dir.deleteFile(malt.io_mod.ctx(), ".malt_tmp_mylink") catch {};
    try dir.symLink(malt.io_mod.ctx(), target, ".malt_tmp_mylink", .{});
    try dir.rename(".malt_tmp_mylink", dir, "mylink", malt.io_mod.ctx());

    // Verify the symlink exists and points to the right target
    var link_target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link_target_len = try dir.readLink(malt.io_mod.ctx(), "mylink", &link_target_buf);
    try testing.expectEqualStrings(target, link_target_buf[0..link_target_len]);
}

test "symlink replacement is atomic" {
    const tmp_dir = "/tmp/malt_link_replace_test";
    malt.fs_compat.makeDirAbsolute(tmp_dir) catch {};
    defer malt.fs_compat.deleteTreeAbsolute(tmp_dir) catch {};

    var dir = try malt.fs_compat.openDirAbsolute(tmp_dir, .{});
    defer dir.close(malt.io_mod.ctx());

    // Create two target files
    {
        const f = try dir.createFile(malt.io_mod.ctx(), "v1", .{});
        f.close(malt.io_mod.ctx());
    }
    {
        const f = try dir.createFile(malt.io_mod.ctx(), "v2", .{});
        f.close(malt.io_mod.ctx());
    }

    var v1_buf: [512]u8 = undefined;
    const v1 = try std.fmt.bufPrint(&v1_buf, "{s}/v1", .{tmp_dir});
    var v2_buf: [512]u8 = undefined;
    const v2 = try std.fmt.bufPrint(&v2_buf, "{s}/v2", .{tmp_dir});

    // Create initial symlink to v1
    try dir.symLink(malt.io_mod.ctx(), v1, "current", .{});

    // Atomically replace with v2
    dir.deleteFile(malt.io_mod.ctx(), ".malt_tmp_current") catch {};
    try dir.symLink(malt.io_mod.ctx(), v2, ".malt_tmp_current", .{});
    try dir.rename(".malt_tmp_current", dir, "current", malt.io_mod.ctx());

    // Verify it now points to v2
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_len = try dir.readLink(malt.io_mod.ctx(), "current", &link_buf);
    try testing.expectEqualStrings(v2, link_buf[0..target_len]);
}

test "conflict detection by reading existing symlink targets" {
    const tmp_dir = "/tmp/malt_conflict_test";
    malt.fs_compat.makeDirAbsolute(tmp_dir) catch {};
    defer malt.fs_compat.deleteTreeAbsolute(tmp_dir) catch {};

    var dir = try malt.fs_compat.openDirAbsolute(tmp_dir, .{});
    defer dir.close(malt.io_mod.ctx());

    // Create a symlink that points to keg A
    const keg_a = "/opt/malt/Cellar/foo/1.0/bin/tool";
    try dir.symLink(malt.io_mod.ctx(), keg_a, "tool", .{});

    // Now "keg B" also has a "tool" binary — check for conflict
    const keg_b_path = "/opt/malt/Cellar/bar/2.0";
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const existing_target_len = try dir.readLink(malt.io_mod.ctx(), "tool", &link_buf);

    // The existing symlink does NOT start with keg_b_path — conflict!
    const has_conflict = !std.mem.startsWith(u8, link_buf[0..existing_target_len], keg_b_path);
    try testing.expect(has_conflict);
}
