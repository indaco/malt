//! malt — passive version-notify (npm/pnpm/gh-cli style).
//!
//! Best-effort by contract: every error path swallows so the notifier
//! can never break a real command. Suppressed under CI, `--quiet`,
//! `--json`, ndjson, `--dry-run`, non-TTY stderr, homebrew origin, and
//! the `version`/`help` meta-commands.

const std = @import("std");
const output = @import("../ui/output.zig");
const client_mod = @import("../net/client.zig");
const release = @import("release.zig");
const origin_mod = @import("origin.zig");
const AppCtx = @import("../app_ctx.zig").AppCtx;

const cache_filename = "version-notify.json";

/// Match gh, npm, pnpm — smaller TTLs nag, larger lose freshness.
pub const cache_ttl_secs: i64 = 24 * 60 * 60;

/// Bounded so a cache miss can't drag the user's hot path. Fires after
/// dispatch, so the command's output is already on screen.
pub const network_timeout_ns: u64 = 1_500 * std.time.ns_per_ms;

/// Persisted as `<cache_dir>/version-notify.json`. Decoder is tolerant
/// so a downgraded malt doesn't strand the file.
pub const State = struct {
    checked_at: i64,
    /// As returned by GitHub: with the leading `v`.
    latest_tag: []const u8,
    /// Lets a fresh cache skip notices for users who've just updated.
    current_seen: []const u8,
};

/// The `current == seen == latest_no_v` clause silences the notice for
/// users who've just updated while the cache TTL is still alive.
pub fn shouldNotify(current: []const u8, latest_tag: []const u8, current_seen: []const u8) bool {
    const latest_no_v = release.stripVPrefix(latest_tag);
    if (latest_no_v.len == 0) return false;
    if (std.mem.eql(u8, current, latest_no_v)) return false;
    if (std.mem.eql(u8, current, current_seen) and std.mem.eql(u8, current_seen, latest_no_v)) return false;
    return true;
}

pub fn cacheStale(now_secs: i64, checked_at: i64, ttl: i64) bool {
    // Cache from the future (clock skew) — treat as fresh, never re-fetch.
    if (now_secs <= checked_at) return false;
    return (now_secs - checked_at) >= ttl;
}

const ci_env_vars = [_][]const u8{
    "CI",
    "GITHUB_ACTIONS",
    "BUILDKITE",
    "JENKINS_URL",
    "TF_BUILD",
    "CIRCLECI",
    "GITLAB_CI",
};

/// Pure variant of `isCi` so tests don't mutate the host environment.
/// `values` parallels `ci_env_vars` entry-for-entry.
pub fn isCiFromValues(values: []const ?[]const u8) bool {
    std.debug.assert(values.len == ci_env_vars.len);
    for (values) |v| {
        if (v) |s| {
            if (s.len > 0) return true;
        }
    }
    return false;
}

pub fn isCi(environ: std.process.Environ) bool {
    inline for (ci_env_vars) |name| {
        if (std.process.Environ.getPosix(environ, name)) |v| {
            if (v.len > 0) return true;
        }
    }
    return false;
}

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
    return .{ .checked_at = checked_at_i, .latest_tag = tag_dup, .current_seen = seen_dup };
}

pub fn freeState(allocator: std.mem.Allocator, state: State) void {
    allocator.free(state.latest_tag);
    allocator.free(state.current_seen);
}

/// Returns null when the file is absent (a torn or first run).
pub fn readCache(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?State {
    const bytes = readFileAllAbsolute(io, allocator, path, 64 * 1024) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer allocator.free(bytes);
    return decodeState(allocator, bytes);
}

/// Creates the parent directory if missing. A torn write surfaces as
/// `error.InvalidPayload` on the next read and is treated as no cache.
pub fn writeCache(io: std.Io, path: []const u8, state: State) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    }
    var buf: [1024]u8 = undefined;
    const encoded = try encodeState(&buf, state);
    const f = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, encoded);
}

fn fetchLatestTag(ctx: *const AppCtx, allocator: std.mem.Allocator) ![]u8 {
    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, allocator);
    http.timeout_ns = network_timeout_ns;
    defer http.deinit();
    var resp = try http.get(release.releases_latest_url);
    defer resp.deinit();
    if (resp.status != 200) return error.NetworkUnavailable;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{}) catch return error.InvalidPayload;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidPayload,
    };
    const tag = release.strField(obj, "tag_name") orelse return error.InvalidPayload;
    return allocator.dupe(u8, tag);
}

/// Errors degrade to `false` — a transient FS error must not silence
/// the notifier for everyone.
fn originIsHomebrew(io: std.Io) bool {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.executablePath(io, &exe_buf) catch return false;
    var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
    return origin_mod.classifyResolved(io, &resolved_buf, exe_buf[0..n]) == .homebrew;
}

/// Install-pipeline commands deliberately aren't here — `bench.sh`
/// redirects stderr, so the non-TTY rule below already exempts them
/// from measurement while interactive users still get the notice.
const meta_commands = [_][]const u8{ "version", "--version", "help", "--help", "-h" };

/// Public so `tests/version_notify_test.zig` can pin the skip list
/// without going through the full `suppressed` flow.
pub fn isSkippedCommand(cmd: []const u8) bool {
    if (cmd.len == 0) return true;
    for (meta_commands) |m| {
        if (std.mem.eql(u8, cmd, m)) return true;
    }
    return false;
}

/// Mirrors `MALT_ALLOW_UNVERIFIED` / `MALT_ALLOW_RAW_POST_INSTALL`:
/// the literal `"1"` is the on-state, anything else (incl. an empty
/// value) is off, so a stray `=` doesn't accidentally silence notices.
pub fn notifierDisabledFromValue(value: ?[]const u8) bool {
    const v = value orelse return false;
    return std.mem.eql(u8, v, "1");
}

fn notifierDisabled(environ: std.process.Environ) bool {
    return notifierDisabledFromValue(std.process.Environ.getPosix(environ, "MALT_NO_VERSION_NOTIFIER"));
}

/// Cheapest checks first. `originIsHomebrew` is deliberately not here —
/// the `executablePath` + `realpath` pair is deferred to `runNotify` so
/// the cache-fresh hot path skips it entirely.
fn suppressed(io: std.Io, environ: std.process.Environ, cmd_str: []const u8) bool {
    if (isSkippedCommand(cmd_str)) return true;
    if (output.isQuiet() or output.isJson() or output.isNdjson() or output.isDryRun()) return true;
    if (notifierDisabled(environ)) return true;
    if (isCi(environ)) return true;
    const stderr_file: std.Io.File = .{ .handle = std.posix.STDERR_FILENO, .flags = .{ .nonblocking = false } };
    if (!(stderr_file.isTty(io) catch false)) return true;
    return false;
}

/// Dim so it recedes next to the command's own info/success lines.
fn printNotice(latest_tag: []const u8, current_version: []const u8) void {
    const latest_no_v = release.stripVPrefix(latest_tag);
    output.dim("A newer malt is available: {s} (you're on {s}).", .{ latest_no_v, current_version });
    output.dim("Run 'mt version update' to upgrade, or set MALT_NO_VERSION_NOTIFIER=1 to silence this.", .{});
}

/// Best-effort cache write so a successful self-update silences the
/// nag immediately, not on the next 24h refresh.
pub fn markUpdatedTo(ctx: *const AppCtx, latest_tag: []const u8, current_version: []const u8) void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = cachePath(ctx.environ, &path_buf) orelse return;
    writeCache(ctx.io, path, .{
        .checked_at = std.Io.Clock.real.now(ctx.io).toSeconds(),
        .latest_tag = latest_tag,
        .current_seen = current_version,
    }) catch {};
}

/// Best-effort entrypoint. `cmd_str` is the canonical subcommand name;
/// `version`/`help` aliases bypass the notice via the suppression list.
pub fn maybeNotify(ctx: *const AppCtx, allocator: std.mem.Allocator, current_version: []const u8, cmd_str: []const u8) void {
    if (suppressed(ctx.io, ctx.environ, cmd_str)) return;
    runNotify(ctx, allocator, current_version) catch {};
}

fn runNotify(ctx: *const AppCtx, allocator: std.mem.Allocator, current_version: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = cachePath(ctx.environ, &path_buf) orelse return;

    var state: ?State = readCache(ctx.io, allocator, path) catch null;
    defer if (state) |s| freeState(allocator, s);

    const now = std.Io.Clock.real.now(ctx.io).toSeconds();
    const need_refresh = if (state) |s| cacheStale(now, s.checked_at, cache_ttl_secs) else true;

    // The 33%-savings clause: cache fresh + no notice due → return without
    // touching `executablePath`/`realpath`. The dominant path on a healthy
    // workstation between refresh windows.
    const wants_print = blk: {
        const s = state orelse break :blk false;
        break :blk shouldNotify(current_version, s.latest_tag, s.current_seen);
    };
    if (!need_refresh and !wants_print) return;

    // Brew installs are owned by `brew upgrade --cask malt`; refresh and
    // print both make no sense for them. Origin check is a 2-syscall
    // executablePath + realpath, paid only on this rare-action path.
    if (originIsHomebrew(ctx.io)) return;

    if (need_refresh) {
        // Don't make the user wait out a 1.5s HTTP timeout after Ctrl-C.
        // Same convention as `cli/install.zig` and `cli/migrate.zig`.
        const main_mod = @import("../main.zig");
        if (main_mod.isInterrupted()) return;
        refreshOnce(ctx, allocator, path, &state, now, current_version) catch {};
    }

    const s = state orelse return;
    if (!shouldNotify(current_version, s.latest_tag, s.current_seen)) return;
    printNotice(s.latest_tag, current_version);
}

/// On network failure `state` is left untouched so the caller's old
/// cache view survives a flaky GitHub API.
fn refreshOnce(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    path: []const u8,
    state: *?State,
    now: i64,
    current_version: []const u8,
) !void {
    const tag = try fetchLatestTag(ctx, allocator);
    errdefer allocator.free(tag);

    // Preserve a previously-recorded `current_seen` if any; else start at
    // the running version so the suppression clause works.
    const prior_seen: []const u8 = if (state.*) |s| s.current_seen else current_version;
    const seen_dup = try allocator.dupe(u8, prior_seen);
    errdefer allocator.free(seen_dup);

    writeCache(ctx.io, path, .{ .checked_at = now, .latest_tag = tag, .current_seen = prior_seen }) catch {};

    if (state.*) |old| freeState(allocator, old);
    state.* = .{ .checked_at = now, .latest_tag = tag, .current_seen = seen_dup };
}

/// Read the entire contents of an absolute file path into a caller-owned slice.
fn readFileAllAbsolute(io: std.Io, allocator: std.mem.Allocator, abs_path: []const u8, max_bytes: usize) ![]u8 {
    const f = try std.Io.Dir.openFileAbsolute(io, abs_path, .{});
    defer f.close(io);
    const st = try f.stat(io);
    const size = @min(@as(u64, max_bytes), st.size);
    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);
    const n = try f.readPositionalAll(io, buf, 0);
    if (n == buf.len) return buf;
    if (allocator.resize(buf, n)) return buf[0..n];
    const shrunk = try allocator.alloc(u8, n);
    @memcpy(shrunk, buf[0..n]);
    allocator.free(buf);
    return shrunk;
}

// --- pure-logic tests ----------------------------------------------------

test "shouldNotify: equal versions never notify (with or without leading v)" {
    try std.testing.expect(!shouldNotify("0.10.0", "v0.10.0", "0.10.0"));
    try std.testing.expect(!shouldNotify("0.10.0", "0.10.0", ""));
}

test "shouldNotify: newer latest fires notice" {
    try std.testing.expect(shouldNotify("0.10.0", "v0.10.1", ""));
    try std.testing.expect(shouldNotify("0.10.0", "v0.11.0", "0.9.0"));
}

test "shouldNotify: empty latest never fires" {
    try std.testing.expect(!shouldNotify("0.10.0", "", ""));
    try std.testing.expect(!shouldNotify("0.10.0", "v", ""));
}

test "shouldNotify: post-update suppression — current_seen matches both" {
    // User updated to 0.10.1; cache still says latest=v0.10.1 — don't nag.
    try std.testing.expect(!shouldNotify("0.10.1", "v0.10.1", "0.10.1"));
}

test "shouldNotify: stale cache with mismatched current_seen still fires" {
    // Cache predates a downgrade-then-cache-rewrite; safe default is to fire.
    try std.testing.expect(shouldNotify("0.9.0", "v0.10.0", "0.8.0"));
}

test "cacheStale: TTL boundary" {
    try std.testing.expect(!cacheStale(100, 100, 60)); // equal ⇒ fresh (delta 0)
    try std.testing.expect(!cacheStale(159, 100, 60)); // delta 59 < 60
    try std.testing.expect(cacheStale(160, 100, 60)); // delta 60 ⇒ stale
    try std.testing.expect(cacheStale(1000, 100, 60));
}

test "cacheStale: clock skew (cache from the future) is treated as fresh" {
    try std.testing.expect(!cacheStale(50, 100, 60));
}

test "notifierDisabledFromValue: only literal \"1\" disables (matches MALT_ALLOW_UNVERIFIED)" {
    try std.testing.expect(!notifierDisabledFromValue(null));
    try std.testing.expect(!notifierDisabledFromValue(""));
    try std.testing.expect(!notifierDisabledFromValue("0"));
    try std.testing.expect(!notifierDisabledFromValue("true"));
    try std.testing.expect(!notifierDisabledFromValue("yes"));
    try std.testing.expect(notifierDisabledFromValue("1"));
}

test "isCiFromValues: any non-empty wins" {
    const all_null = [_]?[]const u8{ null, null, null, null, null, null, null };
    try std.testing.expect(!isCiFromValues(&all_null));

    const empty_string_only = [_]?[]const u8{ "", null, null, null, null, null, null };
    try std.testing.expect(!isCiFromValues(&empty_string_only));

    const ci_set = [_]?[]const u8{ "true", null, null, null, null, null, null };
    try std.testing.expect(isCiFromValues(&ci_set));

    const gha_set = [_]?[]const u8{ null, "true", null, null, null, null, null };
    try std.testing.expect(isCiFromValues(&gha_set));
}

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
