//! malt — outdated parallelisation tests
//!
//! Cache-seeded integration tests for `collectOutdatedFormulas` /
//! `collectOutdatedCasks`. Pure helper assertions live next to their
//! definitions in `src/cli/outdated.zig` as inline `test` blocks.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const outdated_mod = malt.cli_outdated;
const api_mod = malt.api;
const client_mod = malt.client;

// --- Integration: collectOutdatedFormulas / collectOutdatedCasks ---

const TempCacheDir = struct {
    path: []const u8,

    fn init(comptime tag: []const u8) !TempCacheDir {
        const p = "/tmp/malt_outdated_test_" ++ tag;
        malt.fs_compat.deleteTreeAbsolute(p) catch {};
        try malt.fs_compat.makeDirAbsolute(p);
        return .{ .path = p };
    }

    fn deinit(self: *TempCacheDir) void {
        malt.fs_compat.deleteTreeAbsolute(self.path) catch {};
    }

    fn writeCacheFile(self: *TempCacheDir, rel: []const u8, content: []const u8) !void {
        var api_buf: [512]u8 = undefined;
        const api_dir = try std.fmt.bufPrint(&api_buf, "{s}/api", .{self.path});
        malt.fs_compat.makeDirAbsolute(api_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        var path_buf: [512]u8 = undefined;
        const full = try std.fmt.bufPrint(&path_buf, "{s}/api/{s}", .{ self.path, rel });
        const f = try malt.fs_compat.cwd().createFile(full, .{});
        defer f.close();
        try f.writeAll(content);
    }
};

fn freeEntries(allocator: std.mem.Allocator, entries: []outdated_mod.OutdatedEntry) void {
    for (entries) |e| {
        allocator.free(e.name);
        allocator.free(e.installed);
        allocator.free(e.latest);
    }
    allocator.free(entries);
}

fn seedFormula(dir: *TempCacheDir, name: []const u8, latest: []const u8) !void {
    var key_buf: [128]u8 = undefined;
    const file = try std.fmt.bufPrint(&key_buf, "formula_{s}.json", .{name});
    var body_buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "{{\"name\":\"{s}\",\"versions\":{{\"stable\":\"{s}\"}}}}", .{ name, latest });
    try dir.writeCacheFile(file, body);
}

fn seedCask(dir: *TempCacheDir, token: []const u8, latest: []const u8) !void {
    var key_buf: [128]u8 = undefined;
    const file = try std.fmt.bufPrint(&key_buf, "cask_{s}.json", .{token});
    var body_buf: [512]u8 = undefined;
    // parseCask needs `url` too — minimal shape so it returns ok.
    const body = try std.fmt.bufPrint(
        &body_buf,
        "{{\"token\":\"{s}\",\"name\":[\"{s}\"],\"version\":\"{s}\",\"url\":\"https://example.invalid/{s}.dmg\"}}",
        .{ token, token, latest, token },
    );
    try dir.writeCacheFile(file, body);
}

test "collectOutdatedFormulas (small-N, single-client path) returns sorted outdated rows only" {
    var http = client_mod.HttpClient.init(testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("formulas_small");
    defer dir.deinit();

    try seedFormula(&dir, "alpha", "2.0");
    try seedFormula(&dir, "bravo", "1.0");
    try seedFormula(&dir, "charlie", "3.5");

    var api = api_mod.BrewApi.init(testing.allocator, &http, dir.path);

    const kegs = [_]outdated_mod.KegRow{
        .{ .name = "alpha", .version = "1.0" }, // outdated
        .{ .name = "bravo", .version = "1.0" }, // up-to-date
        .{ .name = "charlie", .version = "3.0" }, // outdated
    };

    const out = try outdated_mod.collectOutdatedFormulas(testing.allocator, &api, dir.path, &kegs, null);
    defer freeEntries(testing.allocator, out);

    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("alpha", out[0].name);
    try testing.expectEqualStrings("1.0", out[0].installed);
    try testing.expectEqualStrings("2.0", out[0].latest);
    try testing.expectEqualStrings("charlie", out[1].name);
    try testing.expectEqualStrings("3.0", out[1].installed);
    try testing.expectEqualStrings("3.5", out[1].latest);
}

test "collectOutdatedFormulas (large-N, pool path) preserves sorted order" {
    var http = client_mod.HttpClient.init(testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("formulas_large");
    defer dir.deinit();

    // 10 fake formulas, all outdated (installed=1.0, latest=2.0).
    // 10 > OUTDATED_DEFAULT_WORKERS so the pool path runs.
    const names = [_][]const u8{
        "f00", "f01", "f02", "f03", "f04",
        "f05", "f06", "f07", "f08", "f09",
    };
    for (names) |n| try seedFormula(&dir, n, "2.0");

    var rows_buf: [names.len]outdated_mod.KegRow = undefined;
    for (names, 0..) |n, i| rows_buf[i] = .{ .name = n, .version = "1.0" };

    var api = api_mod.BrewApi.init(testing.allocator, &http, dir.path);
    const out = try outdated_mod.collectOutdatedFormulas(testing.allocator, &api, dir.path, &rows_buf, null);
    defer freeEntries(testing.allocator, out);

    try testing.expectEqual(@as(usize, names.len), out.len);
    for (out, 0..) |entry, i| {
        try testing.expectEqualStrings(names[i], entry.name);
        try testing.expectEqualStrings("1.0", entry.installed);
        try testing.expectEqualStrings("2.0", entry.latest);
    }
}

test "collectOutdatedFormulas tolerates a missing/404 entry without aborting" {
    // One name has no cache entry — the worker treats it as "no remote
    // info" and the row drops out of the result rather than failing the
    // whole command.
    var http = client_mod.HttpClient.init(testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("formulas_partial");
    defer dir.deinit();

    try seedFormula(&dir, "alpha", "2.0");
    // 'ghost' is intentionally not seeded; with no network it yields null.
    try seedFormula(&dir, "zulu", "9.9");

    var api = api_mod.BrewApi.init(testing.allocator, &http, dir.path);

    const kegs = [_]outdated_mod.KegRow{
        .{ .name = "alpha", .version = "1.0" },
        .{ .name = "ghost", .version = "0.1" },
        .{ .name = "zulu", .version = "1.0" },
    };

    const out = try outdated_mod.collectOutdatedFormulas(testing.allocator, &api, dir.path, &kegs, null);
    defer freeEntries(testing.allocator, out);

    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("alpha", out[0].name);
    try testing.expectEqualStrings("zulu", out[1].name);
}

test "collectOutdatedCasks (small-N) returns sorted outdated rows only" {
    var http = client_mod.HttpClient.init(testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("casks_small");
    defer dir.deinit();

    try seedCask(&dir, "appone", "5.0");
    try seedCask(&dir, "appthree", "1.1");
    try seedCask(&dir, "apptwo", "2.0");

    var api = api_mod.BrewApi.init(testing.allocator, &http, dir.path);

    const kegs = [_]outdated_mod.KegRow{
        .{ .name = "appone", .version = "5.0" }, // up-to-date
        .{ .name = "appthree", .version = "1.0" }, // outdated
        .{ .name = "apptwo", .version = "1.0" }, // outdated
    };

    const out = try outdated_mod.collectOutdatedCasks(testing.allocator, &api, dir.path, &kegs, null);
    defer freeEntries(testing.allocator, out);

    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("appthree", out[0].name);
    try testing.expectEqualStrings("apptwo", out[1].name);
}

test "collectOutdatedCasks (large-N, pool path) preserves sorted order" {
    var http = client_mod.HttpClient.init(testing.allocator);
    defer http.deinit();
    var dir = try TempCacheDir.init("casks_large");
    defer dir.deinit();

    const tokens = [_][]const u8{
        "c00", "c01", "c02", "c03", "c04",
        "c05", "c06", "c07", "c08", "c09",
    };
    for (tokens) |t| try seedCask(&dir, t, "2.0");

    var rows_buf: [tokens.len]outdated_mod.KegRow = undefined;
    for (tokens, 0..) |t, i| rows_buf[i] = .{ .name = t, .version = "1.0" };

    var api = api_mod.BrewApi.init(testing.allocator, &http, dir.path);
    const out = try outdated_mod.collectOutdatedCasks(testing.allocator, &api, dir.path, &rows_buf, null);
    defer freeEntries(testing.allocator, out);

    try testing.expectEqual(@as(usize, tokens.len), out.len);
    for (out, 0..) |entry, i| {
        try testing.expectEqualStrings(tokens[i], entry.name);
        try testing.expectEqualStrings("1.0", entry.installed);
        try testing.expectEqualStrings("2.0", entry.latest);
    }
}
