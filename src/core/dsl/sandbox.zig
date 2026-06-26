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

/// Resolve `path` to its canonical form, or return `fallback` when it can't be
/// resolved (e.g. it doesn't exist). Used to compare against the *resolved*
/// keg/prefix so a legitimately symlinked root (macOS `/tmp` → `/private/tmp`)
/// is not mistaken for an escape.
fn realPathOr(io: std.Io, path: []const u8, buf: []u8, fallback: []const u8) []const u8 {
    const n = std.Io.Dir.cwd().realPathFile(io, path, buf) catch return fallback;
    return buf[0..n];
}

/// Validate a create/copy write target: the literal `validatePath` checks plus a
/// resolved-boundary check on the nearest existing ancestor *directory*. This
/// closes the intermediate-directory symlink escape (`ln_s "/etc", keg/d` then a
/// write under `keg/d/...`). A final-component symlink is deliberately left to
/// the open — an atomic copy replaces it, and `openWriteTargetNoFollow` refuses
/// it via `O_NOFOLLOW`. A target whose parents don't exist yet can't escape (the
/// open just fails), so a resolve miss up to the root is allowed.
pub fn validateWriteDir(
    io: std.Io,
    target_path: []const u8,
    cellar_path: []const u8,
    malt_prefix: []const u8,
) SandboxError!void {
    try validatePath(target_path, cellar_path, malt_prefix);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var probe: []const u8 = target_path;
    const dir_real = while (std.fs.path.dirname(probe)) |parent| {
        const n = std.Io.Dir.cwd().realPathFile(io, parent, &buf) catch {
            probe = parent;
            continue;
        };
        break buf[0..n];
    } else return;

    if (containsDotDot(dir_real)) return SandboxError.PathSandboxViolation;

    var cbuf: [std.fs.max_path_bytes]u8 = undefined;
    var xbuf: [std.fs.max_path_bytes]u8 = undefined;
    const cellar_real = realPathOr(io, cellar_path, &cbuf, cellar_path);
    const prefix_real = realPathOr(io, malt_prefix, &xbuf, malt_prefix);

    if (pathHasPrefix(dir_real, cellar_real)) return;
    if (pathHasPrefix(dir_real, prefix_real)) return;
    return SandboxError.PathSandboxViolation;
}

/// Open a create/truncate write target without following a final-component
/// symlink, after `validateWriteDir` confirms the containing directory stays in
/// the keg/prefix. `O_NOFOLLOW` makes the refusal atomic at the kernel (no
/// lstat→open race); both an out-of-keg directory and a symlinked leaf map to
/// `PathSandboxViolation`. Other open failures surface as `OpenError` so callers
/// keep their swallow-on-IO contract.
pub fn openWriteTargetNoFollow(
    io: std.Io,
    target_path: []const u8,
    cellar_path: []const u8,
    malt_prefix: []const u8,
) (SandboxError || std.posix.OpenError)!std.Io.File {
    try validateWriteDir(io, target_path, cellar_path, malt_prefix);
    const fd = std.posix.openat(std.posix.AT.FDCWD, target_path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
        .NOFOLLOW = true,
    }, 0o644) catch |e| switch (e) {
        // O_NOFOLLOW yields ELOOP (SymLinkLoop) when the leaf is a symlink.
        error.SymLinkLoop => return SandboxError.PathSandboxViolation,
        else => return e,
    };
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
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

test "openWriteTargetNoFollow writes a normal in-keg file" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var bb: [std.fs.max_path_bytes]u8 = undefined;
    // Resolved root exercises the /tmp → /private/tmp case: a symlinked prefix
    // must not read as an escape.
    const keg = bb[0..try std.Io.Dir.realPath(tmp.dir, io, &bb)];

    const target = try std.fs.path.join(alloc, &.{ keg, "out.txt" });
    defer alloc.free(target);

    const f = try openWriteTargetNoFollow(io, target, keg, keg);
    {
        defer f.close(io);
        try f.writeStreamingAll(io, "ok");
    }
    var rb: [8]u8 = undefined;
    const rf = try std.Io.Dir.openFileAbsolute(io, target, .{});
    defer rf.close(io);
    try std.testing.expectEqualStrings("ok", rb[0..try rf.readPositionalAll(io, &rb, 0)]);
}

test "openWriteTargetNoFollow refuses a final-component symlink out of the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var bb: [std.fs.max_path_bytes]u8 = undefined;
    const base = bb[0..try std.Io.Dir.realPath(tmp.dir, io, &bb)];

    const keg = try std.fs.path.join(alloc, &.{ base, "keg" });
    defer alloc.free(keg);
    const victim = try std.fs.path.join(alloc, &.{ base, "victim" });
    defer alloc.free(victim);
    const link = try std.fs.path.join(alloc, &.{ keg, "pwn" });
    defer alloc.free(link);

    try std.Io.Dir.cwd().createDirPath(io, keg);
    {
        const vf = try std.Io.Dir.createFileAbsolute(io, victim, .{});
        defer vf.close(io);
        try vf.writeStreamingAll(io, "PRECIOUS");
    }
    try std.Io.Dir.symLinkAbsolute(io, victim, link, .{});

    try std.testing.expectError(
        SandboxError.PathSandboxViolation,
        openWriteTargetNoFollow(io, link, keg, base),
    );

    var rb: [16]u8 = undefined;
    const vf = try std.Io.Dir.openFileAbsolute(io, victim, .{});
    defer vf.close(io);
    try std.testing.expectEqualStrings("PRECIOUS", rb[0..try vf.readPositionalAll(io, &rb, 0)]);
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
