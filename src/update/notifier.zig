//! malt — passive version-notify (npm/pnpm/gh-cli style).
//!
//! Best-effort by contract: every error path swallows so the notifier
//! can never break a real command. Suppressed under CI, `--quiet`,
//! `--json`, ndjson, `--dry-run`, non-TTY stderr, homebrew origin, and
//! the `version`/`help` meta-commands.

const std = @import("std");

const AppCtx = @import("../app_ctx.zig").AppCtx;
const signals = @import("../core/signals.zig");
const client_mod = @import("../net/client.zig");
const color = @import("../ui/color.zig");
const output = @import("../ui/output.zig");
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

/// Bounded so a cache miss can't drag the user's hot path. Fires after
/// dispatch, so the command's output is already on screen.
pub const network_timeout_ns: u64 = 1_500 * std.time.ns_per_ms;

fn fetchLatestTag(ctx: *const AppCtx, allocator: std.mem.Allocator) ![]u8 {
    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, allocator);
    http.timeout_ns = network_timeout_ns;
    // SIGINT on the prompt-after-success window collapses the probe
    // instead of stalling the user behind the 1.5 s deadline.
    http.cancel = signals.isInterrupted;
    http.offline = ctx.offline;
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
fn suppressed(io: std.Io, environ: std.process.Environ, cmd_str: []const u8) bool {
    if (policy.isSkippedCommand(cmd_str)) return true;
    if (output.isQuiet() or output.isJson() or output.isNdjson() or output.isDryRun()) return true;
    if (policy.notifierDisabled(environ)) return true;
    if (policy.isCi(environ)) return true;
    const stderr_file: std.Io.File = .{ .handle = std.posix.STDERR_FILENO, .flags = .{ .nonblocking = false } };
    if (!(stderr_file.isTty(io) catch false)) return true;
    return false;
}

/// Headline keeps the violet `notice` palette so an available update reads
/// as a heads-up, not a warning; the action hint stays dim — reference
/// material, not the message. Rendered inline (rather than via
/// `output.notice`/`output.dim`) so the layout can sit flush-left under a
/// blank-line separator, which reads better at the tail of any subcommand.
fn printNotice(latest_tag: []const u8, current_version: []const u8) void {
    const latest_no_v = release.stripVPrefix(latest_tag);

    var notice_buf: [4096]u8 = undefined;
    const notice_msg = std.fmt.bufPrint(
        &notice_buf,
        "A newer malt is available: {s} (you're on {s}).",
        .{ latest_no_v, current_version },
    ) catch return;
    const dim_msg = "Run 'mt version update' to upgrade, or set MALT_NO_VERSION_NOTIFIER=1 to silence this.";

    const colorize = color.isColorEnabled();
    const emoji = color.isEmojiEnabled();
    const notice_prefix: []const u8 = if (emoji) "ⓘ " else "i ";
    const dim_prefix: []const u8 = if (emoji) "▸ " else "> ";

    // Blank line separates the heads-up from whatever the subcommand
    // printed last. Safe: notifier fires post-dispatch, no other worker
    // is writing concurrently here.
    output.writeStderrAll("\n");

    if (colorize) {
        output.writeStderrAll(color.SemanticStyle.notice.code());
        output.writeStderrAll(notice_prefix);
        output.writeStderrAll(color.Style.reset.code());
    } else {
        output.writeStderrAll(notice_prefix);
    }
    output.writeStderrAll(notice_msg);
    output.writeStderrAll("\n");

    if (colorize) {
        output.writeStderrAll(color.SemanticStyle.detail.code());
        output.writeStderrAll(dim_prefix);
        output.writeStderrAll(dim_msg);
        output.writeStderrAll(color.Style.reset.code());
    } else {
        output.writeStderrAll(dim_prefix);
        output.writeStderrAll(dim_msg);
    }
    output.writeStderrAll("\n");
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
    if (!need_refresh and !wants_print) return;

    // Brew installs are owned by `brew upgrade --cask malt`; refresh and
    // print both make no sense for them. Origin check is a 2-syscall
    // executablePath + realpath, paid only on this rare-action path.
    if (originIsHomebrew(ctx.io)) return;

    if (need_refresh) {
        // Don't make the user wait out a 1.5s HTTP timeout after Ctrl-C.
        // Same convention as `cli/install.zig` and `cli/migrate.zig`.
        if (signals.isInterrupted()) return;
        refreshOnce(ctx, allocator, path, &state, now, current_version) catch {};
    }

    const s = state orelse return;
    if (!shouldNotify(current_version, s.latest_tag, s.current_seen)) return;
    printNotice(s.latest_tag, current_version);
}

/// On network failure `state` is left untouched so the caller's old
/// cache view survives a flaky GitHub API. The failure path persists a
/// `last_attempt` marker so the next invocation skips the probe until
/// `failure_backoff_secs` has elapsed.
fn refreshOnce(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    path: []const u8,
    state: *?State,
    now: i64,
    current_version: []const u8,
) !void {
    const tag = fetchLatestTag(ctx, allocator) catch |err| {
        writeFailureMarker(ctx.io, path, state.*, now, current_version);
        return err;
    };
    errdefer allocator.free(tag);

    // Preserve a previously-recorded `current_seen` if any; else start at
    // the running version so the suppression clause works.
    const prior_seen: []const u8 = if (state.*) |s| s.current_seen else current_version;
    const seen_dup = try allocator.dupe(u8, prior_seen);
    errdefer allocator.free(seen_dup);

    writeCache(ctx.io, path, .{
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

// Pins the heads-up layout: blank-line separator + flush-left prefixes
// in both palettes. The blank line keeps the notice from sticking to a
// subcommand's last line of output; the flush margin keeps the glyphs
// aligned with the user's prompt regardless of which subcommand ran.
test "printNotice: blank-line + flush-left layout, color + emoji on (dark + basic)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    color.setForTest(true, true);
    color.setBackgroundForTest(color.Background.dark);
    color.setTruecolorForTest(false);
    output.beginStderrCapture(std.testing.allocator, &buf);
    defer {
        output.endStderrCapture();
        color.setForTest(null, null);
        color.setBackgroundForTest(null);
        color.setTruecolorForTest(null);
    }

    printNotice("v0.11.6", "0.11.0");

    const want = "\n" ++
        "\x1b[35mⓘ \x1b[0mA newer malt is available: 0.11.6 (you're on 0.11.0).\n" ++
        "\x1b[2m▸ Run 'mt version update' to upgrade, or set MALT_NO_VERSION_NOTIFIER=1 to silence this.\x1b[0m\n";
    try std.testing.expectEqualStrings(want, buf.items);
}

test "printNotice: no color, no emoji → flush-left ASCII layout" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    color.setForTest(false, false);
    output.beginStderrCapture(std.testing.allocator, &buf);
    defer {
        output.endStderrCapture();
        color.setForTest(null, null);
    }

    printNotice("v0.11.6", "0.11.0");

    const want = "\n" ++
        "i A newer malt is available: 0.11.6 (you're on 0.11.0).\n" ++
        "> Run 'mt version update' to upgrade, or set MALT_NO_VERSION_NOTIFIER=1 to silence this.\n";
    try std.testing.expectEqualStrings(want, buf.items);
}

// Submodules carry their own inline tests; pulling them in here keeps the
// `lib_tests` total honest after a split — `refAllDecls` doesn't recurse
// through private `@import`s.
test {
    _ = @import("notifier/policy.zig");
    _ = @import("notifier/cache.zig");
}
