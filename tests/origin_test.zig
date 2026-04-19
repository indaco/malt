//! malt — update origin detection tests.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const origin = malt.update_origin;

const Case = struct {
    path: []const u8,
    want: origin.Origin,
};

test "classify covers every install shape the updater must distinguish" {
    const cases = [_]Case{
        // Direct: install.sh, manual copy, build output.
        .{ .path = "/usr/local/bin/malt", .want = .direct },
        .{ .path = "/opt/malt/bin/malt", .want = .direct },
        .{ .path = "/Users/alice/bin/malt", .want = .direct },
        .{ .path = "/tmp/malt-bench-main/build/malt", .want = .direct },
        // Unresolved brew shim — by contract, callers resolve first.
        .{ .path = "/opt/homebrew/bin/malt", .want = .direct },
        // Defensive: empty must not classify as homebrew.
        .{ .path = "", .want = .direct },
        // Brew formula (Cellar) — Apple Silicon, Intel, linuxbrew.
        .{ .path = "/opt/homebrew/Cellar/malt/0.6.0/bin/malt", .want = .homebrew },
        .{ .path = "/usr/local/Cellar/malt/0.6.0/bin/malt", .want = .homebrew },
        .{ .path = "/home/linuxbrew/.linuxbrew/Cellar/malt/0.6.0/bin/malt", .want = .homebrew },
        // Brew cask (Caskroom).
        .{ .path = "/opt/homebrew/Caskroom/malt/0.6.0/malt", .want = .homebrew },
        .{ .path = "/usr/local/Caskroom/malt/0.6.0/malt", .want = .homebrew },
    };

    for (cases) |c| {
        const got = origin.classify(c.path);
        testing.expectEqual(c.want, got) catch |err| {
            std.debug.print("classify({s}) = .{s}, want .{s}\n", .{
                c.path, @tagName(got), @tagName(c.want),
            });
            return err;
        };
    }
}

test "classify is pure — repeated calls agree" {
    const p = "/opt/homebrew/Cellar/malt/0.6.0/bin/malt";
    try testing.expectEqual(origin.Origin.homebrew, origin.classify(p));
    try testing.expectEqual(origin.Origin.homebrew, origin.classify(p));
}

test "classify is slash-anchored — no false positives on 'cellar' substrings" {
    try testing.expectEqual(origin.Origin.direct, origin.classify("/Users/alice/wine-cellar/malt"));
    try testing.expectEqual(origin.Origin.direct, origin.classify("/tmp/cellarish/malt"));
}

// --- classifyResolved ---------------------------------------------------
//
// Verifies that symlink resolution happens before classification, so a
// brew shim like `/opt/homebrew/bin/malt` pointing into `Cellar` is
// detected as homebrew instead of being treated as a direct install.

const fs_compat = malt.fs_compat;

fn resetScratch(allocator: std.mem.Allocator, tag: []const u8) ![]u8 {
    const dir = try std.fmt.allocPrint(allocator, "/tmp/malt_origin_test_{s}", .{tag});
    fs_compat.deleteTreeAbsolute(dir) catch {};
    try fs_compat.makeDirAbsolute(dir);
    return dir;
}

fn touch(path: []const u8) !void {
    const f = try fs_compat.createFileAbsolute(path, .{});
    defer f.close();
    try f.writeAll("");
}

test "classifyResolved reports homebrew when a shim points into /Cellar/" {
    const dir = try resetScratch(std.testing.allocator, "shim");
    defer std.testing.allocator.free(dir);
    defer fs_compat.deleteTreeAbsolute(dir) catch {};

    // Stand up a `Cellar/malt/0.6.0/bin/malt` real file.
    const cellar = try std.fmt.allocPrint(std.testing.allocator, "{s}/Cellar/malt/0.6.0/bin", .{dir});
    defer std.testing.allocator.free(cellar);
    try fs_compat.cwd().makePath(cellar);
    const real = try std.fmt.allocPrint(std.testing.allocator, "{s}/malt", .{cellar});
    defer std.testing.allocator.free(real);
    try touch(real);

    // Create a `bin/malt` shim pointing at the real file.
    const bin = try std.fmt.allocPrint(std.testing.allocator, "{s}/bin", .{dir});
    defer std.testing.allocator.free(bin);
    try fs_compat.cwd().makePath(bin);
    const shim = try std.fmt.allocPrint(std.testing.allocator, "{s}/malt", .{bin});
    defer std.testing.allocator.free(shim);
    try fs_compat.symLinkAbsolute(real, shim, .{});

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqual(origin.Origin.homebrew, origin.classifyResolved(&buf, shim));
}

test "classifyResolved reports direct for a non-symlinked direct install" {
    const dir = try resetScratch(std.testing.allocator, "direct");
    defer std.testing.allocator.free(dir);
    defer fs_compat.deleteTreeAbsolute(dir) catch {};

    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/malt", .{dir});
    defer std.testing.allocator.free(path);
    try touch(path);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqual(origin.Origin.direct, origin.classifyResolved(&buf, path));
}

test "classifyResolved falls back to direct when the path cannot be resolved" {
    // Safer than refusing to update on a transient FS error.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqual(
        origin.Origin.direct,
        origin.classifyResolved(&buf, "/tmp/malt_origin_test_absent_xyz_99"),
    );
}
