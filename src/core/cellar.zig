//! malt — cellar module
//! Cellar materialization: clonefile from store, Mach-O patching, codesigning.

const std = @import("std");
const clonefile = @import("../fs/clonefile.zig");
// Binary-format-agnostic relocation facade. The Linux task plugs in
// an ELF backend behind the same surface, so cellar never reaches past
// it into `macho/patcher.zig` for either load-command or text-file work.
const patch = @import("patch.zig");
const codesign = @import("../macho/codesign.zig");
const atomic = @import("../fs/atomic.zig");
const relocated_store = @import("relocated_store.zig");

pub const CellarError = error{
    CloneFailed,
    PatchFailed,
    PathTooLong,
    /// A bottle's load-command slot overflowed AND the install_name_tool
    /// fallback reported that the binary's __LINKEDIT padding is
    /// exhausted. Only actionable by shortening MALT_PREFIX or
    /// rebuilding the bottle with `-headerpad_max_install_names`.
    InsufficientHeaderPad,
    /// `install_name_tool` is not on PATH. Surfaced separately so
    /// `mt doctor` / user messaging can point at Xcode Command Line
    /// Tools as the remediation.
    InstallNameToolMissing,
    CodesignFailed,
    RemoveFailed,
    OutOfMemory,
};

/// Human-readable description for a CellarError tag.
/// Used by `mt install` when surfacing a materialize failure.
pub fn describeError(err: CellarError) []const u8 {
    // Only spell out the mappings that carry user-actionable hints;
    // trivial tags speak for themselves via @errorName.
    return switch (err) {
        CellarError.InsufficientHeaderPad => "install_name_tool: bottle built without -headerpad_max_install_names",
        CellarError.InstallNameToolMissing => "install_name_tool not found on PATH (install Xcode Command Line Tools)",
        else => @errorName(err),
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
    io: std.Io,
    allocator: std.mem.Allocator,
    prefix: []const u8,
    store_sha256: []const u8,
    name: []const u8,
    version: []const u8,
) CellarError!Keg {
    return materializeWithCellar(io, allocator, prefix, store_sha256, name, version, "");
}

/// Materialize with an explicit cellar type from the bottle metadata.
/// When cellar_type is ":any" or ":any_skip_relocation", Mach-O binary
/// patching is skipped (relocatable bottle). Text placeholder substitution
/// (@@HOMEBREW_PREFIX@@, @@HOMEBREW_CELLAR@@) always runs.
pub fn materializeWithCellar(
    io: std.Io,
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

    // Warm-reinstall fast path: a prior successful materialize for this
    // bottle sha is already on disk, fully relocated. Clonefile-restore
    // it and skip the expensive extract → patch → codesign pipeline.
    // Falls through on any cache miss/error so a flaky cache never breaks
    // the install.
    if (relocated_store.has(io, prefix, store_sha256)) cache_hit: {
        relocated_store.materialize(io, allocator, prefix, store_sha256, name, version) catch |e| {
            std.log.debug("relocated cache miss for {s}: {s}", .{ store_sha256, @errorName(e) });
            break :cache_hit;
        };
        writeInstallReceipt(io, cellar_path, name, version, store_sha256);
        const owned = allocator.dupe(u8, cellar_path) catch return CellarError.OutOfMemory;
        return .{ .name = name, .version = version, .path = owned };
    }

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
    std.Io.Dir.createDirAbsolute(io, parent, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => {
            std.log.debug("cellar parent mkdir {s}: {s}", .{ parent, @errorName(e) });
            return CellarError.CloneFailed;
        },
    };

    // Try keg_src first (exact version match), then scan for a revision
    // suffix variant (e.g. "10.47_1"), fall back to store_path.
    var keg_rev_buf: [512]u8 = undefined;
    const src = blk: {
        // 1. Exact match: {store}/{name}/{version}
        std.Io.Dir.accessAbsolute(io, keg_src, .{}) catch {
            // 2. Scan {store}/{name}/ for a dir starting with "{version}_"
            var name_dir_buf: [512]u8 = undefined;
            const name_dir_path = std.fmt.bufPrint(&name_dir_buf, "{s}/{s}", .{ store_path, name }) catch break :blk store_path;
            var name_dir = std.Io.Dir.openDirAbsolute(io, name_dir_path, .{ .iterate = true }) catch break :blk store_path;
            defer name_dir.close(io);
            var it = name_dir.iterate();
            while (it.next(io) catch null) |entry| {
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
        std.Io.Dir.cwd().deleteTree(io, cellar_path) catch {};
        std.Io.Dir.deleteDirAbsolute(io, parent) catch {};
    }

    // clonefile(2) returns EEXIST on a populated dst; pre-wipe to match
    // the warm path and survive a SIGKILLed prior run or drop-in keg.
    std.Io.Dir.cwd().deleteTree(io, cellar_path) catch {};

    clonefile.cloneTree(io, allocator, src, cellar_path) catch |e| {
        std.log.debug("cellar clonefile {s} -> {s}: {s}", .{ src, cellar_path, @errorName(e) });
        return CellarError.CloneFailed;
    };

    try relocateKegTree(io, allocator, cellar_path, cellar_type);

    // Write INSTALL_RECEIPT.json for brew compatibility
    writeInstallReceipt(io, cellar_path, name, version, store_sha256);

    // Snapshot the post-relocation keg so the next install of the same
    // bottle sha takes the cache short-circuit at the top of this
    // function. Snapshot failure is non-fatal — the user-visible install
    // already succeeded.
    relocated_store.save(io, allocator, prefix, store_sha256, name, version) catch |e| {
        std.log.debug("relocated cache save failed for {s}: {s}", .{ store_sha256, @errorName(e) });
    };

    // Allocate the path so it survives beyond this function's stack
    const owned_path = allocator.dupe(u8, cellar_path) catch return CellarError.OutOfMemory;

    return .{
        .name = name,
        .version = version,
        .path = owned_path,
    };
}

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
/// Slots that overflow their load-command region are deferred to
/// `install_name_tool` — Homebrew bottles ship ~4 KiB of `__LINKEDIT`
/// padding for that exact purpose, which the slow path uses to grow
/// the slot. A non-zero subprocess exit that reports padding
/// exhaustion surfaces `InsufficientHeaderPad` so the user can
/// shorten MALT_PREFIX or rebuild the bottle; anything else falls
/// through to the generic `PatchFailed`. Per-file I/O errors are
/// skipped so a single bad binary does not abort the whole materialize.
fn walkMachOAndPatch(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    replacements: []const patch.Replacement,
    modified_out: *std.ArrayList([]const u8),
) CellarError!void {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var walker = dir.walk(allocator) catch return;
    defer walker.deinit();

    const parser_mod = @import("../macho/parser.zig");

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;

        const full_path = std.fs.path.join(allocator, &.{ dir_path, entry.path }) catch continue;
        var keep_path = false;
        defer if (!keep_path) allocator.free(full_path);

        // Check if Mach-O by reading magic.
        const file = std.Io.Dir.openFileAbsolute(io, full_path, .{}) catch continue;
        var magic_buf: [4]u8 = undefined;
        const n = file.readPositionalAll(io, &magic_buf, 0) catch {
            file.close(io);
            continue;
        };
        file.close(io);
        if (n < 4) continue;

        if (!parser_mod.isMachO(&magic_buf)) continue;

        // One read/write per file for all replacements. Slots that fit
        // are rewritten in process; slots that overflow are queued for
        // the install_name_tool fallback below.
        var outcome = patch.patchPathsCollecting(io, allocator, full_path, replacements) catch
            continue;
        defer outcome.deinit(allocator);

        if (outcome.overflow.len > 0) {
            patch.flushOverflow(io, allocator, full_path, outcome.overflow) catch |e| switch (e) {
                patch.FallbackError.InsufficientHeaderPad => return CellarError.InsufficientHeaderPad,
                patch.FallbackError.InstallNameToolMissing => return CellarError.InstallNameToolMissing,
                patch.FallbackError.OutOfMemory => return CellarError.OutOfMemory,
                else => return CellarError.PatchFailed,
            };
        }

        const any_modified = outcome.patched_count > 0 or outcome.overflow.len > 0;
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

/// Read-only: does any binary under `cellar_path` link a path containing
/// `needle` (e.g. `/opt/<dep>/`)? Lets cleanup keep a dependency a
/// still-installed keg actually links even if its `dependencies` edge was
/// lost. Best-effort over the relocation facade so the ELF backend slots
/// in unchanged; an unreadable keg dir or file is simply "no link found".
pub fn cellarLinksPath(io: std.Io, allocator: std.mem.Allocator, cellar_path: []const u8, needle: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(io, cellar_path, .{ .iterate = true }) catch return false;
    defer dir.close(io);

    var walker = dir.walk(allocator) catch return false;
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const full_path = std.fs.path.join(allocator, &.{ cellar_path, entry.path }) catch continue;
        defer allocator.free(full_path);
        if (patch.fileLinksPath(io, allocator, full_path, needle)) return true;
    }
    return false;
}

/// Write a brew-compatible INSTALL_RECEIPT.json to the keg directory.
/// This allows Homebrew to recognize malt-installed packages.
/// Relocate a freshly-cloned keg tree at `cellar_path` so its embedded
/// path references point at the live malt prefix: patch Mach-O load
/// commands, substitute `@@HOMEBREW_*@@` placeholders in text files,
/// ad-hoc-codesign every Mach-O the patcher actually mutated. Shared
/// by both the bottle materialize path (`materializeWithCellar`) and
/// the local-Cellar copy fallback (`materializeFromLocalCellar`) so
/// every keg lands on disk with byte-identical relocation regardless
/// of whether it came from the store or a sibling brew install.
fn relocateKegTree(
    io: std.Io,
    allocator: std.mem.Allocator,
    cellar_path: []const u8,
    cellar_type: []const u8,
) CellarError!void {
    const new_prefix = atomic.maltPrefixOrAbort();

    var new_cellar_buf: [256]u8 = undefined;
    const new_cellar = std.fmt.bufPrint(&new_cellar_buf, "{s}/Cellar", .{new_prefix}) catch new_prefix;

    // `@@HOMEBREW_*@@` placeholders are patched for every bottle (they
    // appear even in `:any` bottles — zig, curl, rust, llvm@* all use
    // them in LC_LOAD_DYLIB / LC_RPATH). Absolute-path rewrites are
    // skipped for `:any` / `:any_skip_relocation`, where Homebrew
    // guarantees only `@rpath` / `@loader_path` + placeholder tokens.
    const skip_absolute_rewrite = std.mem.eql(u8, cellar_type, ":any") or
        std.mem.eql(u8, cellar_type, ":any_skip_relocation");

    var macho_reps_buf: [4]patch.Replacement = undefined;
    macho_reps_buf[0] = .{ .old = "@@HOMEBREW_PREFIX@@", .new = new_prefix };
    macho_reps_buf[1] = .{ .old = "@@HOMEBREW_CELLAR@@", .new = new_cellar };
    var macho_reps_len: usize = 2;
    if (!skip_absolute_rewrite) {
        macho_reps_buf[2] = .{ .old = "/opt/homebrew", .new = new_prefix };
        macho_reps_buf[3] = .{ .old = "/usr/local", .new = new_prefix };
        macho_reps_len = 4;
    }

    // `walkMachOAndPatch` collects every file it actually mutated; only
    // those need re-signing. Bottles with no `/opt/homebrew` references
    // (`tree`, ...) come back with an empty list and skip the codesign
    // subprocess entirely.
    var modified_macho_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (modified_macho_paths.items) |p| allocator.free(p);
        modified_macho_paths.deinit(allocator);
    }

    walkMachOAndPatch(
        io,
        allocator,
        cellar_path,
        macho_reps_buf[0..macho_reps_len],
        &modified_macho_paths,
    ) catch |e| switch (e) {
        CellarError.PathTooLong => return CellarError.PathTooLong,
        CellarError.InsufficientHeaderPad => return CellarError.InsufficientHeaderPad,
        CellarError.InstallNameToolMissing => return CellarError.InstallNameToolMissing,
        else => return CellarError.PatchFailed,
    };

    const text_replacements = [_]patch.Replacement{
        .{ .old = "@@HOMEBREW_PREFIX@@", .new = new_prefix },
        .{ .old = "@@HOMEBREW_CELLAR@@", .new = new_cellar },
        .{ .old = "/opt/homebrew", .new = new_prefix },
        .{ .old = "/usr/local", .new = new_prefix },
    };
    _ = patch.patchTextFiles(io, allocator, cellar_path, &text_replacements) catch |e| {
        std.log.warn("text patching failed for {s}: {s}", .{ cellar_path, @errorName(e) });
    };

    if (codesign.isArm64() and modified_macho_paths.items.len > 0) {
        codesign.adHocSignAll(io, allocator, modified_macho_paths.items) catch |e| switch (e) {
            error.SpawnFailed => {},
            else => std.log.warn("codesigning failed for {s}: {s}", .{ cellar_path, @errorName(e) }),
        };
    }
}

/// Copy a keg tree from a sibling Homebrew install at `src_keg_path`
/// (typically `$HOMEBREW_PREFIX/Cellar/<name>/<version>/`) into malt's
/// Cellar and run the same relocation pipeline as the bottle path.
/// Used when a private/third-party tap keg isn't resolvable through the
/// brew API but is already present on disk in the user's Homebrew
/// install — the bytes have been vetted by the user, we just relocate
/// them. The caller-supplied `tap` is recorded in the malt-side
/// `INSTALL_RECEIPT.json`. No store entry is created (no sha256 to
/// key on); a fresh install of the same keg will copy from the source
/// Cellar again rather than hitting the relocated-store cache.
pub fn materializeFromLocalCellar(
    io: std.Io,
    allocator: std.mem.Allocator,
    prefix: []const u8,
    src_keg_path: []const u8,
    name: []const u8,
    version: []const u8,
    tap: []const u8,
    cellar_type: []const u8,
) CellarError!Keg {
    var cellar_buf: [512]u8 = undefined;
    const cellar_path = std.fmt.bufPrint(&cellar_buf, "{s}/Cellar/{s}/{s}", .{ prefix, name, version }) catch
        return CellarError.OutOfMemory;

    var parent_buf: [512]u8 = undefined;
    const parent = std.fmt.bufPrint(&parent_buf, "{s}/Cellar/{s}", .{ prefix, name }) catch
        return CellarError.OutOfMemory;
    std.Io.Dir.createDirAbsolute(io, parent, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => {
            std.log.debug("cellar parent mkdir {s}: {s}", .{ parent, @errorName(e) });
            return CellarError.CloneFailed;
        },
    };

    // On any patching failure below, wipe the partial keg and the
    // empty parent dir so the caller can retry without state drift.
    errdefer {
        std.Io.Dir.cwd().deleteTree(io, cellar_path) catch {};
        std.Io.Dir.deleteDirAbsolute(io, parent) catch {};
    }

    // Pre-wipe matches the bottle path: clonefile(2) returns EEXIST on
    // a populated dst, and a SIGKILLed prior run can leave stale state.
    std.Io.Dir.cwd().deleteTree(io, cellar_path) catch {};

    clonefile.cloneTree(io, allocator, src_keg_path, cellar_path) catch |e| {
        std.log.debug("cellar clonefile {s} -> {s}: {s}", .{ src_keg_path, cellar_path, @errorName(e) });
        return CellarError.CloneFailed;
    };

    try relocateKegTree(io, allocator, cellar_path, cellar_type);

    // Tap-aware receipt: the source-of-truth tap is the sibling
    // brew install's, not "homebrew/core". `mt list` and friends use
    // this to surface where a keg originally came from.
    writeInstallReceiptFull(io, cellar_path, name, version, "", tap, true);

    const owned_path = allocator.dupe(u8, cellar_path) catch return CellarError.OutOfMemory;
    return .{ .name = name, .version = version, .path = owned_path };
}

fn writeInstallReceipt(io: std.Io, cellar_path: []const u8, name: []const u8, version: []const u8, store_sha256: []const u8) void {
    writeInstallReceiptFull(io, cellar_path, name, version, store_sha256, null, true);
}

/// Public version with full options for tap installs.
pub fn writeInstallReceiptFull(
    io: std.Io,
    cellar_path: []const u8,
    name: []const u8,
    version: []const u8,
    store_sha256: []const u8,
    tap: ?[]const u8,
    is_direct: bool,
) void {
    var path_buf: [512]u8 = undefined;
    const receipt_path = std.fmt.bufPrint(&path_buf, "{s}/INSTALL_RECEIPT.json", .{cellar_path}) catch return;

    const file = std.Io.Dir.createFileAbsolute(io, receipt_path, .{}) catch return;
    defer file.close(io);

    const timestamp = std.Io.Clock.real.now(io).toSeconds();
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

    // INSTALL_RECEIPT.json is consumed by Homebrew-compat tools only; a
    // partial write leaves the keg usable, and the DB is the source of truth.
    file.writeStreamingAll(io, json) catch {};
}

/// Remove a keg from the Cellar.
pub fn remove(io: std.Io, prefix: []const u8, name: []const u8, version: []const u8) CellarError!void {
    var buf: [512]u8 = undefined;
    const cellar_path = std.fmt.bufPrint(&buf, "{s}/Cellar/{s}/{s}", .{ prefix, name, version }) catch
        return CellarError.OutOfMemory;
    std.Io.Dir.cwd().deleteTree(io, cellar_path) catch return CellarError.RemoveFailed;
}

// Pins the describeError split: only the user-actionable mappings carry
// prose; every other tag falls through to @errorName.
test "describeError: action-hint tags keep prose, trivial tags fall back to @errorName" {
    try std.testing.expect(std.mem.indexOf(u8, describeError(CellarError.InsufficientHeaderPad), "-headerpad_max_install_names") != null);
    try std.testing.expect(std.mem.indexOf(u8, describeError(CellarError.InstallNameToolMissing), "install_name_tool not found on PATH") != null);

    const fallback_tags = [_]CellarError{
        CellarError.CloneFailed,
        CellarError.PatchFailed,
        CellarError.PathTooLong,
        CellarError.CodesignFailed,
        CellarError.RemoveFailed,
        CellarError.OutOfMemory,
    };
    inline for (fallback_tags) |e| {
        try std.testing.expectEqualStrings(@errorName(e), describeError(e));
    }
}
