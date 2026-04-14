//! malt — version update tests
//! Network-dependent tests deferred. Unit tests cover version parsing
//! and the release-asset matcher — the latter is pure and was the
//! silent failure point on every real self-update attempt before the
//! fix (GoReleaser emits lowercase `darwin` + `_all` suffix, old
//! matcher looked for `Darwin` + per-arch suffix).

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const version_mod = malt.version;
const updater = malt.cli_version_update;

test "version value is non-empty and trimmed" {
    try testing.expect(version_mod.value.len > 0);
    // Should not have trailing whitespace
    try testing.expect(version_mod.value[version_mod.value.len - 1] != '\n');
    try testing.expect(version_mod.value[version_mod.value.len - 1] != ' ');
}

// --- asset matcher --------------------------------------------------------

test "matchesAssetName accepts goreleaser's darwin_all tarball" {
    // This is the exact name shape published by our release workflow.
    // Regression for the old matcher that required `Darwin` + an
    // explicit arch, which missed this asset on every invocation.
    try testing.expect(updater.matchesAssetName("malt_0.3.1_darwin_all.tar.gz", "arm64"));
    try testing.expect(updater.matchesAssetName("malt_0.3.1_darwin_all.tar.gz", "x86_64"));
}

test "matchesAssetName accepts per-arch tarballs for either arch" {
    try testing.expect(updater.matchesAssetName("malt_0.3.1_darwin_arm64.tar.gz", "arm64"));
    try testing.expect(updater.matchesAssetName("malt_0.3.1_darwin_x86_64.tar.gz", "x86_64"));
}

test "matchesAssetName accepts capitalized darwin (legacy name shape)" {
    // GoReleaser's template is configurable — callers may switch back
    // to the capitalized form. Lowercasing keeps both shapes working.
    try testing.expect(updater.matchesAssetName("malt_0.3.1_Darwin_arm64.tar.gz", "arm64"));
}

test "matchesAssetName rejects non-darwin builds" {
    try testing.expect(!updater.matchesAssetName("malt_0.3.1_linux_arm64.tar.gz", "arm64"));
    try testing.expect(!updater.matchesAssetName("malt_0.3.1_windows_x86_64.tar.gz", "x86_64"));
}

test "matchesAssetName rejects the wrong arch on a per-arch build" {
    try testing.expect(!updater.matchesAssetName("malt_0.3.1_darwin_x86_64.tar.gz", "arm64"));
    try testing.expect(!updater.matchesAssetName("malt_0.3.1_darwin_arm64.tar.gz", "x86_64"));
}

test "matchesAssetName rejects the non-tarball sibling assets" {
    // Release artefact set always includes the tarball plus checksums
    // and signatures. Only the tarball should ever be picked.
    try testing.expect(!updater.matchesAssetName("checksums.txt", "arm64"));
    try testing.expect(!updater.matchesAssetName("malt_0.3.1_darwin_all.zip", "arm64"));
    try testing.expect(!updater.matchesAssetName("malt_0.3.1_darwin_all.tar.gz.sig", "arm64"));
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
    const url = updater.pickAssetUrl(arr, "arm64") orelse return error.NoMatch;
    try testing.expectEqualStrings("https://example.com/malt.tgz", url);
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
    try testing.expect(updater.pickAssetUrl(arr, "arm64") == null);
}

// --- extracted-tarball layout ---------------------------------------------

/// Reset a scratch directory tree for a single test. The tree under
/// `path` is fully deleted so fixtures from previous runs (or earlier
/// failed assertions) cannot influence the current one.
fn resetTree(path: []const u8) !std.fs.Dir {
    std.fs.deleteTreeAbsolute(path) catch {};
    try std.fs.makeDirAbsolute(path);
    return std.fs.openDirAbsolute(path, .{ .iterate = true });
}

fn touch(dir: std.fs.Dir, rel: []const u8, content: []const u8) !void {
    const f = try dir.createFile(rel, .{});
    defer f.close();
    try f.writeAll(content);
}

test "findReleaseBinary locates malt nested under GoReleaser's versioned dir" {
    // Mirrors the real tarball layout:
    //   malt_0.3.1_darwin_all/
    //     LICENSE
    //     README.md
    //     malt
    // Confirms the walker descends into the wrap-in-directory layer
    // and returns the binary's path, not just its basename.
    const base = "/tmp/malt_findbin_nested";
    var dir = try resetTree(base);
    defer dir.close();
    defer std.fs.deleteTreeAbsolute(base) catch {};

    try dir.makePath("malt_0.3.1_darwin_all");
    var sub = try dir.openDir("malt_0.3.1_darwin_all", .{});
    defer sub.close();
    try touch(sub, "LICENSE", "MIT");
    try touch(sub, "README.md", "# malt");
    try touch(sub, "malt", "binary-bytes");

    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const found = updater.findReleaseBinary(testing.allocator, base, &out_buf) orelse
        return error.ExpectedMatch;

    try testing.expect(std.mem.endsWith(u8, found, "/malt_0.3.1_darwin_all/malt"));
    // The returned path must actually exist and be the file we wrote.
    const f = try std.fs.openFileAbsolute(found, .{});
    defer f.close();
    var buf: [64]u8 = undefined;
    const n = try f.readAll(&buf);
    try testing.expectEqualStrings("binary-bytes", buf[0..n]);
}

test "findReleaseBinary accepts a flat layout with the binary at the root" {
    // Future tarballs or third-party forks may drop the wrap-in-dir.
    // Make sure the walker handles that shape too.
    const base = "/tmp/malt_findbin_flat";
    var dir = try resetTree(base);
    defer dir.close();
    defer std.fs.deleteTreeAbsolute(base) catch {};

    try touch(dir, "malt", "binary-bytes");

    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const found = updater.findReleaseBinary(testing.allocator, base, &out_buf) orelse
        return error.ExpectedMatch;
    try testing.expect(std.mem.endsWith(u8, found, "/malt"));
}

test "findReleaseBinary accepts the `mt` alias when `malt` is absent" {
    // Not the shape we ship today, but the self-update code has to
    // survive a release that drops `malt` in favour of `mt` (or a
    // user manually repackaging). Treating both names as equivalent
    // avoids a "Binary not found" false negative.
    const base = "/tmp/malt_findbin_mt_only";
    var dir = try resetTree(base);
    defer dir.close();
    defer std.fs.deleteTreeAbsolute(base) catch {};

    try dir.makePath("wrap");
    var sub = try dir.openDir("wrap", .{});
    defer sub.close();
    try touch(sub, "mt", "binary-bytes");

    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const found = updater.findReleaseBinary(testing.allocator, base, &out_buf) orelse
        return error.ExpectedMatch;
    try testing.expect(std.mem.endsWith(u8, found, "/wrap/mt"));
}

test "findReleaseBinary returns null when the archive has no matching binary" {
    // Simulates a future release where the binary name changed.
    // The caller surfaces a clear "binary not found" error instead
    // of silently no-op'ing the update.
    const base = "/tmp/malt_findbin_missing";
    var dir = try resetTree(base);
    defer dir.close();
    defer std.fs.deleteTreeAbsolute(base) catch {};

    try touch(dir, "LICENSE", "MIT");
    try touch(dir, "README.md", "# malt");

    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(updater.findReleaseBinary(testing.allocator, base, &out_buf) == null);
}

test "findReleaseBinary returns null when the prefix does not exist" {
    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(
        updater.findReleaseBinary(testing.allocator, "/tmp/malt_findbin_absent_xyz_99", &out_buf) == null,
    );
}
