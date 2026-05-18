//! malt — shared streaming SHA256 for file paths.
//!
//! Centralises the read-in-chunks-feed-the-hasher dance so callers that
//! hash large files (self-update tarball, cask artifacts) bound RSS to
//! the chunk size instead of the file size.

const std = @import("std");

/// One positional read per 64 KiB — large enough to keep syscall
/// overhead in the noise, small enough that peak RSS stays flat even
/// on the 256 MiB self-update tarball.
const sha256_read_chunk: usize = 64 * 1024;

/// Stream `file_path` through SHA256 and return the raw 32-byte digest.
/// Used by `update/verify.zig` so the self-update tarball is never
/// read whole into memory.
pub fn hashFileSha256Raw(io: std.Io, file_path: []const u8) ![32]u8 {
    const file = try std.Io.Dir.openFileAbsolute(io, file_path, .{});
    defer file.close(io);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var read_buf: [sha256_read_chunk]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try file.readPositionalAll(io, &read_buf, offset);
        if (n == 0) break;
        hasher.update(read_buf[0..n]);
        offset += n;
        // Short read ⇒ EOF; skip one extra syscall on exact-multiple sizes.
        if (n < read_buf.len) break;
    }
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

/// Lowercase-hex form of `hashFileSha256Raw` — the shape `cask` prefers
/// for comparison with manifest strings.
pub fn hashFileSha256Hex(io: std.Io, file_path: []const u8) ![64]u8 {
    const raw = try hashFileSha256Raw(io, file_path);
    return std.fmt.bytesToHex(raw, .lower);
}

/// Constant-time slice equality. Closes the per-byte timing oracle on
/// hex-SHA compares: stops only after looking at every byte, so an
/// adaptive attacker cannot iterate one byte at a time.
pub fn constantTimeEql(comptime T: type, a: []const T, b: []const T) bool {
    if (a.len != b.len) return false;
    var diff: T = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

test "constantTimeEql returns true for equal byte slices" {
    try std.testing.expect(constantTimeEql(u8, "deadbeef", "deadbeef"));
}

test "constantTimeEql returns false on length mismatch" {
    try std.testing.expect(!constantTimeEql(u8, "abc", "abcd"));
}

test "constantTimeEql returns false on different content" {
    try std.testing.expect(!constantTimeEql(u8, "abcd", "abce"));
}

test "constantTimeEql returns true for empty equal slices" {
    try std.testing.expect(constantTimeEql(u8, "", ""));
}

// Regression guards: the SHA path mixes byte positions, so a wrong
// implementation that early-outs on the first byte or that masks late
// bytes would still pass the smoke matrix above. These pin each
// position end-to-end so an accidental refactor cannot slip past.

test "constantTimeEql distinguishes inputs that differ only at first byte" {
    const a = "0deadbeef" ** 8;
    var b: [a.len]u8 = undefined;
    @memcpy(&b, a);
    b[0] = '1';
    try std.testing.expect(!constantTimeEql(u8, a, &b));
}

test "constantTimeEql distinguishes inputs that differ only at last byte" {
    const a = "deadbeef0" ** 8;
    var b: [a.len]u8 = undefined;
    @memcpy(&b, a);
    b[b.len - 1] = '1';
    try std.testing.expect(!constantTimeEql(u8, a, &b));
}

test "constantTimeEql handles single-byte slices" {
    try std.testing.expect(constantTimeEql(u8, "a", "a"));
    try std.testing.expect(!constantTimeEql(u8, "a", "b"));
}

test "constantTimeEql works on non-u8 elements (generic over T)" {
    const a = [_]u32{ 1, 2, 3, 4 };
    const b = [_]u32{ 1, 2, 3, 4 };
    const c = [_]u32{ 1, 2, 3, 5 };
    try std.testing.expect(constantTimeEql(u32, &a, &b));
    try std.testing.expect(!constantTimeEql(u32, &a, &c));
}
