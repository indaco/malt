//! malt — cellar module
//! Cellar materialization: clonefile from store, Mach-O patching, codesigning.

const std = @import("std");
const clonefile = @import("../fs/clonefile.zig");
// Binary-format-agnostic relocation facade. The Linux task plugs in
// an ELF backend behind the same surface, so cellar never reaches past
// it into `macho/patcher.zig` for either load-command or text-file work.
const patch = @import("patch.zig");
const formula = @import("formula.zig");
const codesign = @import("../macho/codesign.zig");
const atomic = @import("../fs/atomic.zig");
const path_component = @import("../fs/path_component.zig");
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
    /// The keg on disk violates an invariant malt is responsible for (a
    /// duplicate LC_RPATH, a placeholder relocation failed to substitute).
    /// The offending file is named in the log; the keg is wiped rather than
    /// recorded, because dyld would refuse to load it.
    VerifyFailed,
    RemoveFailed,
    /// A `name` or `version` that would not stay a single directory under
    /// the Cellar. Every sink that splices one into a path checks for
    /// itself, so the confinement holds even when a feeder forgets.
    UnsafePathComponent,
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
        CellarError.VerifyFailed => "relocated keg ships a binary the loader would reject (re-run with --debug to name it)",
        CellarError.UnsafePathComponent => "formula name or version would place the keg outside the Cellar",
        else => @errorName(err),
    };
}

/// Whether a sink accepts the empty version `parseFormula` produces for a
/// formula with no `versions.stable`. Materializing one is legitimate;
/// deleting is not, because an empty version collapses the path to the whole
/// package dir and would take every sibling version with it.
const EmptyVersion = enum { ok, refused };

/// Every Cellar sink splices `name`/`version` into
/// `<prefix>/Cellar/<name>/<version>` and then writes or deletes there, so
/// each one checks for itself rather than trusting its feeder.
fn confined(name: []const u8, version: []const u8, empty: EmptyVersion) bool {
    if (!path_component.isPathComponent(name)) return false;
    if (empty == .ok and version.len == 0) return true;
    return path_component.isPathComponent(version);
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
    return materializeWithCellar(io, allocator, prefix, store_sha256, name, version, "", null);
}

/// Materialize with an explicit cellar type from the bottle metadata.
/// When cellar_type is ":any" or ":any_skip_relocation", Mach-O binary
/// patching is skipped (relocatable bottle). Text placeholder substitution
/// (@@HOMEBREW_PREFIX@@, @@HOMEBREW_CELLAR@@) always runs.
///
/// `extra_replacement` carries a substitution the caller resolved from the
/// formula (see `formula.dependencyPlaceholder`); null for most bottles.
pub fn materializeWithCellar(
    io: std.Io,
    allocator: std.mem.Allocator,
    prefix: []const u8,
    store_sha256: []const u8,
    name: []const u8,
    version: []const u8,
    cellar_type: []const u8,
    extra_replacement: ?patch.Replacement,
) CellarError!Keg {
    if (!confined(name, version, .ok)) return CellarError.UnsafePathComponent;

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
        // A snapshot taken by an older, buggier relocation outlives the fix
        // that would repair it, because this path never re-patches. Check an
        // unverified entry once and evict it if it fails: the cold path wipes
        // `cellar_path` before cloning, so a bad entry cannot survive a second
        // install even if its cache key was never invalidated. Entries this
        // malt verified are trusted, which keeps warm reinstalls free.
        if (!relocated_store.isVerified(io, prefix, store_sha256)) {
            walkMachOAndVerify(io, allocator, cellar_path) catch |e| {
                std.log.debug("cached keg {s} failed verification ({s}); re-relocating", .{ store_sha256, @errorName(e) });
                relocated_store.remove(io, prefix, store_sha256) catch {};
                break :cache_hit;
            };
            relocated_store.markVerified(io, prefix, store_sha256);
        }
        writeInstallReceipt(io, cellar_path, name, version, store_sha256);
        // Homebrew re-pours etc/var on every install; the cached keg
        // carries `.bottle`, so a wiped or drifted live config is
        // restored even when relocation is skipped.
        installBottleEtcVar(io, allocator, cellar_path, prefix);
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

    try relocateKegTree(io, allocator, cellar_path, cellar_type, extra_replacement);

    // Write INSTALL_RECEIPT.json for brew compatibility
    writeInstallReceipt(io, cellar_path, name, version, store_sha256);

    // Snapshot the post-relocation keg so the next install of the same
    // bottle sha takes the cache short-circuit at the top of this
    // function. Snapshot failure is non-fatal — the user-visible install
    // already succeeded.
    if (relocated_store.save(io, allocator, prefix, store_sha256, name, version)) {
        // `relocateKegTree` already checked this keg, so restores can skip it.
        relocated_store.markVerified(io, prefix, store_sha256);
    } else |e| {
        std.log.debug("relocated cache save failed for {s}: {s}", .{ store_sha256, @errorName(e) });
    }

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
    unrelocatable_out: *u32,
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

        unrelocatable_out.* += outcome.unrelocatable_count;

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

/// Check every Mach-O under `dir_path` against the post-relocation
/// invariants. The first violation fails the keg: malt would otherwise
/// report a successful install for a binary the loader refuses to start.
/// Mirrors `walkMachOAndPatch`'s magic pre-filter so the scan costs four
/// bytes per non-binary file rather than a full read.
fn walkMachOAndVerify(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8) CellarError!void {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var walker = dir.walk(allocator) catch return;
    defer walker.deinit();

    const parser_mod = @import("../macho/parser.zig");

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;

        const full_path = std.fs.path.join(allocator, &.{ dir_path, entry.path }) catch continue;
        defer allocator.free(full_path);

        const file = std.Io.Dir.openFileAbsolute(io, full_path, .{}) catch continue;
        var magic_buf: [4]u8 = undefined;
        const n = file.readPositionalAll(io, &magic_buf, 0) catch {
            file.close(io);
            continue;
        };
        file.close(io);
        if (n < 4 or !parser_mod.isMachO(&magic_buf)) continue;

        patch.verifyFile(io, allocator, full_path) catch |e| {
            // Debug level, like every other per-file detail in this module:
            // the user-facing failure is the non-zero exit plus
            // `describeError`, which points at `--debug` for the file name.
            std.log.debug("keg verification failed for {s}: {s}", .{ full_path, @errorName(e) });
            return CellarError.VerifyFailed;
        };
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
/// `extra_replacement` is one caller-resolved substitution applied after the
/// prefix-derived ones, for tokens this module cannot derive on its own.
/// Count of embedded paths relocation could not rewrite. Recorded rather than
/// re-derived later: whether a bottle was eligible for the absolute rewrite at
/// all is decided here and nowhere else. Lives in the keg so it dies with it.
pub const unrelocated_marker = ".malt-unrelocated";

fn writeUnrelocatedMarker(io: std.Io, allocator: std.mem.Allocator, cellar_path: []const u8, count: u32) void {
    writeKegMarker(io, allocator, cellar_path, unrelocated_marker, count);
}

/// Holds the keg's `RelocStamp`. The bottle carries no such signal and its
/// surviving paths cannot supply one — a relocatable bottle legitimately keeps
/// build-prefix strings — so the stamp is written at the one place that knows.
pub const reloc_version_marker = ".malt-reloc-version";

fn writeKegMarker(io: std.Io, allocator: std.mem.Allocator, cellar_path: []const u8, name: []const u8, value: u32) void {
    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
    writeKegMarkerText(io, allocator, cellar_path, name, text);
}

fn writeKegMarkerText(io: std.Io, allocator: std.mem.Allocator, cellar_path: []const u8, name: []const u8, text: []const u8) void {
    const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ cellar_path, name }) catch return;
    defer allocator.free(path);
    const body = std.fmt.allocPrint(allocator, "{s}\n", .{text}) catch return;
    defer allocator.free(body);
    // Best-effort: a failed write costs a doctor row, never the install.
    atomic.atomicWriteFile(io, path, body) catch {};
}

/// What relocation did to a keg. `not_applicable` is its own answer, not a
/// version: a keg that is extracted rather than relocated has nothing to
/// refresh, so no future bump should ever name it. A missing stamp is a third
/// state — the keg predates stamping and malt cannot say which rules built it.
pub const RelocStamp = union(enum) {
    not_applicable,
    version: u32,
};

const not_applicable_text = "n/a";

pub fn writeRelocStamp(io: std.Io, allocator: std.mem.Allocator, cellar_path: []const u8, stamp: RelocStamp) void {
    switch (stamp) {
        .not_applicable => writeKegMarkerText(io, allocator, cellar_path, reloc_version_marker, not_applicable_text),
        .version => |v| writeKegMarker(io, allocator, cellar_path, reloc_version_marker, v),
    }
}

/// Null when the stamp is absent or unreadable — never a version, since a
/// coerced number would read as stale and send the user to reinstall.
pub fn readRelocStamp(io: std.Io, cellar_path: []const u8) ?RelocStamp {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cellar_path, reloc_version_marker }) catch return null;
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    var buf: [32]u8 = undefined;
    const n = file.readPositional(io, &.{&buf}, 0) catch return null;
    const text = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (std.mem.eql(u8, text, not_applicable_text)) return .not_applicable;
    return .{ .version = std.fmt.parseInt(u32, text, 10) catch return null };
}

/// Marker names malt owns inside a keg. Relocation rewrites them last, so a
/// bottle cannot forge one — but a path that extracts an archive without
/// relocating must strip them, or the archive's author decides what doctor
/// reports about the keg.
pub const keg_markers = [_][]const u8{ unrelocated_marker, reloc_version_marker };

pub fn stripKegMarkers(io: std.Io, cellar_path: []const u8) void {
    for (keg_markers) |name| {
        var buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ cellar_path, name }) catch continue;
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }
}

/// Resolve the perl shebang token from the keg's own `.brew/<name>.rb`, whose
/// dependency list is what decides between a brewed perl and the system one.
/// A keg without that file (a local-Cellar copy, a hand-dropped tree) resolves
/// on its name alone, which still catches perl itself.
fn perlReplacement(
    io: std.Io,
    allocator: std.mem.Allocator,
    buf: []u8,
    prefix: []const u8,
    cellar_path: []const u8,
) patch.Replacement {
    // `<prefix>/Cellar/<name>/<version>` — both call sites build it that way.
    const name = std.fs.path.basename(std.fs.path.dirname(cellar_path) orelse "");

    const ph = perlFromFormulaSource(io, allocator, buf, prefix, cellar_path, name) orelse
        formula.perlPlaceholder(buf, prefix, name, &.{});
    return .{ .old = ph.token, .new = ph.value };
}

/// Null when the formula source is unreadable. The dependency names borrow
/// from it, so the placeholder is formatted into `buf` before it is freed.
fn perlFromFormulaSource(
    io: std.Io,
    allocator: std.mem.Allocator,
    buf: []u8,
    prefix: []const u8,
    cellar_path: []const u8,
    name: []const u8,
) ?formula.Placeholder {
    const src = formula.readKegSource(io, allocator, cellar_path, name) orelse return null;
    defer allocator.free(src);

    var dep_buf: [64][]const u8 = undefined;
    return formula.perlPlaceholder(buf, prefix, name, formula.declaredDependencies(&dep_buf, src));
}

/// Relocate a keg malt staged itself — a tap or `--local` formula's archive or
/// bare release binary — rather than one poured from a bottle. Only the Mach-O
/// half of `relocateKegTree` applies: such an artefact carries no
/// `@@HOMEBREW_*@@` placeholders (those are a bottling artefact), no text tree
/// and no `.bottle/etc` overlay — just the absolute build prefix its author
/// linked against, which is not where malt puts anything.
///
/// Patching invalidates the artefact's signature, so every file this touches is
/// re-signed. A keg with nothing to patch comes back byte-identical and skips
/// the codesign subprocess entirely.
pub fn relocateUnbottledKeg(
    io: std.Io,
    allocator: std.mem.Allocator,
    cellar_path: []const u8,
) CellarError!void {
    const new_prefix = atomic.maltPrefixOrAbort();

    const reps = [_]patch.Replacement{
        .{ .old = "/opt/homebrew", .new = new_prefix },
        .{ .old = "/usr/local", .new = new_prefix },
    };

    var modified: std.ArrayList([]const u8) = .empty;
    defer {
        for (modified.items) |m| allocator.free(m);
        modified.deinit(allocator);
    }

    var unrelocatable: u32 = 0;
    walkMachOAndPatch(io, allocator, cellar_path, &reps, &modified, &unrelocatable) catch |e| switch (e) {
        CellarError.PathTooLong => return CellarError.PathTooLong,
        CellarError.InsufficientHeaderPad => return CellarError.InsufficientHeaderPad,
        CellarError.InstallNameToolMissing => return CellarError.InstallNameToolMissing,
        else => return CellarError.PatchFailed,
    };

    if (unrelocatable > 0) {
        std.log.warn(
            "{s}: {d} embedded path(s) still point at the build prefix — the malt prefix ({d} bytes) is longer than the one baked into the binary; a shorter prefix relocates them",
            .{ cellar_path, unrelocatable, new_prefix.len },
        );
        writeUnrelocatedMarker(io, allocator, cellar_path, unrelocatable);
    }

    if (codesign.isArm64() and modified.items.len > 0) {
        codesign.adHocSignAll(io, allocator, modified.items) catch |e| switch (e) {
            error.SpawnFailed => {},
            else => std.log.warn("codesigning failed for {s}: {s}", .{ cellar_path, @errorName(e) }),
        };
    }

    try walkMachOAndVerify(io, allocator, cellar_path);

    writeRelocStamp(io, allocator, cellar_path, .{ .version = relocated_store.RELOC_LOGIC_VERSION });
}

fn relocateKegTree(
    io: std.Io,
    allocator: std.mem.Allocator,
    cellar_path: []const u8,
    cellar_type: []const u8,
    extra_replacement: ?patch.Replacement,
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

    var unrelocatable: u32 = 0;
    walkMachOAndPatch(
        io,
        allocator,
        cellar_path,
        macho_reps_buf[0..macho_reps_len],
        &modified_macho_paths,
        &unrelocatable,
    ) catch |e| switch (e) {
        CellarError.PathTooLong => return CellarError.PathTooLong,
        CellarError.InsufficientHeaderPad => return CellarError.InsufficientHeaderPad,
        CellarError.InstallNameToolMissing => return CellarError.InstallNameToolMissing,
        else => return CellarError.PatchFailed,
    };

    // An embedded string can only shrink in place, so a prefix longer than
    // the bottled one leaves live references to the build prefix behind. The
    // package then reads config from a directory malt does not own and fails
    // in ways that look unrelated to the prefix — say so, and record it so
    // doctor can still report the keg once this line has scrolled away.
    if (unrelocatable > 0) {
        std.log.warn(
            "{s}: {d} embedded path(s) still point at the build prefix — the malt prefix ({d} bytes) is longer than the one baked into the bottle; a shorter prefix relocates them",
            .{ cellar_path, unrelocatable, new_prefix.len },
        );
        writeUnrelocatedMarker(io, allocator, cellar_path, unrelocatable);
    }

    var new_library_buf: [256]u8 = undefined;
    const new_library = std.fmt.bufPrint(&new_library_buf, "{s}/Library", .{new_prefix}) catch new_prefix;

    // Resolved here rather than at each call site so install, upgrade, migrate
    // and rollback cannot drift apart on it.
    var perl_buf: [std.fs.max_path_bytes]u8 = undefined;
    const perl = perlReplacement(io, allocator, &perl_buf, new_prefix, cellar_path);

    // Last on purpose: `patchTextFiles` runs sequential passes, so appending
    // keeps the substituted path out of the prefix rewrites above.
    var text_reps_buf: [8]patch.Replacement = undefined;
    text_reps_buf[0] = .{ .old = "@@HOMEBREW_PREFIX@@", .new = new_prefix };
    text_reps_buf[1] = .{ .old = "@@HOMEBREW_CELLAR@@", .new = new_cellar };
    // malt has no separate repository checkout; shellenv reports the prefix.
    text_reps_buf[2] = .{ .old = "@@HOMEBREW_REPOSITORY@@", .new = new_prefix };
    text_reps_buf[3] = .{ .old = "@@HOMEBREW_LIBRARY@@", .new = new_library };
    text_reps_buf[4] = .{ .old = "/opt/homebrew", .new = new_prefix };
    text_reps_buf[5] = .{ .old = "/usr/local", .new = new_prefix };
    text_reps_buf[6] = perl;
    var text_reps_len: usize = 7;
    if (extra_replacement) |r| {
        text_reps_buf[7] = r;
        text_reps_len = 8;
    }
    _ = patch.patchTextFiles(io, allocator, cellar_path, text_reps_buf[0..text_reps_len]) catch |e| {
        std.log.warn("text patching failed for {s}: {s}", .{ cellar_path, @errorName(e) });
    };

    if (codesign.isArm64() and modified_macho_paths.items.len > 0) {
        codesign.adHocSignAll(io, allocator, modified_macho_paths.items) catch |e| switch (e) {
            error.SpawnFailed => {},
            else => std.log.warn("codesigning failed for {s}: {s}", .{ cellar_path, @errorName(e) }),
        };
    }

    // Before the etc/var pour, which writes outside the keg: a failure here
    // must leave nothing behind but the caller's `errdefer` wipe.
    try walkMachOAndVerify(io, allocator, cellar_path);

    // After text patching, so the poured configs already carry the malt
    // prefix instead of the bottled `/opt/homebrew` paths.
    installBottleEtcVar(io, allocator, cellar_path, new_prefix);

    // Last: only a keg that got this far was relocated by this logic.
    writeRelocStamp(io, allocator, cellar_path, .{ .version = relocated_store.RELOC_LOGIC_VERSION });
}

/// Pour the bottle's `.bottle/etc` and `.bottle/var` overlay into the
/// live prefix, mirroring Homebrew's pour: a missing file is installed,
/// an identical one skipped, and a user-modified config receives the
/// new bottled default beside it as `<name>.default` instead of a
/// clobber. Best-effort like the text pass — a per-file failure is
/// warned about, never fatal to the install.
/// Pub so the cellar tests can drive it against a scratch prefix.
pub fn installBottleEtcVar(
    io: std.Io,
    allocator: std.mem.Allocator,
    cellar_path: []const u8,
    prefix: []const u8,
) void {
    for ([_][]const u8{ "etc", "var" }) |sub| {
        const src_root = std.fs.path.join(allocator, &.{ cellar_path, ".bottle", sub }) catch continue;
        defer allocator.free(src_root);

        // Most bottles ship no overlay — a missing dir is the normal case.
        var dir = std.Io.Dir.openDirAbsolute(io, src_root, .{ .iterate = true }) catch continue;
        defer dir.close(io);

        var walker = dir.walk(allocator) catch continue;
        defer walker.deinit();

        while (walker.next(io) catch null) |entry| {
            if (entry.kind == .directory) {
                // Bottles ship empty overlay dirs (dbus's `var/lib/dbus`)
                // that hooks rely on; pour the tree shape, not just files.
                const dst = std.fs.path.join(allocator, &.{ prefix, sub, entry.path }) catch continue;
                defer allocator.free(dst);
                std.Io.Dir.cwd().createDirPath(io, dst) catch |e| {
                    std.log.warn("bottle overlay {s}/{s} dir not created: {s}", .{ sub, entry.path, @errorName(e) });
                };
                continue;
            }
            if (entry.kind != .file) {
                std.log.warn("bottle overlay {s}/{s} skipped (unsupported kind)", .{ sub, entry.path });
                continue;
            }
            pourOverlayFile(io, allocator, src_root, entry.path, prefix, sub) catch |e| {
                std.log.warn("bottle overlay {s}/{s} not poured: {s}", .{ sub, entry.path, @errorName(e) });
            };
        }
    }
}

/// One overlay file: install-if-missing, skip-if-identical, else write
/// the bottled content as `<dst>.default` so user edits survive.
fn pourOverlayFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    src_root: []const u8,
    rel: []const u8,
    prefix: []const u8,
    sub: []const u8,
) !void {
    const src_path = try std.fs.path.join(allocator, &.{ src_root, rel });
    defer allocator.free(src_path);
    const dst_path = try std.fs.path.join(allocator, &.{ prefix, sub, rel });
    defer allocator.free(dst_path);

    const content = try readOverlayFile(io, allocator, src_path);
    defer allocator.free(content);

    if (readOverlayFile(io, allocator, dst_path)) |existing| {
        defer allocator.free(existing);
        if (std.mem.eql(u8, existing, content)) return;
        const default_path = try std.mem.concat(allocator, u8, &.{ dst_path, ".default" });
        defer allocator.free(default_path);
        try atomic.atomicReplaceFile(io, default_path, content);
    } else |_| {
        if (std.fs.path.dirname(dst_path)) |parent| {
            try std.Io.Dir.cwd().createDirPath(io, parent);
        }
        try atomic.atomicReplaceFile(io, dst_path, content);
    }
}

fn readOverlayFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    // Overlays are config seeds; anything bigger is not a config we
    // should buffer or silently clobber.
    if (stat.size > 10 * 1024 * 1024) return error.FileTooBig;
    const buf = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    if (n < buf.len) return error.EndOfStream;
    return buf;
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
    if (!confined(name, version, .ok)) return CellarError.UnsafePathComponent;

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

    // No extra replacement: this keg is copied from a sibling brew install,
    // which already resolved every dependency-scoped token at its own
    // install time.
    try relocateKegTree(io, allocator, cellar_path, cellar_type, null);

    // Tap-aware receipt: the source-of-truth tap is the sibling
    // brew install's, not "homebrew/core". `mt list` and friends use
    // this to surface where a keg originally came from.
    writeInstallReceiptFull(io, cellar_path, name, version, "", tap, true);

    const owned_path = allocator.dupe(u8, cellar_path) catch return CellarError.OutOfMemory;
    return .{ .name = name, .version = version, .path = owned_path };
}

/// Escape `s` as JSON string *contents* (no surrounding quotes) into `buf`,
/// returning the written slice or null on overflow. Duplicated from the bundle
/// emitter's escaper rather than importing across modules; this sink is a fixed
/// buffer, not a `std.Io.Writer`, so it can't share the same signature.
fn jsonEscapeInto(buf: []u8, s: []const u8) ?[]const u8 {
    var w: usize = 0;
    for (s) |byte| {
        const esc: ?[]const u8 = switch (byte) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x08 => "\\b",
            0x0c => "\\f",
            else => null,
        };
        if (esc) |e| {
            if (w + e.len > buf.len) return null;
            @memcpy(buf[w..][0..e.len], e);
            w += e.len;
        } else if (byte < 0x20) {
            if (w + 6 > buf.len) return null;
            _ = std.fmt.bufPrint(buf[w..], "\\u{x:0>4}", .{byte}) catch return null;
            w += 6;
        } else {
            if (w >= buf.len) return null;
            buf[w] = byte;
            w += 1;
        }
    }
    return buf[0..w];
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
    const reason = if (is_direct) "true" else "false";
    const dep_reason = if (is_direct) "false" else "true";

    // Escape tap/version before interpolating them into quoted JSON slots: a
    // `"`/`\` from a hand-authored tap would otherwise emit malformed receipts.
    var tap_scratch: [256]u8 = undefined;
    var ver_scratch: [256]u8 = undefined;
    const tap_str = jsonEscapeInto(&tap_scratch, tap orelse "homebrew/core") orelse return;
    const version_str = jsonEscapeInto(&ver_scratch, version) orelse return;

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
        version_str,
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
    if (!confined(name, version, .refused)) return CellarError.UnsafePathComponent;

    var buf: [512]u8 = undefined;
    const cellar_path = std.fmt.bufPrint(&buf, "{s}/Cellar/{s}/{s}", .{ prefix, name, version }) catch
        return CellarError.OutOfMemory;
    std.Io.Dir.cwd().deleteTree(io, cellar_path) catch return CellarError.RemoveFailed;
}

/// One LC_LOAD_DYLIB carrying `dylib_path`. Enough for the relocation walk,
/// which only reads the header and the load-command path slots.
fn buildLoadDylibMachO(allocator: std.mem.Allocator, dylib_path: []const u8, cmdsize: u32) ![]u8 {
    const macho_mod = std.macho;
    const header_size = @sizeOf(macho_mod.mach_header_64);
    const path_off: u32 = @sizeOf(macho_mod.dylib_command);

    const buf = try allocator.alloc(u8, header_size + cmdsize);
    @memset(buf, 0);

    const hdr = std.mem.bytesAsValue(macho_mod.mach_header_64, buf[0..header_size]);
    hdr.* = .{ .magic = macho_mod.MH_MAGIC_64, .ncmds = 1, .sizeofcmds = cmdsize };

    const cmd = std.mem.bytesAsValue(macho_mod.dylib_command, buf[header_size..][0..path_off]);
    cmd.* = .{
        .cmd = .LOAD_DYLIB,
        .cmdsize = cmdsize,
        .dylib = .{ .name = path_off, .timestamp = 0, .current_version = 0, .compatibility_version = 0 },
    };
    std.debug.assert(dylib_path.len + 1 <= cmdsize - path_off);
    @memcpy(buf[header_size + path_off ..][0..dylib_path.len], dylib_path);

    return buf;
}

fn relocatedDylibPath(allocator: std.mem.Allocator, io: std.Io, bin_path: []const u8) ![]u8 {
    const parser_mod = @import("../macho/parser.zig");
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, bin_path, allocator, .unlimited);
    defer allocator.free(bytes);

    var parsed = try parser_mod.parse(allocator, bytes);
    defer parsed.deinit();
    return allocator.dupe(u8, parsed.paths[0].path);
}

test "relocateUnbottledKeg rewrites a build-prefix dylib reference to the malt prefix" {
    const testing = std.testing;
    const io = std.Options.debug_io;

    // A third-party build links the prefix its author used. malt owns a
    // different one, so an unpatched binary resolves nothing at runtime.
    var s = try Scratch.init("reloc_binary_keg");
    defer s.deinit();
    const keg = s.p("/Cellar/tool/1.0");
    const bin_dir = s.p("/Cellar/tool/1.0/bin");
    try std.Io.Dir.cwd().createDirPath(io, bin_dir);

    const bytes = try buildLoadDylibMachO(
        testing.allocator,
        "/opt/homebrew/opt/flac/lib/libFLAC.14.dylib",
        128,
    );
    defer testing.allocator.free(bytes);
    const bin = s.p("/Cellar/tool/1.0/bin/tool");
    try atomic.atomicWriteFile(io, bin, bytes);

    try relocateUnbottledKeg(io, testing.allocator, keg);

    const got = try relocatedDylibPath(testing.allocator, io, bin);
    defer testing.allocator.free(got);

    const prefix = atomic.maltPrefixOrAbort();
    try testing.expect(std.mem.startsWith(u8, got, prefix));
    try testing.expect(std.mem.endsWith(u8, got, "/opt/flac/lib/libFLAC.14.dylib"));
    try testing.expect(std.mem.indexOf(u8, got, "/opt/homebrew") == null);

    // Relocation ran, so a future logic bump must be able to name this keg —
    // `not_applicable` would exempt it forever.
    try testing.expectEqual(
        RelocStamp{ .version = relocated_store.RELOC_LOGIC_VERSION },
        readRelocStamp(io, keg).?,
    );
}

test "relocateUnbottledKeg does not follow a symlink out of the keg" {
    const testing = std.testing;
    const io = std.Options.debug_io;

    // Tap archives are third-party. One shipping `lib -> /opt/homebrew/lib`
    // must not turn relocation into a rewrite of files malt does not own.
    var s = try Scratch.init("reloc_binary_symlink");
    defer s.deinit();
    const keg = s.p("/Cellar/tool/1.0");
    try std.Io.Dir.cwd().createDirPath(io, keg);
    const outside = s.p("/outside");
    try std.Io.Dir.cwd().createDirPath(io, outside);

    const bytes = try buildLoadDylibMachO(
        testing.allocator,
        "/opt/homebrew/opt/flac/lib/libFLAC.14.dylib",
        128,
    );
    defer testing.allocator.free(bytes);
    const victim = s.p("/outside/victim.dylib");
    try atomic.atomicWriteFile(io, victim, bytes);

    const link = s.p("/Cellar/tool/1.0/lib");
    try std.Io.Dir.cwd().symLink(io, outside, link, .{});

    try relocateUnbottledKeg(io, testing.allocator, keg);

    const after = try std.Io.Dir.cwd().readFileAlloc(io, victim, testing.allocator, .unlimited);
    defer testing.allocator.free(after);
    try testing.expectEqualSlices(u8, bytes, after);
}

test "relocateUnbottledKeg leaves a binary with no build-prefix reference untouched" {
    const testing = std.testing;
    const io = std.Options.debug_io;

    // Many tap artefacts are static. Rewriting nothing means the signature
    // they shipped stays valid, so the bytes must come back untouched.
    var s = try Scratch.init("reloc_binary_noop");
    defer s.deinit();
    const keg = s.p("/Cellar/tool/1.0");
    const bin_dir = s.p("/Cellar/tool/1.0/bin");
    try std.Io.Dir.cwd().createDirPath(io, bin_dir);

    const bytes = try buildLoadDylibMachO(testing.allocator, "@rpath/libself.dylib", 128);
    defer testing.allocator.free(bytes);
    const bin = s.p("/Cellar/tool/1.0/bin/tool");
    try atomic.atomicWriteFile(io, bin, bytes);

    try relocateUnbottledKeg(io, testing.allocator, keg);

    const after = try std.Io.Dir.cwd().readFileAlloc(io, bin, testing.allocator, .unlimited);
    defer testing.allocator.free(after);
    try testing.expectEqualSlices(u8, bytes, after);

    // Still stamped: the logic ran, it simply had nothing to do.
    try testing.expectEqual(
        RelocStamp{ .version = relocated_store.RELOC_LOGIC_VERSION },
        readRelocStamp(io, keg).?,
    );
}

// Pins the describeError split: only the user-actionable mappings carry
// prose; every other tag falls through to @errorName.
test "reloc stamp round-trips both states; anything unreadable is absent" {
    const testing = std.testing;
    const io = std.Options.debug_io;

    var s = try Scratch.init("reloc_stamp");
    defer s.deinit();
    const keg = s.p("/Cellar/glow/1.2.3");
    try std.Io.Dir.cwd().createDirPath(io, keg);

    // Absent is its own state: the keg predates stamping, and reading it as a
    // version would send the user to reinstall on no evidence.
    try testing.expect(readRelocStamp(io, keg) == null);

    writeRelocStamp(io, testing.allocator, keg, .{ .version = 4 });
    try testing.expectEqual(RelocStamp{ .version = 4 }, readRelocStamp(io, keg).?);

    // A keg that was extracted, never relocated: no bump can make it stale.
    writeRelocStamp(io, testing.allocator, keg, .not_applicable);
    try testing.expectEqual(RelocStamp.not_applicable, readRelocStamp(io, keg).?);

    const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ keg, reloc_version_marker });
    defer testing.allocator.free(path);
    // Hand-edited spacing still reads.
    try atomic.atomicWriteFile(io, path, " 12 \r\n");
    try testing.expectEqual(RelocStamp{ .version = 12 }, readRelocStamp(io, keg).?);

    // Garbage must never coerce to a version — a bogus 0 flags every keg.
    for ([_][]const u8{ "v4\n", "", "99999999999999999999\n", "n/a extra\n" }) |bad| {
        try atomic.atomicWriteFile(io, path, bad);
        try testing.expect(readRelocStamp(io, keg) == null);
    }
}

test "stripKegMarkers clears a marker the extracted archive supplied" {
    const testing = std.testing;
    const io = std.Options.debug_io;

    var s = try Scratch.init("strip_markers");
    defer s.deinit();
    const keg = s.p("/Cellar/glow/1.2.3");
    try std.Io.Dir.cwd().createDirPath(io, keg);

    // An archive that ships a stamp would otherwise decide what doctor says
    // about the keg — a high one silences it, a low one warns forever, since
    // the path that extracted it never relocates and so never restamps.
    for (keg_markers) |name| {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ keg, name });
        defer testing.allocator.free(p);
        try atomic.atomicWriteFile(io, p, "999\n");
    }
    try testing.expectEqual(RelocStamp{ .version = 999 }, readRelocStamp(io, keg).?);

    stripKegMarkers(io, keg);
    try testing.expect(readRelocStamp(io, keg) == null);
    // Idempotent: the strip runs on every such install, most with no markers.
    stripKegMarkers(io, keg);
}

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

const fs_test_io = std.Options.debug_io;

fn rmrf(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(fs_test_io, path) catch {};
}

var scratch_seq: std.atomic.Value(u32) = .init(0);

/// Scratch tree under a process- and call-unique base: overlapping test runs
/// share /tmp and would otherwise delete each other's fixtures.
const Scratch = struct {
    arena: std.heap.ArenaAllocator,
    base: [:0]const u8,

    fn init(comptime tag: []const u8) !Scratch {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const base = try std.fmt.allocPrintSentinel(
            arena.allocator(),
            "/tmp/malt_" ++ tag ++ "_{d}_{d}",
            .{ std.c.getpid(), scratch_seq.fetchAdd(1, .monotonic) },
            0,
        );
        rmrf(base);
        return .{ .arena = arena, .base = base };
    }

    /// Absolute path to `sub` (leading slash included) inside the scratch
    /// tree; valid until `deinit`.
    fn p(self: *Scratch, sub: []const u8) [:0]const u8 {
        return std.fmt.allocPrintSentinel(
            self.arena.allocator(),
            "{s}{s}",
            .{ self.base, sub },
            0,
        ) catch @panic("OOM");
    }

    fn deinit(self: *Scratch) void {
        rmrf(self.base);
        self.arena.deinit();
    }
};

/// Test helper: write a receipt with the given tap/version into a unique temp
/// dir, read it back, clean up, and return the owned bytes. `tag` keeps
/// concurrent test binaries from colliding on the same path.
fn writeReceiptAndRead(io: std.Io, alloc: std.mem.Allocator, comptime tag: []const u8, tap: []const u8, version: []const u8) ![]u8 {
    var s = try Scratch.init("receipt_" ++ tag);
    defer s.deinit();
    const dir = s.base;
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};

    writeInstallReceiptFull(io, dir, "pkg", version, "abc123", tap, true);

    const path = s.p("/INSTALL_RECEIPT.json");
    const f = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer f.close(io);
    const st = try f.stat(io);
    const bytes = try alloc.alloc(u8, @intCast(st.size));
    errdefer alloc.free(bytes);
    _ = try f.readPositionalAll(io, bytes, 0);
    return bytes;
}

test "install receipt with quoted tap and version stays valid JSON" {
    const testing = std.testing;
    const bytes = try writeReceiptAndRead(std.Options.debug_io, testing.allocator, "quoted", "ta\"p/\\core", "1\"0\\rc");
    defer testing.allocator.free(bytes);

    // The whole point: the receipt must re-parse despite quote/backslash bytes.
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bytes, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("ta\"p/\\core", parsed.value.object.get("source").?.object.get("tap").?.string);
    try testing.expectEqualStrings("1\"0\\rc", parsed.value.object.get("source").?.object.get("versions").?.object.get("stable").?.string);
}

test "install receipt escapes control chars in tap and version" {
    const testing = std.testing;
    const bytes = try writeReceiptAndRead(std.Options.debug_io, testing.allocator, "ctrl", "a\nb\tc", "v\x01w");
    defer testing.allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bytes, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("a\nb\tc", parsed.value.object.get("source").?.object.get("tap").?.string);
    try testing.expectEqualStrings("v\x01w", parsed.value.object.get("source").?.object.get("versions").?.object.get("stable").?.string);
}

test "install receipt with an over-long value degrades without crashing" {
    const testing = std.testing;
    // A tap longer than the escape scratch buffer overruns; the writer must
    // bail out gracefully (best-effort path) rather than panic or truncate mid-JSON.
    const long_tap = "a" ** 300;
    const bytes = try writeReceiptAndRead(std.Options.debug_io, testing.allocator, "overflow", long_tap, "1.0");
    defer testing.allocator.free(bytes);
    // Nothing was written; the empty receipt is the graceful degradation.
    try testing.expectEqual(@as(usize, 0), bytes.len);
}

test "remove refuses a keg path that leaves the Cellar" {
    const testing = std.testing;
    const io = std.Options.debug_io;

    var s = try Scratch.init("remove_escape");
    defer s.deinit();
    const prefix = s.p("/prefix");
    // The Cellar must exist or the kernel stops at the first missing
    // component and `..` never resolves — the escape would look benign.
    try std.Io.Dir.cwd().createDirPath(io, s.p("/prefix/Cellar"));

    // <prefix>/Cellar/../../victim — where an escaping name lands.
    const victim = s.p("/victim/keep");
    try std.Io.Dir.cwd().createDirPath(io, victim);

    // An empty version collapses the path to the whole package dir, so it is
    // barred alongside the traversal shapes.
    const escaping = [_][]const u8{ "../../victim", "a/b", ".", "..", "a\x00b", "" };
    for (escaping) |bad| {
        try testing.expectError(CellarError.UnsafePathComponent, remove(io, prefix, bad, "keep"));
        try testing.expectError(CellarError.UnsafePathComponent, remove(io, prefix, "foo", bad));
    }

    try std.Io.Dir.accessAbsolute(io, victim, .{});
}

test "the materialize sinks refuse a keg path that leaves the Cellar" {
    const testing = std.testing;
    const io = std.Options.debug_io;

    var s = try Scratch.init("materialize_escape");
    defer s.deinit();
    const prefix = s.p("/prefix");
    try std.Io.Dir.cwd().createDirPath(io, s.p("/prefix/Cellar"));

    const victim = s.p("/victim/keep");
    try std.Io.Dir.cwd().createDirPath(io, victim);

    // Both sinks build <prefix>/Cellar/<name>/<version> and wipe it on a
    // failed materialize, so an escaping component writes AND deletes outside.
    const escaping = [_][]const u8{ "../../victim", "a/b", ".", "..", "a\x00b" };
    for (escaping) |bad| {
        for ([_][2][]const u8{ .{ bad, "keep" }, .{ "foo", bad } }) |pair| {
            try testing.expectError(CellarError.UnsafePathComponent, materializeWithCellar(
                io,
                testing.allocator,
                prefix,
                "0" ** 64,
                pair[0],
                pair[1],
                "",
                null,
            ));
            try testing.expectError(CellarError.UnsafePathComponent, materializeFromLocalCellar(
                io,
                testing.allocator,
                prefix,
                s.p("/src"),
                pair[0],
                pair[1],
                "homebrew/core",
                "",
            ));
        }
    }

    // An empty name is still refused — it collapses the path to the Cellar root.
    try testing.expectError(CellarError.UnsafePathComponent, materializeWithCellar(
        io,
        testing.allocator,
        prefix,
        "0" ** 64,
        "",
        "1.0",
        "",
        null,
    ));

    try std.Io.Dir.accessAbsolute(io, victim, .{});
}

test "materialize tolerates the empty version a formula without versions.stable yields" {
    const testing = std.testing;
    const io = std.Options.debug_io;

    var s = try Scratch.init("materialize_empty_ver");
    defer s.deinit();
    const prefix = s.p("/prefix");
    try std.Io.Dir.cwd().createDirPath(io, s.p("/prefix/Cellar"));

    // `parseFormula` calls an absent `versions.stable` legitimate, so the
    // materialize sinks must not turn that into a refusal. They still fail
    // here — no store entry — just not as a confinement violation.
    try testing.expect(materializeWithCellar(
        io,
        testing.allocator,
        prefix,
        "0" ** 64,
        "foo",
        "",
        "",
        null,
    ) catch |e| e != CellarError.UnsafePathComponent);

    try testing.expect(materializeFromLocalCellar(
        io,
        testing.allocator,
        prefix,
        s.p("/src"),
        "foo",
        "",
        "homebrew/core",
        "",
    ) catch |e| e != CellarError.UnsafePathComponent);
}

test "remove deletes the keg it names" {
    const io = std.Options.debug_io;

    var s = try Scratch.init("remove_keg");
    defer s.deinit();
    const prefix = s.p("/prefix");
    const keg = s.p("/prefix/Cellar/openssl@3/3.2.1+dfsg/bin");
    try std.Io.Dir.cwd().createDirPath(io, keg);

    try remove(io, prefix, "openssl@3", "3.2.1+dfsg");

    const gone = s.p("/prefix/Cellar/openssl@3/3.2.1+dfsg");
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, gone, .{}));
}
