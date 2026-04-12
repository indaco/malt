//! malt — DSL path sandboxing
//! Validates that filesystem-mutating operations stay within allowed boundaries.

const std = @import("std");

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

    // Check allowed prefixes
    if (std.mem.startsWith(u8, target_path, cellar_path)) return;
    if (std.mem.startsWith(u8, target_path, malt_prefix)) return;

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
    const resolved = std.fs.cwd().realpath(target_path, &buf) catch {
        return; // Path doesn't exist yet — literal validation passed
    };

    // Re-validate the resolved path
    if (containsDotDot(resolved)) return SandboxError.PathSandboxViolation;
    if (!std.mem.startsWith(u8, resolved, cellar_path) and
        !std.mem.startsWith(u8, resolved, malt_prefix))
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
