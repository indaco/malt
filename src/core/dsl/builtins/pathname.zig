//! malt — DSL builtin: Pathname operations
//! Maps Ruby Pathname methods to std.fs calls.
//!
//! Same contract as fileutils.zig: fs mutations swallow their errors and
//! surface at the downstream step (linker, cellar layout, bottle verify).
//! Matches Ruby's non-raising Pathname helpers used by Homebrew formulae.

const std = @import("std");
const values = @import("../values.zig");
const sandbox = @import("../sandbox.zig");
const fs_read = @import("../../../fs/read.zig");
const ast = @import("../ast.zig");
const fallback_log = @import("../fallback_log.zig");

const Value = values.Value;

pub const BuiltinError = error{
    PathSandboxViolation,
    PostInstallFailed,
    SystemCommandFailed,
    OutOfMemory,
    UnknownMethod,
    UnsupportedNode,
    ParseError,
};

pub const ExecCtx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    cellar_path: []const u8,
    malt_prefix: []const u8,
    /// Suppress a spawned child's stdout (set under --json/--ndjson so it
    /// can't corrupt the document). Threaded in by the interpreter.
    suppress_child_stdout: bool = false,
    /// Record-only diagnostics sink for builtins (e.g. inreplace's
    /// atomic-write fallback). Optional so test contexts can omit it.
    fallback_log: ?*fallback_log.FallbackLog = null,
    /// Formula name stamped on fallback-log entries a builtin records.
    formula_name: []const u8 = "",
};

/// mkpath — recursive directory creation
pub fn mkpath(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    if (path.len == 0) return Value{ .nil = {} };
    sandbox.validateDirTarget(ctx.io, path, ctx.cellar_path, ctx.malt_prefix) catch
        return BuiltinError.PathSandboxViolation;
    std.Io.Dir.cwd().createDirPath(ctx.io, path) catch {};
    return Value{ .nil = {} };
}

/// exist? — check if path exists
pub fn existQ(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    if (path.len == 0) return Value{ .bool = false };
    std.Io.Dir.cwd().access(ctx.io, path, .{}) catch {
        return Value{ .bool = false };
    };
    return Value{ .bool = true };
}

/// directory? — check if path is a directory
pub fn directoryQ(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    if (path.len == 0) return Value{ .bool = false };
    var dir = std.Io.Dir.openDirAbsolute(ctx.io, path, .{}) catch {
        return Value{ .bool = false };
    };
    dir.close(ctx.io);
    return Value{ .bool = true };
}

/// symlink? — check if path is a symlink
pub fn symlinkQ(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    if (path.len == 0) return Value{ .bool = false };
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.Io.Dir.cwd().readLink(ctx.io, path, &buf) catch {
        return Value{ .bool = false };
    };
    return Value{ .bool = true };
}

/// write — write content to file (sandbox-validated)
pub fn write(ctx: ExecCtx, receiver: ?Value, args: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    if (path.len == 0) return Value{ .nil = {} };

    const content = if (args.len > 0) try args[0].asString(ctx.allocator) else "";

    // O_NOFOLLOW + parent-dir resolve: a keg-confined path must not write
    // through a symlink to a target outside the keg.
    const file = sandbox.openTargetNoFollow(ctx.io, path, ctx.cellar_path, ctx.malt_prefix, .{ .create = true, .truncate = true }) catch |e| switch (e) {
        error.PathSandboxViolation => return BuiltinError.PathSandboxViolation,
        else => return Value{ .nil = {} },
    };
    defer file.close(ctx.io);
    file.writeStreamingAll(ctx.io, content) catch {};
    return Value{ .nil = {} };
}

/// read — read file content
pub fn read(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    if (path.len == 0) return Value{ .string = "" };
    const file = sandbox.openSourceNoFollow(ctx.io, path, ctx.cellar_path, ctx.malt_prefix) catch |e| switch (e) {
        error.PathSandboxViolation => return BuiltinError.PathSandboxViolation,
        else => return Value{ .string = "" },
    };
    defer file.close(ctx.io);
    const content = fs_read.readFileAll(ctx.io, ctx.allocator, file, 1024 * 1024) catch {
        return Value{ .string = "" };
    };
    return Value{ .string = content };
}

/// children — list directory entries
pub fn children(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    if (path.len == 0) return Value{ .array = &.{} };
    var dir = std.Io.Dir.openDirAbsolute(ctx.io, path, .{ .iterate = true }) catch {
        return Value{ .array = &.{} };
    };
    defer dir.close(ctx.io);

    var entries: std.ArrayList(Value) = .empty;
    var iter = dir.iterate();
    while (iter.next(ctx.io) catch null) |entry| {
        const child_path = std.fs.path.join(ctx.allocator, &.{ path, entry.name }) catch continue;
        entries.append(ctx.allocator, Value{ .pathname = child_path }) catch continue;
    }
    const slice = entries.toOwnedSlice(ctx.allocator) catch return BuiltinError.OutOfMemory;
    return Value{ .array = slice };
}

/// basename — filename component
pub fn basename(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    return Value{ .string = std.fs.path.basename(path) };
}

/// dirname — parent directory
pub fn dirname(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    return Value{ .pathname = std.fs.path.dirname(path) orelse "/" };
}

/// extname — file extension
pub fn extname(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    return Value{ .string = std.fs.path.extension(path) };
}

/// to_s — convert pathname to string
pub fn toS(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    return Value{ .string = path };
}

/// realpath — resolve symlinks
pub fn realpath(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.cwd().realPathFile(ctx.io, path, &buf) catch {
        return Value{ .pathname = path };
    };
    const duped = ctx.allocator.dupe(u8, buf[0..n]) catch return BuiltinError.OutOfMemory;
    return Value{ .pathname = duped };
}

/// file? — check if path is a regular file
pub fn fileQ(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    if (path.len == 0) return Value{ .bool = false };
    const stat = std.Io.Dir.cwd().statFile(ctx.io, path, .{}) catch {
        return Value{ .bool = false };
    };
    return Value{ .bool = stat.kind == .file };
}

/// atomic_write — write content atomically (sandbox-validated)
pub fn atomicWrite(ctx: ExecCtx, receiver: ?Value, args: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    if (path.len == 0) return Value{ .nil = {} };

    const content = if (args.len > 0) try args[0].asString(ctx.allocator) else "";

    // Reuse `write`'s gate so atomicity cannot become a way around the
    // no-follow rule: a keg-confined symlink leaf is refused, not renamed over.
    if (sandbox.openTargetNoFollow(ctx.io, path, ctx.cellar_path, ctx.malt_prefix, .{ .write = false })) |probe| {
        probe.close(ctx.io);
    } else |e| switch (e) {
        error.PathSandboxViolation => return BuiltinError.PathSandboxViolation,
        else => {}, // usually no target yet; anything else fails again below
    }

    // The rename installs a new inode at the default mode, so carry the old one
    // across. Read it with stat, which needs no read permission on the target -
    // opening one that lacks it would silently widen the mode instead.
    var permissions: std.Io.File.Permissions = .default_file;
    if (std.Io.Dir.cwd().statFile(ctx.io, path, .{ .follow_symlinks = false })) |st| {
        permissions = st.permissions;
    } else |_| {}

    // Temp-plus-rename: the original stays readable until the rename lands,
    // which is what the name promises a formula author.
    var atomic_file = std.Io.Dir.cwd().createFileAtomic(ctx.io, path, .{
        .permissions = permissions,
        .replace = true,
    }) catch return Value{ .nil = {} };
    defer atomic_file.deinit(ctx.io);
    atomic_file.file.writeStreamingAll(ctx.io, content) catch return Value{ .nil = {} };
    atomic_file.replace(ctx.io) catch return Value{ .nil = {} };
    return Value{ .nil = {} };
}

/// opt_bin — receiver/"bin" (Formula accessor)
pub fn optBin(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    const joined = std.fs.path.join(ctx.allocator, &.{ path, "bin" }) catch return BuiltinError.OutOfMemory;
    return Value{ .pathname = joined };
}

/// opt_lib — receiver/"lib" (Formula accessor)
pub fn optLib(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    const joined = std.fs.path.join(ctx.allocator, &.{ path, "lib" }) catch return BuiltinError.OutOfMemory;
    return Value{ .pathname = joined };
}

/// opt_include — receiver/"include" (Formula accessor)
pub fn optInclude(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    const joined = std.fs.path.join(ctx.allocator, &.{ path, "include" }) catch return BuiltinError.OutOfMemory;
    return Value{ .pathname = joined };
}

/// pkgetc — `Formula[name].pkgetc` is `<prefix>/etc/<name>`, not
/// `<opt>/<name>/etc`. The receiver is the opt anchor (`<prefix>/opt/<name>`),
/// so re-anchor under malt_prefix using its basename as the package name.
/// The bare current-formula `pkgetc` resolves through path bindings, not here.
pub fn pkgetc(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    const name = std.fs.path.basename(path);
    const joined = std.fs.path.join(ctx.allocator, &.{ ctx.malt_prefix, "etc", name }) catch return BuiltinError.OutOfMemory;
    return Value{ .pathname = joined };
}

/// unlink — delete a file (alias for File.delete)
pub fn unlink(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    if (path.len == 0) return Value{ .nil = {} };
    sandbox.validateWriteDir(ctx.io, path, ctx.cellar_path, ctx.malt_prefix) catch
        return BuiltinError.PathSandboxViolation;
    std.Io.Dir.cwd().deleteFile(ctx.io, path) catch {};
    return Value{ .nil = {} };
}

/// install_symlink — link source(s) into the receiver directory.
///
/// Homebrew semantics: the receiver is the *target directory*, each arg
/// names a source. A bare source lands at `<dir>/<basename(source)>`; a
/// hash entry `source => link_name` overrides the link name; an array
/// links each element by basename. The link path is sandbox-validated.
pub fn installSymlink(ctx: ExecCtx, receiver: ?Value, args: []const Value) BuiltinError!Value {
    const dir = try receiverPath(ctx.allocator, receiver);
    if (dir.len == 0) return Value{ .nil = {} };
    sandbox.validateDirTarget(ctx.io, dir, ctx.cellar_path, ctx.malt_prefix) catch
        return BuiltinError.PathSandboxViolation;
    std.Io.Dir.cwd().createDirPath(ctx.io, dir) catch {};
    for (args) |arg| try installSymlinkArg(ctx, dir, arg);
    return Value{ .nil = {} };
}

fn installSymlinkArg(ctx: ExecCtx, dir: []const u8, arg: Value) BuiltinError!void {
    switch (arg) {
        // `source => link_name`: key is the source, value the link name.
        .hash => |pairs| for (pairs) |p| {
            const source = try p.key.asString(ctx.allocator);
            const name = try p.value.asString(ctx.allocator);
            try linkInto(ctx, dir, source, name);
        },
        .array => |items| for (items) |item| {
            const source = try item.asString(ctx.allocator);
            try linkInto(ctx, dir, source, std.fs.path.basename(source));
        },
        else => {
            const source = try arg.asString(ctx.allocator);
            try linkInto(ctx, dir, source, std.fs.path.basename(source));
        },
    }
}

/// Symlink `<dir>/<name>` → `<source>`, sandbox-validated on both paths.
/// Same non-raising fs contract as the rest of this module: a
/// failed mkdir/symlink surfaces downstream, not here.
fn linkInto(ctx: ExecCtx, dir: []const u8, source: []const u8, name: []const u8) BuiltinError!void {
    if (source.len == 0 or name.len == 0) return;

    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    // Overflow means a pathological path — skip rather than truncate.
    const link = std.fmt.bufPrint(&link_buf, "{s}/{s}", .{ dir, name }) catch return;

    sandbox.validateWriteDir(ctx.io, link, ctx.cellar_path, ctx.malt_prefix) catch
        return BuiltinError.PathSandboxViolation;
    sandbox.validateLinkTarget(ctx.allocator, ctx.io, source, link, ctx.cellar_path, ctx.malt_prefix) catch |e| switch (e) {
        error.OutOfMemory => return BuiltinError.OutOfMemory,
        error.PathSandboxViolation => return BuiltinError.PathSandboxViolation,
    };

    std.Io.Dir.cwd().deleteFile(ctx.io, link) catch {};
    // Relative targets are ordinary in formulae and already bounds-checked above;
    // `symLinkAbsolute` would assert on one and abort the process.
    std.Io.Dir.cwd().symLink(ctx.io, source, link, .{}) catch {};
}

/// glob(pattern) — match files in a directory against a glob pattern
/// Receiver is the directory path; first arg is the pattern string.
/// If called bare (no receiver), the first arg is the full glob pattern.
pub fn glob(ctx: ExecCtx, receiver: ?Value, args: []const Value) BuiltinError!Value {
    var base_dir: []const u8 = "";
    var pattern: []const u8 = "*";

    if (receiver) |recv| {
        // Receiver form: dir.glob("*.dylib")
        base_dir = switch (recv) {
            .pathname => |p| p,
            .string => |s| s,
            else => recv.asString(ctx.allocator) catch return BuiltinError.OutOfMemory,
        };
        if (args.len == 0) return Value{ .array = &.{} };
        pattern = args[0].asString(ctx.allocator) catch return Value{ .array = &.{} };
    } else {
        // Bare form: Dir.glob("lib/*.dylib") — first arg is full pattern
        if (args.len == 0) return Value{ .array = &.{} };
        const full = args[0].asString(ctx.allocator) catch return Value{ .array = &.{} };
        if (full.len == 0) return Value{ .array = &.{} };
        base_dir = std.fs.path.dirname(full) orelse ".";
        pattern = std.fs.path.basename(full);
    }

    // Guard against empty/relative base_dir
    if (base_dir.len == 0) return Value{ .array = &.{} };

    var dir = std.Io.Dir.openDirAbsolute(ctx.io, base_dir, .{ .iterate = true }) catch {
        return Value{ .array = &.{} };
    };
    defer dir.close(ctx.io);

    var results: std.ArrayList(Value) = .empty;
    var iter = dir.iterate();
    while (iter.next(ctx.io) catch null) |entry| {
        if (globMatch(pattern, entry.name)) {
            const child_path = std.fs.path.join(ctx.allocator, &.{ base_dir, entry.name }) catch continue;
            results.append(ctx.allocator, Value{ .pathname = child_path }) catch continue;
        }
    }

    const slice = results.toOwnedSlice(ctx.allocator) catch return BuiltinError.OutOfMemory;
    return Value{ .array = slice };
}

/// Glob pattern matching with `*`, `?`, and `{a,b,c}` brace expansion.
fn globMatch(pattern: []const u8, name: []const u8) bool {
    // Check if pattern contains braces — if so, expand and try each alternative
    if (std.mem.findScalar(u8, pattern, '{')) |brace_start| {
        if (findMatchingBrace(pattern, brace_start)) |brace_end| {
            const prefix = pattern[0..brace_start];
            const suffix = pattern[brace_end + 1 ..];
            const alternatives = pattern[brace_start + 1 .. brace_end];

            // Split alternatives by comma and try each
            var iter = std.mem.splitScalar(u8, alternatives, ',');
            while (iter.next()) |alt| {
                // Build expanded pattern: prefix + alt + suffix
                var buf: [1024]u8 = undefined;
                const expanded_len = prefix.len + alt.len + suffix.len;
                if (expanded_len > buf.len) continue;
                @memcpy(buf[0..prefix.len], prefix);
                @memcpy(buf[prefix.len .. prefix.len + alt.len], alt);
                @memcpy(buf[prefix.len + alt.len .. expanded_len], suffix);
                if (globMatch(buf[0..expanded_len], name)) return true;
            }
            return false;
        }
    }

    // Standard glob matching without braces
    var pi: usize = 0;
    var ni: usize = 0;
    var star_pi: ?usize = null;
    var star_ni: usize = 0;

    while (ni < name.len) {
        if (pi < pattern.len and (pattern[pi] == name[ni] or pattern[pi] == '?')) {
            pi += 1;
            ni += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_ni = ni;
            pi += 1;
        } else if (star_pi) |sp| {
            pi = sp + 1;
            star_ni += 1;
            ni = star_ni;
        } else {
            return false;
        }
    }

    // Consume trailing *'s in pattern
    while (pi < pattern.len and pattern[pi] == '*') : (pi += 1) {}
    return pi == pattern.len;
}

/// Find matching closing brace, accounting for nesting.
fn findMatchingBrace(pattern: []const u8, start: usize) ?usize {
    var depth: u32 = 0;
    var i = start;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '{') {
            depth += 1;
        } else if (pattern[i] == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn receiverPath(allocator: std.mem.Allocator, receiver: ?Value) BuiltinError![]const u8 {
    const recv = receiver orelse return BuiltinError.UnknownMethod;
    return switch (recv) {
        .pathname => |p| p,
        .string => |s| s,
        else => recv.asString(allocator) catch return BuiltinError.OutOfMemory,
    };
}

// ---------------------------------------------------------------------------
// Inline tests
// ---------------------------------------------------------------------------

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

/// pkgetc only reads `allocator` + `malt_prefix`; the rest is structurally
/// required by ExecCtx but never touched on this path.
fn testCtx(allocator: std.mem.Allocator, malt_prefix: []const u8) ExecCtx {
    return .{
        .allocator = allocator,
        .io = undefined,
        .environ = undefined,
        .cellar_path = "",
        .malt_prefix = malt_prefix,
    };
}

test "pkgetc re-anchors a Formula[] opt path to <prefix>/etc/<name>" {
    // Homebrew's `Formula[name].pkgetc` is `<prefix>/etc/<name>`, not
    // `<opt>/<name>/etc`. The receiver is the opt anchor, so pkgetc rebuilds
    // under malt_prefix; the bare current-formula pkgetc uses path bindings.
    const ctx = testCtx(std.testing.allocator, "/opt/malt");
    const etc = try pkgetc(ctx, Value{ .pathname = "/opt/malt/opt/ca-certificates" }, &.{});
    defer std.testing.allocator.free(etc.pathname);
    try std.testing.expectEqualStrings("/opt/malt/etc/ca-certificates", etc.pathname);
}

test "pkgetc keeps an @-versioned formula name intact" {
    // openssl@3 et al. carry `@` in the keg name; the basename re-anchor
    // must preserve it verbatim.
    const ctx = testCtx(std.testing.allocator, "/opt/malt");
    const etc = try pkgetc(ctx, Value{ .pathname = "/opt/malt/opt/openssl@3" }, &.{});
    defer std.testing.allocator.free(etc.pathname);
    try std.testing.expectEqualStrings("/opt/malt/etc/openssl@3", etc.pathname);
}

test "write refuses to follow a symlink out of the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;

    var s = try Scratch.init("pathname_write_symlink_escape");
    defer s.deinit();
    const base = s.base;

    const keg = try std.fs.path.join(alloc, &.{ base, "Cellar", "foo", "1.0" });
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
    // keg/pwn -> outside victim: a keg-confined link name pointing out of the keg.
    try std.Io.Dir.symLinkAbsolute(io, victim, link, .{});

    const ctx: ExecCtx = .{
        .allocator = alloc,
        .io = io,
        .environ = undefined,
        .cellar_path = keg,
        .malt_prefix = base,
    };

    // Writing through the link must be refused, not followed.
    try std.testing.expectError(
        BuiltinError.PathSandboxViolation,
        write(ctx, Value{ .pathname = link }, &.{Value{ .string = "owned" }}),
    );

    // And the out-of-keg target must be byte-for-byte untouched.
    var rb: [32]u8 = undefined;
    const vf = try std.Io.Dir.openFileAbsolute(io, victim, .{});
    defer vf.close(io);
    const n = try vf.readPositionalAll(io, &rb, 0);
    try std.testing.expectEqualStrings("PRECIOUS", rb[0..n]);
}

test "install_symlink keeps a relative in-keg source instead of aborting" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("install_symlink_relative");
    defer s.deinit();
    const keg = s.base;

    const libexec = try std.fs.path.join(alloc, &.{ keg, "libexec" });
    defer alloc.free(libexec);
    try std.Io.Dir.cwd().createDirPath(io, libexec);
    const real = try std.fs.path.join(alloc, &.{ libexec, "tool" });
    defer alloc.free(real);
    (try std.Io.Dir.createFileAbsolute(io, real, .{})).close(io);
    const bin = try std.fs.path.join(alloc, &.{ keg, "bin" });
    defer alloc.free(bin);

    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    _ = try installSymlink(ctx, Value{ .pathname = bin }, &.{Value{ .string = "../libexec/tool" }});

    const link = try std.fs.path.join(alloc, &.{ bin, "tool" });
    defer alloc.free(link);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.cwd().readLink(io, link, &buf);
    try std.testing.expectEqualStrings("../libexec/tool", buf[0..n]);
    try std.Io.Dir.cwd().access(io, link, .{});
}

test "install_symlink refuses a relative source that escapes the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("install_symlink_rel_escape");
    defer s.deinit();
    const base = s.base;

    const keg = try std.fs.path.join(alloc, &.{ base, "keg" });
    defer alloc.free(keg);
    const bin = try std.fs.path.join(alloc, &.{ keg, "bin" });
    defer alloc.free(bin);
    try std.Io.Dir.cwd().createDirPath(io, bin);

    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    try std.testing.expectError(
        BuiltinError.PathSandboxViolation,
        installSymlink(ctx, Value{ .pathname = bin }, &.{Value{ .string = "../../outside" }}),
    );
    const link = try std.fs.path.join(alloc, &.{ bin, "outside" });
    defer alloc.free(link);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, link, .{}));
}

test "install_symlink hash form keeps a relative source under the given name" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("install_symlink_hash_relative");
    defer s.deinit();
    const keg = s.base;

    const libexec = try std.fs.path.join(alloc, &.{ keg, "libexec" });
    defer alloc.free(libexec);
    try std.Io.Dir.cwd().createDirPath(io, libexec);
    const real = try std.fs.path.join(alloc, &.{ libexec, "tool" });
    defer alloc.free(real);
    (try std.Io.Dir.createFileAbsolute(io, real, .{})).close(io);
    const bin = try std.fs.path.join(alloc, &.{ keg, "bin" });
    defer alloc.free(bin);

    const pairs = [_]Value.HashPair{.{
        .key = Value{ .string = "../libexec/tool" },
        .value = Value{ .string = "alias" },
    }};
    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    _ = try installSymlink(ctx, Value{ .pathname = bin }, &.{Value{ .hash = &pairs }});

    const link = try std.fs.path.join(alloc, &.{ bin, "alias" });
    defer alloc.free(link);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.cwd().readLink(io, link, &buf);
    try std.testing.expectEqualStrings("../libexec/tool", buf[0..n]);
    try std.Io.Dir.cwd().access(io, link, .{});
}

test "atomic_write leaves the original readable until the new content lands" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;

    var s = try Scratch.init("pathname_atomic_write_preserves");
    defer s.deinit();
    const keg = s.base;

    const target = try std.fs.path.join(alloc, &.{ keg, "config" });
    defer alloc.free(target);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, target, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "ORIGINAL");
    }

    // Held open across the write: a temp-plus-rename keeps this handle on the
    // old inode, a truncate-in-place would pull the bytes out from under it.
    const held = try std.Io.Dir.openFileAbsolute(io, target, .{});
    defer held.close(io);

    const ctx: ExecCtx = .{
        .allocator = alloc,
        .io = io,
        .environ = undefined,
        .cellar_path = keg,
        .malt_prefix = keg,
    };
    _ = try atomicWrite(ctx, Value{ .pathname = target }, &.{Value{ .string = "REPLACED" }});

    var old_buf: [16]u8 = undefined;
    const old_n = try held.readPositionalAll(io, &old_buf, 0);
    try std.testing.expectEqualStrings("ORIGINAL", old_buf[0..old_n]);

    var new_buf: [16]u8 = undefined;
    const nf = try std.Io.Dir.openFileAbsolute(io, target, .{});
    defer nf.close(io);
    const new_n = try nf.readPositionalAll(io, &new_buf, 0);
    try std.testing.expectEqualStrings("REPLACED", new_buf[0..new_n]);
}

test "atomic_write refuses to follow a symlink out of the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;

    var s = try Scratch.init("pathname_atomic_write_symlink_escape");
    defer s.deinit();
    const base = s.base;

    const keg = try std.fs.path.join(alloc, &.{ base, "Cellar", "foo", "1.0" });
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

    const ctx: ExecCtx = .{
        .allocator = alloc,
        .io = io,
        .environ = undefined,
        .cellar_path = keg,
        .malt_prefix = base,
    };

    // Atomicity must not become a way around the no-follow rule `write` keeps.
    try std.testing.expectError(
        BuiltinError.PathSandboxViolation,
        atomicWrite(ctx, Value{ .pathname = link }, &.{Value{ .string = "PWNED" }}),
    );

    var vb: [16]u8 = undefined;
    const vf2 = try std.Io.Dir.openFileAbsolute(io, victim, .{});
    defer vf2.close(io);
    try std.testing.expectEqualStrings("PRECIOUS", vb[0..try vf2.readPositionalAll(io, &vb, 0)]);
}

test "atomic_write keeps the mode of a target it cannot open for reading" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;

    var s = try Scratch.init("pathname_atomic_write_unreadable");
    defer s.deinit();
    const keg = s.base;

    const target = try std.fs.path.join(alloc, &.{ keg, "writeonly" });
    defer alloc.free(target);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, target, .{ .permissions = @enumFromInt(0o200) });
        f.close(io);
    }

    const ctx: ExecCtx = .{
        .allocator = alloc,
        .io = io,
        .environ = undefined,
        .cellar_path = keg,
        .malt_prefix = keg,
    };
    _ = try atomicWrite(ctx, Value{ .pathname = target }, &.{Value{ .string = "after" }});

    // Reading the mode by opening the file fails here, and falling back to the
    // default would hand a write-only file world-readable permissions.
    const st = try std.Io.Dir.cwd().statFile(io, target, .{});
    try std.testing.expectEqual(@as(u32, 0o200), @intFromEnum(st.permissions) & 0o777);
}

test "atomic_write keeps the target's existing mode instead of widening it" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;

    var s = try Scratch.init("pathname_atomic_write_mode");
    defer s.deinit();
    const keg = s.base;

    const target = try std.fs.path.join(alloc, &.{ keg, "secret" });
    defer alloc.free(target);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, target, .{ .permissions = @enumFromInt(0o600) });
        defer f.close(io);
        try f.writeStreamingAll(io, "before");
    }

    const ctx: ExecCtx = .{
        .allocator = alloc,
        .io = io,
        .environ = undefined,
        .cellar_path = keg,
        .malt_prefix = keg,
    };
    _ = try atomicWrite(ctx, Value{ .pathname = target }, &.{Value{ .string = "after" }});

    // Replacing by rename creates a new inode; a restrictive mode on a config
    // file must not silently widen because of that.
    const st = try std.Io.Dir.cwd().statFile(io, target, .{});
    try std.testing.expectEqual(@as(u32, 0o600), @intFromEnum(st.permissions) & 0o777);
}

test "glob matches wildcards and brace alternation" {
    // Baseline for the expansion budget below: the shapes formula globs
    // actually use must keep matching exactly as before.
    try std.testing.expect(globMatch("*.h", "stdio.h"));
    try std.testing.expect(!globMatch("*.h", "stdio.c"));
    try std.testing.expect(globMatch("lib?.a", "libz.a"));
    try std.testing.expect(globMatch("*.{h,hpp,hxx}", "vec.hpp"));
    try std.testing.expect(!globMatch("*.{h,hpp,hxx}", "vec.cpp"));
    try std.testing.expect(globMatch("{bin,sbin}/*", "bin/tool"));
    try std.testing.expect(globMatch("a{b,c}d{e,f}", "acdf"));
    try std.testing.expect(!globMatch("a{b,c}d{e,f}", "axdf"));
}

test "glob alternation cannot be driven into an unbounded expansion" {
    // Each `{a,b}` group doubles the work, so a pattern only this long already
    // costs 2^31 expansions unbounded - a hang, not a crash, since the depth
    // stays shallow. The pattern comes from formula code, so it needs a bound.
    var pattern: [30 * 5]u8 = undefined;
    for (0..30) |i| @memcpy(pattern[i * 5 ..][0..5], "{a,b}");

    try std.testing.expect(!globMatch(&pattern, "no-such-name"));
}

test "glob expansion budget refuses instead of exploring" {
    // Exhausting the budget must degrade to "no match" rather than keep going;
    // the surrounding builtin has no error channel to report a give-up on.
    var spent: u32 = 3;
    try std.testing.expect(!globMatchBudgeted("{a,b}{a,b}{a,b}{a,b}", "abab", &spent));

    var ample: u32 = max_glob_expansions;
    try std.testing.expect(globMatchBudgeted("{a,b}{a,b}{a,b}{a,b}", "abab", &ample));
}
