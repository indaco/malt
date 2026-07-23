//! malt — Mach-O patcher
//! Path relocation in load commands and text file patching.

const std = @import("std");
const parser = @import("parser.zig");
const text_replace = @import("../text_replace.zig");
const atomic = @import("../fs/atomic.zig");

pub const PatchError = error{
    PathTooLong,
    OpenFailed,
    ParseFailed,
    IoError,
    OutOfMemory,
};

pub const PatchResult = struct {
    patched_count: u32,
    skipped_count: u32,
};

/// One load-command path that did not fit its slot. The caller flushes
/// these via the slow path (`flushOverflow` → `install_name_tool`).
/// Strings are caller-owned; release through `PatchOutcome.deinit`.
pub const OverflowEntry = struct {
    /// Raw load-command type (`@intFromEnum(LC.LOAD_DYLIB)` etc.).
    /// Drives the `-change` vs `-rpath` vs `-id` argv shape downstream.
    cmd: u32,
    /// Original path embedded in the slot (the `install_name_tool -change`
    /// "old" argument). For a delete entry, the rpath to strip.
    old_path: []const u8,
    /// Replacement path the in-place patcher could not fit. Empty for a
    /// delete entry (`-delete_rpath` takes no new path).
    new_path: []const u8,
    /// True when relocation folded this LC_RPATH onto an already-kept one:
    /// the slot keeps its original bytes and the fallback strips it via
    /// `-delete_rpath old_path` so dyld never sees a duplicate LC_RPATH.
    delete: bool = false,
};

pub const PatchOutcome = struct {
    patched_count: u32,
    skipped_count: u32,
    /// Slots that exceeded their cmd slot. Empty for the fast path.
    overflow: []OverflowEntry,

    pub fn deinit(self: *PatchOutcome, allocator: std.mem.Allocator) void {
        for (self.overflow) |e| {
            allocator.free(e.old_path);
            allocator.free(e.new_path);
        }
        allocator.free(self.overflow);
    }
};

/// Legacy single-replacement entry kept for callers that want the
/// all-or-nothing semantics. Bubbles `PathTooLong` if any slot does not
/// fit; new code should call `patchPathsCollecting` instead and flush
/// the overflow list via `flushOverflow`.
pub fn patchPaths(
    io: std.Io,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    old_prefix: []const u8,
    new_prefix: []const u8,
) PatchError!PatchResult {
    const reps = [_]Replacement{.{ .old = old_prefix, .new = new_prefix }};
    var outcome = try patchPathsCollecting(io, allocator, file_path, &reps);
    defer outcome.deinit(allocator);
    if (outcome.overflow.len > 0) return PatchError.PathTooLong;
    return .{ .patched_count = outcome.patched_count, .skipped_count = outcome.skipped_count };
}

/// Patch every load-command path that fits its slot in place; collect
/// any slot that overflowed into `overflow` for the caller to flush via
/// `install_name_tool`. A single Mach-O walk applies all replacements
/// (first match wins per load command), so the file is opened, read,
/// and rewritten at most once regardless of replacement count.
pub fn patchPathsCollecting(
    io: std.Io,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    replacements: []const Replacement,
) PatchError!PatchOutcome {
    const file = std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_write }) catch
        return PatchError.OpenFailed;
    defer file.close(io);

    const stat = file.stat(io) catch return PatchError.IoError;
    const data = allocator.alloc(u8, stat.size) catch return PatchError.OutOfMemory;
    defer allocator.free(data);

    const bytes_read = file.readPositionalAll(io, data, 0) catch return PatchError.IoError;
    if (bytes_read < data.len) return PatchError.IoError;

    var macho = parser.parse(allocator, data) catch return PatchError.ParseFailed;
    defer macho.deinit();

    // Each appended entry owns two heap strings; the outer errdefer hands
    // them back if a later allocation in the loop fails.
    var overflow: std.ArrayList(OverflowEntry) = .empty;
    errdefer {
        for (overflow.items) |e| {
            allocator.free(e.old_path);
            allocator.free(e.new_path);
        }
        overflow.deinit(allocator);
    }

    // Final (post-relocation) value of every LC_RPATH kept so far, tagged
    // with its arch slice so a fat binary's per-slice rpaths don't collide.
    // Scratch only — never returned; freed unconditionally below.
    const SeenRpath = struct { slice: usize, value: []const u8 };
    var seen_rpaths: std.ArrayList(SeenRpath) = .empty;
    defer {
        for (seen_rpaths.items) |v| allocator.free(v.value);
        seen_rpaths.deinit(allocator);
    }

    var patched: u32 = 0;
    var skipped: u32 = 0;

    for (macho.paths) |lcp| {
        const r_opt = pickReplacement(lcp.path, replacements);

        // dyld aborts on a duplicate LC_RPATH, and relocation can fold two
        // distinct prefixes onto one target. Keep the first occurrence of
        // each final value; queue any later collider for `-delete_rpath`.
        // Scoped to LC_RPATH — duplicate LC_LOAD_DYLIB is legal.
        if (lcp.cmd == @intFromEnum(std.macho.LC.RPATH)) {
            var final_buf: [1024]u8 = undefined;
            if (rpathFinalValue(&final_buf, lcp.path, r_opt)) |final| {
                var seen = false;
                for (seen_rpaths.items) |e| {
                    if (e.slice == lcp.slice_offset and std.mem.eql(u8, e.value, final)) {
                        seen = true;
                        break;
                    }
                }
                if (seen) {
                    // `-delete_rpath` is fat-wide by path, so a universal
                    // binary's per-slice colliders share one deletion.
                    if (!deleteQueued(overflow.items, lcp.path))
                        try recordDelete(allocator, &overflow, lcp);
                    continue;
                }
                const dup = allocator.dupe(u8, final) catch return PatchError.OutOfMemory;
                seen_rpaths.append(allocator, .{ .slice = lcp.slice_offset, .value = dup }) catch {
                    allocator.free(dup);
                    return PatchError.OutOfMemory;
                };
            }
            // A value past the scratch buffer can't fit any slot anyway;
            // fall through so normal handling drops it.
        }

        const r = r_opt orelse {
            skipped += 1;
            continue;
        };

        const suffix = lcp.path[r.old.len..];
        const new_path_len = r.new.len + suffix.len;

        // +1 budgets the NUL terminator so the slot keeps a trailing zero.
        if (new_path_len + 1 > lcp.max_path_len) {
            try recordOverflow(allocator, &overflow, lcp, r);
            continue;
        }

        const offset = lcp.path_offset;
        const end = std.math.add(usize, offset, lcp.max_path_len) catch {
            skipped += 1;
            continue;
        };
        if (end > data.len) {
            skipped += 1;
            continue;
        }

        // Stage the new path in a stack buffer first because `suffix`
        // aliases the same `data` we're about to overwrite.
        var new_path_buf: [1024]u8 = undefined;
        if (new_path_len > new_path_buf.len) {
            skipped += 1;
            continue;
        }
        @memcpy(new_path_buf[0..r.new.len], r.new);
        @memcpy(new_path_buf[r.new.len..new_path_len], suffix);

        @memcpy(data[offset .. offset + new_path_len], new_path_buf[0..new_path_len]);
        @memset(data[offset + new_path_len .. offset + lcp.max_path_len], 0);

        patched += 1;
    }

    for (macho.cstrings) |region| {
        const counts = patchCstringRegion(data, region, replacements);
        patched += counts.patched;
        skipped += counts.skipped;
    }

    if (patched > 0) {
        file.writePositionalAll(io, data, 0) catch return PatchError.IoError;
    }

    return .{
        .patched_count = patched,
        .skipped_count = skipped,
        .overflow = overflow.toOwnedSlice(allocator) catch return PatchError.OutOfMemory,
    };
}

fn pickReplacement(path: []const u8, replacements: []const Replacement) ?Replacement {
    for (replacements) |r| if (hasPrefix(path, r.old)) return r;
    return null;
}

const CstringPatchCounts = struct { patched: u32, skipped: u32 };

/// Rewrite NUL-terminated strings inside one `__cstring` region that
/// contain any configured old prefix — anywhere in the string, not just
/// at its head. In-place only — the section's file offset cannot grow
/// without rewriting every fixup in the binary, which
/// `install_name_tool` does not do for cstring data.
///
/// Each slot's original length (from its NUL terminator) becomes the
/// hard budget. When every occurrence shrinks or keeps its length, the
/// slot is rewritten and the freed tail zero-padded so no fragment of
/// the old path remains. A growing replacement can't fit and leaves the
/// slot byte-identical, counted as skipped — fundamental constraint,
/// not a recoverable error.
///
/// Pointer safety: clang+ld64 with the default `-fmerge-constants`
/// behaviour deduplicate identical strings but do not tail-merge
/// substrings, so every in-binary pointer references the head of its
/// string. Zero-padding the tail after the new NUL cannot break any
/// such pointer.
fn patchCstringRegion(
    data: []u8,
    region: parser.CstringRegion,
    replacements: []const Replacement,
) CstringPatchCounts {
    var counts: CstringPatchCounts = .{ .patched = 0, .skipped = 0 };

    const end = std.math.add(usize, region.file_offset, region.size) catch return counts;
    if (end > data.len) return counts;
    const blob = data[region.file_offset..end];

    var i: usize = 0;
    while (i < blob.len) {
        const nul = std.mem.indexOfScalarPos(u8, blob, i, 0) orelse break;
        if (nul != i) {
            switch (rewriteCstringSlot(blob[i..nul], replacements)) {
                .patched => counts.patched += 1,
                .skipped => counts.skipped += 1,
                .untouched => {},
            }
        }
        i = nul + 1;
    }

    return counts;
}

const SlotOutcome = enum { patched, skipped, untouched };

/// Rewrite every occurrence of any configured old prefix inside one
/// NUL-terminated slot, in place. Compiled-in fallback configs
/// (fontconfig's XML blob) embed the prefix mid-string, so matching is
/// per-occurrence, not head-anchored. Shrink-or-equal replacements let
/// the tail shift left (write index never passes read index); a growing
/// pair can't fit the fixed slot, so the pre-scan bails before any byte
/// is written — a slot is rewritten whole or left byte-identical.
fn rewriteCstringSlot(slot: []u8, replacements: []const Replacement) SlotOutcome {
    var scan: usize = 0;
    var found = false;
    while (scan < slot.len) {
        if (matchReplacementAt(slot, scan, replacements)) |r| {
            if (r.new.len > r.old.len) return .skipped;
            found = true;
            scan += r.old.len;
        } else {
            scan += 1;
        }
    }
    if (!found) return .untouched;

    var read: usize = 0;
    var write: usize = 0;
    while (read < slot.len) {
        if (matchReplacementAt(slot, read, replacements)) |r| {
            @memcpy(slot[write..][0..r.new.len], r.new);
            write += r.new.len;
            read += r.old.len;
        } else {
            slot[write] = slot[read];
            write += 1;
            read += 1;
        }
    }
    // Zero the freed tail up to the original NUL so no fragment of the
    // old path remains.
    @memset(slot[write..], 0);
    return .patched;
}

/// First configured replacement whose old prefix matches at `pos` —
/// same first-match-wins order as `pickReplacement`.
fn matchReplacementAt(
    slot: []const u8,
    pos: usize,
    replacements: []const Replacement,
) ?Replacement {
    for (replacements) |r| {
        if (r.old.len == 0) continue;
        if (pos + r.old.len <= slot.len and
            std.mem.eql(u8, slot[pos..][0..r.old.len], r.old)) return r;
    }
    return null;
}

/// Dupe both old/new strings into the caller's allocator and append.
/// On any allocation failure the partial duplicates are freed so the
/// list never observes a half-built entry; previously appended entries
/// remain owned by the list (the outer errdefer in
/// `patchPathsCollecting` releases them on a final failure).
fn recordOverflow(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(OverflowEntry),
    lcp: parser.LoadCommandPath,
    rep: Replacement,
) PatchError!void {
    const old_dup = allocator.dupe(u8, lcp.path) catch return PatchError.OutOfMemory;
    errdefer allocator.free(old_dup);
    const suffix = lcp.path[rep.old.len..];
    const new_dup = std.mem.concat(allocator, u8, &.{ rep.new, suffix }) catch
        return PatchError.OutOfMemory;
    errdefer allocator.free(new_dup);
    list.append(allocator, .{
        .cmd = lcp.cmd,
        .old_path = old_dup,
        .new_path = new_dup,
    }) catch return PatchError.OutOfMemory;
}

/// Post-relocation value of one rpath: the matched replacement applied, or
/// the original path when nothing matched. Returns null when the result
/// exceeds `buf` — such a path can't fit any slot, so the caller skips
/// dedup and lets normal handling drop it.
fn rpathFinalValue(buf: []u8, path: []const u8, r_opt: ?Replacement) ?[]const u8 {
    const r = r_opt orelse return path;
    const suffix = path[r.old.len..];
    const total = r.new.len + suffix.len;
    if (total > buf.len) return null;
    @memcpy(buf[0..r.new.len], r.new);
    @memcpy(buf[r.new.len..total], suffix);
    return buf[0..total];
}

fn deleteQueued(entries: []const OverflowEntry, old_path: []const u8) bool {
    for (entries) |e| if (e.delete and std.mem.eql(u8, e.old_path, old_path)) return true;
    return false;
}

/// Queue a collapsed LC_RPATH for removal. Deletes by the *original* path:
/// the kept duplicate was already rewritten to the shared target, so the two
/// stay distinct at flush time and `-delete_rpath` strips exactly this slot.
fn recordDelete(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(OverflowEntry),
    lcp: parser.LoadCommandPath,
) PatchError!void {
    const old_dup = allocator.dupe(u8, lcp.path) catch return PatchError.OutOfMemory;
    errdefer allocator.free(old_dup);
    list.append(allocator, .{
        .cmd = lcp.cmd,
        .old_path = old_dup,
        .new_path = "",
        .delete = true,
    }) catch return PatchError.OutOfMemory;
}

/// A single (needle → replacement) pair for `patchTextFiles`.
pub const Replacement = struct {
    old: []const u8,
    new: []const u8,
};

/// Errors surfaced by the `install_name_tool` fallback driver. The
/// generic fail / missing variants are subprocess plumbing problems;
/// `InsufficientHeaderPad` is the actionable user-facing one (rebuild
/// the bottle with `-headerpad_max_install_names`, or shorten
/// MALT_PREFIX).
pub const FallbackError = error{
    InstallNameToolMissing,
    InstallNameToolFailed,
    InsufficientHeaderPad,
    IoError,
    OutOfMemory,
};

/// Name of the platform tool that owns the slow-path slot growing.
/// `comptime` so the doctor check renders the right name without a
/// runtime branch; the future Linux backend swaps this for `"patchelf"`.
pub const external_tool_name: []const u8 = "install_name_tool";

/// Build the `install_name_tool` argv for one binary's overflow batch.
/// Caller owns the returned slice (`allocator.free`); the strings inside
/// are borrowed from the `entries` and `file_path` arguments.
pub fn buildInstallNameToolArgv(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    entries: []const OverflowEntry,
) std.mem.Allocator.Error![][]const u8 {
    // Worst case: one binary path plus three argv slots per entry.
    var argv: std.ArrayList([]const u8) = try .initCapacity(allocator, 1 + entries.len * 3 + 1);
    errdefer argv.deinit(allocator);

    argv.appendAssumeCapacity(external_tool_name);
    for (entries) |e| {
        if (e.delete) {
            // -delete_rpath <old> <file>: strip the collapsed duplicate.
            argv.appendAssumeCapacity("-delete_rpath");
            argv.appendAssumeCapacity(e.old_path);
            continue;
        }
        switch (installNameToolForm(e.cmd)) {
            .change => {
                argv.appendAssumeCapacity("-change");
                argv.appendAssumeCapacity(e.old_path);
                argv.appendAssumeCapacity(e.new_path);
            },
            .rpath => {
                argv.appendAssumeCapacity("-rpath");
                argv.appendAssumeCapacity(e.old_path);
                argv.appendAssumeCapacity(e.new_path);
            },
            .id => {
                // -id takes only the new install name; the old one is
                // implicit (LC_ID_DYLIB carries a single name).
                argv.appendAssumeCapacity("-id");
                argv.appendAssumeCapacity(e.new_path);
            },
        }
    }
    argv.appendAssumeCapacity(file_path);
    return argv.toOwnedSlice(allocator);
}

const InstallNameToolForm = enum { change, rpath, id };

fn installNameToolForm(cmd: u32) InstallNameToolForm {
    const lc = std.macho.LC;
    return switch (cmd) {
        @intFromEnum(lc.ID_DYLIB) => .id,
        @intFromEnum(lc.RPATH) => .rpath,
        // LOAD_DYLIB / LOAD_WEAK_DYLIB / LAZY_LOAD_DYLIB / REEXPORT_DYLIB
        // all use `-change`. Default to `-change` for any other dylib-ish
        // load command rather than refusing the flush.
        else => .change,
    };
}

/// Translate `install_name_tool`'s stderr into a structured fallback
/// error. Apple's wording for the headerpad-exhaustion case is stable
/// across Xcode releases and is the only one users have a remediation
/// for, so it gets its own variant; everything else collapses to a
/// generic failure that surfaces the raw stderr to the user upstream.
pub fn classifyInstallNameToolStderr(stderr: []const u8) FallbackError {
    if (std.mem.indexOf(u8, stderr, "larger updated load commands do not fit") != null)
        return FallbackError.InsufficientHeaderPad;
    if (std.mem.indexOf(u8, stderr, "no room for new load commands") != null)
        return FallbackError.InsufficientHeaderPad;
    return FallbackError.InstallNameToolFailed;
}

/// Flush one binary's overflow list via a single `install_name_tool`
/// invocation. All overflowing slots for the binary share one spawn so
/// cost scales with affected binaries, not load commands. A non-zero
/// exit is mapped through `classifyInstallNameToolStderr` so the
/// user-facing remediation is specific.
pub fn flushOverflow(
    io: std.Io,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    entries: []const OverflowEntry,
) FallbackError!void {
    if (entries.len == 0) return;

    const argv = buildInstallNameToolArgv(allocator, file_path, entries) catch
        return FallbackError.OutOfMemory;
    defer allocator.free(argv);

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdout = .ignore,
        .stderr = .pipe,
    }) catch |e| switch (e) {
        // `FileNotFound` is what `std.process.spawn` returns when the
        // binary is not on PATH — caller's doctor check should have
        // surfaced this already, but bottle installs may run before
        // doctor on a fresh box.
        error.FileNotFound => return FallbackError.InstallNameToolMissing,
        else => return FallbackError.IoError,
    };

    const stderr_file = child.stderr orelse return FallbackError.IoError;
    var read_buf: [4096]u8 = undefined;
    var reader = stderr_file.readerStreaming(io, &read_buf);
    const stderr_bytes = reader.interface.allocRemaining(allocator, std.Io.Limit.limited(64 * 1024)) catch
        return FallbackError.IoError;
    defer allocator.free(stderr_bytes);

    const term = child.wait(io) catch return FallbackError.InstallNameToolFailed;
    switch (term) {
        .exited => |code| {
            if (code != 0) return classifyInstallNameToolStderr(stderr_bytes);
        },
        else => return FallbackError.InstallNameToolFailed,
    }
}

/// Patch text files in a directory tree with a batch of replacements.
///
/// All replacements are applied to each file in a single read/write cycle.
/// The previous implementation required one full walk of the cellar per
/// replacement pair — `/opt/homebrew` and `/usr/local` each did their own
/// walk, and each walk ran the `@@HOMEBREW_PREFIX@@` / `@@HOMEBREW_CELLAR@@`
/// substitutions on every file. With the new API, `cellar.zig` passes all
/// four replacements in one call and each file is opened once.
pub fn patchTextFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    replacements: []const Replacement,
) !u32 {
    if (replacements.len == 0) return 0;

    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var count: u32 = 0;

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;

        // Read-only: the rewrite is published by the atomic helper, not
        // through this handle, so a 0o444 read-only config is still
        // patchable.
        const file = dir.openFile(io, entry.path, .{ .mode = .read_only }) catch continue;
        defer file.close(io);

        const stat = file.stat(io) catch continue;
        if (stat.size > 10 * 1024 * 1024) continue; // Skip files > 10MB
        if (stat.size == 0) continue;

        const content = allocator.alloc(u8, stat.size) catch continue;
        defer allocator.free(content);

        const bytes_read = file.readPositionalAll(io, content, 0) catch continue;
        if (bytes_read < content.len) continue;

        // Check if binary (null bytes in first 8KB)
        const check_len = @min(content.len, 8192);
        if (std.mem.findScalar(u8, content[0..check_len], 0) != null) continue;

        // Apply each replacement in sequence. `current` always points to
        // either `content` or a freshly allocated buffer from replaceAll;
        // when replaceAll returns a different pointer we free the previous
        // buffer (unless it was the immutable `content` slice).
        var current: []const u8 = content;
        var modified = false;
        var patch_failed = false;
        for (replacements) |r| {
            const next = replaceAll(allocator, current, r.old, r.new) catch {
                patch_failed = true;
                break;
            };
            if (next.ptr != current.ptr) {
                if (current.ptr != content.ptr) allocator.free(current);
                current = next;
                modified = true;
            }
        }
        if (patch_failed) {
            if (current.ptr != content.ptr) allocator.free(current);
            continue;
        }

        if (modified) {
            defer if (current.ptr != content.ptr) allocator.free(current);
            // Atomic rename keeps the file old-or-new on a mid-write
            // failure; `Replace` (not `Write`) also preserves the exec
            // bit on shebanged scripts and shell wrappers.
            var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
            const abs_path = std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ dir_path, entry.path }) catch continue;
            atomic.atomicReplaceFile(io, abs_path, current) catch continue;
            count += 1;
        }
    }

    return count;
}

fn hasPrefix(path: []const u8, prefix: []const u8) bool {
    if (path.len < prefix.len) return false;
    return std.mem.eql(u8, path[0..prefix.len], prefix);
}

/// Read-only probe: true iff `file_path` is a Mach-O that *links* a dylib
/// whose path contains `needle` (LC_LOAD_DYLIB and its weak/reexport
/// siblings). `LC_ID_DYLIB` (a dylib's own install name) and search-path
/// commands like `LC_RPATH` are excluded — only a hard link to the dylib
/// counts. Best-effort: an unreadable, non-Mach-O, or unparseable file
/// reads as "no". Opens read-only and never mutates.
pub fn fileLinksPath(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8, needle: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch return false;
    defer file.close(io);

    const stat = file.stat(io) catch return false;
    if (stat.size == 0) return false;
    const data = allocator.alloc(u8, stat.size) catch return false;
    defer allocator.free(data);
    const n = file.readPositionalAll(io, data, 0) catch return false;
    if (n < data.len) return false;

    if (!parser.isMachO(data)) return false;
    var macho = parser.parse(allocator, data) catch return false;
    defer macho.deinit();

    for (macho.paths) |p| {
        switch (p.cmd) {
            @intFromEnum(std.macho.LC.LOAD_DYLIB),
            @intFromEnum(std.macho.LC.LOAD_WEAK_DYLIB),
            @intFromEnum(std.macho.LC.REEXPORT_DYLIB),
            => if (std.mem.indexOf(u8, p.path, needle) != null) return true,
            else => {},
        }
    }
    return false;
}

const replaceAll = text_replace.replaceAll;

const fs_test_io = std.Options.debug_io;

var scratch_seq: std.atomic.Value(u32) = .init(0);

/// Stands in for std.testing.tmpDir, which builds under .zig-cache — a tree the
/// build system owns and rewrites underneath concurrent test runs. The base is
/// process- and call-unique so overlapping runs can't delete each other's
/// fixtures.
const Scratch = struct {
    arena: std.heap.ArenaAllocator,
    base: [:0]const u8,
    dir: std.Io.Dir,

    fn init(comptime tag: []const u8) !Scratch {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const raw = try std.fmt.allocPrintSentinel(
            arena.allocator(),
            "/tmp/malt_" ++ tag ++ "_{d}_{d}",
            .{ std.c.getpid(), scratch_seq.fetchAdd(1, .monotonic) },
            0,
        );
        std.Io.Dir.cwd().deleteTree(fs_test_io, raw) catch {};
        try std.Io.Dir.cwd().createDirPath(fs_test_io, raw);
        // /tmp is a symlink to /private/tmp on macOS; resolve once so paths the
        // code under test returns compare equal to `base`.
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        var d = try std.Io.Dir.cwd().openDir(fs_test_io, raw, .{});
        errdefer d.close(fs_test_io);
        const n = try std.Io.Dir.realPath(d, fs_test_io, &buf);
        const base = try arena.allocator().dupeZ(u8, buf[0..n]);
        return .{ .arena = arena, .base = base, .dir = d };
    }

    /// Absolute path to `sub` (leading slash included); valid until deinit.
    fn p(self: *Scratch, sub: []const u8) [:0]const u8 {
        return std.fmt.allocPrintSentinel(
            self.arena.allocator(),
            "{s}{s}",
            .{ self.base, sub },
            0,
        ) catch @panic("OOM");
    }

    fn deinit(self: *Scratch) void {
        self.dir.close(fs_test_io);
        std.Io.Dir.cwd().deleteTree(fs_test_io, self.base) catch {};
        self.arena.deinit();
    }
};

/// Minimal Mach-O 64 carrying two LC_RPATH load commands, each in its own
/// `cmdsize` slot. Mirrors the two-prefix rpath shape a fastfetch-style
/// bottle ships so the dedup walk can be exercised without a real binary.
fn buildTwoRpathMachO(
    allocator: std.mem.Allocator,
    path1: []const u8,
    cmdsize1: u32,
    path2: []const u8,
    cmdsize2: u32,
) ![]u8 {
    const macho = std.macho;
    const header_size = @sizeOf(macho.mach_header_64);
    const path_off: u32 = @sizeOf(macho.rpath_command);
    const buf = try allocator.alloc(u8, header_size + cmdsize1 + cmdsize2);
    @memset(buf, 0);

    const hdr = std.mem.bytesAsValue(macho.mach_header_64, buf[0..header_size]);
    hdr.* = .{ .magic = macho.MH_MAGIC_64, .ncmds = 2, .sizeofcmds = cmdsize1 + cmdsize2 };

    const off1 = header_size;
    const rp1 = std.mem.bytesAsValue(macho.rpath_command, buf[off1..][0..path_off]);
    rp1.* = .{ .cmd = .RPATH, .cmdsize = cmdsize1, .path = path_off };
    std.debug.assert(path1.len + 1 <= cmdsize1 - path_off);
    @memcpy(buf[off1 + path_off ..][0..path1.len], path1);

    const off2 = header_size + cmdsize1;
    const rp2 = std.mem.bytesAsValue(macho.rpath_command, buf[off2..][0..path_off]);
    rp2.* = .{ .cmd = .RPATH, .cmdsize = cmdsize2, .path = path_off };
    std.debug.assert(path2.len + 1 <= cmdsize2 - path_off);
    @memcpy(buf[off2 + path_off ..][0..path2.len], path2);

    return buf;
}

test "patchPathsCollecting dedups an LC_RPATH that relocation collapses onto a kept one" {
    const testing = std.testing;
    const io = std.Options.debug_io;

    // Both rpaths shrink to "/opt/malt/lib" — the fast in-place path fires.
    const bytes = try buildTwoRpathMachO(
        testing.allocator,
        "@@HOMEBREW_PREFIX@@/lib",
        40,
        "/usr/local/lib",
        32,
    );
    defer testing.allocator.free(bytes);

    var s = try Scratch.init("patcher_dedup");
    defer s.deinit();
    try s.dir.writeFile(io, .{ .sub_path = "bin", .data = bytes });
    const abs = s.p("/bin");

    // The four replacements relocateKegTree applies to a concrete-cellar bottle.
    const reps = [_]Replacement{
        .{ .old = "@@HOMEBREW_PREFIX@@", .new = "/opt/malt" },
        .{ .old = "@@HOMEBREW_CELLAR@@", .new = "/opt/malt/Cellar" },
        .{ .old = "/opt/homebrew", .new = "/opt/malt" },
        .{ .old = "/usr/local", .new = "/opt/malt" },
    };
    var outcome = try patchPathsCollecting(io, testing.allocator, abs, &reps);
    defer outcome.deinit(testing.allocator);

    // First rpath kept + rewritten in place; the colliding second is queued
    // for `-delete_rpath` by its original (pre-relocation) path.
    try testing.expectEqual(@as(u32, 1), outcome.patched_count);
    try testing.expectEqual(@as(usize, 1), outcome.overflow.len);
    try testing.expect(outcome.overflow[0].delete);
    try testing.expectEqual(@intFromEnum(std.macho.LC.RPATH), outcome.overflow[0].cmd);
    try testing.expectEqualStrings("/usr/local/lib", outcome.overflow[0].old_path);
}

test "patchPathsCollecting deletes a collider when the kept rpath needs no relocation" {
    const testing = std.testing;
    const io = std.Options.debug_io;

    // First rpath is already the target (no replacement matches it); the
    // second relocates onto it. Nothing is rewritten in place — the only
    // change is the deletion, which must still be reported.
    const bytes = try buildTwoRpathMachO(
        testing.allocator,
        "/opt/malt/lib",
        32,
        "/usr/local/lib",
        32,
    );
    defer testing.allocator.free(bytes);

    var s = try Scratch.init("patcher_delete_only");
    defer s.deinit();
    try s.dir.writeFile(io, .{ .sub_path = "bin", .data = bytes });
    const abs = s.p("/bin");

    const reps = [_]Replacement{.{ .old = "/usr/local", .new = "/opt/malt" }};
    var outcome = try patchPathsCollecting(io, testing.allocator, abs, &reps);
    defer outcome.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), outcome.patched_count);
    try testing.expectEqual(@as(usize, 1), outcome.overflow.len);
    try testing.expect(outcome.overflow[0].delete);
    try testing.expectEqualStrings("/usr/local/lib", outcome.overflow[0].old_path);
}

test "patchPathsCollecting keeps distinct rpaths when relocation does not collapse them" {
    const testing = std.testing;
    const io = std.Options.debug_io;

    // `:any` bottle: only placeholders are rewritten, so `/usr/local/lib`
    // stays distinct from the relocated `@@HOMEBREW_PREFIX@@/lib`.
    const bytes = try buildTwoRpathMachO(
        testing.allocator,
        "@@HOMEBREW_PREFIX@@/lib",
        40,
        "/usr/local/lib",
        32,
    );
    defer testing.allocator.free(bytes);

    var s = try Scratch.init("patcher_no_collide");
    defer s.deinit();
    try s.dir.writeFile(io, .{ .sub_path = "bin", .data = bytes });
    const abs = s.p("/bin");

    const reps = [_]Replacement{
        .{ .old = "@@HOMEBREW_PREFIX@@", .new = "/opt/malt" },
        .{ .old = "@@HOMEBREW_CELLAR@@", .new = "/opt/malt/Cellar" },
    };
    var outcome = try patchPathsCollecting(io, testing.allocator, abs, &reps);
    defer outcome.deinit(testing.allocator);

    // One rewrite, no deletion: the two rpaths remain byte-distinct.
    try testing.expectEqual(@as(u32, 1), outcome.patched_count);
    try testing.expectEqual(@as(usize, 0), outcome.overflow.len);
}

test "patchPathsCollecting never dedups duplicate LC_LOAD_DYLIB commands" {
    const testing = std.testing;
    const io = std.Options.debug_io;
    const macho = std.macho;

    // Two LC_LOAD_DYLIB slots that relocate to the same target. Duplicate
    // load-dylib commands are legal — dyld only aborts on duplicate rpaths,
    // so the dedup must leave these alone.
    const header_size = @sizeOf(macho.mach_header_64);
    const name_off: u32 = @sizeOf(macho.dylib_command);
    const cmdsize: u32 = 40;
    const buf = try testing.allocator.alloc(u8, header_size + cmdsize * 2);
    defer testing.allocator.free(buf);
    @memset(buf, 0);

    const hdr = std.mem.bytesAsValue(macho.mach_header_64, buf[0..header_size]);
    hdr.* = .{ .magic = macho.MH_MAGIC_64, .ncmds = 2, .sizeofcmds = cmdsize * 2 };
    inline for (.{ header_size, header_size + cmdsize }) |off| {
        const dy = std.mem.bytesAsValue(macho.dylib_command, buf[off..][0..name_off]);
        dy.* = .{
            .cmd = .LOAD_DYLIB,
            .cmdsize = cmdsize,
            .dylib = .{ .name = name_off, .timestamp = 0, .current_version = 0, .compatibility_version = 0 },
        };
        @memcpy(buf[off + name_off ..][0.."/usr/local/x".len], "/usr/local/x");
    }

    var s = try Scratch.init("patcher_dylib_dup");
    defer s.deinit();
    try s.dir.writeFile(io, .{ .sub_path = "bin", .data = buf });
    const abs = s.p("/bin");

    const reps = [_]Replacement{.{ .old = "/usr/local", .new = "/opt/malt" }};
    var outcome = try patchPathsCollecting(io, testing.allocator, abs, &reps);
    defer outcome.deinit(testing.allocator);

    // Both rewritten in place, nothing queued for deletion.
    try testing.expectEqual(@as(u32, 2), outcome.patched_count);
    try testing.expectEqual(@as(usize, 0), outcome.overflow.len);
}

test "fileLinksPath detects a needle in an LC_LOAD_DYLIB and ignores misses" {
    const testing = std.testing;
    const macho = std.macho;

    // Minimal Mach-O: header + one LC_LOAD_DYLIB naming an opt path.
    const lc_size = @sizeOf(macho.dylib_command);
    const path_str = "/opt/malt/opt/oniguruma/lib/libonig.5.dylib\x00";
    const name_offset: u32 = @intCast(lc_size);
    const cmdsize: u32 = @intCast(lc_size + path_str.len);
    const cmdsize_aligned: u32 = (cmdsize + 7) & ~@as(u32, 7);
    const header_size = @sizeOf(macho.mach_header_64);
    const total_len = header_size + cmdsize_aligned;

    const buf = try testing.allocator.alloc(u8, total_len);
    defer testing.allocator.free(buf);
    @memset(buf, 0);

    const header = std.mem.bytesAsValue(macho.mach_header_64, buf[0..header_size]);
    header.* = .{ .magic = macho.MH_MAGIC_64, .ncmds = 1, .sizeofcmds = cmdsize_aligned };
    const dy = std.mem.bytesAsValue(macho.dylib_command, buf[header_size..][0..lc_size]);
    dy.* = .{
        .cmd = .LOAD_DYLIB,
        .cmdsize = cmdsize_aligned,
        .dylib = .{ .name = name_offset, .timestamp = 0, .current_version = 0, .compatibility_version = 0 },
    };
    @memcpy(buf[header_size + lc_size ..][0..path_str.len], path_str);

    var s = try Scratch.init("patcher_links");
    defer s.deinit();
    const io = std.Options.debug_io;
    try s.dir.writeFile(io, .{ .sub_path = "dependent", .data = buf });

    const abs = s.p("/dependent");

    try testing.expect(fileLinksPath(io, testing.allocator, abs, "/opt/oniguruma/"));
    try testing.expect(!fileLinksPath(io, testing.allocator, abs, "/opt/missing/"));
}
