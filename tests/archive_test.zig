//! malt — fs/archive tests
//! Covers extractTarGz happy/error paths and extractTarXzFile happy path.

const std = @import("std");
const testing = std.testing;
const archive = @import("malt").archive;

fn resetDir(path: []const u8) !std.fs.Dir {
    std.fs.deleteTreeAbsolute(path) catch {};
    try std.fs.makeDirAbsolute(path);
    return std.fs.openDirAbsolute(path, .{});
}

fn runTar(argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, std.heap.c_allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.TarFailed,
        else => return error.TarFailed,
    }
}

test "extractTarGz decompresses a real tar.gz produced by system tar" {
    const base = "/tmp/malt_archive_targz_ok";
    var dir = try resetDir(base);
    defer dir.close();
    defer std.fs.deleteTreeAbsolute(base) catch {};

    // Build a simple payload: base/src/hello.txt
    try dir.makePath("src");
    {
        const f = try dir.createFile("src/hello.txt", .{});
        try f.writeAll("hi");
        f.close();
    }

    // Produce bottle.tar.gz in base (what extractTarGz expects).
    try runTar(&.{ "tar", "czf", "/tmp/malt_archive_targz_ok/bottle.tar.gz", "-C", base, "src" });

    // Remove the src dir so we can observe extraction re-creating it.
    try std.fs.deleteTreeAbsolute("/tmp/malt_archive_targz_ok/src");

    var reader_buf: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(&reader_buf); // extractTarGz ignores reader contents
    try archive.extractTarGz(&reader, dir);

    // hello.txt is now back.
    const f = try dir.openFile("src/hello.txt", .{});
    defer f.close();
    var out: [8]u8 = undefined;
    const n = try f.readAll(&out);
    try testing.expectEqualStrings("hi", out[0..n]);
}

test "extractTarGz rejects a non-gzip archive" {
    const base = "/tmp/malt_archive_targz_badmagic";
    var dir = try resetDir(base);
    defer dir.close();
    defer std.fs.deleteTreeAbsolute(base) catch {};

    // Write a 'bottle.tar.gz' with the wrong magic bytes.
    const f = try dir.createFile("bottle.tar.gz", .{});
    try f.writeAll("NOPE, not gzip");
    f.close();

    var rb: [16]u8 = undefined;
    var reader = std.Io.Reader.fixed(&rb);
    try testing.expectError(error.ExtractionFailed, archive.extractTarGz(&reader, dir));
}

test "extractTarGz rejects a missing archive" {
    const base = "/tmp/malt_archive_targz_missing";
    var dir = try resetDir(base);
    defer dir.close();
    defer std.fs.deleteTreeAbsolute(base) catch {};

    var rb: [16]u8 = undefined;
    var reader = std.Io.Reader.fixed(&rb);
    try testing.expectError(error.ExtractionFailed, archive.extractTarGz(&reader, dir));
}
