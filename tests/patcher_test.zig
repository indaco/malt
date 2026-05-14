//! malt — patcher overflow-collection tests
//!
//! Covers `patchPathsCollecting`: the new entry point that replaces the
//! all-or-nothing `PathTooLong` behaviour of `patchPaths` with an outcome
//! that separates in-place rewrites from slots that need the fallback
//! path (install_name_tool). The same walk must keep the fast in-place
//! rewrite for any slot that still fits.

const std = @import("std");
const testing = std.testing;
const macho = std.macho;
const malt = @import("malt");
const patcher = malt.patcher;
const parser = malt.parser;

fn testIo(threaded: *std.Io.Threaded) std.Io {
    threaded.* = .init(testing.allocator, .{});
    return threaded.io();
}

/// Build a Mach-O 64 binary with two LC_LOAD_DYLIB load commands.
/// Each command has `cmdsize` bytes; its path region begins at the
/// `sizeof(dylib_command)` offset and carries the caller-supplied path
/// (null-terminated by the zero-fill).
fn buildTwoDylibFixture(
    allocator: std.mem.Allocator,
    path1: []const u8,
    cmdsize1: u32,
    path2: []const u8,
    cmdsize2: u32,
) ![]u8 {
    const header_size = @sizeOf(macho.mach_header_64);
    const name_offset: u32 = @sizeOf(macho.dylib_command);
    const total = header_size + cmdsize1 + cmdsize2;

    const buf = try allocator.alloc(u8, total);
    @memset(buf, 0);

    const hdr = std.mem.bytesAsValue(macho.mach_header_64, buf[0..header_size]);
    hdr.* = .{
        .magic = macho.MH_MAGIC_64,
        .ncmds = 2,
        .sizeofcmds = cmdsize1 + cmdsize2,
    };

    const lc1_off = header_size;
    const dy1 = std.mem.bytesAsValue(macho.dylib_command, buf[lc1_off..][0..name_offset]);
    dy1.* = .{
        .cmd = .LOAD_DYLIB,
        .cmdsize = cmdsize1,
        .dylib = .{ .name = name_offset, .timestamp = 0, .current_version = 0, .compatibility_version = 0 },
    };
    std.debug.assert(path1.len + 1 <= cmdsize1 - name_offset);
    @memcpy(buf[lc1_off + name_offset ..][0..path1.len], path1);

    const lc2_off = header_size + cmdsize1;
    const dy2 = std.mem.bytesAsValue(macho.dylib_command, buf[lc2_off..][0..name_offset]);
    dy2.* = .{
        .cmd = .LOAD_DYLIB,
        .cmdsize = cmdsize2,
        .dylib = .{ .name = name_offset, .timestamp = 0, .current_version = 0, .compatibility_version = 0 },
    };
    std.debug.assert(path2.len + 1 <= cmdsize2 - name_offset);
    @memcpy(buf[lc2_off + name_offset ..][0..path2.len], path2);

    return buf;
}

fn writeFixture(io: std.Io, dir: []const u8, filename: []const u8, bytes: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, filename });
    const f = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
    return path;
}

fn tmpSubdir(io: std.Io, tag: []const u8) ![]u8 {
    var seed_buf: [8]u8 = undefined;
    io.random(&seed_buf);
    const seed = std.mem.bytesToValue(u64, &seed_buf);
    const path = try std.fmt.allocPrint(
        testing.allocator,
        "/tmp/malt_patcher_test_{s}_{x}",
        .{ tag, seed },
    );
    try std.Io.Dir.cwd().createDirPath(io, path);
    return path;
}

test "patchPathsCollecting mixes in-place rewrite with overflow entries" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    // LC1: cmdsize 48, slot 24B, path "/O/short" — fits any /new-prefix/short replacement.
    // LC2: cmdsize 32, slot  8B, path "/O/x"     — replacement overflows the slot.
    const bytes = try buildTwoDylibFixture(
        testing.allocator,
        "/O/short",
        48,
        "/O/x",
        32,
    );
    defer testing.allocator.free(bytes);

    const dir = try tmpSubdir(io, "mixed");
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        testing.allocator.free(dir);
    }
    const path = try writeFixture(io, dir, "bin", bytes);
    defer testing.allocator.free(path);

    const replacements = [_]patcher.Replacement{
        .{ .old = "/O", .new = "/new-prefix" },
    };
    var outcome = try patcher.patchPathsCollecting(io, testing.allocator, path, &replacements);
    defer outcome.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), outcome.patched_count);
    try testing.expectEqual(@as(usize, 1), outcome.overflow.len);
    try testing.expectEqualStrings("/O/x", outcome.overflow[0].old_path);
    try testing.expectEqualStrings("/new-prefix/x", outcome.overflow[0].new_path);
}

test "patchPathsCollecting does not error when a slot overflows" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    // The whole point: `patchPaths` returns PathTooLong on overflow;
    // `patchPathsCollecting` must carry on and hand the overflow back.
    const bytes = try buildTwoDylibFixture(
        testing.allocator,
        "/O/short",
        48,
        "/O/x",
        32,
    );
    defer testing.allocator.free(bytes);

    const dir = try tmpSubdir(io, "no_error");
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        testing.allocator.free(dir);
    }
    const path = try writeFixture(io, dir, "bin", bytes);
    defer testing.allocator.free(path);

    const replacements = [_]patcher.Replacement{
        .{ .old = "/O", .new = "/new-prefix" },
    };
    // Must not surface PathTooLong: the per-slot failure is absorbed into
    // `outcome.overflow` so the caller can flush it via install_name_tool.
    var outcome = try patcher.patchPathsCollecting(io, testing.allocator, path, &replacements);
    outcome.deinit(testing.allocator);
}

test "patchPathsCollecting on a no-overflow fixture returns an empty overflow list" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    // Both slots easily fit a short replacement.
    const bytes = try buildTwoDylibFixture(
        testing.allocator,
        "/O/a",
        48,
        "/O/b",
        48,
    );
    defer testing.allocator.free(bytes);

    const dir = try tmpSubdir(io, "no_overflow");
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        testing.allocator.free(dir);
    }
    const path = try writeFixture(io, dir, "bin", bytes);
    defer testing.allocator.free(path);

    const replacements = [_]patcher.Replacement{
        .{ .old = "/O", .new = "/N" },
    };
    var outcome = try patcher.patchPathsCollecting(io, testing.allocator, path, &replacements);
    defer outcome.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 2), outcome.patched_count);
    try testing.expectEqual(@as(usize, 0), outcome.overflow.len);
}

test "patchPathsCollecting with only-overflow fixture reports zero in-place patches" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    // Both slots too small to take the long replacement.
    const bytes = try buildTwoDylibFixture(
        testing.allocator,
        "/O/x",
        32,
        "/O/y",
        32,
    );
    defer testing.allocator.free(bytes);

    const dir = try tmpSubdir(io, "only_overflow");
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        testing.allocator.free(dir);
    }
    const path = try writeFixture(io, dir, "bin", bytes);
    defer testing.allocator.free(path);

    const replacements = [_]patcher.Replacement{
        .{ .old = "/O", .new = "/a-long-replacement-prefix" },
    };
    var outcome = try patcher.patchPathsCollecting(io, testing.allocator, path, &replacements);
    defer outcome.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), outcome.patched_count);
    try testing.expectEqual(@as(usize, 2), outcome.overflow.len);
}

test "patchPathsCollecting persists in-place rewrites to disk" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    // After the call, re-parsing the file must show the rewritten slot for
    // the LC that fit, while the overflow slot stays untouched (fallback
    // will own it).
    const bytes = try buildTwoDylibFixture(
        testing.allocator,
        "/O/short",
        48,
        "/O/x",
        32,
    );
    defer testing.allocator.free(bytes);

    const dir = try tmpSubdir(io, "persist");
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        testing.allocator.free(dir);
    }
    const path = try writeFixture(io, dir, "bin", bytes);
    defer testing.allocator.free(path);

    const replacements = [_]patcher.Replacement{
        // Length picked so LC1's 24B slot fits "/medium-prefix/short" (21B
        // incl NUL) but LC2's 8B slot can't take "/medium-prefix/x" (17B).
        .{ .old = "/O", .new = "/medium-prefix" },
    };
    var outcome = try patcher.patchPathsCollecting(io, testing.allocator, path, &replacements);
    outcome.deinit(testing.allocator);

    const opened = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer opened.close(io);
    const stat_after = try opened.stat(io);
    const data = try testing.allocator.alloc(u8, @intCast(stat_after.size));
    defer testing.allocator.free(data);
    _ = try opened.readPositionalAll(io, data, 0);

    var re = try parser.parse(testing.allocator, data);
    defer re.deinit();
    try testing.expectEqual(@as(usize, 2), re.paths.len);
    try testing.expectEqualStrings("/medium-prefix/short", re.paths[0].path);
    // Overflow slot stayed as-is — fallback flushes it later.
    try testing.expectEqualStrings("/O/x", re.paths[1].path);
}

// ---------------------------------------------------------------------------
// flushOverflow / install_name_tool driver
// ---------------------------------------------------------------------------

test "external_tool_name is install_name_tool on macOS" {
    try testing.expectEqualStrings("install_name_tool", patcher.external_tool_name);
}

test "buildInstallNameToolArgv batches -change pairs into a single invocation" {
    const entries = [_]patcher.OverflowEntry{
        .{
            .cmd = @intFromEnum(macho.LC.LOAD_DYLIB),
            .old_path = "@@HOMEBREW_CELLAR@@/openssl/3.0/lib/libssl.dylib",
            .new_path = "/tmp/mt_tahoe/Cellar/openssl/3.0/lib/libssl.dylib",
        },
        .{
            .cmd = @intFromEnum(macho.LC.LOAD_DYLIB),
            .old_path = "@@HOMEBREW_CELLAR@@/openssl/3.0/lib/libcrypto.dylib",
            .new_path = "/tmp/mt_tahoe/Cellar/openssl/3.0/lib/libcrypto.dylib",
        },
    };
    const argv = try patcher.buildInstallNameToolArgv(testing.allocator, "/tmp/binary", &entries);
    defer testing.allocator.free(argv);

    try testing.expectEqual(@as(usize, 8), argv.len);
    try testing.expectEqualStrings("install_name_tool", argv[0]);
    try testing.expectEqualStrings("-change", argv[1]);
    try testing.expectEqualStrings(entries[0].old_path, argv[2]);
    try testing.expectEqualStrings(entries[0].new_path, argv[3]);
    try testing.expectEqualStrings("-change", argv[4]);
    try testing.expectEqualStrings(entries[1].old_path, argv[5]);
    try testing.expectEqualStrings(entries[1].new_path, argv[6]);
    try testing.expectEqualStrings("/tmp/binary", argv[7]);
}

test "buildInstallNameToolArgv routes LC_RPATH through -rpath" {
    const entries = [_]patcher.OverflowEntry{
        .{
            .cmd = @intFromEnum(macho.LC.RPATH),
            .old_path = "@@HOMEBREW_PREFIX@@/lib",
            .new_path = "/tmp/mt_tahoe/lib",
        },
    };
    const argv = try patcher.buildInstallNameToolArgv(testing.allocator, "/tmp/binary", &entries);
    defer testing.allocator.free(argv);

    try testing.expectEqualStrings("-rpath", argv[1]);
    try testing.expectEqualStrings(entries[0].old_path, argv[2]);
    try testing.expectEqualStrings(entries[0].new_path, argv[3]);
}

test "buildInstallNameToolArgv routes LC_ID_DYLIB through -id (no old arg)" {
    const entries = [_]patcher.OverflowEntry{
        .{
            .cmd = @intFromEnum(macho.LC.ID_DYLIB),
            .old_path = "@@HOMEBREW_CELLAR@@/foo.dylib",
            .new_path = "/tmp/mt_tahoe/foo.dylib",
        },
    };
    const argv = try patcher.buildInstallNameToolArgv(testing.allocator, "/tmp/binary", &entries);
    defer testing.allocator.free(argv);

    // -id <new> <binary>: the "old" path is implicit.
    try testing.expectEqual(@as(usize, 4), argv.len);
    try testing.expectEqualStrings("-id", argv[1]);
    try testing.expectEqualStrings(entries[0].new_path, argv[2]);
    try testing.expectEqualStrings("/tmp/binary", argv[3]);
}

test "classifyInstallNameToolStderr maps headerpad text to InsufficientHeaderPad" {
    const stderr =
        "install_name_tool: changing install names or rpaths can't be redone for: " ++
        "/tmp/binary because larger updated load commands do not fit (the program must be relinked, " ++
        "and you may need to use -headerpad or -headerpad_max_install_names)\n";
    const got = patcher.classifyInstallNameToolStderr(stderr);
    try testing.expectEqual(patcher.FallbackError.InsufficientHeaderPad, got);
}

test "classifyInstallNameToolStderr falls back to InstallNameToolFailed for other text" {
    const stderr = "install_name_tool: some other failure\n";
    const got = patcher.classifyInstallNameToolStderr(stderr);
    try testing.expectEqual(patcher.FallbackError.InstallNameToolFailed, got);
}

test "flushOverflow on an empty list does nothing and returns ok" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    // Defensive cheap path: callers can pass an empty overflow list
    // (no-overflow bottle); the driver must not spawn anything.
    try patcher.flushOverflow(threaded.io(), testing.allocator, "/tmp/whatever", &.{});
}

// ---------------------------------------------------------------------------
// patchTextFiles — atomicity and mode-preservation invariants
// ---------------------------------------------------------------------------

test "patchTextFiles leaves the original file intact when atomic staging fails" {
    // Root bypasses POSIX mode bits, so the EACCES path the test relies
    // on cannot fire — skip rather than mis-pass.
    if (std.c.geteuid() == 0) return error.SkipZigTest;

    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    const root = try tmpSubdir(io, "atomic_intact");
    const sub = try std.fmt.allocPrint(testing.allocator, "{s}/sub", .{root});
    defer testing.allocator.free(sub);
    try std.Io.Dir.createDirAbsolute(io, sub, .default_dir);

    const sub_z = try testing.allocator.dupeZ(u8, sub);
    defer testing.allocator.free(sub_z);
    defer {
        // Re-enable write perm so deleteTree can clean up the locked subdir.
        _ = std.c.chmod(sub_z.ptr, 0o755);
        std.Io.Dir.cwd().deleteTree(io, root) catch {};
        testing.allocator.free(root);
    }

    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/wrapper.txt", .{sub});
    defer testing.allocator.free(file_path);
    const original = "exec @@HOMEBREW_PREFIX@@/bin/foo\n";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        try f.writeStreamingAll(io, original);
        f.close(io);
    }

    // 0o555 lets the walker enter and openFile read the existing file
    // (POSIX needs write on the file, not the parent) but blocks the
    // sibling tempfile that an atomic rename stages. The in-place
    // writePositionalAll path the patcher is moving away from would
    // rewrite the file here and corrupt the assertion below.
    if (std.c.chmod(sub_z.ptr, 0o555) != 0) return error.SkipZigTest;

    const replacements = [_]patcher.Replacement{
        .{ .old = "@@HOMEBREW_PREFIX@@", .new = "/opt/malt" },
    };
    // Error is irrelevant — the load-bearing invariant is the file's bytes.
    _ = patcher.patchTextFiles(io, testing.allocator, root, &replacements) catch {};

    _ = std.c.chmod(sub_z.ptr, 0o755);

    const f = try std.Io.Dir.openFileAbsolute(io, file_path, .{});
    defer f.close(io);
    var buf: [128]u8 = undefined;
    const n = try f.readPositionalAll(io, &buf, 0);
    try testing.expectEqualStrings(original, buf[0..n]);
}

test "patchTextFiles preserves the original file mode across the rewrite" {
    // Root would override the 0o755 the test pins against.
    if (std.c.geteuid() == 0) return error.SkipZigTest;

    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    const dir = try tmpSubdir(io, "preserve_mode");
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        testing.allocator.free(dir);
    }

    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/wrapper", .{dir});
    defer testing.allocator.free(file_path);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        try f.writeStreamingAll(io, "#!/bin/sh\nexec @@HOMEBREW_PREFIX@@/bin/foo\n");
        f.close(io);
    }

    // 0o755 is the canonical mode for a Python or shell wrapper inside a
    // relocated keg; losing the exec bit would silently break `mt install`
    // on any formula that ships shebang scripts.
    const fp_z = try testing.allocator.dupeZ(u8, file_path);
    defer testing.allocator.free(fp_z);
    if (std.c.chmod(fp_z.ptr, 0o755) != 0) return error.SkipZigTest;

    const replacements = [_]patcher.Replacement{
        .{ .old = "@@HOMEBREW_PREFIX@@", .new = "/opt/malt" },
    };
    const count = try patcher.patchTextFiles(io, testing.allocator, dir, &replacements);
    // Without an actual patch the rename never runs; the mode check
    // below would pass trivially and stop guarding the regression.
    try testing.expectEqual(@as(u32, 1), count);

    const f = try std.Io.Dir.openFileAbsolute(io, file_path, .{});
    defer f.close(io);
    const s = try f.stat(io);
    try testing.expectEqual(@as(std.posix.mode_t, 0o755), s.permissions.toMode() & 0o7777);
}

/// Build a Mach-O 64 binary carrying one LC_SEGMENT_64 (__TEXT) with a
/// single __cstring section holding `blob`. The section's file offset is
/// placed immediately after the load commands so the on-disk layout is
/// trivially predictable for byte-level assertions.
///
/// Returns the buffer and the absolute file offset of `blob[0]`.
const CstringFixture = struct {
    bytes: []u8,
    cstring_offset: usize,
};

fn buildCstringFixture(
    allocator: std.mem.Allocator,
    blob: []const u8,
) !CstringFixture {
    const header_size = @sizeOf(macho.mach_header_64);
    const seg_size = @sizeOf(macho.segment_command_64);
    const sect_size = @sizeOf(macho.section_64);
    const cmdsize: u32 = @intCast(seg_size + sect_size);
    const cstring_offset = header_size + cmdsize;
    const total = cstring_offset + blob.len;

    const buf = try allocator.alloc(u8, total);
    @memset(buf, 0);

    const hdr = std.mem.bytesAsValue(macho.mach_header_64, buf[0..header_size]);
    hdr.* = .{
        .magic = macho.MH_MAGIC_64,
        .ncmds = 1,
        .sizeofcmds = cmdsize,
    };

    const seg = std.mem.bytesAsValue(macho.segment_command_64, buf[header_size..][0..seg_size]);
    seg.* = .{
        .cmd = .SEGMENT_64,
        .cmdsize = cmdsize,
        .segname = [_]u8{0} ** 16,
        .nsects = 1,
    };
    @memcpy(seg.segname[0.."__TEXT".len], "__TEXT");

    const sect = std.mem.bytesAsValue(macho.section_64, buf[header_size + seg_size ..][0..sect_size]);
    sect.* = .{
        .sectname = [_]u8{0} ** 16,
        .segname = [_]u8{0} ** 16,
        .offset = @intCast(cstring_offset),
        .size = blob.len,
        .flags = macho.S_CSTRING_LITERALS,
    };
    @memcpy(sect.sectname[0.."__cstring".len], "__cstring");
    @memcpy(sect.segname[0.."__TEXT".len], "__TEXT");

    @memcpy(buf[cstring_offset..][0..blob.len], blob);

    return .{ .bytes = buf, .cstring_offset = cstring_offset };
}

test "patchPathsCollecting rewrites __cstring strings that match an old prefix" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    // Two prefix-matching strings and one untouched neighbour, all NUL-
    // terminated and packed back-to-back as ld64 emits them.
    const a = "/opt/homebrew/foo\x00";
    const b = "/opt/homebrew/Cellar/imagemagick\x00";
    const c = "unchanged\x00";
    const blob = a ++ b ++ c;

    const fix = try buildCstringFixture(testing.allocator, blob);
    defer testing.allocator.free(fix.bytes);

    const dir = try tmpSubdir(io, "cstr_basic");
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        testing.allocator.free(dir);
    }
    const path = try writeFixture(io, dir, "bin", fix.bytes);
    defer testing.allocator.free(path);

    const replacements = [_]patcher.Replacement{
        .{ .old = "/opt/homebrew", .new = "/M" },
    };
    var outcome = try patcher.patchPathsCollecting(io, testing.allocator, path, &replacements);
    defer outcome.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 2), outcome.patched_count);
    try testing.expectEqual(@as(usize, 0), outcome.overflow.len);

    // Re-read and inspect the cstring region byte-for-byte.
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const got = try testing.allocator.alloc(u8, fix.bytes.len);
    defer testing.allocator.free(got);
    _ = try file.readPositionalAll(io, got, 0);

    const region = got[fix.cstring_offset..][0..blob.len];

    // First string: "/opt/homebrew/foo" → "/M/foo", NUL-padded to original 17B slot.
    const slot_a_len = a.len; // includes trailing NUL
    try testing.expectEqualStrings("/M/foo", std.mem.sliceTo(region[0..slot_a_len], 0));
    for (region[("/M/foo".len + 1)..slot_a_len]) |byte| try testing.expectEqual(@as(u8, 0), byte);

    // Second string: "/opt/homebrew/Cellar/imagemagick" → "/M/Cellar/imagemagick".
    const slot_b_off = slot_a_len;
    const slot_b_len = b.len;
    try testing.expectEqualStrings(
        "/M/Cellar/imagemagick",
        std.mem.sliceTo(region[slot_b_off..][0..slot_b_len], 0),
    );

    // Third string left intact.
    const slot_c_off = slot_a_len + slot_b_len;
    try testing.expectEqualStrings("unchanged", std.mem.sliceTo(region[slot_c_off..][0..c.len], 0));
}

test "patchPathsCollecting leaves __cstring strings whose replacement does not fit" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    // Replacement "/opt/homebrew/much-longer-prefix" > "/x" (old) for any cstring
    // beginning with "/x". Cstring slots can't grow in place — the patcher
    // must leave the byte untouched and not error.
    const blob = "/x/short\x00";
    const fix = try buildCstringFixture(testing.allocator, blob);
    defer testing.allocator.free(fix.bytes);

    const dir = try tmpSubdir(io, "cstr_overflow");
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        testing.allocator.free(dir);
    }
    const path = try writeFixture(io, dir, "bin", fix.bytes);
    defer testing.allocator.free(path);

    const replacements = [_]patcher.Replacement{
        .{ .old = "/x", .new = "/much-longer-prefix" },
    };
    var outcome = try patcher.patchPathsCollecting(io, testing.allocator, path, &replacements);
    defer outcome.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), outcome.patched_count);
    try testing.expectEqual(@as(usize, 0), outcome.overflow.len);

    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const got = try testing.allocator.alloc(u8, fix.bytes.len);
    defer testing.allocator.free(got);
    _ = try file.readPositionalAll(io, got, 0);
    try testing.expectEqualStrings(
        "/x/short",
        std.mem.sliceTo(got[fix.cstring_offset..][0..blob.len], 0),
    );
}

test "patchPathsCollecting picks the first matching prefix for cstrings" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);
    defer threaded.deinit();

    // Two replacement candidates with overlapping prefixes — first match wins
    // (same semantics as the load-command path; documented at pickReplacement).
    const blob = "/opt/homebrew/lib/x\x00";
    const fix = try buildCstringFixture(testing.allocator, blob);
    defer testing.allocator.free(fix.bytes);

    const dir = try tmpSubdir(io, "cstr_firstmatch");
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        testing.allocator.free(dir);
    }
    const path = try writeFixture(io, dir, "bin", fix.bytes);
    defer testing.allocator.free(path);

    const replacements = [_]patcher.Replacement{
        .{ .old = "/opt/homebrew", .new = "/A" },
        .{ .old = "/opt", .new = "/B" },
    };
    var outcome = try patcher.patchPathsCollecting(io, testing.allocator, path, &replacements);
    defer outcome.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), outcome.patched_count);

    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const got = try testing.allocator.alloc(u8, fix.bytes.len);
    defer testing.allocator.free(got);
    _ = try file.readPositionalAll(io, got, 0);
    try testing.expectEqualStrings(
        "/A/lib/x",
        std.mem.sliceTo(got[fix.cstring_offset..][0..blob.len], 0),
    );
}
