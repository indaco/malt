const std = @import("std");
const fs_compat = @import("compat.zig");
const clonefile = @import("clonefile.zig");

/// 512 bytes: ~4× real Homebrew prefix length, still small enough that
/// anything past it is either a bug or overflow bait.
pub const MAX_PREFIX_LEN: usize = 512;

pub const PrefixError = error{
    Empty,
    NotAbsolute,
    DotDotComponent,
    EmbeddedNul,
    TooLong,
    EmptyComponent,
    DisallowedByte,
};

/// Single source of truth for the prefix charset. Matches
/// `validatePathForProfile` in `core/sandbox/macos.zig` so anything that
/// passes here is safe to interpolate into a Ruby single-quoted literal,
/// a sandbox-profile path string, or a shell argv.
pub fn isAllowedPrefixByte(b: u8) bool {
    return switch (b) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '+', '-', '/' => true,
        else => false,
    };
}

/// Charset for a formula `name` or `version`. Same alphabet as the prefix
/// minus `/` (a name with `/` would pierce a `{prefix}/Cellar/{name}/...`
/// path) plus `@` (versioned formulae like `llvm@21`, `python@3.12`).
pub fn isAllowedNameByte(b: u8) bool {
    return switch (b) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '+', '-', '@' => true,
        else => false,
    };
}

/// Validate a candidate install prefix. Called at the env boundary so
/// downstream code can assume absolute, NUL-free, traversal-free.
pub fn validatePrefix(prefix: []const u8) PrefixError!void {
    if (prefix.len == 0) return PrefixError.Empty;
    if (prefix.len > MAX_PREFIX_LEN) return PrefixError.TooLong;
    if (prefix[0] != '/') return PrefixError.NotAbsolute;
    if (std.mem.indexOfScalar(u8, prefix, 0) != null) return PrefixError.EmbeddedNul;
    // Tight charset closes the BUG-007/BUG-019 injection class — quotes,
    // backslashes, control bytes, parens etc. flow into single-quoted
    // Ruby literals and sandbox-profile strings unchanged.
    for (prefix) |b| if (!isAllowedPrefixByte(b)) return PrefixError.DisallowedByte;

    // Strip one trailing slash; `/opt/malt/` is fine, `//` inside is not.
    const trimmed = if (prefix.len > 1 and prefix[prefix.len - 1] == '/')
        prefix[0 .. prefix.len - 1]
    else
        prefix;
    if (trimmed.len == 1) return; // just "/" — no components to scan

    var it = std.mem.splitScalar(u8, trimmed, '/');
    _ = it.next(); // leading "/" yields an empty first slice
    while (it.next()) |comp| {
        if (comp.len == 0) return PrefixError.EmptyComponent;
        if (std.mem.eql(u8, comp, "..")) return PrefixError.DotDotComponent;
    }
}

pub fn describePrefixError(e: PrefixError) []const u8 {
    return switch (e) {
        PrefixError.Empty => "empty",
        PrefixError.NotAbsolute => "not an absolute path",
        PrefixError.DotDotComponent => "contains '..' component",
        PrefixError.EmbeddedNul => "contains NUL byte",
        PrefixError.TooLong => "exceeds 512 bytes",
        PrefixError.EmptyComponent => "contains empty path component ('//')",
        PrefixError.DisallowedByte => "contains a byte outside [a-zA-Z0-9._+-/]",
    };
}

/// Validated form of `maltPrefix`, returns an error on bad env so tests
/// can inspect the failure without the process exiting.
pub fn maltPrefixChecked() PrefixError![:0]const u8 {
    const raw = fs_compat.getenv("MALT_PREFIX") orelse return "/opt/malt";
    try validatePrefix(raw);
    return raw;
}

/// Install prefix with a fail-closed env check. A malformed MALT_PREFIX
/// is a startup misconfig or traversal attempt — abort loudly rather
/// than falling back silently.
pub fn maltPrefix() [:0]const u8 {
    return maltPrefixChecked() catch |e| {
        const raw = fs_compat.getenv("MALT_PREFIX") orelse "<unset>";
        // Bypass the UI layer — atomic.zig sits below it in the dep graph.
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "malt: refusing to use MALT_PREFIX='{s}': {s}\n",
            .{ raw, describePrefixError(e) },
        ) catch "malt: MALT_PREFIX rejected; refusing to proceed\n";
        _ = std.c.write(std.c.STDERR_FILENO, msg.ptr, msg.len);
        std.process.exit(78); // EX_CONFIG
    };
}

/// Rename `src_path` to `dst_path`. Tries a single `rename(2)` first — the
/// atomic, crash-safe path that every caller wants on the happy case. If
/// the kernel returns EXDEV (src and dst live on different filesystems,
/// which `rename(2)` cannot span) we fall back to a clone-or-copy of the
/// tree followed by removal of the source. The fallback is not atomic
/// from a crash standpoint, but the end state (dst present, src absent)
/// matches `rename` semantics; a crash mid-way leaves the tmp source
/// intact for the next housekeeping sweep to clean up.
pub fn atomicRename(src_path: []const u8, dst_path: []const u8) !void {
    fs_compat.renameAbsolute(src_path, dst_path) catch |e| switch (e) {
        error.CrossDevice => {
            try clonefile.cloneTree(src_path, dst_path);
            fs_compat.deleteTreeAbsolute(src_path) catch {};
        },
        else => return e,
    };
}

/// Write `data` to `dst_path` via a uniquely-named sibling tempfile
/// and a single `rename(2)`. Readers see either the old contents or
/// the new ones — never a partial write. A crash before the rename
/// leaves the tempfile behind; the next call writes its own and
/// overwrites atomically.
pub fn atomicWriteFile(dst_path: []const u8, data: []const u8) !void {
    var rand_bytes: [4]u8 = undefined;
    std.c.arc4random_buf(&rand_bytes, rand_bytes.len);
    const hex_chars = "0123456789abcdef";
    var hex: [8]u8 = undefined;
    for (rand_bytes, 0..) |b, i| {
        hex[i * 2] = hex_chars[b >> 4];
        hex[i * 2 + 1] = hex_chars[b & 0x0f];
    }

    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.{s}.tmp", .{ dst_path, &hex }) catch
        return error.NameTooLong;

    {
        const f = try fs_compat.createFileAbsolute(tmp_path, .{ .truncate = true });
        defer f.close();
        f.writeAll(data) catch |e| {
            fs_compat.deleteFileAbsolute(tmp_path) catch {};
            return e;
        };
    }

    fs_compat.renameAbsolute(tmp_path, dst_path) catch |e| {
        fs_compat.deleteFileAbsolute(tmp_path) catch {};
        return e;
    };
}

/// Create a temporary directory under {prefix}/tmp/ with the given label and
/// a random hex suffix.  The returned path is allocated via `allocator` and
/// the caller owns the memory.
pub fn createTempDir(allocator: std.mem.Allocator, label: []const u8) ![]const u8 {
    const prefix = maltPrefix();

    // Ensure the tmp base directory exists.
    const tmp_base = try std.fmt.allocPrint(allocator, "{s}/tmp", .{prefix});
    defer allocator.free(tmp_base);
    fs_compat.cwd().makePath(tmp_base) catch {};

    // Generate 8 random bytes -> 16 hex chars.
    var rand_bytes: [8]u8 = undefined;
    std.c.arc4random_buf(&rand_bytes, rand_bytes.len);

    var hex_buf: [16]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (rand_bytes, 0..) |b, i| {
        hex_buf[i * 2] = hex_chars[b >> 4];
        hex_buf[i * 2 + 1] = hex_chars[b & 0x0f];
    }

    const dir_path = try std.fmt.allocPrint(allocator, "{s}/tmp/{s}_{s}", .{ prefix, label, &hex_buf });

    fs_compat.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {}, // unlikely but harmless
        else => {
            allocator.free(dir_path);
            return err;
        },
    };

    return dir_path;
}

/// Remove a temporary directory recursively.  Best-effort: errors are ignored.
pub fn cleanupTempDir(dir_path: []const u8) void {
    fs_compat.deleteTreeAbsolute(dir_path) catch {};
}

/// Return "{prefix}/tmp", allocated via `allocator`.
pub fn maltTmpDir(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/tmp", .{maltPrefix()});
}

/// Return "{prefix}/db", allocated via `allocator`.
pub fn maltDbDir(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/db", .{maltPrefix()});
}

/// Return the cache directory, honouring MALT_CACHE env var.
/// Falls back to "{prefix}/cache".
pub fn maltCacheDir(allocator: std.mem.Allocator) ![]const u8 {
    if (fs_compat.getenv("MALT_CACHE")) |cache| {
        return allocator.dupe(u8, std.mem.sliceTo(cache, 0));
    }
    return std.fmt.allocPrint(allocator, "{s}/cache", .{maltPrefix()});
}
