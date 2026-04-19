//! malt — release-asset selection for self-update.
//!
//! Pure helpers that pick the right tarball from a GitHub release
//! payload and locate the binary inside the extracted tree. Kept
//! separate from I/O so tests can pin the matching rules without
//! spinning up an HTTP fixture.

const std = @import("std");
const fs_compat = @import("../fs/compat.zig");

/// Exact-name asset lookup. For `checksums.txt` and
/// `checksums.txt.sigstore.json`, which must match by name, not pattern.
pub fn pickAssetUrlByName(assets: std.json.Array, name: []const u8) ?[]const u8 {
    for (assets.items) |asset| {
        const obj = switch (asset) {
            .object => |o| o,
            else => continue,
        };
        const asset_name = strField(obj, "name") orelse continue;
        if (!std.mem.eql(u8, asset_name, name)) continue;
        return strField(obj, "browser_download_url");
    }
    return null;
}

/// First asset whose name matches `arch_str` wins. Returns its
/// `browser_download_url`, or `null` when nothing matches.
pub fn pickAssetUrl(assets: std.json.Array, arch_str: []const u8) ?[]const u8 {
    for (assets.items) |asset| {
        const obj = switch (asset) {
            .object => |o| o,
            else => continue,
        };
        const name = strField(obj, "name") orelse continue;
        if (!matchesAssetName(name, arch_str)) continue;
        return strField(obj, "browser_download_url");
    }
    return null;
}

/// True when `name` is a darwin tarball covering `arch_str` — either
/// a per-arch build or a universal (`_all` / `universal`) one.
///
/// Lowercases before comparing: GoReleaser emits `darwin` but users
/// can template the name, and we hit a real regression when the old
/// matcher insisted on `Darwin` + per-arch suffix and silently missed
/// every `_all` tarball we publish.
pub fn matchesAssetName(name: []const u8, arch_str: []const u8) bool {
    if (!std.mem.endsWith(u8, name, ".tar.gz")) return false;

    var lower_buf: [256]u8 = undefined;
    if (name.len > lower_buf.len) return false;
    const lower = std.ascii.lowerString(lower_buf[0..name.len], name);

    if (std.mem.indexOf(u8, lower, "darwin") == null) return false;
    if (std.mem.indexOf(u8, lower, arch_str) != null) return true;
    if (std.mem.indexOf(u8, lower, "_all") != null) return true;
    if (std.mem.indexOf(u8, lower, "universal") != null) return true;
    return false;
}

/// Walk `tmp_dir` and return the first file basename-matching `malt`
/// or `mt`. The absolute path is written into `out_buf` and returned
/// as a slice; caller owns the buffer. `allocator` is used only for
/// `Dir.walk`'s internal arena — nothing outlives the call.
///
/// Accepting `mt` as well covers future releases that drop `malt` in
/// favour of the short alias, so self-update survives a rename.
pub fn findReleaseBinary(
    allocator: std.mem.Allocator,
    tmp_dir: []const u8,
    out_buf: []u8,
) ?[]const u8 {
    var dir = fs_compat.openDirAbsolute(tmp_dir, .{ .iterate = true }) catch return null;
    defer dir.close();

    var walker = dir.walk(allocator) catch return null;
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        const base = std.fs.path.basename(entry.path);
        if (!std.mem.eql(u8, base, "malt") and !std.mem.eql(u8, base, "mt")) continue;
        const full = std.fmt.bufPrint(out_buf, "{s}/{s}", .{ tmp_dir, entry.path }) catch return null;
        return full;
    }
    return null;
}

/// Return `obj[key]` when it is a JSON string, else `null`. Pub'd so
/// the updater's `tag_name` extraction can reuse it.
pub fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}
