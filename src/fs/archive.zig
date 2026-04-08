const std = @import("std");

/// Extracts a tar.gz archive from the given input reader into output_dir.
pub fn extractTarGz(input: *std.Io.Reader, output_dir: std.fs.Dir) !void {
    // gzip decompressor needs a window buffer of at least max_window_len
    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(input, .gzip, &window_buf);
    try std.tar.pipeToFileSystem(output_dir, &decompressor.reader, .{});
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
    var child = std.process.Child.init(&argv, std.heap.page_allocator);
    child.spawn() catch return error.ExtractionFailed;
    const term = child.wait() catch return error.ExtractionFailed;
    switch (term) {
        .Exited => |code| {
            if (code != 0) return error.ExtractionFailed;
        },
        else => return error.ExtractionFailed,
    }
}
