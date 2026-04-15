//! malt — cellar module
//! Cellar materialization: clonefile from store, Mach-O patching, codesigning.

const std = @import("std");
const fs_compat = @import("../fs/compat.zig");
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
    fs_compat.makeDirAbsolute(parent) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return CellarError.CloneFailed,
    };

    // Try keg_src first (exact version match), then scan for a revision
    // suffix variant (e.g. "10.47_1"), fall back to store_path.
    var keg_rev_buf: [512]u8 = undefined;
    const src = blk: {
        // 1. Exact match: {store}/{name}/{version}
        fs_compat.accessAbsolute(keg_src, .{}) catch {
            // 2. Scan {store}/{name}/ for a dir starting with "{version}_"
            var name_dir_buf: [512]u8 = undefined;
            const name_dir_path = std.fmt.bufPrint(&name_dir_buf, "{s}/{s}", .{ store_path, name }) catch break :blk store_path;
            var name_dir = fs_compat.openDirAbsolute(name_dir_path, .{ .iterate = true }) catch break :blk store_path;
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

    // errdefer: remove cellar entry on any failure from this point — including
    // `cloneTree` itself, which would otherwise leave the freshly-created
    // `Cellar/{name}/` parent dir behind as an empty orphan.
    //
    // `deleteTreeAbsolute` is a no-op when the target doesn't exist yet, and
    // `deleteDirAbsolute` only succeeds when the directory is empty, so
    // installed sibling versions are left untouched.
    errdefer {
        fs_compat.deleteTreeAbsolute(cellar_path) catch {};
        fs_compat.deleteDirAbsolute(parent) catch {};
    }

    // Clone from store to Cellar
    clonefile.cloneTree(src, cellar_path) catch return CellarError.CloneFailed;

    const new_prefix = atomic.maltPrefix();

    // Build cellar replacement for @@HOMEBREW_CELLAR@@
    var new_cellar_buf: [256]u8 = undefined;
    const new_cellar = std.fmt.bufPrint(&new_cellar_buf, "{s}/Cellar", .{new_prefix}) catch new_prefix;

    // Build the full Mach-O replacement list in one shot. `@@HOMEBREW_*@@`
    // placeholders are patched for every bottle (they appear even in `:any`
    // bottles — zig, curl, rust, llvm@* all use them in LC_LOAD_DYLIB /
    // LC_RPATH load commands). The absolute-path rewrites are skipped for
    // `:any` and `:any_skip_relocation` bottles, where Homebrew guarantees
    // only `@rpath` / `@loader_path` + placeholder tokens.
    //
    // Passing all the replacements in one call means the walker visits
    // each file exactly once and opens it exactly once per active
    // replacement, instead of walking the cellar twice.
    const skip_absolute_rewrite = std.mem.eql(u8, cellar_type, ":any") or
        std.mem.eql(u8, cellar_type, ":any_skip_relocation");

    var macho_reps_buf: [4]Replacement = undefined;
    macho_reps_buf[0] = .{ .old = "@@HOMEBREW_PREFIX@@", .new = new_prefix };
    macho_reps_buf[1] = .{ .old = "@@HOMEBREW_CELLAR@@", .new = new_cellar };
    var macho_reps_len: usize = 2;
    if (!skip_absolute_rewrite) {
        macho_reps_buf[2] = .{ .old = "/opt/homebrew", .new = new_prefix };
        macho_reps_buf[3] = .{ .old = "/usr/local", .new = new_prefix };
        macho_reps_len = 4;
    }

    // `walkMachOAndPatch` collects the full paths of every Mach-O file
    // it actually modified (i.e. where at least one replacement rewrote
    // bytes). Those are the only files whose ad-hoc signature got
    // invalidated, so they are the only files we need to re-sign. For a
    // bottle whose binaries don't reference `/opt/homebrew` at all
    // (e.g. `tree`), this list comes back empty and the expensive
    // codesign subprocess is skipped entirely.
    var modified_macho_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (modified_macho_paths.items) |p| allocator.free(p);
        modified_macho_paths.deinit(allocator);
    }

    walkMachOAndPatch(
        allocator,
        cellar_path,
        macho_reps_buf[0..macho_reps_len],
        &modified_macho_paths,
    ) catch |e| switch (e) {
        CellarError.PathTooLong => return CellarError.PathTooLong,
        else => return CellarError.PatchFailed,
    };

    // Always patch text files — @@HOMEBREW_PREFIX@@ and @@HOMEBREW_CELLAR@@
    // placeholders appear in scripts, .pc files, and configs regardless of
    // whether the bottle is relocatable. Text files don't carry code
    // signatures so they don't feed back into the codesign list.
    const text_replacements = [_]patcher.Replacement{
        .{ .old = "@@HOMEBREW_PREFIX@@", .new = new_prefix },
        .{ .old = "@@HOMEBREW_CELLAR@@", .new = new_cellar },
        .{ .old = "/opt/homebrew", .new = new_prefix },
        .{ .old = "/usr/local", .new = new_prefix },
    };
    _ = patcher.patchTextFiles(allocator, cellar_path, &text_replacements) catch |e| {
        std.log.warn("text patching failed for {s}: {s}", .{ cellar_path, @errorName(e) });
    };

    // Ad-hoc codesign on arm64. We only sign the Mach-O files we actually
    // modified above — unpatched binaries keep their original ad-hoc
    // signature, so re-signing them is pure waste. For bottles without any
    // homebrew path references (tree, etc.), the modified list is empty
    // and the ~15 ms codesign subprocess is skipped entirely.
    if (codesign.isArm64() and modified_macho_paths.items.len > 0) {
        codesign.adHocSignAll(allocator, modified_macho_paths.items) catch |e| {
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

const Replacement = struct {
    old: []const u8,
    new: []const u8,
};

/// Walk a cellar directory, apply every replacement in `replacements` to
/// every Mach-O file found, and collect the paths of files that were
/// actually mutated into `modified_out` so the caller can re-codesign
/// only those.
///
/// `modified_out` is a caller-owned list; each appended entry is a
/// freshly duplicated allocation (caller frees). Files whose load
/// commands don't contain any of the needles are left untouched and
/// are *not* added to the list — their ad-hoc signature is still valid
/// and they don't need re-signing.
///
/// `PathTooLong` is surfaced as a real error (MALT_PREFIX exceeded the
/// in-place patching budget); other per-file errors are skipped so a
/// single bad binary does not fail the whole materialize.
fn walkMachOAndPatch(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    replacements: []const Replacement,
    modified_out: *std.ArrayList([]const u8),
) CellarError!void {
    var dir = fs_compat.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var walker = dir.walk(allocator) catch return;
    defer walker.deinit();

    const parser_mod = @import("../macho/parser.zig");

    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;

        const full_path = std.fs.path.join(allocator, &.{ dir_path, entry.path }) catch continue;
        var keep_path = false;
        defer if (!keep_path) allocator.free(full_path);

        // Check if Mach-O by reading magic.
        const file = fs_compat.openFileAbsolute(full_path, .{}) catch continue;
        var magic_buf: [4]u8 = undefined;
        const n = file.readAll(&magic_buf) catch {
            file.close();
            continue;
        };
        file.close();
        if (n < 4) continue;

        if (!parser_mod.isMachO(&magic_buf)) continue;

        var any_modified = false;
        for (replacements) |r| {
            const result = patcher.patchPaths(allocator, full_path, r.old, r.new) catch |e| switch (e) {
                error.PathTooLong => return CellarError.PathTooLong,
                else => continue,
            };
            if (result.patched_count > 0) any_modified = true;
        }

        if (any_modified) {
            // Transfer ownership of `full_path` into the modified list.
            // On append failure, let the defer free it and carry on —
            // we'd rather silently over-sign (i.e. not sign a file we
            // mutated) than abort the whole materialize for an OOM.
            modified_out.append(allocator, full_path) catch continue;
            keep_path = true;
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

    const file = fs_compat.createFileAbsolute(receipt_path, .{}) catch return;
    defer file.close();

    const timestamp = fs_compat.timestamp();
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
    fs_compat.deleteTreeAbsolute(cellar_path) catch return CellarError.RemoveFailed;
}
