//! malt — bottle module
//! Bottle download, SHA256 verification, and extraction pipeline.

const std = @import("std");

const archive = @import("../fs/archive.zig");
const client_mod = @import("../net/client.zig");
const ghcr_mod = @import("../net/ghcr.zig");
const hash_mod = @import("hash.zig");

pub const BottleError = error{
    DownloadFailed,
    DownloadPermanent,
    DownloadRateLimited,
    Sha256Mismatch,
    ExtractionFailed,
    OutOfMemory,
    PathTooLong,
    IoError,
};

/// Formats `<dest_dir>/bottle.tar.gz` into `buf`; distinguishes path overflow
/// from allocation failure so callers can surface a precise message.
pub fn buildTmpArchivePath(buf: []u8, dest_dir: []const u8) BottleError![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/bottle.tar.gz", .{dest_dir}) catch
        return BottleError.PathTooLong;
}

pub const BottleResult = struct {
    sha256: []const u8,
    extract_path: []const u8,
};

/// Diagnostic captured when a bottle download's SHA256 doesn't match
/// the expected value. Surfaced via `download`'s `mismatch_info` out-param
/// so the worker can log expected/got/length without re-importing the
/// hash bytes — every transient mismatch in the wild becomes triageable.
pub const MismatchInfo = struct {
    expected: [64]u8,
    computed: [64]u8,
    body_len: u64,
};

/// Pure SHA verification: returns null when `body`'s SHA256 matches the
/// 64-hex-char `expected` value, or a populated `MismatchInfo` otherwise.
/// Split out of `download` so tests can exercise the mismatch surface
/// without spinning up GHCR / an HTTP client.
pub fn checkBottleSha(expected: []const u8, body: []const u8) ?MismatchInfo {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &hash, .{});
    const computed_hex = std.fmt.bytesToHex(hash, .lower);

    // Constant-time compare — deny a byte-by-byte timing oracle against
    // the expected hash.
    if (hash_mod.constantTimeEql(u8, &computed_hex, expected)) return null;

    var info: MismatchInfo = .{
        .expected = undefined,
        .computed = computed_hex,
        .body_len = body.len,
    };
    // Real bottle SHAs are exactly 64 hex chars; pad with NULs if the
    // caller handed us a shorter slice so the diagnostic is still safe
    // to format with `{s}` against `expected[0..n]`.
    const n = @min(expected.len, info.expected.len);
    @memset(&info.expected, 0);
    @memcpy(info.expected[0..n], expected[0..n]);
    return info;
}

/// Download a bottle from GHCR, verify SHA256, and extract to tmp.
/// Returns the SHA256 and path to extracted contents.
///
/// `http` is a caller-owned HttpClient (typically borrowed from a
/// `HttpClientPool`); it must not be used concurrently by any other
/// thread for the duration of this call.
///
/// `mismatch_info` is populated only when the call returns
/// `Sha256Mismatch` — left untouched on every other path so the caller
/// can pre-zero or skip the field.
pub fn download(
    io: std.Io,
    allocator: std.mem.Allocator,
    ghcr: *ghcr_mod.GhcrClient,
    http: *client_mod.HttpClient,
    repo: []const u8,
    digest: []const u8,
    expected_sha256: []const u8,
    dest_dir: []const u8,
    progress: ?client_mod.ProgressCallback,
    mismatch_info: ?*MismatchInfo,
) BottleError!BottleResult {
    // Download blob into memory
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);

    ghcr.downloadBlob(allocator, http, repo, digest, &body, progress) catch |e| {
        return switch (e) {
            ghcr_mod.GhcrError.DownloadHttpClientError => BottleError.DownloadPermanent,
            ghcr_mod.GhcrError.DownloadRateLimited => BottleError.DownloadRateLimited,
            else => BottleError.DownloadFailed,
        };
    };

    if (checkBottleSha(expected_sha256, body.items)) |info| {
        // Clean up dest_dir on mismatch; Sha256Mismatch is the real error.
        std.Io.Dir.cwd().deleteTree(io, dest_dir) catch {};
        if (mismatch_info) |out| out.* = info;
        return BottleError.Sha256Mismatch;
    }

    // Ensure dest_dir exists
    std.Io.Dir.createDirAbsolute(io, dest_dir, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return BottleError.IoError,
    };

    // Write bottle to temp file for extraction
    var tmp_path_buf: [512]u8 = undefined;
    const tmp_path = try buildTmpArchivePath(&tmp_path_buf, dest_dir);

    const tmp_file = std.Io.Dir.createFileAbsolute(io, tmp_path, .{}) catch return BottleError.IoError;
    tmp_file.writeStreamingAll(io, body.items) catch {
        tmp_file.close(io);
        return BottleError.IoError;
    };
    tmp_file.close(io);

    // Extract
    archive.extractTarGz(io, tmp_path, dest_dir) catch return BottleError.ExtractionFailed;

    // Remove the temp archive file; a leftover tmp is harmless, overwritten on retry.
    std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    return .{
        .sha256 = expected_sha256,
        .extract_path = dest_dir,
    };
}

/// Verify SHA256 of a file on disk.
///
/// Streams the file through the centralised SHA256 helper so peak RSS
/// stays bounded by the 64 KiB read chunk, not the bottle size (200-400
/// MB for ffmpeg/llvm).
pub fn verify(io: std.Io, file_path: []const u8, expected_sha256: []const u8) !bool {
    const raw = hash_mod.hashFileSha256Raw(io, file_path) catch return false;
    const computed_hex = std.fmt.bytesToHex(raw, .lower);

    // Constant-time SHA compare — denies a byte-by-byte timing oracle on
    // re-verify-on-disk paths reachable with a remote-controllable hash.
    return hash_mod.constantTimeEql(u8, &computed_hex, expected_sha256);
}

test "verify returns true when sha256 matches on-disk content" {
    const testing = std.testing;
    const io = std.Options.debug_io;
    const base = "/tmp/malt_bottle_verify_ok";
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    std.Io.Dir.createDirAbsolute(io, base, .default_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};

    const path = base ++ "/payload.bin";
    const f = try std.Io.Dir.createFileAbsolute(io, path, .{});
    try f.writeStreamingAll(io, "hello");
    f.close(io);

    // SHA256("hello")
    const expected = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
    try testing.expect(try verify(io, path, expected));
}

test "verify returns false for a mismatching sha256" {
    const testing = std.testing;
    const io = std.Options.debug_io;
    const base = "/tmp/malt_bottle_verify_mismatch";
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    std.Io.Dir.createDirAbsolute(io, base, .default_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};

    const path = base ++ "/payload.bin";
    const f = try std.Io.Dir.createFileAbsolute(io, path, .{});
    try f.writeStreamingAll(io, "hello");
    f.close(io);

    try testing.expect(!try verify(io, path, "00" ** 32));
}

test "verify returns false when the file does not exist" {
    const testing = std.testing;
    try testing.expect(!try verify(std.Options.debug_io, "/tmp/malt_bottle_verify_missing_xyz", "00" ** 32));
}

test "verify rejects mismatches in any position (constant-time-equivalent)" {
    const testing = std.testing;
    const io = std.Options.debug_io;
    const base = "/tmp/malt_bottle_verify_positions";
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    std.Io.Dir.createDirAbsolute(io, base, .default_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};

    const path = base ++ "/payload.bin";
    const f = try std.Io.Dir.createFileAbsolute(io, path, .{});
    try f.writeStreamingAll(io, "hello");
    f.close(io);

    // SHA256("hello"); flip the first, middle, and last hex char in turn.
    const correct = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
    const head_diff = "3cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
    const mid_diff = "2cf24dba5fb0a30e26e83b2ac5b9e29f1b161e5c1fa7425e73043362938b9824";
    const tail_diff = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9825";

    try testing.expect(try verify(io, path, correct));
    try testing.expect(!try verify(io, path, head_diff));
    try testing.expect(!try verify(io, path, mid_diff));
    try testing.expect(!try verify(io, path, tail_diff));
}

test "verify rejects expected_sha256 of wrong length" {
    const testing = std.testing;
    const io = std.Options.debug_io;
    const base = "/tmp/malt_bottle_verify_length";
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    std.Io.Dir.createDirAbsolute(io, base, .default_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};

    const path = base ++ "/payload.bin";
    const f = try std.Io.Dir.createFileAbsolute(io, path, .{});
    try f.writeStreamingAll(io, "hello");
    f.close(io);

    try testing.expect(!try verify(io, path, "2c"));
    try testing.expect(!try verify(io, path, "00" ** 32 ++ "00"));
}

test "verify hashes payloads larger than the streaming chunk without buffering" {
    // 192 KiB > 64 KiB read chunk: forces the streaming hasher across
    // multiple positional reads, exercising the path that real bottles
    // (200-400 MB) hit. RSS stays bounded by the chunk size.
    const testing = std.testing;
    const io = std.Options.debug_io;
    const base = "/tmp/malt_bottle_verify_chunked";
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    std.Io.Dir.createDirAbsolute(io, base, .default_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};

    const size: usize = 192 * 1024;
    const payload = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i);

    const path = base ++ "/payload.bin";
    const f = try std.Io.Dir.createFileAbsolute(io, path, .{});
    try f.writeStreamingAll(io, payload);
    f.close(io);

    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &raw, .{});
    const expected = std.fmt.bytesToHex(raw, .lower);

    try testing.expect(try verify(io, path, &expected));

    var bad = expected;
    bad[0] = if (bad[0] == '0') '1' else '0';
    try testing.expect(!try verify(io, path, &bad));
}

test "buildTmpArchivePath returns PathTooLong for an oversized dest_dir" {
    var buf: [512]u8 = undefined;
    const long_dest = "/" ++ ("a" ** 499);
    try std.testing.expectError(BottleError.PathTooLong, buildTmpArchivePath(&buf, long_dest));
}

test "buildTmpArchivePath joins a normal dest_dir with the archive name" {
    var buf: [512]u8 = undefined;
    const path = try buildTmpArchivePath(&buf, "/tmp/malt_bottle_buildpath_ok");
    try std.testing.expectEqualStrings("/tmp/malt_bottle_buildpath_ok/bottle.tar.gz", path);
}

// ---------------------------------------------------------------------------
// checkBottleSha — pure SHA verification helper extracted from `download`.
// Covers the happy path, the diagnostic path, and pathological inputs. The
// allocator-free contract is what makes `download` testable end-to-end
// without spinning up a fake GHCR.
// ---------------------------------------------------------------------------

test "checkBottleSha returns null for matching SHA" {
    const body = "hello world";
    // SHA256("hello world") = b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9
    const expected = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9";
    try std.testing.expect(checkBottleSha(expected, body) == null);
}

test "checkBottleSha returns null for matching SHA on empty body" {
    // SHA256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    const expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    try std.testing.expect(checkBottleSha(expected, "") == null);
}

test "checkBottleSha returns MismatchInfo with body length when SHA differs" {
    const body = "hello world";
    const wrong = "0000000000000000000000000000000000000000000000000000000000000000";
    const info = checkBottleSha(wrong, body) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(u64, body.len), info.body_len);
    // computed must be the actual SHA of "hello world", lower-hex.
    try std.testing.expectEqualStrings(
        "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9",
        &info.computed,
    );
    // expected must echo the caller's input verbatim in the first 64 bytes.
    try std.testing.expectEqualStrings(wrong, info.expected[0..64]);
}

test "checkBottleSha mismatch on a single byte difference (constant-time-equivalent)" {
    // Flip the last hex char of the correct SHA — must still reject.
    const body = "hello world";
    const off_by_one = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcdea";
    try std.testing.expect(checkBottleSha(off_by_one, body) != null);
}

test "checkBottleSha mismatch on first-byte difference" {
    const body = "hello world";
    const off = "094d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9";
    try std.testing.expect(checkBottleSha(off, body) != null);
}

test "checkBottleSha records body length on a large payload" {
    // Use a one-MiB body; verify body_len matches even when the buffer
    // is larger than typical formula JSON. SHA value isn't asserted here —
    // the property is "len carried through" — which is the diagnostic
    // signal the worker logs.
    const alloc = std.testing.allocator;
    const big = try alloc.alloc(u8, 1024 * 1024);
    defer alloc.free(big);
    @memset(big, 'x');
    const wrong = "0000000000000000000000000000000000000000000000000000000000000000";
    const info = checkBottleSha(wrong, big) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(u64, 1024 * 1024), info.body_len);
}

test "checkBottleSha tolerates an empty expected slice without crashing" {
    // Hostile input: an empty expected hash should never match a real SHA.
    // The constant-time compare returns false on length mismatch (it's
    // strict on length), so we get a populated MismatchInfo back.
    const info = checkBottleSha("", "x") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(u64, 1), info.body_len);
    // expected buffer is zero-filled (no caller bytes to copy).
    for (info.expected) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "checkBottleSha tolerates an oversized expected (longer than 64)" {
    // Pathological: the hex pads beyond 64 chars. Helper truncates to 64
    // for the captured echo (no overflow, no crash), but the comparator
    // sees the full slice — so the result is still "mismatch".
    const long_expected = "a" ** 128;
    const info = checkBottleSha(long_expected, "y") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(u64, 1), info.body_len);
    // First 64 bytes of expected captured.
    for (info.expected) |b| try std.testing.expectEqual(@as(u8, 'a'), b);
}

test "checkBottleSha mismatch when body contains the expected hex literally" {
    // A body whose bytes happen to spell the expected SHA hex must NOT
    // accidentally match — the hash of the bytes is what counts, not
    // the bytes themselves.
    const expected = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef";
    try std.testing.expect(checkBottleSha(expected, expected) != null);
}

test "checkBottleSha is symmetric on body equality (idempotent over identical bytes)" {
    // Same body twice → same SHA → same null/non-null verdict.
    const a = checkBottleSha(
        "0000000000000000000000000000000000000000000000000000000000000000",
        "abc",
    );
    const b = checkBottleSha(
        "0000000000000000000000000000000000000000000000000000000000000000",
        "abc",
    );
    try std.testing.expectEqual(a == null, b == null);
    if (a) |ai| if (b) |bi| {
        try std.testing.expectEqualStrings(&ai.computed, &bi.computed);
        try std.testing.expectEqual(ai.body_len, bi.body_len);
    };
}

test "checkBottleSha computed hash is always lowercase hex" {
    // The diagnostic format compares directly against the caller-supplied
    // `expected` (lowercase by Homebrew API convention). A stray uppercase
    // character would silently mismatch even a correct hash.
    const info = checkBottleSha(
        "0000000000000000000000000000000000000000000000000000000000000000",
        "any-payload",
    ) orelse return error.TestUnexpectedNull;
    for (info.computed) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(ok);
    }
}
