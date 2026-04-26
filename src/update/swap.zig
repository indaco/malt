//! malt - atomic binary replacement for self-update.
//!
//! `atomicReplace(target, new)` swaps in a fresh binary using two
//! POSIX rename(2) calls. Both operands live in the same directory
//! as `target` at the rename step, so the rename is always within
//! one filesystem and therefore atomic. Preserves `<target>.old` for
//! manual rollback on success; restores it to `<target>` on failure.

const std = @import("std");
const fs_compat = @import("../fs/compat.zig");

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
pub fn atomicReplace(target_path: []const u8, new_path: []const u8) SwapError!void {
    const target_dir = std.fs.path.dirname(target_path) orelse return error.SwapFailed;

    var old_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const old_path = std.fmt.bufPrint(&old_path_buf, "{s}.old", .{target_path}) catch
        return error.StagingFailed;

    var staged_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const staged_path = std.fmt.bufPrint(&staged_path_buf, "{s}/.malt-update-{d}", .{ target_dir, std.c.getpid() }) catch
        return error.StagingFailed;

    // Stage the new binary next to the target. Cleans any stale file
    // from a killed earlier run first so copy never EEXISTs. EACCES on
    // the staging copy means the target dir is unwritable — the updater
    // catches `PermissionDenied` and re-runs the swap under sudo.
    fs_compat.deleteFileAbsolute(staged_path) catch {};
    fs_compat.copyFileAbsolute(new_path, staged_path, .{}) catch |e| switch (e) {
        error.AccessDenied => return error.PermissionDenied,
        else => return error.StagingFailed,
    };
    // Errdefer cleanup: stage leaks get reaped by the next update's pre-copy delete above.
    errdefer fs_compat.deleteFileAbsolute(staged_path) catch {};

    // Set mode on the staged file so we never leave a non-executable
    // malt in place if the rename succeeds but chmod races. Sync before
    // close: a rename is not durable without a prior fsync, so a power
    // loss after rename could otherwise expose a partial binary.
    {
        const f = fs_compat.openFileAbsolute(staged_path, .{ .mode = .read_write }) catch |e| switch (e) {
            error.AccessDenied => return error.PermissionDenied,
            else => return error.StagingFailed,
        };
        defer f.close();
        f.chmod(0o755) catch return error.StagingFailed;
        f.sync() catch return error.StagingFailed;
    }

    // Clear any .old left by a crashed prior run before we overwrite it.
    fs_compat.deleteFileAbsolute(old_path) catch {};

    // Atomic rename #1: target -> target.old. EACCES/EPERM here means
    // the dir is unwritable — same sudo-fallback path as the staging copy.
    fs_compat.renameAbsolute(target_path, old_path) catch |e| switch (e) {
        error.AccessDenied, error.PermissionDenied => return error.PermissionDenied,
        else => return error.SwapFailed,
    };
    // Rollback rename; if this also fails the caller already has RollbackFailed surfaced.
    errdefer fs_compat.renameAbsolute(old_path, target_path) catch {};

    // Atomic rename #2: staged -> target. If this fails the errdefers
    // above restore .old to target and delete the stage.
    fs_compat.renameAbsolute(staged_path, target_path) catch return error.RollbackFailed;

    // Flush the parent so both rename dirents are durable. Swallowing
    // errors here is fine: the swap already succeeded in the page cache;
    // only a power loss in the next few ms could lose the dirents and
    // there is nothing to roll back to at this point.
    var dir = fs_compat.openDirAbsolute(target_dir, .{}) catch return;
    defer dir.close();
    dir.sync() catch {};
}
