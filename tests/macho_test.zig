//! malt — Mach-O module tests
//! Tests for Mach-O parsing, magic detection, and path patching.

const std = @import("std");
const testing = std.testing;
const macho = std.macho;
const malt = @import("malt");
const parser = malt.parser;
const patcher = malt.patcher;
const codesign = malt.codesign;

test "isMachO detects MH_MAGIC_64" {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, macho.MH_MAGIC_64, .little);
    try testing.expect(parser.isMachO(&buf));
}

test "isMachO detects MH_CIGAM_64" {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, macho.MH_CIGAM_64, .little);
    try testing.expect(parser.isMachO(&buf));
}

test "isMachO detects FAT_MAGIC" {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, macho.FAT_MAGIC, .little);
    try testing.expect(parser.isMachO(&buf));
}

test "isMachO rejects non-Mach-O" {
    try testing.expect(!parser.isMachO("ELF!"));
    try testing.expect(!parser.isMachO(""));
    try testing.expect(!parser.isMachO("\x00\x00"));
}

test "parse rejects truncated file" {
    try testing.expectError(parser.ParseError.TruncatedFile, parser.parse(testing.allocator, "ab"));
}

test "parse rejects invalid magic" {
    var buf: [32]u8 = .{0} ** 32;
    buf[0] = 0xFF;
    try testing.expectError(parser.ParseError.InvalidMagic, parser.parse(testing.allocator, &buf));
}

test "parse empty Mach-O 64 with zero load commands" {
    // Build a minimal valid mach_header_64 with ncmds=0
    var buf: [@sizeOf(macho.mach_header_64)]u8 = undefined;
    const header = std.mem.bytesAsValue(macho.mach_header_64, &buf);
    header.* = .{
        .magic = macho.MH_MAGIC_64,
        .ncmds = 0,
        .sizeofcmds = 0,
    };

    var result = try parser.parse(testing.allocator, &buf);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.paths.len);
}

test "codesign isArm64 returns consistent result" {
    // Just verify it doesn't crash and returns a bool
    const is_arm = codesign.isArm64();
    _ = is_arm;
}

test "patcher hasPrefix helper via patchPaths on non-existent file" {
    // patchPaths on a non-existent file should return OpenFailed
    const result = patcher.patchPaths(testing.allocator, "/nonexistent/path/to/binary", "/opt/homebrew", "/opt/malt");
    try testing.expectError(error.OpenFailed, result);
}

// --- Parser edge cases (truncated + dylib/rpath load commands) ---

test "parse rejects truncated header" {
    // < sizeof(mach_header_64) bytes after magic check → TruncatedFile
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], macho.MH_MAGIC_64, .little);
    @memset(buf[4..], 0);
    try testing.expectError(parser.ParseError.TruncatedFile, parser.parse(testing.allocator, &buf));
}

test "parse a Mach-O 64 with an LC_LOAD_DYLIB load command extracts the path" {
    // Build a minimal binary: mach_header_64 + dylib_command + padded name.
    const lc_size = @sizeOf(macho.dylib_command);
    const path_str = "/opt/homebrew/lib/libfoo.dylib\x00";
    // dylib_command.cmdsize must cover the whole LC including the path.
    const name_offset: u32 = @intCast(lc_size);
    const cmdsize: u32 = @intCast(lc_size + path_str.len);
    const cmdsize_aligned: u32 = (cmdsize + 7) & ~@as(u32, 7);

    const header_size = @sizeOf(macho.mach_header_64);
    const total_len = header_size + cmdsize_aligned;

    const buf = try testing.allocator.alloc(u8, total_len);
    defer testing.allocator.free(buf);
    @memset(buf, 0);

    const header = std.mem.bytesAsValue(macho.mach_header_64, buf[0..header_size]);
    header.* = .{
        .magic = macho.MH_MAGIC_64,
        .ncmds = 1,
        .sizeofcmds = cmdsize_aligned,
    };

    const dy = std.mem.bytesAsValue(macho.dylib_command, buf[header_size..][0..lc_size]);
    dy.* = .{
        .cmd = .LOAD_DYLIB,
        .cmdsize = cmdsize_aligned,
        .dylib = .{
            .name = name_offset,
            .timestamp = 0,
            .current_version = 0,
            .compatibility_version = 0,
        },
    };

    // Write the path bytes right after the dylib_command struct.
    @memcpy(
        buf[header_size + lc_size ..][0..path_str.len],
        path_str,
    );

    var m = try parser.parse(testing.allocator, buf);
    defer m.deinit();
    try testing.expectEqual(@as(usize, 1), m.paths.len);
    try testing.expectEqualStrings("/opt/homebrew/lib/libfoo.dylib", m.paths[0].path);
    try testing.expectEqual(
        @as(u32, @intFromEnum(macho.LC.LOAD_DYLIB)),
        m.paths[0].cmd,
    );
}

test "parse a Mach-O 64 with an LC_RPATH command extracts the path" {
    const lc_size = @sizeOf(macho.rpath_command);
    const path_str = "@executable_path/../lib\x00";
    const rpath_offset: u32 = @intCast(lc_size);
    const cmdsize: u32 = @intCast(lc_size + path_str.len);
    const cmdsize_aligned: u32 = (cmdsize + 7) & ~@as(u32, 7);

    const header_size = @sizeOf(macho.mach_header_64);
    const total_len = header_size + cmdsize_aligned;

    const buf = try testing.allocator.alloc(u8, total_len);
    defer testing.allocator.free(buf);
    @memset(buf, 0);

    const header = std.mem.bytesAsValue(macho.mach_header_64, buf[0..header_size]);
    header.* = .{
        .magic = macho.MH_MAGIC_64,
        .ncmds = 1,
        .sizeofcmds = cmdsize_aligned,
    };

    const rp = std.mem.bytesAsValue(macho.rpath_command, buf[header_size..][0..lc_size]);
    rp.* = .{
        .cmd = .RPATH,
        .cmdsize = cmdsize_aligned,
        .path = rpath_offset,
    };
    @memcpy(
        buf[header_size + lc_size ..][0..path_str.len],
        path_str,
    );

    var m = try parser.parse(testing.allocator, buf);
    defer m.deinit();
    try testing.expectEqual(@as(usize, 1), m.paths.len);
    try testing.expectEqualStrings("@executable_path/../lib", m.paths[0].path);
}

test "parse rejects a truncated fat header" {
    // Only 4 bytes — not enough for the nfat_arch field.
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, macho.FAT_MAGIC, .big);
    try testing.expectError(parser.ParseError.TruncatedFile, parser.parse(testing.allocator, &buf));
}

test "parse rejects a fat archive whose slice extends beyond data" {
    // Build a fat header claiming one arch whose slice is out of bounds.
    var buf: [28]u8 = undefined;
    @memset(&buf, 0);
    std.mem.writeInt(u32, buf[0..4], macho.FAT_MAGIC, .big);
    std.mem.writeInt(u32, buf[4..8], 1, .big); // nfat_arch = 1
    // fat_arch entry starts at offset 8: cputype, cpusubtype, offset, size, align.
    std.mem.writeInt(u32, buf[16..20], 100, .big); // offset = 100 (past EOF)
    std.mem.writeInt(u32, buf[20..24], 200, .big); // size = 200
    try testing.expectError(parser.ParseError.TruncatedFile, parser.parse(testing.allocator, &buf));
}

test "parse bubbles InvalidLoadCommand from a corrupt fat slice" {
    // A fat archive whose only slice is a Mach-O 64 with a bogus load
    // command (cmdsize < sizeof(load_command)). The parser must surface
    // the structural corruption instead of silently skipping the slice
    // like it does for legacy arches (InvalidMagic / UnsupportedArch /
    // TruncatedFile).
    const macho_header_size = @sizeOf(macho.mach_header_64);
    const lc_size = @sizeOf(macho.load_command);
    const slice_len = macho_header_size + lc_size;

    // Fat header (big-endian): magic(4), nfat_arch(4), fat_arch(20).
    const fat_header_len: usize = 8 + 20;
    const total_len = fat_header_len + slice_len;

    const buf = try testing.allocator.alloc(u8, total_len);
    defer testing.allocator.free(buf);
    @memset(buf, 0);

    std.mem.writeInt(u32, buf[0..4], macho.FAT_MAGIC, .big);
    std.mem.writeInt(u32, buf[4..8], 1, .big); // nfat_arch = 1
    // fat_arch entry at offset 8: cputype, cpusubtype, offset, size, align.
    std.mem.writeInt(u32, buf[16..20], @intCast(fat_header_len), .big);
    std.mem.writeInt(u32, buf[20..24], @intCast(slice_len), .big);

    // Slice body: mach_header_64 + one corrupt load command.
    const slice = buf[fat_header_len..];
    const header = std.mem.bytesAsValue(macho.mach_header_64, slice[0..macho_header_size]);
    header.* = .{
        .magic = macho.MH_MAGIC_64,
        .ncmds = 1,
        .sizeofcmds = lc_size,
    };
    const lc = std.mem.bytesAsValue(macho.load_command, slice[macho_header_size..][0..lc_size]);
    lc.* = .{ .cmd = .LOAD_DYLIB, .cmdsize = 1 }; // bogus tiny cmdsize

    try testing.expectError(
        parser.ParseError.InvalidLoadCommand,
        parser.parse(testing.allocator, buf),
    );
}

test "parse rejects a cmdsize shorter than the generic load_command" {
    const header_size = @sizeOf(macho.mach_header_64);
    const lc_size = @sizeOf(macho.load_command);
    const buf = try testing.allocator.alloc(u8, header_size + lc_size);
    defer testing.allocator.free(buf);
    @memset(buf, 0);

    const header = std.mem.bytesAsValue(macho.mach_header_64, buf[0..header_size]);
    header.* = .{
        .magic = macho.MH_MAGIC_64,
        .ncmds = 1,
        .sizeofcmds = lc_size,
    };

    const lc = std.mem.bytesAsValue(macho.load_command, buf[header_size..][0..lc_size]);
    lc.* = .{ .cmd = .LOAD_DYLIB, .cmdsize = 1 }; // bogus tiny cmdsize
    try testing.expectError(parser.ParseError.InvalidLoadCommand, parser.parse(testing.allocator, buf));
}

test "patchPaths preserves trailing NUL at max_path_len-1 boundary" {
    // Pins the NUL-terminator invariant for an LC_LOAD_DYLIB slot whose
    // path fills exactly `max_path_len - 1` content bytes. The guard must
    // leave the last slot byte as 0 so dyld never reads past the path.

    const lc_size = @sizeOf(macho.dylib_command);
    const header_size = @sizeOf(macho.mach_header_64);

    // cmdsize chosen so the path region is 16 bytes (multiple-of-8 align).
    // max_path_len = cmdsize - name_offset = 40 - 24 = 16.
    const name_offset: u32 = @intCast(lc_size);
    const cmdsize_aligned: u32 = @intCast(lc_size + 16);
    const max_path_len: usize = cmdsize_aligned - name_offset;

    // Slot layout: "/opt/aaaaaaaaaa" + NUL → 15 content bytes + terminator.
    const old_path = "/opt/aaaaaaaaaa"; // 15 bytes, == max_path_len - 1.
    try testing.expectEqual(max_path_len - 1, old_path.len);

    const total_len = header_size + cmdsize_aligned;
    const buf = try testing.allocator.alloc(u8, total_len);
    defer testing.allocator.free(buf);
    @memset(buf, 0);

    const header = std.mem.bytesAsValue(macho.mach_header_64, buf[0..header_size]);
    header.* = .{
        .magic = macho.MH_MAGIC_64,
        .ncmds = 1,
        .sizeofcmds = cmdsize_aligned,
    };

    const dy = std.mem.bytesAsValue(macho.dylib_command, buf[header_size..][0..lc_size]);
    dy.* = .{
        .cmd = .LOAD_DYLIB,
        .cmdsize = cmdsize_aligned,
        .dylib = .{
            .name = name_offset,
            .timestamp = 0,
            .current_version = 0,
            .compatibility_version = 0,
        },
    };
    @memcpy(buf[header_size + lc_size ..][0..old_path.len], old_path);
    // buf[header_size + lc_size + 15] stays 0 from the earlier @memset.

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_abs_len = try std.Io.Dir.realPath(tmp.dir, malt.io_mod.ctx(), &dir_path_buf);
    var full_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(
        &full_path_buf,
        "{s}/fixture.bin",
        .{dir_path_buf[0..dir_abs_len]},
    );
    {
        const f = try malt.fs_compat.createFileAbsolute(full_path, .{});
        defer f.close();
        try f.writeAll(buf);
    }

    // Same-length patch: new_path_len == max_path_len - 1.
    const result = try patcher.patchPaths(
        testing.allocator,
        full_path,
        "/opt/",
        "/bin/",
    );
    try testing.expectEqual(@as(u32, 1), result.patched_count);

    const patched = try malt.fs_compat.readFileAbsoluteAlloc(testing.allocator, full_path, 1024);
    defer testing.allocator.free(patched);

    const slot = patched[header_size + lc_size ..][0..max_path_len];
    try testing.expectEqualStrings("/bin/aaaaaaaaaa", slot[0 .. max_path_len - 1]);
    try testing.expectEqual(@as(u8, 0), slot[max_path_len - 1]);
}
