const std = @import("std");
const io_mod = @import("../ui/io.zig");
const fs_compat = @import("compat.zig");

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

/// Extract a tar.gz archive from `archive_path` into `dest_dir` using
/// the native 0.16 `std.compress.flate` + `std.tar.pipeToFileSystem`
/// pipeline — no `tar` subprocess. The 0.15 decompressor was known to
/// panic (unreachable in `Writer.rebase`) on malformed gzip streams;
/// 0.16's flate surfaces those as plain errors, so we can stream the
/// archive in-process and skip a fork/exec per bottle.
///
/// The archive is validated to start with the gzip magic (0x1f 0x8b)
/// before handing off to the decompressor so a truncated download or
/// an HTML error page saved with a .tar.gz extension fails fast with
/// a clear error rather than a mid-stream decompression fault.
///
/// `pipeToFileSystem`'s default `ModeMode.executable_bit_only` copies
/// the owner-exec bit into group/other on regular files, matching what
/// `tar xzf` produces on macOS bottles. Symlinks and nested directories
/// are materialised via the normal tar-entry handlers.
pub fn extractTarGz(archive_path: []const u8, dest_dir: []const u8) !void {
    var magic: [2]u8 = undefined;
    const n = try sniffMagic(archive_path, &magic);
    if (n < 2 or magic[0] != 0x1f or magic[1] != 0x8b) {
        return error.ExtractionFailed;
    }

    const io = io_mod.ctx();

    var file = std.Io.Dir.openFileAbsolute(io, archive_path, .{}) catch return error.ExtractionFailed;
    defer file.close(io);

    // 16 KiB input buffer — enough to amortise per-read syscalls without
    // holding a page-sized read-ahead on the stack for every extract.
    var file_buf: [16 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);
    const input: *std.Io.Reader = &file_reader.interface;

    // flate.max_window_len is 64 KiB — fine on the stack here, same
    // shape `extractTarZst` uses for the zstd decompressor.
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(input, .gzip, &window);

    var dir = std.Io.Dir.openDirAbsolute(io, dest_dir, .{}) catch return error.ExtractionFailed;
    defer dir.close(io);

    std.tar.pipeToFileSystem(io, dir, &decompress.reader, .{}) catch return error.ExtractionFailed;
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
    var child = fs_compat.Child.init(&argv, child_allocator);
    child.spawn() catch return error.ExtractionFailed;
    const term = child.wait() catch return error.ExtractionFailed;
    switch (term) {
        .exited => |code| {
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
    var child = fs_compat.Child.init(&argv, child_allocator);
    child.spawn() catch return error.ExtractionFailed;
    const term = child.wait() catch return error.ExtractionFailed;
    switch (term) {
        .exited => |code| {
            if (code != 0) return error.ExtractionFailed;
        },
        else => return error.ExtractionFailed,
    }
}
