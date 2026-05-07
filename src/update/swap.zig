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

/// Replace `target_path` with the contents of `new_path`. On success,
/// the previous binary is kept at `<target_path>.old` for manual
/// rollback. On failure during the swap, the previous binary is
/// restored and no partial state is left behind.
///
/// `new_path` is copied - not moved - so callers can keep scratch
/// extraction in `$TMPDIR` without caring whether it shares a volume
/// with the target.
pub fn atomicReplace(io: std.Io, target_path: []const u8, new_path: []const u8) SwapError!void {
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
    std.Io.Dir.renameAbsolute(target_path, old_path, io) catch |e| switch (e) {
        error.AccessDenied, error.PermissionDenied => return error.PermissionDenied,
        else => return error.SwapFailed,
    };
    // Rollback on late failure: restore target from .old and drop the
    // never-installed stage in one explicit block so the unwind reads
    // top-to-bottom. The stage errdefer above also fires after this and
    // is a no-op once the file is gone.
    errdefer {
        std.Io.Dir.renameAbsolute(old_path, target_path, io) catch {};
        std.Io.Dir.deleteFileAbsolute(io, staged_path) catch {};
    }

    // Atomic rename #2: staged -> target.
    std.Io.Dir.renameAbsolute(staged_path, target_path, io) catch return error.RollbackFailed;

    // Flush the parent so both rename dirents are durable. Swallowing
    // errors here is fine: the swap already succeeded in the page cache;
    // only a power loss in the next few ms could lose the dirents and
    // there is nothing to roll back to at this point.
    var dir = std.Io.Dir.openDirAbsolute(io, target_dir, .{}) catch return;
    defer dir.close(io);
    const dir_file: std.Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    dir_file.sync(io) catch {};
}
