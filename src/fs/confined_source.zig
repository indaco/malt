//! Open an existing file only after proving its resolved path stays below a
//! trusted source root. The component-by-component reopen keeps the check and
//! use tied to directory handles and refuses symlinks introduced after the
//! canonical-path check.

const std = @import("std");

pub const OpenedFile = struct {
    allocator: std.mem.Allocator,
    path: [:0]u8,
    file: std.Io.File,

    pub fn deinit(self: *OpenedFile, io: std.Io) void {
        self.file.close(io);
        self.allocator.free(self.path);
    }

    /// Atomically replace `dest_path` with a copy of the already-confined file.
    pub fn copyToAbsolute(self: *OpenedFile, io: std.Io, dest_path: []const u8) !void {
        const stat = try self.file.stat(io);
        if (stat.kind != .file) return error.NotFile;

        var reader: std.Io.File.Reader = .init(self.file, io, &.{});
        reader.size = stat.size;

        var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, dest_path, .{
            .permissions = stat.permissions,
            .replace = true,
        });
        defer atomic_file.deinit(io);

        var buffer: [1024]u8 = undefined;
        var writer = atomic_file.file.writer(io, &buffer);
        _ = writer.interface.sendFileAll(&reader, .unlimited) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            error.WriteFailed => return writer.err.?,
        };
        try writer.flush();
        try atomic_file.replace(io);
    }
};

/// Resolve `candidate`, require the result to be below `root`, then reopen the
/// canonical path without following any component symlinks. The returned path
/// and file refer to the checked in-root object.
pub fn openFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    candidate: []const u8,
    mode: std.Io.Dir.OpenFileOptions.Mode,
) !OpenedFile {
    const root_real = try std.Io.Dir.realPathFileAbsoluteAlloc(io, root, allocator);
    defer allocator.free(root_real);
    const source_real = try std.Io.Dir.realPathFileAbsoluteAlloc(io, candidate, allocator);
    errdefer allocator.free(source_real);

    if (!pathHasPrefix(source_real, root_real) or source_real.len == root_real.len) {
        return error.AccessDenied;
    }
    const relative = source_real[root_real.len + 1 ..];

    var dir = try openCanonicalDirNoFollow(io, root_real);
    defer dir.close(io);

    if (std.fs.path.dirname(relative)) |parent| {
        var components = std.mem.tokenizeScalar(u8, parent, '/');
        while (components.next()) |component| {
            const next = try dir.openDir(io, component, .{ .follow_symlinks = false });
            dir.close(io);
            dir = next;
        }
    }

    const file = try dir.openFile(io, std.fs.path.basename(relative), .{
        .mode = mode,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    errdefer file.close(io);
    if ((try file.stat(io)).kind != .file) return error.NotFile;

    return .{
        .allocator = allocator,
        .path = source_real,
        .file = file,
    };
}

/// Open every component of an already-canonical absolute directory path with
/// symlink following disabled. Opening only the final component would leave an
/// intermediate-directory swap between `realPath` and `open` exploitable.
fn openCanonicalDirNoFollow(io: std.Io, path: []const u8) !std.Io.Dir {
    if (!std.fs.path.isAbsolute(path)) return error.BadPathName;

    var dir = try std.Io.Dir.openDirAbsolute(io, "/", .{ .follow_symlinks = false });
    errdefer dir.close(io);
    var components = std.mem.tokenizeScalar(u8, path, '/');
    while (components.next()) |component| {
        const next = try dir.openDir(io, component, .{ .follow_symlinks = false });
        dir.close(io);
        dir = next;
    }
    return dir;
}

fn pathHasPrefix(path: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0 or !std.mem.startsWith(u8, path, prefix)) return false;
    return path.len == prefix.len or prefix[prefix.len - 1] == '/' or path[prefix.len] == '/';
}

test "openFile allows an internal symlink but rejects an external one" {
    const io = std.Options.debug_io;
    const a = std.testing.allocator;
    const base = try std.fmt.allocPrintSentinel(a, "/tmp/malt_confined_source_{d}", .{std.c.getpid()}, 0);
    defer a.free(base);
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};

    const root = try std.fmt.allocPrint(a, "{s}/root", .{base});
    defer a.free(root);
    const real = try std.fmt.allocPrint(a, "{s}/real", .{root});
    defer a.free(real);
    const inside = try std.fmt.allocPrint(a, "{s}/inside", .{root});
    defer a.free(inside);
    const outside = try std.fmt.allocPrint(a, "{s}/outside", .{base});
    defer a.free(outside);
    const escaped = try std.fmt.allocPrint(a, "{s}/escaped", .{root});
    defer a.free(escaped);

    try std.Io.Dir.cwd().createDirPath(io, root);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, real, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "inside");
    }
    {
        const f = try std.Io.Dir.createFileAbsolute(io, outside, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "outside");
    }
    try std.Io.Dir.symLinkAbsolute(io, real, inside, .{});
    try std.Io.Dir.symLinkAbsolute(io, outside, escaped, .{});

    var opened = try openFile(io, a, root, inside, .read_only);
    opened.deinit(io);
    try std.testing.expectError(error.AccessDenied, openFile(io, a, root, escaped, .read_only));
}
