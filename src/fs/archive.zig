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

    // flate.max_window_len is 64 KiB — fine on the stack for a per-extract
    // decompressor window.
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
/// Pax extended headers ('x') are interpreted for `linkpath=`/`path=` so
/// the pre-scan validates the *effective* symlink target the extractor
/// will use, not the stale ustar field. GNU long-name extensions remain
/// uninterpreted: a hardlink whose name lives in a GNU header is not found
/// here. Homebrew bottles use plain ustar paths, so that gap is acceptable.
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

    // Pax overrides apply to the single entry that follows the 'x' header,
    // mirroring std.tar: `path=` replaces the name, `linkpath=` the target.
    // Both reset once consumed (or when a new 'x' supersedes them).
    var pax_name: ?[]const u8 = null;
    var pax_link: ?[]const u8 = null;

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

        // Pax extended header: its payload can override the *next* entry's
        // link target (and name). std.tar applies these over the ustar
        // fields, so validating the raw ustar field here would check bytes
        // the extractor never uses. Each 'x' supersedes the previous one.
        if (kind_byte == 'x') {
            pax_name = null;
            pax_link = null;
            try parsePaxOverrides(r, arena, size, &pax_name, &pax_link);
            // The parse consumed exactly `size` bytes; skip only the block pad.
            const pad: u64 = (512 - (size % 512)) % 512;
            if (pad > 0) r.discardAll64(pad) catch return error.ExtractionFailed;
            continue;
        }
        // Global pax header is never applied to later entries (std.tar
        // discards it); skip its payload and keep any pending overrides.
        if (kind_byte == 'g') {
            const skip_g: u64 = (size + 511) / 512 * 512;
            if (skip_g > 0) r.discardAll64(skip_g) catch return error.ExtractionFailed;
            continue;
        }

        // ustar combines bytes[345..500] (prefix) + '/' + bytes[0..100] (name).
        const ustar = std.mem.eql(u8, header[257..262], "ustar");
        const raw_name = nullSlice(header[0..100]);
        const raw_prefix = if (ustar) nullSlice(header[345..500]) else "";
        var name_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const ustar_name = composePath(&name_buf, raw_prefix, raw_name) catch return error.ExtractionFailed;

        if (!isSafeEntryPath(ustar_name)) return error.ExtractionFailed;
        // A pax `path=` override must clear the same bar; std.tar sanitises
        // names regardless, but the pre-scan should not silently diverge.
        if (pax_name) |pn| if (!isSafeEntryPath(pn)) return error.ExtractionFailed;
        const name = pax_name orelse ustar_name;

        const ustar_link = nullSlice(header[157..257]);
        const link_name = pax_link orelse ustar_link;
        switch (kind_byte) {
            // Symbolic link: link target is interpreted relative to the
            // entry's parent directory (POSIX). Reuse the existing
            // bottle-aware target check against the effective target.
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
        // Pending overrides are consumed by this entry whatever its kind;
        // reset so they can never leak forward to an unrelated entry.
        pax_name = null;
        pax_link = null;

        // Advance past the data payload (rounded up to the next 512-byte
        // boundary). Symlinks/hardlinks/dirs report size 0 so this is a
        // no-op for them, but regular-file blocks DO carry data.
        const skip_bytes: u64 = (size + 511) / 512 * 512;
        if (skip_bytes > 0) {
            r.discardAll64(skip_bytes) catch return error.ExtractionFailed;
        }
    }

    return hardlinks.toOwnedSlice(arena);
}

/// Parse a pax extended-header payload (`size` bytes from the current block)
/// for `path=`/`linkpath=`, returning the last value seen for each — std.tar
/// applies these over the ustar fields of the following entry. The returned
/// slices are arena-owned and outlive the scan. Reads exactly `size` bytes.
fn parsePaxOverrides(
    r: *std.Io.Reader,
    arena: std.mem.Allocator,
    size: u64,
    out_name: *?[]const u8,
    out_link: *?[]const u8,
) !void {
    // Real pax headers are tens of bytes; bound the buffer against a hostile
    // size before allocating or reading.
    if (size > 64 * 1024) return error.ExtractionFailed;
    const payload = arena.alloc(u8, @intCast(size)) catch return error.ExtractionFailed;
    r.readSliceAll(payload) catch return error.ExtractionFailed;

    // Each record is `"<len> KEY=VALUE\n"`; <len> counts the whole record.
    var rest: []const u8 = payload;
    while (rest.len > 0) {
        const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.ExtractionFailed;
        const rec_len = std.fmt.parseInt(usize, rest[0..sp], 10) catch return error.ExtractionFailed;
        if (rec_len < sp + 2 or rec_len > rest.len or rest[rec_len - 1] != '\n') return error.ExtractionFailed;
        const kv = rest[sp + 1 .. rec_len - 1];
        if (std.mem.indexOfScalar(u8, kv, '=')) |eq| {
            const key = kv[0..eq];
            const value = kv[eq + 1 ..];
            if (std.mem.eql(u8, key, "linkpath")) {
                out_link.* = value;
            } else if (std.mem.eql(u8, key, "path")) {
                out_name.* = value;
            }
        }
        rest = rest[rec_len..];
    }
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

    // The `-Z1` listing only surfaces entry names; symlink targets are not
    // checked until the tree exists on disk.
    try rejectEscapingSymlinks(io, dest_dir);
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

    // `tar tf` validated entry names, not symlink targets; check those on
    // the materialised tree.
    try rejectEscapingSymlinks(io, dest_dir);
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

/// Walk a freshly-extracted tree and reject any symlink whose target escapes
/// `dest_dir`. The `tar tf`/`unzip -Z1` pre-scan validates entry names but
/// not symlink *targets*; macOS `tar`/`unzip` refuse to write *through* a
/// symlink, so a dangling escaping link is the only residue — this catches it.
/// The whole tree is wiped on rejection so a failed extract leaves nothing
/// behind, matching the in-process tar.gz contract. The walker descends real
/// directories only (symlink entries are never followed), so it cannot loop.
fn rejectEscapingSymlinks(io: std.Io, dest_dir: []const u8) !void {
    var escaped = false;
    {
        var dir = std.Io.Dir.openDirAbsolute(io, dest_dir, .{ .iterate = true }) catch
            return error.ExtractionFailed;
        defer dir.close(io);
        var walker = dir.walk(child_allocator) catch return error.ExtractionFailed;
        defer walker.deinit();
        while (walker.next(io) catch return error.ExtractionFailed) |entry| {
            if (entry.kind != .sym_link) continue;
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const len = entry.dir.readLink(io, entry.basename, &buf) catch return error.ExtractionFailed;
            // `entry.path` is relative to dest_dir — the same shape the tar.gz
            // pre-scan feeds `isSafeSymlinkTarget`, so the policy stays uniform.
            if (!isSafeSymlinkTarget(entry.path, buf[0..len])) {
                escaped = true;
                break;
            }
        }
    }
    if (escaped) {
        std.Io.Dir.cwd().deleteTree(io, dest_dir) catch {};
        return error.ExtractionFailed;
    }
}

// --- pax symlink-target test helpers --------------------------------------

/// Build a minimal 512-byte ustar header with a valid checksum. Only the
/// fields the pre-scan reads (name, size, typeflag, linkname, magic) are
/// populated; everything else stays zero.
fn testTarHeader(name: []const u8, typeflag: u8, link: []const u8, size: u64) [512]u8 {
    var h: [512]u8 = @splat(0);
    @memcpy(h[0..name.len], name);
    _ = std.fmt.bufPrint(h[124..135], "{o:0>11}", .{size}) catch unreachable;
    h[156] = typeflag;
    @memcpy(h[157..][0..link.len], link);
    @memcpy(h[257..262], "ustar");
    h[263] = '0';
    h[264] = '0';
    // Checksum: sum the whole header with the chksum field read as spaces.
    @memset(h[148..156], ' ');
    var sum: u64 = 0;
    for (h) |b| sum += b;
    _ = std.fmt.bufPrint(h[148..154], "{o:0>6}", .{sum}) catch unreachable;
    h[154] = 0;
    h[155] = ' ';
    return h;
}

/// Format a pax record `"<len> KEY=VALUE\n"` where `<len>` counts the whole
/// record including its own digits.
fn testPaxRecord(out: []u8, key: []const u8, value: []const u8) []const u8 {
    const fixed = 1 + key.len + 1 + value.len + 1; // space, '=', '\n'
    var digits: usize = 1;
    var total = fixed + digits;
    while (std.fmt.count("{d}", .{total}) != digits) {
        digits = std.fmt.count("{d}", .{total});
        total = fixed + digits;
    }
    return std.fmt.bufPrint(out, "{d} {s}={s}\n", .{ total, key, value }) catch unreachable;
}

/// gzip-compress `raw` into `out`, returning the written gzip stream.
fn testGzip(out: []u8, raw: []const u8) []const u8 {
    var out_w = std.Io.Writer.fixed(out);
    var win: [std.compress.flate.max_window_len]u8 = undefined;
    var comp = std.compress.flate.Compress.init(&out_w, &win, .gzip, std.compress.flate.Compress.Options.level_4) catch unreachable;
    comp.writer.writeAll(raw) catch unreachable;
    comp.finish() catch unreachable;
    return out_w.buffered();
}

/// Assembles raw tar blocks into a caller-owned buffer. Trailing zero blocks
/// (the buffer is zeroed up front) terminate the archive after `len`.
const TestTar = struct {
    buf: []u8,
    len: usize = 0,

    fn init(buf: []u8) TestTar {
        @memset(buf, 0);
        return .{ .buf = buf };
    }

    /// Append a single 512-byte entry header (size 0 — links/dirs only).
    fn entry(self: *TestTar, name: []const u8, typeflag: u8, link: []const u8) void {
        const h = testTarHeader(name, typeflag, link, 0);
        @memcpy(self.buf[self.len..][0..512], h[0..]);
        self.len += 512;
    }

    /// Append a pax header ('x' extended or 'g' global) with one record.
    fn pax(self: *TestTar, typeflag: u8, key: []const u8, value: []const u8) void {
        var rec_buf: [512]u8 = undefined;
        const rec = testPaxRecord(&rec_buf, key, value);
        const h = testTarHeader("PaxHeaders/0", typeflag, "", rec.len);
        @memcpy(self.buf[self.len..][0..512], h[0..]);
        self.len += 512;
        @memcpy(self.buf[self.len..][0..rec.len], rec);
        self.len += 512; // record fits one padded block
    }

    fn bytes(self: *const TestTar) []const u8 {
        return self.buf[0 .. self.len + 1024]; // + EOF marker blocks
    }
};

/// gzip `raw`, write it under `tmp`, and run `extractTarGz` into `tmp/dest`,
/// returning whatever the extract returns. `tmp/dest` must already exist.
fn testExtract(io: std.Io, tmp: *std.testing.TmpDir, raw: []const u8) !void {
    var gz_buf: [8192]u8 = undefined;
    const gz = testGzip(&gz_buf, raw);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.tar.gz", .data = gz });

    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try std.Io.Dir.realPath(tmp.dir, io, &base_buf)];
    var arc_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const arc = try std.fmt.bufPrint(&arc_buf, "{s}/a.tar.gz", .{base});
    var dst_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dst = try std.fmt.bufPrint(&dst_buf, "{s}/dest", .{base});
    return extractTarGz(io, arc, dst);
}

test "extractTarGz rejects a pax linkpath that escapes the destination" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "dest");

    // Benign ustar linkname passes the pre-scan, but the pax override climbs
    // out of dest — the extract must refuse it, not materialise it.
    var raw: [4096]u8 = undefined;
    var t = TestTar.init(&raw);
    t.pax('x', "linkpath", "../../../../../../tmp/evil");
    t.entry("placeholder", '2', "benign");
    try std.testing.expectError(error.ExtractionFailed, testExtract(io, &tmp, t.bytes()));
}

test "extractTarGz accepts a pax linkpath within the destination" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "dest");

    var raw: [4096]u8 = undefined;
    var t = TestTar.init(&raw);
    t.pax('x', "linkpath", "legit-target");
    t.entry("link", '2', "benign");
    try testExtract(io, &tmp, t.bytes());

    // The pax linkpath, not the ustar linkname, must be what landed on disk —
    // proving the pre-scan validated (and the extractor used) the same bytes.
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try std.Io.Dir.realPath(tmp.dir, io, &base_buf)];
    var dst_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dst = try std.fmt.bufPrint(&dst_buf, "{s}/dest", .{base});
    var dest_dir = try std.Io.Dir.openDirAbsolute(io, dst, .{});
    defer dest_dir.close(io);
    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const target = link_buf[0..try dest_dir.readLink(io, "link", &link_buf)];
    try std.testing.expectEqualStrings("legit-target", target);
}

test "extractTarGz ignores a global pax linkpath (no leak to the next entry)" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "dest");

    // A 'g' global header must not be applied to following entries; the
    // benign ustar target stands, so this extracts cleanly.
    var raw: [4096]u8 = undefined;
    var t = TestTar.init(&raw);
    t.pax('g', "linkpath", "../../../../../../tmp/evil");
    t.entry("link", '2', "benign");
    try testExtract(io, &tmp, t.bytes());
}

test "extractTarGz applies only the last pax header before an entry" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "dest");

    // The first 'x' escapes, but a second 'x' supersedes it with a safe
    // target — matching std.tar's reset. Over-carrying the first would
    // wrongly reject this archive.
    var raw: [4096]u8 = undefined;
    var t = TestTar.init(&raw);
    t.pax('x', "linkpath", "../../../../../../tmp/evil");
    t.pax('x', "linkpath", "safe-target");
    t.entry("link", '2', "benign");
    try testExtract(io, &tmp, t.bytes());
}

test "extractTarGz rejects a pax path override that escapes by name" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "dest");

    // A pax `path=` override re-runs the entry-name guard; a climbing name
    // is rejected even though the ustar name is benign.
    var raw: [4096]u8 = undefined;
    var t = TestTar.init(&raw);
    t.pax('x', "path", "../escape-name");
    t.entry("placeholder", '2', "benign");
    try std.testing.expectError(error.ExtractionFailed, testExtract(io, &tmp, t.bytes()));
}

test "extractTarGz rejects a pax linkpath that escapes via a hard link" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "dest");

    // std.tar applies pax `linkpath` to hard-link targets too; the pre-scan
    // recovers hard links itself, so the effective target must clear the
    // same entry-path guard rather than the stale ustar field.
    var raw: [4096]u8 = undefined;
    var t = TestTar.init(&raw);
    t.pax('x', "linkpath", "../escape");
    t.entry("placeholder", '1', "benign");
    try std.testing.expectError(error.ExtractionFailed, testExtract(io, &tmp, t.bytes()));
}

test "extractTarGz does not leak a pax override to a later entry" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "dest");

    // The 'x' override applies to entry "a" only; "b" must fall back to its
    // own ustar target, never inherit "a"'s pax linkpath.
    var raw: [4096]u8 = undefined;
    var t = TestTar.init(&raw);
    t.pax('x', "linkpath", "target-a");
    t.entry("a", '2', "ustar-a");
    t.entry("b", '2', "target-b");
    try testExtract(io, &tmp, t.bytes());

    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try std.Io.Dir.realPath(tmp.dir, io, &base_buf)];
    var dst_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dst = try std.fmt.bufPrint(&dst_buf, "{s}/dest", .{base});
    var dest_dir = try std.Io.Dir.openDirAbsolute(io, dst, .{});
    defer dest_dir.close(io);
    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const a = link_buf[0..try dest_dir.readLink(io, "a", &link_buf)];
    try std.testing.expectEqualStrings("target-a", a);
    var link_buf2: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const b = link_buf2[0..try dest_dir.readLink(io, "b", &link_buf2)];
    try std.testing.expectEqualStrings("target-b", b);
}

// --- subprocess-extractor symlink-target guard (xz/zip) -------------------

fn testDestAbs(tmp: *std.testing.TmpDir, io: std.Io, buf: []u8) ![]const u8 {
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try std.Io.Dir.realPath(tmp.dir, io, &base_buf)];
    return std.fmt.bufPrint(buf, "{s}/dest", .{base});
}

test "rejectEscapingSymlinks rejects a climbing target and wipes the tree" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "dest");
    // A symlink at the root climbing several levels escapes dest.
    try tmp.dir.symLink(io, "../../../../etc/evil", "dest/escape", .{});

    var dst_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dst = try testDestAbs(&tmp, io, &dst_buf);
    try std.testing.expectError(error.ExtractionFailed, rejectEscapingSymlinks(io, dst));
    // Rejection wipes the tree so nothing dangerous is left behind.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, dst, .{}));
}

test "rejectEscapingSymlinks rejects an absolute target" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "dest");
    try tmp.dir.symLink(io, "/etc/passwd", "dest/abs", .{});

    var dst_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dst = try testDestAbs(&tmp, io, &dst_buf);
    try std.testing.expectError(error.ExtractionFailed, rejectEscapingSymlinks(io, dst));
}

test "rejectEscapingSymlinks rejects a nested climbing target" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "dest/sub");
    // From dest/sub, three climbs reach above dest.
    try tmp.dir.symLink(io, "../../../etc/evil", "dest/sub/escape", .{});

    var dst_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dst = try testDestAbs(&tmp, io, &dst_buf);
    try std.testing.expectError(error.ExtractionFailed, rejectEscapingSymlinks(io, dst));
}

test "rejectEscapingSymlinks accepts in-tree symlinks" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "dest/bin");
    // A sibling-relative link and a one-level climb that stays in-tree.
    try tmp.dir.symLink(io, "sibling", "dest/ok", .{});
    try tmp.dir.symLink(io, "../lib/real", "dest/bin/link", .{});

    var dst_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dst = try testDestAbs(&tmp, io, &dst_buf);
    try rejectEscapingSymlinks(io, dst);
    // The tree is left intact when nothing escapes.
    try std.Io.Dir.accessAbsolute(io, dst, .{});
}
