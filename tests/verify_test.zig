//! malt - trust layer tests.
//!
//! SHA256 + checksums.txt parsing are pure. Cosign verification is
//! exercised with a fake `cosign_bin` (a shell script we write to a
//! tmp path) so the test suite has no hard dep on cosign being installed.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const verify = malt.update_verify;
const fs_compat = malt.fs_compat;

// SHA256("hello world")
const HELLO_WORLD_HEX = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9";
// SHA256("")
const EMPTY_HEX = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

// --- verifySha256 ---------------------------------------------------------

test "verifySha256 accepts the correct hex for a known input" {
    try verify.verifySha256("hello world", HELLO_WORLD_HEX);
}

test "verifySha256 is case-insensitive on the expected hex" {
    const upper = "B94D27B9934D3E08A52E52D7DA7DABFAC484EFE37A5380EE9088F7ACE2EFCDE9";
    try verify.verifySha256("hello world", upper);
}

test "verifySha256 rejects a single-bit flip in the expected hex" {
    // Last char: 9 -> 8. One byte differs, mismatch is required.
    const flipped = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde8";
    try testing.expectError(error.ChecksumMismatch, verify.verifySha256("hello world", flipped));
}

test "verifySha256 rejects a tampered input byte" {
    try testing.expectError(error.ChecksumMismatch, verify.verifySha256("hello world!", HELLO_WORLD_HEX));
}

test "verifySha256 rejects wrong hex length" {
    try testing.expectError(error.InvalidHex, verify.verifySha256("hello world", "deadbeef"));
    // 63 chars - one short
    try testing.expectError(
        error.InvalidHex,
        verify.verifySha256("hello world", "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde"),
    );
}

test "verifySha256 rejects non-hex characters" {
    // Same length, but 'z' is not hex.
    const bad = "z94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9";
    try testing.expectError(error.InvalidHex, verify.verifySha256("hello world", bad));
}

test "verifySha256 accepts the empty-bytes digest" {
    try verify.verifySha256("", EMPTY_HEX);
}

// --- lookupSha256 ---------------------------------------------------------

test "lookupSha256 finds a single-line archive" {
    const txt = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9  malt_0.7.0_darwin_all.tar.gz\n";
    const got = verify.lookupSha256(txt, "malt_0.7.0_darwin_all.tar.gz") orelse return error.Missing;
    try testing.expectEqualStrings(HELLO_WORLD_HEX, got);
}

test "lookupSha256 picks the right line among many" {
    const txt =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  other.tar.gz\n" ++
        "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9  malt_0.7.0_darwin_all.tar.gz\n" ++
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc  third.tar.gz\n";
    const got = verify.lookupSha256(txt, "malt_0.7.0_darwin_all.tar.gz") orelse return error.Missing;
    try testing.expectEqualStrings(HELLO_WORLD_HEX, got);
}

test "lookupSha256 tolerates CRLF line endings" {
    const txt = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9  malt_0.7.0_darwin_all.tar.gz\r\n";
    const got = verify.lookupSha256(txt, "malt_0.7.0_darwin_all.tar.gz") orelse return error.Missing;
    try testing.expectEqualStrings(HELLO_WORLD_HEX, got);
}

test "lookupSha256 returns null when the archive is absent" {
    const txt = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  other.tar.gz\n";
    try testing.expect(verify.lookupSha256(txt, "malt_0.7.0_darwin_all.tar.gz") == null);
}

test "lookupSha256 ignores malformed lines without crashing" {
    // First line is garbage; second line is a valid match. The matcher
    // must skip the broken line, not bail the whole scan.
    const txt =
        "not-even-hex\n" ++
        "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9  malt_0.7.0_darwin_all.tar.gz\n";
    const got = verify.lookupSha256(txt, "malt_0.7.0_darwin_all.tar.gz") orelse return error.Missing;
    try testing.expectEqualStrings(HELLO_WORLD_HEX, got);
}

// --- verifyCosignBlob -----------------------------------------------------

/// Write a shell script to `path` that exits with `exit_code` when run,
/// and chmod it executable. Used as a drop-in `cosign_bin` so tests can
/// exercise the subprocess path without depending on real cosign.
fn writeFakeCosign(path: []const u8, exit_code: u8) !void {
    fs_compat.deleteFileAbsolute(path) catch {};
    const f = try fs_compat.createFileAbsolute(path, .{});
    defer f.close();
    var buf: [64]u8 = undefined;
    const script = try std.fmt.bufPrint(&buf, "#!/bin/sh\nexit {d}\n", .{exit_code});
    try f.writeAll(script);
    try f.chmod(0o755);
}

const fake_args = verify.CosignBlob{
    .blob_path = "/tmp/does-not-need-to-exist",
    .bundle_path = "/tmp/does-not-need-to-exist.sigstore.json",
    .cert_identity_regex = "^https://example\\.com/",
    .oidc_issuer = "https://example.com",
};

test "verifyCosignBlob returns CosignNotFound when the binary is missing" {
    var args = fake_args;
    args.cosign_bin = "/tmp/malt_nonexistent_cosign_xyz_99";
    try testing.expectError(error.CosignNotFound, verify.verifyCosignBlob(testing.allocator, args));
}

test "verifyCosignBlob accepts a cosign that exits 0" {
    const path = "/tmp/malt_fake_cosign_ok";
    try writeFakeCosign(path, 0);
    defer fs_compat.deleteFileAbsolute(path) catch {};

    var args = fake_args;
    args.cosign_bin = path;
    try verify.verifyCosignBlob(testing.allocator, args);
}

test "verifyCosignBlob errors when cosign exits non-zero" {
    const path = "/tmp/malt_fake_cosign_fail";
    try writeFakeCosign(path, 1);
    defer fs_compat.deleteFileAbsolute(path) catch {};

    var args = fake_args;
    args.cosign_bin = path;
    try testing.expectError(error.CosignVerifyFailed, verify.verifyCosignBlob(testing.allocator, args));
}
