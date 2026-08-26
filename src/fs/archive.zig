const std = @import("std");
const builtin = @import("builtin");
const system_tools = @import("../system_tools.zig");

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
/// `std.Io.Dir.hardLink` after `pipeToFileSystem` returns.
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
        try applyHardLinks(io, dir, hardlinks);
    }
}

const HardLink = struct {
    name: []const u8,
    target: []const u8,
};

/// Canonical form of a tar entry name: `.` and empty components dropped,
/// single `/` separators. Tar routinely emits `./name` for the same path that
/// a later entry spells `name`, so the symlink bookkeeping below has to
/// compare canonical forms or the two spellings look like different files.
/// The returned slice lives in `arena`.
fn canonicalEntryName(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |comp| {
        if (comp.len == 0 or std.mem.eql(u8, comp, ".")) continue;
        if (out.items.len > 0) try out.append(arena, '/');
        try out.appendSlice(arena, comp);
    }
    return out.toOwnedSlice(arena);
}

/// True when any proper directory prefix of `canon` names a symlink the same
/// archive declared earlier.
fn traversesSymlink(set: *const std.StringHashMapUnmanaged(void), canon: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, canon, i, '/')) |slash| {
        if (set.contains(canon[0..slash])) return true;
        i = slash + 1;
    }
    return false;
}

/// Recreate each `target -> name` hard link inside `dir`. `follow_symlinks`
/// stays false (the default): macOS `link(2)` follows, which would let an
/// archive craft a hardlink that escapes via a symlink hop. Paths stay relative
/// to the open handle so no absolute path is rebuilt from an entry name.
fn applyHardLinks(io: std.Io, dir: std.Io.Dir, links: []const HardLink) !void {
    for (links) |hl| {
        std.Io.Dir.hardLink(dir, hl.target, dir, hl.name, io, .{}) catch
            return error.ExtractionFailed;
    }
}

/// Walk the tar archive at raw 512-byte blocks to enforce path safety
/// AND recover hard-link pairs the std iterator silently drops.
/// Pax extended headers ('x') and GNU long-name/long-link records ('L'/'K')
/// are interpreted so the pre-scan validates the *effective* name and symlink
/// target the extractor will use, not stale placeholder fields.
///
/// This is the only defence, not a fast-fail: `pipeToFileSystem` writes the
/// whole archive before its diagnostics are inspected, so anything this scan
/// lets through is already on disk by the time extraction reports failure.
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

    // Every symlink this archive declares, in canonical form. An entry may
    // legitimately *be* a symlink that points out of the tree — a bottle links
    // to a sibling formula via `../../../../opt/<name>`, which only resolves
    // once the keg reaches its install location — but nothing may be written
    // *through* one. `isSafeSymlinkTarget`'s depth arithmetic treats every
    // component of an entry name as a real directory, so once `a` exists as a
    // symlink the budget no longer describes the filesystem and repeated
    // "one level up" hops compose into an unbounded escape.
    var symlink_names: std.StringHashMapUnmanaged(void) = .empty;

    // Metadata overrides apply to the next real entry. A pax header replaces
    // the whole pending record, while GNU L/K records replace one field. This
    // mirrors std.tar.Iterator's File accumulator exactly.
    var override_name: ?[]const u8 = null;
    var override_link: ?[]const u8 = null;

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
            override_name = null;
            override_link = null;
            try parsePaxOverrides(r, arena, size, &override_name, &override_link);
            // The parse consumed exactly `size` bytes; skip only the block pad.
            const pad: u64 = (512 - (size % 512)) % 512;
            if (pad > 0) r.discardAll64(pad) catch return error.ExtractionFailed;
            continue;
        }
        // GNU metadata stores the next entry's effective name or link target
        // as a NUL-terminated payload. std.tar applies these records before it
        // validates or extracts the following entry, so the security scan must
        // consume the same bytes.
        if (kind_byte == 'L' or kind_byte == 'K') {
            const value = try parseGnuOverride(r, arena, size);
            if (kind_byte == 'L') override_name = value else override_link = value;
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
        if (override_name) |pn| if (!isSafeEntryPath(pn)) return error.ExtractionFailed;
        const name = override_name orelse ustar_name;

        const ustar_link = nullSlice(header[157..257]);
        const link_name = override_link orelse ustar_link;

        // No entry may be reached through a symlink this archive created —
        // that is the step that turns a bounded, dangling link into a write
        // outside the extraction root.
        const canon = try canonicalEntryName(arena, name);
        if (traversesSymlink(&symlink_names, canon)) return error.ExtractionFailed;

        switch (kind_byte) {
            // Symbolic link: link target is interpreted relative to the
            // entry's parent directory (POSIX). Reuse the existing
            // bottle-aware target check against the effective target.
            '2' => {
                if (!isSafeSymlinkTarget(name, link_name)) return error.ExtractionFailed;
                if (canon.len > 0) try symlink_names.put(arena, canon, {});
            },
            // Hard link: target is a tar-relative path identical in
            // shape to a regular entry name. `hardLink`'s follow_symlinks=false
            // only protects the final component — the kernel still resolves
            // every directory on the way there — so the target gets the same
            // traversal check as an entry name.
            '1' => {
                if (!isSafeEntryPath(link_name)) return error.ExtractionFailed;
                const canon_target = try canonicalEntryName(arena, link_name);
                if (traversesSymlink(&symlink_names, canon_target)) return error.ExtractionFailed;
                try hardlinks.append(arena, .{
                    .name = try arena.dupe(u8, name),
                    .target = try arena.dupe(u8, link_name),
                });
            },
            else => {},
        }
        // Only the kinds std.tar returns upstream consume a pending record.
        // Clearing it for any other header would bind it to a different entry
        // than extraction does.
        switch (kind_byte) {
            0, '0', '2', '5' => {
                override_name = null;
                override_link = null;
            },
            else => {},
        }

        // Advance past the data payload (rounded up to the next 512-byte
        // boundary). Symlinks/hardlinks/dirs report size 0 so this is a
        // no-op for them, but regular-file blocks DO carry data.
        const skip_bytes: u64 = (size + 511) / 512 * 512;
        if (skip_bytes > 0) {
            r.discardAll64(skip_bytes) catch return error.ExtractionFailed;
        }
    }

    // Hard links are recreated only after the extractor has processed the
    // entire archive. Recheck them against the complete symlink set so a link
    // declared later cannot change how either deferred path resolves.
    for (hardlinks.items) |hl| {
        const canon_name = try canonicalEntryName(arena, hl.name);
        if (traversesSymlink(&symlink_names, canon_name)) return error.ExtractionFailed;
        const canon_target = try canonicalEntryName(arena, hl.target);
        if (traversesSymlink(&symlink_names, canon_target)) return error.ExtractionFailed;
    }

    return hardlinks.toOwnedSlice(arena);
}

/// Read one GNU `L`/`K` payload and its block padding. Zig's iterator buffers
/// at most `max_path_bytes` and uses the bytes before the first NUL.
fn parseGnuOverride(r: *std.Io.Reader, arena: std.mem.Allocator, size: u64) ![]const u8 {
    const len = std.math.cast(usize, size) orelse return error.ExtractionFailed;
    if (len > std.Io.Dir.max_path_bytes) return error.ExtractionFailed;
    const payload = arena.alloc(u8, len) catch return error.ExtractionFailed;
    r.readSliceAll(payload) catch return error.ExtractionFailed;
    const pad: u64 = (512 - (size % 512)) % 512;
    if (pad > 0) r.discardAll64(pad) catch return error.ExtractionFailed;
    return nullSlice(payload);
}

/// Parse a pax extended-header payload (`size` bytes from the current block)
/// for `path=`/`linkpath=`, returning the last value seen for each — std.tar
/// applies these over the ustar fields of the following entry. The returned
/// slices are arena-owned and outlive the scan. Reads exactly `size` bytes.
///
/// Streams record-by-record, mirroring `std.tar.PaxIterator`: only the bounded
/// `path`/`linkpath` values are buffered; every other record (macOS bsdtar
/// packs a file's extended attributes here, routinely hundreds of KiB) is
/// discarded as it streams. Buffering the whole payload would either reject
/// those legitimate archives or hold an attacker-sized allocation.
fn parsePaxOverrides(
    r: *std.Io.Reader,
    arena: std.mem.Allocator,
    size: u64,
    out_name: *?[]const u8,
    out_link: *?[]const u8,
) !void {
    // Each record is `"<len> KEY=VALUE\n"`; <len> counts the whole record.
    var remaining: usize = std.math.cast(usize, size) orelse return error.ExtractionFailed;
    while (remaining > 0) {
        const len_buf = r.takeSentinel(' ') catch return error.ExtractionFailed;
        const rec_len = std.fmt.parseInt(usize, len_buf, 10) catch return error.ExtractionFailed;
        const key = r.takeSentinel('=') catch return error.ExtractionFailed;
        // Bytes consumed for framing: len digits, the space, the key, the '='.
        const framed = len_buf.len + 1 + key.len + 1;
        if (rec_len < framed + 1 or rec_len > remaining) return error.ExtractionFailed;
        const value_len = rec_len - framed - 1; // trailing '\n'
        remaining -= rec_len;

        const slot: ?*?[]const u8 = if (std.mem.eql(u8, key, "linkpath"))
            out_link
        else if (std.mem.eql(u8, key, "path"))
            out_name
        else
            null;
        // A path/linkpath longer than the filesystem allows is not the value
        // the extractor will use — std.tar caps both at max_path_bytes and
        // errors past it — so treat an over-long one as a non-path record and
        // discard it rather than buffering an attacker-sized blob.
        if (slot != null and value_len <= std.Io.Dir.max_path_bytes) {
            const value = arena.alloc(u8, value_len) catch return error.ExtractionFailed;
            r.readSliceAll(value) catch return error.ExtractionFailed;
            if (std.mem.indexOfScalar(u8, value, 0) != null) return error.ExtractionFailed;
            slot.?.* = value;
        } else {
            r.discardAll(value_len) catch return error.ExtractionFailed;
        }
        const nl = r.takeByte() catch return error.ExtractionFailed;
        if (nl != '\n') return error.ExtractionFailed;
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
    const argv = [_][]const u8{ system_tools.unzip, "-q", "-o", archive_path, "-d", dest_dir };
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
    const argv = [_][]const u8{ system_tools.unzip, "-Z1", archive_path };
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

    const argv = [_][]const u8{ system_tools.tar, "xf", archive_path, "-C", dest_dir, "--no-same-permissions", "--no-same-owner" };
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
    const argv = [_][]const u8{ system_tools.tar, "tf", archive_path };
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

const test_io = std.Options.debug_io;

var scratch_seq: std.atomic.Value(u32) = .init(0);

/// Stands in for std.testing.tmpDir, which builds under .zig-cache — a tree the
/// build system owns and rewrites underneath concurrent test runs. The pid and
/// sequence keep overlapping runs from deleting each other's fixtures.
const Scratch = struct {
    arena: std.heap.ArenaAllocator,
    base: [:0]const u8,
    dir: std.Io.Dir,

    fn init(comptime tag: []const u8) !Scratch {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const raw = try std.fmt.allocPrintSentinel(
            arena.allocator(),
            "/tmp/malt_archive_" ++ tag ++ "_{d}_{d}",
            .{ std.c.getpid(), scratch_seq.fetchAdd(1, .monotonic) },
            0,
        );
        std.Io.Dir.cwd().deleteTree(test_io, raw) catch {};
        try std.Io.Dir.cwd().createDirPath(test_io, raw);
        var dir = try std.Io.Dir.openDirAbsolute(test_io, raw, .{});
        errdefer dir.close(test_io);
        // /tmp is a symlink to /private/tmp on macOS; resolve once so paths the
        // code under test returns compare equal to `base`.
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try std.Io.Dir.realPath(dir, test_io, &buf);
        const base = try arena.allocator().dupeZ(u8, buf[0..n]);
        return .{ .arena = arena, .base = base, .dir = dir };
    }

    /// Absolute path to `sub` (leading slash included); valid until deinit.
    fn p(self: *Scratch, sub: []const u8) [:0]const u8 {
        return std.fmt.allocPrintSentinel(
            self.arena.allocator(),
            "{s}{s}",
            .{ self.base, sub },
            0,
        ) catch @panic("OOM");
    }

    fn deinit(self: *Scratch) void {
        self.dir.close(test_io);
        std.Io.Dir.cwd().deleteTree(test_io, self.base) catch {};
        self.arena.deinit();
    }
};

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
        self.paxRecord(typeflag, rec);
    }

    /// Append a pax header carrying a pre-formatted record, spanning as many
    /// padded 512-byte blocks as the record needs (macOS xattr records are
    /// routinely larger than one block).
    fn paxRecord(self: *TestTar, typeflag: u8, rec: []const u8) void {
        const h = testTarHeader("PaxHeaders/0", typeflag, "", rec.len);
        @memcpy(self.buf[self.len..][0..512], h[0..]);
        self.len += 512;
        @memcpy(self.buf[self.len..][0..rec.len], rec);
        self.len += (rec.len + 511) / 512 * 512;
    }

    /// Append a GNU long-name/long-link metadata record. Zig's tar iterator
    /// applies this value to the next entry, so the security pre-scan must
    /// validate the same effective bytes rather than the following ustar
    /// header's placeholder field.
    fn gnuString(self: *TestTar, typeflag: u8, value: []const u8) void {
        const payload_len = value.len + 1; // GNU payload is NUL-terminated.
        const h = testTarHeader("././@LongLink", typeflag, "", payload_len);
        @memcpy(self.buf[self.len..][0..512], h[0..]);
        self.len += 512;
        @memcpy(self.buf[self.len..][0..value.len], value);
        self.buf[self.len + value.len] = 0;
        self.len += (payload_len + 511) / 512 * 512;
    }

    /// Append a regular-file entry with `data` as its payload.
    fn file(self: *TestTar, name: []const u8, data: []const u8) void {
        const h = testTarHeader(name, '0', "", data.len);
        @memcpy(self.buf[self.len..][0..512], h[0..]);
        self.len += 512;
        @memcpy(self.buf[self.len..][0..data.len], data);
        self.len += (data.len + 511) / 512 * 512;
    }

    fn bytes(self: *const TestTar) []const u8 {
        return self.buf[0 .. self.len + 1024]; // + EOF marker blocks
    }
};

/// gzip `raw`, write it under `s`, and run `extractTarGz` into `<s>/dest`,
/// returning whatever the extract returns. `<s>/dest` must already exist.
fn testExtract(io: std.Io, s: *Scratch, raw: []const u8) !void {
    var gz_buf: [8192]u8 = undefined;
    const gz = testGzip(&gz_buf, raw);
    try s.dir.writeFile(io, .{ .sub_path = "a.tar.gz", .data = gz });
    return extractTarGz(io, s.p("/a.tar.gz"), s.p("/dest"));
}

test "extractZip ignores a PATH-resident unzip shim" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var s = try Scratch.init("zip_path_shim");
    defer s.deinit();
    const source = s.p("/payload");
    const archive_path = s.p("/payload.zip");
    const dest = s.p("/dest");
    const shim_dir = s.p("/shim");
    const shim = s.p("/shim/unzip");
    try s.dir.createDirPath(test_io, "dest");
    try s.dir.createDirPath(test_io, "shim");
    {
        const f = try std.Io.Dir.createFileAbsolute(test_io, source, .{});
        defer f.close(test_io);
        try f.writeStreamingAll(test_io, "payload");
    }

    var host_io: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer host_io.deinit();
    var zip = try std.process.spawn(host_io.io(), .{
        .argv = &.{ "/usr/bin/zip", "-j", "-q", archive_path, source },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const zip_term = try zip.wait(host_io.io());
    try std.testing.expect(zip_term == .exited and zip_term.exited == 0);
    try std.Io.Dir.symLinkAbsolute(test_io, "/usr/bin/false", shim, .{});

    const path_entry = try std.fmt.allocPrintSentinel(s.arena.allocator(), "PATH={s}", .{shim_dir}, 0);
    const entries = [_:null]?[*:0]const u8{path_entry.ptr};
    const environ: std.process.Environ = .{ .block = .{ .slice = &entries } };
    var shim_io: std.Io.Threaded = .init(std.testing.allocator, .{ .environ = environ });
    defer shim_io.deinit();

    try extractZip(shim_io.io(), archive_path, dest);
    try std.Io.Dir.accessAbsolute(test_io, s.p("/dest/payload"), .{});
}

test "extractTarGz rejects a pax linkpath that escapes the destination" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("pax_escape");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest");

    // Benign ustar linkname passes the pre-scan, but the pax override climbs
    // out of dest — the extract must refuse it, not materialise it.
    var raw: [4096]u8 = undefined;
    var t = TestTar.init(&raw);
    t.pax('x', "linkpath", "../../../../../../tmp/evil");
    t.entry("placeholder", '2', "benign");
    try std.testing.expectError(error.ExtractionFailed, testExtract(io, &s, t.bytes()));
}

test "extractTarGz rejects a deferred hardlink through a later symlink" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("hardlink_later_symlink");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest");
    try s.dir.createDirPath(io, "outside");

    var raw: [8192]u8 = undefined;
    var t = TestTar.init(&raw);
    t.file("victim", "payload");
    // Hardlinks are re-applied only after extraction. A symlink declared
    // later therefore exists by the time this destination is resolved.
    t.entry("door/escaped", '1', "victim");
    t.entry("door", '2', "../outside");

    const result = testExtract(io, &s, t.bytes());
    if (std.Io.Dir.accessAbsolute(io, s.p("/outside/escaped"), .{})) {
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(error.FileNotFound, err);
    try std.testing.expectError(error.ExtractionFailed, result);
}

test "extractTarGz rejects an escaping GNU long-link target" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("gnu_long_link_escape");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest");

    var raw: [4096]u8 = undefined;
    var t = TestTar.init(&raw);
    t.gnuString('K', "../../../../../../tmp/malt-gnu-link-escape");
    t.entry("alias", '2', "benign");

    const result = testExtract(io, &s, t.bytes());
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.Io.Dir.readLinkAbsolute(io, s.p("/dest/alias"), &link_buf)) |_| {
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(error.FileNotFound, err);
    try std.testing.expectError(error.ExtractionFailed, result);
}

test "extractTarGz rejects a write through a GNU long-named symlink" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("gnu_long_name_symlink");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest");
    try s.dir.createDirPath(io, "outside");

    var raw: [8192]u8 = undefined;
    var t = TestTar.init(&raw);
    t.gnuString('L', "door");
    t.entry("placeholder", '2', "../outside");
    t.file("door/escaped", "owned");

    const result = testExtract(io, &s, t.bytes());
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(io, s.p("/outside/escaped"), .{}),
    );
    try std.testing.expectError(error.ExtractionFailed, result);
}

test "extractTarGz keeps a GNU long name pending across an unsupported entry" {
    // An unsupported kind between the record and the real entry leaves the
    // extractor naming the symlink "door" while a scan that dropped the record
    // sees "placeholder", and then allows a write through it.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("gnu_carry_unsupported");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest");
    try s.dir.createDirPath(io, "outside");

    var raw: [8192]u8 = undefined;
    var t = TestTar.init(&raw);
    t.gnuString('L', "door");
    t.entry("decoy", '3', "");
    t.entry("placeholder", '2', "../outside");
    t.file("door/escaped", "owned");

    const result = testExtract(io, &s, t.bytes());
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(io, s.p("/outside/escaped"), .{}),
    );
    try std.testing.expectError(error.ExtractionFailed, result);
}

test "extractTarGz keeps a GNU long name pending across a hard link entry" {
    // The practical form of the same gap: extraction tolerates hard links, so
    // only this scan can stop one.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("gnu_carry_hardlink");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest");
    try s.dir.createDirPath(io, "outside");

    var raw: [8192]u8 = undefined;
    var t = TestTar.init(&raw);
    t.file("victim", "payload");
    t.gnuString('L', "door");
    t.entry("decoy", '1', "victim");
    t.entry("placeholder", '2', "../outside");
    t.file("door/escaped", "owned");

    const result = testExtract(io, &s, t.bytes());
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(io, s.p("/outside/escaped"), .{}),
    );
    try std.testing.expectError(error.ExtractionFailed, result);
}

test "extractTarGz lets an old-style file entry consume a GNU long link" {
    // std.tar folds the legacy 0 type byte into a normal file, so it consumes
    // the record; carrying it forward would refuse a safe archive.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("gnu_alias_consumes");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest");

    var raw: [8192]u8 = undefined;
    var t = TestTar.init(&raw);
    t.file("benign", "payload");
    t.gnuString('K', "../../../../../../tmp/malt-gnu-alias-escape");
    t.entry("decoy", 0, "");
    t.entry("alias", '2', "benign");

    try testExtract(io, &s, t.bytes());
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.readLinkAbsolute(io, s.p("/dest/alias"), &link_buf);
    try std.testing.expectEqualStrings("benign", link_buf[0..n]);
}

test "extractTarGz lets a directory entry consume a GNU long name" {
    // The mirror of the carry-over cases: a returned kind must clear the
    // record, or the scan refuses a safe archive.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("gnu_dir_consumes");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest");

    var raw: [8192]u8 = undefined;
    var t = TestTar.init(&raw);
    t.file("target", "payload");
    t.gnuString('L', "safe");
    t.entry("placeholder", '5', "");
    t.entry("alias", '2', "target");
    t.file("safe/inside", "data");

    try testExtract(io, &s, t.bytes());
    try std.Io.Dir.accessAbsolute(io, s.p("/dest/safe/inside"), .{});
}

test "extractTarGz accepts safe GNU long-name and long-link metadata" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("gnu_long_safe");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest");

    var raw: [8192]u8 = undefined;
    var t = TestTar.init(&raw);
    t.file("target", "payload");
    t.gnuString('L', "nested/alias");
    t.gnuString('K', "../target");
    t.entry("placeholder", '2', "placeholder");

    try testExtract(io, &s, t.bytes());
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link_len = try std.Io.Dir.readLinkAbsolute(io, s.p("/dest/nested/alias"), &link_buf);
    try std.testing.expectEqualStrings("../target", link_buf[0..link_len]);
}

test "extractTarGz accepts a pax linkpath within the destination" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("pax_ok");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest");

    var raw: [4096]u8 = undefined;
    var t = TestTar.init(&raw);
    t.pax('x', "linkpath", "legit-target");
    t.entry("link", '2', "benign");
    try testExtract(io, &s, t.bytes());

    // The pax linkpath, not the ustar linkname, must be what landed on disk —
    // proving the pre-scan validated (and the extractor used) the same bytes.
    var dest_dir = try std.Io.Dir.openDirAbsolute(io, s.p("/dest"), .{});
    defer dest_dir.close(io);
    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const target = link_buf[0..try dest_dir.readLink(io, "link", &link_buf)];
    try std.testing.expectEqualStrings("legit-target", target);
}

test "extractTarGz tolerates an oversized pax header from a file's xattrs" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("pax_xattr");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest");

    // macOS bsdtar packs a signed binary's extended attributes into a pax 'x'
    // header far larger than any fixed payload buffer (yabai ships ~365 KiB).
    // The pre-scan must stream past the unknown record like std.tar does, not
    // reject the whole archive — the file that follows must still materialise.
    const a = std.testing.allocator;
    const tar = try a.alloc(u8, 256 * 1024);
    defer a.free(tar);
    const blob = try a.alloc(u8, 100 * 1024);
    defer a.free(blob);
    @memset(blob, 'x');
    const rec_buf = try a.alloc(u8, 110 * 1024);
    defer a.free(rec_buf);
    const rec = testPaxRecord(rec_buf, "SCHILY.xattr.user.test", blob);

    var t = TestTar.init(tar);
    t.paxRecord('x', rec);
    t.file("payload", "hello");
    try testExtract(io, &s, t.bytes());

    var dest_dir = try std.Io.Dir.openDirAbsolute(io, s.p("/dest"), .{});
    defer dest_dir.close(io);
    const st = try dest_dir.statFile(io, "payload", .{});
    try std.testing.expectEqual(@as(u64, "hello".len), st.size);
}

test "extractTarGz rejects a pax linkpath escape that trails a large xattr record" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("pax_escape_after_xattr");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest");

    // A malicious linkpath sitting *after* a discarded xattr blob in the same
    // pax header must still be caught — proving the streaming parser stays
    // byte-aligned across a discard and does not skip the record that follows.
    const a = std.testing.allocator;
    const tar = try a.alloc(u8, 256 * 1024);
    defer a.free(tar);
    const blob = try a.alloc(u8, 80 * 1024);
    defer a.free(blob);
    @memset(blob, 'x');
    const rec_buf = try a.alloc(u8, 100 * 1024);
    defer a.free(rec_buf);
    const r1 = testPaxRecord(rec_buf, "SCHILY.xattr.user.x", blob);
    const r2 = testPaxRecord(rec_buf[r1.len..], "linkpath", "../../../../../../tmp/evil");

    var t = TestTar.init(tar);
    t.paxRecord('x', rec_buf[0 .. r1.len + r2.len]);
    t.entry("placeholder", '2', "benign");
    try std.testing.expectError(error.ExtractionFailed, testExtract(io, &s, t.bytes()));
}

test "extractTarGz applies a pax linkpath that trails a large xattr record" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("pax_ok_after_xattr");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest");

    // The positive mirror: a legitimate linkpath following the discarded blob
    // must still be captured and applied to the entry.
    const a = std.testing.allocator;
    const tar = try a.alloc(u8, 256 * 1024);
    defer a.free(tar);
    const blob = try a.alloc(u8, 80 * 1024);
    defer a.free(blob);
    @memset(blob, 'x');
    const rec_buf = try a.alloc(u8, 100 * 1024);
    defer a.free(rec_buf);
    const r1 = testPaxRecord(rec_buf, "SCHILY.xattr.user.x", blob);
    const r2 = testPaxRecord(rec_buf[r1.len..], "linkpath", "legit-target");

    var t = TestTar.init(tar);
    t.paxRecord('x', rec_buf[0 .. r1.len + r2.len]);
    t.entry("link", '2', "benign");
    try testExtract(io, &s, t.bytes());

    var dest_dir = try std.Io.Dir.openDirAbsolute(io, s.p("/dest"), .{});
    defer dest_dir.close(io);
    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const target = link_buf[0..try dest_dir.readLink(io, "link", &link_buf)];
    try std.testing.expectEqualStrings("legit-target", target);
}

test "extractTarGz ignores a global pax linkpath (no leak to the next entry)" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("pax_global");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest");

    // A 'g' global header must not be applied to following entries; the
    // benign ustar target stands, so this extracts cleanly.
    var raw: [4096]u8 = undefined;
    var t = TestTar.init(&raw);
    t.pax('g', "linkpath", "../../../../../../tmp/evil");
    t.entry("link", '2', "benign");
    try testExtract(io, &s, t.bytes());
}

test "extractTarGz applies only the last pax header before an entry" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("pax_last_wins");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest");

    // The first 'x' escapes, but a second 'x' supersedes it with a safe
    // target — matching std.tar's reset. Over-carrying the first would
    // wrongly reject this archive.
    var raw: [4096]u8 = undefined;
    var t = TestTar.init(&raw);
    t.pax('x', "linkpath", "../../../../../../tmp/evil");
    t.pax('x', "linkpath", "safe-target");
    t.entry("link", '2', "benign");
    try testExtract(io, &s, t.bytes());
}

test "extractTarGz rejects a pax path override that escapes by name" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("pax_path_escape");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest");

    // A pax `path=` override re-runs the entry-name guard; a climbing name
    // is rejected even though the ustar name is benign.
    var raw: [4096]u8 = undefined;
    var t = TestTar.init(&raw);
    t.pax('x', "path", "../escape-name");
    t.entry("placeholder", '2', "benign");
    try std.testing.expectError(error.ExtractionFailed, testExtract(io, &s, t.bytes()));
}

test "extractTarGz rejects a pax linkpath that escapes via a hard link" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("pax_hardlink_escape");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest");

    // std.tar applies pax `linkpath` to hard-link targets too; the pre-scan
    // recovers hard links itself, so the effective target must clear the
    // same entry-path guard rather than the stale ustar field.
    var raw: [4096]u8 = undefined;
    var t = TestTar.init(&raw);
    t.pax('x', "linkpath", "../escape");
    t.entry("placeholder", '1', "benign");
    try std.testing.expectError(error.ExtractionFailed, testExtract(io, &s, t.bytes()));
}

test "extractTarGz does not leak a pax override to a later entry" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("pax_no_leak");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest");

    // The 'x' override applies to entry "a" only; "b" must fall back to its
    // own ustar target, never inherit "a"'s pax linkpath.
    var raw: [4096]u8 = undefined;
    var t = TestTar.init(&raw);
    t.pax('x', "linkpath", "target-a");
    t.entry("a", '2', "ustar-a");
    t.entry("b", '2', "target-b");
    try testExtract(io, &s, t.bytes());

    var dest_dir = try std.Io.Dir.openDirAbsolute(io, s.p("/dest"), .{});
    defer dest_dir.close(io);
    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const a = link_buf[0..try dest_dir.readLink(io, "a", &link_buf)];
    try std.testing.expectEqualStrings("target-a", a);
    var link_buf2: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const b = link_buf2[0..try dest_dir.readLink(io, "b", &link_buf2)];
    try std.testing.expectEqualStrings("target-b", b);
}

// --- writing through an archive-created symlink ---------------------------

test "extractTarGz rejects a file written through a symlink the archive created" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("sym_write_through");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest");

    // `up` is a legal symlink on its own (one level up is the allowed
    // prefix-parent shape). The escape is the *next* entry, whose name walks
    // through it — the depth arithmetic counts `up` as a directory, so
    // `up/ESCAPED` reads as depth 1 while it actually lands in dest's parent.
    var raw: [4096]u8 = undefined;
    var t = TestTar.init(&raw);
    t.entry("up", '2', "..");
    t.file("up/ESCAPED", "pwned\n");
    try std.testing.expectError(error.ExtractionFailed, testExtract(io, &s, t.bytes()));

    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(io, s.p("/ESCAPED"), .{}),
    );
}

test "extractTarGz rejects chained symlinks that walk arbitrarily far out" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("sym_chain");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest");
    try s.dir.createDirPath(io, "bin");

    // Each hop is individually within the one-level budget, but the budget was
    // never meant to compose: `a` is a symlink, so `a/b` is not at the depth
    // its name implies, and by the third entry the write lands in a sibling of
    // dest — `<prefix>/bin` in the real layout, which is on the user's PATH.
    var raw: [4096]u8 = undefined;
    var t = TestTar.init(&raw);
    t.entry("a", '2', "..");
    t.entry("a/b", '2', "..");
    t.file("a/b/bin/EVIL", "payload\n");
    try std.testing.expectError(error.ExtractionFailed, testExtract(io, &s, t.bytes()));

    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(io, s.p("/bin/EVIL"), .{}),
    );
}

test "extractTarGz rejects a hard link resolved through a symlink the archive created" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("hardlink_escape");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest");
    try s.dir.writeFile(io, .{ .sub_path = "secret.txt", .data = "TOP SECRET\n" });

    // `follow_symlinks = false` only governs the final component; the kernel
    // still resolves `up`. A hard link is a second name for the inode, so this
    // would import a file the archive never shipped into the keg — where the
    // linker can expose it and a later chmod can widen it.
    var raw: [4096]u8 = undefined;
    var t = TestTar.init(&raw);
    t.entry("up", '2', "..");
    t.entry("stolen", '1', "up/secret.txt");
    try std.testing.expectError(error.ExtractionFailed, testExtract(io, &s, t.bytes()));

    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(io, s.p("/dest/stolen"), .{}),
    );
}

test "extractTarGz sees through a ./-spelled symlink name" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("sym_dotslash");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest");

    // tar emits `./name` and `name` interchangeably; the guard compares
    // canonical forms so the two spellings cannot be used to smuggle a
    // traversal past it.
    var raw: [4096]u8 = undefined;
    var t = TestTar.init(&raw);
    t.entry("./up", '2', "..");
    t.file("up/ESCAPED", "pwned\n");
    try std.testing.expectError(error.ExtractionFailed, testExtract(io, &s, t.bytes()));
}

test "extractTarGz records a symlink under its pax-overridden name" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("sym_pax_name");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest");

    // The symlink bookkeeping has to key off the *effective* name, or a pax
    // `path=` override renames the link out from under the guard and the next
    // entry walks through it unnoticed.
    var raw: [4096]u8 = undefined;
    var t = TestTar.init(&raw);
    t.pax('x', "path", "up");
    t.entry("ustar-name-ignored", '2', "..");
    t.file("up/ESCAPED", "pwned\n");
    try std.testing.expectError(error.ExtractionFailed, testExtract(io, &s, t.bytes()));

    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(io, s.p("/ESCAPED"), .{}),
    );
}

test "extractTarGz still accepts the out-of-tree leaf symlinks real bottles ship" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("sym_bottle_ok");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest");

    // Compatibility guard. Bottles are built for their *installed* location,
    // so a formula that references a sibling reaches it by climbing out of the
    // tarball root — the rust bottle's `opt/llvm` link is the canonical case.
    // Those links dangle at extraction time and resolve once the keg is in
    // place; nothing is written through them, so they stay legal.
    var raw: [8192]u8 = undefined;
    var t = TestTar.init(&raw);
    t.file("rust/1.95.0/lib/rustlib/aarch64-apple-darwin/bin/real", "x\n");
    t.entry(
        "rust/1.95.0/lib/rustlib/aarch64-apple-darwin/bin/rust-objcopy",
        '2',
        "../../../../../../../opt/llvm/bin/llvm-objcopy",
    );
    t.entry("rust/1.95.0/bin/sibling", '2', "real");
    t.entry("rust/1.95.0/bin/up-and-over", '2', "../lib/rustlib");
    t.file("rust/1.95.0/bin/real", "y\n");
    try testExtract(io, &s, t.bytes());

    var dest_dir = try std.Io.Dir.openDirAbsolute(io, s.p("/dest"), .{});
    defer dest_dir.close(io);
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "../../../../../../../opt/llvm/bin/llvm-objcopy",
        buf[0..try dest_dir.readLink(io, "rust/1.95.0/lib/rustlib/aarch64-apple-darwin/bin/rust-objcopy", &buf)],
    );
}

test "extractTarGz still applies a hard link that does not cross a symlink" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("hardlink_ok");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest");

    var raw: [4096]u8 = undefined;
    var t = TestTar.init(&raw);
    t.file("pkg/bin/tool", "payload\n");
    t.entry("pkg/bin/tool-alias", '1', "pkg/bin/tool");
    t.entry("unrelated", '2', "missing-target");
    try testExtract(io, &s, t.bytes());

    var dest_dir = try std.Io.Dir.openDirAbsolute(io, s.p("/dest"), .{});
    defer dest_dir.close(io);
    const st = try dest_dir.statFile(io, "pkg/bin/tool-alias", .{});
    try std.testing.expectEqual(@as(u64, "payload\n".len), st.size);
}

// --- subprocess-extractor symlink-target guard (xz/zip) -------------------

test "rejectEscapingSymlinks rejects a climbing target and wipes the tree" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("sym_climb");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest");
    // A symlink at the root climbing several levels escapes dest.
    try s.dir.symLink(io, "../../../../etc/evil", "dest/escape", .{});

    const dst = s.p("/dest");
    try std.testing.expectError(error.ExtractionFailed, rejectEscapingSymlinks(io, dst));
    // Rejection wipes the tree so nothing dangerous is left behind.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, dst, .{}));
}

test "rejectEscapingSymlinks rejects an absolute target" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("sym_abs");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest");
    try s.dir.symLink(io, "/etc/passwd", "dest/abs", .{});

    const dst = s.p("/dest");
    try std.testing.expectError(error.ExtractionFailed, rejectEscapingSymlinks(io, dst));
}

test "rejectEscapingSymlinks rejects a nested climbing target" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("sym_nested_climb");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest/sub");
    // From dest/sub, three climbs reach above dest.
    try s.dir.symLink(io, "../../../etc/evil", "dest/sub/escape", .{});

    const dst = s.p("/dest");
    try std.testing.expectError(error.ExtractionFailed, rejectEscapingSymlinks(io, dst));
}

test "rejectEscapingSymlinks accepts in-tree symlinks" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("sym_in_tree");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest/bin");
    // A sibling-relative link and a one-level climb that stays in-tree.
    try s.dir.symLink(io, "sibling", "dest/ok", .{});
    try s.dir.symLink(io, "../lib/real", "dest/bin/link", .{});

    const dst = s.p("/dest");
    try rejectEscapingSymlinks(io, dst);
    // The tree is left intact when nothing escapes.
    try std.Io.Dir.accessAbsolute(io, dst, .{});
}

test "rejectEscapingSymlinks does not follow symlinks while walking" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("sym_no_follow");
    defer s.deinit();
    try s.dir.createDirPath(io, "dest/realdir");
    try s.dir.writeFile(io, .{ .sub_path = "dest/realdir/f", .data = "x" });
    // A symlink to an in-tree dir and a self-referential symlink: if the
    // walker followed either, this would recurse forever instead of
    // terminating. Both targets are in-tree, so the guard must accept them.
    try s.dir.symLink(io, "realdir", "dest/dirlink", .{});
    try s.dir.symLink(io, ".", "dest/self", .{});

    try rejectEscapingSymlinks(io, s.p("/dest"));
}
