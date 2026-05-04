//! malt — fs/archive tests
//! Covers extractTarGz happy/error paths and extractTarXzFile happy path.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const archive = @import("malt").archive;

fn resetDir(path: []const u8) !std.Io.Dir {
    test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    try test_io.makeDirAbsolute(std.Options.debug_io, path);
    return test_io.openDirAbsolute(std.Options.debug_io, path, .{});
}

fn runTar(argv: []const []const u8) !void {
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{ .environ = malt.app_ctx.processEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.TarFailed,
        else => return error.TarFailed,
    }
}

/// Real `Threaded` io for tests that drive a subprocess (tar/zip/unzip) —
/// `std.Options.debug_io`'s failing allocator can't back a child spawn.
fn spawnIo() std.Io.Threaded {
    return std.Io.Threaded.init(std.heap.c_allocator, .{});
}

test "extractTarGz decompresses a real tar.gz produced by system tar" {
    const base = "/tmp/malt_archive_targz_ok";
    var dir = try resetDir(base);
    defer dir.close(std.Options.debug_io);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};

    // Build a simple payload: base/src/hello.txt
    try dir.createDirPath(std.Options.debug_io, "src");
    {
        const f = try dir.createFile(std.Options.debug_io, "src/hello.txt", .{});
        try f.writeStreamingAll(std.Options.debug_io, "hi");
        f.close(std.Options.debug_io);
    }

    const archive_path = base ++ "/payload.tar.gz";
    try runTar(&.{ "tar", "czf", archive_path, "-C", base, "src" });

    // Remove the src dir so we can observe extraction re-creating it.
    try test_io.deleteTreeAbsolute(std.Options.debug_io, base ++ "/src");

    try archive.extractTarGz(std.Options.debug_io, archive_path, base);

    const f = try dir.openFile(std.Options.debug_io, "src/hello.txt", .{});
    defer f.close(std.Options.debug_io);
    var out: [8]u8 = undefined;
    const n = try f.readPositionalAll(std.Options.debug_io, &out, 0);
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
    test_io.deleteTreeAbsolute(std.Options.debug_io, src_dir) catch {};
    test_io.deleteTreeAbsolute(std.Options.debug_io, dest_dir) catch {};
    try test_io.makeDirAbsolute(std.Options.debug_io, src_dir);
    try test_io.makeDirAbsolute(std.Options.debug_io, dest_dir);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, src_dir) catch {};
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, dest_dir) catch {};

    // Build payload in src_dir and tarball it into src_dir/tap_download.tar.gz.
    try test_io.makeDirAbsolute(std.Options.debug_io, src_dir ++ "/payload");
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, src_dir ++ "/payload/bin", .{});
        try f.writeStreamingAll(std.Options.debug_io, "#!/bin/sh\n");
        f.close(std.Options.debug_io);
    }
    const archive_path = src_dir ++ "/tap_download.tar.gz";
    try runTar(&.{ "tar", "czf", archive_path, "-C", src_dir, "payload" });

    try archive.extractTarGz(std.Options.debug_io, archive_path, dest_dir);

    // The payload landed in dest_dir, not next to the archive.
    const f = try test_io.openFileAbsolute(std.Options.debug_io, dest_dir ++ "/payload/bin", .{});
    defer f.close(std.Options.debug_io);
}

// S8: native tar.gz extractor (no `tar xzf` subprocess). The bottle
// extraction path has to preserve three things or installed binaries
// break at runtime: the owner-executable bit on programs, relative
// symlinks (used heavily by Homebrew to pin `share/`, `lib/`, etc.),
// and deeply nested paths (bottles routinely reach 6+ levels under
// `<name>/<version>/share/...`). A single tarball exercises all three
// so a regression in any one tripps this test.
test "extractTarGz preserves exec bits, symlinks, and deep paths" {
    const base = "/tmp/malt_archive_targz_perms";
    var dir = try resetDir(base);
    defer dir.close(std.Options.debug_io);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};

    // Build the source tree to tar up: an executable, a deep file, and
    // a relative symlink pointing at the executable.
    const src_root = base ++ "/src";
    try test_io.makeDirAbsolute(std.Options.debug_io, src_root);
    try dir.createDirPath(std.Options.debug_io, "src/bin");
    try dir.createDirPath(std.Options.debug_io, "src/a/b/c/d/e/f");
    {
        const f = try dir.createFile(std.Options.debug_io, "src/bin/hello", .{ .permissions = std.Io.File.Permissions.fromMode(0o755) });
        try f.writeStreamingAll(std.Options.debug_io, "#!/bin/sh\necho hi\n");
        f.close(std.Options.debug_io);
    }
    {
        const f = try dir.createFile(std.Options.debug_io, "src/a/b/c/d/e/f/deep.txt", .{});
        try f.writeStreamingAll(std.Options.debug_io, "deep");
        f.close(std.Options.debug_io);
    }
    // Relative symlink sitting next to the executable, pointing at it
    // by basename — the usual bottle shape.
    const src_subdir = try dir.openDir(std.Options.debug_io, "src/bin", .{});
    defer {
        var m = src_subdir;
        m.close(std.Options.debug_io);
    }
    try src_subdir.symLink(std.Options.debug_io, "hello", "hello_link", .{});

    // Tar it up; GNU/BSD tar both preserve exec bits and symlinks by
    // default, so the round-trip through our native extractor is the
    // thing under test, not tar's archive-building behaviour.
    const archive_path = base ++ "/payload.tar.gz";
    try runTar(&.{ "tar", "czf", archive_path, "-C", base, "src" });

    // Nuke the source tree so observed state after extract can only
    // come from our extractor.
    try test_io.deleteTreeAbsolute(std.Options.debug_io, src_root);

    try archive.extractTarGz(std.Options.debug_io, archive_path, base);

    // Exec bit preserved (tar.ExtractOptions.ModeMode.executable_bit_only
    // is the default — owner-x copied to group/other).
    const st = try dir.statFile(std.Options.debug_io, "src/bin/hello", .{});
    const mode = st.permissions.toMode();
    try testing.expect(mode & 0o111 != 0);

    // Symlink extracted as a link, not a copy — readLink succeeds and
    // returns the original relative target.
    var link_buf: [64]u8 = undefined;
    const target_len = try dir.readLink(std.Options.debug_io, "src/bin/hello_link", &link_buf);
    try testing.expectEqualStrings("hello", link_buf[0..target_len]);

    // Deep nested path reached intact.
    const deep = try dir.openFile(std.Options.debug_io, "src/a/b/c/d/e/f/deep.txt", .{});
    defer deep.close(std.Options.debug_io);
    var buf: [8]u8 = undefined;
    const n = try deep.readPositionalAll(std.Options.debug_io, &buf, 0);
    try testing.expectEqualStrings("deep", buf[0..n]);
}

// Bottles for formulae like `libdeflate` ship multi-name CLIs via tar
// hard-link entries (`bin/libdeflate-gzip` -> `bin/libdeflate-gunzip`).
// `std.tar.FileKind` has no `.hard_link` variant in zig 0.16, so the
// stock `pipeToFileSystem` would otherwise fail with the generic
// "Download failed" surface. Pre-scan + post-pass `link()` recovers
// the alias without touching the bulk extraction pipeline.
test "extractTarGz materialises a tar hard-link entry" {
    const base = "/tmp/malt_archive_targz_hardlink";
    var dir = try resetDir(base);
    defer dir.close(std.Options.debug_io);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};

    // Build payload: src/bin/primary holds 'pri', src/bin/aliased is a
    // hard link to primary. We use `ln` (not `ln -s`) so tar records a
    // type-'1' header; with `ln -s` it would be a symlink instead.
    try dir.createDirPath(std.Options.debug_io, "src/bin");
    {
        const f = try dir.createFile(std.Options.debug_io, "src/bin/primary", .{
            .permissions = std.Io.File.Permissions.fromMode(0o755),
        });
        try f.writeStreamingAll(std.Options.debug_io, "pri");
        f.close(std.Options.debug_io);
    }
    try runCmd(&.{ "ln", base ++ "/src/bin/primary", base ++ "/src/bin/aliased" });

    const archive_path = base ++ "/payload.tar.gz";
    try runTar(&.{ "tar", "czf", archive_path, "-C", base, "src" });

    // Wipe so observed state can only come from our extractor.
    try test_io.deleteTreeAbsolute(std.Options.debug_io, base ++ "/src");

    try archive.extractTarGz(std.Options.debug_io, archive_path, base);

    // Both names land on disk with the same content; that's necessary
    // for libdeflate-style multi-binary kegs to actually function.
    var buf: [8]u8 = undefined;
    {
        const f = try dir.openFile(std.Options.debug_io, "src/bin/primary", .{});
        defer f.close(std.Options.debug_io);
        const n = try f.readPositionalAll(std.Options.debug_io, &buf, 0);
        try testing.expectEqualStrings("pri", buf[0..n]);
    }
    {
        const f = try dir.openFile(std.Options.debug_io, "src/bin/aliased", .{});
        defer f.close(std.Options.debug_io);
        const n = try f.readPositionalAll(std.Options.debug_io, &buf, 0);
        try testing.expectEqualStrings("pri", buf[0..n]);
    }

    // Hard link semantics: same inode, link count >= 2. Confirms we did
    // a `link()` call rather than copying the bytes (which would defeat
    // the point of hard-link entries in the bottle and double the disk
    // footprint per multi-binary keg).
    const stat_a = try dir.statFile(std.Options.debug_io, "src/bin/primary", .{});
    const stat_b = try dir.statFile(std.Options.debug_io, "src/bin/aliased", .{});
    try testing.expectEqual(stat_a.inode, stat_b.inode);
    try testing.expect(stat_a.nlink >= 2);
}

test "extractTarGz rejects a non-gzip archive" {
    const base = "/tmp/malt_archive_targz_badmagic";
    var dir = try resetDir(base);
    defer dir.close(std.Options.debug_io);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};

    // Write an archive file with wrong magic bytes.
    const archive_path = base ++ "/payload.tar.gz";
    const f = try test_io.createFileAbsolute(std.Options.debug_io, archive_path, .{});
    try f.writeStreamingAll(std.Options.debug_io, "NOPE, not gzip");
    f.close(std.Options.debug_io);

    try testing.expectError(error.ExtractionFailed, archive.extractTarGz(std.Options.debug_io, archive_path, base));
}

test "extractTarGz rejects a missing archive" {
    const base = "/tmp/malt_archive_targz_missing";
    var dir = try resetDir(base);
    defer dir.close(std.Options.debug_io);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};

    try testing.expectError(error.ExtractionFailed, archive.extractTarGz(std.Options.debug_io, base ++ "/nope.tar.gz", base));
}

fn runCmd(argv: []const []const u8) !void {
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{ .environ = malt.app_ctx.processEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.CmdFailed,
        else => return error.CmdFailed,
    }
}

test "extractZip decompresses a real zip produced by system zip" {
    const base = "/tmp/malt_archive_zip_ok";
    var dir = try resetDir(base);
    defer dir.close(std.Options.debug_io);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};

    // Build a payload mirroring what a HashiCorp-style release contains:
    // a single executable at the archive root, no nested directory. The
    // binary-finding walker in the tap-install path depends on exactly
    // this shape.
    {
        const f = try dir.createFile(std.Options.debug_io, "terraform", .{ .permissions = std.Io.File.Permissions.fromMode(0o755) });
        try f.writeStreamingAll(std.Options.debug_io, "#!/bin/sh\necho hi\n");
        f.close(std.Options.debug_io);
    }
    const archive_path = base ++ "/payload.zip";
    try runCmd(&.{ "zip", "-j", "-q", archive_path, base ++ "/terraform" });
    try test_io.deleteFileAbsolute(std.Options.debug_io, base ++ "/terraform");

    var threaded = spawnIo();
    defer threaded.deinit();
    try archive.extractZip(threaded.io(), archive_path, base);

    const f = try dir.openFile(std.Options.debug_io, "terraform", .{});
    defer f.close(std.Options.debug_io);
    var buf: [32]u8 = undefined;
    const n = try f.readPositionalAll(std.Options.debug_io, &buf, 0);
    try testing.expect(n > 0);
    try testing.expect(std.mem.startsWith(u8, buf[0..n], "#!/bin/sh"));
}

test "extractZip rejects a non-zip archive" {
    const base = "/tmp/malt_archive_zip_badmagic";
    var dir = try resetDir(base);
    defer dir.close(std.Options.debug_io);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};

    const archive_path = base ++ "/payload.zip";
    const f = try test_io.createFileAbsolute(std.Options.debug_io, archive_path, .{});
    try f.writeStreamingAll(std.Options.debug_io, "NOPE, not a zip");
    f.close(std.Options.debug_io);

    try testing.expectError(error.ExtractionFailed, archive.extractZip(std.Options.debug_io, archive_path, base));
}

test "extractZip rejects a missing archive" {
    const base = "/tmp/malt_archive_zip_missing";
    var dir = try resetDir(base);
    defer dir.close(std.Options.debug_io);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};

    try testing.expectError(error.ExtractionFailed, archive.extractZip(std.Options.debug_io, base ++ "/nope.zip", base));
}

// tar-slip: pre-scan must reject the whole archive before any entry
// lands. `-s` rewrites bad.txt's header name to `../escape.txt` so the
// tarball claims a path outside dest. good.txt comes first in tar
// order — if the extractor streamed entries it would write good.txt
// before hitting the bad one, which the test forbids.
test "extractTarGz rejects tar-slip and leaves dest untouched" {
    const base = "/tmp/malt_archive_tarslip_targz";
    test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};
    try test_io.makeDirAbsolute(std.Options.debug_io, base);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};
    const dest = base ++ "/dest";
    try test_io.makeDirAbsolute(std.Options.debug_io, dest);

    const src_dir = base ++ "/src";
    try test_io.makeDirAbsolute(std.Options.debug_io, src_dir);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, src_dir ++ "/good.txt", .{});
        try f.writeStreamingAll(std.Options.debug_io, "safe");
        f.close(std.Options.debug_io);
    }
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, src_dir ++ "/bad.txt", .{});
        try f.writeStreamingAll(std.Options.debug_io, "hostile");
        f.close(std.Options.debug_io);
    }

    const archive_path = base ++ "/hostile.tar.gz";
    try runCmd(&.{ "tar", "czf", archive_path, "-C", src_dir, "-s", "|^bad.txt|../escape.txt|", "good.txt", "bad.txt" });

    try testing.expectError(error.ExtractionFailed, archive.extractTarGz(std.Options.debug_io, archive_path, dest));
    try testing.expectError(error.FileNotFound, test_io.accessAbsolute(std.Options.debug_io, dest ++ "/good.txt", .{}));
    try testing.expectError(error.FileNotFound, test_io.accessAbsolute(std.Options.debug_io, base ++ "/escape.txt", .{}));
}

// tar-slip for zip: macOS `zip` normalises `..` out at creation, so
// we lean on python3's zipfile to emit the entry name verbatim.
test "extractZip rejects tar-slip and leaves dest untouched" {
    const base = "/tmp/malt_archive_tarslip_zip";
    test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};
    try test_io.makeDirAbsolute(std.Options.debug_io, base);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};
    const dest = base ++ "/dest";
    try test_io.makeDirAbsolute(std.Options.debug_io, dest);

    const archive_path = base ++ "/hostile.zip";
    const script = "import zipfile\n" ++
        "with zipfile.ZipFile('" ++ archive_path ++ "', 'w') as z:\n" ++
        "    z.writestr('good.txt', b'safe')\n" ++
        "    z.writestr('../escape.txt', b'hostile')\n";
    try runCmd(&.{ "python3", "-c", script });

    var threaded = spawnIo();
    defer threaded.deinit();
    try testing.expectError(error.ExtractionFailed, archive.extractZip(threaded.io(), archive_path, dest));
    try testing.expectError(error.FileNotFound, test_io.accessAbsolute(std.Options.debug_io, dest ++ "/good.txt", .{}));
    try testing.expectError(error.FileNotFound, test_io.accessAbsolute(std.Options.debug_io, base ++ "/escape.txt", .{}));
}

test "extractTarXzFile rejects tar-slip and leaves dest untouched" {
    const base = "/tmp/malt_archive_tarslip_tarxz";
    test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};
    try test_io.makeDirAbsolute(std.Options.debug_io, base);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};
    const dest = base ++ "/dest";
    try test_io.makeDirAbsolute(std.Options.debug_io, dest);

    const src_dir = base ++ "/src";
    try test_io.makeDirAbsolute(std.Options.debug_io, src_dir);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, src_dir ++ "/good.txt", .{});
        try f.writeStreamingAll(std.Options.debug_io, "safe");
        f.close(std.Options.debug_io);
    }
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, src_dir ++ "/bad.txt", .{});
        try f.writeStreamingAll(std.Options.debug_io, "hostile");
        f.close(std.Options.debug_io);
    }

    const archive_path = base ++ "/hostile.tar.xz";
    try runCmd(&.{ "tar", "cJf", archive_path, "-C", src_dir, "-s", "|^bad.txt|../escape.txt|", "good.txt", "bad.txt" });

    var threaded = spawnIo();
    defer threaded.deinit();
    try testing.expectError(error.ExtractionFailed, archive.extractTarXzFile(threaded.io(), archive_path, dest));
    try testing.expectError(error.FileNotFound, test_io.accessAbsolute(std.Options.debug_io, dest ++ "/good.txt", .{}));
    try testing.expectError(error.FileNotFound, test_io.accessAbsolute(std.Options.debug_io, base ++ "/escape.txt", .{}));
}

test "extractTarGz rejects a symlink entry whose target escapes dest" {
    const base = "/tmp/malt_archive_tarslip_targz_symlink";
    test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};
    try test_io.makeDirAbsolute(std.Options.debug_io, base);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};
    const dest = base ++ "/dest";
    try test_io.makeDirAbsolute(std.Options.debug_io, dest);

    const src_dir = base ++ "/src";
    try test_io.makeDirAbsolute(std.Options.debug_io, src_dir);
    try test_io.symLinkAbsolute(std.Options.debug_io, "/etc/passwd", src_dir ++ "/badlink", .{});

    const archive_path = base ++ "/sym.tar.gz";
    try runCmd(&.{ "tar", "czf", archive_path, "-C", src_dir, "badlink" });

    try testing.expectError(error.ExtractionFailed, archive.extractTarGz(std.Options.debug_io, archive_path, dest));
    try testing.expectError(error.FileNotFound, test_io.accessAbsolute(std.Options.debug_io, dest ++ "/badlink", .{}));
}

test "isSafeEntryPath rejects escape paths" {
    try testing.expect(archive.isSafeEntryPath("a/b/c"));
    try testing.expect(archive.isSafeEntryPath("./ok"));
    try testing.expect(archive.isSafeEntryPath("a/./b"));
    try testing.expect(archive.isSafeEntryPath("deep/dir/"));
    try testing.expect(!archive.isSafeEntryPath(""));
    try testing.expect(!archive.isSafeEntryPath("/abs/path"));
    try testing.expect(!archive.isSafeEntryPath("../escape"));
    try testing.expect(!archive.isSafeEntryPath("a/../b"));
    try testing.expect(!archive.isSafeEntryPath("a/b/.."));
    try testing.expect(!archive.isSafeEntryPath("..\x00"));
    try testing.expect(!archive.isSafeEntryPath("ok\x00evil"));
}

test "isSafeSymlinkTarget: accepts intra-bundle relative targets" {
    // The llvm@21 / .xctoolchain shape: ../../../bin from a 5-deep dir
    // resolves to a sibling at depth 2 — safely inside the extraction root.
    try testing.expect(archive.isSafeSymlinkTarget(
        "llvm@21/21.1.8/Toolchains/LLVM21.1.8.xctoolchain/usr/bin",
        "../../../bin",
    ));
    // Sibling next to the symlink (the common bottle shape).
    try testing.expect(archive.isSafeSymlinkTarget("a/b/link", "sibling"));
    // Up one level into a sibling subtree.
    try testing.expect(archive.isSafeSymlinkTarget("a/b/c/link", "../d"));
    // `.` and empty components are no-ops.
    try testing.expect(archive.isSafeSymlinkTarget("a/b/link", "./c/./d"));
}

test "isSafeSymlinkTarget: accepts prefix-relative targets one level above root" {
    // Rust bottle shape: 7 ../ from a 6-deep parent lands in the prefix
    // parent and descends into the sibling formula's opt path.
    try testing.expect(archive.isSafeSymlinkTarget(
        "rust/1.95.0/lib/rustlib/aarch64-apple-darwin/bin/rust-objcopy",
        "../../../../../../../opt/llvm/bin/llvm-objcopy",
    ));
    // Minimum case: top-level entry climbing exactly to the prefix parent.
    try testing.expect(archive.isSafeSymlinkTarget("link", "../opt/sibling"));
    // Deep entry whose `..` run lands at the prefix parent, then descends.
    try testing.expect(archive.isSafeSymlinkTarget(
        "a/b/c/link",
        "../../../../etc/shared",
    ));
}

test "isSafeSymlinkTarget: rejects targets that climb beyond the prefix parent" {
    // +2 from a top-level entry — one step past the prefix parent.
    try testing.expect(!archive.isSafeSymlinkTarget("link", "../../escape"));
    // +2 from a deeper entry: 5 `..` from parent_depth 3 underflows by two.
    try testing.expect(!archive.isSafeSymlinkTarget(
        "a/b/c/link",
        "../../../../../etc",
    ));
    // Mid-path overshoot: pops past the prefix parent before climbing back.
    try testing.expect(!archive.isSafeSymlinkTarget("a/link", "../../../oops/back"));
}

test "isSafeSymlinkTarget: rejects absolute, empty, and NUL-bearing targets" {
    try testing.expect(!archive.isSafeSymlinkTarget("a/b/link", "/etc/passwd"));
    try testing.expect(!archive.isSafeSymlinkTarget("a/b/link", ""));
    try testing.expect(!archive.isSafeSymlinkTarget("a/b/link", "ok\x00evil"));
}

test "extractTarGz accepts a symlink whose relative target stays inside dest" {
    // Mirrors the llvm@21 bottle layout: a deep symlink whose `..`-only
    // target resolves to a sibling within the extracted tree. Rejecting
    // these would break every Homebrew bottle that ships xctoolchain-style
    // cross-dir links.
    const base = "/tmp/malt_archive_targz_intra_symlink";
    test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};
    try test_io.makeDirAbsolute(std.Options.debug_io, base);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};

    const src_root = base ++ "/src";
    try test_io.makeDirAbsolute(std.Options.debug_io, src_root);
    var src_dir = try test_io.openDirAbsolute(std.Options.debug_io, src_root, .{});
    defer {
        var sd = src_dir;
        sd.close(std.Options.debug_io);
    }
    try src_dir.createDirPath(std.Options.debug_io, "bin");
    try src_dir.createDirPath(std.Options.debug_io, "Toolchains/x.xctoolchain/usr");
    {
        const f = try src_dir.createFile(std.Options.debug_io, "bin/llvm-tool", .{});
        try f.writeStreamingAll(std.Options.debug_io, "#!/bin/sh\n");
        f.close(std.Options.debug_io);
    }
    // Symlink target uses `..` to point at the sibling `bin` dir — exactly
    // the shape Apple .xctoolchain bundles ship with.
    var usr_dir = try src_dir.openDir(std.Options.debug_io, "Toolchains/x.xctoolchain/usr", .{});
    defer {
        var ud = usr_dir;
        ud.close(std.Options.debug_io);
    }
    try usr_dir.symLink(std.Options.debug_io, "../../../bin", "bin", .{});

    const archive_path = base ++ "/payload.tar.gz";
    try runTar(&.{ "tar", "czf", archive_path, "-C", base, "src" });
    try test_io.deleteTreeAbsolute(std.Options.debug_io, src_root);

    try archive.extractTarGz(std.Options.debug_io, archive_path, base);

    var link_buf: [64]u8 = undefined;
    var dest_dir = try test_io.openDirAbsolute(std.Options.debug_io, base, .{});
    defer {
        var dd = dest_dir;
        dd.close(std.Options.debug_io);
    }
    const target_len = try dest_dir.readLink(std.Options.debug_io, "src/Toolchains/x.xctoolchain/usr/bin", &link_buf);
    try testing.expectEqualStrings("../../../bin", link_buf[0..target_len]);
}
