//! malt - cleanup of self-update artefacts.
//!
//! `<target>.old` is kept for manual rollback after each update.
//! Over time these accumulate, and killed updates may leave
//! `.malt-update-<pid>` staging files behind. `cleanUpdateArtefacts`
//! removes both from the target's directory.

const std = @import("std");
const fs_compat = @import("../fs/compat.zig");
const io_mod = @import("../ui/io.zig");

pub const Cleaned = struct {
    /// Number of `<target>.old` files removed (0 or 1).
    old: u32 = 0,
    /// Number of `.malt-update-<pid>` staging files removed.
    staging: u32 = 0,

    pub fn total(self: Cleaned) u32 {
        return self.old + self.staging;
    }
};

/// Remove `<target>.old` and any `.malt-update-*` staging files in
/// `target`'s directory. Silent on missing files - "already clean" is
/// a success state, not an error.
pub fn cleanUpdateArtefacts(target_path: []const u8) !Cleaned {
    var cleaned = Cleaned{};

    var old_buf: [std.fs.max_path_bytes]u8 = undefined;
    const old_path = try std.fmt.bufPrint(&old_buf, "{s}.old", .{target_path});
    if (fs_compat.deleteFileAbsolute(old_path)) |_| {
        cleaned.old += 1;
    } else |_| {}

    const target_dir = std.fs.path.dirname(target_path) orelse return cleaned;
    var dir = fs_compat.openDirAbsolute(target_dir, .{ .iterate = true }) catch return cleaned;
    defer dir.close();

    var it = dir.inner.iterate();
    while (it.next(io_mod.ctx()) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, ".malt-update-")) continue;
        dir.inner.deleteFile(io_mod.ctx(), entry.name) catch continue;
        cleaned.staging += 1;
    }
    return cleaned;
}
