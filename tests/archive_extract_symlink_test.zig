//! malt — end-to-end symlink-target guard for the subprocess extractors.
//!
//! `extractTarXzFile` (system `tar`) and `extractZip` (system `unzip`)
//! validate entry *names* via a listing pass, but the listing never surfaces
//! symlink *targets*. These tests build real archives whose only escape is a
//! symlink target climbing out of the destination, and assert the extractor
//! refuses them while a benign archive still extracts.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const archive = malt.archive;

/// Run `argv` (optionally in `cwd`) and fail the test if it doesn't exit 0.
fn run(io: std.Io, argv: []const []const u8, cwd: std.process.Child.Cwd) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    switch (try child.wait(io)) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn destAbs(tmp: *std.testing.TmpDir, io: std.Io, buf: []u8) ![]const u8 {
    var base: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const b = base[0..try std.Io.Dir.realPath(tmp.dir, io, &base)];
    return std.fmt.bufPrint(buf, "{s}/dest", .{b});
}

fn archiveAbs(tmp: *std.testing.TmpDir, io: std.Io, name: []const u8, buf: []u8) ![]const u8 {
    var base: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const b = base[0..try std.Io.Dir.realPath(tmp.dir, io, &base)];
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ b, name });
}

test "extractTarXzFile rejects a tar.xz symlink target that escapes the destination" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.createDirPath(io, "dest");
    var src = try tmp.dir.openDir(io, "src", .{});
    defer src.close(io);
    try src.symLink(io, "../../../../etc/evil", "escape", .{});

    var arc_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const arc = try archiveAbs(&tmp, io, "evil.tar.xz", &arc_buf);
    try run(io, &.{ "tar", "-cJf", arc, "-C", "src", "escape" }, .{ .dir = tmp.dir });

    var dst_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dst = try destAbs(&tmp, io, &dst_buf);
    try testing.expectError(error.ExtractionFailed, archive.extractTarXzFile(io, arc, dst));
    // The guard wipes the tree, so no escaping symlink is left behind.
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, dst, .{}));
}

test "extractZip rejects a zip symlink target that escapes the destination" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.createDirPath(io, "dest");
    var src = try tmp.dir.openDir(io, "src", .{});
    defer src.close(io);
    try src.symLink(io, "../../../../etc/evil", "escape", .{});

    var arc_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const arc = try archiveAbs(&tmp, io, "evil.zip", &arc_buf);
    // `--symlinks` stores the link as a symlink rather than dereferencing it.
    try run(io, &.{ "zip", "-q", "--symlinks", arc, "escape" }, .{ .dir = src });

    var dst_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dst = try destAbs(&tmp, io, &dst_buf);
    try testing.expectError(error.ExtractionFailed, archive.extractZip(io, arc, dst));
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, dst, .{}));
}

test "extractZip still extracts a benign archive" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.createDirPath(io, "dest");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/hello", .data = "hi" });
    var src = try tmp.dir.openDir(io, "src", .{});
    defer src.close(io);

    var arc_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const arc = try archiveAbs(&tmp, io, "ok.zip", &arc_buf);
    try run(io, &.{ "zip", "-q", arc, "hello" }, .{ .dir = src });

    var dst_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dst = try destAbs(&tmp, io, &dst_buf);
    try archive.extractZip(io, arc, dst);

    var hello_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const hello = try std.fmt.bufPrint(&hello_buf, "{s}/hello", .{dst});
    try std.Io.Dir.accessAbsolute(io, hello, .{});
}
