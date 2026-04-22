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

fn writeFixture(dir: []const u8, filename: []const u8, bytes: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, filename });
    const f = try malt.fs_compat.createFileAbsolute(path, .{});
    defer f.close();
    try f.writeAll(bytes);
    return path;
}

fn tmpSubdir(tag: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(
        testing.allocator,
        "/tmp/malt_patcher_test_{s}_{x}",
        .{ tag, malt.fs_compat.randomInt(u64) },
    );
    try malt.fs_compat.cwd().makePath(path);
    return path;
}

test "patchPathsCollecting mixes in-place rewrite with overflow entries" {
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

    const dir = try tmpSubdir("mixed");
    defer {
        malt.fs_compat.deleteTreeAbsolute(dir) catch {};
        testing.allocator.free(dir);
    }
    const path = try writeFixture(dir, "bin", bytes);
    defer testing.allocator.free(path);

    const replacements = [_]patcher.Replacement{
        .{ .old = "/O", .new = "/new-prefix" },
    };
    var outcome = try patcher.patchPathsCollecting(testing.allocator, path, &replacements);
    defer outcome.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), outcome.patched_count);
    try testing.expectEqual(@as(usize, 1), outcome.overflow.len);
    try testing.expectEqualStrings("/O/x", outcome.overflow[0].old_path);
    try testing.expectEqualStrings("/new-prefix/x", outcome.overflow[0].new_path);
}

test "patchPathsCollecting does not error when a slot overflows" {
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

    const dir = try tmpSubdir("no_error");
    defer {
        malt.fs_compat.deleteTreeAbsolute(dir) catch {};
        testing.allocator.free(dir);
    }
    const path = try writeFixture(dir, "bin", bytes);
    defer testing.allocator.free(path);

    const replacements = [_]patcher.Replacement{
        .{ .old = "/O", .new = "/new-prefix" },
    };
    // Must not surface PathTooLong: the per-slot failure is absorbed into
    // `outcome.overflow` so the caller can flush it via install_name_tool.
    var outcome = try patcher.patchPathsCollecting(testing.allocator, path, &replacements);
    outcome.deinit(testing.allocator);
}

test "patchPathsCollecting on a no-overflow fixture returns an empty overflow list" {
    // Both slots easily fit a short replacement.
    const bytes = try buildTwoDylibFixture(
        testing.allocator,
        "/O/a",
        48,
        "/O/b",
        48,
    );
    defer testing.allocator.free(bytes);

    const dir = try tmpSubdir("no_overflow");
    defer {
        malt.fs_compat.deleteTreeAbsolute(dir) catch {};
        testing.allocator.free(dir);
    }
    const path = try writeFixture(dir, "bin", bytes);
    defer testing.allocator.free(path);

    const replacements = [_]patcher.Replacement{
        .{ .old = "/O", .new = "/N" },
    };
    var outcome = try patcher.patchPathsCollecting(testing.allocator, path, &replacements);
    defer outcome.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 2), outcome.patched_count);
    try testing.expectEqual(@as(usize, 0), outcome.overflow.len);
}

test "patchPathsCollecting with only-overflow fixture reports zero in-place patches" {
    // Both slots too small to take the long replacement.
    const bytes = try buildTwoDylibFixture(
        testing.allocator,
        "/O/x",
        32,
        "/O/y",
        32,
    );
    defer testing.allocator.free(bytes);

    const dir = try tmpSubdir("only_overflow");
    defer {
        malt.fs_compat.deleteTreeAbsolute(dir) catch {};
        testing.allocator.free(dir);
    }
    const path = try writeFixture(dir, "bin", bytes);
    defer testing.allocator.free(path);

    const replacements = [_]patcher.Replacement{
        .{ .old = "/O", .new = "/a-long-replacement-prefix" },
    };
    var outcome = try patcher.patchPathsCollecting(testing.allocator, path, &replacements);
    defer outcome.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), outcome.patched_count);
    try testing.expectEqual(@as(usize, 2), outcome.overflow.len);
}

test "patchPathsCollecting persists in-place rewrites to disk" {
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

    const dir = try tmpSubdir("persist");
    defer {
        malt.fs_compat.deleteTreeAbsolute(dir) catch {};
        testing.allocator.free(dir);
    }
    const path = try writeFixture(dir, "bin", bytes);
    defer testing.allocator.free(path);

    const replacements = [_]patcher.Replacement{
        // Length picked so LC1's 24B slot fits "/medium-prefix/short" (21B
        // incl NUL) but LC2's 8B slot can't take "/medium-prefix/x" (17B).
        .{ .old = "/O", .new = "/medium-prefix" },
    };
    var outcome = try patcher.patchPathsCollecting(testing.allocator, path, &replacements);
    outcome.deinit(testing.allocator);

    const data = try malt.fs_compat.readFileAbsoluteAlloc(testing.allocator, path, 4096);
    defer testing.allocator.free(data);

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
    // Defensive cheap path: callers can pass an empty overflow list
    // (no-overflow bottle); the driver must not spawn anything.
    try patcher.flushOverflow(testing.allocator, "/tmp/whatever", &.{});
}
