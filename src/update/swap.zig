//! malt - atomic binary replacement for self-update.
//!
//! `atomicReplace(target, new)` swaps in a fresh binary using two
//! POSIX rename(2) calls. Both operands live in the same directory
//! as `target` at the rename step, so the rename is always within
//! one filesystem and therefore atomic. Preserves `<target>.old` for
//! manual rollback on success; restores it to `<target>` on failure.

const std = @import("std");

pub const SwapError = error{
    /// Could not stage the new binary next to the target (disk full,
    /// non-permission failure). No file has moved yet.
    StagingFailed,
    /// The target→.old rename failed. Target is untouched.
    SwapFailed,
    /// The swap happened but the state is inconsistent (e.g. rollback
    /// also failed). `<target>.old` may be the live binary; the real
    /// target path may not exist. Caller surfaces the situation loudly.
    RollbackFailed,
    /// EACCES/EPERM on the staging copy or the target rename. Distinct
    /// from `StagingFailed`/`SwapFailed` so the updater can elevate via
    /// sudo instead of dumping a manual recovery hint.
    PermissionDenied,
};

/// The rename primitive that `atomicReplaceImpl` moves files with. The
/// public entry point wires the real `renameAbsolute`; a test injects a
/// stub to fail a chosen rename without a real cross-device move.
const RenameFn = *const fn (old_path: []const u8, new_path: []const u8, io: std.Io) std.Io.Dir.RenameError!void;

fn realRename(old_path: []const u8, new_path: []const u8, io: std.Io) std.Io.Dir.RenameError!void {
    return std.Io.Dir.renameAbsolute(old_path, new_path, io);
}

/// Replace `target_path` with the contents of `new_path`. On success,
/// the previous binary is kept at `<target_path>.old` for manual
/// rollback. On failure during the swap, the previous binary is
/// restored and no partial state is left behind.
///
/// `new_path` is copied - not moved - so callers can keep scratch
/// extraction in `$TMPDIR` without caring whether it shares a volume
/// with the target.
pub fn atomicReplace(io: std.Io, target_path: []const u8, new_path: []const u8) SwapError!void {
    return atomicReplaceImpl(io, target_path, new_path, realRename);
}

fn atomicReplaceImpl(io: std.Io, target_path: []const u8, new_path: []const u8, rename_fn: RenameFn) SwapError!void {
    const target_dir = std.fs.path.dirname(target_path) orelse return error.SwapFailed;

    var old_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const old_path = std.fmt.bufPrint(&old_path_buf, "{s}.old", .{target_path}) catch
        return error.StagingFailed;

    var staged_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const staged_path = std.fmt.bufPrint(&staged_path_buf, "{s}/.malt-update-{d}", .{ target_dir, std.c.getpid() }) catch
        return error.StagingFailed;

    const cwd_dir: std.Io.Dir = .cwd();

    // Stage the new binary next to the target. Cleans any stale file
    // from a killed earlier run first so copy never EEXISTs. EACCES on
    // the staging copy means the target dir is unwritable — the updater
    // catches `PermissionDenied` and re-runs the swap under sudo.
    std.Io.Dir.deleteFileAbsolute(io, staged_path) catch {};
    std.Io.Dir.copyFile(cwd_dir, new_path, cwd_dir, staged_path, io, .{}) catch |e| switch (e) {
        error.AccessDenied => return error.PermissionDenied,
        else => return error.StagingFailed,
    };
    // Drop the stage on any error path after this point — chmod, sync,
    // either rename. Pairs with the rollback errdefer below; on a late
    // failure both fire (LIFO) so target is restored and stage is gone.
    errdefer std.Io.Dir.deleteFileAbsolute(io, staged_path) catch {};

    // Set mode on the staged file so we never leave a non-executable
    // malt in place if the rename succeeds but chmod races. Sync before
    // close: a rename is not durable without a prior fsync, so a power
    // loss after rename could otherwise expose a partial binary.
    {
        const f = std.Io.Dir.openFileAbsolute(io, staged_path, .{ .mode = .read_write }) catch |e| switch (e) {
            error.AccessDenied => return error.PermissionDenied,
            else => return error.StagingFailed,
        };
        defer f.close(io);
        f.setPermissions(io, std.Io.File.Permissions.fromMode(0o755)) catch return error.StagingFailed;
        f.sync(io) catch return error.StagingFailed;
    }

    // Clear any .old left by a crashed prior run before we overwrite it.
    std.Io.Dir.deleteFileAbsolute(io, old_path) catch {};

    // Atomic rename #1: target -> target.old. EACCES/EPERM here means
    // the dir is unwritable — same sudo-fallback path as the staging copy.
    rename_fn(target_path, old_path, io) catch |e| switch (e) {
        error.AccessDenied, error.PermissionDenied => return error.PermissionDenied,
        else => return error.SwapFailed,
    };

    // Atomic rename #2: staged -> target. On failure, restore from .old: a
    // confirmed restore is a clean SwapFailed, only an unconfirmed one is
    // RollbackFailed. The stage-drop errdefer clears the temp on both.
    rename_fn(staged_path, target_path, io) catch {
        rename_fn(old_path, target_path, io) catch return error.RollbackFailed;
        return error.SwapFailed;
    };

    // Flush the parent so both rename dirents are durable. Swallowing
    // errors here is fine: the swap already succeeded in the page cache;
    // only a power loss in the next few ms could lose the dirents and
    // there is nothing to roll back to at this point.
    var dir = std.Io.Dir.openDirAbsolute(io, target_dir, .{}) catch return;
    defer dir.close(io);
    const dir_file: std.Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    dir_file.sync(io) catch {};
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;

// The rename stubs are non-capturing fn pointers, so they can't hold a
// per-call counter of their own; they share this file-scope one, which
// each test resets before use.
var rename_calls: usize = 0;

// Fails rename #2 (staged -> target) with EXDEV; rename #1 and the restore
// succeed.
fn failStagedRename(old_path: []const u8, new_path: []const u8, io: std.Io) std.Io.Dir.RenameError!void {
    rename_calls += 1;
    if (rename_calls == 2) return error.CrossDevice;
    return std.Io.Dir.renameAbsolute(old_path, new_path, io);
}

// Fails rename #2 and every rename after it, so the restore also fails and
// target is left unrecovered — the only genuinely inconsistent state.
fn failStagedAndRestore(old_path: []const u8, new_path: []const u8, io: std.Io) std.Io.Dir.RenameError!void {
    rename_calls += 1;
    if (rename_calls >= 2) return error.CrossDevice;
    return std.Io.Dir.renameAbsolute(old_path, new_path, io);
}

fn expectMissing(io: std.Io, path: []const u8) !void {
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, path, .{}));
}

fn expectBytes(io: std.Io, path: []const u8, want: []const u8) !void {
    var buf: [16]u8 = undefined;
    const f = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer f.close(io);
    const n = try f.readPositionalAll(io, &buf, 0);
    try testing.expectEqualStrings(want, buf[0..n]);
}

// A fresh scratch dir holding a `target` (OLD) and `new` (NEW), with the
// `.old` and staged paths the impl derives. Mirrors the fixture style in
// tests/swap_test.zig; `staged` uses the same pid the impl does.
const Scratch = struct {
    dir: []u8,
    target: []u8,
    new: []u8,
    old: []u8,
    staged: []u8,

    fn init(a: std.mem.Allocator, io: std.Io, tag: []const u8) !Scratch {
        const dir = try std.fmt.allocPrint(a, "/tmp/malt-swap-{s}-{d}", .{ tag, std.c.getpid() });
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        try std.Io.Dir.createDirAbsolute(io, dir, .default_dir);
        const s: Scratch = .{
            .dir = dir,
            .target = try std.fmt.allocPrint(a, "{s}/malt", .{dir}),
            .new = try std.fmt.allocPrint(a, "{s}/malt.new", .{dir}),
            .old = try std.fmt.allocPrint(a, "{s}/malt.old", .{dir}),
            .staged = try std.fmt.allocPrint(a, "{s}/.malt-update-{d}", .{ dir, std.c.getpid() }),
        };
        const t = try std.Io.Dir.createFileAbsolute(io, s.target, .{});
        try t.writeStreamingAll(io, "OLD");
        t.close(io);
        const n = try std.Io.Dir.createFileAbsolute(io, s.new, .{});
        try n.writeStreamingAll(io, "NEW");
        n.close(io);
        return s;
    }

    fn deinit(self: Scratch, io: std.Io, a: std.mem.Allocator) void {
        std.Io.Dir.cwd().deleteTree(io, self.dir) catch {};
        for ([_][]u8{ self.dir, self.target, self.new, self.old, self.staged }) |p| a.free(p);
    }
};

test "atomicReplace reports a successful restore as SwapFailed, not RollbackFailed" {
    const io = std.Options.debug_io;
    const s = try Scratch.init(testing.allocator, io, "swapfailed");
    defer s.deinit(io, testing.allocator);

    rename_calls = 0;
    const result = atomicReplaceImpl(io, s.target, s.new, failStagedRename);

    // Restore consumed `.old`, so the tree is consistent: the caller must be
    // told the swap failed (target intact), NOT that the rollback failed —
    // the latter's `mv <self>.old <self>` hint would error, `.old` is gone.
    try testing.expectError(error.SwapFailed, result);
    try expectBytes(io, s.target, "OLD");
    try expectMissing(io, s.old);
    try expectMissing(io, s.staged);
}

test "atomicReplace reports RollbackFailed only when the restore itself fails" {
    const io = std.Options.debug_io;
    const s = try Scratch.init(testing.allocator, io, "rollbackfailed");
    defer s.deinit(io, testing.allocator);

    rename_calls = 0;
    const result = atomicReplaceImpl(io, s.target, s.new, failStagedAndRestore);

    // Restore failed: target is gone, the previous binary sits at `.old`.
    // This is exactly the state the loud recovery hint is for.
    try testing.expectError(error.RollbackFailed, result);
    try expectMissing(io, s.target);
    try expectBytes(io, s.old, "OLD");
    try expectMissing(io, s.staged);
}
