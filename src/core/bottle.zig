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

/// SHA verification for the streaming download: given the digest the tee
/// computed while writing the bottle to disk (no `body` slice survives to
/// re-hash) and the byte count, returns null on a match or a populated
/// `MismatchInfo` otherwise. Split out of `download` so tests can exercise the
/// mismatch surface without spinning up GHCR / an HTTP client.
pub fn checkStreamedSha(expected: []const u8, computed_hex: [64]u8, body_len: u64) ?MismatchInfo {
    // Bottle SHAs from the API are public: constant-time here is for
    // uniformity across malt's SHA paths, not to close a live oracle.
    if (hash_mod.eqlHex256(computed_hex, expected)) return null;

    var info: MismatchInfo = .{
        .expected = undefined,
        .computed = computed_hex,
        .body_len = body_len,
    };
    // Real bottle SHAs are exactly 64 hex chars; pad with NULs if the
    // caller handed us a shorter slice so the diagnostic is still safe
    // to format with `{s}` against `expected[0..n]`.
    const n = @min(expected.len, info.expected.len);
    @memset(&info.expected, 0);
    @memcpy(info.expected[0..n], expected[0..n]);
    return info;
}

/// Streaming sink that tees every drained chunk to a temp file *and* a
/// `Sha256` hasher in one pass, so the bottle is hashed as it is written to
/// disk — peak RSS stays bounded by the transfer buffer, never the bottle
/// size. It sits *below* net's `CountingWriter` (which caps + reports), so
/// chunks reaching here are already cap-checked and counted. Same
/// `@fieldParentPtr("writer", …)` vtable shape as that precedent.
const HashingFileSink = struct {
    io: std.Io,
    file: std.Io.File,
    hasher: std.crypto.hash.sha2.Sha256,
    len: u64,
    writer: std.Io.Writer,

    fn init(io: std.Io, file: std.Io.File) HashingFileSink {
        return .{
            .io = io,
            .file = file,
            .hasher = std.crypto.hash.sha2.Sha256.init(.{}),
            .len = 0,
            .writer = .{ .buffer = &.{}, .vtable = &vtable },
        };
    }

    const vtable: std.Io.Writer.VTable = .{ .drain = drain };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        // @alignCast is sound: `w` always points at the `writer` field of a
        // properly aligned `HashingFileSink` (created by `init`).
        const self: *HashingFileSink = @alignCast(@fieldParentPtr("writer", w));
        var written: usize = 0;
        // All but the last slice are written once; the last is repeated `splat`
        // times (mirrors std.Io.Writer's drain contract).
        for (data[0 .. data.len - 1]) |bytes| {
            try self.feed(bytes);
            written += bytes.len;
        }
        const pattern = data[data.len - 1];
        var i: usize = 0;
        while (i < splat) : (i += 1) try self.feed(pattern);
        written += pattern.len * splat;
        return written;
    }

    fn feed(self: *HashingFileSink, bytes: []const u8) std.Io.Writer.Error!void {
        if (bytes.len == 0) return;
        // Tee: same bytes to the file and the hasher, so the on-disk archive
        // and the digest can never diverge.
        self.file.writeStreamingAll(self.io, bytes) catch return error.WriteFailed;
        self.hasher.update(bytes);
        self.len += @intCast(bytes.len);
    }
};

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
    _ = allocator; // Signature kept stable for callers; the streaming path is allocation-free.

    // Create dest_dir and the temp file *before* the first byte arrives — the
    // bottle streams straight to disk while hashing, so there is no in-RAM copy.
    std.Io.Dir.createDirAbsolute(io, dest_dir, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return BottleError.IoError,
    };

    var tmp_path_buf: [512]u8 = undefined;
    const tmp_path = try buildTmpArchivePath(&tmp_path_buf, dest_dir);

    // `truncate = true` so a leftover tmp from a prior attempt can't leak a
    // longer tail into the extract step.
    const tmp_file = std.Io.Dir.createFileAbsolute(io, tmp_path, .{ .truncate = true }) catch
        return BottleError.IoError;

    // The temp file exists before the SHA is known, so every early return must
    // remove it. It lives inside dest_dir, so wiping the tree drops both the
    // partial (or over-cap) archive and the dir — nothing unverified can reach
    // extract, and the outer install loop retries with a fresh temp dir.
    errdefer std.Io.Dir.cwd().deleteTree(io, dest_dir) catch {};

    var sink = HashingFileSink.init(io, tmp_file);
    const dl = ghcr.downloadBlob(http, repo, digest, &sink.writer, progress);
    tmp_file.close(io); // fd no longer needed; extract reopens by path
    dl catch |e| return switch (e) {
        ghcr_mod.GhcrError.DownloadHttpClientError => BottleError.DownloadPermanent,
        ghcr_mod.GhcrError.DownloadRateLimited => BottleError.DownloadRateLimited,
        else => BottleError.DownloadFailed,
    };

    var raw: [32]u8 = undefined;
    sink.hasher.final(&raw);
    const computed_hex = std.fmt.bytesToHex(raw, .lower);

    if (checkStreamedSha(expected_sha256, computed_hex, sink.len)) |info| {
        // errdefer wipes the temp + dest_dir; an unverified bottle never extracts.
        if (mismatch_info) |out| out.* = info;
        return BottleError.Sha256Mismatch;
    }

    // Verified: extract the stored archive, then drop the temp file.
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

    // Bottle SHAs from the API are public: constant-time here is for
    // uniformity across malt's SHA paths, not to close a live oracle.
    return hash_mod.eqlHex256(computed_hex, expected_sha256);
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
// checkStreamedSha — the compare + diagnostic construction the streaming
// download drives after the tee finalizes its digest. Covers the match path,
// the diagnostic payload, and pathological `expected` inputs.
// ---------------------------------------------------------------------------

test "checkStreamedSha returns null when computed matches expected" {
    const expected = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9";
    var computed: [64]u8 = undefined;
    @memcpy(&computed, expected);
    try std.testing.expect(checkStreamedSha(expected, computed, 11) == null);
}

test "checkStreamedSha carries computed and a 400MB body_len into MismatchInfo" {
    const expected = "0000000000000000000000000000000000000000000000000000000000000000";
    var computed: [64]u8 = undefined;
    @memcpy(&computed, "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9");
    const big_len: u64 = 400 * 1024 * 1024;
    const info = checkStreamedSha(expected, computed, big_len) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings(&computed, &info.computed);
    try std.testing.expectEqual(big_len, info.body_len);
    try std.testing.expectEqualStrings(expected, info.expected[0..64]);
}

test "checkStreamedSha over a freshly hashed body matches the good SHA and rejects a wrong one" {
    // Mirrors the production sequence (hash-while-writing → compare) on a real
    // body: the correct digest passes, a wrong `expected` yields a diagnostic
    // carrying the true computed digest, the echoed expected, and the length.
    const body = "hello world";
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &h, .{});
    const computed = std.fmt.bytesToHex(h, .lower);

    const good = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9";
    try std.testing.expect(checkStreamedSha(good, computed, body.len) == null);

    const wrong = "0000000000000000000000000000000000000000000000000000000000000000";
    const info = checkStreamedSha(wrong, computed, body.len) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings(&computed, &info.computed);
    try std.testing.expectEqualStrings(wrong, info.expected[0..64]);
    try std.testing.expectEqual(@as(u64, body.len), info.body_len);
}

test "checkStreamedSha tolerates empty and oversized expected without crashing" {
    var computed: [64]u8 = undefined;
    @memset(&computed, 'a');

    const empty_info = checkStreamedSha("", computed, 1) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(u64, 1), empty_info.body_len);
    for (empty_info.expected) |byte| try std.testing.expectEqual(@as(u8, 0), byte);

    const long_info = checkStreamedSha("b" ** 128, computed, 1) orelse return error.TestUnexpectedNull;
    for (long_info.expected) |byte| try std.testing.expectEqual(@as(u8, 'b'), byte);
}

// ---------------------------------------------------------------------------
// HashingFileSink — the tee that folds the SHA into the write stream. Feeding
// it a chunked byte sequence (a multi-slice drain and a splat) must leave the
// temp file byte-equal to the input, produce a digest identical to a one-shot
// hash of the same bytes, and count every byte in `len`.
// ---------------------------------------------------------------------------

test "HashingFileSink tees each chunk to the file and the hasher" {
    const io = std.Options.debug_io;
    const base = "/tmp/malt_hashing_file_sink";
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    std.Io.Dir.createDirAbsolute(io, base, .default_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};

    const path = base ++ "/bottle.tar.gz";
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });

    var sink = HashingFileSink.init(io, file);
    const w = &sink.writer;

    // Multiple drain calls — a single slice, a two-slice call, and a splat —
    // mirror how streamRemaining fans decompressed chunks into the sink.
    try std.testing.expectEqual(@as(usize, 9), try w.vtable.drain(w, &.{"chunk-one"}, 1));
    try std.testing.expectEqual(@as(usize, 4), try w.vtable.drain(w, &.{ "AB", "CD" }, 1));
    try std.testing.expectEqual(@as(usize, 6), try w.vtable.drain(w, &.{"xy"}, 3));
    file.close(io);

    const input = "chunk-one" ++ "AB" ++ "CD" ++ "xyxyxy";

    // Finalized digest equals a one-shot hash of the exact streamed bytes.
    var raw: [32]u8 = undefined;
    sink.hasher.final(&raw);
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, &raw);

    // File on disk holds exactly the concatenated stream (re-hash it).
    const expected_hex = std.fmt.bytesToHex(expected, .lower);
    try std.testing.expect(try verify(io, path, &expected_hex));

    // `len` counts every teed byte.
    try std.testing.expectEqual(@as(u64, input.len), sink.len);
}

test "HashingFileSink drain tolerates empty chunks and a zero splat" {
    // Boundary cases of the drain contract: an empty slice contributes
    // nothing, and a zero splat writes the pattern zero times. Both must leave
    // the file, digest, and len consistent with the bytes actually written.
    const io = std.Options.debug_io;
    const base = "/tmp/malt_hashing_file_sink_edge";
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    std.Io.Dir.createDirAbsolute(io, base, .default_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};

    const path = base ++ "/bottle.tar.gz";
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });

    var sink = HashingFileSink.init(io, file);
    const w = &sink.writer;

    // Empty leading slice is skipped; the pattern is written once.
    try std.testing.expectEqual(@as(usize, 3), try w.vtable.drain(w, &.{ "", "abc" }, 1));
    // Zero splat writes nothing and reports zero bytes consumed.
    try std.testing.expectEqual(@as(usize, 0), try w.vtable.drain(w, &.{"tail"}, 0));
    file.close(io);

    const input = "abc";
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &expected, .{});
    var raw: [32]u8 = undefined;
    sink.hasher.final(&raw);
    try std.testing.expectEqualSlices(u8, &expected, &raw);

    const expected_hex = std.fmt.bytesToHex(expected, .lower);
    try std.testing.expect(try verify(io, path, &expected_hex));
    try std.testing.expectEqual(@as(u64, input.len), sink.len);
}

test "checkStreamedSha NUL-pads a shorter-than-64 expected in the echo" {
    // Interior padding: some caller bytes copied, the tail zeroed — the
    // branch the empty (n=0) and oversized (n=64) cases don't reach.
    var computed: [64]u8 = undefined;
    @memset(&computed, 'a');
    const short = "c" ** 32;
    const info = checkStreamedSha(short, computed, 7) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(u64, 7), info.body_len);
    try std.testing.expectEqualStrings(short, info.expected[0..32]);
    for (info.expected[32..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}
