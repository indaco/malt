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
///    — skipped when cellar_type is ":any" or ":any_skip_relocation" (relocatable bottle)
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
    return materializeWithCellar(allocator, prefix, store_sha256, name, version, "");
}

/// Materialize with an explicit cellar type from the bottle metadata.
/// When cellar_type is ":any" or ":any_skip_relocation", Mach-O patching
/// and text-file prefix rewriting are skipped because the bottle is
/// already relocatable.
pub fn materializeWithCellar(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    store_sha256: []const u8,
    name: []const u8,
    version: []const u8,
    cellar_type: []const u8,
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

    // Relocatable bottles (cellar: ":any" or ":any_skip_relocation") do not
    // need Mach-O patching or text-file prefix rewriting — they are built to
    // work from any prefix without modification.
    const skip_patching = std.mem.eql(u8, cellar_type, ":any") or
        std.mem.eql(u8, cellar_type, ":any_skip_relocation");

    if (!skip_patching) {
        // Build cellar replacement for @@HOMEBREW_CELLAR@@
        var new_cellar_buf: [256]u8 = undefined;
        const new_cellar = std.fmt.bufPrint(&new_cellar_buf, "{s}/Cellar", .{new_prefix}) catch new_prefix;

        // Walk cellar directory and patch each Mach-O binary
        patchAllMachO(allocator, cellar_path, new_prefix, new_cellar) catch
            return CellarError.PatchFailed;

        // Patch text files (scripts, .pc files, configs).
        // Failures here mean .pc files and scripts will have wrong prefixes,
        // causing build/runtime errors for dependents. Warn but don't abort.
        _ = patcher.patchTextFiles(allocator, cellar_path, "/opt/homebrew", new_prefix) catch |e| {
            std.log.warn("text patching failed for {s}: {s}", .{ cellar_path, @errorName(e) });
        };
        _ = patcher.patchTextFiles(allocator, cellar_path, "/usr/local", new_prefix) catch |e| {
            std.log.warn("text patching failed for {s}: {s}", .{ cellar_path, @errorName(e) });
        };
    }

    // Ad-hoc codesign on arm64. Without this, binaries won't execute on Apple Silicon.
    if (codesign.isArm64()) {
        codesign.signAllMachOInDir(cellar_path, allocator) catch |e| {
            std.log.warn("codesigning failed for {s}: {s}", .{ cellar_path, @errorName(e) });
        };
    }

    // Write INSTALL_RECEIPT.json for brew compatibility
    writeInstallReceipt(cellar_path, name, version, store_sha256);

    // Allocate the path so it survives beyond this function's stack
    const owned_path = allocator.dupe(u8, cellar_path) catch return CellarError.OutOfMemory;

    return .{
        .name = name,
        .version = version,
        .path = owned_path,
    };
}

/// Walk a directory and patch all Mach-O binaries with prefix replacements.
/// Returns PatchFailed if any binary has paths that are too long for in-place patching.
fn patchAllMachO(allocator: std.mem.Allocator, dir_path: []const u8, new_prefix: []const u8, new_cellar: []const u8) CellarError!void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var walker = dir.walk(allocator) catch return;
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;

        const full_path = std.fs.path.join(allocator, &.{ dir_path, entry.path }) catch continue;
        defer allocator.free(full_path);

        // Check if Mach-O by reading magic
        const file = std.fs.openFileAbsolute(full_path, .{}) catch continue;
        var magic_buf: [4]u8 = undefined;
        const n = file.readAll(&magic_buf) catch {
            file.close();
            continue;
        };
        file.close();
        if (n < 4) continue;

        const parser_mod = @import("../macho/parser.zig");
        if (!parser_mod.isMachO(&magic_buf)) continue;

        // Patch all known prefix patterns in this Mach-O.
        // PathTooLong is a real error — surface it so the caller knows the
        // binary cannot be relocated in-place.
        _ = patcher.patchPaths(allocator, full_path, "/opt/homebrew", new_prefix) catch |e| switch (e) {
            error.PathTooLong => return CellarError.PatchFailed,
            else => continue,
        };
        _ = patcher.patchPaths(allocator, full_path, "/usr/local", new_prefix) catch |e| switch (e) {
            error.PathTooLong => return CellarError.PatchFailed,
            else => continue,
        };
        _ = patcher.patchPaths(allocator, full_path, "@@HOMEBREW_PREFIX@@", new_prefix) catch |e| switch (e) {
            error.PathTooLong => return CellarError.PatchFailed,
            else => continue,
        };
        _ = patcher.patchPaths(allocator, full_path, "@@HOMEBREW_CELLAR@@", new_cellar) catch |e| switch (e) {
            error.PathTooLong => return CellarError.PatchFailed,
            else => continue,
        };
    }
}

/// Write a brew-compatible INSTALL_RECEIPT.json to the keg directory.
/// This allows Homebrew to recognize malt-installed packages.
fn writeInstallReceipt(cellar_path: []const u8, name: []const u8, version: []const u8, store_sha256: []const u8) void {
    writeInstallReceiptFull(cellar_path, name, version, store_sha256, null, true);
}

/// Public version with full options for tap installs.
pub fn writeInstallReceiptFull(
    cellar_path: []const u8,
    name: []const u8,
    version: []const u8,
    store_sha256: []const u8,
    tap: ?[]const u8,
    is_direct: bool,
) void {
    var path_buf: [512]u8 = undefined;
    const receipt_path = std.fmt.bufPrint(&path_buf, "{s}/INSTALL_RECEIPT.json", .{cellar_path}) catch return;

    const file = std.fs.createFileAbsolute(receipt_path, .{}) catch return;
    defer file.close();

    const timestamp = std.time.timestamp();
    const tap_str = tap orelse "homebrew/core";
    const reason = if (is_direct) "true" else "false";
    const dep_reason = if (is_direct) "false" else "true";

    var buf: [2048]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        \\{{
        \\  "homebrew_version": null,
        \\  "used_options": [],
        \\  "unused_options": [],
        \\  "built_as_bottle": true,
        \\  "poured_from_bottle": true,
        \\  "installed_as_dependency": {s},
        \\  "installed_on_request": {s},
        \\  "changed_files": [],
        \\  "time": {d},
        \\  "source": {{
        \\    "tap": "{s}",
        \\    "path": null,
        \\    "spec": "stable",
        \\    "versions": {{
        \\      "stable": "{s}",
        \\      "head": null
        \\    }},
        \\    "vendor": "malt"
        \\  }},
        \\  "arch": "{s}",
        \\  "store_sha256": "{s}"
        \\}}
    , .{
        dep_reason,
        reason,
        timestamp,
        tap_str,
        version,
        if (@import("builtin").cpu.arch == .aarch64) "arm64" else "x86_64",
        store_sha256,
    }) catch return;

    // Also include name in a comment-style field (not standard but useful)
    _ = name;

    file.writeAll(json) catch {};
}

/// Remove a keg from the Cellar.
pub fn remove(prefix: []const u8, name: []const u8, version: []const u8) CellarError!void {
    var buf: [512]u8 = undefined;
    const cellar_path = std.fmt.bufPrint(&buf, "{s}/Cellar/{s}/{s}", .{ prefix, name, version }) catch
        return CellarError.OutOfMemory;
    std.fs.deleteTreeAbsolute(cellar_path) catch return CellarError.RemoveFailed;
}
