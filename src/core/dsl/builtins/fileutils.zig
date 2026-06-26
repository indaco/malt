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
                sandbox.validatePath(path, ctx.cellar_path, ctx.malt_prefix) catch continue;
                std.Io.Dir.cwd().deleteFile(ctx.io, path) catch {};
            }
        },
        else => {
            const path = try args[0].asString(ctx.allocator);
            sandbox.validatePath(path, ctx.cellar_path, ctx.malt_prefix) catch
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
    sandbox.validatePath(path, ctx.cellar_path, ctx.malt_prefix) catch
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
    sandbox.validatePath(path, ctx.cellar_path, ctx.malt_prefix) catch
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
                std.Io.Dir.copyFileAbsolute(src, dest_path, ctx.io, .{}) catch {};
            }
        },
        else => {
            const src = args[0].asString(ctx.allocator) catch return Value{ .nil = {} };
            std.Io.Dir.copyFileAbsolute(src, dst, ctx.io, .{}) catch {};
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

    // Try as single file first
    std.Io.Dir.copyFileAbsolute(src, dst, ctx.io, .{}) catch {
        // Try as directory: walk and copy
        copyDirRecursive(ctx.io, ctx.allocator, src, dst, ctx.cellar_path, ctx.malt_prefix) catch {};
    };
    return Value{ .nil = {} };
}

/// mv — move/rename
pub fn mv(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len < 2) return Value{ .nil = {} };
    const src = try args[0].asString(ctx.allocator);
    const dst = try args[1].asString(ctx.allocator);
    sandbox.validatePath(dst, ctx.cellar_path, ctx.malt_prefix) catch
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
    const mode: std.posix.mode_t = @intCast(@as(u32, @bitCast(@as(i32, @intCast(mode_val)))));

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
    sandbox.validatePath(link_path, ctx.cellar_path, ctx.malt_prefix) catch
        return BuiltinError.PathSandboxViolation;

    if (std.fs.path.dirname(link_path)) |parent| {
        std.Io.Dir.cwd().createDirPath(ctx.io, parent) catch {};
    }
    std.Io.Dir.symLinkAbsolute(ctx.io, target, link_path, .{}) catch {};
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
            sandbox.validatePath(dest_dir, ctx.cellar_path, ctx.malt_prefix) catch
                return BuiltinError.PathSandboxViolation;
            std.Io.Dir.cwd().createDirPath(ctx.io, dest_dir) catch {};
            for (items) |item| {
                const target = item.asString(ctx.allocator) catch continue;
                const base = std.fs.path.basename(target);
                const link_path = std.fs.path.join(ctx.allocator, &.{ dest_dir, base }) catch continue;
                std.Io.Dir.cwd().deleteFile(ctx.io, link_path) catch {};
                std.Io.Dir.symLinkAbsolute(ctx.io, target, link_path, .{}) catch {};
            }
        },
        else => {
            const target = try args[0].asString(ctx.allocator);
            const link_path = try args[1].asString(ctx.allocator);
            sandbox.validatePath(link_path, ctx.cellar_path, ctx.malt_prefix) catch
                return BuiltinError.PathSandboxViolation;

            if (std.fs.path.dirname(link_path)) |parent| {
                std.Io.Dir.cwd().createDirPath(ctx.io, parent) catch {};
            }
            std.Io.Dir.cwd().deleteFile(ctx.io, link_path) catch {};
            std.Io.Dir.symLinkAbsolute(ctx.io, target, link_path, .{}) catch {};
        },
    }
    return Value{ .nil = {} };
}

test "cp refuses to copy through an intermediate-directory symlink out of the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var bb: [std.fs.max_path_bytes]u8 = undefined;
    const base = bb[0..try std.Io.Dir.realPath(tmp.dir, io, &bb)];

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

test "touch refuses to create through a symlink out of the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var bb: [std.fs.max_path_bytes]u8 = undefined;
    const base = bb[0..try std.Io.Dir.realPath(tmp.dir, io, &bb)];

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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var bb: [std.fs.max_path_bytes]u8 = undefined;
    const base = bb[0..try std.Io.Dir.realPath(tmp.dir, io, &bb)];

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

test "cp copies a regular file within the keg" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var bb: [std.fs.max_path_bytes]u8 = undefined;
    const keg = bb[0..try std.Io.Dir.realPath(tmp.dir, io, &bb)];

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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var bb: [std.fs.max_path_bytes]u8 = undefined;
    const keg = bb[0..try std.Io.Dir.realPath(tmp.dir, io, &bb)];

    const target = try std.fs.path.join(alloc, &.{ keg, "stamp" });
    defer alloc.free(target);

    const ctx: ExecCtx = .{ .allocator = alloc, .io = io, .environ = undefined, .cellar_path = keg, .malt_prefix = keg };
    _ = try touch(ctx, null, &.{Value{ .string = target }});
    try std.Io.Dir.cwd().access(io, target, .{}); // exists now
}

test "chmod changes the mode of a regular keg file" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var bb: [std.fs.max_path_bytes]u8 = undefined;
    const keg = bb[0..try std.Io.Dir.realPath(tmp.dir, io, &bb)];

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

fn copyDirRecursive(io: std.Io, allocator: std.mem.Allocator, src: []const u8, dst: []const u8, cellar_path: []const u8, malt_prefix: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(io, dst) catch {};
    // Per level: refuse to descend if dst resolves out of the keg, so a symlink
    // planted anywhere in the dest subtree can't redirect the copy. Files land
    // directly in dst (validated here) and replace any leaf symlink atomically.
    sandbox.validateDirTarget(io, dst, cellar_path, malt_prefix) catch return;

    var dir = std.Io.Dir.openDirAbsolute(io, src, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        const src_child = std.fs.path.join(allocator, &.{ src, entry.name }) catch continue;
        const dst_child = std.fs.path.join(allocator, &.{ dst, entry.name }) catch continue;

        if (entry.kind == .directory) {
            try copyDirRecursive(io, allocator, src_child, dst_child, cellar_path, malt_prefix);
        } else {
            std.Io.Dir.copyFileAbsolute(src_child, dst_child, io, .{}) catch {};
        }
    }
}
