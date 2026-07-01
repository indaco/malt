//! malt — nuclear wipe path: plan construction, manifest writing, and
//! the orchestrator that executes a built plan under a single lock.

const std = @import("std");
const AppCtx = @import("../../app_ctx.zig").AppCtx;
const sqlite = @import("../../db/sqlite.zig");
const atomic = @import("../../fs/atomic.zig");
const path_write = @import("../../fs/path_write.zig");
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

pub fn writeManifest(ctx: *const AppCtx, allocator: std.mem.Allocator, path: []const u8) Error!void {
    const prefix = atomic.maltPrefixOrAbort();
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

    try writeBytesToPath(ctx, path, aw.written());
}

fn writeBytesToPath(ctx: *const AppCtx, path: []const u8, bytes: []const u8) Error!void {
    // Silent mapping — the outer wipe command reports; a parent-dir failure
    // and an open failure are both "couldn't create the manifest".
    path_write.writeFile(ctx.io, path, bytes) catch |e| switch (e) {
        error.MakeParentDirFailed, error.OpenFileFailed => return Error.OpenFileFailed,
        error.WriteFailed => return Error.WriteFailed,
    };
}

pub fn deleteTarget(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().deleteTree(io, path) catch {
        output.warn("could not remove {s}", .{path});
        return false;
    };
    return true;
}

pub fn deletePrefixRoot(io: std.Io, path: []const u8) bool {
    std.Io.Dir.deleteDirAbsolute(io, path) catch |e| switch (e) {
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

pub fn verifyWipe(io: std.Io, plan: []const Target) void {
    var leaks: usize = 0;
    for (plan) |t| {
        if (t.category == .prefix_root) continue;
        std.Io.Dir.accessAbsolute(io, t.path, .{}) catch continue;
        output.warn("verification: {s} still present", .{t.path});
        leaks += 1;
    }
    if (leaks == 0) {
        output.info("verification: all targeted paths are gone", .{});
    }
}

/// Same idempotency contract as `accessAbsolute`: a missing path is not
/// an error, just absent.
fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

pub fn runWipe(ctx: *const AppCtx, allocator: std.mem.Allocator, opts: Options, prefix: []const u8, cache_dir: []const u8, dry_run: bool) !util.TierResult {
    warnBanner();
    output.dimPlain("prefix:  {s}", .{prefix});
    output.dimPlain("cache:   {s}", .{cache_dir});
    if (opts.keep_cache) output.dimPlain("keep-cache: on", .{});
    if (opts.remove_binary) output.dimPlain("remove-binary: on (/usr/local/bin/{{mt,malt}})", .{});

    const plan = try buildPlan(allocator, opts, prefix, cache_dir);
    defer freePlan(allocator, plan);

    const io = ctx.io;

    // Pre-flight stat: track which plan entries already hold data so the
    // JSON `removed` counter reflects paths that would actually be freed.
    // Without this, deleteTree's idempotent success on missing paths
    // would inflate the count to plan.len on a half-installed prefix.
    const existed = try allocator.alloc(bool, plan.len);
    defer allocator.free(existed);
    // Per-path preflight sizes so a failed delete can be excluded from the
    // freed-byte total; `total_bytes` stays the "bytes present" figure used
    // by the dry-run return and the pre-flight "total:" display line.
    const sizes = try allocator.alloc(u64, plan.len);
    defer allocator.free(sizes);

    var total_bytes: u64 = 0;
    var existing_count: u32 = 0;
    for (plan, 0..) |t, idx| {
        existed[idx] = pathExists(io, t.path);
        const size = if (existed[idx]) util.pathSize(io, allocator, t.path) else 0;
        sizes[idx] = size;
        total_bytes += size;
        if (existed[idx]) existing_count += 1;
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
            try writeManifest(ctx, allocator, bp);
            output.success("backup manifest written to {s}", .{bp});
        }
    }

    if (dry_run) {
        output.info("dry run — nothing was removed", .{});
        return .{ .removed = existing_count, .bytes = total_bytes };
    }

    try util.confirmScope(opts.yes, "purge", "wipe");

    var lock_path_buf: [512]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_path_buf, "{s}/db/malt.lock", .{prefix}) catch return .{};
    var lk_maybe: ?lock_mod.LockFile = lock_mod.LockFile.acquire(ctx.io, lock_path, 30_000) catch null;

    var removed: usize = 0;
    var skipped: usize = 0;
    var freed_paths: u32 = 0;
    // Mirror of the freed-path decision, indexed by plan slot, so the byte
    // total credits exactly the targets the path count does.
    const freed = try allocator.alloc(bool, plan.len);
    defer allocator.free(freed);
    @memset(freed, false);
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
        if (deleteTarget(io, t.path)) {
            removed += 1;
            if (existed[idx]) {
                freed_paths += 1;
                freed[idx] = true;
            }
        } else skipped += 1;
    }

    if (lk_maybe) |*lk| lk.release(ctx.io);

    if (db_idx) |idx| {
        if (deleteTarget(io, plan[idx].path)) {
            removed += 1;
            if (existed[idx]) {
                freed_paths += 1;
                freed[idx] = true;
            }
        } else skipped += 1;
    }
    if (prefix_idx) |idx| {
        if (deletePrefixRoot(io, plan[idx].path)) {
            removed += 1;
            if (existed[idx]) {
                freed_paths += 1;
                freed[idx] = true;
            }
        } else skipped += 1;
    }

    verifyWipe(io, plan);

    var sum_buf: [128]u8 = undefined;
    const sum = std.fmt.bufPrint(&sum_buf, "removed {d} target(s), skipped {d}", .{ removed, skipped }) catch "";
    output.success("{s}", .{sum});
    return .{ .removed = freed_paths, .bytes = freedBytes(sizes, freed) };
}

/// Bytes credited by a wipe: only targets whose delete succeeded, using the
/// preflight size. A target that resizes between the preflight stat and the
/// unlink is a benign TOCTOU — this is a reporting figure, not a safety gate.
/// `sizes[i]` is already 0 for non-existing paths, so `freed[i]` alone gates
/// the sum and keeps the byte total consistent with the freed-path count.
fn freedBytes(sizes: []const u64, freed: []const bool) u64 {
    var total: u64 = 0;
    for (sizes, freed) |s, f| {
        if (f) total += s;
    }
    return total;
}

test "freedBytes credits only successfully-freed targets" {
    const sizes = [_]u64{ 1048576, 4096, 8192 };
    // Middle target's delete failed: its bytes must not be credited even
    // though it was present in the preflight sum.
    const freed = [_]bool{ true, false, true };
    try std.testing.expectEqual(@as(u64, 1048576 + 8192), freedBytes(&sizes, &freed));
}

test "freedBytes is zero when every delete failed" {
    const sizes = [_]u64{ 1048576, 4096 };
    const freed = [_]bool{ false, false };
    try std.testing.expectEqual(@as(u64, 0), freedBytes(&sizes, &freed));
}

test "freedBytes credits the full total when every delete succeeded" {
    // The happy path: a fully successful wipe must still report all bytes,
    // matching the old `total_bytes` behaviour that this fix preserves.
    const sizes = [_]u64{ 1048576, 4096, 8192 };
    const freed = [_]bool{ true, true, true };
    try std.testing.expectEqual(@as(u64, 1048576 + 4096 + 8192), freedBytes(&sizes, &freed));
}

test "freedBytes is zero for an empty plan" {
    try std.testing.expectEqual(@as(u64, 0), freedBytes(&.{}, &.{}));
}

test "writeBytesToPath creates a full absolute parent chain with a missing grandparent" {
    // Delegation smoke: the safety manifest lands even when --backup points at
    // a nested absolute path whose grandparent is absent (path_write creates
    // it). Exhaustive edge cases live in `fs/path_write.zig`.
    const io = std.Options.debug_io;
    const ts = std.Io.Clock.real.now(io).toNanoseconds();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = std.fmt.bufPrint(&buf, "/tmp/malt_purge_abschain_{d}", .{ts}) catch unreachable;
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var dest_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dest = std.fmt.bufPrint(&dest_buf, "{s}/a/b/manifest.txt", .{root}) catch unreachable;

    const ctx: AppCtx = .{ .io = io, .environ = .empty };
    try writeBytesToPath(&ctx, dest, "formula git\n");

    const f = try std.Io.Dir.cwd().openFile(io, dest, .{});
    defer f.close(io);
    const stat = try f.stat(io);
    try std.testing.expect(stat.size > 0);
}

test "writeBytesToPath maps a path_write failure to OpenFileFailed" {
    // Pins the caller's error mapping: a parent-dir failure (a parent
    // component is a regular file) must surface as OpenFileFailed.
    const io = std.Options.debug_io;
    const ts = std.Io.Clock.real.now(io).toNanoseconds();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = std.fmt.bufPrint(&buf, "/tmp/malt_purge_parentfile_{d}", .{ts}) catch unreachable;
    std.Io.Dir.cwd().createDirPath(io, root) catch unreachable;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var blocker_buf: [std.fs.max_path_bytes]u8 = undefined;
    const blocker = std.fmt.bufPrint(&blocker_buf, "{s}/afile", .{root}) catch unreachable;
    (std.Io.Dir.cwd().createFile(io, blocker, .{ .truncate = true }) catch unreachable).close(io);

    var dest_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dest = std.fmt.bufPrint(&dest_buf, "{s}/afile/sub/manifest.txt", .{root}) catch unreachable;

    const ctx: AppCtx = .{ .io = io, .environ = .empty };
    try std.testing.expectError(Error.OpenFileFailed, writeBytesToPath(&ctx, dest, "formula git\n"));
}
