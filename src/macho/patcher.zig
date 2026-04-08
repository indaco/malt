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

/// Patch text files in a directory tree.
/// Replaces old_prefix and @@HOMEBREW_PREFIX@@/@@HOMEBREW_CELLAR@@ placeholders.
pub fn patchTextFiles(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    old_prefix: []const u8,
    new_prefix: []const u8,
) !u32 {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    // Build cellar replacement
    var cellar_buf: [256]u8 = undefined;
    const new_cellar = std.fmt.bufPrint(&cellar_buf, "{s}/Cellar", .{new_prefix}) catch return 0;

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

        // Perform replacements
        var modified = false;
        const result = replaceAll(allocator, content, "@@HOMEBREW_PREFIX@@", new_prefix) catch continue;

        if (result.ptr != content.ptr) modified = true;

        const result2 = replaceAll(allocator, result, "@@HOMEBREW_CELLAR@@", new_cellar) catch {
            if (modified) allocator.free(result);
            continue;
        };
        if (result2.ptr != result.ptr) {
            if (result.ptr != content.ptr) allocator.free(result);
            modified = true;
        }

        const result3 = replaceAll(allocator, result2, old_prefix, new_prefix) catch {
            if (result2.ptr != content.ptr) allocator.free(result2);
            continue;
        };
        if (result3.ptr != result2.ptr) {
            if (result2.ptr != content.ptr) allocator.free(result2);
            modified = true;
        }

        if (modified) {
            defer if (result3.ptr != content.ptr) allocator.free(result3);
            // Write back
            file.seekTo(0) catch continue;
            file.writeAll(result3) catch continue;
            // Truncate if new content is shorter
            file.setEndPos(result3.len) catch {};
            count += 1;
        } else {
            if (result3.ptr != content.ptr) allocator.free(result3);
        }
    }

    return count;
}

fn hasPrefix(path: []const u8, prefix: []const u8) bool {
    if (path.len < prefix.len) return false;
    return std.mem.eql(u8, path[0..prefix.len], prefix);
}

/// Replace all occurrences of needle with replacement in haystack.
/// Returns the original slice if no changes, or a new allocation if changes were made.
fn replaceAll(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    if (needle.len == 0) return haystack;

    // Count occurrences
    var occ_count: usize = 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) {
            occ_count += 1;
            i += needle.len;
        } else {
            i += 1;
        }
    }

    if (occ_count == 0) return haystack;

    // Build result
    const new_len = haystack.len - (occ_count * needle.len) + (occ_count * replacement.len);
    const buf = try allocator.alloc(u8, new_len);

    var src: usize = 0;
    var dst: usize = 0;
    while (src + needle.len <= haystack.len) {
        if (std.mem.eql(u8, haystack[src .. src + needle.len], needle)) {
            @memcpy(buf[dst .. dst + replacement.len], replacement);
            dst += replacement.len;
            src += needle.len;
        } else {
            buf[dst] = haystack[src];
            dst += 1;
            src += 1;
        }
    }
    // Copy remaining bytes
    while (src < haystack.len) {
        buf[dst] = haystack[src];
        dst += 1;
        src += 1;
    }

    return buf;
}
