//! malt — cellar module
//! Cellar materialization: clonefile from store, Mach-O patching, codesigning.

const std = @import("std");
const clonefile = @import("../fs/clonefile.zig");
const patcher = @import("../macho/patcher.zig");
const codesign = @import("../macho/codesign.zig");
const atomic = @import("../fs/atomic.zig");

pub const CellarError = error{
    CloneFailed,
    PatchFailed,
    CodesignFailed,
    RemoveFailed,
    OutOfMemory,
};

pub const Keg = struct {
    name: []const u8,
    version: []const u8,
    path: []const u8,
};

/// Materialize a keg from the store to the Cellar.
/// 1. clonefile store/{sha256}/... → Cellar/{name}/{version}/
/// 2. Patch Mach-O load commands (both /opt/homebrew and /usr/local prefixes)
/// 3. Patch text files (@@HOMEBREW_PREFIX@@ etc.)
/// 4. Ad-hoc codesign on arm64
/// Uses errdefer to clean up Cellar entry on failure.
pub fn materialize(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    store_sha256: []const u8,
    name: []const u8,
    version: []const u8,
) CellarError!Keg {
    // Build paths
    var store_buf: [512]u8 = undefined;
    const store_path = std.fmt.bufPrint(&store_buf, "{s}/store/{s}", .{ prefix, store_sha256 }) catch
        return CellarError.OutOfMemory;

    var cellar_buf: [512]u8 = undefined;
    const cellar_path = std.fmt.bufPrint(&cellar_buf, "{s}/Cellar/{s}/{s}", .{ prefix, name, version }) catch
        return CellarError.OutOfMemory;

    // Find the actual keg subdirectory inside the store entry
    // Bottles extract as: store/{sha256}/{name}/{version}/
    var keg_src_buf: [512]u8 = undefined;
    const keg_src = std.fmt.bufPrint(&keg_src_buf, "{s}/{s}/{s}", .{ store_path, name, version }) catch
        return CellarError.OutOfMemory;

    // Ensure parent dir exists
    var parent_buf: [512]u8 = undefined;
    const parent = std.fmt.bufPrint(&parent_buf, "{s}/Cellar/{s}", .{ prefix, name }) catch
        return CellarError.OutOfMemory;
    std.fs.makeDirAbsolute(parent) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return CellarError.CloneFailed,
    };

    // Try keg_src first, fall back to store_path if it doesn't exist
    const src = blk: {
        std.fs.accessAbsolute(keg_src, .{}) catch break :blk store_path;
        break :blk keg_src;
    };

    // Clone from store to Cellar
    clonefile.cloneTree(src, cellar_path) catch return CellarError.CloneFailed;

    // errdefer: remove cellar entry on any failure from this point
    errdefer std.fs.deleteTreeAbsolute(cellar_path) catch {};

    const new_prefix = atomic.maltPrefix();

    // Patch Mach-O: /opt/homebrew -> /opt/malt (arm64 bottles)
    _ = patcher.patchPaths(allocator, cellar_path, "/opt/homebrew", new_prefix) catch {};

    // Patch Mach-O: /usr/local -> /opt/malt (x86_64 bottles)
    _ = patcher.patchPaths(allocator, cellar_path, "/usr/local", new_prefix) catch {};

    // Patch text files
    _ = patcher.patchTextFiles(allocator, cellar_path, "/opt/homebrew", new_prefix) catch {};

    // Ad-hoc codesign on arm64
    if (codesign.isArm64()) {
        codesign.signAllMachOInDir(cellar_path, allocator) catch {};
    }

    return .{
        .name = name,
        .version = version,
        .path = cellar_path,
    };
}

/// Remove a keg from the Cellar.
pub fn remove(prefix: []const u8, name: []const u8, version: []const u8) CellarError!void {
    var buf: [512]u8 = undefined;
    const cellar_path = std.fmt.bufPrint(&buf, "{s}/Cellar/{s}/{s}", .{ prefix, name, version }) catch
        return CellarError.OutOfMemory;
    std.fs.deleteTreeAbsolute(cellar_path) catch return CellarError.RemoveFailed;
}
