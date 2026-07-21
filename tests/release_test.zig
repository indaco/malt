//! malt — release-asset selection tests.
//!
//! Pure: no network, no subprocess. Covers the matcher, the URL
//! picker, and the extracted-binary walker.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");
const release = malt.update_release;

// --- asset matcher --------------------------------------------------------

test "matchesAssetName accepts goreleaser's darwin_all tarball" {
    // Regression: old matcher required `Darwin` + per-arch suffix and
    // missed every `_all` tarball we actually publish.
    try testing.expect(release.matchesAssetName("malt_0.3.1_darwin_all.tar.gz", "arm64"));
    try testing.expect(release.matchesAssetName("malt_0.3.1_darwin_all.tar.gz", "x86_64"));
}

test "matchesAssetName accepts per-arch tarballs for either arch" {
    try testing.expect(release.matchesAssetName("malt_0.3.1_darwin_arm64.tar.gz", "arm64"));
    try testing.expect(release.matchesAssetName("malt_0.3.1_darwin_x86_64.tar.gz", "x86_64"));
}

test "matchesAssetName accepts capitalized darwin (legacy name shape)" {
    // GoReleaser's template is configurable; lowercasing keeps both
    // forms working without a template-chase.
    try testing.expect(release.matchesAssetName("malt_0.3.1_Darwin_arm64.tar.gz", "arm64"));
}

test "matchesAssetName rejects non-darwin builds" {
    try testing.expect(!release.matchesAssetName("malt_0.3.1_linux_arm64.tar.gz", "arm64"));
    try testing.expect(!release.matchesAssetName("malt_0.3.1_windows_x86_64.tar.gz", "x86_64"));
}

test "matchesAssetName rejects the wrong arch on a per-arch build" {
    try testing.expect(!release.matchesAssetName("malt_0.3.1_darwin_x86_64.tar.gz", "arm64"));
    try testing.expect(!release.matchesAssetName("malt_0.3.1_darwin_arm64.tar.gz", "x86_64"));
}

test "matchesAssetName rejects names longer than the internal lowercase buffer" {
    // The matcher uses a 256-byte stack buffer for the lowercase copy.
    // Names exceeding it must return false (not silently truncate and
    // match). Documents the boundary so a future GoReleaser template
    // change that produces longer names surfaces a clear fix.
    var buf: [300]u8 = undefined;
    @memset(&buf, 'a');
    std.mem.copyForwards(u8, buf[buf.len - 22 ..], "_darwin_all.tar.gz.zip");
    try testing.expect(!release.matchesAssetName(buf[0..buf.len], "arm64"));
}

test "matchesAssetName rejects the non-tarball sibling assets" {
    // Release set also contains checksums + signature files; only the
    // tarball is ever a valid pick.
    try testing.expect(!release.matchesAssetName("checksums.txt", "arm64"));
    try testing.expect(!release.matchesAssetName("malt_0.3.1_darwin_all.zip", "arm64"));
    try testing.expect(!release.matchesAssetName("malt_0.3.1_darwin_all.tar.gz.sig", "arm64"));
}

test "pickAssetUrl returns the browser_download_url of the first match" {
    const json =
        \\[
        \\  {"name":"checksums.txt","browser_download_url":"https://example.com/checksums.txt"},
        \\  {"name":"malt_0.3.1_darwin_all.tar.gz","browser_download_url":"https://example.com/malt.tgz"}
        \\]
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.Unexpected,
    };
    const url = release.pickAssetUrl(arr, "arm64") orelse return error.NoMatch;
    try testing.expectEqualStrings("https://example.com/malt.tgz", url);
}

test "pickAssetUrlByName finds checksums + sigstore bundle by exact name" {
    const json =
        \\[
        \\  {"name":"malt_0.7.0_darwin_all.tar.gz","browser_download_url":"https://example.com/malt.tgz"},
        \\  {"name":"checksums.txt","browser_download_url":"https://example.com/checksums.txt"},
        \\  {"name":"checksums.txt.sigstore.json","browser_download_url":"https://example.com/sigstore.json"}
        \\]
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.Unexpected,
    };
    try testing.expectEqualStrings(
        "https://example.com/checksums.txt",
        release.pickAssetUrlByName(arr, "checksums.txt") orelse return error.NoMatch,
    );
    try testing.expectEqualStrings(
        "https://example.com/sigstore.json",
        release.pickAssetUrlByName(arr, "checksums.txt.sigstore.json") orelse return error.NoMatch,
    );
}

test "pickAssetUrlByName returns null for an unknown name" {
    const json =
        \\[
        \\  {"name":"checksums.txt","browser_download_url":"https://example.com/checksums.txt"}
        \\]
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.Unexpected,
    };
    try testing.expect(release.pickAssetUrlByName(arr, "does-not-exist.txt") == null);
}

test "pickAssetUrl returns null when nothing matches" {
    const json =
        \\[
        \\  {"name":"malt_0.3.1_linux_arm64.tar.gz","browser_download_url":"https://example.com/linux.tgz"}
        \\]
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.Unexpected,
    };
    try testing.expect(release.pickAssetUrl(arr, "arm64") == null);
}

// --- extracted-tarball layout ---------------------------------------------

/// Scratch tree under a process-unique base, so overlapping test runs cannot
/// wipe each other's fixtures.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    base: []const u8,
    dir: std.Io.Dir,

    fn init(tag: []const u8) !Fixture {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const base = try test_io.uniqueTempPath(arena.allocator(), "findbin", tag);
        test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};
        try test_io.makeDirAbsolute(std.Options.debug_io, base);
        return .{
            .arena = arena,
            .base = base,
            .dir = try test_io.openDirAbsolute(std.Options.debug_io, base, .{ .iterate = true }),
        };
    }

    fn deinit(self: *Fixture) void {
        self.dir.close(std.Options.debug_io);
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.base) catch {};
        self.arena.deinit();
    }
};

fn touch(dir: std.Io.Dir, rel: []const u8, content: []const u8) !void {
    const f = try dir.createFile(std.Options.debug_io, rel, .{});
    defer f.close(std.Options.debug_io);
    try f.writeStreamingAll(std.Options.debug_io, content);
}

test "findReleaseBinary locates malt nested under GoReleaser's versioned dir" {
    // Mirrors the real tarball layout: malt_<ver>_darwin_all/{LICENSE,README,malt}
    var fx = try Fixture.init("nested");
    defer fx.deinit();

    try fx.dir.createDirPath(std.Options.debug_io, "malt_0.3.1_darwin_all");
    var sub = try fx.dir.openDir(std.Options.debug_io, "malt_0.3.1_darwin_all", .{});
    defer sub.close(std.Options.debug_io);
    try touch(sub, "LICENSE", "MIT");
    try touch(sub, "README.md", "# malt");
    try touch(sub, "malt", "binary-bytes");

    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const found = release.findReleaseBinary(std.Options.debug_io, testing.allocator, fx.base, &out_buf) orelse
        return error.ExpectedMatch;

    try testing.expect(std.mem.endsWith(u8, found, "/malt_0.3.1_darwin_all/malt"));
    const f = try test_io.openFileAbsolute(std.Options.debug_io, found, .{});
    defer f.close(std.Options.debug_io);
    var buf: [64]u8 = undefined;
    const n = try f.readPositionalAll(std.Options.debug_io, &buf, 0);
    try testing.expectEqualStrings("binary-bytes", buf[0..n]);
}

test "findReleaseBinary accepts a flat layout with the binary at the root" {
    // Forks or future layouts may drop the wrap-in-dir.
    var fx = try Fixture.init("flat");
    defer fx.deinit();

    try touch(fx.dir, "malt", "binary-bytes");

    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const found = release.findReleaseBinary(std.Options.debug_io, testing.allocator, fx.base, &out_buf) orelse
        return error.ExpectedMatch;
    try testing.expect(std.mem.endsWith(u8, found, "/malt"));
}

test "findReleaseBinary accepts the `mt` alias when `malt` is absent" {
    // Survives a release that renames the binary to the short alias.
    var fx = try Fixture.init("mt_only");
    defer fx.deinit();

    try fx.dir.createDirPath(std.Options.debug_io, "wrap");
    var sub = try fx.dir.openDir(std.Options.debug_io, "wrap", .{});
    defer sub.close(std.Options.debug_io);
    try touch(sub, "mt", "binary-bytes");

    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const found = release.findReleaseBinary(std.Options.debug_io, testing.allocator, fx.base, &out_buf) orelse
        return error.ExpectedMatch;
    try testing.expect(std.mem.endsWith(u8, found, "/wrap/mt"));
}

test "findReleaseBinary returns null when the archive has no matching binary" {
    // Caller surfaces a clear error instead of silently no-op'ing.
    var fx = try Fixture.init("missing");
    defer fx.deinit();

    try touch(fx.dir, "LICENSE", "MIT");
    try touch(fx.dir, "README.md", "# malt");

    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(release.findReleaseBinary(std.Options.debug_io, testing.allocator, fx.base, &out_buf) == null);
}

test "findReleaseBinary returns null when the prefix does not exist" {
    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(
        release.findReleaseBinary(std.Options.debug_io, testing.allocator, "/tmp/malt_findbin_absent_xyz_99", &out_buf) == null,
    );
}

test "stripVPrefix drops a leading 'v' but leaves bare versions and edges alone" {
    try testing.expectEqualStrings("0.10.1", release.stripVPrefix("v0.10.1"));
    try testing.expectEqualStrings("0.10.1", release.stripVPrefix("0.10.1"));
    try testing.expectEqualStrings("", release.stripVPrefix(""));
    try testing.expectEqualStrings("", release.stripVPrefix("v"));
    // Single-letter input that is not 'v' must pass through.
    try testing.expectEqualStrings("x", release.stripVPrefix("x"));
}
