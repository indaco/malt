//! malt — nuclear wipe path: plan construction, manifest writing, and
//! the orchestrator that executes a built plan under a single lock.

const std = @import("std");
const fs_compat = @import("../../fs/compat.zig");
const sqlite = @import("../../db/sqlite.zig");
const atomic = @import("../../fs/atomic.zig");
const output = @import("../../ui/output.zig");
const lock_mod = @import("../../db/lock.zig");
const backup_mod = @import("../backup.zig");
const args_mod = @import("args.zig");
const util = @import("util.zig");

const Error = args_mod.Error;
const Options = args_mod.Options;
const Target = args_mod.Target;

pub fn buildPlan(
    allocator: std.mem.Allocator,
    opts: Options,
    prefix: []const u8,
    cache_dir: []const u8,
) Error![]Target {
    var list: std.ArrayList(Target) = .empty;
    errdefer freeList(allocator, &list);

    const linked = [_][]const u8{ "bin", "sbin", "lib", "include", "share", "etc" };
    for (linked) |name| {
        const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name }) catch return Error.OutOfMemory;
        list.append(allocator, .{ .path = path, .category = .linked_dir }) catch return Error.OutOfMemory;
    }

    list.append(allocator, .{
        .path = std.fmt.allocPrint(allocator, "{s}/opt", .{prefix}) catch return Error.OutOfMemory,
        .category = .opt,
    }) catch return Error.OutOfMemory;
    list.append(allocator, .{
        .path = std.fmt.allocPrint(allocator, "{s}/Cellar", .{prefix}) catch return Error.OutOfMemory,
        .category = .cellar,
    }) catch return Error.OutOfMemory;
    list.append(allocator, .{
        .path = std.fmt.allocPrint(allocator, "{s}/Caskroom", .{prefix}) catch return Error.OutOfMemory,
        .category = .caskroom,
    }) catch return Error.OutOfMemory;
    list.append(allocator, .{
        .path = std.fmt.allocPrint(allocator, "{s}/store", .{prefix}) catch return Error.OutOfMemory,
        .category = .store,
    }) catch return Error.OutOfMemory;

    if (!opts.keep_cache) {
        const dup = allocator.dupe(u8, cache_dir) catch return Error.OutOfMemory;
        list.append(allocator, .{ .path = dup, .category = .cache }) catch return Error.OutOfMemory;
    }

    list.append(allocator, .{
        .path = std.fmt.allocPrint(allocator, "{s}/tmp", .{prefix}) catch return Error.OutOfMemory,
        .category = .tmp,
    }) catch return Error.OutOfMemory;
    list.append(allocator, .{
        .path = std.fmt.allocPrint(allocator, "{s}/db", .{prefix}) catch return Error.OutOfMemory,
        .category = .db,
    }) catch return Error.OutOfMemory;
    list.append(allocator, .{
        .path = allocator.dupe(u8, prefix) catch return Error.OutOfMemory,
        .category = .prefix_root,
    }) catch return Error.OutOfMemory;

    if (opts.remove_binary) {
        const bin_paths = [_][]const u8{ "/usr/local/bin/mt", "/usr/local/bin/malt" };
        for (bin_paths) |p| {
            const dup = allocator.dupe(u8, p) catch return Error.OutOfMemory;
            list.append(allocator, .{ .path = dup, .category = .binary }) catch return Error.OutOfMemory;
        }
    }

    return list.toOwnedSlice(allocator) catch return Error.OutOfMemory;
}

pub fn freePlan(allocator: std.mem.Allocator, plan: []const Target) void {
    for (plan) |t| allocator.free(t.path);
    allocator.free(plan);
}

fn freeList(allocator: std.mem.Allocator, list: *std.ArrayList(Target)) void {
    for (list.items) |t| allocator.free(t.path);
    list.deinit(allocator);
}

fn warnBanner() void {
    const rule = "────────────────────────────────────────────────────────────";
    output.warnPlain("{s}", .{rule});
    output.warnPlain("WARNING: this will permanently wipe your malt installation.", .{});
    output.warnPlain("{s}", .{rule});
}

pub fn writeManifest(allocator: std.mem.Allocator, path: []const u8) Error!void {
    const prefix = atomic.maltPrefix();
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return Error.DatabaseError;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    backup_mod.writeHeader(w) catch return Error.WriteFailed;

    if (sqlite.Database.open(db_path)) |*db_val| {
        var db = db_val.*;
        defer db.close();

        var fstmt = db.prepare(
            "SELECT name, version FROM kegs WHERE install_reason = 'direct' ORDER BY name;",
        ) catch null;
        if (fstmt) |*s| {
            defer s.finalize();
            while (s.step() catch false) {
                const name_ptr = s.columnText(0) orelse continue;
                const ver_ptr = s.columnText(1);
                const name = std.mem.sliceTo(name_ptr, 0);
                const version = if (ver_ptr) |p| std.mem.sliceTo(p, 0) else "";
                backup_mod.writeEntry(w, .formula, name, version, true) catch return Error.WriteFailed;
            }
        }

        var cstmt = db.prepare("SELECT token, version FROM casks ORDER BY token;") catch null;
        if (cstmt) |*s| {
            defer s.finalize();
            while (s.step() catch false) {
                const name_ptr = s.columnText(0) orelse continue;
                const ver_ptr = s.columnText(1);
                const name = std.mem.sliceTo(name_ptr, 0);
                const version = if (ver_ptr) |p| std.mem.sliceTo(p, 0) else "";
                backup_mod.writeEntry(w, .cask, name, version, true) catch return Error.WriteFailed;
            }
        }
    } else |_| {}

    try writeBytesToPath(path, aw.written());
}

fn writeBytesToPath(path: []const u8, bytes: []const u8) Error!void {
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0) {
            // Parent may already exist; the subsequent createFile reports real errors.
            if (std.fs.path.isAbsolute(dir)) {
                fs_compat.makeDirAbsolute(dir) catch {};
            } else {
                fs_compat.cwd().makePath(dir) catch {};
            }
        }
    }
    const file = if (std.fs.path.isAbsolute(path))
        fs_compat.createFileAbsolute(path, .{ .truncate = true }) catch return Error.OpenFileFailed
    else
        fs_compat.cwd().createFile(path, .{ .truncate = true }) catch return Error.OpenFileFailed;
    defer file.close();
    file.writeAll(bytes) catch return Error.WriteFailed;
}

pub fn deleteTarget(path: []const u8) bool {
    fs_compat.deleteTreeAbsolute(path) catch {
        output.warn("could not remove {s}", .{path});
        return false;
    };
    return true;
}

pub fn deletePrefixRoot(path: []const u8) bool {
    fs_compat.deleteDirAbsolute(path) catch |e| switch (e) {
        error.FileNotFound => return true,
        error.DirNotEmpty => {
            output.info("prefix {s} not empty — leaving it in place", .{path});
            return false;
        },
        else => {
            output.warn("could not remove prefix {s}", .{path});
            return false;
        },
    };
    return true;
}

pub fn verifyWipe(plan: []const Target) void {
    var leaks: usize = 0;
    for (plan) |t| {
        if (t.category == .prefix_root) continue;
        fs_compat.accessAbsolute(t.path, .{}) catch continue;
        output.warn("verification: {s} still present", .{t.path});
        leaks += 1;
    }
    if (leaks == 0) {
        output.info("verification: all targeted paths are gone", .{});
    }
}

pub fn runWipe(allocator: std.mem.Allocator, opts: Options, prefix: []const u8, cache_dir: []const u8, dry_run: bool) !void {
    warnBanner();
    output.dimPlain("prefix:  {s}", .{prefix});
    output.dimPlain("cache:   {s}", .{cache_dir});
    if (opts.keep_cache) output.dimPlain("keep-cache: on", .{});
    if (opts.remove_binary) output.dimPlain("remove-binary: on (/usr/local/bin/{{mt,malt}})", .{});

    const plan = try buildPlan(allocator, opts, prefix, cache_dir);
    defer freePlan(allocator, plan);

    var total_bytes: u64 = 0;
    for (plan) |t| {
        const size = util.pathSize(allocator, t.path);
        total_bytes += size;
        var sz_buf: [32]u8 = undefined;
        const sz = util.formatBytes(size, &sz_buf);
        output.plain("  [{s:<8}] {s} ({s})", .{ t.category.label(), t.path, sz });
    }
    {
        var buf: [64]u8 = undefined;
        const total_str = util.formatBytes(total_bytes, &buf);
        output.boldPlain("total: {s}", .{total_str});
    }

    if (opts.backup_path) |bp| {
        if (dry_run) {
            output.info("would write backup manifest to {s}", .{bp});
        } else {
            try writeManifest(allocator, bp);
            output.success("backup manifest written to {s}", .{bp});
        }
    }

    if (dry_run) {
        output.info("dry run — nothing was removed", .{});
        return;
    }

    try util.confirmScope(opts.yes, "purge", "wipe");

    var lock_path_buf: [512]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_path_buf, "{s}/db/malt.lock", .{prefix}) catch return;
    var lk_maybe: ?lock_mod.LockFile = lock_mod.LockFile.acquire(lock_path, 30_000) catch null;

    var removed: usize = 0;
    var skipped: usize = 0;
    var db_idx: ?usize = null;
    var prefix_idx: ?usize = null;

    for (plan, 0..) |t, idx| {
        switch (t.category) {
            .db => {
                db_idx = idx;
                continue;
            },
            .prefix_root => {
                prefix_idx = idx;
                continue;
            },
            else => {},
        }
        if (deleteTarget(t.path)) removed += 1 else skipped += 1;
    }

    if (lk_maybe) |*lk| lk.release();

    if (db_idx) |idx| {
        if (deleteTarget(plan[idx].path)) removed += 1 else skipped += 1;
    }
    if (prefix_idx) |idx| {
        if (deletePrefixRoot(plan[idx].path)) removed += 1 else skipped += 1;
    }

    verifyWipe(plan);

    var sum_buf: [128]u8 = undefined;
    const sum = std.fmt.bufPrint(&sum_buf, "removed {d} target(s), skipped {d}", .{ removed, skipped }) catch "";
    output.success("{s}", .{sum});
}
