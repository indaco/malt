//! Notifier cache — file location resolution, codec, and atomic IO.
//! Format compat is the load-bearing piece: a downgraded malt must still
//! decode a newer cache, so the encoder bytes are pinned by the inline
//! round-trip tests and the integration suite.

const std = @import("std");

const atomic = @import("../../fs/atomic.zig");
const read = @import("../../fs/read.zig");
const output = @import("../../ui/output.zig");

const cache_filename = "version-notify.json";

/// Persisted as `<cache_dir>/version-notify.json`. Decoder is tolerant
/// so a downgraded malt doesn't strand the file.
pub const State = struct {
    checked_at: i64,
    /// As returned by GitHub: with the leading `v`.
    latest_tag: []const u8,
    /// Lets a fresh cache skip notices for users who've just updated.
    current_seen: []const u8,
    /// Wall-clock of the most recent probe attempt (success or failure).
    /// `last_attempt > checked_at` is the failure-marker shape: the next
    /// invocation backs off until `failure_backoff_secs` has elapsed.
    last_attempt: i64 = 0,
};

/// Precedence: `MALT_CACHE` > `XDG_CACHE_HOME` > `HOME`. Pulled into a
/// struct so the rule is testable without touching the host environment.
pub const EnvOverride = struct {
    malt_cache: ?[]const u8 = null,
    xdg_cache_home: ?[]const u8 = null,
    home: ?[]const u8 = null,
};

/// Returns slice-into-`buf`, or null if no env var in the chain is set.
pub fn cacheDirFrom(env: EnvOverride, buf: []u8) ?[]const u8 {
    if (env.malt_cache) |v| if (v.len > 0) return std.fmt.bufPrint(buf, "{s}", .{v}) catch null;
    if (env.xdg_cache_home) |v| if (v.len > 0) return std.fmt.bufPrint(buf, "{s}/malt", .{v}) catch null;
    if (env.home) |v| if (v.len > 0) return std.fmt.bufPrint(buf, "{s}/.cache/malt", .{v}) catch null;
    return null;
}

fn liveEnv(environ: std.process.Environ) EnvOverride {
    return .{
        .malt_cache = std.process.Environ.getPosix(environ, "MALT_CACHE"),
        .xdg_cache_home = std.process.Environ.getPosix(environ, "XDG_CACHE_HOME"),
        .home = std.process.Environ.getPosix(environ, "HOME"),
    };
}

pub fn cacheDir(environ: std.process.Environ, buf: []u8) ?[]const u8 {
    return cacheDirFrom(liveEnv(environ), buf);
}

pub fn cachePathFrom(env: EnvOverride, buf: []u8) ?[]const u8 {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = cacheDirFrom(env, &dir_buf) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, cache_filename }) catch null;
}

pub fn cachePath(environ: std.process.Environ, buf: []u8) ?[]const u8 {
    return cachePathFrom(liveEnv(environ), buf);
}

/// Realistic failure: `error.NoSpaceLeft` when `buf` is undersized.
pub fn encodeState(buf: []u8, state: State) ![]u8 {
    var w = std.Io.Writer.fixed(buf);
    try w.writeAll("{\"checked_at\":");
    var num_buf: [32]u8 = undefined;
    const num = try std.fmt.bufPrint(&num_buf, "{d}", .{state.checked_at});
    try w.writeAll(num);
    try w.writeAll(",\"latest_tag\":");
    try output.jsonStr(&w, state.latest_tag);
    try w.writeAll(",\"current_seen\":");
    try output.jsonStr(&w, state.current_seen);
    try w.writeAll(",\"last_attempt\":");
    const att = try std.fmt.bufPrint(&num_buf, "{d}", .{state.last_attempt});
    try w.writeAll(att);
    try w.writeAll("}\n");
    return w.buffered();
}

/// Caller frees via `freeState`. OOM propagates; every other parse
/// error collapses to `error.InvalidPayload` so a torn cache doesn't
/// leak a JSON parser type into best-effort callers.
pub fn decodeState(allocator: std.mem.Allocator, bytes: []const u8) !?State {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPayload,
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const checked_at_v = obj.get("checked_at") orelse return null;
    const latest_tag_v = obj.get("latest_tag") orelse return null;
    const current_seen_v = obj.get("current_seen") orelse return null;
    const checked_at_i = switch (checked_at_v) {
        .integer => |i| i,
        else => return null,
    };
    const latest_tag_s = switch (latest_tag_v) {
        .string => |s| s,
        else => return null,
    };
    const current_seen_s = switch (current_seen_v) {
        .string => |s| s,
        else => return null,
    };
    const tag_dup = try allocator.dupe(u8, latest_tag_s);
    errdefer allocator.free(tag_dup);
    const seen_dup = try allocator.dupe(u8, current_seen_s);
    // Optional, default 0 so caches written by older malt still decode.
    const last_attempt_i: i64 = if (obj.get("last_attempt")) |v| switch (v) {
        .integer => |i| i,
        else => 0,
    } else 0;
    return .{
        .checked_at = checked_at_i,
        .latest_tag = tag_dup,
        .current_seen = seen_dup,
        .last_attempt = last_attempt_i,
    };
}

pub fn freeState(allocator: std.mem.Allocator, state: State) void {
    allocator.free(state.latest_tag);
    allocator.free(state.current_seen);
}

/// Install `new_value` first, then free the prior — single statement so a
/// caller's `defer if (state) |s| freeState(...)` can never observe a freed
/// pair, even if a future edit slips a fallible call in between.
pub fn replaceState(state: *?State, allocator: std.mem.Allocator, new_value: State) void {
    const prior = state.*;
    state.* = new_value;
    if (prior) |p| freeState(allocator, p);
}

/// Returns null when the file is absent (a torn or first run).
pub fn readCache(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?State {
    const bytes = read.readFileAllAbsolute(io, allocator, path, 64 * 1024) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer allocator.free(bytes);
    return decodeState(allocator, bytes);
}

/// Creates the parent directory if missing. Routed through
/// `atomicWriteFile` so a SIGKILL or concurrent writer can never publish
/// a torn JSON — readers see either the old cache or the new one.
pub fn writeCache(io: std.Io, path: []const u8, state: State) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    }
    var buf: [1024]u8 = undefined;
    const encoded = try encodeState(&buf, state);
    try atomic.atomicWriteFile(io, path, encoded);
}

// --- inline tests --------------------------------------------------------

test "cacheDirFrom: precedence is MALT_CACHE > XDG_CACHE_HOME > HOME" {
    var buf: [256]u8 = undefined;
    {
        const got = cacheDirFrom(.{
            .malt_cache = "/m",
            .xdg_cache_home = "/x",
            .home = "/h",
        }, &buf) orelse return error.TestExpectedNonNull;
        try std.testing.expectEqualStrings("/m", got);
    }
    {
        const got = cacheDirFrom(.{
            .xdg_cache_home = "/x",
            .home = "/h",
        }, &buf) orelse return error.TestExpectedNonNull;
        try std.testing.expectEqualStrings("/x/malt", got);
    }
    {
        const got = cacheDirFrom(.{ .home = "/h" }, &buf) orelse return error.TestExpectedNonNull;
        try std.testing.expectEqualStrings("/h/.cache/malt", got);
    }
    try std.testing.expect(cacheDirFrom(.{}, &buf) == null);
}

test "cacheDirFrom: empty values fall through to the next candidate" {
    var buf: [256]u8 = undefined;
    const got = cacheDirFrom(.{
        .malt_cache = "",
        .xdg_cache_home = "",
        .home = "/home/u",
    }, &buf) orelse return error.TestExpectedNonNull;
    try std.testing.expectEqualStrings("/home/u/.cache/malt", got);
}

test "encodeState: byte-for-byte JSON format is pinned" {
    // Format compat: a downgrade-then-upgrade round-trip must read the
    // same bytes a newer malt writes. The on-disk shape is part of the
    // contract; any change here is a deliberate format break.
    var buf: [256]u8 = undefined;
    const encoded = try encodeState(&buf, .{
        .checked_at = 42,
        .latest_tag = "v0.10.1",
        .current_seen = "0.10.0",
        .last_attempt = 99,
    });
    const want = "{\"checked_at\":42,\"latest_tag\":\"v0.10.1\",\"current_seen\":\"0.10.0\",\"last_attempt\":99}\n";
    try std.testing.expectEqualStrings(want, encoded);
}

test "encodeState/decodeState: round-trip preserves every field" {
    const allocator = std.testing.allocator;
    var buf: [1024]u8 = undefined;
    const encoded = try encodeState(&buf, .{
        .checked_at = 1714400000,
        .latest_tag = "v0.10.1",
        .current_seen = "0.10.0",
    });

    const got = (try decodeState(allocator, encoded)) orelse return error.TestExpectedNonNull;
    defer freeState(allocator, got);

    try std.testing.expectEqual(@as(i64, 1714400000), got.checked_at);
    try std.testing.expectEqualStrings("v0.10.1", got.latest_tag);
    try std.testing.expectEqualStrings("0.10.0", got.current_seen);
}

test "decodeState: malformed JSON yields error.InvalidPayload" {
    try std.testing.expectError(error.InvalidPayload, decodeState(std.testing.allocator, "not json"));
}

test "decodeState: missing fields yield null (not an error)" {
    const got = try decodeState(std.testing.allocator, "{\"checked_at\":1}");
    try std.testing.expect(got == null);
}

test "decodeState: extra fields are ignored (forwards-compat)" {
    const allocator = std.testing.allocator;
    const json =
        \\{"checked_at":1,"latest_tag":"v0.10.1","current_seen":"0.10.0","future_field":42}
    ;
    const got = (try decodeState(allocator, json)) orelse return error.TestExpectedNonNull;
    defer freeState(allocator, got);
    try std.testing.expectEqualStrings("v0.10.1", got.latest_tag);
}

test "encodeState: escapes JSON special characters in tag/version strings" {
    var buf: [256]u8 = undefined;
    const encoded = try encodeState(&buf, .{
        .checked_at = 0,
        .latest_tag = "v\"X",
        .current_seen = "ok",
    });
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\\\"") != null);
}

test "writeCache + readCache round-trip on a real file" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/malt_notifier_rt_{d}", .{std.Io.Clock.real.now(io).toNanoseconds()});
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/version-notify.json", .{dir});

    try writeCache(io, path, .{
        .checked_at = 1714400000,
        .latest_tag = "v0.10.1",
        .current_seen = "0.10.0",
    });
    const got = (try readCache(io, allocator, path)) orelse return error.TestExpectedNonNull;
    defer freeState(allocator, got);

    try std.testing.expectEqual(@as(i64, 1714400000), got.checked_at);
    try std.testing.expectEqualStrings("v0.10.1", got.latest_tag);
    try std.testing.expectEqualStrings("0.10.0", got.current_seen);
}

test "writeCache replaces an existing cache atomically (rename, not in-place truncate)" {
    // A torn write reaches disk only when the writer truncates `path` and
    // streams into it. Rename-publish gives the destination a fresh inode,
    // so a stable inode after overwrite is the visible truncate signature.
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/malt_notifier_atomic_{d}", .{std.Io.Clock.real.now(io).toNanoseconds()});
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/version-notify.json", .{dir});

    try writeCache(io, path, .{
        .checked_at = 1714400000,
        .latest_tag = "v0.10.1",
        .current_seen = "0.10.0",
    });
    const before = blk: {
        const f = try std.Io.Dir.openFileAbsolute(io, path, .{});
        defer f.close(io);
        break :blk try f.stat(io);
    };

    try writeCache(io, path, .{
        .checked_at = 1714500000,
        .latest_tag = "v0.10.2",
        .current_seen = "0.10.0",
    });
    const after = blk: {
        const f = try std.Io.Dir.openFileAbsolute(io, path, .{});
        defer f.close(io);
        break :blk try f.stat(io);
    };

    try std.testing.expect(before.inode != after.inode);

    // No stale `.tmp` siblings — the rename must publish the new file.
    var d = try std.Io.Dir.openDirAbsolute(io, dir, .{ .iterate = true });
    defer d.close(io);
    var iter = d.iterate();
    var count: usize = 0;
    while (try iter.next(io)) |entry| {
        try std.testing.expectEqualStrings("version-notify.json", entry.name);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "replaceState: prior null installs new without freeing" {
    const allocator = std.testing.allocator;
    var state: ?State = null;
    const new_state: State = .{
        .checked_at = 1,
        .latest_tag = try allocator.dupe(u8, "v0.10.1"),
        .current_seen = try allocator.dupe(u8, "0.10.0"),
    };
    replaceState(&state, allocator, new_state);
    defer if (state) |s| freeState(allocator, s);
    try std.testing.expect(state != null);
    try std.testing.expectEqualStrings("v0.10.1", state.?.latest_tag);
}

test "replaceState: prior non-null is freed; caller's deferred free of new is single-owner" {
    const allocator = std.testing.allocator;
    var state: ?State = .{
        .checked_at = 0,
        .latest_tag = try allocator.dupe(u8, "v0.9.0"),
        .current_seen = try allocator.dupe(u8, "0.8.0"),
    };
    const new_state: State = .{
        .checked_at = 1,
        .latest_tag = try allocator.dupe(u8, "v0.10.0"),
        .current_seen = try allocator.dupe(u8, "0.9.0"),
    };
    replaceState(&state, allocator, new_state);
    // Mirrors the orchestrator's scope-exit pattern; testing.allocator catches
    // a double-free of the prior pair or a leak of the prior pair.
    defer if (state) |s| freeState(allocator, s);
    try std.testing.expectEqual(@as(i64, 1), state.?.checked_at);
    try std.testing.expectEqualStrings("v0.10.0", state.?.latest_tag);
}

test "readCache: missing file is null, not an error" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/tmp/malt_notifier_absent_{d}.json", .{std.Io.Clock.real.now(io).toNanoseconds()});
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    const got = try readCache(io, std.testing.allocator, path);
    try std.testing.expect(got == null);
}
