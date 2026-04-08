const std = @import("std");

/// Extracts a tar.gz archive from the given input reader into output_dir.
///
/// The caller must provide an `*std.Io.Reader` that yields raw gzip-compressed
/// tar bytes.  Internally this pipes through `std.compress.flate.Decompress`
/// (with `.gzip` container) and then `std.tar.pipeToFileSystem`.
pub fn extractTarGz(input: *std.Io.Reader, output_dir: std.fs.Dir) !void {
    // gzip decompressor — pass empty buffer so the direct vtable is used
    // (no caller-owned window needed when streaming to a Writer).
    var decompressor = std.compress.flate.Decompress.init(input, .gzip, &.{});
    try std.tar.pipeToFileSystem(output_dir, &decompressor.reader, .{});
}

/// Extracts a tar.zst archive from the given input reader into output_dir.
///
/// The caller must provide an `*std.Io.Reader` that yields raw zstd-compressed
/// tar bytes.  Internally this pipes through `std.compress.zstd.Decompress`
/// and then `std.tar.pipeToFileSystem`.
pub fn extractTarZst(input: *std.Io.Reader, output_dir: std.fs.Dir) !void {
    // zstd decompressor — pass empty buffer so the direct vtable is used.
    var decompressor = std.compress.zstd.Decompress.init(input, &.{}, .{});
    try std.tar.pipeToFileSystem(output_dir, &decompressor.reader, .{});
}
