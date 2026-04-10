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
    PathTooLong,
    CodesignFailed,
    RemoveFailed,
    OutOfMemory,
};

/// Human-readable description for a CellarError tag.
/// Used by `mt install` when surfacing a materialize failure.
pub fn describeError(err: CellarError) []const u8 {
    return switch (err) {
        CellarError.CloneFailed => "APFS clonefile or copy failed",
        CellarError.PatchFailed => "Mach-O or text-file path patching failed",
        CellarError.PathTooLong => "new prefix path is longer than the bottle was built with",
        CellarError.CodesignFailed => "codesign re-signing failed",
        CellarError.RemoveFailed => "cellar directory removal failed",
        CellarError.OutOfMemory => "out of memory",
    };
}

pub const Keg = struct {
    name: []const u8,
    version: []const u8,
    path: []const u8,
};

/// Materialize a keg from the store to the Cellar.
/// 1. clonefile store/{sha256}/... → Cellar/{name}/{version}/
/// 2. Patch Mach-O placeholder tokens (@@HOMEBREW_PREFIX@@ / @@HOMEBREW_CELLAR@@)
///    — ALWAYS runs, even for ":any" relocatable bottles, because placeholders
///    in LC_LOAD_DYLIB / LC_RPATH must be substituted at pour time.
/// 3. Patch Mach-O absolute paths (/opt/homebrew, /usr/local)
///    — skipped when cellar_type is ":any" or ":any_skip_relocation".
/// 4. Patch text files (@@HOMEBREW_PREFIX@@ etc.)
/// 5. Ad-hoc codesign on arm64
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
/// When cellar_type is ":any" or ":any_skip_relocation", Mach-O binary
/// patching is skipped (relocatable bottle). Text placeholder substitution
/// (@@HOMEBREW_PREFIX@@, @@HOMEBREW_CELLAR@@) always runs.
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

    // Find the actual keg subdirectory inside the store entry.
    // Bottles extract as: store/{sha256}/{name}/{version}/ but the version
    // directory may include a Homebrew revision suffix (e.g. "10.47_1" for
    // formula version "10.47"). We first try an exact match, then scan for
    // a directory that starts with the version string followed by "_".
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

    // Try keg_src first (exact version match), then scan for a revision
    // suffix variant (e.g. "10.47_1"), fall back to store_path.
    var keg_rev_buf: [512]u8 = undefined;
    const src = blk: {
        // 1. Exact match: {store}/{name}/{version}
        std.fs.accessAbsolute(keg_src, .{}) catch {
            // 2. Scan {store}/{name}/ for a dir starting with "{version}_"
            var name_dir_buf: [512]u8 = undefined;
            const name_dir_path = std.fmt.bufPrint(&name_dir_buf, "{s}/{s}", .{ store_path, name }) catch break :blk store_path;
            var name_dir = std.fs.openDirAbsolute(name_dir_path, .{ .iterate = true }) catch break :blk store_path;
            defer name_dir.close();
            var it = name_dir.iterate();
            while (it.next() catch null) |entry| {
                if (entry.kind != .directory) continue;
                // Match "{version}_..." (revision suffix)
                if (entry.name.len > version.len and
                    std.mem.eql(u8, entry.name[0..version.len], version) and
                    entry.name[version.len] == '_')
                {
                    const rev_path = std.fmt.bufPrint(&keg_rev_buf, "{s}/{s}", .{ name_dir_path, entry.name }) catch break :blk store_path;
                    break :blk rev_path;
                }
            }
            break :blk store_path;
        };
        break :blk keg_src;
    };

    // Clone from store to Cellar
    clonefile.cloneTree(src, cellar_path) catch return CellarError.CloneFailed;

    // errdefer: remove cellar entry on any failure from this point
    errdefer std.fs.deleteTreeAbsolute(cellar_path) catch {};

    const new_prefix = atomic.maltPrefix();

    // Build cellar replacement for @@HOMEBREW_CELLAR@@
    var new_cellar_buf: [256]u8 = undefined;
    const new_cellar = std.fmt.bufPrint(&new_cellar_buf, "{s}/Cellar", .{new_prefix}) catch new_prefix;

    // Pass 1: placeholder substitution — ALWAYS runs, regardless of cellar_type.
    // `@@HOMEBREW_PREFIX@@` / `@@HOMEBREW_CELLAR@@` tokens appear in LC_LOAD_DYLIB,
    // LC_RPATH, etc. even in `:any` bottles (zig, curl, rust, llvm@* all do this)
    // and must be rewritten or the resulting binaries will fail with
    // `dyld: Symbol not found`.
    patchMachOPlaceholders(allocator, cellar_path, new_prefix, new_cellar) catch |e| switch (e) {
        CellarError.PathTooLong => return CellarError.PathTooLong,
        else => return CellarError.PatchFailed,
    };

    // Pass 2: absolute-path rewrite — skipped for relocatable bottles, which
    // Homebrew guarantees to only use `@rpath`/`@loader_path` or the placeholder
    // tokens handled above.
    const skip_absolute_rewrite = std.mem.eql(u8, cellar_type, ":any") or
        std.mem.eql(u8, cellar_type, ":any_skip_relocation");

    if (!skip_absolute_rewrite) {
        patchMachOAbsolutePaths(allocator, cellar_path, new_prefix) catch |e| switch (e) {
            CellarError.PathTooLong => return CellarError.PathTooLong,
            else => return CellarError.PatchFailed,
        };
    }

    // Always patch text files — @@HOMEBREW_PREFIX@@ and @@HOMEBREW_CELLAR@@
    // placeholders appear in scripts, .pc files, and configs regardless of
    // whether the bottle is relocatable.
    _ = patcher.patchTextFiles(allocator, cellar_path, "/opt/homebrew", new_prefix) catch |e| {
        std.log.warn("text patching failed for {s}: {s}", .{ cellar_path, @errorName(e) });
    };
    _ = patcher.patchTextFiles(allocator, cellar_path, "/usr/local", new_prefix) catch |e| {
        std.log.warn("text patching failed for {s}: {s}", .{ cellar_path, @errorName(e) });
    };

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

/// Walk a directory and patch the `@@HOMEBREW_PREFIX@@` / `@@HOMEBREW_CELLAR@@`
/// tokens in every Mach-O load command. This ALWAYS runs, including for `:any`
/// relocatable bottles — see call-site comment.
///
/// Returns `PathTooLong` if the substituted path would not fit in the existing
/// load-command slot (the new MALT_PREFIX is longer than what the bottle was
/// built for). Returns `PatchFailed` for any other patcher error.
fn patchMachOPlaceholders(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    new_prefix: []const u8,
    new_cellar: []const u8,
) CellarError!void {
    try walkMachOAndPatch(allocator, dir_path, &.{
        .{ .old = "@@HOMEBREW_PREFIX@@", .new = new_prefix },
        .{ .old = "@@HOMEBREW_CELLAR@@", .new = new_cellar },
    });
}

/// Walk a directory and rewrite `/opt/homebrew` / `/usr/local` to the current
/// MALT_PREFIX in every Mach-O load command. Skipped for `:any` bottles by the
/// caller (those only use rpath + placeholder tokens).
fn patchMachOAbsolutePaths(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    new_prefix: []const u8,
) CellarError!void {
    try walkMachOAndPatch(allocator, dir_path, &.{
        .{ .old = "/opt/homebrew", .new = new_prefix },
        .{ .old = "/usr/local", .new = new_prefix },
    });
}

const Replacement = struct {
    old: []const u8,
    new: []const u8,
};

/// Shared Mach-O walker: for every file that looks like a Mach-O, run each
/// replacement in order. `PathTooLong` is surfaced as a real error; other
/// per-file errors are skipped so a single bad binary does not fail the whole
/// materialize.
fn walkMachOAndPatch(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    replacements: []const Replacement,
) CellarError!void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var walker = dir.walk(allocator) catch return;
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;

        const full_path = std.fs.path.join(allocator, &.{ dir_path, entry.path }) catch continue;
        defer allocator.free(full_path);

        // Check if Mach-O by reading magic.
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

        for (replacements) |r| {
            _ = patcher.patchPaths(allocator, full_path, r.old, r.new) catch |e| switch (e) {
                error.PathTooLong => return CellarError.PathTooLong,
                else => continue,
            };
        }
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
