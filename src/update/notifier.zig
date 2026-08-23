//! malt — passive version-notify (npm/pnpm/gh-cli style).
//!
//! Best-effort by contract: every error path swallows so the notifier
//! can never break a real command. Suppressed under CI, `--quiet`,
//! `--json`, ndjson, `--dry-run`, non-TTY stderr, homebrew origin, and
//! the `version`/`help` meta-commands.

const std = @import("std");

const signals = @import("../core/signals.zig");
const client_mod = @import("../net/client.zig");
const origin_mod = @import("origin.zig");
const release = @import("release.zig");
const cache = @import("notifier/cache.zig");
const policy = @import("notifier/policy.zig");

pub const cache_ttl_secs = policy.cache_ttl_secs;
pub const failure_backoff_secs = policy.failure_backoff_secs;
pub const behind_refresh_secs = policy.behind_refresh_secs;
pub const refreshTtl = policy.refreshTtl;
pub const shouldNotify = policy.shouldNotify;
pub const cacheStale = policy.cacheStale;
pub const inFailureBackoff = policy.inFailureBackoff;
pub const isCi = policy.isCi;
pub const isCiFromValues = policy.isCiFromValues;
pub const isSkippedCommand = policy.isSkippedCommand;
pub const notifierDisabledFromValue = policy.notifierDisabledFromValue;

pub const State = cache.State;
pub const EnvOverride = cache.EnvOverride;
pub const cacheDirFrom = cache.cacheDirFrom;
pub const cacheDir = cache.cacheDir;
pub const cachePathFrom = cache.cachePathFrom;
pub const cachePath = cache.cachePath;
pub const encodeState = cache.encodeState;
pub const decodeState = cache.decodeState;
pub const freeState = cache.freeState;
pub const readCache = cache.readCache;
pub const writeCache = cache.writeCache;

/// Output modes that suppress the notice. They are CLI-layer process state,
/// so the caller reads them and hands the answer down rather than the leaf
/// reaching back into the UI it must not know about.
pub const Gates = struct {
    quiet: bool = false,
    json: bool = false,
    ndjson: bool = false,
    dry_run: bool = false,

    pub fn anySuppress(self: Gates) bool {
        return self.quiet or self.json or self.ndjson or self.dry_run;
    }
};

/// Bounded so a cache miss can't drag the user's hot path. Fires after
/// dispatch, so the command's output is already on screen.
pub const network_timeout_ns: u64 = 1_500 * std.time.ns_per_ms;

/// Hold every phase of the probe to the bound above. Connect, head read and
/// body each carry their own knob, and the retry schedule sits outside all
/// three - a transient failure otherwise costs four attempts plus seven
/// seconds of backoff, on the hot path of every command.
pub fn applyProbeBudget(http: *client_mod.HttpClient) void {
    http.timeout_ns = network_timeout_ns;
    http.head_timeout_ns = network_timeout_ns;
    http.retry_backoff_ms = &.{};
}

fn fetchLatestTag(io: std.Io, environ: std.process.Environ, offline: bool, allocator: std.mem.Allocator) ![]u8 {
    var http = client_mod.HttpClient.init(io, environ, allocator);
    applyProbeBudget(&http);
    // SIGINT on the prompt-after-success window collapses the probe
    // instead of stalling the user behind the 1.5 s deadline.
    http.cancel = signals.isInterrupted;
    http.offline = offline;
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

/// Cheapest checks first. `originIsHomebrew` is deliberately not here —
/// the `executablePath` + `realpath` pair is deferred to `runNotify` so
/// the cache-fresh hot path skips it entirely.
fn suppressed(io: std.Io, environ: std.process.Environ, cmd_str: []const u8, gates: Gates) bool {
    if (policy.isSkippedCommand(cmd_str)) return true;
    if (gates.anySuppress()) return true;
    if (policy.notifierDisabled(environ)) return true;
    if (policy.isCi(environ)) return true;
    // The assume-TTY seam lets scripted runs exercise the notice without a
    // pty; it bypasses only this gate, not the CI/quiet/json suppressors.
    if (policy.assumeTty(environ)) return false;
    const stderr_file: std.Io.File = .{ .handle = std.posix.STDERR_FILENO, .flags = .{ .nonblocking = false } };
    if (!(stderr_file.isTty(io) catch false)) return true;
    return false;
}

/// Best-effort cache write so a successful self-update silences the
/// nag immediately, not on the next 24h refresh.
pub fn markUpdatedTo(io: std.Io, environ: std.process.Environ, latest_tag: []const u8, current_version: []const u8) void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = cachePath(environ, &path_buf) orelse return;
    writeCache(io, path, .{
        .checked_at = std.Io.Clock.real.now(io).toSeconds(),
        .latest_tag = latest_tag,
        .current_seen = current_version,
    }) catch {};
}

/// Longest tag the notice will carry back. Releases are short semver tags;
/// anything longer is a malformed feed, and dropping the notice is the
/// best-effort answer.
pub const max_tag_len: usize = 64;

/// Best-effort entrypoint: returns the tag to announce, or null when no
/// notice is due. `cmd_str` is the canonical subcommand name; `version`/`help`
/// aliases bypass the notice via the suppression list. The tag is copied into
/// `tag_buf` because the cache state it comes from is freed on the way out.
pub fn pendingNotice(
    io: std.Io,
    environ: std.process.Environ,
    offline: bool,
    allocator: std.mem.Allocator,
    current_version: []const u8,
    cmd_str: []const u8,
    gates: Gates,
    tag_buf: []u8,
) ?[]const u8 {
    if (suppressed(io, environ, cmd_str, gates)) return null;
    return runNotify(io, environ, offline, allocator, current_version, tag_buf) catch null;
}

fn runNotify(
    io: std.Io,
    environ: std.process.Environ,
    offline: bool,
    allocator: std.mem.Allocator,
    current_version: []const u8,
    tag_buf: []u8,
) !?[]const u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = cachePath(environ, &path_buf) orelse return null;

    var state: ?State = readCache(io, allocator, path) catch null;
    defer if (state) |s| freeState(allocator, s);

    const now = std.Io.Clock.real.now(io).toSeconds();

    // Whether the cached view already says the user is behind. Computed
    // first so a behind state can shorten the refresh window below — a
    // faster point release gets re-fetched promptly instead of waiting out
    // the full TTL, while up-to-date users still refresh only every TTL.
    const wants_print = blk: {
        const s = state orelse break :blk false;
        break :blk shouldNotify(current_version, s.latest_tag, s.current_seen);
    };

    const need_refresh = if (state) |s| blk: {
        if (!cacheStale(now, s.checked_at, refreshTtl(wants_print))) break :blk false;
        break :blk !inFailureBackoff(now, s.last_attempt, s.checked_at, failure_backoff_secs);
    } else true;

    // The 33%-savings clause: cache fresh + no notice due → return without
    // touching `executablePath`/`realpath`. The dominant path on a healthy
    // workstation between refresh windows.
    if (!need_refresh and !wants_print) return null;

    // Brew installs are owned by `brew upgrade --cask malt`; refresh and
    // print both make no sense for them. Origin check is a 2-syscall
    // executablePath + realpath, paid only on this rare-action path.
    if (originIsHomebrew(io)) return null;

    if (need_refresh) {
        // Don't make the user wait out a 1.5s HTTP timeout after Ctrl-C.
        // Same convention as `cli/install.zig` and `cli/migrate.zig`.
        if (signals.isInterrupted()) return null;
        refreshOnce(io, environ, offline, allocator, path, &state, now, current_version) catch {};
    }

    const s = state orelse return null;
    if (!shouldNotify(current_version, s.latest_tag, s.current_seen)) return null;
    if (s.latest_tag.len > tag_buf.len) return null;
    @memcpy(tag_buf[0..s.latest_tag.len], s.latest_tag);
    return tag_buf[0..s.latest_tag.len];
}

/// On network failure `state` is left untouched so the caller's old
/// cache view survives a flaky GitHub API. The failure path persists a
/// `last_attempt` marker so the next invocation skips the probe until
/// `failure_backoff_secs` has elapsed.
fn refreshOnce(
    io: std.Io,
    environ: std.process.Environ,
    offline: bool,
    allocator: std.mem.Allocator,
    path: []const u8,
    state: *?State,
    now: i64,
    current_version: []const u8,
) !void {
    const tag = fetchLatestTag(io, environ, offline, allocator) catch |err| {
        writeFailureMarker(io, path, state.*, now, current_version);
        return err;
    };
    errdefer allocator.free(tag);

    // Preserve a previously-recorded `current_seen` if any; else start at
    // the running version so the suppression clause works.
    const prior_seen: []const u8 = if (state.*) |s| s.current_seen else current_version;
    const seen_dup = try allocator.dupe(u8, prior_seen);
    errdefer allocator.free(seen_dup);

    writeCache(io, path, .{
        .checked_at = now,
        .latest_tag = tag,
        .current_seen = prior_seen,
        .last_attempt = now,
    }) catch {};

    cache.replaceState(state, allocator, .{
        .checked_at = now,
        .latest_tag = tag,
        .current_seen = seen_dup,
        .last_attempt = now,
    });
}

/// Persist a failure marker so the next invocation backs off instead of
/// re-probing through a network outage. Best-effort: a write error here
/// just defers to the next probe, which is the same as today.
pub fn writeFailureMarker(io: std.Io, path: []const u8, prior: ?State, now: i64, current_version: []const u8) void {
    const checked_at: i64 = if (prior) |p| p.checked_at else 0;
    const tag: []const u8 = if (prior) |p| p.latest_tag else "";
    const seen: []const u8 = if (prior) |p| p.current_seen else current_version;
    writeCache(io, path, .{
        .checked_at = checked_at,
        .latest_tag = tag,
        .current_seen = seen,
        .last_attempt = now,
    }) catch {};
}

// --- inline tests --------------------------------------------------------

test "applyProbeBudget: every phase of the probe shares the advertised bound" {
    // The connect, the head read and the body each have their own knob, and
    // any one left at the 30 s default makes the bound above a claim the
    // probe cannot keep.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var http = client_mod.HttpClient.init(threaded.io(), std.process.Environ.empty, std.testing.allocator);
    defer http.deinit();

    applyProbeBudget(&http);

    try std.testing.expectEqual(network_timeout_ns, http.timeout_ns);
    try std.testing.expectEqual(network_timeout_ns, http.head_timeout_ns);
}

test "applyProbeBudget: the probe does not retry" {
    // The retry schedule is the probe's real worst case: four attempts plus
    // seven seconds of backoff is what held every command through a brownout.
    // A passive notice is not worth a second attempt the user waits through.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var http = client_mod.HttpClient.init(threaded.io(), std.process.Environ.empty, std.testing.allocator);
    defer http.deinit();

    applyProbeBudget(&http);

    try std.testing.expectEqual(@as(usize, 0), http.retry_backoff_ms.len);
}

// Submodules carry their own inline tests; pulling them in here keeps the
// `lib_tests` total honest after a split — `refAllDecls` doesn't recurse
// through private `@import`s.
test {
    _ = @import("notifier/policy.zig");
    _ = @import("notifier/cache.zig");
}
