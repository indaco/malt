//! malt — fs/archive tests
//! Covers extractTarGz happy/error paths and extractTarXzFile happy path.

const std = @import("std");
const malt = @import("malt");
const testing = std.testing;
const archive = @import("malt").archive;

fn resetDir(path: []const u8) !malt.fs_compat.Dir {
    malt.fs_compat.deleteTreeAbsolute(path) catch {};
    try malt.fs_compat.makeDirAbsolute(path);
    return malt.fs_compat.openDirAbsolute(path, .{});
}

fn runTar(argv: []const []const u8) !void {
    var child = malt.fs_compat.Child.init(argv, std.heap.c_allocator);
    child.stdout_behavior = .ignore;
    child.stderr_behavior = .ignore;
    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .exited => |code| if (code != 0) return error.TarFailed,
        else => return error.TarFailed,
    }
}

test "extractTarGz decompresses a real tar.gz produced by system tar" {
    const base = "/tmp/malt_archive_targz_ok";
    var dir = try resetDir(base);
    defer dir.close();
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};

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
    try malt.fs_compat.deleteTreeAbsolute(base ++ "/src");

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
    malt.fs_compat.deleteTreeAbsolute(src_dir) catch {};
    malt.fs_compat.deleteTreeAbsolute(dest_dir) catch {};
    try malt.fs_compat.makeDirAbsolute(src_dir);
    try malt.fs_compat.makeDirAbsolute(dest_dir);
    defer malt.fs_compat.deleteTreeAbsolute(src_dir) catch {};
    defer malt.fs_compat.deleteTreeAbsolute(dest_dir) catch {};

    // Build payload in src_dir and tarball it into src_dir/tap_download.tar.gz.
    try malt.fs_compat.makeDirAbsolute(src_dir ++ "/payload");
    {
        const f = try malt.fs_compat.createFileAbsolute(src_dir ++ "/payload/bin", .{});
        try f.writeAll("#!/bin/sh\n");
        f.close();
    }
    const archive_path = src_dir ++ "/tap_download.tar.gz";
    try runTar(&.{ "tar", "czf", archive_path, "-C", src_dir, "payload" });

    try archive.extractTarGz(archive_path, dest_dir);

    // The payload landed in dest_dir, not next to the archive.
    const f = try malt.fs_compat.openFileAbsolute(dest_dir ++ "/payload/bin", .{});
    defer f.close();
}

test "extractTarGz rejects a non-gzip archive" {
    const base = "/tmp/malt_archive_targz_badmagic";
    var dir = try resetDir(base);
    defer dir.close();
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};

    // Write an archive file with wrong magic bytes.
    const archive_path = base ++ "/payload.tar.gz";
    const f = try malt.fs_compat.createFileAbsolute(archive_path, .{});
    try f.writeAll("NOPE, not gzip");
    f.close();

    try testing.expectError(error.ExtractionFailed, archive.extractTarGz(archive_path, base));
}

test "extractTarGz rejects a missing archive" {
    const base = "/tmp/malt_archive_targz_missing";
    var dir = try resetDir(base);
    defer dir.close();
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};

    try testing.expectError(error.ExtractionFailed, archive.extractTarGz(base ++ "/nope.tar.gz", base));
}

fn runCmd(argv: []const []const u8) !void {
    var child = malt.fs_compat.Child.init(argv, std.heap.c_allocator);
    child.stdout_behavior = .ignore;
    child.stderr_behavior = .ignore;
    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .exited => |code| if (code != 0) return error.CmdFailed,
        else => return error.CmdFailed,
    }
}

test "extractZip decompresses a real zip produced by system zip" {
    const base = "/tmp/malt_archive_zip_ok";
    var dir = try resetDir(base);
    defer dir.close();
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};

    // Build a payload mirroring what a HashiCorp-style release contains:
    // a single executable at the archive root, no nested directory. The
    // binary-finding walker in the tap-install path depends on exactly
    // this shape.
    {
        const f = try dir.createFile("terraform", .{ .permissions = std.Io.File.Permissions.fromMode(0o755) });
        try f.writeAll("#!/bin/sh\necho hi\n");
        f.close();
    }
    const archive_path = base ++ "/payload.zip";
    try runCmd(&.{ "zip", "-j", "-q", archive_path, base ++ "/terraform" });
    try malt.fs_compat.deleteFileAbsolute(base ++ "/terraform");

    try archive.extractZip(archive_path, base);

    const f = try dir.openFile("terraform", .{});
    defer f.close();
    var buf: [32]u8 = undefined;
    const n = try f.readAll(&buf);
    try testing.expect(n > 0);
    try testing.expect(std.mem.startsWith(u8, buf[0..n], "#!/bin/sh"));
}

test "extractZip rejects a non-zip archive" {
    const base = "/tmp/malt_archive_zip_badmagic";
    var dir = try resetDir(base);
    defer dir.close();
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};

    const archive_path = base ++ "/payload.zip";
    const f = try malt.fs_compat.createFileAbsolute(archive_path, .{});
    try f.writeAll("NOPE, not a zip");
    f.close();

    try testing.expectError(error.ExtractionFailed, archive.extractZip(archive_path, base));
}

test "extractZip rejects a missing archive" {
    const base = "/tmp/malt_archive_zip_missing";
    var dir = try resetDir(base);
    defer dir.close();
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};

    try testing.expectError(error.ExtractionFailed, archive.extractZip(base ++ "/nope.zip", base));
}
