//! malt — fs/archive tests
//! Covers extractTarGz happy/error paths and extractTarXzFile happy path.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const archive = @import("malt").archive;

/// Per-test scratch tree under a process-unique base, so overlapping test
/// runs cannot wipe each other's fixtures.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    base: []const u8,
    dir: std.Io.Dir,

    fn init(tag: []const u8) !Fixture {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const base = try test_io.uniqueTempPath(arena.allocator(), "archive", tag);
        test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};
        try test_io.makeDirAbsolute(std.Options.debug_io, base);
        return .{
            .arena = arena,
            .base = base,
            .dir = try test_io.openDirAbsolute(std.Options.debug_io, base, .{}),
        };
    }

    /// Absolute path to `sub` inside the fixture; valid until `deinit`.
    fn p(self: *Fixture, sub: []const u8) []const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "{s}/{s}", .{ self.base, sub }) catch @panic("OOM");
    }

    fn deinit(self: *Fixture) void {
        self.dir.close(std.Options.debug_io);
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.base) catch {};
        self.arena.deinit();
    }
};

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
    var fx = try Fixture.init("targz_ok");
    defer fx.deinit();

    // Build a simple payload: base/src/hello.txt
    try fx.dir.createDirPath(std.Options.debug_io, "src");
    {
        const f = try fx.dir.createFile(std.Options.debug_io, "src/hello.txt", .{});
        try f.writeStreamingAll(std.Options.debug_io, "hi");
        f.close(std.Options.debug_io);
    }

    const archive_path = fx.p("payload.tar.gz");
    try runTar(&.{ "tar", "czf", archive_path, "-C", fx.base, "src" });

    // Remove the src dir so we can observe extraction re-creating it.
    try test_io.deleteTreeAbsolute(std.Options.debug_io, fx.p("src"));

    try archive.extractTarGz(std.Options.debug_io, archive_path, fx.base);

    const f = try fx.dir.openFile(std.Options.debug_io, "src/hello.txt", .{});
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
    var fx = try Fixture.init("targz_split");
    defer fx.deinit();
    const src_dir = fx.p("src");
    const dest_dir = fx.p("dest");
    try test_io.makeDirAbsolute(std.Options.debug_io, src_dir);
    try test_io.makeDirAbsolute(std.Options.debug_io, dest_dir);

    // Build payload in src_dir and tarball it into src_dir/tap_download.tar.gz.
    try test_io.makeDirAbsolute(std.Options.debug_io, fx.p("src/payload"));
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, fx.p("src/payload/bin"), .{});
        try f.writeStreamingAll(std.Options.debug_io, "#!/bin/sh\n");
        f.close(std.Options.debug_io);
    }
    const archive_path = fx.p("src/tap_download.tar.gz");
    try runTar(&.{ "tar", "czf", archive_path, "-C", src_dir, "payload" });

    try archive.extractTarGz(std.Options.debug_io, archive_path, dest_dir);

    // The payload landed in dest_dir, not next to the archive.
    const f = try test_io.openFileAbsolute(std.Options.debug_io, fx.p("dest/payload/bin"), .{});
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
    var fx = try Fixture.init("targz_perms");
    defer fx.deinit();

    // Build the source tree to tar up: an executable, a deep file, and
    // a relative symlink pointing at the executable.
    const src_root = fx.p("src");
    try test_io.makeDirAbsolute(std.Options.debug_io, src_root);
    try fx.dir.createDirPath(std.Options.debug_io, "src/bin");
    try fx.dir.createDirPath(std.Options.debug_io, "src/a/b/c/d/e/f");
    {
        const f = try fx.dir.createFile(std.Options.debug_io, "src/bin/hello", .{ .permissions = std.Io.File.Permissions.fromMode(0o755) });
        try f.writeStreamingAll(std.Options.debug_io, "#!/bin/sh\necho hi\n");
        f.close(std.Options.debug_io);
    }
    {
        const f = try fx.dir.createFile(std.Options.debug_io, "src/a/b/c/d/e/f/deep.txt", .{});
        try f.writeStreamingAll(std.Options.debug_io, "deep");
        f.close(std.Options.debug_io);
    }
    // Relative symlink sitting next to the executable, pointing at it
    // by basename — the usual bottle shape.
    const src_subdir = try fx.dir.openDir(std.Options.debug_io, "src/bin", .{});
    defer {
        var m = src_subdir;
        m.close(std.Options.debug_io);
    }
    try src_subdir.symLink(std.Options.debug_io, "hello", "hello_link", .{});

    // Tar it up; GNU/BSD tar both preserve exec bits and symlinks by
    // default, so the round-trip through our native extractor is the
    // thing under test, not tar's archive-building behaviour.
    const archive_path = fx.p("payload.tar.gz");
    try runTar(&.{ "tar", "czf", archive_path, "-C", fx.base, "src" });

    // Nuke the source tree so observed state after extract can only
    // come from our extractor.
    try test_io.deleteTreeAbsolute(std.Options.debug_io, src_root);

    try archive.extractTarGz(std.Options.debug_io, archive_path, fx.base);

    // Exec bit preserved (tar.ExtractOptions.ModeMode.executable_bit_only
    // is the default — owner-x copied to group/other).
    const st = try fx.dir.statFile(std.Options.debug_io, "src/bin/hello", .{});
    const mode = st.permissions.toMode();
    try testing.expect(mode & 0o111 != 0);

    // Symlink extracted as a link, not a copy — readLink succeeds and
    // returns the original relative target.
    var link_buf: [64]u8 = undefined;
    const target_len = try fx.dir.readLink(std.Options.debug_io, "src/bin/hello_link", &link_buf);
    try testing.expectEqualStrings("hello", link_buf[0..target_len]);

    // Deep nested path reached intact.
    const deep = try fx.dir.openFile(std.Options.debug_io, "src/a/b/c/d/e/f/deep.txt", .{});
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
    var fx = try Fixture.init("targz_hardlink");
    defer fx.deinit();

    // Build payload: src/bin/primary holds 'pri', src/bin/aliased is a
    // hard link to primary. We use `ln` (not `ln -s`) so tar records a
    // type-'1' header; with `ln -s` it would be a symlink instead.
    try fx.dir.createDirPath(std.Options.debug_io, "src/bin");
    {
        const f = try fx.dir.createFile(std.Options.debug_io, "src/bin/primary", .{
            .permissions = std.Io.File.Permissions.fromMode(0o755),
        });
        try f.writeStreamingAll(std.Options.debug_io, "pri");
        f.close(std.Options.debug_io);
    }
    try runCmd(&.{ "ln", fx.p("src/bin/primary"), fx.p("src/bin/aliased") });

    const archive_path = fx.p("payload.tar.gz");
    try runTar(&.{ "tar", "czf", archive_path, "-C", fx.base, "src" });

    // Wipe so observed state can only come from our extractor.
    try test_io.deleteTreeAbsolute(std.Options.debug_io, fx.p("src"));

    try archive.extractTarGz(std.Options.debug_io, archive_path, fx.base);

    // Both names land on disk with the same content; that's necessary
    // for libdeflate-style multi-binary kegs to actually function.
    var buf: [8]u8 = undefined;
    {
        const f = try fx.dir.openFile(std.Options.debug_io, "src/bin/primary", .{});
        defer f.close(std.Options.debug_io);
        const n = try f.readPositionalAll(std.Options.debug_io, &buf, 0);
        try testing.expectEqualStrings("pri", buf[0..n]);
    }
    {
        const f = try fx.dir.openFile(std.Options.debug_io, "src/bin/aliased", .{});
        defer f.close(std.Options.debug_io);
        const n = try f.readPositionalAll(std.Options.debug_io, &buf, 0);
        try testing.expectEqualStrings("pri", buf[0..n]);
    }

    // Hard link semantics: same inode, link count >= 2. Confirms we did
    // a `link()` call rather than copying the bytes (which would defeat
    // the point of hard-link entries in the bottle and double the disk
    // footprint per multi-binary keg).
    const stat_a = try fx.dir.statFile(std.Options.debug_io, "src/bin/primary", .{});
    const stat_b = try fx.dir.statFile(std.Options.debug_io, "src/bin/aliased", .{});
    try testing.expectEqual(stat_a.inode, stat_b.inode);
    try testing.expect(stat_a.nlink >= 2);
}

// Tar's end-of-archive marker is a zero block. Anything past it - GNU
// tar pads to record-size with zeros, but homebrew-foreign producers
// occasionally append non-zero trailers - is not a tar header and must
// not be re-interpreted as one. Without the fix, the pre-scan would
// keep reading 512-byte chunks past the marker and fail validChksum on
// the first non-zero trailer, surfacing ExtractionFailed for archives
// the stock `tar xzf` would extract cleanly.
test "extractTarGz stops scanning at end-of-archive and ignores trailing garbage" {
    var fx = try Fixture.init("targz_eofgarbage");
    defer fx.deinit();

    try fx.dir.createDirPath(std.Options.debug_io, "src");
    {
        const f = try fx.dir.createFile(std.Options.debug_io, "src/legit.txt", .{});
        try f.writeStreamingAll(std.Options.debug_io, "ok");
        f.close(std.Options.debug_io);
    }

    // Uncompressed tar first - we need to splice garbage past the
    // end-of-archive zeros before re-compressing.
    const uncompressed = fx.p("payload.tar");
    try runTar(&.{ "tar", "cf", uncompressed, "-C", fx.base, "src" });

    // A single non-zero trailer is enough: the next 512-byte chunk read
    // by preScanTarGz is no longer all-zero, so a `continue` past the
    // first zero block would parse it as a header and trip the checksum.
    const append_garbage = try std.fmt.allocPrint(fx.arena.allocator(), "printf 'GARBAGE!' >> '{s}'", .{uncompressed});
    try runCmd(&.{ "sh", "-c", append_garbage });
    try runCmd(&.{ "gzip", "-f", uncompressed });

    // Wipe the source tree so observed state can only come from our extractor.
    try test_io.deleteTreeAbsolute(std.Options.debug_io, fx.p("src"));

    const archive_path = fx.p("payload.tar.gz");
    try archive.extractTarGz(std.Options.debug_io, archive_path, fx.base);

    const f = try fx.dir.openFile(std.Options.debug_io, "src/legit.txt", .{});
    defer f.close(std.Options.debug_io);
    var out: [8]u8 = undefined;
    const n = try f.readPositionalAll(std.Options.debug_io, &out, 0);
    try testing.expectEqualStrings("ok", out[0..n]);
}

// Hard-link entries are the *only* tar kind outside file/dir/symlink
// the extractor recovers. Every other unsupported kind (fifo, char/block
// special, sparse, contiguous) must still surface as ExtractionFailed
// so the install layer can route to its retry/abort policy. Locks in
// the diagnostics allow-list against accidental widening.
// Defensive guard: a tar entry can be a hard link whose target is
// itself a symbolic link. POSIX `link(2)` on Darwin/Linux does not
// follow symlinks, so the hard-linked alias must share the SYMLINK's
// inode (not the symlink's target inode). If this ever regressed,
// a hostile bottle could craft a hard-link-of-symlink pair to land
// an inode shared with a file the symlink dereferences to.
test "extractTarGz hard-link to a symlink shares the symlink inode, not the target" {
    var fx = try Fixture.init("targz_hardlink_symlink");
    defer fx.deinit();

    try fx.dir.createDirPath(std.Options.debug_io, "src");
    {
        const f = try fx.dir.createFile(std.Options.debug_io, "src/data.txt", .{});
        try f.writeStreamingAll(std.Options.debug_io, "data");
        f.close(std.Options.debug_io);
    }
    var src_dir = try fx.dir.openDir(std.Options.debug_io, "src", .{});
    defer {
        var sd = src_dir;
        sd.close(std.Options.debug_io);
    }
    try src_dir.symLink(std.Options.debug_io, "data.txt", "linkalias", .{});
    // `ln -P` forces a hard link to the symlink itself rather than
    // dereferencing - macOS BSD `ln` follows symlinks by default.
    try runCmd(&.{ "ln", "-P", fx.p("src/linkalias"), fx.p("src/link") });

    const archive_path = fx.p("payload.tar.gz");
    try runTar(&.{ "tar", "czf", archive_path, "-C", fx.base, "src" });

    try test_io.deleteTreeAbsolute(std.Options.debug_io, fx.p("src"));

    try archive.extractTarGz(std.Options.debug_io, archive_path, fx.base);

    // Both names readlink to the same symlink target. If link() had
    // dereferenced, one of the two would be a regular file with
    // 'data' as content - not a symlink at all.
    var link_buf: [64]u8 = undefined;
    var alias_buf: [64]u8 = undefined;
    const link_target_len = try fx.dir.readLink(std.Options.debug_io, "src/link", &link_buf);
    const alias_target_len = try fx.dir.readLink(std.Options.debug_io, "src/linkalias", &alias_buf);
    try testing.expectEqualStrings("data.txt", link_buf[0..link_target_len]);
    try testing.expectEqualStrings("data.txt", alias_buf[0..alias_target_len]);

    // Inode equality (no follow): link and linkalias share the symlink
    // inode; data.txt has its own. This is the security-relevant check.
    const link_stat = try fx.dir.statFile(std.Options.debug_io, "src/link", .{ .follow_symlinks = false });
    const alias_stat = try fx.dir.statFile(std.Options.debug_io, "src/linkalias", .{ .follow_symlinks = false });
    const data_stat = try fx.dir.statFile(std.Options.debug_io, "src/data.txt", .{ .follow_symlinks = false });
    try testing.expectEqual(link_stat.inode, alias_stat.inode);
    try testing.expect(data_stat.inode != link_stat.inode);
    try testing.expect(link_stat.nlink >= 2);
}

test "extractTarGz rejects an archive containing a fifo entry" {
    var fx = try Fixture.init("targz_fifo");
    defer fx.deinit();

    try fx.dir.createDirPath(std.Options.debug_io, "src");
    {
        const f = try fx.dir.createFile(std.Options.debug_io, "src/regular.txt", .{});
        try f.writeStreamingAll(std.Options.debug_io, "ok");
        f.close(std.Options.debug_io);
    }
    // mkfifo is what makes tar emit a type-'6' header; nothing in zig's
    // std lets us synthesise one without invoking the system tool.
    try runCmd(&.{ "mkfifo", fx.p("src/pipe") });

    const archive_path = fx.p("payload.tar.gz");
    try runTar(&.{ "tar", "czf", archive_path, "-C", fx.base, "src" });

    try test_io.deleteTreeAbsolute(std.Options.debug_io, fx.p("src"));

    try testing.expectError(error.ExtractionFailed, archive.extractTarGz(std.Options.debug_io, archive_path, fx.base));
}

test "extractTarGz rejects a non-gzip archive" {
    var fx = try Fixture.init("targz_badmagic");
    defer fx.deinit();

    // Write an archive file with wrong magic bytes.
    const archive_path = fx.p("payload.tar.gz");
    const f = try test_io.createFileAbsolute(std.Options.debug_io, archive_path, .{});
    try f.writeStreamingAll(std.Options.debug_io, "NOPE, not gzip");
    f.close(std.Options.debug_io);

    try testing.expectError(error.ExtractionFailed, archive.extractTarGz(std.Options.debug_io, archive_path, fx.base));
}

test "extractTarGz rejects a missing archive" {
    var fx = try Fixture.init("targz_missing");
    defer fx.deinit();

    try testing.expectError(error.ExtractionFailed, archive.extractTarGz(std.Options.debug_io, fx.p("nope.tar.gz"), fx.base));
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
    var fx = try Fixture.init("zip_ok");
    defer fx.deinit();

    // Build a payload mirroring what a HashiCorp-style release contains:
    // a single executable at the archive root, no nested directory. The
    // binary-finding walker in the tap-install path depends on exactly
    // this shape.
    {
        const f = try fx.dir.createFile(std.Options.debug_io, "terraform", .{ .permissions = std.Io.File.Permissions.fromMode(0o755) });
        try f.writeStreamingAll(std.Options.debug_io, "#!/bin/sh\necho hi\n");
        f.close(std.Options.debug_io);
    }
    const archive_path = fx.p("payload.zip");
    try runCmd(&.{ "zip", "-j", "-q", archive_path, fx.p("terraform") });
    try test_io.deleteFileAbsolute(std.Options.debug_io, fx.p("terraform"));

    var threaded = spawnIo();
    defer threaded.deinit();
    try archive.extractZip(threaded.io(), archive_path, fx.base);

    const f = try fx.dir.openFile(std.Options.debug_io, "terraform", .{});
    defer f.close(std.Options.debug_io);
    var buf: [32]u8 = undefined;
    const n = try f.readPositionalAll(std.Options.debug_io, &buf, 0);
    try testing.expect(n > 0);
    try testing.expect(std.mem.startsWith(u8, buf[0..n], "#!/bin/sh"));
}

test "extractZip rejects a non-zip archive" {
    var fx = try Fixture.init("zip_badmagic");
    defer fx.deinit();

    const archive_path = fx.p("payload.zip");
    const f = try test_io.createFileAbsolute(std.Options.debug_io, archive_path, .{});
    try f.writeStreamingAll(std.Options.debug_io, "NOPE, not a zip");
    f.close(std.Options.debug_io);

    try testing.expectError(error.ExtractionFailed, archive.extractZip(std.Options.debug_io, archive_path, fx.base));
}

test "extractZip rejects a missing archive" {
    var fx = try Fixture.init("zip_missing");
    defer fx.deinit();

    try testing.expectError(error.ExtractionFailed, archive.extractZip(std.Options.debug_io, fx.p("nope.zip"), fx.base));
}

// tar-slip: pre-scan must reject the whole archive before any entry
// lands. `-s` rewrites bad.txt's header name to `../escape.txt` so the
// tarball claims a path outside dest. good.txt comes first in tar
// order — if the extractor streamed entries it would write good.txt
// before hitting the bad one, which the test forbids.
test "extractTarGz rejects tar-slip and leaves dest untouched" {
    var fx = try Fixture.init("tarslip_targz");
    defer fx.deinit();
    const dest = fx.p("dest");
    try test_io.makeDirAbsolute(std.Options.debug_io, dest);

    const src_dir = fx.p("src");
    try test_io.makeDirAbsolute(std.Options.debug_io, src_dir);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, fx.p("src/good.txt"), .{});
        try f.writeStreamingAll(std.Options.debug_io, "safe");
        f.close(std.Options.debug_io);
    }
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, fx.p("src/bad.txt"), .{});
        try f.writeStreamingAll(std.Options.debug_io, "hostile");
        f.close(std.Options.debug_io);
    }

    const archive_path = fx.p("hostile.tar.gz");
    try runCmd(&.{ "tar", "czf", archive_path, "-C", src_dir, "-s", "|^bad.txt|../escape.txt|", "good.txt", "bad.txt" });

    try testing.expectError(error.ExtractionFailed, archive.extractTarGz(std.Options.debug_io, archive_path, dest));
    try testing.expectError(error.FileNotFound, test_io.accessAbsolute(std.Options.debug_io, fx.p("dest/good.txt"), .{}));
    try testing.expectError(error.FileNotFound, test_io.accessAbsolute(std.Options.debug_io, fx.p("escape.txt"), .{}));
}

// tar-slip for zip: macOS `zip` normalises `..` out at creation, so
// we lean on python3's zipfile to emit the entry name verbatim.
test "extractZip rejects tar-slip and leaves dest untouched" {
    var fx = try Fixture.init("tarslip_zip");
    defer fx.deinit();
    const dest = fx.p("dest");
    try test_io.makeDirAbsolute(std.Options.debug_io, dest);

    const archive_path = fx.p("hostile.zip");
    const script = try std.fmt.allocPrint(fx.arena.allocator(), "import zipfile\n" ++
        "with zipfile.ZipFile('{s}', 'w') as z:\n" ++
        "    z.writestr('good.txt', b'safe')\n" ++
        "    z.writestr('../escape.txt', b'hostile')\n", .{archive_path});
    try runCmd(&.{ "python3", "-c", script });

    var threaded = spawnIo();
    defer threaded.deinit();
    try testing.expectError(error.ExtractionFailed, archive.extractZip(threaded.io(), archive_path, dest));
    try testing.expectError(error.FileNotFound, test_io.accessAbsolute(std.Options.debug_io, fx.p("dest/good.txt"), .{}));
    try testing.expectError(error.FileNotFound, test_io.accessAbsolute(std.Options.debug_io, fx.p("escape.txt"), .{}));
}

test "extractTarXzFile rejects tar-slip and leaves dest untouched" {
    var fx = try Fixture.init("tarslip_tarxz");
    defer fx.deinit();
    const dest = fx.p("dest");
    try test_io.makeDirAbsolute(std.Options.debug_io, dest);

    const src_dir = fx.p("src");
    try test_io.makeDirAbsolute(std.Options.debug_io, src_dir);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, fx.p("src/good.txt"), .{});
        try f.writeStreamingAll(std.Options.debug_io, "safe");
        f.close(std.Options.debug_io);
    }
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, fx.p("src/bad.txt"), .{});
        try f.writeStreamingAll(std.Options.debug_io, "hostile");
        f.close(std.Options.debug_io);
    }

    const archive_path = fx.p("hostile.tar.xz");
    try runCmd(&.{ "tar", "cJf", archive_path, "-C", src_dir, "-s", "|^bad.txt|../escape.txt|", "good.txt", "bad.txt" });

    var threaded = spawnIo();
    defer threaded.deinit();
    try testing.expectError(error.ExtractionFailed, archive.extractTarXzFile(threaded.io(), archive_path, dest));
    try testing.expectError(error.FileNotFound, test_io.accessAbsolute(std.Options.debug_io, fx.p("dest/good.txt"), .{}));
    try testing.expectError(error.FileNotFound, test_io.accessAbsolute(std.Options.debug_io, fx.p("escape.txt"), .{}));
}

test "extractTarGz rejects a symlink entry whose target escapes dest" {
    var fx = try Fixture.init("tarslip_targz_symlink");
    defer fx.deinit();
    const dest = fx.p("dest");
    try test_io.makeDirAbsolute(std.Options.debug_io, dest);

    const src_dir = fx.p("src");
    try test_io.makeDirAbsolute(std.Options.debug_io, src_dir);
    try test_io.symLinkAbsolute(std.Options.debug_io, "/etc/passwd", fx.p("src/badlink"), .{});

    const archive_path = fx.p("sym.tar.gz");
    try runCmd(&.{ "tar", "czf", archive_path, "-C", src_dir, "badlink" });

    try testing.expectError(error.ExtractionFailed, archive.extractTarGz(std.Options.debug_io, archive_path, dest));
    try testing.expectError(error.FileNotFound, test_io.accessAbsolute(std.Options.debug_io, fx.p("dest/badlink"), .{}));
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
    var fx = try Fixture.init("targz_intra_symlink");
    defer fx.deinit();

    const src_root = fx.p("src");
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

    const archive_path = fx.p("payload.tar.gz");
    try runTar(&.{ "tar", "czf", archive_path, "-C", fx.base, "src" });
    try test_io.deleteTreeAbsolute(std.Options.debug_io, src_root);

    try archive.extractTarGz(std.Options.debug_io, archive_path, fx.base);

    var link_buf: [64]u8 = undefined;
    var dest_dir = try test_io.openDirAbsolute(std.Options.debug_io, fx.base, .{});
    defer {
        var dd = dest_dir;
        dd.close(std.Options.debug_io);
    }
    const target_len = try dest_dir.readLink(std.Options.debug_io, "src/Toolchains/x.xctoolchain/usr/bin", &link_buf);
    try testing.expectEqualStrings("../../../bin", link_buf[0..target_len]);
}
