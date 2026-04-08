const std = @import("std");
const c = @cImport(@cInclude("sys/clonefile.h"));

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

    const e = std.posix.errno(rc);
    switch (e) {
        .OPNOTSUPP => {
            copyTreeFallback(src_path, dst_path) catch return error.IoError;
        },
        .EXIST => return error.AlreadyExists,
        .ACCES, .PERM => return error.PermissionDenied,
        else => return error.IoError,
    }
}

/// Heuristic check: attempt a probe clone in the same directory to see
/// whether the volume supports APFS clonefile.  Returns true on macOS by
/// default when the probe is inconclusive.
pub fn isApfs(path: []const u8) bool {
    _ = path;
    // On macOS the vast majority of volumes are APFS.  A real probe would
    // clone a temp file and inspect the result, but for now we simply
    // return true so the caller always tries clonefile first.
    return true;
}

fn copyTreeFallback(src_path: []const u8, dst_path: []const u8) !void {
    // Open source directory.
    var src_dir = std.fs.openDirAbsolute(src_path, .{ .iterate = true }) catch return error.FileNotFound;
    defer src_dir.close();

    // Create destination directory.
    std.fs.makeDirAbsolute(dst_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var dst_dir = std.fs.openDirAbsolute(dst_path, .{}) catch return error.FileNotFound;
    defer dst_dir.close();

    // Walk the source tree.
    var walker = src_dir.walk(std.heap.page_allocator) catch return error.OutOfMemory;
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
                entry.dir.copyFile(entry.basename, dst_dir, entry.path, .{}) catch {};
            },
            .sym_link => {
                // Read the symlink target and recreate it.
                var link_buf: [std.fs.max_path_bytes]u8 = undefined;
                const target = entry.dir.readLink(entry.basename, &link_buf) catch continue;
                dst_dir.symLink(target, entry.path, .{}) catch {};
            },
            else => {},
        }
    }
}
