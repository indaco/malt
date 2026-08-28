//! Is a path a symlink, without following it.
//!
//! Callers that splice a trusted string into `<root>/<component>/...` prove
//! the component is lexically confined, but the kernel still resolves a
//! symlinked intermediate, so the write or delete lands wherever it points.
//! Screening the intermediate here closes that gap.

const std = @import("std");

/// True when `path` is a symlink, and also when it cannot be read. Only a
/// path that is genuinely absent is cleared: that is the first-install case.
/// Any other stat failure means the caller cannot prove the path is safe to
/// splice below, and the sinks that follow would resolve a link if one is
/// there, so this fails closed.
pub fn isSymlinkOrUnreadable(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => return true,
    };
    return stat.kind == .sym_link;
}

// ── inline unit tests ──────────────────────────────────────────────────────

var scratch_seq: std.atomic.Value(u32) = .init(0);

/// A created, empty scratch directory. The pid and sequence keep concurrent
/// test binaries off each other's paths.
fn scratchRoot(io: std.Io, buf: []u8) ![]const u8 {
    const root = std.fmt.bufPrint(buf, "/tmp/malt_symlink_{d}_{d}", .{
        std.c.getpid(),
        scratch_seq.fetchAdd(1, .monotonic),
    }) catch unreachable;
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.createDirAbsolute(io, root, .default_dir);
    return root;
}

test "a directory link is caught, its target and a missing path are not" {
    const io = std.Options.debug_io;

    var root_buf: [128]u8 = undefined;
    const root = try scratchRoot(io, &root_buf);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var target_buf: [192]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "{s}/target", .{root});
    try std.Io.Dir.createDirAbsolute(io, target, .default_dir);

    var link_buf: [192]u8 = undefined;
    const link = try std.fmt.bufPrint(&link_buf, "{s}/link", .{root});
    try std.Io.Dir.symLinkAbsolute(io, target, link, .{ .is_directory = true });

    try std.testing.expect(isSymlinkOrUnreadable(io, link));
    try std.testing.expect(!isSymlinkOrUnreadable(io, target));
    try std.testing.expect(!isSymlinkOrUnreadable(io, root));

    var missing_buf: [192]u8 = undefined;
    const missing = try std.fmt.bufPrint(&missing_buf, "{s}/absent", .{root});
    try std.testing.expect(!isSymlinkOrUnreadable(io, missing));

    // A dangling link still redirects a create, so it must still read as one.
    try std.Io.Dir.deleteDirAbsolute(io, target);
    try std.testing.expect(isSymlinkOrUnreadable(io, link));
}

test "a relative-target link is caught the same as an absolute one" {
    // Real Cellar entries are as likely to be relative as absolute, and the
    // probe must not depend on the target's form.
    const io = std.Options.debug_io;

    var root_buf: [128]u8 = undefined;
    const root = try scratchRoot(io, &root_buf);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var dir = try std.Io.Dir.openDirAbsolute(io, root, .{});
    defer dir.close(io);
    try dir.createDir(io, "target", .default_dir);
    try dir.symLink(io, "./target", "rel", .{ .is_directory = true });

    var link_buf: [192]u8 = undefined;
    const link = try std.fmt.bufPrint(&link_buf, "{s}/rel", .{root});
    try std.testing.expect(isSymlinkOrUnreadable(io, link));
}

test "a file link is caught, a plain file is not" {
    const io = std.Options.debug_io;

    var root_buf: [128]u8 = undefined;
    const root = try scratchRoot(io, &root_buf);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var file_buf: [192]u8 = undefined;
    const file = try std.fmt.bufPrint(&file_buf, "{s}/f", .{root});
    (try std.Io.Dir.cwd().createFile(io, file, .{})).close(io);

    var link_buf: [192]u8 = undefined;
    const link = try std.fmt.bufPrint(&link_buf, "{s}/f-link", .{root});
    try std.Io.Dir.symLinkAbsolute(io, file, link, .{});

    try std.testing.expect(!isSymlinkOrUnreadable(io, file));
    try std.testing.expect(isSymlinkOrUnreadable(io, link));
}
