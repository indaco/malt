//! malt — Mach-O module tests
//! Tests for Mach-O parsing, magic detection, and path patching.

const std = @import("std");
const testing = std.testing;
const macho = std.macho;
const parser = @import("malt").parser;
const patcher = @import("malt").patcher;
const codesign = @import("malt").codesign;

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
