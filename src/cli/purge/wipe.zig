//! malt — nuclear wipe path: plan construction, manifest writing, and
//! the orchestrator that executes a built plan under a single lock.

const std = @import("std");
const AppCtx = @import("../../app_ctx.zig").AppCtx;
const sqlite = @import("../../db/sqlite.zig");
const schema = @import("../../db/schema.zig");
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

/// The caller deletes the prefix on the strength of this manifest, so a DB
/// fault must be louder than an empty file. Only a prefix that never had a
/// database is honestly empty.
pub fn writeManifest(ctx: *const AppCtx, allocator: std.mem.Allocator, path: []const u8) Error!void {
    const prefix = atomic.maltPrefixOrAbort();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    backup_mod.writeHeader(w) catch return Error.WriteFailed;

    switch (util.openDbTri(ctx.io, prefix)) {
        .absent => {},
        .unreadable => |e| return refuseUnusableDb(prefix, e),
        .opened => |db_val| {
            var db = db_val;
            defer db.close();
            // Guarantees the tables exist, so a failing `prepare` below can
            // only mean a genuinely broken database, never a fresh one.
            schema.initSchema(&db) catch |e| return refuseUnusableDb(prefix, e);
            // Versions always pinned and services always included: the
            // wipe destroys the launchd plists, so this manifest is the
            // only record of the auto-start set.
            _ = backup_mod.writeRows(w, &db, true, true) catch |e| switch (e) {
                error.DatabaseError => {
                    output.err("cannot read installed packages — refusing to wipe without a usable backup", .{});
                    return Error.DatabaseError;
                },
                error.WriteFailed => return Error.WriteFailed,
            };
        },
    }

    try writeBytesToPath(ctx, path, aw.written());
}

/// Open and schema faults are the same story to the caller: no row source it
/// can trust.
fn refuseUnusableDb(prefix: []const u8, e: anyerror) Error {
    output.err("cannot read database at {s}/db/malt.db ({s}) — refusing to wipe without a usable backup", .{ prefix, @errorName(e) });
    return Error.DatabaseError;
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
            writeManifest(ctx, allocator, bp) catch |e| return if (e == Error.DatabaseError) error.Aborted else e;
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

const fs_test_io = std.Options.debug_io;

fn rmrf(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(fs_test_io, path) catch {};
}

var scratch_seq: std.atomic.Value(u32) = .init(0);

/// Scratch tree under a process- and call-unique base: overlapping test runs
/// share /tmp and would otherwise delete each other's fixtures.
const Scratch = struct {
    arena: std.heap.ArenaAllocator,
    base: [:0]const u8,

    fn init(comptime tag: []const u8) !Scratch {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const base = try std.fmt.allocPrintSentinel(
            arena.allocator(),
            "/tmp/malt_" ++ tag ++ "_{d}_{d}",
            .{ std.c.getpid(), scratch_seq.fetchAdd(1, .monotonic) },
            0,
        );
        rmrf(base);
        return .{ .arena = arena, .base = base };
    }

    /// Absolute path to `sub` (leading slash included) inside the scratch
    /// tree; valid until `deinit`.
    fn p(self: *Scratch, sub: []const u8) [:0]const u8 {
        return std.fmt.allocPrintSentinel(
            self.arena.allocator(),
            "{s}{s}",
            .{ self.base, sub },
            0,
        ) catch @panic("OOM");
    }

    fn deinit(self: *Scratch) void {
        rmrf(self.base);
        self.arena.deinit();
    }
};

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
    var s = try Scratch.init("purge_abschain");
    defer s.deinit();

    const dest = s.p("/a/b/manifest.txt");

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
    var s = try Scratch.init("purge_parentfile");
    defer s.deinit();
    try std.Io.Dir.cwd().createDirPath(io, s.base);

    (try std.Io.Dir.cwd().createFile(io, s.p("/afile"), .{ .truncate = true })).close(io);

    const dest = s.p("/afile/sub/manifest.txt");

    const ctx: AppCtx = .{ .io = io, .environ = .empty };
    try std.testing.expectError(Error.OpenFileFailed, writeBytesToPath(&ctx, dest, "formula git\n"));
}

/// Points MALT_PREFIX at a test prefix and puts the prior value back: the
/// harness sets a throwaway, and unsetting it would send every later test
/// at the real /opt/malt. The prior value is copied because setenv may free
/// the environ string it replaces.
const PrefixEnv = struct {
    const c = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
        extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;
    };
    prev: ?[:0]u8,

    fn set(base: [:0]const u8) !PrefixEnv {
        const prev: ?[:0]u8 = if (c.getenv("MALT_PREFIX")) |v| try std.testing.allocator.dupeZ(u8, std.mem.span(v)) else null;
        _ = c.setenv("MALT_PREFIX", base.ptr, 1);
        return .{ .prev = prev };
    }

    fn restore(self: *PrefixEnv) void {
        if (self.prev) |v| {
            _ = c.setenv("MALT_PREFIX", v.ptr, 1);
            std.testing.allocator.free(v);
        } else {
            _ = c.unsetenv("MALT_PREFIX");
        }
    }
};

test "writeManifest writes the same tap-qualified cask and service rows as mt backup" {
    // The wipe manifest is the only record left once the prefix is gone, so
    // it must be restorable: third-party casks keep their tap and auto-start
    // services are always included.
    const io = std.Options.debug_io;
    var s = try Scratch.init("purge_manifest_rows");
    defer s.deinit();
    try std.Io.Dir.cwd().createDirPath(io, s.p("/db"));

    var db = try sqlite.Database.open(s.p("/db/malt.db"));
    try schema.initSchema(&db);
    try db.exec(
        \\INSERT INTO casks(token, name, version, url, tap) VALUES
        \\  ('foo', 'Foo', '1.0', 'https://x/foo.dmg', 'acme/tools'),
        \\  ('bar', 'Bar', '2.0', 'https://x/bar.dmg', 'homebrew/cask');
        \\INSERT INTO services(name, keg_name, plist_path, auto_start)
        \\  VALUES ('svc', 'svc', '/svc.plist', 1);
    );
    db.close();

    var env = try PrefixEnv.set(s.base);
    defer env.restore();
    const ctx: AppCtx = .{ .io = io, .environ = .empty };
    const dest = s.p("/manifest.txt");
    try writeManifest(&ctx, std.testing.allocator, dest);

    const got = try std.Io.Dir.cwd().readFileAlloc(io, dest, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "cask bar@2.0\ncask acme/tools/foo@1.0\nservice svc\n") != null);
}

test "writeManifest refuses a database whose tables cannot be read and leaves no manifest" {
    // A bad table must abort like a bad file: a partial manifest followed
    // by the wipe would be worse than no manifest at all.
    const io = std.Options.debug_io;
    var s = try Scratch.init("purge_manifest_badtable");
    defer s.deinit();
    try std.Io.Dir.cwd().createDirPath(io, s.p("/db"));

    var db = try sqlite.Database.open(s.p("/db/malt.db"));
    // `initSchema` is CREATE IF NOT EXISTS, so this shape survives it.
    try db.exec("CREATE TABLE kegs(x);");
    db.close();

    var env = try PrefixEnv.set(s.base);
    defer env.restore();
    const ctx: AppCtx = .{ .io = io, .environ = .empty };
    const dest = s.p("/manifest.txt");

    try std.testing.expectError(Error.DatabaseError, writeManifest(&ctx, std.testing.allocator, dest));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, dest, .{}));
}
