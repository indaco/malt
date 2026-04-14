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

    const archive_path = base ++ "/payload.tar.gz";
    try runTar(&.{ "tar", "czf", archive_path, "-C", base, "src" });

    // Remove the src dir so we can observe extraction re-creating it.
    try std.fs.deleteTreeAbsolute(base ++ "/src");

    try archive.extractTarGz(archive_path, base);

    const f = try dir.openFile("src/hello.txt", .{});
    defer f.close();
    var out: [8]u8 = undefined;
    const n = try f.readAll(&out);
    try testing.expectEqualStrings("hi", out[0..n]);
}

// Regression: the tap-formula install path writes its archive to
// `{prefix}/tmp/tap_download.tar.gz` (not `bottle.tar.gz`) and extracts
// into the cellar. The previous `extractTarGz` hardcoded the archive
// lookup to `{dest_dir}/bottle.tar.gz`, so `mt install user/tap/formula`
// silently failed with `CellarFailed`. Covers both halves of the fix:
// caller-supplied archive path, caller-supplied dest dir.
test "extractTarGz extracts an archive living outside the destination dir" {
    const src_dir = "/tmp/malt_archive_targz_split_src";
    const dest_dir = "/tmp/malt_archive_targz_split_dest";
    std.fs.deleteTreeAbsolute(src_dir) catch {};
    std.fs.deleteTreeAbsolute(dest_dir) catch {};
    try std.fs.makeDirAbsolute(src_dir);
    try std.fs.makeDirAbsolute(dest_dir);
    defer std.fs.deleteTreeAbsolute(src_dir) catch {};
    defer std.fs.deleteTreeAbsolute(dest_dir) catch {};

    // Build payload in src_dir and tarball it into src_dir/tap_download.tar.gz.
    try std.fs.makeDirAbsolute(src_dir ++ "/payload");
    {
        const f = try std.fs.createFileAbsolute(src_dir ++ "/payload/bin", .{});
        try f.writeAll("#!/bin/sh\n");
        f.close();
    }
    const archive_path = src_dir ++ "/tap_download.tar.gz";
    try runTar(&.{ "tar", "czf", archive_path, "-C", src_dir, "payload" });

    try archive.extractTarGz(archive_path, dest_dir);

    // The payload landed in dest_dir, not next to the archive.
    const f = try std.fs.openFileAbsolute(dest_dir ++ "/payload/bin", .{});
    defer f.close();
}

test "extractTarGz rejects a non-gzip archive" {
    const base = "/tmp/malt_archive_targz_badmagic";
    var dir = try resetDir(base);
    defer dir.close();
    defer std.fs.deleteTreeAbsolute(base) catch {};

    // Write an archive file with wrong magic bytes.
    const archive_path = base ++ "/payload.tar.gz";
    const f = try std.fs.createFileAbsolute(archive_path, .{});
    try f.writeAll("NOPE, not gzip");
    f.close();

    try testing.expectError(error.ExtractionFailed, archive.extractTarGz(archive_path, base));
}

test "extractTarGz rejects a missing archive" {
    const base = "/tmp/malt_archive_targz_missing";
    var dir = try resetDir(base);
    defer dir.close();
    defer std.fs.deleteTreeAbsolute(base) catch {};

    try testing.expectError(error.ExtractionFailed, archive.extractTarGz(base ++ "/nope.tar.gz", base));
}
