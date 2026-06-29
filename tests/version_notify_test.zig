//! malt — passive version-notify tests.
//!
//! Pure-logic + cache-file IO. The HTTP refresh path is exercised live
//! by the inline tests in `src/update/notifier.zig` only as far as the
//! decode/encode shape; the network call itself is left to the existing
//! `HttpClient` test surface.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");
const notifier = malt.update_notifier;
const app_ctx = malt.app_ctx;
const fs_compat = test_io;

const c_env = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

test "shouldNotify: full table — equal/newer/post-update" {
    const Case = struct {
        current: []const u8,
        latest: []const u8,
        seen: []const u8,
        want: bool,
    };
    const cases = [_]Case{
        .{ .current = "0.10.0", .latest = "v0.10.0", .seen = "0.10.0", .want = false },
        .{ .current = "0.10.0", .latest = "v0.10.1", .seen = "0.10.0", .want = true },
        .{ .current = "0.10.0", .latest = "0.10.1", .seen = "", .want = true },
        .{ .current = "0.10.1", .latest = "v0.10.1", .seen = "0.10.1", .want = false },
        .{ .current = "0.10.0", .latest = "", .seen = "", .want = false },
        // Latest semver-behind current: byte inequality once nagged; semver stays quiet.
        .{ .current = "0.10.0", .latest = "v0.9.0", .seen = "", .want = false },
    };
    for (cases) |c| {
        const got = notifier.shouldNotify(c.current, c.latest, c.seen);
        testing.expectEqual(c.want, got) catch |err| {
            std.debug.print("shouldNotify({s}, {s}, {s}) = {}, want {}\n", .{
                c.current, c.latest, c.seen, got, c.want,
            });
            return err;
        };
    }
}

test "cacheStale: TTL boundary table" {
    const Case = struct { now: i64, checked: i64, ttl: i64, want: bool };
    const cases = [_]Case{
        .{ .now = 100, .checked = 100, .ttl = 60, .want = false },
        .{ .now = 159, .checked = 100, .ttl = 60, .want = false },
        .{ .now = 160, .checked = 100, .ttl = 60, .want = true },
        .{ .now = 9999, .checked = 100, .ttl = 60, .want = true },
        // Clock skew: cache from the future is treated as fresh.
        .{ .now = 50, .checked = 100, .ttl = 60, .want = false },
    };
    for (cases) |c| {
        try testing.expectEqual(c.want, notifier.cacheStale(c.now, c.checked, c.ttl));
    }
}

test "isSkippedCommand: meta commands skip; install-pipeline does NOT" {
    // Meta: own their own messaging or do no work. Notice would be noise.
    try testing.expect(notifier.isSkippedCommand("version"));
    try testing.expect(notifier.isSkippedCommand("--version"));
    try testing.expect(notifier.isSkippedCommand("help"));
    try testing.expect(notifier.isSkippedCommand("--help"));
    try testing.expect(notifier.isSkippedCommand("-h"));
    try testing.expect(notifier.isSkippedCommand("")); // defensive

    // Install-pipeline / heavy mutation commands — notice fires AFTER the
    // pipeline. bench.sh is unaffected because it redirects stderr to a
    // file, tripping the non-TTY suppression rule instead.
    try testing.expect(!notifier.isSkippedCommand("install"));
    try testing.expect(!notifier.isSkippedCommand("uninstall"));
    try testing.expect(!notifier.isSkippedCommand("upgrade"));
    try testing.expect(!notifier.isSkippedCommand("migrate"));
    try testing.expect(!notifier.isSkippedCommand("bundle"));

    // Read-only / fast commands clearly keep the notice.
    try testing.expect(!notifier.isSkippedCommand("list"));
    try testing.expect(!notifier.isSkippedCommand("info"));
    try testing.expect(!notifier.isSkippedCommand("search"));
    try testing.expect(!notifier.isSkippedCommand("outdated"));
    try testing.expect(!notifier.isSkippedCommand("doctor"));
}

test "notifierDisabledFromValue: only \"1\" disables (matches MALT_ALLOW_UNVERIFIED shape)" {
    try testing.expect(!notifier.notifierDisabledFromValue(null));
    try testing.expect(!notifier.notifierDisabledFromValue(""));
    try testing.expect(!notifier.notifierDisabledFromValue("0"));
    try testing.expect(!notifier.notifierDisabledFromValue("true"));
    try testing.expect(!notifier.notifierDisabledFromValue("yes"));
    try testing.expect(notifier.notifierDisabledFromValue("1"));
}

test "isCiFromValues: detects any non-empty CI variable" {
    const empty = [_]?[]const u8{ null, null, null, null, null, null, null };
    try testing.expect(!notifier.isCiFromValues(&empty));

    const all_empty_strings = [_]?[]const u8{ "", "", "", "", "", "", "" };
    try testing.expect(!notifier.isCiFromValues(&all_empty_strings));

    // Each slot in turn — proves no off-by-one in the loop.
    var slots = [_]?[]const u8{ null, null, null, null, null, null, null };
    var i: usize = 0;
    while (i < slots.len) : (i += 1) {
        slots = [_]?[]const u8{ null, null, null, null, null, null, null };
        slots[i] = "yes";
        try testing.expect(notifier.isCiFromValues(&slots));
    }
}

test "cacheDirFrom: precedence MALT_CACHE > XDG_CACHE_HOME > HOME" {
    var buf: [256]u8 = undefined;
    {
        const got = notifier.cacheDirFrom(.{
            .malt_cache = "/m",
            .xdg_cache_home = "/x",
            .home = "/h",
        }, &buf) orelse return error.TestExpectedNonNull;
        try testing.expectEqualStrings("/m", got);
    }
    {
        const got = notifier.cacheDirFrom(.{
            .xdg_cache_home = "/x",
            .home = "/h",
        }, &buf) orelse return error.TestExpectedNonNull;
        try testing.expectEqualStrings("/x/malt", got);
    }
    {
        const got = notifier.cacheDirFrom(.{ .home = "/h" }, &buf) orelse return error.TestExpectedNonNull;
        try testing.expectEqualStrings("/h/.cache/malt", got);
    }
    try testing.expect(notifier.cacheDirFrom(.{}, &buf) == null);
}

test "cachePathFrom: appends version-notify.json to the resolved dir" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const got = notifier.cachePathFrom(.{ .malt_cache = "/cache" }, &buf) orelse
        return error.TestExpectedNonNull;
    try testing.expectEqualStrings("/cache/version-notify.json", got);
}

test "encodeState/decodeState round-trip preserves every field" {
    const allocator = testing.allocator;
    var buf: [1024]u8 = undefined;
    const encoded = try notifier.encodeState(&buf, .{
        .checked_at = 1714400000,
        .latest_tag = "v0.10.1",
        .current_seen = "0.10.0",
        .last_attempt = 1714400500,
    });
    const got = (try notifier.decodeState(allocator, encoded)) orelse
        return error.TestExpectedNonNull;
    defer notifier.freeState(allocator, got);
    try testing.expectEqual(@as(i64, 1714400000), got.checked_at);
    try testing.expectEqualStrings("v0.10.1", got.latest_tag);
    try testing.expectEqualStrings("0.10.0", got.current_seen);
    try testing.expectEqual(@as(i64, 1714400500), got.last_attempt);
}

test "decodeState: caches written before last_attempt existed default to 0" {
    // Old cache files lack the `last_attempt` key; tolerant decode keeps
    // them readable so a downgrade-then-upgrade round-trip is safe.
    const legacy = "{\"checked_at\":42,\"latest_tag\":\"v0.10.0\",\"current_seen\":\"0.9.0\"}";
    const got = (try notifier.decodeState(testing.allocator, legacy)) orelse
        return error.TestExpectedNonNull;
    defer notifier.freeState(testing.allocator, got);
    try testing.expectEqual(@as(i64, 0), got.last_attempt);
}

test "inFailureBackoff: only fires when last_attempt > checked_at" {
    // Equal pair = success shape; never a backoff.
    try testing.expect(!notifier.inFailureBackoff(1000, 500, 500, 60));
    // last_attempt newer than checked_at + within window → back off.
    try testing.expect(notifier.inFailureBackoff(550, 500, 100, 60));
    // Window elapsed → no longer backing off.
    try testing.expect(!notifier.inFailureBackoff(600, 500, 100, 60));
    // Clock skew (now < last_attempt) — never back off, never crash.
    try testing.expect(!notifier.inFailureBackoff(400, 500, 100, 60));
}

test "writeFailureMarker preserves prior cache and bumps last_attempt" {
    const allocator = testing.allocator;
    const io = std.Options.debug_io;

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/malt_notify_fail_{d}", .{fs_compat.nanoTimestamp(
        std.Options.debug_io,
    )});
    fs_compat.deleteTreeAbsolute(std.Options.debug_io, dir) catch {};
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, dir) catch {};

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/version-notify.json", .{dir});

    // Seed a successful cache, then simulate a probe failure.
    try notifier.writeCache(io, path, .{
        .checked_at = 100,
        .latest_tag = "v0.10.1",
        .current_seen = "0.10.0",
        .last_attempt = 100,
    });
    const prior = (try notifier.readCache(io, allocator, path)) orelse return error.TestExpectedNonNull;
    defer notifier.freeState(allocator, prior);

    notifier.writeFailureMarker(io, path, prior, 250, "0.10.0");

    const after = (try notifier.readCache(io, allocator, path)) orelse return error.TestExpectedNonNull;
    defer notifier.freeState(allocator, after);
    // checked_at stays at the last successful probe; only last_attempt moves.
    try testing.expectEqual(@as(i64, 100), after.checked_at);
    try testing.expectEqual(@as(i64, 250), after.last_attempt);
    try testing.expectEqualStrings("v0.10.1", after.latest_tag);
    try testing.expectEqualStrings("0.10.0", after.current_seen);
}

test "markUpdatedTo bumps current_seen so a manual --check stops the nag" {
    // Pin the N-10 contract: a manual `mt version update --check` that
    // confirms `latest == current` must update `current_seen` so
    // `shouldNotify` flips to false on the next invocation.
    const allocator = testing.allocator;
    const io = std.Options.debug_io;

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dir_buf, "/tmp/malt_notify_check_{d}", .{fs_compat.nanoTimestamp(
        std.Options.debug_io,
    )});
    fs_compat.deleteTreeAbsolute(std.Options.debug_io, dir) catch {};
    try fs_compat.makeDirAbsolute(std.Options.debug_io, dir);
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, dir) catch {};

    _ = c_env.setenv("MALT_CACHE", dir.ptr, 1);
    defer _ = c_env.unsetenv("MALT_CACHE");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/version-notify.json", .{dir});

    // Pre-seed a stale cache: notifier observed v0.10.1 long ago and the
    // user has since installed it elsewhere, so current_seen drifted.
    try notifier.writeCache(io, path, .{
        .checked_at = 1,
        .latest_tag = "v0.10.1",
        .current_seen = "0.10.0",
        .last_attempt = 1,
    });

    // Snapshot the live env so cachePath sees MALT_CACHE.
    const ctx: app_ctx.AppCtx = .{ .io = io, .environ = app_ctx.processEnviron() };
    notifier.markUpdatedTo(&ctx, "v0.10.1", "0.10.1");

    const got = (try notifier.readCache(io, allocator, path)) orelse return error.TestExpectedNonNull;
    defer notifier.freeState(allocator, got);
    try testing.expectEqualStrings("v0.10.1", got.latest_tag);
    try testing.expectEqualStrings("0.10.1", got.current_seen);
    try testing.expect(!notifier.shouldNotify("0.10.1", got.latest_tag, got.current_seen));
}

test "writeFailureMarker on a first-ever run records only the failed attempt" {
    const allocator = testing.allocator;
    const io = std.Options.debug_io;

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/malt_notify_first_{d}", .{fs_compat.nanoTimestamp(
        std.Options.debug_io,
    )});
    fs_compat.deleteTreeAbsolute(std.Options.debug_io, dir) catch {};
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, dir) catch {};

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/version-notify.json", .{dir});

    notifier.writeFailureMarker(io, path, null, 500, "0.10.0");

    const got = (try notifier.readCache(io, allocator, path)) orelse return error.TestExpectedNonNull;
    defer notifier.freeState(allocator, got);
    try testing.expectEqual(@as(i64, 0), got.checked_at);
    try testing.expectEqual(@as(i64, 500), got.last_attempt);
    try testing.expectEqualStrings("", got.latest_tag);
    try testing.expectEqualStrings("0.10.0", got.current_seen);
}

test "decodeState: malformed JSON yields error.InvalidPayload" {
    try testing.expectError(error.InvalidPayload, notifier.decodeState(testing.allocator, "{nope"));
}

test "decodeState: missing required field yields null (not an error)" {
    const got = try notifier.decodeState(testing.allocator, "{\"checked_at\":1}");
    try testing.expect(got == null);
}

test "writeCache + readCache full round-trip on disk" {
    const allocator = testing.allocator;
    const io = std.Options.debug_io;

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/malt_notify_test_{d}", .{fs_compat.nanoTimestamp(
        std.Options.debug_io,
    )});
    fs_compat.deleteTreeAbsolute(std.Options.debug_io, dir) catch {};
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, dir) catch {};

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/version-notify.json", .{dir});

    try notifier.writeCache(io, path, .{
        .checked_at = 42,
        .latest_tag = "v0.99.0",
        .current_seen = "0.10.0",
        .last_attempt = 42,
    });

    const got = (try notifier.readCache(io, allocator, path)) orelse return error.TestExpectedNonNull;
    defer notifier.freeState(allocator, got);

    try testing.expectEqual(@as(i64, 42), got.checked_at);
    try testing.expectEqualStrings("v0.99.0", got.latest_tag);
    try testing.expectEqualStrings("0.10.0", got.current_seen);
    try testing.expectEqual(@as(i64, 42), got.last_attempt);
}

test "writeCache creates the parent directory when absent" {
    const allocator = testing.allocator;
    const io = std.Options.debug_io;

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/malt_notify_mkdir_{d}", .{fs_compat.nanoTimestamp(
        std.Options.debug_io,
    )});
    fs_compat.deleteTreeAbsolute(std.Options.debug_io, dir) catch {};
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, dir) catch {};

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    // Three-deep path to confirm `createDirPath` recurses (not just the leaf).
    const path = try std.fmt.bufPrint(&path_buf, "{s}/a/b/c/version-notify.json", .{dir});

    try notifier.writeCache(io, path, .{
        .checked_at = 0,
        .latest_tag = "v1.0.0",
        .current_seen = "0.0.0",
    });

    const got = (try notifier.readCache(io, allocator, path)) orelse return error.TestExpectedNonNull;
    defer notifier.freeState(allocator, got);
    try testing.expectEqualStrings("v1.0.0", got.latest_tag);
}

test "readCache: missing file is null, not an error" {
    const io = std.Options.debug_io;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/tmp/malt_notify_absent_{d}.json", .{fs_compat.nanoTimestamp(
        std.Options.debug_io,
    )});
    fs_compat.deleteFileAbsolute(std.Options.debug_io, path) catch {};
    const got = try notifier.readCache(io, testing.allocator, path);
    try testing.expect(got == null);
}

test "readCache: corrupt file surfaces InvalidPayload (caller can choose to ignore)" {
    const io = std.Options.debug_io;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/malt_notify_corrupt_{d}", .{fs_compat.nanoTimestamp(
        std.Options.debug_io,
    )});
    fs_compat.deleteTreeAbsolute(std.Options.debug_io, dir) catch {};
    try fs_compat.makeDirAbsolute(std.Options.debug_io, dir);
    defer fs_compat.deleteTreeAbsolute(std.Options.debug_io, dir) catch {};

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/version-notify.json", .{dir});
    {
        const f = try fs_compat.createFileAbsolute(std.Options.debug_io, path, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "garbage{not_json");
    }

    try testing.expectError(error.InvalidPayload, notifier.readCache(io, testing.allocator, path));
}
