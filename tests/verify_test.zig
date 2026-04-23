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

// libc env mutators: Zig 0.16 has no std wrapper for these and the
// regression test needs a scoped PATH change to prove bare-name lookup.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "verifyCosignBlob finds a bare 'cosign' via PATH (regression: gh#151)" {
    // Before: `fs_compat.Child.spawn` initialized Threaded with an empty
    // environ, so PATH resolution fell back to Zig's hard-coded
    // `/usr/local/bin:/bin/:/usr/bin` and missed `/opt/homebrew/bin`. Drop
    // a fake `cosign` into a scratch dir, prepend to PATH, and assert
    // bare-name spawn resolves it.
    const dir = "/tmp/malt_cosign_path_lookup";
    fs_compat.deleteTreeAbsolute(dir) catch {};
    try fs_compat.makeDirAbsolute(dir);
    defer fs_compat.deleteTreeAbsolute(dir) catch {};

    try writeFakeCosign(dir ++ "/cosign", 0);

    // Snapshot PATH before mutating: `getenv` points into libc's environ,
    // which `setenv` may realloc, so copy into a stable sentinel buffer.
    // PATH is a colon-joined list, so size the buffer generously.
    var orig_buf: [8192]u8 = undefined;
    const orig_raw = fs_compat.getenv("PATH") orelse "";
    if (orig_raw.len >= orig_buf.len) return error.SkipZigTest;
    @memcpy(orig_buf[0..orig_raw.len], orig_raw);
    orig_buf[orig_raw.len] = 0;

    var new_path_buf: [8192]u8 = undefined;
    const new_path = try std.fmt.bufPrintZ(&new_path_buf, "{s}:{s}", .{ dir, orig_raw });
    if (setenv("PATH", new_path.ptr, 1) != 0) return error.SetEnvFailed;
    defer _ = if (orig_raw.len == 0) unsetenv("PATH") else setenv("PATH", @ptrCast(&orig_buf), 1);

    var args = fake_args;
    args.cosign_bin = "cosign";
    try verify.verifyCosignBlob(testing.allocator, args);
}

// --- verifyAll (end-to-end, local fixtures) ------------------------------
//
// Exercises the composed trust chain without HTTP: caller stages three
// files on disk, verifyAll runs cosign + SHA256 and either succeeds or
// refuses. Covers every failure mode the updater must catch.

const HELLO_WORLD_HEX_LINE = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9  malt_0.7.0_darwin_all.tar.gz\n";
const ARCHIVE_NAME = "malt_0.7.0_darwin_all.tar.gz";

const Fixture = struct {
    dir: []const u8,
    tarball: []const u8,
    checksums: []const u8,
    sigstore: []const u8,
    cosign_bin: []const u8,

    fn setup(allocator: std.mem.Allocator, tag: []const u8, tarball_bytes: []const u8, checksums_bytes: []const u8, cosign_exit: u8) !Fixture {
        const dir = try std.fmt.allocPrint(allocator, "/tmp/malt_verifyall_{s}", .{tag});
        fs_compat.deleteTreeAbsolute(dir) catch {};
        try fs_compat.makeDirAbsolute(dir);

        const tarball = try std.fmt.allocPrint(allocator, "{s}/malt.tgz", .{dir});
        const checksums = try std.fmt.allocPrint(allocator, "{s}/checksums.txt", .{dir});
        const sigstore = try std.fmt.allocPrint(allocator, "{s}/checksums.txt.sigstore.json", .{dir});
        const cosign_bin = try std.fmt.allocPrint(allocator, "{s}/fake_cosign", .{dir});

        try writeFile(tarball, tarball_bytes);
        try writeFile(checksums, checksums_bytes);
        try writeFile(sigstore, "{}"); // content doesn't matter; fake cosign ignores it
        try writeFakeCosign(cosign_bin, cosign_exit);

        return .{
            .dir = dir,
            .tarball = tarball,
            .checksums = checksums,
            .sigstore = sigstore,
            .cosign_bin = cosign_bin,
        };
    }

    fn deinit(self: *const Fixture, allocator: std.mem.Allocator) void {
        fs_compat.deleteTreeAbsolute(self.dir) catch {};
        allocator.free(self.dir);
        allocator.free(self.tarball);
        allocator.free(self.checksums);
        allocator.free(self.sigstore);
        allocator.free(self.cosign_bin);
    }

    fn inputs(self: *const Fixture) verify.VerifyInputs {
        return .{
            .cosign_bin = self.cosign_bin,
            .tarball_path = self.tarball,
            .checksums_path = self.checksums,
            .sigstore_path = self.sigstore,
            .archive_name = ARCHIVE_NAME,
            .cert_identity_regex = "^https://example\\.com/",
            .oidc_issuer = "https://example.com",
        };
    }
};

fn writeFile(path: []const u8, content: []const u8) !void {
    const f = try fs_compat.createFileAbsolute(path, .{});
    defer f.close();
    try f.writeAll(content);
}

test "verifyAll accepts a valid tarball + matching checksum + good cosign" {
    var fx = try Fixture.setup(testing.allocator, "happy", "hello world", HELLO_WORLD_HEX_LINE, 0);
    defer fx.deinit(testing.allocator);
    try verify.verifyAll(testing.allocator, fx.inputs());
}

test "verifyAll rejects a tampered tarball (SHA256 mismatch)" {
    var fx = try Fixture.setup(testing.allocator, "sha_mismatch", "hello WORLD", HELLO_WORLD_HEX_LINE, 0);
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.ChecksumMismatch, verify.verifyAll(testing.allocator, fx.inputs()));
}

test "verifyAll rejects when checksums.txt omits the archive" {
    const unrelated = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  other.tar.gz\n";
    var fx = try Fixture.setup(testing.allocator, "missing_entry", "hello world", unrelated, 0);
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.ChecksumMissing, verify.verifyAll(testing.allocator, fx.inputs()));
}

test "verifyAll rejects when cosign exits non-zero (signature tampered)" {
    var fx = try Fixture.setup(testing.allocator, "cosign_fail", "hello world", HELLO_WORLD_HEX_LINE, 1);
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.CosignVerifyFailed, verify.verifyAll(testing.allocator, fx.inputs()));
}

test "verifyAll reports CosignNotFound when the binary is missing" {
    var fx = try Fixture.setup(testing.allocator, "no_cosign", "hello world", HELLO_WORLD_HEX_LINE, 0);
    defer fx.deinit(testing.allocator);
    var inputs = fx.inputs();
    inputs.cosign_bin = "/tmp/malt_verifyall_absent_cosign_xyz";
    try testing.expectError(error.CosignNotFound, verify.verifyAll(testing.allocator, inputs));
}

test "verifyAll reports ReadFailed when the tarball cannot be read" {
    var fx = try Fixture.setup(testing.allocator, "missing_tarball", "hello world", HELLO_WORLD_HEX_LINE, 0);
    defer fx.deinit(testing.allocator);
    try fs_compat.deleteFileAbsolute(fx.tarball);
    try testing.expectError(error.ReadFailed, verify.verifyAll(testing.allocator, fx.inputs()));
}

// --- verifyAll (multi-chunk tarball) --------------------------------------
//
// Pins the tarball-hashing path across the switch to streaming SHA256.
// A 160 KiB payload (2.5x the 64 KiB read chunk) forces the stream
// loop through multiple iterations — if any later chunk ever stops
// reaching the hasher, these tests catch it.

fn patternedPayload(alloc: std.mem.Allocator, size: usize) ![]u8 {
    const buf = try alloc.alloc(u8, size);
    for (buf, 0..) |*b, i| b.* = @intCast((i *% 131 +% 7) & 0xFF);
    return buf;
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    return std.fmt.bytesToHex(raw, .lower);
}

test "verifyAll streams a large tarball without loading it whole (smoke)" {
    // Gated: MALT_VERIFY_SMOKE_MIB=N enables a realistic self-update-sized
    // run. Measured under `/usr/bin/time -l`, peak RSS stays flat as N
    // grows — the fixture below writes the tarball in 64 KiB chunks so
    // the test itself never holds the whole payload in memory.
    const env = fs_compat.getenv("MALT_VERIFY_SMOKE_MIB") orelse return error.SkipZigTest;
    const mib = std.fmt.parseInt(usize, env, 10) catch return error.SkipZigTest;
    if (mib == 0) return error.SkipZigTest;
    const total: usize = mib * 1024 * 1024;

    const dir = "/tmp/malt_verifyall_smoke";
    fs_compat.deleteTreeAbsolute(dir) catch {};
    try fs_compat.makeDirAbsolute(dir);
    defer fs_compat.deleteTreeAbsolute(dir) catch {};

    const tarball = try std.fmt.allocPrint(testing.allocator, "{s}/malt.tgz", .{dir});
    defer testing.allocator.free(tarball);
    const checksums = try std.fmt.allocPrint(testing.allocator, "{s}/checksums.txt", .{dir});
    defer testing.allocator.free(checksums);
    const sigstore = try std.fmt.allocPrint(testing.allocator, "{s}/checksums.txt.sigstore.json", .{dir});
    defer testing.allocator.free(sigstore);
    const cosign_bin = try std.fmt.allocPrint(testing.allocator, "{s}/fake_cosign", .{dir});
    defer testing.allocator.free(cosign_bin);

    // Stream-write the tarball while hashing the same bytes. A 64 KiB
    // pattern buffer is the only payload-sized allocation this test makes.
    var chunk: [64 * 1024]u8 = undefined;
    for (&chunk, 0..) |*b, i| b.* = @intCast((i *% 131 +% 7) & 0xFF);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    {
        const tf = try fs_compat.createFileAbsolute(tarball, .{});
        defer tf.close();
        var remaining = total;
        while (remaining > 0) {
            const n = @min(remaining, chunk.len);
            try tf.writeAll(chunk[0..n]);
            hasher.update(chunk[0..n]);
            remaining -= n;
        }
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);

    const line = try std.fmt.allocPrint(
        testing.allocator,
        "{s}  {s}\n",
        .{ hex, ARCHIVE_NAME },
    );
    defer testing.allocator.free(line);
    try writeFile(checksums, line);

    try writeFile(sigstore, "{}");
    try writeFakeCosign(cosign_bin, 0);

    try verify.verifyAll(testing.allocator, .{
        .cosign_bin = cosign_bin,
        .tarball_path = tarball,
        .checksums_path = checksums,
        .sigstore_path = sigstore,
        .archive_name = ARCHIVE_NAME,
        .cert_identity_regex = "^https://example\\.com/",
        .oidc_issuer = "https://example.com",
    });
}

test "verifyAll accepts a multi-chunk tarball whose hash matches" {
    const payload = try patternedPayload(testing.allocator, 160 * 1024);
    defer testing.allocator.free(payload);

    const hex = sha256Hex(payload);
    const line = try std.fmt.allocPrint(
        testing.allocator,
        "{s}  {s}\n",
        .{ hex, ARCHIVE_NAME },
    );
    defer testing.allocator.free(line);

    var fx = try Fixture.setup(testing.allocator, "multi_ok", payload, line, 0);
    defer fx.deinit(testing.allocator);
    try verify.verifyAll(testing.allocator, fx.inputs());
}

test "verifyAll rejects a multi-chunk tarball whose content was tampered" {
    const payload = try patternedPayload(testing.allocator, 160 * 1024);
    defer testing.allocator.free(payload);

    const hex = sha256Hex(payload);
    const line = try std.fmt.allocPrint(
        testing.allocator,
        "{s}  {s}\n",
        .{ hex, ARCHIVE_NAME },
    );
    defer testing.allocator.free(line);

    // Flip one byte deep inside the second chunk — within the range
    // that the old chunk-0-only bug used to skip.
    const tampered = try testing.allocator.dupe(u8, payload);
    defer testing.allocator.free(tampered);
    tampered[80 * 1024] ^= 0x01;

    var fx = try Fixture.setup(testing.allocator, "multi_bad", tampered, line, 0);
    defer fx.deinit(testing.allocator);
    try testing.expectError(error.ChecksumMismatch, verify.verifyAll(testing.allocator, fx.inputs()));
}

test "verifyCosignBlob errors when cosign exits non-zero" {
    const path = "/tmp/malt_fake_cosign_fail";
    try writeFakeCosign(path, 1);
    defer fs_compat.deleteFileAbsolute(path) catch {};

    var args = fake_args;
    args.cosign_bin = path;
    try testing.expectError(error.CosignVerifyFailed, verify.verifyCosignBlob(testing.allocator, args));
}
