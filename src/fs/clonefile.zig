const std = @import("std");
const fs_compat = @import("compat.zig");
const io_mod = @import("../ui/io.zig");
const c = @import("c_clonefile");
const statfs_c = @import("c_mount");

pub const CloneError = error{
    AlreadyExists,
    NotSupported,
    PermissionDenied,
    IoError,
};

/// Clone a directory tree using the macOS APFS clonefile(2) syscall.
/// Falls back to a recursive copy when the filesystem does not support
/// copy-on-write clones (ENOTSUP).
pub fn cloneTree(src_path: []const u8, dst_path: []const u8) CloneError!void {
    const src_z = std.posix.toPosixPath(src_path) catch return error.IoError;
    const dst_z = std.posix.toPosixPath(dst_path) catch return error.IoError;

    const rc = c.clonefile(&src_z, &dst_z, 0);
    if (rc == 0) return;

    // clonefile(2) is libc-style: -1 on error with errno set globally.
    // Read errno directly; std.posix.errno expects a Zig-syscall return.
    const e: std.c.E = @enumFromInt(std.c._errno().*);
    switch (e) {
        .OPNOTSUPP => {
            copyTreeFallback(src_path, dst_path) catch return error.IoError;
        },
        .EXIST => return error.AlreadyExists,
        .ACCES, .PERM => return error.PermissionDenied,
        else => return error.IoError,
    }
}

/// Check whether the volume at `path` is APFS using statfs(2).
pub fn isApfs(path: []const u8) bool {
    const posix_path = std.posix.toPosixPath(path) catch return true;
    var stat_buf: statfs_c.struct_statfs = undefined;
    const rc = statfs_c.statfs(&posix_path, &stat_buf);
    if (rc != 0) return true; // assume APFS if probe fails

    // f_fstypename is a fixed-size array; compare the leading bytes
    const fs_name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&stat_buf.f_fstypename)), 0);
    return std.mem.eql(u8, fs_name, "apfs");
}

pub fn copyTreeFallback(src_path: []const u8, dst_path: []const u8) !void {
    // Open source directory.
    var src_dir = fs_compat.openDirAbsolute(src_path, .{ .iterate = true }) catch return error.FileNotFound;
    defer src_dir.close();

    // Create destination directory.
    fs_compat.makeDirAbsolute(dst_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var dst_dir = fs_compat.openDirAbsolute(dst_path, .{}) catch return error.FileNotFound;
    defer dst_dir.close();

    // Walk the source tree.
    var walker = src_dir.walk(std.heap.c_allocator) catch return error.OutOfMemory;
    defer walker.deinit();

    while (walker.next() catch return error.AccessDenied) |entry| {
        switch (entry.kind) {
            .directory => {
                dst_dir.makePath(entry.path) catch {};
            },
            .file => {
                // Ensure parent directory exists in destination.
                if (std.fs.path.dirname(entry.path)) |parent| {
                    dst_dir.makePath(parent) catch {};
                }
                std.Io.Dir.copyFile(entry.dir, entry.basename, dst_dir.inner, entry.path, io_mod.ctx(), .{}) catch {};
            },
            .sym_link => {
                // Read the symlink target and recreate it.
                var link_buf: [fs_compat.max_path_bytes]u8 = undefined;
                const n = std.Io.Dir.readLink(entry.dir, io_mod.ctx(), entry.basename, &link_buf) catch continue;
                dst_dir.symLink(link_buf[0..n], entry.path, .{}) catch {};
            },
            else => {},
        }
    }
}
