//! malt — bottle.zig integration tests
//! Covers the SHA verification surface (`checkBottleSha` + `MismatchInfo`)
//! and the `isDeterministicDownloadError` classifier reachable through the
//! install facade. The full network-driven `bottle.download` path stays
//! out of scope — these tests pin the *pure* invariants the worker relies
//! on so the diagnostic message format is stable and the retry gate keeps
//! transient SHA mismatches retriable.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const bottle = malt.bottle;
const install_download = malt.install_download;

// ---------------------------------------------------------------------------
// MismatchInfo shape — pinned so the worker's log format never drifts
// silently (worker formats `info.expected[0..64]` and `info.computed[0..]`).
// ---------------------------------------------------------------------------

test "MismatchInfo struct shape: 64-byte expected, 64-byte computed, u64 length" {
    // Comptime guards. If anyone changes the field types, the worker's
    // {s} formatter will start producing wrong-shape output silently.
    comptime {
        const Info = bottle.MismatchInfo;
        std.debug.assert(@sizeOf(@FieldType(Info, "expected")) == 64);
        std.debug.assert(@sizeOf(@FieldType(Info, "computed")) == 64);
        std.debug.assert(@FieldType(Info, "body_len") == u64);
    }
}

// ---------------------------------------------------------------------------
// checkBottleSha — happy path against vector hashes from RFC test corpus
// and Homebrew-style 64-hex bodies.
// ---------------------------------------------------------------------------

test "checkBottleSha: SHA matches a 64-byte body of mixed bytes" {
    // SHA256(0x00..0x3F) — deterministic, easily re-derivable.
    const body = [_]u8{
        0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15,
        16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
        32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47,
        48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
    };
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&body, &hash, .{});
    const expected = std.fmt.bytesToHex(hash, .lower);
    try testing.expect(bottle.checkBottleSha(&expected, &body) == null);
}

test "checkBottleSha: byte-level fuzz — any single-byte body change invalidates the hash" {
    // The pure helper is the only thing standing between the install
    // pipeline and an attacker who can flip a single bottle byte. Walk
    // all 256 trailing-byte variants of an 8-byte body and confirm only
    // the canonical one passes.
    var body = [_]u8{ 'h', 'e', 'l', 'l', 'o', '_', '_', 0 };
    var hash: [32]u8 = undefined;
    body[7] = 0x42;
    std.crypto.hash.sha2.Sha256.hash(&body, &hash, .{});
    const canonical_expected = std.fmt.bytesToHex(hash, .lower);
    try testing.expect(bottle.checkBottleSha(&canonical_expected, &body) == null);

    var i: u16 = 0;
    while (i < 256) : (i += 1) {
        if (i == 0x42) continue;
        body[7] = @intCast(i);
        try testing.expect(bottle.checkBottleSha(&canonical_expected, &body) != null);
    }
}

// ---------------------------------------------------------------------------
// Diagnostic surface invariants — these are what the worker formats into
// its error line, so a regression here would silently degrade triage.
// ---------------------------------------------------------------------------

test "MismatchInfo.body_len is the actual byte count, not a clamped value" {
    // Real bottles run 200-400 MiB; the diagnostic must carry the full
    // size so a half-truncated body is visible from the log alone.
    const alloc = testing.allocator;
    const big_size: usize = 64 * 1024 * 1024 + 7; // odd size so off-by-one shows up
    const big = try alloc.alloc(u8, big_size);
    defer alloc.free(big);
    @memset(big, 0xAB);
    const wrong = "0" ** 64;
    const info = bottle.checkBottleSha(wrong, big) orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(u64, big_size), info.body_len);
}

test "MismatchInfo.expected echoes caller bytes verbatim (no normalisation)" {
    // The worker's log compares the printed `expected` to the API JSON;
    // any normalisation (case fold, trim, etc.) would break the visual
    // diff a user does between the API hash and the log line.
    const expected = "DeAdBeEfDeAdBeEfDeAdBeEfDeAdBeEfDeAdBeEfDeAdBeEfDeAdBeEfDeAdBeEf";
    const info = bottle.checkBottleSha(expected, "x") orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings(expected, info.expected[0..64]);
}

test "MismatchInfo.computed is independent from MismatchInfo.expected (no aliasing)" {
    // Pin the no-aliasing invariant: computed must reflect the real hash
    // of the body, never a copy of expected. A trivial bug ("if mismatch,
    // return expected for both") would silently make the diagnostic
    // useless — assert by comparing computed to a known SHA.
    const body = "xyz"; // SHA256 = 3608bca1e44ea6c4d268eb6db02260269892c0b42b86bbf1e77a6fa16c3c9282
    const wrong = "0" ** 64;
    const info = bottle.checkBottleSha(wrong, body) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings(
        "3608bca1e44ea6c4d268eb6db02260269892c0b42b86bbf1e77a6fa16c3c9282",
        &info.computed,
    );
    try testing.expect(!std.mem.eql(u8, &info.computed, info.expected[0..64]));
}

// ---------------------------------------------------------------------------
// isDeterministicDownloadError — reachable through the install facade so
// the test isn't tied to internal module layout.
// ---------------------------------------------------------------------------

test "install_download.isDeterministicDownloadError: Sha256Mismatch is retriable (regression guard)" {
    // The single highest-value assertion in this file: if a future
    // refactor moves Sha256Mismatch back into the deterministic set,
    // a transient corruption-in-flight will fail the install with a
    // non-actionable message. Pin it here.
    try testing.expect(!install_download.isDeterministicDownloadError(bottle.BottleError.Sha256Mismatch));
}

test "install_download.isDeterministicDownloadError: ExtractionFailed is non-retriable" {
    try testing.expect(install_download.isDeterministicDownloadError(bottle.BottleError.ExtractionFailed));
}

test "install_download.isDeterministicDownloadError: PathTooLong is non-retriable" {
    try testing.expect(install_download.isDeterministicDownloadError(bottle.BottleError.PathTooLong));
}

test "install_download.isDeterministicDownloadError: OutOfMemory is non-retriable" {
    try testing.expect(install_download.isDeterministicDownloadError(bottle.BottleError.OutOfMemory));
}

test "install_download.isDeterministicDownloadError: transport errors all retry" {
    // The full set of network-side errors that should pass back through
    // the retry budget. Listing them explicitly so a new variant can't
    // be silently classified by future maintainers.
    try testing.expect(!install_download.isDeterministicDownloadError(bottle.BottleError.DownloadFailed));
    try testing.expect(!install_download.isDeterministicDownloadError(bottle.BottleError.DownloadRateLimited));
    try testing.expect(!install_download.isDeterministicDownloadError(bottle.BottleError.IoError));
}

// ---------------------------------------------------------------------------
// Verify (existing surface) — round-trip a body through `checkBottleSha`
// and `verify` to confirm the on-disk and in-memory paths agree on the
// same SHA contract.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Worker log line shape — the exact format string the worker uses to
// surface a SHA mismatch. Tested here so a renamed field or a swapped
// `{s}` argument is caught without exercising the full GHCR pipeline.
// ---------------------------------------------------------------------------

test "MismatchInfo formats cleanly through the worker's log template" {
    // Stand in for the worker's `output.err(..., expected, computed, body_len)`
    // line. We don't capture stderr here — instead, format into a buffer
    // with the exact same format string and confirm:
    //   1. Both 64-byte hex fields land in full.
    //   2. The body length lands as a decimal.
    //   3. The result fits inside `output`'s 4 KiB internal scratch
    //      buffer (the worker would silently drop a too-long line).
    var info: bottle.MismatchInfo = .{
        .expected = undefined,
        .computed = undefined,
        .body_len = 36308387,
    };
    const exp = "12b55d2efffbc6fc65f471ff989703934fee7f55e60887e400c8c18abd1b3baf";
    const got = "0000000000000000000000000000000000000000000000000000000000000000";
    @memcpy(&info.expected, exp);
    @memcpy(&info.computed, got);

    var buf: [4096]u8 = undefined;
    const line = try std.fmt.bufPrint(
        &buf,
        "  zig: Sha256Mismatch (expected={s} got={s} bytes={d})",
        .{ info.expected[0..@min(64, info.expected.len)], info.computed[0..], info.body_len },
    );

    try testing.expect(std.mem.indexOf(u8, line, exp) != null);
    try testing.expect(std.mem.indexOf(u8, line, got) != null);
    try testing.expect(std.mem.indexOf(u8, line, "bytes=36308387") != null);
    try testing.expect(line.len < 4096);
}

test "checkBottleSha and verify agree on the same body's SHA" {
    const test_io = @import("test_io");
    const path = try std.fmt.allocPrint(
        testing.allocator,
        "/tmp/malt_bottle_roundtrip_{d}",
        .{test_io.nanoTimestamp(std.Options.debug_io)},
    );
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};

    const body = "round-trip test payload — non-empty, smaller than the streaming chunk";
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, path, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, body);
    }

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &hash, .{});
    const sha_hex = std.fmt.bytesToHex(hash, .lower);

    // Both routes agree this body matches its hash.
    try testing.expect(bottle.checkBottleSha(&sha_hex, body) == null);
    try testing.expect(try bottle.verify(std.Options.debug_io, path, &sha_hex));

    // And both reject the same wrong hash.
    const wrong = "0" ** 64;
    try testing.expect(bottle.checkBottleSha(wrong, body) != null);
    try testing.expect(!(try bottle.verify(std.Options.debug_io, path, wrong)));
}
