//! malt — DSL builtin: FileUtils operations
//! Maps Ruby FileUtils module calls to std.fs operations.
//! All mutating operations go through sandbox.validatePath first.
//!
//! Every fs mutation below swallows its error. The contract is:
//! formulae run as a sequence of mutations and a final check (linker,
//! cellar layout, bottle verify); a silent mid-step failure surfaces at
//! the downstream step that expects the side effect to have happened.
//! Matches Ruby FileUtils' force variants — closer to `rm_f`/`cp` with
//! `force: true` than their strict counterparts.

const std = @import("std");
const values = @import("../values.zig");
const sandbox = @import("../sandbox.zig");
const pathname = @import("pathname.zig");

const Value = values.Value;
const BuiltinError = pathname.BuiltinError;
const ExecCtx = pathname.ExecCtx;

/// rm — remove a file or array of files
pub fn rm(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len == 0) return Value{ .nil = {} };

    // If first arg is an array, remove each file
    switch (args[0]) {
        .array => |items| {
            for (items) |item| {
                const path = item.asString(ctx.allocator) catch continue;
                sandbox.validateWriteDir(ctx.io, path, ctx.cellar_path, ctx.malt_prefix) catch continue;
                std.Io.Dir.cwd().deleteFile(ctx.io, path) catch {};
            }
        },
        else => {
            const path = try args[0].asString(ctx.allocator);
            sandbox.validateWriteDir(ctx.io, path, ctx.cellar_path, ctx.malt_prefix) catch
                return BuiltinError.PathSandboxViolation;
            std.Io.Dir.cwd().deleteFile(ctx.io, path) catch {};
        },
    }
    return Value{ .nil = {} };
}

/// rm_r — remove recursively
pub fn rmR(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len == 0) return Value{ .nil = {} };
    const path = try args[0].asString(ctx.allocator);
    // Resolve the parent, not the leaf: `deleteTree` unlinks a symlinked leaf
    // without following it (so an in-keg alias stays removable), but it *does*
    // traverse intermediate components — which is how a planted directory
    // symlink turned this into an out-of-keg recursive delete. Same guard
    // `cp`/`cp_r` already use for their destination.
    sandbox.validateWriteDir(ctx.io, path, ctx.cellar_path, ctx.malt_prefix) catch
        return BuiltinError.PathSandboxViolation;
    std.Io.Dir.cwd().deleteTree(ctx.io, path) catch {};
    return Value{ .nil = {} };
}

/// rm_rf — remove recursively, force (ignore errors)
pub fn rmRf(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    return rmR(ctx, null, args);
}

/// mkdir_p — create directory and parents
pub fn mkdirP(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len == 0) return Value{ .nil = {} };
    const path = try args[0].asString(ctx.allocator);
    // `createDirPath` follows intermediate symlinks, so the lexical check alone
    // let a planted directory link materialise the tree outside the keg.
    sandbox.validateWriteDir(ctx.io, path, ctx.cellar_path, ctx.malt_prefix) catch
        return BuiltinError.PathSandboxViolation;
    std.Io.Dir.cwd().createDirPath(ctx.io, path) catch {};
    return Value{ .nil = {} };
}

/// cp — copy file(s). First arg can be a single path or an array of paths.
pub fn cp(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len < 2) return Value{ .nil = {} };
    const dst = try args[1].asString(ctx.allocator);
    // Resolve the dest's parent so an intermediate-directory symlink can't pull
    // the copy out of the keg; the final component is replaced atomically.
    sandbox.validateWriteDir(ctx.io, dst, ctx.cellar_path, ctx.malt_prefix) catch
        return BuiltinError.PathSandboxViolation;

    // If first arg is an array, copy each file into dst directory
    switch (args[0]) {
        .array => |items| {
            std.Io.Dir.cwd().createDirPath(ctx.io, dst) catch {};
            // dst is the directory we copy into; resolve it (it may be a planted
            // symlink) before landing files in it. Entries replace a final-
            // component symlink atomically, so they need no extra guard.
            sandbox.validateDirTarget(ctx.io, dst, ctx.cellar_path, ctx.malt_prefix) catch
                return BuiltinError.PathSandboxViolation;
            for (items) |item| {
                const src = item.asString(ctx.allocator) catch continue;
                const base = std.fs.path.basename(src);
                const dest_path = std.fs.path.join(ctx.allocator, &.{ dst, base }) catch continue;
                // Best-effort per entry: a forbidden/out-of-keg source is skipped.
                copyFileConfined(ctx.io, src, dest_path, ctx.cellar_path, ctx.malt_prefix) catch continue;
            }
        },
        else => {
            const src = args[0].asString(ctx.allocator) catch return Value{ .nil = {} };
            copyFileConfined(ctx.io, src, dst, ctx.cellar_path, ctx.malt_prefix) catch |e| switch (e) {
                error.PathSandboxViolation => return BuiltinError.PathSandboxViolation,
                error.NotRegularFile => {}, // a directory src is a silent no-op for cp, as before
            };
        },
    }
    return Value{ .nil = {} };
}

/// cp_r — copy recursively
pub fn cpR(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len < 2) return Value{ .nil = {} };
    const src = try args[0].asString(ctx.allocator);
    const dst = try args[1].asString(ctx.allocator);
    sandbox.validateWriteDir(ctx.io, dst, ctx.cellar_path, ctx.malt_prefix) catch
        return BuiltinError.PathSandboxViolation;

    // Try as a single file (no-follow read confines the source leaf); a
    // directory falls through to the recursive walk, which confines each level.
    copyFileConfined(ctx.io, src, dst, ctx.cellar_path, ctx.malt_prefix) catch |e| switch (e) {
        error.PathSandboxViolation => return BuiltinError.PathSandboxViolation,
        error.NotRegularFile => copyDirRecursive(ctx.io, ctx.allocator, src, dst, ctx.cellar_path, ctx.malt_prefix) catch {},
    };
    return Value{ .nil = {} };
}

/// mv — move/rename
pub fn mv(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len < 2) return Value{ .nil = {} };
    const src = try args[0].asString(ctx.allocator);
    const dst = try args[1].asString(ctx.allocator);
    // Resolve the dest's parent too, so an intermediate-directory symlink can't
    // pull the move out of the keg; rename replaces a final-component symlink
    // atomically without following it.
    sandbox.validateWriteDir(ctx.io, dst, ctx.cellar_path, ctx.malt_prefix) catch
        return BuiltinError.PathSandboxViolation;
    // Confine the source too: rename unlinks the source dir-entry, so an
    // unchecked src is an out-of-keg destroy/relocate primitive. validateWriteDir
    // rejects a direct out-of-keg src and an intermediate-directory symlink; a
    // final-component symlink src is fine — rename relinks the link itself.
    sandbox.validateWriteDir(ctx.io, src, ctx.cellar_path, ctx.malt_prefix) catch
        return BuiltinError.PathSandboxViolation;
    std.Io.Dir.renameAbsolute(src, dst, ctx.io) catch {};
    return Value{ .nil = {} };
}

/// chmod — change file mode. Second arg can be path or array of paths.
pub fn chmod(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len < 2) return Value{ .nil = {} };
    const mode_val = switch (args[0]) {
        .int => |i| i,
        else => return Value{ .nil = {} },
    };
    // chmod(2) only consults the low permission bits; mask so any i64 formula
    // mode fits mode_t without a checked-cast panic on out-of-range input.
    const mode: std.posix.mode_t = @intCast(mode_val & 0o7777);

    switch (args[1]) {
        .array => |items| {
            // Best-effort per entry: skip anything that escapes or follows a link.
            for (items) |item| {
                const p = item.asString(ctx.allocator) catch continue;
                chmodNoFollow(ctx, p, mode) catch continue;
            }
        },
        else => {
            const path = args[1].asString(ctx.allocator) catch return Value{ .nil = {} };
            chmodNoFollow(ctx, path, mode) catch |e| switch (e) {
                error.PathSandboxViolation => return BuiltinError.PathSandboxViolation,
                else => {},
            };
        },
    }
    return Value{ .nil = {} };
}

/// chmod via an `O_NOFOLLOW` handle so a symlinked leaf chmods the link, not its
/// (possibly out-of-keg) target. Opens read-only — `fchmod` only needs the fd.
fn chmodNoFollow(ctx: ExecCtx, path: []const u8, mode: std.posix.mode_t) (sandbox.SandboxError || std.posix.OpenError)!void {
    const file = try sandbox.openTargetNoFollow(ctx.io, path, ctx.cellar_path, ctx.malt_prefix, .{ .write = false });
    defer file.close(ctx.io);
    file.setPermissions(ctx.io, std.Io.File.Permissions.fromMode(mode)) catch {};
}

/// touch — create file or update timestamp
pub fn touch(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len == 0) return Value{ .nil = {} };
    const path = try args[0].asString(ctx.allocator);

    // Create (no truncate) through an O_NOFOLLOW handle: a symlinked leaf must
    // not let touch create/clobber a file outside the keg.
    const file = sandbox.openTargetNoFollow(ctx.io, path, ctx.cellar_path, ctx.malt_prefix, .{ .create = true }) catch |e| switch (e) {
        error.PathSandboxViolation => return BuiltinError.PathSandboxViolation,
        else => return Value{ .nil = {} },
    };
    file.close(ctx.io);
    return Value{ .nil = {} };
}

/// ln_s — create symbolic link
pub fn lnS(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len < 2) return Value{ .nil = {} };
    const target = try args[0].asString(ctx.allocator);
    const link_path = try args[1].asString(ctx.allocator);
    if (target.len == 0 or link_path.len == 0) return Value{ .nil = {} };
    sandbox.validateWriteDir(ctx.io, link_path, ctx.cellar_path, ctx.malt_prefix) catch
        return BuiltinError.PathSandboxViolation;
    // The target was previously unchecked, which let a formula mint a doorway
    // out of the keg for any later builtin (or the linker) to walk through.
    // POSIX resolves a relative target against the link's own directory, so
    // resolve it the same way and hold it to the same boundary as a write.
    sandbox.validateLinkTarget(ctx.allocator, ctx.io, target, link_path, ctx.cellar_path, ctx.malt_prefix) catch |e| switch (e) {
        error.OutOfMemory => return BuiltinError.OutOfMemory,
        error.PathSandboxViolation => return BuiltinError.PathSandboxViolation,
    };

    if (std.fs.path.dirname(link_path)) |parent| {
        std.Io.Dir.cwd().createDirPath(ctx.io, parent) catch {};
    }
    // Relative targets are ordinary in formulae and already bounds-checked above;
    // `symLinkAbsolute` would assert on one and abort the process.
    std.Io.Dir.cwd().symLink(ctx.io, target, link_path, .{}) catch {};
    return Value{ .nil = {} };
}

/// ln_sf — create symbolic link, force (remove existing)
/// Supports: ln_sf target, link_path  OR  ln_sf [array_of_targets], dest_dir
pub fn lnSf(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len < 2) return Value{ .nil = {} };

    // If first arg is an array, symlink each item into the destination directory
    switch (args[0]) {
        .array => |items| {
            const dest_dir = args[1].asString(ctx.allocator) catch return Value{ .nil = {} };
            sandbox.validateDirTarget(ctx.io, dest_dir, ctx.cellar_path, ctx.malt_prefix) catch
                return BuiltinError.PathSandboxViolation;
            std.Io.Dir.cwd().createDirPath(ctx.io, dest_dir) catch {};
            for (items) |item| {
                const target = item.asString(ctx.allocator) catch continue;
                const base = std.fs.path.basename(target);
                const link_path = std.fs.path.join(ctx.allocator, &.{ dest_dir, base }) catch continue;
                defer ctx.allocator.free(link_path);
                try forceSymlink(ctx, target, link_path);
            }
        },
        else => {
            const target = try args[0].asString(ctx.allocator);
            const link_path = try args[1].asString(ctx.allocator);
            try forceSymlink(ctx, target, link_path);
        },
    }
    return Value{ .nil = {} };
}

fn forceSymlink(ctx: ExecCtx, target: []const u8, link_path: []const u8) BuiltinError!void {
    sandbox.validateWriteDir(ctx.io, link_path, ctx.cellar_path, ctx.malt_prefix) catch
        return BuiltinError.PathSandboxViolation;
    sandbox.validateLinkTarget(ctx.allocator, ctx.io, target, link_path, ctx.cellar_path, ctx.malt_prefix) catch |e| switch (e) {
        error.OutOfMemory => return BuiltinError.OutOfMemory,
        error.PathSandboxViolation => return BuiltinError.PathSandboxViolation,
    };
    if (std.fs.path.dirname(link_path)) |parent| {
        std.Io.Dir.cwd().createDirPath(ctx.io, parent) catch {};
    }
    std.Io.Dir.cwd().deleteFile(ctx.io, link_path) catch {};
    // Relative targets are ordinary in formulae and already bounds-checked above;
    // `symLinkAbsolute` would assert on one and abort the process.
    std.Io.Dir.cwd().symLink(ctx.io, target, link_path, .{}) catch {};
}

const fs_test_io = std.Options.debug_io;

var scratch_seq: std.atomic.Value(u32) = .init(0);

/// Stands in for std.testing.tmpDir, which builds under .zig-cache - a tree the
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

test "cp refuses to copy through an intermediate-directory symlink out of the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("fileutils_cp_dirlink_dst");
    defer s.deinit();
    const base = s.base;

    const keg = try std.fs.path.join(alloc, &.{ base, "keg" });
    defer alloc.free(keg);
    const outside = try std.fs.path.join(alloc, &.{ base, "outside" });
    defer alloc.free(outside);
    const dirlink = try std.fs.path.join(alloc, &.{ keg, "d" });
    defer alloc.free(dirlink);
    const src = try std.fs.path.join(alloc, &.{ keg, "src.txt" });
    defer alloc.free(src);
    const dst = try std.fs.path.join(alloc, &.{ dirlink, "x" }); // keg/d/x, d -> outside
    defer alloc.free(dst);
    const escaped = try std.fs.path.join(alloc, &.{ outside, "x" });
    defer alloc.free(escaped);

    try std.Io.Dir.cwd().createDirPath(io, keg);
    try std.Io.Dir.cwd().createDirPath(io, outside);
    {
        const sf = try std.Io.Dir.createFileAbsolute(io, src, .{});
        defer sf.close(io);
        try sf.writeStreamingAll(io, "data");
    }
    try std.Io.Dir.symLinkAbsolute(io, outside, dirlink, .{});

    // keg is the only writable boundary, so base/outside is genuinely out of bounds.
    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    try std.testing.expectError(
        BuiltinError.PathSandboxViolation,
        cp(ctx, null, &.{ Value{ .string = src }, Value{ .string = dst } }),
    );
    // Nothing landed outside the keg.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, escaped, .{}));
}

test "ln_s refuses a target that points out of the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("fileutils_lns_target");
    defer s.deinit();
    const base = s.base;

    const keg = try std.fs.path.join(alloc, &.{ base, "keg" });
    defer alloc.free(keg);
    const outside = try std.fs.path.join(alloc, &.{ base, "outside" });
    defer alloc.free(outside);
    const link = try std.fs.path.join(alloc, &.{ keg, "d" });
    defer alloc.free(link);

    try std.Io.Dir.cwd().createDirPath(io, keg);
    try std.Io.Dir.cwd().createDirPath(io, outside);

    // Only the link path was screened before; an unscreened target turns the
    // keg into a doorway that later builtins traverse.
    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    try std.testing.expectError(
        BuiltinError.PathSandboxViolation,
        lnS(ctx, null, &.{ Value{ .string = outside }, Value{ .string = link } }),
    );
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, link, .{}));
}

test "ln_s still links to a target inside the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("fileutils_lns_ok");
    defer s.deinit();
    const keg = s.base;

    const target = try std.fs.path.join(alloc, &.{ keg, "real.txt" });
    defer alloc.free(target);
    const link = try std.fs.path.join(alloc, &.{ keg, "alias" });
    defer alloc.free(link);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, target, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "x");
    }

    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    _ = try lnS(ctx, null, &.{ Value{ .string = target }, Value{ .string = link } });
    try std.Io.Dir.cwd().access(io, link, .{});
}

test "ln_s refuses a target that reaches out through a planted directory symlink" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("fileutils_lns_dirlink");
    defer s.deinit();
    const base = s.base;

    const keg = try std.fs.path.join(alloc, &.{ base, "keg" });
    defer alloc.free(keg);
    const outside = try std.fs.path.join(alloc, &.{ base, "outside" });
    defer alloc.free(outside);
    const dirlink = try std.fs.path.join(alloc, &.{ keg, "d" });
    defer alloc.free(dirlink);
    // Lexically inside the keg, but `d` is a doorway the bottle shipped.
    const target = try std.fs.path.join(alloc, &.{ dirlink, "secret" });
    defer alloc.free(target);
    const link = try std.fs.path.join(alloc, &.{ keg, "alias" });
    defer alloc.free(link);

    try std.Io.Dir.cwd().createDirPath(io, keg);
    try std.Io.Dir.cwd().createDirPath(io, outside);
    try std.Io.Dir.symLinkAbsolute(io, outside, dirlink, .{});

    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    try std.testing.expectError(
        BuiltinError.PathSandboxViolation,
        lnS(ctx, null, &.{ Value{ .string = target }, Value{ .string = link } }),
    );
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, link, .{}));
}

test "rm_r refuses to delete through an intermediate-directory symlink out of the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("fileutils_rmr_dirlink");
    defer s.deinit();
    const base = s.base;

    const keg = try std.fs.path.join(alloc, &.{ base, "keg" });
    defer alloc.free(keg);
    const outside = try std.fs.path.join(alloc, &.{ base, "outside" });
    defer alloc.free(outside);
    const victim = try std.fs.path.join(alloc, &.{ outside, "precious" });
    defer alloc.free(victim);
    const dirlink = try std.fs.path.join(alloc, &.{ keg, "d" });
    defer alloc.free(dirlink);
    const through = try std.fs.path.join(alloc, &.{ dirlink, "precious" });
    defer alloc.free(through);

    try std.Io.Dir.cwd().createDirPath(io, keg);
    try std.Io.Dir.cwd().createDirPath(io, victim);
    // Planted directly: `ln_s` now refuses this, but a symlink can also arrive
    // inside the bottle itself, so the delete path must stand on its own.
    try std.Io.Dir.symLinkAbsolute(io, outside, dirlink, .{});

    // `cp`/`cp_r` already resolve intermediate symlinks; `rm_r` was still
    // lexical, so the same planted link reached outside the boundary.
    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    try std.testing.expectError(
        BuiltinError.PathSandboxViolation,
        rmR(ctx, null, &.{Value{ .string = through }}),
    );
    try std.Io.Dir.cwd().access(io, victim, .{});
}

test "rm_r still deletes a tree inside the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("fileutils_rmr_ok");
    defer s.deinit();
    const keg = s.base;

    const doomed = try std.fs.path.join(alloc, &.{ keg, "build" });
    defer alloc.free(doomed);
    try std.Io.Dir.cwd().createDirPath(io, doomed);

    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    _ = try rmR(ctx, null, &.{Value{ .string = doomed }});
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, doomed, .{}));
}

test "mkdir_p refuses to create through an intermediate-directory symlink out of the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("fileutils_mkdirp_dirlink");
    defer s.deinit();
    const base = s.base;

    const keg = try std.fs.path.join(alloc, &.{ base, "keg" });
    defer alloc.free(keg);
    const outside = try std.fs.path.join(alloc, &.{ base, "outside" });
    defer alloc.free(outside);
    const dirlink = try std.fs.path.join(alloc, &.{ keg, "d" });
    defer alloc.free(dirlink);
    const through = try std.fs.path.join(alloc, &.{ dirlink, "made" });
    defer alloc.free(through);
    const escaped = try std.fs.path.join(alloc, &.{ outside, "made" });
    defer alloc.free(escaped);

    try std.Io.Dir.cwd().createDirPath(io, keg);
    try std.Io.Dir.cwd().createDirPath(io, outside);
    try std.Io.Dir.symLinkAbsolute(io, outside, dirlink, .{});

    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    try std.testing.expectError(
        BuiltinError.PathSandboxViolation,
        mkdirP(ctx, null, &.{Value{ .string = through }}),
    );
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, escaped, .{}));
}

test "touch refuses to create through a symlink out of the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("fileutils_touch_symlink");
    defer s.deinit();
    const base = s.base;

    const keg = try std.fs.path.join(alloc, &.{ base, "keg" });
    defer alloc.free(keg);
    const target = try std.fs.path.join(alloc, &.{ base, "outside" }); // out of keg, never created
    defer alloc.free(target);
    const link = try std.fs.path.join(alloc, &.{ keg, "pwn" }); // keg/pwn -> base/outside
    defer alloc.free(link);

    try std.Io.Dir.cwd().createDirPath(io, keg);
    try std.Io.Dir.symLinkAbsolute(io, target, link, .{});

    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    try std.testing.expectError(
        BuiltinError.PathSandboxViolation,
        touch(ctx, null, &.{Value{ .string = link }}),
    );
    // The link's out-of-keg target was not created behind it.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, target, .{}));
}

test "chmod refuses to follow a symlink out of the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("fileutils_chmod_symlink");
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
    }
    try std.Io.Dir.symLinkAbsolute(io, victim, link, .{});
    // Snapshot the victim's mode so we can prove it was untouched.
    const before = (try std.Io.Dir.cwd().statFile(io, victim, .{})).permissions.toMode();

    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    try std.testing.expectError(
        BuiltinError.PathSandboxViolation,
        chmod(ctx, null, &.{ Value{ .int = 0o777 }, Value{ .string = link } }),
    );
    const after = (try std.Io.Dir.cwd().statFile(io, victim, .{})).permissions.toMode();
    try std.testing.expectEqual(before, after);
}

test "cp_r refuses a symlink planted deep in the dest subtree" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("fileutils_cpr_dst_deep_symlink");
    defer s.deinit();
    const base = s.base;

    const keg = try std.fs.path.join(alloc, &.{ base, "keg" });
    defer alloc.free(keg);
    const outside = try std.fs.path.join(alloc, &.{ base, "outside" });
    defer alloc.free(outside);

    // Source tree: src/sub/file.txt
    const src = try std.fs.path.join(alloc, &.{ keg, "src" });
    defer alloc.free(src);
    const src_file = try std.fs.path.join(alloc, &.{ keg, "src", "sub", "file.txt" });
    defer alloc.free(src_file);
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(src_file).?);
    {
        const sf = try std.Io.Dir.createFileAbsolute(io, src_file, .{});
        defer sf.close(io);
        try sf.writeStreamingAll(io, "secret");
    }

    // Dest tree with a planted symlink at dst/sub -> outside.
    const dst = try std.fs.path.join(alloc, &.{ keg, "dst" });
    defer alloc.free(dst);
    const dst_sub = try std.fs.path.join(alloc, &.{ keg, "dst", "sub" });
    defer alloc.free(dst_sub);
    const escaped = try std.fs.path.join(alloc, &.{ outside, "file.txt" });
    defer alloc.free(escaped);
    try std.Io.Dir.cwd().createDirPath(io, dst);
    try std.Io.Dir.cwd().createDirPath(io, outside);
    try std.Io.Dir.symLinkAbsolute(io, outside, dst_sub, .{}); // dst/sub -> outside

    // cp_r joins child paths on ctx.allocator (the per-formula arena in prod);
    // give it an arena here so the recursion's scratch paths are reclaimed.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: ExecCtx = .{ .allocator = arena.allocator(), .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    // cp_r swallows per-entry failures; the contract is that nothing escapes.
    _ = try cpR(ctx, null, &.{ Value{ .string = src }, Value{ .string = dst } });
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, escaped, .{}));
}

test "mv refuses to move a source from outside the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("fileutils_mv_src_outside");
    defer s.deinit();
    const base = s.base;

    const keg = try std.fs.path.join(alloc, &.{ base, "keg" });
    defer alloc.free(keg);
    const secret = try std.fs.path.join(alloc, &.{ base, "secret" }); // out of keg
    defer alloc.free(secret);
    const dst = try std.fs.path.join(alloc, &.{ keg, "loot" });
    defer alloc.free(dst);

    try std.Io.Dir.cwd().createDirPath(io, keg);
    {
        const sf = try std.Io.Dir.createFileAbsolute(io, secret, .{});
        defer sf.close(io);
        try sf.writeStreamingAll(io, "classified");
    }

    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    try std.testing.expectError(
        BuiltinError.PathSandboxViolation,
        mv(ctx, null, &.{ Value{ .string = secret }, Value{ .string = dst } }),
    );
    // rename (a destroy/relocate primitive) never fired: the out-of-keg source
    // still exists where it was, and nothing landed in the keg.
    try std.Io.Dir.cwd().access(io, secret, .{});
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, dst, .{}));
}

test "mv moves a regular file within the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("fileutils_mv_ok");
    defer s.deinit();
    const keg = s.base;

    const src = try std.fs.path.join(alloc, &.{ keg, "a.txt" });
    defer alloc.free(src);
    const dst = try std.fs.path.join(alloc, &.{ keg, "b.txt" });
    defer alloc.free(dst);
    {
        const sf = try std.Io.Dir.createFileAbsolute(io, src, .{});
        defer sf.close(io);
        try sf.writeStreamingAll(io, "data");
    }

    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    _ = try mv(ctx, null, &.{ Value{ .string = src }, Value{ .string = dst } });

    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, src, .{}));
    var rb: [8]u8 = undefined;
    const df = try std.Io.Dir.openFileAbsolute(io, dst, .{});
    defer df.close(io);
    try std.testing.expectEqualStrings("data", rb[0..try df.readPositionalAll(io, &rb, 0)]);
}

test "cp refuses to copy a source from outside the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("fileutils_cp_src_outside");
    defer s.deinit();
    const base = s.base;

    const keg = try std.fs.path.join(alloc, &.{ base, "keg" });
    defer alloc.free(keg);
    const secret = try std.fs.path.join(alloc, &.{ base, "secret" }); // out of keg
    defer alloc.free(secret);
    const dst = try std.fs.path.join(alloc, &.{ keg, "leak" });
    defer alloc.free(dst);

    try std.Io.Dir.cwd().createDirPath(io, keg);
    {
        const sf = try std.Io.Dir.createFileAbsolute(io, secret, .{});
        defer sf.close(io);
        try sf.writeStreamingAll(io, "TOPSECRET");
    }

    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    try std.testing.expectError(
        BuiltinError.PathSandboxViolation,
        cp(ctx, null, &.{ Value{ .string = secret }, Value{ .string = dst } }),
    );
    // Nothing was exfiltrated into the keg.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, dst, .{}));
}

test "cp refuses to read through a source symlink out of the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("fileutils_cp_src_symlink");
    defer s.deinit();
    const base = s.base;

    const keg = try std.fs.path.join(alloc, &.{ base, "keg" });
    defer alloc.free(keg);
    const secret = try std.fs.path.join(alloc, &.{ base, "secret" }); // out of keg
    defer alloc.free(secret);
    const link = try std.fs.path.join(alloc, &.{ keg, "link" }); // keg/link -> base/secret
    defer alloc.free(link);
    const dst = try std.fs.path.join(alloc, &.{ keg, "leak" });
    defer alloc.free(dst);

    try std.Io.Dir.cwd().createDirPath(io, keg);
    {
        const sf = try std.Io.Dir.createFileAbsolute(io, secret, .{});
        defer sf.close(io);
        try sf.writeStreamingAll(io, "TOPSECRET");
    }
    try std.Io.Dir.symLinkAbsolute(io, secret, link, .{});

    // The source path is literally in-keg, but its final component is a symlink
    // out of the keg: the no-follow read must refuse it, not chase the target.
    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    try std.testing.expectError(
        BuiltinError.PathSandboxViolation,
        cp(ctx, null, &.{ Value{ .string = link }, Value{ .string = dst } }),
    );
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, dst, .{}));
}

test "cp array branch skips an out-of-keg source but copies an in-keg one" {
    const io = std.Options.debug_io;
    var s = try Scratch.init("fileutils_cp_array_mixed");
    defer s.deinit();
    const base = s.base;

    // cp's array branch joins child paths on ctx.allocator; give it an arena.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const keg = try std.fs.path.join(alloc, &.{ base, "keg" });
    const good = try std.fs.path.join(alloc, &.{ keg, "good.txt" }); // in keg
    const secret = try std.fs.path.join(alloc, &.{ base, "secret" }); // out of keg
    const into = try std.fs.path.join(alloc, &.{ keg, "into" }); // dest dir
    const landed = try std.fs.path.join(alloc, &.{ into, "good.txt" });
    const escaped = try std.fs.path.join(alloc, &.{ into, "secret" });

    try std.Io.Dir.cwd().createDirPath(io, keg);
    {
        const gf = try std.Io.Dir.createFileAbsolute(io, good, .{});
        defer gf.close(io);
        try gf.writeStreamingAll(io, "GOOD");
    }
    {
        const sf = try std.Io.Dir.createFileAbsolute(io, secret, .{});
        defer sf.close(io);
        try sf.writeStreamingAll(io, "SECRET");
    }

    const items = [_]Value{ Value{ .string = good }, Value{ .string = secret } };
    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    // Best-effort per entry: the forbidden source is skipped, the rest succeed —
    // the call does not abort.
    _ = try cp(ctx, null, &.{ Value{ .array = &items }, Value{ .string = into } });

    var rb: [8]u8 = undefined;
    const df = try std.Io.Dir.openFileAbsolute(io, landed, .{});
    defer df.close(io);
    try std.testing.expectEqualStrings("GOOD", rb[0..try df.readPositionalAll(io, &rb, 0)]);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, escaped, .{}));
}

test "cp_r refuses to copy a source from outside the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("fileutils_cpr_src_outside");
    defer s.deinit();
    const base = s.base;

    const keg = try std.fs.path.join(alloc, &.{ base, "keg" });
    defer alloc.free(keg);
    const tree = try std.fs.path.join(alloc, &.{ base, "tree" }); // out-of-keg source dir
    defer alloc.free(tree);
    const tree_file = try std.fs.path.join(alloc, &.{ base, "tree", "f.txt" });
    defer alloc.free(tree_file);
    const dst = try std.fs.path.join(alloc, &.{ keg, "copy" });
    defer alloc.free(dst);

    try std.Io.Dir.cwd().createDirPath(io, tree);
    try std.Io.Dir.cwd().createDirPath(io, keg);
    {
        const tf = try std.Io.Dir.createFileAbsolute(io, tree_file, .{});
        defer tf.close(io);
        try tf.writeStreamingAll(io, "x");
    }

    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    try std.testing.expectError(
        BuiltinError.PathSandboxViolation,
        cpR(ctx, null, &.{ Value{ .string = tree }, Value{ .string = dst } }),
    );
    // Nothing was read into the keg.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, dst, .{}));
}

test "cp_r refuses to read a source symlink planted in the source subtree" {
    const io = std.Options.debug_io;
    var s = try Scratch.init("fileutils_cpr_src_symlink_leaf");
    defer s.deinit();
    const base = s.base;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const keg = try std.fs.path.join(alloc, &.{ base, "keg" });
    const secret = try std.fs.path.join(alloc, &.{ base, "secret" }); // out of keg
    const src = try std.fs.path.join(alloc, &.{ keg, "src" }); // in-keg source dir
    const link = try std.fs.path.join(alloc, &.{ keg, "src", "link" }); // src/link -> secret
    const dst = try std.fs.path.join(alloc, &.{ keg, "dst" });
    const leaked = try std.fs.path.join(alloc, &.{ keg, "dst", "link" });

    try std.Io.Dir.cwd().createDirPath(io, src);
    {
        const sf = try std.Io.Dir.createFileAbsolute(io, secret, .{});
        defer sf.close(io);
        try sf.writeStreamingAll(io, "LEAK");
    }
    try std.Io.Dir.symLinkAbsolute(io, secret, link, .{}); // planted in the source tree

    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    // cp_r swallows per-entry failures; the contract is that nothing was read in.
    _ = try cpR(ctx, null, &.{ Value{ .string = src }, Value{ .string = dst } });
    // The symlinked source leaf was not followed, so the secret never landed.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, leaked, .{}));
}

test "cp_r copies a directory tree within the keg" {
    const io = std.Options.debug_io;
    var s = try Scratch.init("fileutils_cpr_ok");
    defer s.deinit();
    const keg = s.base;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src = try std.fs.path.join(alloc, &.{ keg, "src" });
    const src_file = try std.fs.path.join(alloc, &.{ keg, "src", "sub", "file.txt" });
    const dst = try std.fs.path.join(alloc, &.{ keg, "dst" });
    const copied = try std.fs.path.join(alloc, &.{ keg, "dst", "sub", "file.txt" });

    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(src_file).?);
    {
        const sf = try std.Io.Dir.createFileAbsolute(io, src_file, .{});
        defer sf.close(io);
        try sf.writeStreamingAll(io, "hello");
    }

    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    _ = try cpR(ctx, null, &.{ Value{ .string = src }, Value{ .string = dst } });

    var rb: [8]u8 = undefined;
    const df = try std.Io.Dir.openFileAbsolute(io, copied, .{});
    defer df.close(io);
    try std.testing.expectEqualStrings("hello", rb[0..try df.readPositionalAll(io, &rb, 0)]);
}

test "mv refuses a source under an intermediate-directory symlink out of the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("fileutils_mv_src_dirlink");
    defer s.deinit();
    const base = s.base;

    const keg = try std.fs.path.join(alloc, &.{ base, "keg" });
    defer alloc.free(keg);
    const outside = try std.fs.path.join(alloc, &.{ base, "outside" });
    defer alloc.free(outside);
    const victim = try std.fs.path.join(alloc, &.{ base, "outside", "victim" });
    defer alloc.free(victim);
    const dirlink = try std.fs.path.join(alloc, &.{ keg, "d" }); // keg/d -> outside
    defer alloc.free(dirlink);
    const src = try std.fs.path.join(alloc, &.{ keg, "d", "victim" }); // literal in-keg, resolves out
    defer alloc.free(src);
    const dst = try std.fs.path.join(alloc, &.{ keg, "loot" });
    defer alloc.free(dst);

    try std.Io.Dir.cwd().createDirPath(io, keg);
    try std.Io.Dir.cwd().createDirPath(io, outside);
    {
        const vf = try std.Io.Dir.createFileAbsolute(io, victim, .{});
        defer vf.close(io);
        try vf.writeStreamingAll(io, "classified");
    }
    try std.Io.Dir.symLinkAbsolute(io, outside, dirlink, .{});

    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    try std.testing.expectError(
        BuiltinError.PathSandboxViolation,
        mv(ctx, null, &.{ Value{ .string = src }, Value{ .string = dst } }),
    );
    // The out-of-keg victim was neither moved nor destroyed.
    try std.Io.Dir.cwd().access(io, victim, .{});
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, dst, .{}));
}

test "mv refuses a destination under an intermediate-directory symlink out of the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("fileutils_mv_dst_dirlink");
    defer s.deinit();
    const base = s.base;

    const keg = try std.fs.path.join(alloc, &.{ base, "keg" });
    defer alloc.free(keg);
    const outside = try std.fs.path.join(alloc, &.{ base, "outside" });
    defer alloc.free(outside);
    const src = try std.fs.path.join(alloc, &.{ keg, "src.txt" }); // in-keg source
    defer alloc.free(src);
    const dirlink = try std.fs.path.join(alloc, &.{ keg, "d" }); // keg/d -> outside
    defer alloc.free(dirlink);
    const dst = try std.fs.path.join(alloc, &.{ keg, "d", "x" }); // literal in-keg, resolves out
    defer alloc.free(dst);
    const escaped = try std.fs.path.join(alloc, &.{ outside, "x" });
    defer alloc.free(escaped);

    try std.Io.Dir.cwd().createDirPath(io, keg);
    try std.Io.Dir.cwd().createDirPath(io, outside);
    {
        const sf = try std.Io.Dir.createFileAbsolute(io, src, .{});
        defer sf.close(io);
        try sf.writeStreamingAll(io, "data");
    }
    try std.Io.Dir.symLinkAbsolute(io, outside, dirlink, .{});

    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    try std.testing.expectError(
        BuiltinError.PathSandboxViolation,
        mv(ctx, null, &.{ Value{ .string = src }, Value{ .string = dst } }),
    );
    // The move never fired: nothing landed outside, and the source is intact.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, escaped, .{}));
    try std.Io.Dir.cwd().access(io, src, .{});
}

test "mv moves an in-keg symlink leaf, relinking it without following" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("fileutils_mv_symlink_leaf");
    defer s.deinit();
    const keg = s.base;

    // A final-component symlink source is acceptable for mv: rename relinks the
    // link entry itself, it does not read through it. The guard must not reject
    // it, and the moved entry must remain a symlink (not a dereferenced copy).
    const link = try std.fs.path.join(alloc, &.{ keg, "link" });
    defer alloc.free(link);
    const dst = try std.fs.path.join(alloc, &.{ keg, "moved" });
    defer alloc.free(dst);
    try std.Io.Dir.symLinkAbsolute(io, "/etc/hosts", link, .{});

    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    _ = try mv(ctx, null, &.{ Value{ .string = link }, Value{ .string = dst } });

    // The link entry moved; the destination is still a symlink to the same target.
    var lb: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.readLinkAbsolute(io, dst, &lb);
    try std.testing.expectEqualStrings("/etc/hosts", lb[0..n]);
}

test "cp refuses a source under an intermediate-directory symlink out of the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("fileutils_cp_src_dirlink");
    defer s.deinit();
    const base = s.base;

    const keg = try std.fs.path.join(alloc, &.{ base, "keg" });
    defer alloc.free(keg);
    const outside = try std.fs.path.join(alloc, &.{ base, "outside" });
    defer alloc.free(outside);
    const secret = try std.fs.path.join(alloc, &.{ base, "outside", "secret" });
    defer alloc.free(secret);
    const dirlink = try std.fs.path.join(alloc, &.{ keg, "d" }); // keg/d -> outside
    defer alloc.free(dirlink);
    const src = try std.fs.path.join(alloc, &.{ keg, "d", "secret" }); // literal in-keg, resolves out
    defer alloc.free(src);
    const dst = try std.fs.path.join(alloc, &.{ keg, "leak" });
    defer alloc.free(dst);

    try std.Io.Dir.cwd().createDirPath(io, keg);
    try std.Io.Dir.cwd().createDirPath(io, outside);
    {
        const sf = try std.Io.Dir.createFileAbsolute(io, secret, .{});
        defer sf.close(io);
        try sf.writeStreamingAll(io, "TOPSECRET");
    }
    try std.Io.Dir.symLinkAbsolute(io, outside, dirlink, .{});

    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    try std.testing.expectError(
        BuiltinError.PathSandboxViolation,
        cp(ctx, null, &.{ Value{ .string = src }, Value{ .string = dst } }),
    );
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, dst, .{}));
}

test "cp_r refuses to follow a symlinked directory in the source subtree" {
    const io = std.Options.debug_io;
    var s = try Scratch.init("fileutils_cpr_src_dirlink");
    defer s.deinit();
    const base = s.base;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const keg = try std.fs.path.join(alloc, &.{ base, "keg" });
    const outside = try std.fs.path.join(alloc, &.{ base, "outside" }); // out-of-keg dir
    const outside_file = try std.fs.path.join(alloc, &.{ base, "outside", "secret" });
    const src = try std.fs.path.join(alloc, &.{ keg, "src" }); // in-keg source dir
    const sublink = try std.fs.path.join(alloc, &.{ keg, "src", "sub" }); // src/sub -> outside
    const dst = try std.fs.path.join(alloc, &.{ keg, "dst" });
    const leaked = try std.fs.path.join(alloc, &.{ keg, "dst", "sub", "secret" });

    try std.Io.Dir.cwd().createDirPath(io, src);
    try std.Io.Dir.cwd().createDirPath(io, outside);
    {
        const of = try std.Io.Dir.createFileAbsolute(io, outside_file, .{});
        defer of.close(io);
        try of.writeStreamingAll(io, "LEAK");
    }
    try std.Io.Dir.symLinkAbsolute(io, outside, sublink, .{}); // symlinked dir planted in source

    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    _ = try cpR(ctx, null, &.{ Value{ .string = src }, Value{ .string = dst } });
    // The symlinked source directory was not descended into.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, leaked, .{}));
}

test "cp preserves the source file mode within the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("fileutils_cp_mode");
    defer s.deinit();
    const keg = s.base;

    // The no-follow read + atomic write must keep the executable bit that
    // copyFileAbsolute used to carry, or poured scripts would lose +x.
    const src = try std.fs.path.join(alloc, &.{ keg, "exec.sh" });
    defer alloc.free(src);
    const dst = try std.fs.path.join(alloc, &.{ keg, "copy.sh" });
    defer alloc.free(dst);
    {
        const sf = try std.Io.Dir.createFileAbsolute(io, src, .{});
        defer sf.close(io);
        try sf.writeStreamingAll(io, "#!script\n");
        try sf.setPermissions(io, std.Io.File.Permissions.fromMode(0o755));
    }

    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    _ = try cp(ctx, null, &.{ Value{ .string = src }, Value{ .string = dst } });

    const got = (try std.Io.Dir.cwd().statFile(io, dst, .{})).permissions.toMode();
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), got & 0o777);
}

test "cp copies a regular file within the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("fileutils_cp_ok");
    defer s.deinit();
    const keg = s.base;

    const src = try std.fs.path.join(alloc, &.{ keg, "src.txt" });
    defer alloc.free(src);
    const dst = try std.fs.path.join(alloc, &.{ keg, "dst.txt" });
    defer alloc.free(dst);
    {
        const sf = try std.Io.Dir.createFileAbsolute(io, src, .{});
        defer sf.close(io);
        try sf.writeStreamingAll(io, "hi");
    }

    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    _ = try cp(ctx, null, &.{ Value{ .string = src }, Value{ .string = dst } });

    var rb: [8]u8 = undefined;
    const df = try std.Io.Dir.openFileAbsolute(io, dst, .{});
    defer df.close(io);
    try std.testing.expectEqualStrings("hi", rb[0..try df.readPositionalAll(io, &rb, 0)]);
}

test "touch creates a regular file in the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("fileutils_touch_ok");
    defer s.deinit();
    const keg = s.base;

    const target = try std.fs.path.join(alloc, &.{ keg, "stamp" });
    defer alloc.free(target);

    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    _ = try touch(ctx, null, &.{Value{ .string = target }});
    try std.Io.Dir.cwd().access(io, target, .{}); // exists now
}

test "chmod changes the mode of a regular keg file" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("fileutils_chmod_ok");
    defer s.deinit();
    const keg = s.base;

    const file = try std.fs.path.join(alloc, &.{ keg, "script" });
    defer alloc.free(file);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file, .{});
        f.close(io);
    }

    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    _ = try chmod(ctx, null, &.{ Value{ .int = 0o755 }, Value{ .string = file } });

    const got = (try std.Io.Dir.cwd().statFile(io, file, .{})).permissions.toMode();
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), got & 0o777);
}

/// Copy a regular file `src` into `dst`, reading the source through an
/// `O_NOFOLLOW` handle so a symlinked source leaf cannot redirect the read out
/// of the keg, and landing the dest atomically (createFileAtomic + rename) so
/// the dst leaf is never followed either. `validatePath`/`validateWriteDir`
/// confine where bytes land; this confines where they come from. The caller is
/// responsible for validating the dest's containing directory.
///
/// Returns `NotRegularFile` when `src` is a directory (or other non-file) so
/// `cp_r` can fall through to a recursive walk; `PathSandboxViolation` when the
/// source escapes the keg. Other IO errors are swallowed, matching the
/// force-variant contract of this module.
fn copyFileConfined(
    io: std.Io,
    src: []const u8,
    dst: []const u8,
    cellar_path: []const u8,
    malt_prefix: []const u8,
) (sandbox.SandboxError || error{NotRegularFile})!void {
    const file = sandbox.openTargetNoFollow(io, src, cellar_path, malt_prefix, .{ .write = false }) catch |e| switch (e) {
        error.PathSandboxViolation => return error.PathSandboxViolation,
        else => return, // missing source or IO error: swallow, like copyFileAbsolute catch {}
    };
    var file_reader: std.Io.File.Reader = .init(file, io, &.{});
    defer file_reader.file.close(io);

    const st = file_reader.file.stat(io) catch return;
    if (st.kind != .file) return error.NotRegularFile;
    file_reader.size = st.size;

    var atomic_file = std.Io.Dir.cwd().createFileAtomic(io, dst, .{
        .permissions = st.permissions,
        .replace = true,
    }) catch return;
    defer atomic_file.deinit(io);

    var buffer: [1024]u8 = undefined;
    var file_writer = atomic_file.file.writer(io, &buffer);
    _ = file_writer.interface.sendFileAll(&file_reader, .unlimited) catch return;
    file_writer.flush() catch return;
    atomic_file.replace(io) catch return;
}

fn copyDirRecursive(io: std.Io, allocator: std.mem.Allocator, src: []const u8, dst: []const u8, cellar_path: []const u8, malt_prefix: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(io, dst) catch {};
    // Per level: refuse to descend if dst resolves out of the keg, so a symlink
    // planted anywhere in the dest subtree can't redirect the copy. Files land
    // directly in dst (validated here) and replace any leaf symlink atomically.
    sandbox.validateDirTarget(io, dst, cellar_path, malt_prefix) catch return;
    // Symmetric source guard: refuse to read through a src dir that resolves out
    // of the keg, so a symlinked directory planted in the source subtree can't
    // redirect the read walk. A symlinked *file* leaf is caught below by the
    // no-follow per-file copy.
    sandbox.validateDirTarget(io, src, cellar_path, malt_prefix) catch return;

    var dir = std.Io.Dir.openDirAbsolute(io, src, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        const src_child = std.fs.path.join(allocator, &.{ src, entry.name }) catch continue;
        const dst_child = std.fs.path.join(allocator, &.{ dst, entry.name }) catch continue;

        if (entry.kind == .directory) {
            try copyDirRecursive(io, allocator, src_child, dst_child, cellar_path, malt_prefix);
        } else {
            copyFileConfined(io, src_child, dst_child, cellar_path, malt_prefix) catch {};
        }
    }
}

test "ln_s keeps a relative in-keg target instead of aborting" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("lns_relative_target");
    defer s.deinit();
    const keg = s.base;

    // `ln_s "../libexec/tool", bin/"tool"` is ordinary Homebrew shorthand: the
    // target is relative so the link survives the keg being relocated.
    const libexec = try std.fs.path.join(alloc, &.{ keg, "libexec" });
    defer alloc.free(libexec);
    const bin = try std.fs.path.join(alloc, &.{ keg, "bin" });
    defer alloc.free(bin);
    try std.Io.Dir.cwd().createDirPath(io, libexec);
    try std.Io.Dir.cwd().createDirPath(io, bin);
    const real = try std.fs.path.join(alloc, &.{ libexec, "tool" });
    defer alloc.free(real);
    (try std.Io.Dir.createFileAbsolute(io, real, .{})).close(io);
    const link = try std.fs.path.join(alloc, &.{ bin, "tool" });
    defer alloc.free(link);

    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    _ = try lnS(ctx, null, &.{ Value{ .string = "../libexec/tool" }, Value{ .string = link } });

    // Stored verbatim, and it resolves to the real file.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.cwd().readLink(io, link, &buf);
    try std.testing.expectEqualStrings("../libexec/tool", buf[0..n]);
    try std.Io.Dir.cwd().access(io, link, .{});
}

test "ln_sf keeps a relative in-keg target instead of aborting" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("lnsf_relative_target");
    defer s.deinit();
    const keg = s.base;

    const libexec = try std.fs.path.join(alloc, &.{ keg, "libexec" });
    defer alloc.free(libexec);
    const bin = try std.fs.path.join(alloc, &.{ keg, "bin" });
    defer alloc.free(bin);
    try std.Io.Dir.cwd().createDirPath(io, libexec);
    try std.Io.Dir.cwd().createDirPath(io, bin);
    const real = try std.fs.path.join(alloc, &.{ libexec, "tool" });
    defer alloc.free(real);
    (try std.Io.Dir.createFileAbsolute(io, real, .{})).close(io);
    const link = try std.fs.path.join(alloc, &.{ bin, "tool" });
    defer alloc.free(link);

    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    _ = try lnSf(ctx, null, &.{ Value{ .string = "../libexec/tool" }, Value{ .string = link } });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.cwd().readLink(io, link, &buf);
    try std.testing.expectEqualStrings("../libexec/tool", buf[0..n]);
}

test "ln_s refuses a relative target that escapes the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("lns_relative_escape");
    defer s.deinit();
    const base = s.base;

    const keg = try std.fs.path.join(alloc, &.{ base, "keg" });
    defer alloc.free(keg);
    const bin = try std.fs.path.join(alloc, &.{ keg, "bin" });
    defer alloc.free(bin);
    try std.Io.Dir.cwd().createDirPath(io, bin);
    const link = try std.fs.path.join(alloc, &.{ bin, "pwn" });
    defer alloc.free(link);

    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    // Relative spelling must not become a way around the boundary check, and
    // must be refused rather than abort the process.
    try std.testing.expectError(
        BuiltinError.PathSandboxViolation,
        lnS(ctx, null, &.{ Value{ .string = "../../outside" }, Value{ .string = link } }),
    );
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, link, .{}));
}

test "ln_sf refuses a relative target that escapes the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("lnsf_relative_escape");
    defer s.deinit();
    const base = s.base;

    const keg = try std.fs.path.join(alloc, &.{ base, "keg" });
    defer alloc.free(keg);
    const bin = try std.fs.path.join(alloc, &.{ keg, "bin" });
    defer alloc.free(bin);
    try std.Io.Dir.cwd().createDirPath(io, bin);
    const link = try std.fs.path.join(alloc, &.{ bin, "pwn" });
    defer alloc.free(link);

    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    try std.testing.expectError(
        BuiltinError.PathSandboxViolation,
        lnSf(ctx, null, &.{ Value{ .string = "../../outside" }, Value{ .string = link } }),
    );
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, link, .{}));
}

test "ln_sf leaves no link for an empty target" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var s = try Scratch.init("lnsf_empty_target");
    defer s.deinit();
    const keg = s.base;

    const link = try std.fs.path.join(alloc, &.{ keg, "tool" });
    defer alloc.free(link);
    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    // `ln_s` guards this arg but the force variant does not; it must still be
    // an inert no-op rather than a crash or an empty dangling link.
    _ = try lnSf(ctx, null, &.{ Value{ .string = "" }, Value{ .string = link } });
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, link, .{}));
}
