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
fn parseFat(allocator: std.mem.Allocator, data: []const u8) ParseError!MachO {
    if (data.len < 8) return ParseError.TruncatedFile;

    // Fat header is big-endian: magic (4), nfat_arch (4).
    const nfat_arch = std.mem.readInt(u32, data[4..8], .big);

    var all_paths: std.ArrayList(LoadCommandPath) = .empty;
    errdefer all_paths.deinit(allocator);

    var offset: usize = 8;
    var i: u32 = 0;
    while (i < nfat_arch) : (i += 1) {
        if (offset + 20 > data.len) return ParseError.TruncatedFile;

        // fat_arch layout: cputype(4), cpusubtype(4), offset(4), size(4), align(4).
        const slice_offset = std.mem.readInt(u32, data[offset + 8 ..][0..4], .big);
        const slice_size = std.mem.readInt(u32, data[offset + 12 ..][0..4], .big);

        offset += 20;

        if (slice_offset + slice_size > data.len) return ParseError.TruncatedFile;

        // Parse this slice. Skip unrecognised slices (legacy arches etc.)
        // rather than failing the whole file.
        const slice_result = parseMachO64(
            allocator,
            data[slice_offset .. slice_offset + slice_size],
            slice_offset,
        ) catch |e| switch (e) {
            ParseError.InvalidMagic,
            ParseError.UnsupportedArch,
            ParseError.TruncatedFile,
            => continue,
            ParseError.InvalidLoadCommand => continue,
            ParseError.OutOfMemory => return e,
        };
        // Transfer the slice's LoadCommandPath values (struct-by-value) into
        // the aggregated list, then free the slice's container. The `path`
        // byte slices inside each LoadCommandPath still reference the outer
        // `data` buffer which outlives this call.
        defer allocator.free(slice_result.paths);
        all_paths.appendSlice(allocator, slice_result.paths) catch return ParseError.OutOfMemory;
    }

    return .{
        .paths = all_paths.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
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

    var cmd_offset: usize = header_size;
    var cmd_idx: u32 = 0;
    while (cmd_idx < header.ncmds) : (cmd_idx += 1) {
        if (cmd_offset + @sizeOf(macho.load_command) > data.len) return ParseError.TruncatedFile;

        // Read the generic load_command to get cmd + cmdsize
        const lc = std.mem.bytesAsValue(macho.load_command, data[cmd_offset..][0..@sizeOf(macho.load_command)]);
        const cmdsize = lc.cmdsize;

        if (cmdsize < @sizeOf(macho.load_command) or cmd_offset + cmdsize > data.len)
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
            else => {},
        }

        cmd_offset += cmdsize;
    }

    return .{
        .paths = paths.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
        .allocator = allocator,
    };
}
