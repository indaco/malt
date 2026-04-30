//! malt — fs/archive tests
//! Covers extractTarGz happy/error paths and extractTarXzFile happy path.

const std = @import("std");
const malt = @import("malt");
const testing = std.testing;
const archive = @import("malt").archive;

fn resetDir(path: []const u8) !std.Io.Dir {
    malt.fs_compat.deleteTreeAbsolute(path) catch {};
    try malt.fs_compat.makeDirAbsolute(path);
    return malt.fs_compat.openDirAbsolute(path, .{});
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
    defer dir.close(malt.io_mod.ctx());
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};

    // Build a simple payload: base/src/hello.txt
    try dir.createDirPath(malt.io_mod.ctx(), "src");
    {
        const f = try dir.createFile(malt.io_mod.ctx(), "src/hello.txt", .{});
        try f.writeStreamingAll(malt.io_mod.ctx(), "hi");
        f.close(malt.io_mod.ctx());
    }

    const archive_path = base ++ "/payload.tar.gz";
    try runTar(&.{ "tar", "czf", archive_path, "-C", base, "src" });

    // Remove the src dir so we can observe extraction re-creating it.
    try malt.fs_compat.deleteTreeAbsolute(base ++ "/src");

    try archive.extractTarGz(std.Options.debug_io, archive_path, base);

    const f = try dir.openFile(malt.io_mod.ctx(), "src/hello.txt", .{});
    defer f.close(malt.io_mod.ctx());
    var out: [8]u8 = undefined;
    const n = try f.readPositionalAll(malt.io_mod.ctx(), &out, 0);
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
        try f.writeStreamingAll(malt.io_mod.ctx(), "#!/bin/sh\n");
        f.close(malt.io_mod.ctx());
    }
    const archive_path = src_dir ++ "/tap_download.tar.gz";
    try runTar(&.{ "tar", "czf", archive_path, "-C", src_dir, "payload" });

    try archive.extractTarGz(std.Options.debug_io, archive_path, dest_dir);

    // The payload landed in dest_dir, not next to the archive.
    const f = try malt.fs_compat.openFileAbsolute(dest_dir ++ "/payload/bin", .{});
    defer f.close(malt.io_mod.ctx());
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
    defer dir.close(malt.io_mod.ctx());
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};

    // Build the source tree to tar up: an executable, a deep file, and
    // a relative symlink pointing at the executable.
    const src_root = base ++ "/src";
    try malt.fs_compat.makeDirAbsolute(src_root);
    try dir.createDirPath(malt.io_mod.ctx(), "src/bin");
    try dir.createDirPath(malt.io_mod.ctx(), "src/a/b/c/d/e/f");
    {
        const f = try dir.createFile(malt.io_mod.ctx(), "src/bin/hello", .{ .permissions = std.Io.File.Permissions.fromMode(0o755) });
        try f.writeStreamingAll(malt.io_mod.ctx(), "#!/bin/sh\necho hi\n");
        f.close(malt.io_mod.ctx());
    }
    {
        const f = try dir.createFile(malt.io_mod.ctx(), "src/a/b/c/d/e/f/deep.txt", .{});
        try f.writeStreamingAll(malt.io_mod.ctx(), "deep");
        f.close(malt.io_mod.ctx());
    }
    // Relative symlink sitting next to the executable, pointing at it
    // by basename — the usual bottle shape.
    const src_subdir = try dir.openDir(malt.io_mod.ctx(), "src/bin", .{});
    defer {
        var m = src_subdir;
        m.close(malt.io_mod.ctx());
    }
    try src_subdir.symLink(malt.io_mod.ctx(), "hello", "hello_link", .{});

    // Tar it up; GNU/BSD tar both preserve exec bits and symlinks by
    // default, so the round-trip through our native extractor is the
    // thing under test, not tar's archive-building behaviour.
    const archive_path = base ++ "/payload.tar.gz";
    try runTar(&.{ "tar", "czf", archive_path, "-C", base, "src" });

    // Nuke the source tree so observed state after extract can only
    // come from our extractor.
    try malt.fs_compat.deleteTreeAbsolute(src_root);

    try archive.extractTarGz(std.Options.debug_io, archive_path, base);

    // Exec bit preserved (tar.ExtractOptions.ModeMode.executable_bit_only
    // is the default — owner-x copied to group/other).
    const st = try dir.statFile(malt.io_mod.ctx(), "src/bin/hello", .{});
    const mode = st.permissions.toMode();
    try testing.expect(mode & 0o111 != 0);

    // Symlink extracted as a link, not a copy — readLink succeeds and
    // returns the original relative target.
    var link_buf: [64]u8 = undefined;
    const target_len = try dir.readLink(malt.io_mod.ctx(), "src/bin/hello_link", &link_buf);
    try testing.expectEqualStrings("hello", link_buf[0..target_len]);

    // Deep nested path reached intact.
    const deep = try dir.openFile(malt.io_mod.ctx(), "src/a/b/c/d/e/f/deep.txt", .{});
    defer deep.close(malt.io_mod.ctx());
    var buf: [8]u8 = undefined;
    const n = try deep.readPositionalAll(malt.io_mod.ctx(), &buf, 0);
    try testing.expectEqualStrings("deep", buf[0..n]);
}

test "extractTarGz rejects a non-gzip archive" {
    const base = "/tmp/malt_archive_targz_badmagic";
    var dir = try resetDir(base);
    defer dir.close(malt.io_mod.ctx());
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};

    // Write an archive file with wrong magic bytes.
    const archive_path = base ++ "/payload.tar.gz";
    const f = try malt.fs_compat.createFileAbsolute(archive_path, .{});
    try f.writeStreamingAll(malt.io_mod.ctx(), "NOPE, not gzip");
    f.close(malt.io_mod.ctx());

    try testing.expectError(error.ExtractionFailed, archive.extractTarGz(std.Options.debug_io, archive_path, base));
}

test "extractTarGz rejects a missing archive" {
    const base = "/tmp/malt_archive_targz_missing";
    var dir = try resetDir(base);
    defer dir.close(malt.io_mod.ctx());
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};

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
    defer dir.close(malt.io_mod.ctx());
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};

    // Build a payload mirroring what a HashiCorp-style release contains:
    // a single executable at the archive root, no nested directory. The
    // binary-finding walker in the tap-install path depends on exactly
    // this shape.
    {
        const f = try dir.createFile(malt.io_mod.ctx(), "terraform", .{ .permissions = std.Io.File.Permissions.fromMode(0o755) });
        try f.writeStreamingAll(malt.io_mod.ctx(), "#!/bin/sh\necho hi\n");
        f.close(malt.io_mod.ctx());
    }
    const archive_path = base ++ "/payload.zip";
    try runCmd(&.{ "zip", "-j", "-q", archive_path, base ++ "/terraform" });
    try malt.fs_compat.deleteFileAbsolute(base ++ "/terraform");

    var threaded = spawnIo();
    defer threaded.deinit();
    try archive.extractZip(threaded.io(), archive_path, base);

    const f = try dir.openFile(malt.io_mod.ctx(), "terraform", .{});
    defer f.close(malt.io_mod.ctx());
    var buf: [32]u8 = undefined;
    const n = try f.readPositionalAll(malt.io_mod.ctx(), &buf, 0);
    try testing.expect(n > 0);
    try testing.expect(std.mem.startsWith(u8, buf[0..n], "#!/bin/sh"));
}

test "extractZip rejects a non-zip archive" {
    const base = "/tmp/malt_archive_zip_badmagic";
    var dir = try resetDir(base);
    defer dir.close(malt.io_mod.ctx());
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};

    const archive_path = base ++ "/payload.zip";
    const f = try malt.fs_compat.createFileAbsolute(archive_path, .{});
    try f.writeStreamingAll(malt.io_mod.ctx(), "NOPE, not a zip");
    f.close(malt.io_mod.ctx());

    try testing.expectError(error.ExtractionFailed, archive.extractZip(std.Options.debug_io, archive_path, base));
}

test "extractZip rejects a missing archive" {
    const base = "/tmp/malt_archive_zip_missing";
    var dir = try resetDir(base);
    defer dir.close(malt.io_mod.ctx());
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};

    try testing.expectError(error.ExtractionFailed, archive.extractZip(std.Options.debug_io, base ++ "/nope.zip", base));
}

// tar-slip: pre-scan must reject the whole archive before any entry
// lands. `-s` rewrites bad.txt's header name to `../escape.txt` so the
// tarball claims a path outside dest. good.txt comes first in tar
// order — if the extractor streamed entries it would write good.txt
// before hitting the bad one, which the test forbids.
test "extractTarGz rejects tar-slip and leaves dest untouched" {
    const base = "/tmp/malt_archive_tarslip_targz";
    malt.fs_compat.deleteTreeAbsolute(base) catch {};
    try malt.fs_compat.makeDirAbsolute(base);
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};
    const dest = base ++ "/dest";
    try malt.fs_compat.makeDirAbsolute(dest);

    const src_dir = base ++ "/src";
    try malt.fs_compat.makeDirAbsolute(src_dir);
    {
        const f = try malt.fs_compat.createFileAbsolute(src_dir ++ "/good.txt", .{});
        try f.writeStreamingAll(malt.io_mod.ctx(), "safe");
        f.close(malt.io_mod.ctx());
    }
    {
        const f = try malt.fs_compat.createFileAbsolute(src_dir ++ "/bad.txt", .{});
        try f.writeStreamingAll(malt.io_mod.ctx(), "hostile");
        f.close(malt.io_mod.ctx());
    }

    const archive_path = base ++ "/hostile.tar.gz";
    try runCmd(&.{ "tar", "czf", archive_path, "-C", src_dir, "-s", "|^bad.txt|../escape.txt|", "good.txt", "bad.txt" });

    try testing.expectError(error.ExtractionFailed, archive.extractTarGz(std.Options.debug_io, archive_path, dest));
    try testing.expectError(error.FileNotFound, malt.fs_compat.accessAbsolute(dest ++ "/good.txt", .{}));
    try testing.expectError(error.FileNotFound, malt.fs_compat.accessAbsolute(base ++ "/escape.txt", .{}));
}

// tar-slip for zip: macOS `zip` normalises `..` out at creation, so
// we lean on python3's zipfile to emit the entry name verbatim.
test "extractZip rejects tar-slip and leaves dest untouched" {
    const base = "/tmp/malt_archive_tarslip_zip";
    malt.fs_compat.deleteTreeAbsolute(base) catch {};
    try malt.fs_compat.makeDirAbsolute(base);
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};
    const dest = base ++ "/dest";
    try malt.fs_compat.makeDirAbsolute(dest);

    const archive_path = base ++ "/hostile.zip";
    const script = "import zipfile\n" ++
        "with zipfile.ZipFile('" ++ archive_path ++ "', 'w') as z:\n" ++
        "    z.writestr('good.txt', b'safe')\n" ++
        "    z.writestr('../escape.txt', b'hostile')\n";
    try runCmd(&.{ "python3", "-c", script });

    var threaded = spawnIo();
    defer threaded.deinit();
    try testing.expectError(error.ExtractionFailed, archive.extractZip(threaded.io(), archive_path, dest));
    try testing.expectError(error.FileNotFound, malt.fs_compat.accessAbsolute(dest ++ "/good.txt", .{}));
    try testing.expectError(error.FileNotFound, malt.fs_compat.accessAbsolute(base ++ "/escape.txt", .{}));
}

test "extractTarXzFile rejects tar-slip and leaves dest untouched" {
    const base = "/tmp/malt_archive_tarslip_tarxz";
    malt.fs_compat.deleteTreeAbsolute(base) catch {};
    try malt.fs_compat.makeDirAbsolute(base);
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};
    const dest = base ++ "/dest";
    try malt.fs_compat.makeDirAbsolute(dest);

    const src_dir = base ++ "/src";
    try malt.fs_compat.makeDirAbsolute(src_dir);
    {
        const f = try malt.fs_compat.createFileAbsolute(src_dir ++ "/good.txt", .{});
        try f.writeStreamingAll(malt.io_mod.ctx(), "safe");
        f.close(malt.io_mod.ctx());
    }
    {
        const f = try malt.fs_compat.createFileAbsolute(src_dir ++ "/bad.txt", .{});
        try f.writeStreamingAll(malt.io_mod.ctx(), "hostile");
        f.close(malt.io_mod.ctx());
    }

    const archive_path = base ++ "/hostile.tar.xz";
    try runCmd(&.{ "tar", "cJf", archive_path, "-C", src_dir, "-s", "|^bad.txt|../escape.txt|", "good.txt", "bad.txt" });

    var threaded = spawnIo();
    defer threaded.deinit();
    try testing.expectError(error.ExtractionFailed, archive.extractTarXzFile(threaded.io(), archive_path, dest));
    try testing.expectError(error.FileNotFound, malt.fs_compat.accessAbsolute(dest ++ "/good.txt", .{}));
    try testing.expectError(error.FileNotFound, malt.fs_compat.accessAbsolute(base ++ "/escape.txt", .{}));
}

test "extractTarGz rejects a symlink entry whose target escapes dest" {
    const base = "/tmp/malt_archive_tarslip_targz_symlink";
    malt.fs_compat.deleteTreeAbsolute(base) catch {};
    try malt.fs_compat.makeDirAbsolute(base);
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};
    const dest = base ++ "/dest";
    try malt.fs_compat.makeDirAbsolute(dest);

    const src_dir = base ++ "/src";
    try malt.fs_compat.makeDirAbsolute(src_dir);
    try malt.fs_compat.symLinkAbsolute("/etc/passwd", src_dir ++ "/badlink", .{});

    const archive_path = base ++ "/sym.tar.gz";
    try runCmd(&.{ "tar", "czf", archive_path, "-C", src_dir, "badlink" });

    try testing.expectError(error.ExtractionFailed, archive.extractTarGz(std.Options.debug_io, archive_path, dest));
    try testing.expectError(error.FileNotFound, malt.fs_compat.accessAbsolute(dest ++ "/badlink", .{}));
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
    malt.fs_compat.deleteTreeAbsolute(base) catch {};
    try malt.fs_compat.makeDirAbsolute(base);
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};

    const src_root = base ++ "/src";
    try malt.fs_compat.makeDirAbsolute(src_root);
    var src_dir = try malt.fs_compat.openDirAbsolute(src_root, .{});
    defer {
        var sd = src_dir;
        sd.close(malt.io_mod.ctx());
    }
    try src_dir.createDirPath(malt.io_mod.ctx(), "bin");
    try src_dir.createDirPath(malt.io_mod.ctx(), "Toolchains/x.xctoolchain/usr");
    {
        const f = try src_dir.createFile(malt.io_mod.ctx(), "bin/llvm-tool", .{});
        try f.writeStreamingAll(malt.io_mod.ctx(), "#!/bin/sh\n");
        f.close(malt.io_mod.ctx());
    }
    // Symlink target uses `..` to point at the sibling `bin` dir — exactly
    // the shape Apple .xctoolchain bundles ship with.
    var usr_dir = try src_dir.openDir(malt.io_mod.ctx(), "Toolchains/x.xctoolchain/usr", .{});
    defer {
        var ud = usr_dir;
        ud.close(malt.io_mod.ctx());
    }
    try usr_dir.symLink(malt.io_mod.ctx(), "../../../bin", "bin", .{});

    const archive_path = base ++ "/payload.tar.gz";
    try runTar(&.{ "tar", "czf", archive_path, "-C", base, "src" });
    try malt.fs_compat.deleteTreeAbsolute(src_root);

    try archive.extractTarGz(std.Options.debug_io, archive_path, base);

    var link_buf: [64]u8 = undefined;
    var dest_dir = try malt.fs_compat.openDirAbsolute(base, .{});
    defer {
        var dd = dest_dir;
        dd.close(malt.io_mod.ctx());
    }
    const target_len = try dest_dir.readLink(malt.io_mod.ctx(), "src/Toolchains/x.xctoolchain/usr/bin", &link_buf);
    try testing.expectEqualStrings("../../../bin", link_buf[0..target_len]);
}
