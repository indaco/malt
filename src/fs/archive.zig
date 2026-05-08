const std = @import("std");

/// `c_allocator` is used for `std.process.Child` internals (argv/env
/// bookkeeping) throughout this module. Callers may be running under an
/// arena, but the child process allocates a handful of bytes that live only
/// for the duration of the spawn and are freed via the child's own deinit —
/// routing them through the caller's arena would give the arena a growing
/// pool of noise for zero benefit. Kept on libc alloc for clarity.
const child_allocator = std.heap.c_allocator;

/// archive entries can escape dest; reject before extract.
/// Reject absolute, `..`-bearing, NUL-bearing, or empty names — `.`
/// components are tolerated since tar routinely emits `./name`.
pub fn isSafeEntryPath(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] == '/') return false;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return false;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, "..")) return false;
    }
    return true;
}

/// Symlink targets may climb to a sibling inside the bundle (Apple
/// `.xctoolchain`) or one level above it — bottles reach sibling formulas
/// via `<prefix>/opt/<name>`, resolved against the implicit Cellar parent.
/// Resolve `link_name` lexically against `dirname(entry_name)` and reject
/// climbs deeper than that, plus absolute, empty, or NUL-bearing targets.
/// `entry_name` is assumed to have passed `isSafeEntryPath`, so a later
/// entry cannot chain through the escape beyond the prefix parent.
pub fn isSafeSymlinkTarget(entry_name: []const u8, link_name: []const u8) bool {
    if (link_name.len == 0) return false;
    if (link_name[0] == '/') return false;
    if (std.mem.indexOfScalar(u8, link_name, 0) != null) return false;

    // Parent depth: components in entry_name minus the symlink's own slot.
    var parent_depth: isize = 0;
    var name_it = std.mem.splitScalar(u8, entry_name, '/');
    while (name_it.next()) |comp| {
        if (comp.len == 0 or std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) return false;
        parent_depth += 1;
    }
    if (parent_depth == 0) return false;
    parent_depth -= 1;

    var depth = parent_depth;
    var link_it = std.mem.splitScalar(u8, link_name, '/');
    while (link_it.next()) |comp| {
        if (comp.len == 0 or std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            depth -= 1;
            // -1 lands in the prefix parent (legitimate bottle shape);
            // anything beyond is genuine escape.
            if (depth < -1) return false;
        } else {
            depth += 1;
        }
    }
    return true;
}

/// Read up to `out.len` bytes from the file at `absolute_path`, returning how
/// many were actually read. Used for the magic-byte sniff before handing a
/// downloaded archive off to an external extractor.
fn sniffMagic(io: std.Io, absolute_path: []const u8, out: []u8) !usize {
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
///
/// Hard-link entries (zig 0.16's `std.tar.FileKind` lacks `.hard_link`)
/// are recovered via a raw header pre-scan and re-applied with
/// `std.c.link` after `pipeToFileSystem` returns.
pub fn extractTarGz(io: std.Io, archive_path: []const u8, dest_dir: []const u8) !void {
    var magic: [2]u8 = undefined;
    const n = try sniffMagic(io, archive_path, &magic);
    if (n < 2 or magic[0] != 0x1f or magic[1] != 0x8b) {
        return error.ExtractionFailed;
    }

    // Pre-scan first: extraction streams in order, so a safe entry
    // before a hostile one would already be on disk. Same pass collects
    // hardlink pairs the std iterator silently drops.
    var pre_arena = std.heap.ArenaAllocator.init(child_allocator);
    defer pre_arena.deinit();
    const hardlinks = try preScanTarGz(io, pre_arena.allocator(), archive_path);

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

    // Diagnostics sink absorbs hard-link entries; we re-apply them
    // post-pass. Any other logged category is a real failure.
    var diags: std.tar.Diagnostics = .{ .allocator = pre_arena.allocator() };
    defer diags.deinit();
    std.tar.pipeToFileSystem(io, dir, &decompress.reader, .{ .diagnostics = &diags }) catch
        return error.ExtractionFailed;
    for (diags.errors.items) |item| switch (item) {
        .unsupported_file_type => |info| if (info.file_type != .hard_link) return error.ExtractionFailed,
        else => return error.ExtractionFailed,
    };

    if (hardlinks.len > 0) {
        try applyHardLinks(dest_dir, hardlinks);
    }
}

const HardLink = struct {
    name: []const u8,
    target: []const u8,
};

/// Recreate each `target -> name` hard link inside `dest_dir`. Uses
/// `linkat` with flags=0 (no AT_SYMLINK_FOLLOW) so a hardlink whose
/// target is itself a symlink shares the symlink inode rather than the
/// symlink's target inode - macOS `link(2)` follows by default, which
/// would let an archive craft a hardlink that escapes via a symlink hop.
fn applyHardLinks(dest_dir: []const u8, links: []const HardLink) !void {
    var target_buf: [std.Io.Dir.max_path_bytes * 2]u8 = undefined;
    var name_buf: [std.Io.Dir.max_path_bytes * 2]u8 = undefined;
    for (links) |hl| {
        const target_z = std.fmt.bufPrintZ(&target_buf, "{s}/{s}", .{ dest_dir, hl.target }) catch
            return error.ExtractionFailed;
        const name_z = std.fmt.bufPrintZ(&name_buf, "{s}/{s}", .{ dest_dir, hl.name }) catch
            return error.ExtractionFailed;
        if (std.c.linkat(std.c.AT.FDCWD, target_z.ptr, std.c.AT.FDCWD, name_z.ptr, 0) != 0) {
            return error.ExtractionFailed;
        }
    }
}

/// Walk the tar archive at raw 512-byte blocks to enforce path safety
/// AND recover hard-link pairs the std iterator silently drops.
/// Pax/GNU long-name extensions are uninterpreted: a hardlink whose
/// name lives in a pax header is not found here. Homebrew bottles use
/// plain ustar paths, so the gap is acceptable for the current scope.
fn preScanTarGz(
    io: std.Io,
    arena: std.mem.Allocator,
    archive_path: []const u8,
) ![]const HardLink {
    var file = std.Io.Dir.openFileAbsolute(io, archive_path, .{}) catch return error.ExtractionFailed;
    defer file.close(io);

    var file_buf: [16 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);
    const input: *std.Io.Reader = &file_reader.interface;

    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(input, .gzip, &window);
    const r: *std.Io.Reader = &decompress.reader;

    var hardlinks: std.ArrayList(HardLink) = .empty;

    while (true) {
        var header: [512]u8 = undefined;
        const got = r.readSliceShort(&header) catch return error.ExtractionFailed;
        if (got == 0) break;
        if (got < 512) return error.ExtractionFailed;
        // First zero block ends the scan. Tar formally requires two,
        // but no valid header lives between them, and parsing further
        // would let trailing pad/garbage get re-interpreted as headers.
        if (std.mem.allEqual(u8, &header, 0)) break;
        if (!validChksum(&header)) return error.ExtractionFailed;

        const kind_byte = header[156];
        const size = parseHeaderOctal(header[124..136]) catch return error.ExtractionFailed;

        // ustar combines bytes[345..500] (prefix) + '/' + bytes[0..100] (name).
        const ustar = std.mem.eql(u8, header[257..262], "ustar");
        const raw_name = nullSlice(header[0..100]);
        const raw_prefix = if (ustar) nullSlice(header[345..500]) else "";
        var name_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const name = composePath(&name_buf, raw_prefix, raw_name) catch return error.ExtractionFailed;

        if (!isSafeEntryPath(name)) return error.ExtractionFailed;

        const link_name = nullSlice(header[157..257]);
        switch (kind_byte) {
            // Symbolic link: link target is interpreted relative to the
            // entry's parent directory (POSIX). Reuse the existing
            // bottle-aware target check.
            '2' => if (!isSafeSymlinkTarget(name, link_name)) return error.ExtractionFailed,
            // Hard link: target is a tar-relative path identical in
            // shape to a regular entry name.
            '1' => {
                if (!isSafeEntryPath(link_name)) return error.ExtractionFailed;
                try hardlinks.append(arena, .{
                    .name = try arena.dupe(u8, name),
                    .target = try arena.dupe(u8, link_name),
                });
            },
            else => {},
        }

        // Advance past the data payload (rounded up to the next 512-byte
        // boundary). Symlinks/hardlinks/dirs report size 0 so this is a
        // no-op for them, but pax/gnu extension blocks DO carry data.
        const skip_bytes: u64 = (size + 511) / 512 * 512;
        if (skip_bytes > 0) {
            r.discardAll64(skip_bytes) catch return error.ExtractionFailed;
        }
    }

    return hardlinks.toOwnedSlice(arena);
}

/// `nullStr` from std.tar - first NUL terminates, full slice otherwise.
fn nullSlice(buf: []const u8) []const u8 {
    return buf[0 .. std.mem.indexOfScalar(u8, buf, 0) orelse buf.len];
}

/// Parse a tar octal field (ASCII digits, possibly leading zeros, often
/// padded with NULs/spaces). Empty fields decode as 0.
fn parseHeaderOctal(raw: []const u8) !u64 {
    const ltrim = std.mem.trimStart(u8, raw, "0 ");
    const rtrim = std.mem.trimEnd(u8, ltrim, " \x00");
    if (rtrim.len == 0) return 0;
    return std.fmt.parseInt(u64, rtrim, 8);
}

/// ustar prefix + '/' + name. Pre-ustar archives leave prefix empty.
fn composePath(buf: []u8, prefix: []const u8, name: []const u8) ![]const u8 {
    if (prefix.len == 0) {
        if (name.len > buf.len) return error.NameTooLong;
        @memcpy(buf[0..name.len], name);
        return buf[0..name.len];
    }
    const total = prefix.len + 1 + name.len;
    if (total > buf.len) return error.NameTooLong;
    @memcpy(buf[0..prefix.len], prefix);
    buf[prefix.len] = '/';
    @memcpy(buf[prefix.len + 1 ..][0..name.len], name);
    return buf[0..total];
}

/// Tar header checksum: ASCII octal at bytes 148..156, computed over the
/// whole header with bytes 148..156 treated as spaces (0x20). Reject
/// blocks that fail to validate - re-syncing on a corrupted tar would
/// produce spurious hardlink hits.
fn validChksum(header: *const [512]u8) bool {
    const stored = parseHeaderOctal(header[148..156]) catch return false;
    var sum: u64 = 0;
    for (header, 0..) |b, i| {
        sum += if (i >= 148 and i < 156) ' ' else b;
    }
    return sum == stored;
}

/// Extracts a tar.zst archive from the given input reader into output_dir.
pub fn extractTarZst(io: std.Io, input: *std.Io.Reader, output_dir: std.Io.Dir) !void {
    var window_buf: [std.compress.zstd.default_window_len]u8 = undefined;
    var decompressor = std.compress.zstd.Decompress.init(input, &window_buf, .{});
    try std.tar.pipeToFileSystem(io, output_dir, &decompressor.reader, .{});
}

/// Extract a .zip archive to `dest_dir`. Used by the tap-install path
/// for formulae whose upstream release artifacts are zip-packed (e.g.
/// every HashiCorp tool, and a handful of other popular user taps).
/// Shells out to the system `unzip` — always present on macOS, and
/// its behavior on binary-only archives is boring and well understood.
/// Validates the PKZip magic `PK\x03\x04` up front so an HTML error
/// page saved as .zip gives a clean error instead of propagating up
/// from unzip's own output.
pub fn extractZip(io: std.Io, archive_path: []const u8, dest_dir: []const u8) !void {
    var magic: [4]u8 = undefined;
    const n = try sniffMagic(io, archive_path, &magic);
    if (n < 4 or magic[0] != 'P' or magic[1] != 'K' or magic[2] != 0x03 or magic[3] != 0x04) {
        return error.ExtractionFailed;
    }

    try validateZip(io, archive_path);

    // -q: quiet, -o: overwrite without prompting, -d: destination dir.
    const argv = [_][]const u8{ "unzip", "-q", "-o", archive_path, "-d", dest_dir };
    var child = std.process.spawn(io, .{
        .argv = &argv,
    }) catch return error.ExtractionFailed;
    const term = child.wait(io) catch return error.ExtractionFailed;
    switch (term) {
        .exited => |code| {
            if (code != 0) return error.ExtractionFailed;
        },
        else => return error.ExtractionFailed,
    }
}

fn validateZip(io: std.Io, archive_path: []const u8) !void {
    // `-Z1` prints one entry name per line with no headers or sizes —
    // a zero-column listing we can scan without parsing unzip's table.
    const argv = [_][]const u8{ "unzip", "-Z1", archive_path };
    try validateSubprocessListing(io, &argv);
}

/// Extracts a tar.xz archive file to a directory using the system `tar` command.
/// Zig 0.15's xz decompressor uses the legacy I/O API which doesn't integrate
/// with std.tar, so we shell out to the system tar (always available on macOS).
/// `--no-same-permissions`/`--no-same-owner` stop tar from honouring archived
/// uid/mode bits on extract — downloaded archives should not shape the
/// on-disk identity of what they produce.
pub fn extractTarXzFile(io: std.Io, archive_path: []const u8, dest_dir: []const u8) !void {
    try validateTarListing(io, archive_path);

    const argv = [_][]const u8{ "tar", "xf", archive_path, "-C", dest_dir, "--no-same-permissions", "--no-same-owner" };
    var child = std.process.spawn(io, .{
        .argv = &argv,
    }) catch return error.ExtractionFailed;
    const term = child.wait(io) catch return error.ExtractionFailed;
    switch (term) {
        .exited => |code| {
            if (code != 0) return error.ExtractionFailed;
        },
        else => return error.ExtractionFailed,
    }
}

fn validateTarListing(io: std.Io, archive_path: []const u8) !void {
    const argv = [_][]const u8{ "tar", "tf", archive_path };
    try validateSubprocessListing(io, &argv);
}

/// Spawn `argv` expecting one entry name per stdout line, and reject the
/// archive if any entry fails `isSafeEntryPath`. Shared by `extractZip`
/// (via `unzip -Z1`) and `extractTarXzFile` (via `tar tf`).
fn validateSubprocessListing(io: std.Io, argv: []const []const u8) !void {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return error.ExtractionFailed;
    const stdout = child.stdout orelse {
        // Reap the child we just spawned; ExtractionFailed is the real signal.
        _ = child.wait(io) catch {};
        return error.ExtractionFailed;
    };
    // 4 MiB cap: bottle/tap listings are orders of magnitude smaller;
    // the bound just prevents a pathological archive from ballooning RAM.
    var buf: [4096]u8 = undefined;
    var r = stdout.readerStreaming(io, &buf);
    const listing = r.interface.allocRemaining(child_allocator, std.Io.Limit.limited(4 * 1024 * 1024)) catch {
        // Reap the child we just spawned; ExtractionFailed is the real signal.
        _ = child.wait(io) catch {};
        return error.ExtractionFailed;
    };
    defer child_allocator.free(listing);
    const term = child.wait(io) catch return error.ExtractionFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.ExtractionFailed,
        else => return error.ExtractionFailed,
    }

    var it = std.mem.splitScalar(u8, listing, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (!isSafeEntryPath(line)) return error.ExtractionFailed;
    }
}
