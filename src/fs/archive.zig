const std = @import("std");
const io_mod = @import("../ui/io.zig");

/// `c_allocator` is used for `std.process.Child` internals (argv/env
/// bookkeeping) throughout this module. Callers may be running under an
/// arena, but the child process allocates a handful of bytes that live only
/// for the duration of the spawn and are freed via the child's own deinit —
/// routing them through the caller's arena would give the arena a growing
/// pool of noise for zero benefit. Kept on libc alloc for clarity.
const child_allocator = std.heap.c_allocator;

/// Read up to `out.len` bytes from the file at `absolute_path`, returning how
/// many were actually read. Used for the magic-byte sniff before handing a
/// downloaded archive off to an external extractor.
fn sniffMagic(absolute_path: []const u8, out: []u8) !usize {
    const io = io_mod.ctx();
    const file = std.Io.Dir.openFileAbsolute(io, absolute_path, .{}) catch return error.ExtractionFailed;
    defer file.close(io);
    return file.readPositionalAll(io, out, 0) catch return error.ExtractionFailed;
}

/// Extract a tar.gz archive from `archive_path` into `dest_dir`. Uses the
/// system `tar` command to avoid Zig stdlib flate decompressor panics on
/// corrupt/truncated gzip streams (Zig issue: unreachable in Writer.rebase
/// when the inflate state machine encounters malformed data). The archive
/// is validated to start with the gzip magic (0x1f 0x8b) before spawning
/// tar, which gives a clear error on truncated downloads or wrong-mime
/// responses (e.g. HTML error pages saved with a .tar.gz extension).
pub fn extractTarGz(archive_path: []const u8, dest_dir: []const u8) !void {
    var magic: [2]u8 = undefined;
    const n = try sniffMagic(archive_path, &magic);
    if (n < 2 or magic[0] != 0x1f or magic[1] != 0x8b) {
        return error.ExtractionFailed;
    }

    const argv = [_][]const u8{ "tar", "xzf", archive_path, "-C", dest_dir };
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
pub fn extractTarZst(input: *std.Io.Reader, output_dir: std.Io.Dir) !void {
    var window_buf: [std.compress.zstd.default_window_len]u8 = undefined;
    var decompressor = std.compress.zstd.Decompress.init(input, &window_buf, .{});
    try std.tar.pipeToFileSystem(io_mod.ctx(), output_dir, &decompressor.reader, .{});
}

/// Extract a .zip archive to `dest_dir`. Used by the tap-install path
/// for formulae whose upstream release artifacts are zip-packed (e.g.
/// every HashiCorp tool, and a handful of other popular user taps).
/// Shells out to the system `unzip` — always present on macOS, and
/// its behavior on binary-only archives is boring and well understood.
/// Validates the PKZip magic `PK\x03\x04` up front so an HTML error
/// page saved as .zip gives a clean error instead of propagating up
/// from unzip's own output.
pub fn extractZip(archive_path: []const u8, dest_dir: []const u8) !void {
    var magic: [4]u8 = undefined;
    const n = try sniffMagic(archive_path, &magic);
    if (n < 4 or magic[0] != 'P' or magic[1] != 'K' or magic[2] != 0x03 or magic[3] != 0x04) {
        return error.ExtractionFailed;
    }

    // -q: quiet, -o: overwrite without prompting, -d: destination dir.
    const argv = [_][]const u8{ "unzip", "-q", "-o", archive_path, "-d", dest_dir };
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
