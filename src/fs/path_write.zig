//! Non-atomic writes to a user-supplied output path (`backup -o`,
//! `purge --backup`): creates the parent chain and accepts absolute or
//! relative paths. Use `atomic.zig` when a partial write must never be
//! visible. Leaf: depends only on `std`; errors are typed and UI-agnostic
//! so callers own the messaging.

const std = @import("std");

pub const ParentError = error{MakeParentDirFailed};
pub const WriteError = ParentError || error{ OpenFileFailed, WriteFailed };

/// Create the parent chain of `path` (recursive; absolute or relative).
///
/// `createDirPath`'s existence check is nofollow, so an existing
/// symlink-to-dir parent (e.g. macOS `/tmp`) would be rejected as `NotDir` —
/// skip creation when the parent already resolves to a directory.
pub fn ensureParentDir(io: std.Io, path: []const u8) ParentError!void {
    const dir = std.fs.path.dirname(path) orelse return;
    if (dir.len == 0) return;

    // Follows symlinks, so a symlink-to-dir parent counts as already present.
    if (std.Io.Dir.cwd().statFile(io, dir, .{})) |st| {
        if (st.kind == .directory) return;
    } else |_| {}

    std.Io.Dir.cwd().createDirPath(io, dir) catch return error.MakeParentDirFailed;
}

/// Write `bytes` to `path`, creating parent directories as needed and
/// truncating any existing file. Not atomic — a crash mid-write can leave a
/// partial file; use `atomic.zig` when readers must never see one.
pub fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) WriteError!void {
    try ensureParentDir(io, path);
    // createFileAbsolute is createFile on cwd for an absolute path, so one
    // call covers both path kinds.
    const file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true }) catch
        return error.OpenFileFailed;
    defer file.close(io);
    file.writeStreamingAll(io, bytes) catch return error.WriteFailed;
}

// ── tests ──────────────────────────────────────────────────────────────

test "writeFile creates a full absolute parent chain with a missing grandparent" {
    const io = std.Options.debug_io;
    const ts = std.Io.Clock.real.now(io).toNanoseconds();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = std.fmt.bufPrint(&buf, "/tmp/malt_pathwrite_abschain_{d}", .{ts}) catch unreachable;
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var dest_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dest = std.fmt.bufPrint(&dest_buf, "{s}/a/b/out.txt", .{root}) catch unreachable;

    try writeFile(io, dest, "data\n");

    const f = try std.Io.Dir.cwd().openFile(io, dest, .{});
    defer f.close(io);
    try std.testing.expect((try f.stat(io)).size > 0);
}

test "writeFile creates a relative nested parent chain" {
    const io = std.Options.debug_io;
    const ts = std.Io.Clock.real.now(io).toNanoseconds();
    var rel_buf: [64]u8 = undefined;
    const rel_root = std.fmt.bufPrint(&rel_buf, "zz_malt_pathwrite_rel_{d}", .{ts}) catch unreachable;
    defer std.Io.Dir.cwd().deleteTree(io, rel_root) catch {};

    var dest_buf: [128]u8 = undefined;
    const dest = std.fmt.bufPrint(&dest_buf, "{s}/sub/out.txt", .{rel_root}) catch unreachable;

    try writeFile(io, dest, "data\n");

    const f = try std.Io.Dir.cwd().openFile(io, dest, .{});
    defer f.close(io);
    try std.testing.expect((try f.stat(io)).size > 0);
}

test "writeFile accepts a symlink-to-directory parent (e.g. /tmp)" {
    // createDirPath's nofollow kind check rejects an existing symlink-to-dir
    // as NotDir; the writer must still succeed (macOS /tmp → /private/tmp).
    const io = std.Options.debug_io;
    const ts = std.Io.Clock.real.now(io).toNanoseconds();
    var dest_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dest = std.fmt.bufPrint(&dest_buf, "/tmp/malt_pathwrite_symlink_{d}.txt", .{ts}) catch unreachable;
    defer std.Io.Dir.cwd().deleteTree(io, dest) catch {};

    try writeFile(io, dest, "data\n");

    const f = try std.Io.Dir.cwd().openFile(io, dest, .{});
    defer f.close(io);
    try std.testing.expect((try f.stat(io)).size > 0);
}

test "writeFile surfaces MakeParentDirFailed when a parent component is a file" {
    const io = std.Options.debug_io;
    const ts = std.Io.Clock.real.now(io).toNanoseconds();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = std.fmt.bufPrint(&buf, "/tmp/malt_pathwrite_parentfile_{d}", .{ts}) catch unreachable;
    std.Io.Dir.cwd().createDirPath(io, root) catch unreachable;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var blocker_buf: [std.fs.max_path_bytes]u8 = undefined;
    const blocker = std.fmt.bufPrint(&blocker_buf, "{s}/afile", .{root}) catch unreachable;
    (std.Io.Dir.cwd().createFile(io, blocker, .{ .truncate = true }) catch unreachable).close(io);

    var dest_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dest = std.fmt.bufPrint(&dest_buf, "{s}/afile/sub/out.txt", .{root}) catch unreachable;

    try std.testing.expectError(error.MakeParentDirFailed, writeFile(io, dest, "data\n"));
}

test "writeFile surfaces OpenFileFailed when the destination is a directory" {
    const io = std.Options.debug_io;
    const ts = std.Io.Clock.real.now(io).toNanoseconds();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = std.fmt.bufPrint(&buf, "/tmp/malt_pathwrite_destdir_{d}", .{ts}) catch unreachable;
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var dest_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dest = std.fmt.bufPrint(&dest_buf, "{s}/target", .{root}) catch unreachable;
    std.Io.Dir.cwd().createDirPath(io, dest) catch unreachable; // dest is a dir

    try std.testing.expectError(error.OpenFileFailed, writeFile(io, dest, "data\n"));
}

test "ensureParentDir is a no-op for a bare filename (no directory component)" {
    // dirname("out.txt") is null → nothing to create, no error.
    try ensureParentDir(std.Options.debug_io, "out.txt");
}

test "ensureParentDir creates a missing directory chain" {
    const io = std.Options.debug_io;
    const ts = std.Io.Clock.real.now(io).toNanoseconds();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = std.fmt.bufPrint(&buf, "/tmp/malt_pathwrite_ensure_{d}", .{ts}) catch unreachable;
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var child_buf: [std.fs.max_path_bytes]u8 = undefined;
    const child = std.fmt.bufPrint(&child_buf, "{s}/x/y/out.txt", .{root}) catch unreachable;
    try ensureParentDir(io, child);

    var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
    const parent = std.fmt.bufPrint(&parent_buf, "{s}/x/y", .{root}) catch unreachable;
    const st = try std.Io.Dir.cwd().statFile(io, parent, .{});
    try std.testing.expect(st.kind == .directory);
}

test "writeFile truncates an existing file and reuses its existing parent" {
    // A second write to the same path: parent already exists (skip create),
    // and a shorter payload must leave no stale tail.
    const io = std.Options.debug_io;
    const ts = std.Io.Clock.real.now(io).toNanoseconds();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dest = std.fmt.bufPrint(&buf, "/tmp/malt_pathwrite_trunc_{d}.txt", .{ts}) catch unreachable;
    defer std.Io.Dir.cwd().deleteTree(io, dest) catch {};

    try writeFile(io, dest, "a long first payload");
    try writeFile(io, dest, "x");

    const f = try std.Io.Dir.cwd().openFile(io, dest, .{});
    defer f.close(io);
    try std.testing.expectEqual(@as(u64, 1), (try f.stat(io)).size);
}

test "writeFile writes a zero-length file for empty bytes" {
    const io = std.Options.debug_io;
    const ts = std.Io.Clock.real.now(io).toNanoseconds();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dest = std.fmt.bufPrint(&buf, "/tmp/malt_pathwrite_empty_{d}.txt", .{ts}) catch unreachable;
    defer std.Io.Dir.cwd().deleteTree(io, dest) catch {};

    try writeFile(io, dest, "");

    const f = try std.Io.Dir.cwd().openFile(io, dest, .{});
    defer f.close(io);
    try std.testing.expectEqual(@as(u64, 0), (try f.stat(io)).size);
}
