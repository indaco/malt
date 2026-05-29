//! malt — DSL path sandboxing
//! Validates that filesystem-mutating operations stay within allowed boundaries.

const std = @import("std");
const macos = @import("../sandbox/macos.zig");

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

/// Gate `system()`'s argv0 the way `validatePath` gates FS writes, so a
/// fake sandbox can isolate all four DSL builtins instead of three. Bare
/// command names defer to the scrubbed PATH; absolute paths must live
/// under the formula's keg/prefix or the same system dirs the macOS
/// fence exposes.
pub fn validateArgv(
    argv: []const []const u8,
    cellar_path: []const u8,
    malt_prefix: []const u8,
) SandboxError!void {
    if (argv.len == 0) return;
    const argv0 = argv[0];

    if (containsDotDot(argv0)) return SandboxError.PathSandboxViolation;

    // Bare command name (no separator) resolves through the scrubbed PATH.
    if (std.mem.indexOfScalar(u8, argv0, '/') == null) return;

    // Anything with a separator must be an absolute path under an allowed root.
    if (argv0[0] != '/') return SandboxError.PathSandboxViolation;
    if (pathHasPrefix(argv0, cellar_path)) return;
    if (pathHasPrefix(argv0, malt_prefix)) return;
    if (underSandboxPathDir(argv0)) return;

    return SandboxError.PathSandboxViolation;
}

/// True iff `argv0` lives under one of the system dirs in the macOS
/// fence's scrubbed PATH; keeps the DSL allowlist a function of that
/// list rather than a second copy.
fn underSandboxPathDir(argv0: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, macos.sandbox_path, ':');
    while (it.next()) |dir| {
        if (pathHasPrefix(argv0, dir)) return true;
    }
    return false;
}

/// Resolve a path to its canonical form (resolving symlinks)
/// and then validate it.
pub fn validateResolved(
    io: std.Io,
    target_path: []const u8,
    cellar_path: []const u8,
    malt_prefix: []const u8,
) SandboxError!void {
    // First validate the literal path
    try validatePath(target_path, cellar_path, malt_prefix);

    // Try to resolve symlinks. If the path doesn't exist yet,
    // that's fine — just validate the literal path.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.cwd().realPathFile(io, target_path, &buf) catch {
        return; // Path doesn't exist yet — literal validation passed
    };
    const resolved = buf[0..n];

    // Re-validate the resolved path with the same boundary rules.
    if (containsDotDot(resolved)) return SandboxError.PathSandboxViolation;
    if (!pathHasPrefix(resolved, cellar_path) and
        !pathHasPrefix(resolved, malt_prefix))
    {
        return SandboxError.PathSandboxViolation;
    }
}

test "validateArgv accepts bare command names" {
    try validateArgv(&.{"make"}, "/opt/malt/Cellar/foo/1.0", "/opt/malt");
    try validateArgv(&.{ "fc-cache", "-f" }, "/opt/malt/Cellar/foo/1.0", "/opt/malt");
}

test "validateArgv accepts absolute paths under system dirs and the prefix" {
    const cellar = "/opt/malt/Cellar/foo/1.0";
    try validateArgv(&.{"/usr/bin/true"}, cellar, "/opt/malt");
    try validateArgv(&.{"/bin/ls"}, cellar, "/opt/malt");
    try validateArgv(&.{"/opt/malt/opt/foo/bin/tool"}, cellar, "/opt/malt");
    try validateArgv(&.{cellar ++ "/bin/tool"}, cellar, "/opt/malt");
}

test "validateArgv rejects absolute paths outside allowed roots" {
    try std.testing.expectError(
        SandboxError.PathSandboxViolation,
        validateArgv(&.{"/Users/me/evil"}, "/opt/malt/Cellar/foo/1.0", "/opt/malt"),
    );
}

test "validateArgv rejects traversal and relative paths with separators" {
    const cellar = "/opt/malt/Cellar/foo/1.0";
    try std.testing.expectError(
        SandboxError.PathSandboxViolation,
        validateArgv(&.{"../../bin/evil"}, cellar, "/opt/malt"),
    );
    try std.testing.expectError(
        SandboxError.PathSandboxViolation,
        validateArgv(&.{"./evil"}, cellar, "/opt/malt"),
    );
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
pub fn pathHasPrefix(path: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0) return false;
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    if (path.len == prefix.len) return true;
    // prefix already ends in '/' (e.g. "/opt/malt/") — boundary already covered.
    if (prefix[prefix.len - 1] == '/') return true;
    // Next char in path must be the separator; otherwise it's a substring,
    // not a path-component prefix.
    return path[prefix.len] == '/';
}
