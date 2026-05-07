//! malt — Mach-O patcher
//! Path relocation in load commands and text file patching.

const std = @import("std");
const parser = @import("parser.zig");
const text_replace = @import("../text_replace.zig");

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
    /// "old" argument).
    old_path: []const u8,
    /// Replacement path the in-place patcher could not fit.
    new_path: []const u8,
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

    var patched: u32 = 0;
    var skipped: u32 = 0;

    for (macho.paths) |lcp| {
        const r = pickReplacement(lcp.path, replacements) orelse {
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
    for (entries) |e| switch (installNameToolForm(e.cmd)) {
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
    };
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

        // Read file
        const file = dir.openFile(io, entry.path, .{ .mode = .read_write }) catch continue;
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
            // Write back
            file.writePositionalAll(io, current, 0) catch continue;
            // Truncate if new content is shorter; trailing bytes are harmless if truncate fails
            // (Mach-O loader stops at size recorded in header, not file size).
            file.setLength(io, current.len) catch {};
            count += 1;
        }
    }

    return count;
}

fn hasPrefix(path: []const u8, prefix: []const u8) bool {
    if (path.len < prefix.len) return false;
    return std.mem.eql(u8, path[0..prefix.len], prefix);
}

const replaceAll = text_replace.replaceAll;
