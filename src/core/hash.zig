//! malt — shared streaming SHA256 for file paths.
//!
//! Centralises the read-in-chunks-feed-the-hasher dance so callers that
//! hash large files (self-update tarball, cask artifacts) bound RSS to
//! the chunk size instead of the file size. Raw and hex variants both
//! route through the same `fs_compat.streamFile` loop.

const std = @import("std");
const fs_compat = @import("../fs/compat.zig");

/// One positional read per 64 KiB — large enough to keep syscall
/// overhead in the noise, small enough that peak RSS stays flat even
/// on the 256 MiB self-update tarball.
const sha256_read_chunk: usize = 64 * 1024;

/// Stream `file_path` through SHA256 and return the raw 32-byte digest.
/// Used by `update/verify.zig` so the self-update tarball is never
/// read whole into memory.
pub fn hashFileSha256Raw(file_path: []const u8) ![32]u8 {
    const file = try fs_compat.openFileAbsolute(file_path, .{});
    defer file.close();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var read_buf: [sha256_read_chunk]u8 = undefined;
    try fs_compat.streamFile(file, &read_buf, .{
        .context = @ptrCast(&hasher),
        .func = &sha256Update,
    });
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

/// Lowercase-hex form of `hashFileSha256Raw` — the shape `cask` prefers
/// for comparison with manifest strings.
pub fn hashFileSha256Hex(file_path: []const u8) ![64]u8 {
    const raw = try hashFileSha256Raw(file_path);
    return std.fmt.bytesToHex(raw, .lower);
}

/// Bridge `streamFile`'s erased-context callback to `Sha256.update`.
fn sha256Update(ctx: *anyopaque, chunk: []const u8) fs_compat.StreamError!void {
    const hasher: *std.crypto.hash.sha2.Sha256 = @ptrCast(@alignCast(ctx));
    hasher.update(chunk);
}
