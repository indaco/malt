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
