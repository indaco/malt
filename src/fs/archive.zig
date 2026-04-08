const std = @import("std");

/// Extracts a tar.gz archive from the given input reader into output_dir.
pub fn extractTarGz(input: anytype, output_dir: std.fs.Dir) !void {
    _ = .{ input, output_dir };
    return error.NotImplemented;
}

/// Extracts a tar.zst archive from the given input reader into output_dir.
pub fn extractTarZst(input: anytype, output_dir: std.fs.Dir) !void {
    _ = .{ input, output_dir };
    return error.NotImplemented;
}
