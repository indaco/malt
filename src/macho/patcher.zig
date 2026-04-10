//! malt — Mach-O patcher
//! Path relocation in load commands and text file patching.

const std = @import("std");
const parser = @import("parser.zig");

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

/// Patch all Mach-O load command paths in a binary file.
/// Replaces occurrences of old_prefix with new_prefix, null-padding to maintain size.
/// The binary is modified in-place (read, modify, write back).
pub fn patchPaths(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    old_prefix: []const u8,
    new_prefix: []const u8,
) PatchError!PatchResult {
    // Read the entire file
    const file = std.fs.cwd().openFile(file_path, .{ .mode = .read_write }) catch
        return PatchError.OpenFailed;
    defer file.close();

    const stat = file.stat() catch return PatchError.IoError;
    const data = allocator.alloc(u8, stat.size) catch return PatchError.OutOfMemory;
    defer allocator.free(data);

    const bytes_read = file.readAll(data) catch return PatchError.IoError;
    if (bytes_read < data.len) return PatchError.IoError;

    // Parse Mach-O to find load command paths
    var macho = parser.parse(allocator, data) catch return PatchError.ParseFailed;
    defer macho.deinit();

    var patched: u32 = 0;
    var skipped: u32 = 0;

    for (macho.paths) |lcp| {
        // Check if path contains old_prefix
        if (!hasPrefix(lcp.path, old_prefix)) {
            skipped += 1;
            continue;
        }

        // Build replacement path
        const suffix = lcp.path[old_prefix.len..];
        const new_path_len = new_prefix.len + suffix.len;

        // PATH LENGTH GUARD (CRITICAL)
        if (new_path_len >= lcp.max_path_len) {
            return PatchError.PathTooLong;
        }

        // Write replacement at the offset
        const offset = lcp.path_offset;
        if (offset + lcp.max_path_len > data.len) {
            skipped += 1;
            continue;
        }

        // Build the new path in a temp buffer to avoid aliasing issues
        // (suffix points into data which we're about to overwrite)
        var new_path_buf: [1024]u8 = undefined;
        if (new_path_len > new_path_buf.len) {
            skipped += 1;
            continue;
        }
        @memcpy(new_path_buf[0..new_prefix.len], new_prefix);
        @memcpy(new_path_buf[new_prefix.len..new_path_len], suffix);

        // Write replacement + null padding
        @memcpy(data[offset .. offset + new_path_len], new_path_buf[0..new_path_len]);
        @memset(data[offset + new_path_len .. offset + lcp.max_path_len], 0);

        patched += 1;
    }

    if (patched > 0) {
        // Write modified data back to file
        file.seekTo(0) catch return PatchError.IoError;
        file.writeAll(data) catch return PatchError.IoError;
    }

    return .{ .patched_count = patched, .skipped_count = skipped };
}

/// A single (needle → replacement) pair for `patchTextFiles`.
pub const Replacement = struct {
    old: []const u8,
    new: []const u8,
};

/// Patch text files in a directory tree with a batch of replacements.
///
/// All replacements are applied to each file in a single read/write cycle.
/// The previous implementation required one full walk of the cellar per
/// replacement pair — `/opt/homebrew` and `/usr/local` each did their own
/// walk, and each walk ran the `@@HOMEBREW_PREFIX@@` / `@@HOMEBREW_CELLAR@@`
/// substitutions on every file. With the new API, `cellar.zig` passes all
/// four replacements in one call and each file is opened once.
pub fn patchTextFiles(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    replacements: []const Replacement,
) !u32 {
    if (replacements.len == 0) return 0;

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var count: u32 = 0;

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        // Read file
        const file = dir.openFile(entry.path, .{ .mode = .read_write }) catch continue;
        defer file.close();

        const stat = file.stat() catch continue;
        if (stat.size > 10 * 1024 * 1024) continue; // Skip files > 10MB
        if (stat.size == 0) continue;

        const content = allocator.alloc(u8, stat.size) catch continue;
        defer allocator.free(content);

        const bytes_read = file.readAll(content) catch continue;
        if (bytes_read < content.len) continue;

        // Check if binary (null bytes in first 8KB)
        const check_len = @min(content.len, 8192);
        if (std.mem.indexOfScalar(u8, content[0..check_len], 0) != null) continue;

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
            file.seekTo(0) catch continue;
            file.writeAll(current) catch continue;
            // Truncate if new content is shorter
            file.setEndPos(current.len) catch {};
            count += 1;
        }
    }

    return count;
}

fn hasPrefix(path: []const u8, prefix: []const u8) bool {
    if (path.len < prefix.len) return false;
    return std.mem.eql(u8, path[0..prefix.len], prefix);
}

/// Replace all occurrences of `needle` with `replacement` in `haystack`.
/// Returns the original slice (same pointer) if there were no matches, or
/// a caller-owned allocation with the substitution applied. Uses
/// `std.mem.indexOfPos` which is memchr-based and significantly faster
/// than a naive byte-by-byte `mem.eql` loop for small needles — the old
/// implementation showed up as ~60 samples on `mem.eqlBytes` in the
/// warm-ffmpeg profile.
fn replaceAll(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    if (needle.len == 0) return haystack;

    // Fast path: no matches at all → return the original slice unchanged.
    const first = std.mem.indexOf(u8, haystack, needle) orelse return haystack;

    // Count the remaining matches so we can preallocate exactly.
    // (indexOfPos is O(n) per call; the total work is one linear pass.)
    var match_count: usize = 1;
    var probe = first + needle.len;
    while (std.mem.indexOfPos(u8, haystack, probe, needle)) |p| {
        match_count += 1;
        probe = p + needle.len;
    }

    const rep_len = replacement.len;
    const ndl_len = needle.len;
    const new_len = haystack.len + match_count * rep_len - match_count * ndl_len;
    const buf = try allocator.alloc(u8, new_len);
    errdefer allocator.free(buf);

    // Second pass: copy segments between matches and write the replacement
    // at each match position. Uses indexOfPos for the fast scan.
    var src: usize = 0;
    var dst: usize = 0;
    var match = first;
    while (true) {
        // Copy the segment leading up to `match`.
        const segment_len = match - src;
        if (segment_len > 0) {
            @memcpy(buf[dst .. dst + segment_len], haystack[src..match]);
            dst += segment_len;
        }
        // Emit replacement.
        @memcpy(buf[dst .. dst + rep_len], replacement);
        dst += rep_len;
        src = match + ndl_len;

        match = std.mem.indexOfPos(u8, haystack, src, needle) orelse break;
    }

    // Tail: everything after the last match.
    if (src < haystack.len) {
        @memcpy(buf[dst .. dst + (haystack.len - src)], haystack[src..]);
        dst += haystack.len - src;
    }

    std.debug.assert(dst == new_len);
    return buf;
}
