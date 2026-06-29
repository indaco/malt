//! Pure notifier policy — the decision side of the version-notify
//! contract. No IO, no allocator, no filesystem. The orchestrator
//! composes these predicates with cache state + IO suppression rules.

const std = @import("std");

const release = @import("../release.zig");

/// Match gh, npm, pnpm — smaller TTLs nag, larger lose freshness.
pub const cache_ttl_secs: i64 = 24 * 60 * 60;

/// Cooldown after a failed probe so a GitHub outage does not re-fire the
/// 1.5 s timeout on every malt invocation. Short enough that a recovered
/// network is picked up the next time the user runs anything.
pub const failure_backoff_secs: i64 = 5 * 60;

/// Refresh window once the cache already shows the user is behind. Shorter
/// than the full TTL so a faster point release is re-fetched promptly
/// instead of waiting out the 24 h — up-to-date users keep `cache_ttl_secs`
/// and pay no extra probes.
pub const behind_refresh_secs: i64 = 60 * 60;

/// Pick the cache freshness window from whether a notice is already due:
/// the shorter behind-window when the cache says the user is behind, the
/// full TTL otherwise.
pub fn refreshTtl(wants_notice: bool) i64 {
    return if (wants_notice) behind_refresh_secs else cache_ttl_secs;
}

/// The `current == seen == latest_no_v` clause silences the notice for
/// users who've just updated while the cache TTL is still alive.
pub fn shouldNotify(current: []const u8, latest_tag: []const u8, current_seen: []const u8) bool {
    const latest_no_v = release.stripVPrefix(latest_tag);
    if (latest_no_v.len == 0) return false;
    if (std.mem.eql(u8, current, current_seen) and std.mem.eql(u8, current_seen, latest_no_v)) return false;
    // Fire only when the released version is semantically newer — an equal
    // or behind `latest` (e.g. an ahead-of-release dev build) must not nag.
    return release.order(latest_no_v, current) == .gt;
}

pub fn cacheStale(now_secs: i64, checked_at: i64, ttl: i64) bool {
    // Cache from the future (clock skew) — treat as fresh, never re-fetch.
    if (now_secs <= checked_at) return false;
    return (now_secs - checked_at) >= ttl;
}

/// True when the previous probe failed recently and the caller should
/// skip the network. `last_attempt > checked_at` is the failure shape:
/// success bumps both fields together so they stay equal.
pub fn inFailureBackoff(now_secs: i64, last_attempt: i64, checked_at: i64, backoff: i64) bool {
    if (last_attempt <= checked_at) return false;
    if (now_secs <= last_attempt) return false; // clock skew
    return (now_secs - last_attempt) < backoff;
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

/// Install-pipeline commands deliberately aren't here — `bench.sh`
/// redirects stderr, so the non-TTY rule in the orchestrator already
/// exempts them from measurement while interactive users still get
/// the notice.
const meta_commands = [_][]const u8{ "version", "--version", "help", "--help", "-h" };

/// Public so `tests/version_notify_test.zig` can pin the skip list
/// without going through the full suppression flow.
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

pub fn notifierDisabled(environ: std.process.Environ) bool {
    return notifierDisabledFromValue(std.process.Environ.getPosix(environ, "MALT_NO_VERSION_NOTIFIER"));
}

// --- inline tests --------------------------------------------------------

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

test "shouldNotify: latest behind current never fires (no downgrade nag)" {
    try std.testing.expect(!shouldNotify("0.20.0", "v0.0.1", ""));
    try std.testing.expect(!shouldNotify("0.10.0", "v0.9.0", "0.10.0"));
}

test "shouldNotify: a pre-release build ahead of latest stays quiet" {
    // Running 0.20.0-dev while the published latest is v0.19.3 — you're ahead.
    try std.testing.expect(!shouldNotify("0.20.0-dev", "v0.19.3", ""));
}

test "refreshTtl: behind shortens the window; up-to-date keeps the full TTL" {
    try std.testing.expectEqual(cache_ttl_secs, refreshTtl(false));
    try std.testing.expectEqual(behind_refresh_secs, refreshTtl(true));
    // The whole point of the fix: the behind window must actually be shorter,
    // or a faster point release would still wait out the full TTL.
    try std.testing.expect(behind_refresh_secs < cache_ttl_secs);
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

test "inFailureBackoff: only fires when last_attempt > checked_at" {
    // Equal pair = success shape; never a backoff.
    try std.testing.expect(!inFailureBackoff(1000, 500, 500, 60));
    // last_attempt newer than checked_at + within window → back off.
    try std.testing.expect(inFailureBackoff(550, 500, 100, 60));
    // Window elapsed → no longer backing off.
    try std.testing.expect(!inFailureBackoff(600, 500, 100, 60));
    // Clock skew (now < last_attempt) — never back off, never crash.
    try std.testing.expect(!inFailureBackoff(400, 500, 100, 60));
}

test "isSkippedCommand: meta-command list" {
    try std.testing.expect(isSkippedCommand(""));
    try std.testing.expect(isSkippedCommand("version"));
    try std.testing.expect(isSkippedCommand("--version"));
    try std.testing.expect(isSkippedCommand("help"));
    try std.testing.expect(isSkippedCommand("--help"));
    try std.testing.expect(isSkippedCommand("-h"));
    try std.testing.expect(!isSkippedCommand("install"));
    try std.testing.expect(!isSkippedCommand("upgrade"));
    try std.testing.expect(!isSkippedCommand("list"));
}
