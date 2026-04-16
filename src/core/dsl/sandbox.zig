//! malt — DSL path sandboxing
//! Validates that filesystem-mutating operations stay within allowed boundaries.

const std = @import("std");
const fs_compat = @import("../../fs/compat.zig");

pub const SandboxError = error{PathSandboxViolation};

/// Validate that `target_path` is within allowed boundaries.
/// Allowed prefixes:
///   - cellar_path (the formula's own keg)
///   - malt_prefix (for shared directories like etc, var, share)
///
/// Rejects:
///   - Paths containing ".." after normalization
///   - Absolute paths not under allowed prefixes
pub fn validatePath(
    target_path: []const u8,
    cellar_path: []const u8,
    malt_prefix: []const u8,
) SandboxError!void {
    // Reject paths containing ".." components
    if (containsDotDot(target_path)) return SandboxError.PathSandboxViolation;

    // Must be absolute
    if (target_path.len == 0 or target_path[0] != '/') {
        return SandboxError.PathSandboxViolation;
    }

    // Check allowed prefixes with a proper path-component boundary so that
    // `/opt/malt/Cellar/foo/1.0evil` is not accepted as a prefix match of
    // `/opt/malt/Cellar/foo/1.0`.
    if (pathHasPrefix(target_path, cellar_path)) return;
    if (pathHasPrefix(target_path, malt_prefix)) return;

    return SandboxError.PathSandboxViolation;
}

/// Resolve a path to its canonical form (resolving symlinks)
/// and then validate it.
pub fn validateResolved(
    target_path: []const u8,
    cellar_path: []const u8,
    malt_prefix: []const u8,
) SandboxError!void {
    // First validate the literal path
    try validatePath(target_path, cellar_path, malt_prefix);

    // Try to resolve symlinks. If the path doesn't exist yet,
    // that's fine — just validate the literal path.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = fs_compat.cwd().realpath(target_path, &buf) catch {
        return; // Path doesn't exist yet — literal validation passed
    };

    // Re-validate the resolved path with the same boundary rules.
    if (containsDotDot(resolved)) return SandboxError.PathSandboxViolation;
    if (!pathHasPrefix(resolved, cellar_path) and
        !pathHasPrefix(resolved, malt_prefix))
    {
        return SandboxError.PathSandboxViolation;
    }
}

fn containsDotDot(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return true;
    }
    return false;
}

/// Return true iff `path` is equal to `prefix` or extends it along a
/// path-component boundary. Guards against substring matches such as
/// `prefix="/opt/malt"` vs `path="/opt/malthack"` where a plain
/// `std.mem.startsWith` would incorrectly return true.
fn pathHasPrefix(path: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0) return false;
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    if (path.len == prefix.len) return true;
    // prefix already ends in '/' (e.g. "/opt/malt/") — boundary already covered.
    if (prefix[prefix.len - 1] == '/') return true;
    // Next char in path must be the separator; otherwise it's a substring,
    // not a path-component prefix.
    return path[prefix.len] == '/';
}
