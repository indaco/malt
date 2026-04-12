//! malt — DSL builtin: FileUtils operations
//! Maps Ruby FileUtils module calls to std.fs operations.
//! All mutating operations go through sandbox.validatePath first.

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
                std.fs.cwd().deleteFile(path) catch {};
            }
        },
        else => {
            const path = try args[0].asString(ctx.allocator);
            sandbox.validatePath(path, ctx.cellar_path, ctx.malt_prefix) catch
                return BuiltinError.PathSandboxViolation;
            std.fs.cwd().deleteFile(path) catch {};
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
    std.fs.cwd().deleteTree(path) catch {};
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
    std.fs.cwd().makePath(path) catch {};
    return Value{ .nil = {} };
}

/// cp — copy file(s). First arg can be a single path or an array of paths.
pub fn cp(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len < 2) return Value{ .nil = {} };
    const dst = try args[1].asString(ctx.allocator);
    sandbox.validatePath(dst, ctx.cellar_path, ctx.malt_prefix) catch
        return BuiltinError.PathSandboxViolation;

    // If first arg is an array, copy each file into dst directory
    switch (args[0]) {
        .array => |items| {
            std.fs.cwd().makePath(dst) catch {};
            for (items) |item| {
                const src = item.asString(ctx.allocator) catch continue;
                const base = std.fs.path.basename(src);
                const dest_path = std.fs.path.join(ctx.allocator, &.{ dst, base }) catch continue;
                std.fs.copyFileAbsolute(src, dest_path, .{}) catch {};
            }
        },
        else => {
            const src = args[0].asString(ctx.allocator) catch return Value{ .nil = {} };
            std.fs.copyFileAbsolute(src, dst, .{}) catch {};
        },
    }
    return Value{ .nil = {} };
}

/// cp_r — copy recursively
pub fn cpR(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len < 2) return Value{ .nil = {} };
    const src = try args[0].asString(ctx.allocator);
    const dst = try args[1].asString(ctx.allocator);
    sandbox.validatePath(dst, ctx.cellar_path, ctx.malt_prefix) catch
        return BuiltinError.PathSandboxViolation;

    // Try as single file first
    std.fs.copyFileAbsolute(src, dst, .{}) catch {
        // Try as directory: walk and copy
        copyDirRecursive(ctx.allocator, src, dst) catch {};
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
    std.fs.renameAbsolute(src, dst) catch {};
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
            for (items) |item| {
                const p = item.asString(ctx.allocator) catch continue;
                sandbox.validatePath(p, ctx.cellar_path, ctx.malt_prefix) catch continue;
                chmodPath(p, mode);
            }
        },
        else => {
            const path = args[1].asString(ctx.allocator) catch return Value{ .nil = {} };
            sandbox.validatePath(path, ctx.cellar_path, ctx.malt_prefix) catch
                return BuiltinError.PathSandboxViolation;
            chmodPath(path, mode);
        },
    }
    return Value{ .nil = {} };
}

fn chmodPath(path: []const u8, mode: std.posix.mode_t) void {
    const file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch return;
    defer file.close();
    file.chmod(mode) catch {};
}

/// touch — create file or update timestamp
pub fn touch(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len == 0) return Value{ .nil = {} };
    const path = try args[0].asString(ctx.allocator);
    sandbox.validatePath(path, ctx.cellar_path, ctx.malt_prefix) catch
        return BuiltinError.PathSandboxViolation;

    // Try to open existing file, or create
    const file = std.fs.createFileAbsolute(path, .{ .truncate = false }) catch {
        return Value{ .nil = {} };
    };
    file.close();
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
        std.fs.cwd().makePath(parent) catch {};
    }
    std.fs.symLinkAbsolute(target, link_path, .{}) catch {};
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
            std.fs.cwd().makePath(dest_dir) catch {};
            for (items) |item| {
                const target = item.asString(ctx.allocator) catch continue;
                const base = std.fs.path.basename(target);
                const link_path = std.fs.path.join(ctx.allocator, &.{ dest_dir, base }) catch continue;
                std.fs.cwd().deleteFile(link_path) catch {};
                std.fs.symLinkAbsolute(target, link_path, .{}) catch {};
            }
        },
        else => {
            const target = try args[0].asString(ctx.allocator);
            const link_path = try args[1].asString(ctx.allocator);
            sandbox.validatePath(link_path, ctx.cellar_path, ctx.malt_prefix) catch
                return BuiltinError.PathSandboxViolation;

            if (std.fs.path.dirname(link_path)) |parent| {
                std.fs.cwd().makePath(parent) catch {};
            }
            std.fs.cwd().deleteFile(link_path) catch {};
            std.fs.symLinkAbsolute(target, link_path, .{}) catch {};
        },
    }
    return Value{ .nil = {} };
}

fn copyDirRecursive(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    std.fs.cwd().makePath(dst) catch {};

    var dir = std.fs.openDirAbsolute(src, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        const src_child = std.fs.path.join(allocator, &.{ src, entry.name }) catch continue;
        const dst_child = std.fs.path.join(allocator, &.{ dst, entry.name }) catch continue;

        if (entry.kind == .directory) {
            try copyDirRecursive(allocator, src_child, dst_child);
        } else {
            std.fs.copyFileAbsolute(src_child, dst_child, .{}) catch {};
        }
    }
}
