//! malt — Mach-O parser
//! Parse Mach-O 64-bit headers and extract load command paths for relocation.

const std = @import("std");

// Mach-O constants
const MH_MAGIC_64: u32 = 0xFEEDFACF;
const MH_CIGAM_64: u32 = 0xCFFAEDFE;
const FAT_MAGIC: u32 = 0xCAFEBABE;
const FAT_CIGAM: u32 = 0xBEBAFECA;

// Load command types we care about
pub const LC_ID_DYLIB: u32 = 0x0D;
pub const LC_LOAD_DYLIB: u32 = 0x0C;
pub const LC_LOAD_WEAK_DYLIB: u32 = 0x80000018;
pub const LC_RPATH: u32 = 0x8000001C;
pub const LC_REEXPORT_DYLIB: u32 = 0x8000001F;

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

pub const MachO = struct {
    /// All load command paths found in the binary
    paths: []LoadCommandPath,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *MachO) void {
        self.allocator.free(self.paths);
    }
};

/// Check if a file looks like a Mach-O binary by reading the magic bytes.
pub fn isMachO(data: []const u8) bool {
    if (data.len < 4) return false;
    const magic = std.mem.readInt(u32, data[0..4], .little);
    return magic == MH_MAGIC_64 or magic == MH_CIGAM_64 or
        magic == FAT_MAGIC or magic == FAT_CIGAM;
}

/// Parse a Mach-O file from a memory-mapped buffer and extract all load command paths.
pub fn parse(allocator: std.mem.Allocator, data: []const u8) ParseError!MachO {
    if (data.len < 4) return ParseError.TruncatedFile;

    const magic = std.mem.readInt(u32, data[0..4], .little);

    if (magic == FAT_MAGIC or magic == FAT_CIGAM) {
        return parseFat(allocator, data);
    }

    if (magic == MH_MAGIC_64) {
        return parseMachO64(allocator, data, 0);
    }

    // Try big-endian magic (MH_CIGAM_64)
    if (magic == MH_CIGAM_64) {
        return parseMachO64(allocator, data, 0);
    }

    return ParseError.InvalidMagic;
}

fn parseFat(allocator: std.mem.Allocator, data: []const u8) ParseError!MachO {
    if (data.len < 8) return ParseError.TruncatedFile;

    // Fat header is big-endian
    const nfat_arch = std.mem.readInt(u32, data[4..8], .big);

    // Find the slice for the current architecture
    const target_cputype: u32 = if (@import("builtin").cpu.arch == .aarch64)
        0x0100000C // CPU_TYPE_ARM64
    else
        0x01000007; // CPU_TYPE_X86_64

    var offset: usize = 8;
    var i: u32 = 0;
    while (i < nfat_arch) : (i += 1) {
        if (offset + 20 > data.len) return ParseError.TruncatedFile;

        const cputype = std.mem.readInt(u32, data[offset..][0..4], .big);
        const slice_offset = std.mem.readInt(u32, data[offset + 8 ..][0..4], .big);
        const slice_size = std.mem.readInt(u32, data[offset + 12 ..][0..4], .big);

        if (cputype == target_cputype) {
            if (slice_offset + slice_size > data.len) return ParseError.TruncatedFile;
            return parseMachO64(allocator, data[slice_offset .. slice_offset + slice_size], slice_offset);
        }

        offset += 20; // sizeof(fat_arch)
    }

    return ParseError.UnsupportedArch;
}

fn parseMachO64(allocator: std.mem.Allocator, data: []const u8, base_offset: usize) ParseError!MachO {
    if (data.len < 32) return ParseError.TruncatedFile;

    // mach_header_64: magic(4) + cputype(4) + cpusubtype(4) + filetype(4) +
    //                 ncmds(4) + sizeofcmds(4) + flags(4) + reserved(4) = 32 bytes
    const ncmds = std.mem.readInt(u32, data[16..20], .little);

    var paths: std.ArrayList(LoadCommandPath) = .empty;
    errdefer paths.deinit(allocator);

    var cmd_offset: usize = 32; // past mach_header_64
    var cmd_idx: u32 = 0;
    while (cmd_idx < ncmds) : (cmd_idx += 1) {
        if (cmd_offset + 8 > data.len) return ParseError.TruncatedFile;

        const cmd = std.mem.readInt(u32, data[cmd_offset..][0..4], .little);
        const cmdsize = std.mem.readInt(u32, data[cmd_offset + 4 ..][0..4], .little);

        if (cmdsize < 8 or cmd_offset + cmdsize > data.len) return ParseError.InvalidLoadCommand;

        switch (cmd) {
            LC_ID_DYLIB, LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB => {
                // dylib_command: cmd(4) + cmdsize(4) + name.offset(4) + timestamp(4) + ...
                if (cmdsize < 16) {
                    cmd_offset += cmdsize;
                    continue;
                }
                const name_offset = std.mem.readInt(u32, data[cmd_offset + 8 ..][0..4], .little);
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
                    .cmd = cmd,
                    .path_offset = base_offset + path_start,
                    .max_path_len = cmdsize - name_offset,
                    .path = path,
                }) catch return ParseError.OutOfMemory;
            },
            LC_RPATH => {
                // rpath_command: cmd(4) + cmdsize(4) + path.offset(4)
                if (cmdsize < 12) {
                    cmd_offset += cmdsize;
                    continue;
                }
                const path_offset = std.mem.readInt(u32, data[cmd_offset + 8 ..][0..4], .little);
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
                    .cmd = cmd,
                    .path_offset = base_offset + path_start,
                    .max_path_len = cmdsize - path_offset,
                    .path = path,
                }) catch return ParseError.OutOfMemory;
            },
            else => {},
        }

        cmd_offset += cmdsize;
    }

    return .{
        .paths = paths.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
        .allocator = allocator,
    };
}
