//! malt — release-asset selection for self-update.
//!
//! Pure helpers that pick the right tarball from a GitHub release
//! payload and locate the binary inside the extracted tree. Kept
//! separate from I/O so tests can pin the matching rules without
//! spinning up an HTTP fixture.

const std = @import("std");

/// Single source of truth for the GitHub release endpoint. Shared with the
/// passive notifier so it doesn't drift away from the authenticated updater.
pub const releases_latest_url = "https://api.github.com/repos/indaco/malt/releases/latest";

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
    io: std.Io,
    allocator: std.mem.Allocator,
    tmp_dir: []const u8,
    out_buf: []u8,
) ?[]const u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, tmp_dir, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var walker = dir.walk(allocator) catch return null;
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
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

/// Drop a leading `v` from a release tag. Centralised so the updater,
/// the notifier, and any future caller agree on what `v0.10.1` vs
/// `0.10.1` mean.
pub fn stripVPrefix(tag: []const u8) []const u8 {
    return if (tag.len > 0 and tag[0] == 'v') tag[1..] else tag;
}

/// Order two release strings by their `major.minor.patch` core, ignoring
/// any pre-release suffix (everything from the first `-`). Degrades to a
/// byte comparison when either side is not a clean numeric triple, so a
/// malformed tag never silences a real update — it just behaves as the
/// old string compare did. Callers strip a leading `v` first.
pub fn order(a: []const u8, b: []const u8) std.math.Order {
    const ta = coreTriple(a) orelse return std.mem.order(u8, a, b);
    const tb = coreTriple(b) orelse return std.mem.order(u8, a, b);
    for (ta, tb) |x, y| {
        const o = std.math.order(x, y);
        if (o != .eq) return o;
    }
    return .eq;
}

fn coreTriple(tag: []const u8) ?[3]u64 {
    const core = if (std.mem.indexOfScalar(u8, tag, '-')) |i| tag[0..i] else tag;
    var it = std.mem.splitScalar(u8, core, '.');
    var out: [3]u64 = undefined;
    inline for (0..3) |i| {
        const part = it.next() orelse return null;
        out[i] = std.fmt.parseInt(u64, part, 10) catch return null;
    }
    if (it.next() != null) return null; // extra components ⇒ not a clean triple
    return out;
}

// --- inline tests --------------------------------------------------------

test "order: numeric semver, not byte ordering" {
    try std.testing.expectEqual(std.math.Order.lt, order("0.19.3", "0.20.0"));
    try std.testing.expectEqual(std.math.Order.gt, order("0.20.0", "0.19.3"));
    try std.testing.expectEqual(std.math.Order.eq, order("0.20.0", "0.20.0"));
    // Byte comparison ranks "0.9.0" after "0.10.0"; semver must not.
    try std.testing.expectEqual(std.math.Order.gt, order("0.10.0", "0.9.0"));
}

test "order: pre-release suffix compares by the core triple" {
    try std.testing.expectEqual(std.math.Order.eq, order("0.20.0-dev", "0.20.0"));
    try std.testing.expectEqual(std.math.Order.gt, order("0.20.0-dev", "0.19.3"));
    try std.testing.expectEqual(std.math.Order.lt, order("0.19.3", "0.20.0-rc1"));
}

test "order: malformed component degrades to byte comparison" {
    try std.testing.expectEqual(std.mem.order(u8, "1.x.0", "1.2.0"), order("1.x.0", "1.2.0"));
    try std.testing.expectEqual(std.mem.order(u8, "1.2", "1.2.0"), order("1.2", "1.2.0"));
    try std.testing.expectEqual(std.mem.order(u8, "1.2.3.4", "1.2.3"), order("1.2.3.4", "1.2.3"));
}
