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
    opts: macos.ProfileOpts,
) FenceError![]const []const u8 {
    if (builtin.os.tag != .macos or argv.len == 0) return argv;

    const profile = macos.renderRubyProfile(allocator, cellar_path, malt_prefix, opts) catch |e| switch (e) {
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

/// Resolve the nearest existing directory at or above `start` and require it to
/// stay within the *resolved* keg/prefix. `start == null` (root reached) or a
/// fully unresolvable chain means nothing exists yet to escape through, so it
/// passes — the subsequent open/copy simply fails if the path is unusable.
fn resolvedDirWithinBoundary(
    io: std.Io,
    start: ?[]const u8,
    cellar_path: []const u8,
    malt_prefix: []const u8,
) SandboxError!void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var probe: ?[]const u8 = start;
    const dir_real = while (probe) |p| {
        // Stop once the walk leaves the literal keg/prefix: nothing inside the
        // boundary exists yet, so there is no symlink there to redirect us, and
        // an existing ancestor *above* the boundary (e.g. `/opt`) is not ours to
        // judge. `validatePath` already confirmed the target itself is in bounds.
        if (!pathHasPrefix(p, cellar_path) and !pathHasPrefix(p, malt_prefix)) return;
        const n = std.Io.Dir.cwd().realPathFile(io, p, &buf) catch {
            probe = std.fs.path.dirname(p);
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

/// Validate a write target whose final component is a *file*: the literal
/// `validatePath` checks plus a resolved-boundary check on its parent directory.
/// This closes the intermediate-directory symlink escape (`ln_s "/etc", keg/d`
/// then a write under `keg/d/...`). The final component itself is left to the
/// open — an atomic copy replaces it, and `openTargetNoFollow` refuses it via
/// `O_NOFOLLOW` — so a legitimate in-keg symlink leaf is not falsely rejected
/// here.
pub fn validateWriteDir(
    io: std.Io,
    target_path: []const u8,
    cellar_path: []const u8,
    malt_prefix: []const u8,
) SandboxError!void {
    try validatePath(target_path, cellar_path, malt_prefix);
    try resolvedDirWithinBoundary(io, std.fs.path.dirname(target_path), cellar_path, malt_prefix);
}

/// Validate a *directory* that will be written into (cp / cp_r dest). Unlike
/// `validateWriteDir`, the directory itself is resolved: when copying into `D`, a
/// symlinked `D` pointing out of the keg is the escape, not a safe replace
/// target. Used per recursion level so a planted symlink anywhere in the dest
/// subtree is caught.
pub fn validateDirTarget(
    io: std.Io,
    dir_path: []const u8,
    cellar_path: []const u8,
    malt_prefix: []const u8,
) SandboxError!void {
    try validatePath(dir_path, cellar_path, malt_prefix);
    try resolvedDirWithinBoundary(io, dir_path, cellar_path, malt_prefix);
}

/// Validate the object a new symlink will resolve to. Relative targets use the
/// link's parent directory, matching POSIX symlink semantics. Resolving the
/// target itself, including an existing final component, prevents a link from
/// becoming a doorway through another symlink that already leaves the prefix.
pub fn validateLinkTarget(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: []const u8,
    link_path: []const u8,
    cellar_path: []const u8,
    malt_prefix: []const u8,
) (SandboxError || std.mem.Allocator.Error)!void {
    const parent = std.fs.path.dirname(link_path) orelse "/";
    const resolved = try std.fs.path.resolve(allocator, &.{ parent, target });
    defer allocator.free(resolved);
    try validateDirTarget(io, resolved, cellar_path, malt_prefix);
}

/// How `openTargetNoFollow` opens the leaf. `write` toggles WRONLY vs RDONLY
/// (chmod only needs a handle to `fchmod`); `create`/`truncate` map to
/// `O_CREAT`/`O_TRUNC`.
pub const OpenIntent = struct {
    write: bool = true,
    create: bool = false,
    truncate: bool = false,
};

/// Open `target_path` without following a final-component symlink, after
/// `validateWriteDir` confirms the containing directory stays in the keg/prefix.
/// `O_NOFOLLOW` makes the refusal atomic at the kernel (no lstat→open race);
/// both an out-of-keg directory and a symlinked leaf map to
/// `PathSandboxViolation`. Other open failures surface as `OpenError` so callers
/// keep their swallow-on-IO contract.
pub fn openTargetNoFollow(
    io: std.Io,
    target_path: []const u8,
    cellar_path: []const u8,
    malt_prefix: []const u8,
    intent: OpenIntent,
) (SandboxError || std.posix.OpenError)!std.Io.File {
    try validateWriteDir(io, target_path, cellar_path, malt_prefix);
    const fd = std.posix.openat(std.posix.AT.FDCWD, target_path, .{
        .ACCMODE = if (intent.write) .WRONLY else .RDONLY,
        .CREAT = intent.create,
        .TRUNC = intent.truncate,
        .CLOEXEC = true,
        .NOFOLLOW = true,
    }, 0o666) catch |e| switch (e) { // 0o666 & umask, matching the prior createFileAbsolute default
        // O_NOFOLLOW yields ELOOP (SymLinkLoop) when the leaf is a symlink.
        error.SymLinkLoop => return SandboxError.PathSandboxViolation,
        else => return e,
    };
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

/// Open a confined source without following its final component. Keeping the
/// returned descriptor open binds subsequent reads to the checked object and
/// closes the leaf-symlink and check-then-open windows.
pub fn openSourceNoFollow(
    io: std.Io,
    source_path: []const u8,
    cellar_path: []const u8,
    malt_prefix: []const u8,
) (SandboxError || std.posix.OpenError)!std.Io.File {
    return openTargetNoFollow(io, source_path, cellar_path, malt_prefix, .{ .write = false });
}

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
    const wrapped = try fenceArgv(arena.allocator(), &.{ "make", "install" }, "/opt/malt/Cellar/foo/1.0", "/opt/malt", .{});
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
    const out = try fenceArgv(std.testing.allocator, empty, "/opt/malt/Cellar/foo/1.0", "/opt/malt", .{});
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
        fenceArgv(arena.allocator(), &.{"make"}, "/opt/malt\"/evil", "/opt/malt", .{}),
    );
}

test "fenceArgv maps a profile allocation failure to OutOfMemory" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // Clean paths pass validation, so the only failure left is the profile
    // allocation — it must surface as OutOfMemory, not a sandbox violation.
    try std.testing.expectError(
        FenceError.OutOfMemory,
        fenceArgv(std.testing.failing_allocator, &.{"make"}, "/opt/malt/Cellar/foo/1.0", "/opt/malt", .{}),
    );
}

test "openTargetNoFollow writes a normal in-keg file" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    // Resolved root exercises the /tmp → /private/tmp case: a symlinked prefix
    // must not read as an escape.
    var s = try Scratch.init("sandbox_open_inkeg");
    defer s.deinit();
    const keg = s.base;

    const target = try std.fs.path.join(alloc, &.{ keg, "out.txt" });
    defer alloc.free(target);

    const f = try openTargetNoFollow(io, target, keg, keg, .{ .create = true, .truncate = true });
    {
        defer f.close(io);
        try f.writeStreamingAll(io, "ok");
    }
    var rb: [8]u8 = undefined;
    const rf = try std.Io.Dir.openFileAbsolute(io, target, .{});
    defer rf.close(io);
    try std.testing.expectEqualStrings("ok", rb[0..try rf.readPositionalAll(io, &rb, 0)]);
}

test "openTargetNoFollow refuses a final-component symlink out of the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("sandbox_open_symlink_escape");
    defer s.deinit();
    const base = s.base;

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
        openTargetNoFollow(io, link, keg, base, .{ .create = true, .truncate = true }),
    );

    var rb: [16]u8 = undefined;
    const vf = try std.Io.Dir.openFileAbsolute(io, victim, .{});
    defer vf.close(io);
    try std.testing.expectEqualStrings("PRECIOUS", rb[0..try vf.readPositionalAll(io, &rb, 0)]);
}

test "validateDirTarget accepts a real in-keg dir and rejects a symlinked one" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("sandbox_dirtarget");
    defer s.deinit();
    const base = s.base;

    const keg = try std.fs.path.join(alloc, &.{ base, "keg" });
    defer alloc.free(keg);
    const realdir = try std.fs.path.join(alloc, &.{ keg, "real" });
    defer alloc.free(realdir);
    const outside = try std.fs.path.join(alloc, &.{ base, "outside" });
    defer alloc.free(outside);
    const dirlink = try std.fs.path.join(alloc, &.{ keg, "d" });
    defer alloc.free(dirlink);

    try std.Io.Dir.cwd().createDirPath(io, realdir);
    try std.Io.Dir.cwd().createDirPath(io, outside);
    try std.Io.Dir.symLinkAbsolute(io, outside, dirlink, .{});

    // A genuine directory inside the keg is fine to write into.
    try validateDirTarget(io, realdir, keg, keg);
    // A directory that is itself a symlink out of the keg is not.
    try std.testing.expectError(
        SandboxError.PathSandboxViolation,
        validateDirTarget(io, dirlink, keg, keg),
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
