//! malt — formula/cask ambiguity-warning regression test.
//! Pins two observable contracts around the cask-ambiguity probe in
//! `install.execute`:
//!   1. When both a formula and a cask of the same name are cached
//!      locally, the "exists as both …" warning is emitted on stderr.
//!   2. When only the formula is cached, no warning is emitted —
//!      the probe must not invent a cask out of thin air.

const std = @import("std");
const malt = @import("malt");
const testing = std.testing;
const install = @import("malt").install;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

const ambiguity_marker: []const u8 = "exists as both a formula and a cask";

const formula_wget_json =
    \\{"name":"wget","full_name":"wget","tap":"homebrew/core","desc":"","homepage":"",
    \\ "versions":{"stable":"1.0"},"revision":0,"dependencies":[],"oldnames":[],
    \\ "keg_only":false,"post_install_defined":false,
    \\ "bottle":{"stable":{"root_url":"https://ghcr.io/v2/homebrew/core/wget/blobs",
    \\   "files":{
    \\     "arm64_sequoia":{"cellar":":any","url":"https://ghcr.io/v2/arm","sha256":"aa"},
    \\     "arm64_sonoma":{"cellar":":any","url":"https://ghcr.io/v2/arm","sha256":"aa"},
    \\     "arm64_ventura":{"cellar":":any","url":"https://ghcr.io/v2/arm","sha256":"aa"},
    \\     "arm64_monterey":{"cellar":":any","url":"https://ghcr.io/v2/arm","sha256":"aa"},
    \\     "sequoia":{"cellar":":any","url":"https://ghcr.io/v2/x86","sha256":"xx"},
    \\     "sonoma":{"cellar":":any","url":"https://ghcr.io/v2/x86","sha256":"xx"},
    \\     "ventura":{"cellar":":any","url":"https://ghcr.io/v2/x86","sha256":"xx"},
    \\     "monterey":{"cellar":":any","url":"https://ghcr.io/v2/x86","sha256":"xx"}
    \\   }}}}
;

fn seedCacheFile(prefix: []const u8, rel: []const u8, body: []const u8) !void {
    const cache_api = try std.fmt.allocPrint(testing.allocator, "{s}/cache/api", .{prefix});
    defer testing.allocator.free(cache_api);
    try malt.fs_compat.cwd().makePath(cache_api);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ cache_api, rel });
    defer testing.allocator.free(path);
    const f = try malt.fs_compat.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(body);
}

test "ambiguity warning fires when both formula and cask are cached" {
    const prefix_z: [:0]const u8 = "/tmp/mamb_b";
    malt.fs_compat.deleteTreeAbsolute(prefix_z) catch {};
    try malt.fs_compat.cwd().makePath(prefix_z);
    _ = c.setenv("MALT_PREFIX", prefix_z.ptr, 1);
    defer malt.fs_compat.deleteTreeAbsolute(prefix_z) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    try seedCacheFile(prefix_z, "formula_wget.json", formula_wget_json);
    try seedCacheFile(
        prefix_z,
        "cask_wget.json",
        "{\"token\":\"wget\",\"url\":\"https://example.com/x.dmg\",\"version\":\"1\"}",
    );

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const prior_quiet = malt.output.isQuiet();
    malt.output.setQuiet(false);
    defer malt.output.setQuiet(prior_quiet);

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.io_mod.beginStderrCapture(testing.allocator, &captured);
    defer malt.io_mod.endStderrCapture();

    try install.execute(arena.allocator(), &.{ "--dry-run", "wget" });

    try testing.expect(std.mem.indexOf(u8, captured.items, ambiguity_marker) != null);
}

test "ambiguity warning is silent when no cask cache is present" {
    const prefix_z: [:0]const u8 = "/tmp/mamb_n";
    malt.fs_compat.deleteTreeAbsolute(prefix_z) catch {};
    try malt.fs_compat.cwd().makePath(prefix_z);
    _ = c.setenv("MALT_PREFIX", prefix_z.ptr, 1);
    defer malt.fs_compat.deleteTreeAbsolute(prefix_z) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    try seedCacheFile(prefix_z, "formula_wget.json", formula_wget_json);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const prior_quiet = malt.output.isQuiet();
    malt.output.setQuiet(false);
    defer malt.output.setQuiet(prior_quiet);

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.io_mod.beginStderrCapture(testing.allocator, &captured);
    defer malt.io_mod.endStderrCapture();

    try install.execute(arena.allocator(), &.{ "--dry-run", "wget" });

    try testing.expect(std.mem.indexOf(u8, captured.items, ambiguity_marker) == null);
}
