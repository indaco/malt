const std = @import("std");
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
/// copy-on-write clones (ENOTSUP). `allocator` only participates in the
/// fallback path (for the directory walker); APFS-native clones are a
/// single syscall and do not allocate.
pub fn cloneTree(io: std.Io, allocator: std.mem.Allocator, src_path: []const u8, dst_path: []const u8) CloneError!void {
    const src_z = std.posix.toPosixPath(src_path) catch return error.IoError;
    const dst_z = std.posix.toPosixPath(dst_path) catch return error.IoError;

    const rc = c.clonefile(&src_z, &dst_z, 0);
    if (rc == 0) return;

    // clonefile(2) is libc-style: -1 on error with errno set globally.
    // Read errno directly; std.posix.errno expects a Zig-syscall return.
    const e: std.c.E = @enumFromInt(std.c._errno().*);
    switch (e) {
        .OPNOTSUPP => {
            copyTreeFallback(io, allocator, src_path, dst_path) catch return error.IoError;
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

pub fn copyTreeFallback(io: std.Io, allocator: std.mem.Allocator, src_path: []const u8, dst_path: []const u8) !void {
    var src_dir = std.Io.Dir.openDirAbsolute(io, src_path, .{ .iterate = true }) catch return error.FileNotFound;
    defer src_dir.close(io);

    std.Io.Dir.createDirAbsolute(io, dst_path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var dst_dir = std.Io.Dir.openDirAbsolute(io, dst_path, .{}) catch return error.FileNotFound;
    defer dst_dir.close(io);

    var walker = src_dir.walk(allocator) catch return error.OutOfMemory;
    defer walker.deinit();

    // Per-entry clone is opportunistic: any single-entry failure skips that
    // path and continues the walk. Callers verify the final tree shape.
    while (walker.next(io) catch return error.AccessDenied) |entry| {
        switch (entry.kind) {
            .directory => {
                dst_dir.createDirPath(io, entry.path) catch {};
            },
            .file => {
                if (std.fs.path.dirname(entry.path)) |parent| {
                    dst_dir.createDirPath(io, parent) catch {};
                }
                std.Io.Dir.copyFile(entry.dir, entry.basename, dst_dir, entry.path, io, .{}) catch {};
            },
            .sym_link => {
                var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const n = std.Io.Dir.readLink(entry.dir, io, entry.basename, &link_buf) catch continue;
                dst_dir.symLink(io, link_buf[0..n], entry.path, .{}) catch {};
            },
            else => {},
        }
    }
}
