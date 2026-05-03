//! malt - shared streaming-SHA helper tests.
//!
//! The helper hashes files in bounded chunks so callers that might
//! see large payloads (self-update tarballs, casks) never need to
//! hold the whole file in RAM. Tests cover the boundary matrix,
//! the NIST "abc" vector, empty input, and missing-path propagation.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const hash = malt.hash;

/// 64 KiB — internal SHA256 read chunk. Boundary cases are expressed
/// relative to this so the tests stay meaningful if the constant moves.
const CHUNK: usize = 64 * 1024;

fn testIo() std.Io {
    return std.Options.debug_io;
}

fn tempPath(tag: []const u8, buf: []u8) ![]const u8 {
    const ts = std.Io.Clock.real.now(testIo()).toNanoseconds();
    return std.fmt.bufPrint(buf, "/tmp/malt_hash_test_{s}_{d}", .{ tag, ts });
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    const f = try std.Io.Dir.createFileAbsolute(testIo(), path, .{});
    defer f.close(testIo());
    try f.writeStreamingAll(testIo(), bytes);
}

fn deleteFile(path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(testIo(), path) catch {};
}

fn fillPattern(buf: []u8) void {
    for (buf, 0..) |*b, i| b.* = @intCast((i *% 131 +% 7) & 0xFF);
}

fn referenceRaw(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}

test "hashFileSha256Raw returns the canonical empty digest" {
    var buf: [128]u8 = undefined;
    const p = try tempPath("empty_raw", &buf);
    try writeFile(p, "");
    defer deleteFile(p);

    const got = try hash.hashFileSha256Raw(testIo(), p);
    // SHA256("")
    const want = [_]u8{
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
        0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
        0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
        0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
    };
    try testing.expectEqualSlices(u8, &want, &got);
}

test "hashFileSha256Raw matches NIST 'abc' vector" {
    var buf: [128]u8 = undefined;
    const p = try tempPath("abc_raw", &buf);
    try writeFile(p, "abc");
    defer deleteFile(p);

    const got = try hash.hashFileSha256Raw(testIo(), p);
    const want = [_]u8{
        0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
        0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
        0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
        0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
    };
    try testing.expectEqualSlices(u8, &want, &got);
}

test "hashFileSha256Raw streams past the chunk boundary" {
    // 2.5x CHUNK — the exact repro size that broke the pre-stream
    // hash in cask. Proves later chunks reach the hasher intact.
    const size = 2 * CHUNK + CHUNK / 2;
    const payload = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(payload);
    fillPattern(payload);

    var buf: [128]u8 = undefined;
    const p = try tempPath("multi_raw", &buf);
    try writeFile(p, payload);
    defer deleteFile(p);

    const got = try hash.hashFileSha256Raw(testIo(), p);
    const want = referenceRaw(payload);
    try testing.expectEqualSlices(u8, &want, &got);
}

test "hashFileSha256Raw propagates FileNotFound" {
    try testing.expectError(
        error.FileNotFound,
        hash.hashFileSha256Raw(testIo(), "/tmp/malt_hash_test_absent_xyzzy.bin"),
    );
}

test "hashFileSha256Hex is the lowercase hex of hashFileSha256Raw" {
    var buf: [128]u8 = undefined;
    const p = try tempPath("hex_match", &buf);
    try writeFile(p, "hello world");
    defer deleteFile(p);

    const raw = try hash.hashFileSha256Raw(testIo(), p);
    const hex = try hash.hashFileSha256Hex(testIo(), p);
    const expected_hex = std.fmt.bytesToHex(raw, .lower);
    try testing.expectEqualSlices(u8, &expected_hex, &hex);
}
