//! malt — recursive on-disk size of a directory tree.
//!
//! A leaf helper used by `mt list --json --size` to report `size_bytes`
//! per installed keg/cask. Symlink-safe: regular files are summed,
//! real subdirectories are recursed, and symlinks are neither counted
//! nor followed — so a keg's internal symlinks and a cask's `app_path`
//! symlink-into-Caskroom never double-count or escape the tree.

const std = @import("std");
const testing = std.testing;

/// Sum the byte size of every regular file under `path`, recursively.
/// Missing or unreadable directories contribute 0 rather than failing —
/// a partial/absent keg dir must not crash the row writer.
pub fn dirSizeBytes(io: std.Io, path: []const u8) u64 {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    return sumDir(io, &dir);
}

/// Walk one directory level: count regular files, recurse real
/// subdirectories. Anything else (symlinks, sockets, devices) is left
/// alone so symlinks are never counted nor traversed. Saturating add
/// guards the theoretical u64 overflow on a pathological tree.
fn sumDir(io: std.Io, dir: *std.Io.Dir) u64 {
    var total: u64 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        switch (entry.kind) {
            .file => {
                const st = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch continue;
                total +|= st.size;
            },
            .directory => {
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer sub.close(io);
                total +|= sumDir(io, &sub);
            },
            else => {},
        }
    }
    return total;
}

test "dirSizeBytes sums nested regular files and skips symlinks" {
    const io = std.Options.debug_io;
    const root = "/tmp/malt_dirsize_nested";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/sub");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    {
        const f = try std.Io.Dir.createFileAbsolute(io, root ++ "/a.txt", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "12345"); // 5 bytes
    }
    {
        const f = try std.Io.Dir.createFileAbsolute(io, root ++ "/sub/b.txt", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "678"); // 3 bytes
    }
    // A symlink to a real 5-byte file must contribute nothing.
    var sub = try std.Io.Dir.openDirAbsolute(io, root, .{});
    defer sub.close(io);
    sub.symLink(io, root ++ "/a.txt", "link", .{}) catch {};

    try testing.expectEqual(@as(u64, 8), dirSizeBytes(io, root));
}

test "dirSizeBytes does not follow a symlink that points at a directory" {
    // The escape/double-count guard: a keg/cask can contain a symlink to
    // another directory. Following it would count bytes outside the tree.
    const io = std.Options.debug_io;
    const root = "/tmp/malt_dirsize_dirlink";
    const outside = "/tmp/malt_dirsize_outside";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    std.Io.Dir.cwd().deleteTree(io, outside) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/real");
    try std.Io.Dir.createDirAbsolute(io, outside, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, outside) catch {};

    {
        const f = try std.Io.Dir.createFileAbsolute(io, root ++ "/real/keep", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "1234"); // 4 bytes — the only thing counted
    }
    {
        const f = try std.Io.Dir.createFileAbsolute(io, outside ++ "/escaped", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "SHOULD-NOT-COUNT"); // behind a dir symlink
    }
    var rd = try std.Io.Dir.openDirAbsolute(io, root, .{});
    defer rd.close(io);
    rd.symLink(io, outside, "danger", .{}) catch {};

    try testing.expectEqual(@as(u64, 4), dirSizeBytes(io, root));
}

test "dirSizeBytes returns 0 for a missing directory" {
    const io = std.Options.debug_io;
    try testing.expectEqual(@as(u64, 0), dirSizeBytes(io, "/tmp/malt_dirsize_does_not_exist_xyz"));
}

test "dirSizeBytes counts a zero-byte file as 0 without skipping the tree" {
    const io = std.Options.debug_io;
    const root = "/tmp/malt_dirsize_zerofile";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.createDirAbsolute(io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    {
        const f = try std.Io.Dir.createFileAbsolute(io, root ++ "/empty", .{});
        f.close(io);
    }
    {
        const f = try std.Io.Dir.createFileAbsolute(io, root ++ "/data", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "xyz"); // 3 bytes
    }
    try testing.expectEqual(@as(u64, 3), dirSizeBytes(io, root));
}

test "dirSizeBytes returns 0 for an empty directory" {
    const io = std.Options.debug_io;
    const root = "/tmp/malt_dirsize_empty";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.createDirAbsolute(io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try testing.expectEqual(@as(u64, 0), dirSizeBytes(io, root));
}
