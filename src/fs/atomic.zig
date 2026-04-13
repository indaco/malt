const std = @import("std");
const clonefile = @import("clonefile.zig");

/// Return the malt install prefix, honouring the MALT_PREFIX environment
/// variable and falling back to "/opt/malt".
pub fn maltPrefix() [:0]const u8 {
    return std.posix.getenv("MALT_PREFIX") orelse "/opt/malt";
}

/// Rename `src_path` to `dst_path`. Tries a single `rename(2)` first — the
/// atomic, crash-safe path that every caller wants on the happy case. If
/// the kernel returns EXDEV (src and dst live on different filesystems,
/// which `rename(2)` cannot span) we fall back to a clone-or-copy of the
/// tree followed by removal of the source. The fallback is not atomic
/// from a crash standpoint, but the end state (dst present, src absent)
/// matches `rename` semantics; a crash mid-way leaves the tmp source
/// intact for the next housekeeping sweep to clean up.
pub fn atomicRename(src_path: []const u8, dst_path: []const u8) !void {
    std.fs.renameAbsolute(src_path, dst_path) catch |e| switch (e) {
        error.RenameAcrossMountPoints => {
            try clonefile.cloneTree(src_path, dst_path);
            std.fs.deleteTreeAbsolute(src_path) catch {};
        },
        else => return e,
    };
}

/// Create a temporary directory under {prefix}/tmp/ with the given label and
/// a random hex suffix.  The returned path is allocated via `allocator` and
/// the caller owns the memory.
pub fn createTempDir(allocator: std.mem.Allocator, label: []const u8) ![]const u8 {
    const prefix = maltPrefix();

    // Ensure the tmp base directory exists.
    const tmp_base = try std.fmt.allocPrint(allocator, "{s}/tmp", .{prefix});
    defer allocator.free(tmp_base);
    std.fs.cwd().makePath(tmp_base) catch {};

    // Generate 8 random bytes -> 16 hex chars.
    var rand_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);

    var hex_buf: [16]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (rand_bytes, 0..) |b, i| {
        hex_buf[i * 2] = hex_chars[b >> 4];
        hex_buf[i * 2 + 1] = hex_chars[b & 0x0f];
    }

    const dir_path = try std.fmt.allocPrint(allocator, "{s}/tmp/{s}_{s}", .{ prefix, label, &hex_buf });

    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {}, // unlikely but harmless
        else => {
            allocator.free(dir_path);
            return err;
        },
    };

    return dir_path;
}

/// Remove a temporary directory recursively.  Best-effort: errors are ignored.
pub fn cleanupTempDir(dir_path: []const u8) void {
    std.fs.deleteTreeAbsolute(dir_path) catch {};
}

/// Return "{prefix}/tmp", allocated via `allocator`.
pub fn maltTmpDir(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/tmp", .{maltPrefix()});
}

/// Return "{prefix}/db", allocated via `allocator`.
pub fn maltDbDir(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/db", .{maltPrefix()});
}

/// Return the cache directory, honouring MALT_CACHE env var.
/// Falls back to "{prefix}/cache".
pub fn maltCacheDir(allocator: std.mem.Allocator) ![]const u8 {
    if (std.posix.getenv("MALT_CACHE")) |cache| {
        return allocator.dupe(u8, std.mem.sliceTo(cache, 0));
    }
    return std.fmt.allocPrint(allocator, "{s}/cache", .{maltPrefix()});
}
