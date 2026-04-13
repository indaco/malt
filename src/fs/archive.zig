const std = @import("std");

/// `c_allocator` is used for `std.process.Child` internals (argv/env
/// bookkeeping) throughout this module. Callers may be running under an
/// arena, but the child process allocates a handful of bytes that live only
/// for the duration of the spawn and are freed via the child's own deinit —
/// routing them through the caller's arena would give the arena a growing
/// pool of noise for zero benefit. Kept on libc alloc for clarity.
const child_allocator = std.heap.c_allocator;

/// Extracts a tar.gz archive from the given input reader into output_dir.
/// Uses the system `tar` command to avoid Zig stdlib flate decompressor
/// panics on corrupt/truncated gzip streams (Zig issue: unreachable in
/// Writer.rebase when the inflate state machine encounters malformed data).
pub fn extractTarGz(_: *std.Io.Reader, output_dir: std.fs.Dir) !void {
    // We need the absolute path of the output dir and the archive file.
    // The archive is always written to {output_dir}/bottle.tar.gz by the
    // download step before extractTarGz is called.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = output_dir.realpath(".", &path_buf) catch return error.ExtractionFailed;

    var archive_buf: [std.fs.max_path_bytes]u8 = undefined;
    const archive_path = std.fmt.bufPrint(&archive_buf, "{s}/bottle.tar.gz", .{dir_path}) catch
        return error.ExtractionFailed;

    // Verify the archive exists and has gzip magic bytes
    const archive_file = std.fs.openFileAbsolute(archive_path, .{}) catch return error.ExtractionFailed;
    var magic: [2]u8 = undefined;
    const n = archive_file.readAll(&magic) catch {
        archive_file.close();
        return error.ExtractionFailed;
    };
    archive_file.close();
    if (n < 2 or magic[0] != 0x1f or magic[1] != 0x8b) {
        return error.ExtractionFailed;
    }

    // Use system tar — immune to Zig flate decompressor panics
    const argv = [_][]const u8{ "tar", "xzf", archive_path, "-C", dir_path };
    var child = std.process.Child.init(&argv, child_allocator);
    child.spawn() catch return error.ExtractionFailed;
    const term = child.wait() catch return error.ExtractionFailed;
    switch (term) {
        .Exited => |code| {
            if (code != 0) return error.ExtractionFailed;
        },
        else => return error.ExtractionFailed,
    }
}

/// Extracts a tar.zst archive from the given input reader into output_dir.
pub fn extractTarZst(input: *std.Io.Reader, output_dir: std.fs.Dir) !void {
    var window_buf: [std.compress.zstd.default_window_len]u8 = undefined;
    var decompressor = std.compress.zstd.Decompress.init(input, &window_buf, .{});
    try std.tar.pipeToFileSystem(output_dir, &decompressor.reader, .{});
}

/// Extracts a tar.xz archive file to a directory using the system `tar` command.
/// Zig 0.15's xz decompressor uses the legacy I/O API which doesn't integrate
/// with std.tar, so we shell out to the system tar (always available on macOS).
pub fn extractTarXzFile(archive_path: []const u8, dest_dir: []const u8) !void {
    const argv = [_][]const u8{ "tar", "xf", archive_path, "-C", dest_dir };
    var child = std.process.Child.init(&argv, child_allocator);
    child.spawn() catch return error.ExtractionFailed;
    const term = child.wait() catch return error.ExtractionFailed;
    switch (term) {
        .Exited => |code| {
            if (code != 0) return error.ExtractionFailed;
        },
        else => return error.ExtractionFailed,
    }
}
