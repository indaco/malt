//! malt — DSL path sandboxing
//! Validates that filesystem-mutating operations stay within allowed boundaries.

const std = @import("std");
const builtin = @import("builtin");
const macos = @import("../sandbox/macos.zig");

pub const SandboxError = error{PathSandboxViolation};

/// `fenceArgv` either rejects (unsafe profile path) or allocates the wrapper.
pub const FenceError = error{ PathSandboxViolation, OutOfMemory };

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

/// Wrap `argv` so the spawn runs under the same real `sandbox-exec` write
/// fence the `--use-system-ruby` path gets — `validateArgv` is only a lint
/// (it waves bare/system-dir argv0 through), so the OS fence is what actually
/// stops a destructive write the formula's *arguments* aim outside the keg.
///
/// Returns `argv` unchanged off macOS (no `sandbox-exec` there) so the
/// builtin stays portable; on macOS returns a fresh argv prefixed with
/// `/usr/bin/sandbox-exec -p <profile>`. The profile and wrapper live on
/// `allocator` (the per-formula arena). An unsafe cellar/prefix path fails
/// closed as a sandbox violation rather than spawning unconfined.
pub fn fenceArgv(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cellar_path: []const u8,
    malt_prefix: []const u8,
) FenceError![]const []const u8 {
    if (builtin.os.tag != .macos or argv.len == 0) return argv;

    const profile = macos.renderRubyProfile(allocator, cellar_path, malt_prefix) catch |e| switch (e) {
        // The renderer only allocates and validates: an alloc miss is OOM,
        // anything else (unsafe path) means we can't confine — fail closed.
        error.ProfileBuildFailed => return FenceError.OutOfMemory,
        else => return FenceError.PathSandboxViolation,
    };

    const wrapped = try allocator.alloc([]const u8, argv.len + 3);
    wrapped[0] = "/usr/bin/sandbox-exec";
    wrapped[1] = "-p";
    wrapped[2] = profile;
    @memcpy(wrapped[3..], argv);
    return wrapped;
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

test "fenceArgv wraps argv under sandbox-exec with the keg/prefix profile" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const wrapped = try fenceArgv(arena.allocator(), &.{ "make", "install" }, "/opt/malt/Cellar/foo/1.0", "/opt/malt");
    try std.testing.expectEqualStrings("/usr/bin/sandbox-exec", wrapped[0]);
    try std.testing.expectEqualStrings("-p", wrapped[1]);
    try std.testing.expect(std.mem.indexOf(u8, wrapped[2], "(deny default)") != null);
    // Original argv preserved in order after the wrapper prefix.
    try std.testing.expectEqualStrings("make", wrapped[3]);
    try std.testing.expectEqualStrings("install", wrapped[4]);
    try std.testing.expectEqual(@as(usize, 5), wrapped.len);
}

test "fenceArgv leaves empty argv untouched" {
    const empty: []const []const u8 = &.{};
    const out = try fenceArgv(std.testing.allocator, empty, "/opt/malt/Cellar/foo/1.0", "/opt/malt");
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "fenceArgv fails closed when the profile path is unsafe" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // An SCL-metachar in the cellar can't render a safe profile — reject the
    // spawn rather than running it unconfined.
    try std.testing.expectError(
        FenceError.PathSandboxViolation,
        fenceArgv(arena.allocator(), &.{"make"}, "/opt/malt\"/evil", "/opt/malt"),
    );
}

test "fenceArgv maps a profile allocation failure to OutOfMemory" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // Clean paths pass validation, so the only failure left is the profile
    // allocation — it must surface as OutOfMemory, not a sandbox violation.
    try std.testing.expectError(
        FenceError.OutOfMemory,
        fenceArgv(std.testing.failing_allocator, &.{"make"}, "/opt/malt/Cellar/foo/1.0", "/opt/malt"),
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
