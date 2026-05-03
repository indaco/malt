//! malt - cleanup of self-update artefacts.
//!
//! `<target>.old` is kept for manual rollback after each update.
//! Over time these accumulate, and killed updates may leave
//! `.malt-update-<pid>` staging files behind. `cleanUpdateArtefacts`
//! removes both from the target's directory.

const std = @import("std");

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
pub fn cleanUpdateArtefacts(io: std.Io, target_path: []const u8) !Cleaned {
    var cleaned = Cleaned{};

    var old_buf: [std.fs.max_path_bytes]u8 = undefined;
    const old_path = try std.fmt.bufPrint(&old_buf, "{s}.old", .{target_path});
    if (std.Io.Dir.deleteFileAbsolute(io, old_path)) |_| {
        cleaned.old += 1;
    } else |_| {}

    const target_dir = std.fs.path.dirname(target_path) orelse return cleaned;
    var dir = std.Io.Dir.openDirAbsolute(io, target_dir, .{ .iterate = true }) catch return cleaned;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, ".malt-update-")) continue;
        dir.deleteFile(io, entry.name) catch continue;
        cleaned.staging += 1;
    }
    return cleaned;
}
