//! Signed Mach-O images for tests. `codesign` refuses to embed into a
//! Mach-O with no `__LINKEDIT`, so test images sign themselves in the
//! layout `codesign.codeDirectoryCoverage` reads.

const std = @import("std");
const macho = std.macho;

/// One SuperBlob holding one CodeDirectory whose page hashes cover `code`.
/// A `page_log2` of 0 means one hash over the whole range, as in `cs_blobs.h`.
pub fn adHocCodeDirectory(allocator: std.mem.Allocator, code: []const u8, page_log2: u8, hash_type: u8) ![]u8 {
    const CD = macho.CodeDirectory;
    const hash_size = digestLength(hash_type);
    const page: usize = if (page_log2 == 0) code.len else @as(usize, 1) << @intCast(page_log2);
    const slots = if (code.len == 0) 0 else std.math.divCeil(usize, code.len, page) catch unreachable;
    const index_len = @sizeOf(macho.SuperBlob) + @sizeOf(macho.BlobIndex);
    const cd_len = @sizeOf(CD) + slots * hash_size;

    const blob = try allocator.alloc(u8, index_len + cd_len);
    @memset(blob, 0);
    writeBe32(blob, 0, macho.CSMAGIC_EMBEDDED_SIGNATURE);
    writeBe32(blob, 4, blob.len);
    writeBe32(blob, 8, 1);
    writeBe32(blob, @sizeOf(macho.SuperBlob), macho.CSSLOT_CODEDIRECTORY);
    writeBe32(blob, @sizeOf(macho.SuperBlob) + 4, index_len);

    const cd = blob[index_len..];
    writeBe32(cd, 0, macho.CSMAGIC_CODEDIRECTORY);
    writeBe32(cd, @offsetOf(CD, "length"), cd_len);
    writeBe32(cd, @offsetOf(CD, "hashOffset"), @sizeOf(CD));
    writeBe32(cd, @offsetOf(CD, "nCodeSlots"), slots);
    writeBe32(cd, @offsetOf(CD, "codeLimit"), code.len);
    cd[@offsetOf(CD, "hashSize")] = @intCast(hash_size);
    cd[@offsetOf(CD, "hashType")] = hash_type;
    cd[@offsetOf(CD, "pageSize")] = page_log2;

    var start: usize = 0;
    var slot: usize = 0;
    while (start < code.len) : ({
        start += page;
        slot += 1;
    }) {
        const out = cd[@sizeOf(CD) + slot * hash_size ..][0..hash_size];
        hashPage(hash_type, code[start..@min(start + page, code.len)], out);
    }
    return blob;
}

/// Append an LC_CODE_SIGNATURE and the directory it points at to a thin
/// Mach-O `image`, the way a bottle binary ships. The command is hashed with
/// the rest of the header, so the blob is sized before the final hash.
pub fn appendAdHocSignature(allocator: std.mem.Allocator, image: []const u8, hash_type: u8) ![]u8 {
    const header_size = @sizeOf(macho.mach_header_64);
    const sig_size: u32 = @sizeOf(macho.linkedit_data_command);

    const code = try allocator.alloc(u8, image.len + sig_size);
    defer allocator.free(code);
    @memcpy(code[0..image.len], image);
    const hdr = std.mem.bytesAsValue(macho.mach_header_64, code[0..header_size]);
    hdr.ncmds += 1;
    hdr.sizeofcmds += sig_size;

    const sizing = try adHocCodeDirectory(allocator, code, 12, hash_type);
    const datasize: u32 = @intCast(sizing.len);
    allocator.free(sizing);
    const sig = std.mem.bytesAsValue(macho.linkedit_data_command, code[image.len..][0..sig_size]);
    sig.* = .{ .cmd = .CODE_SIGNATURE, .dataoff = @intCast(code.len), .datasize = datasize };

    const blob = try adHocCodeDirectory(allocator, code, 12, hash_type);
    defer allocator.free(blob);
    return std.mem.concat(allocator, u8, &.{ code, blob });
}

/// Thin Mach-O of `cputype` carrying one LC_LOAD_DYLIB for `dylib_path`.
pub fn loadDylibImage(allocator: std.mem.Allocator, dylib_path: []const u8, cputype: macho.cpu_type_t) ![]u8 {
    const header_size = @sizeOf(macho.mach_header_64);
    const cmdsize: u32 = 64;
    const path_off: u32 = @sizeOf(macho.dylib_command);

    const buf = try allocator.alloc(u8, header_size + cmdsize);
    @memset(buf, 0);
    const hdr = std.mem.bytesAsValue(macho.mach_header_64, buf[0..header_size]);
    hdr.* = .{ .magic = macho.MH_MAGIC_64, .cputype = cputype, .ncmds = 1, .sizeofcmds = cmdsize };
    const cmd = std.mem.bytesAsValue(macho.dylib_command, buf[header_size..][0..path_off]);
    cmd.* = .{
        .cmd = .LOAD_DYLIB,
        .cmdsize = cmdsize,
        .dylib = .{ .name = path_off, .timestamp = 0, .current_version = 0, .compatibility_version = 0 },
    };
    std.debug.assert(dylib_path.len + 1 <= cmdsize - path_off);
    @memcpy(buf[header_size + path_off ..][0..dylib_path.len], dylib_path);
    return buf;
}

/// Fat container around thin `slices`, each entry typed from its own header.
pub fn fatOf(allocator: std.mem.Allocator, slices: []const []const u8) ![]u8 {
    const table_end = 8 + slices.len * @sizeOf(macho.fat_arch);
    var total = table_end;
    for (slices) |s| total += s.len;

    const buf = try allocator.alloc(u8, total);
    @memset(buf, 0);
    std.mem.writeInt(u32, buf[0..4], macho.FAT_MAGIC, .little);
    writeBe32(buf, 4, slices.len);
    var offset = table_end;
    for (slices, 0..) |s, i| {
        const entry = 8 + i * @sizeOf(macho.fat_arch);
        const hdr = std.mem.bytesAsValue(macho.mach_header_64, s[0..@sizeOf(macho.mach_header_64)]);
        writeBe32(buf, entry, @intCast(@as(u32, @bitCast(hdr.cputype))));
        writeBe32(buf, entry + 8, offset);
        writeBe32(buf, entry + 12, s.len);
        @memcpy(buf[offset..][0..s.len], s);
        offset += s.len;
    }
    return buf;
}

fn digestLength(hash_type: u8) usize {
    return switch (hash_type) {
        macho.CS_HASHTYPE_SHA1, macho.CS_HASHTYPE_SHA256_TRUNCATED => 20,
        macho.CS_HASHTYPE_SHA256 => 32,
        macho.CS_HASHTYPE_SHA384 => 48,
        else => unreachable,
    };
}

fn hashPage(hash_type: u8, page: []const u8, out: []u8) void {
    switch (hash_type) {
        macho.CS_HASHTYPE_SHA1 => std.crypto.hash.Sha1.hash(page, out[0..20], .{}),
        macho.CS_HASHTYPE_SHA256 => std.crypto.hash.sha2.Sha256.hash(page, out[0..32], .{}),
        macho.CS_HASHTYPE_SHA256_TRUNCATED => {
            var full: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(page, &full, .{});
            @memcpy(out[0..20], full[0..20]);
        },
        macho.CS_HASHTYPE_SHA384 => std.crypto.hash.sha2.Sha384.hash(page, out[0..48], .{}),
        else => unreachable,
    }
}

fn writeBe32(b: []u8, off: usize, v: usize) void {
    std.mem.writeInt(u32, b[off..][0..4], @intCast(v), .big);
}
