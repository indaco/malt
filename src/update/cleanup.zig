//! malt - cleanup of self-update artefacts.
//!
//! `<target>.old` is kept for manual rollback after each update. A
//! legacy dual-binary update also leaves the twin's `.old` behind.
//! Over time these accumulate, and killed updates may leave
//! `.malt-update-<pid>` staging files behind. `cleanUpdateArtefacts`
//! removes all of them from the target's directory.

const std = @import("std");

pub const Cleaned = struct {
    /// Number of `.old` files removed (target's and its twin's, 0-2).
    old: u32 = 0,
    /// Number of `.malt-update-<pid>` staging files removed.
    staging: u32 = 0,

    pub fn total(self: Cleaned) u32 {
        return self.old + self.staging;
    }
};

/// Remove `<target>.old`, the twin's `.old` (`malt` <-> `mt`), and any
/// `.malt-update-*` staging files in `target`'s directory. Silent on
/// missing files - "already clean" is a success state, not an error.
pub fn cleanUpdateArtefacts(io: std.Io, target_path: []const u8) !Cleaned {
    var cleaned = Cleaned{};

    var old_buf: [std.fs.max_path_bytes]u8 = undefined;
    const old_path = try std.fmt.bufPrint(&old_buf, "{s}.old", .{target_path});
    if (std.Io.Dir.deleteFileAbsolute(io, old_path)) |_| {
        cleaned.old += 1;
    } else |_| {}

    const target_dir = std.fs.path.dirname(target_path) orelse return cleaned;

    // A legacy dual-regular-file update swaps both binaries before the
    // twin becomes a symlink, so the twin's .old must be swept too.
    const base = std.fs.path.basename(target_path);
    const twin_base: ?[]const u8 =
        if (std.mem.eql(u8, base, "malt")) "mt" else if (std.mem.eql(u8, base, "mt")) "malt" else null;
    if (twin_base) |tb| {
        var twin_buf: [std.fs.max_path_bytes]u8 = undefined;
        const twin_old = try std.fmt.bufPrint(&twin_buf, "{s}/{s}.old", .{ target_dir, tb });
        if (std.Io.Dir.deleteFileAbsolute(io, twin_old)) |_| {
            cleaned.old += 1;
        } else |_| {}
    }

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
