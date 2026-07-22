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

/// Compare a computed lowercase-hex SHA256 against an expected one. Only the
/// length may short-circuit — a hash's length is public; the bytes go through
/// the stdlib's constant-time compare so every SHA path stays uniform.
pub fn eqlHex256(computed: [64]u8, expected: []const u8) bool {
    if (expected.len != computed.len) return false;
    return std.crypto.timing_safe.eql([64]u8, computed, expected[0..64].*);
}

test "eqlHex256 matches a digest against its own hex string" {
    const computed = "d".* ++ ("eadbeef" ** 9).*;
    try std.testing.expect(eqlHex256(computed, &computed));
}

test "eqlHex256 rejects a difference in the last byte" {
    const computed = ("deadbeef" ** 8).*;
    var expected = computed;
    expected[expected.len - 1] = '0';
    try std.testing.expect(!eqlHex256(computed, &expected));
}

test "eqlHex256 rejects a difference in the first byte" {
    const computed = ("deadbeef" ** 8).*;
    var expected = computed;
    expected[0] = '0';
    try std.testing.expect(!eqlHex256(computed, &expected));
}

test "eqlHex256 rejects an expected hash that is not 64 chars" {
    const computed = ("deadbeef" ** 8).*;
    try std.testing.expect(!eqlHex256(computed, computed[0..63]));
    try std.testing.expect(!eqlHex256(computed, computed ++ "0"));
    try std.testing.expect(!eqlHex256(computed, ""));
}

test "eqlHex256 is byte-exact, not case-insensitive" {
    const computed = ("deadbeef" ** 8).*;
    try std.testing.expect(!eqlHex256(computed, "DEADBEEF" ** 8));
}
