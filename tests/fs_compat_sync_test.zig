//! malt — fs_compat.sync tests
//!
//! `sync` on a File / Dir is the seam callers use to make writes
//! and rename metadata durable. Every atomic-swap style path needs
//! this, so keep it exercised at the compat layer — the POSIX
//! primitive is the same whether we wrap `std.Io.File.sync` or
//! `fsync(2)` directly for directories.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const fs = malt.fs_compat;

fn scratchDir(tag: []const u8, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "/tmp/malt_sync_{s}_{d}", .{ tag, fs.nanoTimestamp() });
}

test "File.sync flushes a freshly written file without error" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try scratchDir("file", &path_buf);
    fs.deleteTreeAbsolute(dir_path) catch {};
    try fs.makeDirAbsolute(dir_path);
    defer fs.deleteTreeAbsolute(dir_path) catch {};

    var file_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&file_path_buf, "{s}/data", .{dir_path});

    const f = try fs.createFileAbsolute(file_path, .{});
    defer f.close();
    try f.writeAll("durable-bytes");
    try f.sync();
}

test "Dir.sync flushes directory metadata without error" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try scratchDir("dir", &path_buf);
    fs.deleteTreeAbsolute(dir_path) catch {};
    try fs.makeDirAbsolute(dir_path);
    defer fs.deleteTreeAbsolute(dir_path) catch {};

    // Create a file so the directory has metadata worth flushing.
    var child_buf: [std.fs.max_path_bytes]u8 = undefined;
    const child_path = try std.fmt.bufPrint(&child_buf, "{s}/child", .{dir_path});
    const child = try fs.createFileAbsolute(child_path, .{});
    child.close();

    var dir = try fs.openDirAbsolute(dir_path, .{});
    defer dir.close();
    try dir.sync();
}
