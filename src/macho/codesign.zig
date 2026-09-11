//! malt — codesign module
//! Ad-hoc codesigning wrapper and signature coverage check for arm64
//! Mach-O binaries.

const std = @import("std");
const system_tools = @import("../system_tools.zig");
const builtin = @import("builtin");

pub const CodesignError = error{
    CodesignFailed,
    CodesignNotFound,
    SpawnFailed,
    OutOfMemory,
};

/// Returns true if the current build target is arm64 (aarch64).
pub fn isArm64() bool {
    return builtin.cpu.arch == .aarch64;
}

/// Ad-hoc codesign a single binary. Thin wrapper around `adHocSignAll`
/// kept for callers that have exactly one path on hand.
pub fn adHocSign(io: std.Io, allocator: std.mem.Allocator, path: []const u8) CodesignError!void {
    const one = [_][]const u8{path};
    return adHocSignAll(io, allocator, &one);
}

/// Ad-hoc codesign every path in `paths` with a **single** `codesign`
/// subprocess invocation:
///     codesign --force --sign - path1 path2 ...
///
/// macOS `codesign(1)` accepts multiple path arguments, so this collapses
/// N spawn + wait cycles (~15 ms each on arm64) into one. For packages
/// with many Mach-O files (ffmpeg ships ~20+ dylibs and binaries) this
/// is the difference between ~300 ms and ~15 ms of codesign cost.
pub fn adHocSignAll(io: std.Io, allocator: std.mem.Allocator, paths: []const []const u8) CodesignError!void {
    if (paths.len == 0) return;

    // argv = ["/usr/bin/codesign", "--force", "--sign", "-", path1, path2, ...]
    var argv = std.ArrayList([]const u8).initCapacity(allocator, paths.len + 4) catch
        return CodesignError.OutOfMemory;
    defer argv.deinit(allocator);
    argv.appendAssumeCapacity(system_tools.codesign);
    argv.appendAssumeCapacity("--force");
    argv.appendAssumeCapacity("--sign");
    argv.appendAssumeCapacity("-");
    for (paths) |p| argv.appendAssumeCapacity(p);

    // Redirect stdout/stderr to /dev/null to suppress codesign messages.
    var spawned = std.process.spawn(io, .{
        .argv = argv.items,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return CodesignError.SpawnFailed;
    const term = spawned.wait(io) catch return CodesignError.CodesignFailed;
    switch (term) {
        .exited => |code| {
            if (code != 0) return CodesignError.CodesignFailed;
        },
        else => return CodesignError.CodesignFailed,
    }
}

/// Whether a slice's embedded CodeDirectory still hashes to its code pages.
pub const Coverage = enum { intact, stale, unverifiable };

/// Judge the embedded signature at `sig_off..sig_off+sig_len` of one arch
/// `slice` against the code it claims to cover. Only the primary
/// CodeDirectory's page hashes are compared: bytes rewritten after signing
/// fail there, and that is the one way relocation can break a signature.
/// Anything this cannot read is `unverifiable`, never `stale`.
pub fn codeDirectoryCoverage(slice: []const u8, sig_off: usize, sig_len: usize) Coverage {
    const CD = std.macho.CodeDirectory;
    const sig = subslice(slice, sig_off, sig_len) orelse return .unverifiable;
    const cd = primaryCodeDirectory(sig) orelse return .unverifiable;
    if (be32(cd, 0) != std.macho.CSMAGIC_CODEDIRECTORY) return .unverifiable;
    if (cd.len < @offsetOf(CD, "spare2")) return .unverifiable;

    const hash_offset = be32(cd, @offsetOf(CD, "hashOffset")).?;
    const n_code_slots = be32(cd, @offsetOf(CD, "nCodeSlots")).?;
    const code_limit = be32(cd, @offsetOf(CD, "codeLimit")).?;
    const hash_size: usize = cd[@offsetOf(CD, "hashSize")];
    const hash_type = cd[@offsetOf(CD, "hashType")];
    const page_log2 = cd[@offsetOf(CD, "pageSize")];
    if (hash_size == 0 or code_limit == 0 or code_limit > slice.len) return .unverifiable;
    if (page_log2 >= @bitSizeOf(usize)) return .unverifiable;

    // A page size of 0 means one hash over the whole range.
    const page = if (page_log2 == 0) code_limit else @as(usize, 1) << @intCast(page_log2);
    const slots = std.math.divCeil(usize, code_limit, page) catch unreachable;
    if (slots > n_code_slots) return .unverifiable;
    const table = subslice(cd, hash_offset, slots * hash_size) orelse return .unverifiable;

    var start: usize = 0;
    var slot: usize = 0;
    while (start < code_limit) : ({
        start += page;
        slot += 1;
    }) {
        const expected = table[slot * hash_size ..][0..hash_size];
        const matches = pageMatches(hash_type, slice[start..@min(start + page, code_limit)], expected) orelse
            return .unverifiable;
        if (!matches) return .stale;
    }
    return .intact;
}

/// The CodeDirectory slot of an embedded-signature SuperBlob, or null when
/// the index cannot be walked.
fn primaryCodeDirectory(sig: []const u8) ?[]const u8 {
    const macho = std.macho;
    if (be32(sig, 0) != macho.CSMAGIC_EMBEDDED_SIGNATURE) return null;
    const count = be32(sig, 8) orelse return null;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const entry = @sizeOf(macho.SuperBlob) + i * @sizeOf(macho.BlobIndex);
        const kind = be32(sig, entry) orelse return null;
        const offset = be32(sig, entry + 4) orelse return null;
        if (kind != macho.CSSLOT_CODEDIRECTORY) continue;
        if (offset > sig.len) return null;
        return sig[offset..];
    }
    return null;
}

fn pageMatches(hash_type: u8, page: []const u8, expected: []const u8) ?bool {
    const macho = std.macho;
    return switch (hash_type) {
        macho.CS_HASHTYPE_SHA1 => digestMatches(std.crypto.hash.Sha1, page, expected),
        macho.CS_HASHTYPE_SHA256, macho.CS_HASHTYPE_SHA256_TRUNCATED => digestMatches(std.crypto.hash.sha2.Sha256, page, expected),
        macho.CS_HASHTYPE_SHA384 => digestMatches(std.crypto.hash.sha2.Sha384, page, expected),
        else => null,
    };
}

fn digestMatches(comptime H: type, page: []const u8, expected: []const u8) ?bool {
    if (expected.len > H.digest_length) return null;
    var digest: [H.digest_length]u8 = undefined;
    H.hash(page, &digest, .{});
    return std.mem.eql(u8, digest[0..expected.len], expected);
}

fn subslice(b: []const u8, off: usize, len: usize) ?[]const u8 {
    const end = std.math.add(usize, off, len) catch return null;
    if (end > b.len) return null;
    return b[off..end];
}

/// Signature blobs are big-endian regardless of the host.
fn be32(b: []const u8, off: usize) ?u32 {
    const bytes = subslice(b, off, 4) orelse return null;
    return std.mem.readInt(u32, bytes[0..4], .big);
}

test "adHocSignAll does not execute a prefix-resident codesign shim" {
    const testing = std.testing;
    const io = std.Options.debug_io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrintSentinel(a, "/tmp/malt_codesign_shim_{d}", .{std.c.getpid()}, 0);
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const bin = try std.fmt.allocPrint(a, "{s}/bin", .{root});
    const shim = try std.fmt.allocPrint(a, "{s}/codesign", .{bin});
    try std.Io.Dir.cwd().createDirPath(io, bin);
    try std.Io.Dir.symLinkAbsolute(io, "/usr/bin/true", shim, .{});

    const path_entry = try std.fmt.allocPrintSentinel(a, "PATH={s}:/usr/bin:/bin", .{bin}, 0);
    const entries = [_:null]?[*:0]const u8{path_entry.ptr};
    const environ: std.process.Environ = .{ .block = .{ .slice = &entries } };
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = environ });
    defer threaded.deinit();

    try testing.expectError(
        CodesignError.CodesignFailed,
        adHocSignAll(threaded.io(), a, &.{"/no/such/macho"}),
    );
}

const fixtures = @import("test_fixtures.zig");

fn signedSlice(allocator: std.mem.Allocator, code: []const u8, page_log2: u8, hash_type: u8) ![]u8 {
    const blob = try fixtures.adHocCodeDirectory(allocator, code, page_log2, hash_type);
    defer allocator.free(blob);
    return std.mem.concat(allocator, u8, &.{ code, blob });
}

test "codeDirectoryCoverage judges the primary CodeDirectory against the bytes on disk" {
    const testing = std.testing;

    // Two full pages plus a partial tail, so both page lengths get hashed.
    var code: [4096 * 2 + 100]u8 = undefined;
    for (&code, 0..) |*b, i| b.* = @truncate(i * 31);

    // Every hash type a signer may have used, including the SHA-1 primary
    // `codesign` still emits for older deployment targets.
    for ([_]u8{
        std.macho.CS_HASHTYPE_SHA1,
        std.macho.CS_HASHTYPE_SHA256,
        std.macho.CS_HASHTYPE_SHA256_TRUNCATED,
        std.macho.CS_HASHTYPE_SHA384,
    }) |hash_type| {
        const slice = try signedSlice(testing.allocator, &code, 12, hash_type);
        defer testing.allocator.free(slice);
        const sig_len = slice.len - code.len;

        try testing.expectEqual(Coverage.intact, codeDirectoryCoverage(slice, code.len, sig_len));

        // One byte flipped in the tail page: the shape of an in-place
        // relocation edit that was never re-signed.
        slice[code.len - 1] ^= 0xff;
        try testing.expectEqual(Coverage.stale, codeDirectoryCoverage(slice, code.len, sig_len));
        slice[code.len - 1] ^= 0xff;

        slice[0] ^= 0xff;
        try testing.expectEqual(Coverage.stale, codeDirectoryCoverage(slice, code.len, sig_len));
    }
}

test "codeDirectoryCoverage treats page size 0 as one hash over the whole range" {
    const testing = std.testing;

    var code: [5000]u8 = undefined;
    for (&code, 0..) |*b, i| b.* = @truncate(i * 7);
    const slice = try signedSlice(testing.allocator, &code, 0, std.macho.CS_HASHTYPE_SHA256);
    defer testing.allocator.free(slice);
    const sig_len = slice.len - code.len;

    try testing.expectEqual(Coverage.intact, codeDirectoryCoverage(slice, code.len, sig_len));
    slice[4999] ^= 0xff;
    try testing.expectEqual(Coverage.stale, codeDirectoryCoverage(slice, code.len, sig_len));
}

test "codeDirectoryCoverage never condemns a signature it cannot read" {
    const testing = std.testing;

    var code: [300]u8 = undefined;
    for (&code, 0..) |*b, i| b.* = @truncate(i);
    const slice = try signedSlice(testing.allocator, &code, 12, std.macho.CS_HASHTYPE_SHA256);
    defer testing.allocator.free(slice);
    const sig_len = slice.len - code.len;
    const cd = slice[code.len + @sizeOf(std.macho.SuperBlob) + @sizeOf(std.macho.BlobIndex) ..];

    // Signature range past the end of the slice.
    try testing.expectEqual(Coverage.unverifiable, codeDirectoryCoverage(slice, code.len, sig_len + 1));
    // Hash table cut short by the declared signature length.
    try testing.expectEqual(Coverage.unverifiable, codeDirectoryCoverage(slice, code.len, sig_len - 1));

    // Not an embedded-signature SuperBlob at all.
    slice[code.len] ^= 0xff;
    try testing.expectEqual(Coverage.unverifiable, codeDirectoryCoverage(slice, code.len, sig_len));
    slice[code.len] ^= 0xff;

    // A hash type this build cannot compute.
    const hash_type = @offsetOf(std.macho.CodeDirectory, "hashType");
    cd[hash_type] = 0x7f;
    try testing.expectEqual(Coverage.unverifiable, codeDirectoryCoverage(slice, code.len, sig_len));
    cd[hash_type] = std.macho.CS_HASHTYPE_SHA256;

    // A codeLimit that reaches past the file, and one that covers nothing.
    const code_limit = @offsetOf(std.macho.CodeDirectory, "codeLimit");
    std.mem.writeInt(u32, cd[code_limit..][0..4], @intCast(slice.len + 1), .big);
    try testing.expectEqual(Coverage.unverifiable, codeDirectoryCoverage(slice, code.len, sig_len));
    std.mem.writeInt(u32, cd[code_limit..][0..4], 0, .big);
    try testing.expectEqual(Coverage.unverifiable, codeDirectoryCoverage(slice, code.len, sig_len));
    std.mem.writeInt(u32, cd[code_limit..][0..4], code.len, .big);

    // A page size no machine has: the shift must not trap.
    const page_size = @offsetOf(std.macho.CodeDirectory, "pageSize");
    cd[page_size] = 200;
    try testing.expectEqual(Coverage.unverifiable, codeDirectoryCoverage(slice, code.len, sig_len));
    cd[page_size] = 12;

    // A directory index pointing past the blob: the slice math must not trap.
    const index_offset = code.len + @sizeOf(std.macho.SuperBlob) + 4;
    std.mem.writeInt(u32, slice[index_offset..][0..4], @intCast(sig_len + 8), .big);
    try testing.expectEqual(Coverage.unverifiable, codeDirectoryCoverage(slice, code.len, sig_len));
    std.mem.writeInt(u32, slice[index_offset..][0..4], @sizeOf(std.macho.SuperBlob) + @sizeOf(std.macho.BlobIndex), .big);

    // Still intact once everything is put back.
    try testing.expectEqual(Coverage.intact, codeDirectoryCoverage(slice, code.len, sig_len));
}

test "codeDirectoryCoverage reads a signature the platform tools produced" {
    const testing = std.testing;
    const io = std.Options.debug_io;
    const parser = @import("parser.zig");

    // The fixtures above mirror the checker's own writer. A binary Apple
    // signed carries the blobs and special slots real bottles do, so it must
    // come back intact, not unverifiable.
    const data = std.Io.Dir.cwd().readFileAlloc(io, "/usr/bin/true", testing.allocator, .unlimited) catch
        return error.SkipZigTest;
    defer testing.allocator.free(data);
    var parsed = try parser.parse(testing.allocator, data);
    defer parsed.deinit();

    var judged: usize = 0;
    for (parsed.signatures) |sig| {
        if (!sig.is_arm64) continue;
        const slice = data[sig.slice_offset..][0..sig.slice_len];
        try testing.expectEqual(Coverage.intact, codeDirectoryCoverage(slice, sig.dataoff, sig.datasize));
        judged += 1;
    }
    try testing.expect(judged > 0);
}
