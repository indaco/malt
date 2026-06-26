//! malt — Mach-O parser
//! Parse Mach-O 64-bit headers and extract load command paths for relocation.
//! Uses std.macho struct types for type-safe field access.

const std = @import("std");
const macho = std.macho;

pub const ParseError = error{
    InvalidMagic,
    TruncatedFile,
    InvalidLoadCommand,
    UnsupportedArch,
    OutOfMemory,
};

/// A path found in a Mach-O load command, with its file offset for in-place patching.
pub const LoadCommandPath = struct {
    /// Load command type (LC_ID_DYLIB, LC_LOAD_DYLIB, etc.)
    cmd: u32,
    /// Absolute byte offset of the path string within the file
    path_offset: usize,
    /// Maximum bytes available for the path (cmdsize - name_offset), for length validation
    max_path_len: usize,
    /// The current path string
    path: []const u8,
};

/// A `__TEXT,__cstring` (or any S_CSTRING_LITERALS) section located in
/// the binary. Holds the absolute file offset + byte size of the packed
/// NUL-separated string blob so the patcher can rewrite path literals
/// (e.g. ImageMagick's compiled-in `MAGICKCORE_CODER_PATH`) that the
/// load-command walker never sees.
pub const CstringRegion = struct {
    file_offset: usize,
    size: usize,
};

pub const MachO = struct {
    /// All load command paths found in the binary
    paths: []LoadCommandPath,
    /// Every S_CSTRING_LITERALS section across all arch slices.
    cstrings: []CstringRegion,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *MachO) void {
        self.allocator.free(self.paths);
        self.allocator.free(self.cstrings);
    }
};

/// Check if a file looks like a Mach-O binary by reading the magic bytes.
pub fn isMachO(data: []const u8) bool {
    if (data.len < 4) return false;
    const magic = std.mem.readInt(u32, data[0..4], .little);
    return magic == macho.MH_MAGIC_64 or magic == macho.MH_CIGAM_64 or
        magic == macho.FAT_MAGIC or magic == macho.FAT_CIGAM;
}

/// Parse a Mach-O file from a memory-mapped buffer and extract all load command paths.
pub fn parse(allocator: std.mem.Allocator, data: []const u8) ParseError!MachO {
    if (data.len < 4) return ParseError.TruncatedFile;

    const magic = std.mem.readInt(u32, data[0..4], .little);

    if (magic == macho.FAT_MAGIC or magic == macho.FAT_CIGAM) {
        return parseFat(allocator, data);
    }

    if (magic == macho.MH_MAGIC_64 or magic == macho.MH_CIGAM_64) {
        return parseMachO64(allocator, data, 0);
    }

    return ParseError.InvalidMagic;
}

/// Parse every arch slice in a fat Mach-O and return the union of their
/// load-command paths.
///
/// Before: this only parsed the slice matching the host CPU and ignored the
/// rest. That silently left the other arch's LC_LOAD_DYLIB / LC_RPATH paths
/// unpatched, so running e.g. an arm64 install on an Intel Mac (or vice
/// versa) would fail with `dyld: Symbol not found` on the first fat-bottle
/// it touched. (P9 — cross-arch fat-binary patching.)
///
/// Each `LoadCommandPath` already carries the absolute file offset of its
/// path string (parseMachO64 is given the slice's `base_offset`), so the
/// patcher can rewrite every arch's load commands in a single pass over
/// the full file buffer.
///
/// Unrecognised or truncated slices are skipped rather than aborting the
/// whole parse — some fat archives carry legacy arches (PPC, arm64e, arm64_32)
/// whose parseMachO64 call can legitimately return InvalidMagic /
/// UnsupportedArch / TruncatedFile.
///
/// `InvalidLoadCommand` is deliberately *not* swallowed: it signals structural
/// corruption in an otherwise recognised slice, and silently skipping it would
/// leave the patcher free to rewrite the surviving slices and produce a
/// half-patched fat binary. Bubble it up so the caller aborts the whole patch.
fn parseFat(allocator: std.mem.Allocator, data: []const u8) ParseError!MachO {
    if (data.len < 8) return ParseError.TruncatedFile;

    // Fat header is big-endian: magic (4), nfat_arch (4).
    const nfat_arch = std.mem.readInt(u32, data[4..8], .big);

    var all_paths: std.ArrayList(LoadCommandPath) = .empty;
    errdefer all_paths.deinit(allocator);
    var all_cstrings: std.ArrayList(CstringRegion) = .empty;
    errdefer all_cstrings.deinit(allocator);

    var offset: usize = 8;
    var i: u32 = 0;
    while (i < nfat_arch) : (i += 1) {
        if (offset + 20 > data.len) return ParseError.TruncatedFile;

        // fat_arch layout: cputype(4), cpusubtype(4), offset(4), size(4), align(4).
        // Widen to usize: both fields are ≤ 2³², so their sum can't overflow a
        // 64-bit usize and the bounds check below stays honest. In u32 a crafted
        // offset+size wraps and bypasses the guard.
        const slice_offset: usize = std.mem.readInt(u32, data[offset + 8 ..][0..4], .big);
        const slice_size: usize = std.mem.readInt(u32, data[offset + 12 ..][0..4], .big);

        offset += 20;

        if (slice_offset + slice_size > data.len) return ParseError.TruncatedFile;

        // Skip legacy/unsupported slices; bubble structural corruption.
        // See the doc comment above for the full policy.
        var slice_result = parseMachO64(
            allocator,
            data[slice_offset .. slice_offset + slice_size],
            slice_offset,
        ) catch |e| switch (e) {
            ParseError.InvalidMagic,
            ParseError.UnsupportedArch,
            ParseError.TruncatedFile,
            => continue,
            ParseError.InvalidLoadCommand,
            ParseError.OutOfMemory,
            => return e,
        };
        // Transfer the slice's results (struct-by-value) into the aggregated
        // lists, then release the per-slice containers. The byte slices
        // inside each LoadCommandPath still reference the outer `data`
        // buffer which outlives this call.
        defer slice_result.deinit();
        all_paths.appendSlice(allocator, slice_result.paths) catch return ParseError.OutOfMemory;
        all_cstrings.appendSlice(allocator, slice_result.cstrings) catch return ParseError.OutOfMemory;
    }

    return .{
        .paths = all_paths.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
        .cstrings = all_cstrings.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
        .allocator = allocator,
    };
}

fn parseMachO64(allocator: std.mem.Allocator, data: []const u8, base_offset: usize) ParseError!MachO {
    const header_size = @sizeOf(macho.mach_header_64);
    if (data.len < header_size) return ParseError.TruncatedFile;

    // Read the header using the struct type for type-safe access
    const header = std.mem.bytesAsValue(macho.mach_header_64, data[0..header_size]);

    var paths: std.ArrayList(LoadCommandPath) = .empty;
    errdefer paths.deinit(allocator);
    var cstrings: std.ArrayList(CstringRegion) = .empty;
    errdefer cstrings.deinit(allocator);

    // Sanity check: reject obviously corrupt headers (ncmds > 10,000 is unreasonable)
    if (header.ncmds > 10_000) return ParseError.InvalidLoadCommand;

    var cmd_offset: usize = header_size;
    var cmd_idx: u32 = 0;
    while (cmd_idx < header.ncmds) : (cmd_idx += 1) {
        const lc_end = @addWithOverflow(cmd_offset, @sizeOf(macho.load_command));
        if (lc_end[1] != 0 or lc_end[0] > data.len) return ParseError.TruncatedFile;

        // Read the generic load_command to get cmd + cmdsize
        const lc = std.mem.bytesAsValue(macho.load_command, data[cmd_offset..][0..@sizeOf(macho.load_command)]);
        const cmdsize = lc.cmdsize;

        // Overflow-safe bounds check: reject corrupt cmdsize values
        if (cmdsize < @sizeOf(macho.load_command))
            return ParseError.InvalidLoadCommand;
        const cmd_end = @addWithOverflow(cmd_offset, cmdsize);
        if (cmd_end[1] != 0 or cmd_end[0] > data.len)
            return ParseError.InvalidLoadCommand;

        const cmd_int = @intFromEnum(lc.cmd);

        switch (lc.cmd) {
            .ID_DYLIB, .LOAD_DYLIB, .LOAD_WEAK_DYLIB, .REEXPORT_DYLIB => {
                if (cmdsize < @sizeOf(macho.dylib_command)) {
                    cmd_offset += cmdsize;
                    continue;
                }
                const dylib_cmd = std.mem.bytesAsValue(
                    macho.dylib_command,
                    data[cmd_offset..][0..@sizeOf(macho.dylib_command)],
                );
                const name_offset = dylib_cmd.dylib.name;
                if (name_offset >= cmdsize) {
                    cmd_offset += cmdsize;
                    continue;
                }

                const path_start = cmd_offset + name_offset;
                const path_end = cmd_offset + cmdsize;
                if (path_start >= data.len) {
                    cmd_offset += cmdsize;
                    continue;
                }

                const path_region = data[path_start..@min(path_end, data.len)];
                const path = std.mem.sliceTo(path_region, 0);

                paths.append(allocator, .{
                    .cmd = cmd_int,
                    .path_offset = base_offset + path_start,
                    .max_path_len = cmdsize - name_offset,
                    .path = path,
                }) catch return ParseError.OutOfMemory;
            },
            .RPATH => {
                if (cmdsize < @sizeOf(macho.rpath_command)) {
                    cmd_offset += cmdsize;
                    continue;
                }
                const rpath_cmd = std.mem.bytesAsValue(
                    macho.rpath_command,
                    data[cmd_offset..][0..@sizeOf(macho.rpath_command)],
                );
                const path_offset = rpath_cmd.path;
                if (path_offset >= cmdsize) {
                    cmd_offset += cmdsize;
                    continue;
                }

                const path_start = cmd_offset + path_offset;
                const path_end = cmd_offset + cmdsize;
                if (path_start >= data.len) {
                    cmd_offset += cmdsize;
                    continue;
                }

                const path_region = data[path_start..@min(path_end, data.len)];
                const path = std.mem.sliceTo(path_region, 0);

                paths.append(allocator, .{
                    .cmd = cmd_int,
                    .path_offset = base_offset + path_start,
                    .max_path_len = cmdsize - path_offset,
                    .path = path,
                }) catch return ParseError.OutOfMemory;
            },
            .SEGMENT_64 => {
                // Bottle dylibs (ImageMagick, …) bake their install prefix
                // into compile-time `#define`d C strings that live in
                // `__TEXT,__cstring`, separately from any LC_LOAD_DYLIB
                // path. Collect every S_CSTRING_LITERALS section so the
                // patcher can rewrite those literals too.
                try collectCstringSections(allocator, data, cmd_offset, cmdsize, base_offset, &cstrings);
            },
            else => {},
        }

        cmd_offset += cmdsize;
    }

    return .{
        .paths = paths.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
        .cstrings = cstrings.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
        .allocator = allocator,
    };
}

/// Walk every `section_64` inside one LC_SEGMENT_64 and append the C-string
/// regions to `out`. Mach-O permits multiple S_CSTRING_LITERALS sections per
/// segment, so we don't short-circuit on the first match.
///
/// Bounds and overflow checks mirror the rest of `parseMachO64`: any field
/// that would point past the slice's `data` buffer is treated as corruption
/// and bubbled via `ParseError.InvalidLoadCommand`. A section whose
/// declared file offset + size lands beyond the slice is dropped (legacy
/// stripped binaries do this for zerofill-like layouts and are not corrupt
/// per se), keeping the parse resilient.
fn collectCstringSections(
    allocator: std.mem.Allocator,
    data: []const u8,
    cmd_offset: usize,
    cmdsize: u32,
    base_offset: usize,
    out: *std.ArrayList(CstringRegion),
) ParseError!void {
    const seg_size = @sizeOf(macho.segment_command_64);
    const sect_size = @sizeOf(macho.section_64);
    if (cmdsize < seg_size) return;

    const seg = std.mem.bytesAsValue(
        macho.segment_command_64,
        data[cmd_offset..][0..seg_size],
    );
    const nsects = seg.nsects;

    const sects_total = @as(usize, nsects) * sect_size;
    const sects_end = @addWithOverflow(seg_size, sects_total);
    if (sects_end[1] != 0 or sects_end[0] > cmdsize) return ParseError.InvalidLoadCommand;

    var sect_idx: u32 = 0;
    while (sect_idx < nsects) : (sect_idx += 1) {
        const sect_off = cmd_offset + seg_size + @as(usize, sect_idx) * sect_size;
        const sect = std.mem.bytesAsValue(
            macho.section_64,
            data[sect_off..][0..sect_size],
        );

        if (sect.type() != macho.S_CSTRING_LITERALS) continue;

        const sect_file_off: usize = sect.offset;
        const sect_size_bytes: usize = @intCast(sect.size);
        if (sect_size_bytes == 0) continue;

        // Drop sections that land outside the current slice — legacy /
        // pre-stripped binaries occasionally claim offsets they don't
        // actually carry, and a malformed section_64 must not let the
        // patcher walk off the buffer.
        const end = @addWithOverflow(sect_file_off, sect_size_bytes);
        if (end[1] != 0 or end[0] > data.len) continue;

        out.append(allocator, .{
            .file_offset = base_offset + sect_file_off,
            .size = sect_size_bytes,
        }) catch return ParseError.OutOfMemory;
    }
}
