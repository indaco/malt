//! malt — run command
//! Run a package binary without installing — download to temp, execute, clean up.
//! `--keep` extracts under {cache}/run/<sha256>/ so subsequent runs skip download.

const std = @import("std");
const fs_compat = @import("../fs/compat.zig");
const formula_mod = @import("../core/formula.zig");
const bottle_mod = @import("../core/bottle.zig");
const client_mod = @import("../net/client.zig");
const ghcr_mod = @import("../net/ghcr.zig");
const api_mod = @import("../net/api.zig");
const atomic = @import("../fs/atomic.zig");
const lock_mod = @import("../db/lock.zig");
const output = @import("../ui/output.zig");
const help = @import("help.zig");

/// Cap on how long a peer holding `{cache}/run/<sha>.lock` can keep us
/// waiting before we surface the contention as a hard error. Tunable
/// via `MALT_RUN_KEEP_LOCK_TIMEOUT_MS` so CI / slow-link users can raise it.
const default_keep_lock_timeout_ms: u32 = 300_000;

fn keepLockTimeoutMs() u32 {
    if (fs_compat.getenv("MALT_RUN_KEEP_LOCK_TIMEOUT_MS")) |v| {
        return std.fmt.parseInt(u32, std.mem.sliceTo(v, 0), 10) catch default_keep_lock_timeout_ms;
    }
    return default_keep_lock_timeout_ms;
}

/// Release-and-clear: scattered call sites would otherwise drift on the
/// release/null pairing and silently leak the lock fd into exec.
fn releaseKeepLock(slot: *?lock_mod.LockFile) void {
    if (slot.*) |*lk| lk.release();
    slot.* = null;
}

pub const ParsedArgs = struct {
    pkg_name: []const u8,
    keep: bool,
    cmd_args: []const []const u8,
};

/// Parse `mt run` argv into package name, --keep flag, and command args after `--`.
/// Accepts `--keep` in any position before the `--` separator. Returns null when
/// no package name is present so callers can surface usage.
pub fn parseArgs(args: []const []const u8) ?ParsedArgs {
    var keep = false;
    var pkg_name: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            const cmd_args = if (i + 1 < args.len) args[i + 1 ..] else &[_][]const u8{};
            if (pkg_name) |name| return .{ .pkg_name = name, .keep = keep, .cmd_args = cmd_args };
            return null;
        }
        if (std.mem.eql(u8, arg, "--keep")) {
            keep = true;
            continue;
        }
        if (pkg_name == null) pkg_name = arg;
    }
    if (pkg_name) |name| return .{ .pkg_name = name, .keep = keep, .cmd_args = &[_][]const u8{} };
    return null;
}

/// Format `{cache_dir}/run/<sha256>` into `buf`. PathTooLong distinguishes
/// overflow from allocation failure for callers that surface the cause.
pub fn buildKeepCachePath(buf: []u8, cache_dir: []const u8, sha256: []const u8) error{PathTooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/run/{s}", .{ cache_dir, sha256 }) catch error.PathTooLong;
}

/// Sibling lock file for the cache slot. Lives next to (not inside) the
/// slot so wiping the slot on a re-extract leaves the lock file intact.
pub fn buildKeepLockPath(buf: []u8, cache_dir: []const u8, sha256: []const u8) error{PathTooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/run/{s}.lock", .{ cache_dir, sha256 }) catch error.PathTooLong;
}

/// Probe `{cache_dir}/run/<sha>/<pkg>/<ver>/bin/<pkg>`. Returns the path
/// (borrowed from `buf`) on hit, null on miss.
pub fn findCachedBinary(
    buf: []u8,
    cache_dir: []const u8,
    sha256: []const u8,
    pkg_name: []const u8,
    version: []const u8,
) error{PathTooLong}!?[]const u8 {
    const bin_path = std.fmt.bufPrint(buf, "{s}/run/{s}/{s}/{s}/bin/{s}", .{
        cache_dir, sha256, pkg_name, version, pkg_name,
    }) catch return error.PathTooLong;
    fs_compat.accessAbsolute(bin_path, .{}) catch return null;
    return bin_path;
}

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "run")) return;

    const parsed = parseArgs(args) orelse {
        output.err("Usage: mt run [--keep] <package> [-- <args...>]", .{});
        output.info("Example: mt run jq -- --version", .{});
        return error.Aborted;
    };

    const prefix = atomic.maltPrefix();

    var bin_buf: [512]u8 = undefined;
    const installed_bin = std.fmt.bufPrint(&bin_buf, "{s}/bin/{s}", .{ prefix, parsed.pkg_name }) catch return;
    fs_compat.accessAbsolute(installed_bin, .{}) catch {
        return ephemeralRun(allocator, parsed.pkg_name, parsed.cmd_args, parsed.keep, prefix);
    };

    output.info("Running installed {s}...", .{parsed.pkg_name});
    return try execBinary(allocator, installed_bin, parsed.cmd_args);
}

fn ephemeralRun(
    allocator: std.mem.Allocator,
    pkg_name: []const u8,
    cmd_args: []const []const u8,
    keep: bool,
    prefix: []const u8,
) !void {
    output.info("Fetching {s} for ephemeral run...", .{pkg_name});

    var http = client_mod.HttpClient.init(allocator);
    defer http.deinit();

    var cache_buf: [512]u8 = undefined;
    const cache_dir = std.fmt.bufPrint(&cache_buf, "{s}/cache", .{prefix}) catch return;
    var api = api_mod.BrewApi.init(allocator, &http, cache_dir);

    const formula_json = api.fetchFormula(pkg_name) catch {
        output.err("Formula '{s}' not found", .{pkg_name});
        return error.Aborted;
    };
    defer allocator.free(formula_json);

    var formula = formula_mod.parseFormula(allocator, formula_json) catch {
        output.err("Failed to parse formula for '{s}'", .{pkg_name});
        return error.Aborted;
    };
    defer formula.deinit();

    const bottle = formula_mod.resolveBottle(allocator, &formula) catch {
        output.err("No bottle available for {s} on this platform", .{pkg_name});
        return error.Aborted;
    };

    // Per-slot lock serializes parallel `mt run --keep <pkg>` so two
    // peers don't truncate one another's bottle.tar.gz mid-extract.
    var keep_lock: ?lock_mod.LockFile = null;
    errdefer releaseKeepLock(&keep_lock);

    if (keep) {
        var run_root_buf: [512]u8 = undefined;
        const run_root = std.fmt.bufPrint(&run_root_buf, "{s}/run", .{cache_dir}) catch {
            output.err("Cache root path too long for {s}", .{pkg_name});
            return error.Aborted;
        };
        // Lock file needs the run/ root to exist before open(O_CREAT).
        fs_compat.cwd().makePath(run_root) catch {
            output.err("Failed to create run cache root", .{});
            return error.Aborted;
        };

        var lock_buf: [512]u8 = undefined;
        const lock_path = buildKeepLockPath(&lock_buf, cache_dir, bottle.sha256) catch {
            output.err("Cache lock path too long for {s}", .{pkg_name});
            return error.Aborted;
        };
        keep_lock = lock_mod.LockFile.acquire(lock_path, keepLockTimeoutMs()) catch |e| {
            if (e == error.Timeout) {
                if (lock_mod.LockFile.holderPid(lock_path)) |pid| {
                    output.err("Another `mt run --keep` for {s} is in progress (pid {d})", .{ pkg_name, pid });
                } else {
                    output.err("Another `mt run --keep` for {s} is in progress", .{pkg_name});
                }
            } else {
                output.err("Failed to acquire run cache lock for {s}", .{pkg_name});
            }
            return error.Aborted;
        };

        // Probe under the lock — a peer that just released may have populated the slot.
        var hit_buf: [512]u8 = undefined;
        if (findCachedBinary(&hit_buf, cache_dir, bottle.sha256, pkg_name, formula.version) catch null) |cached_bin| {
            // Drop the lock before exec so peers can run the cached binary unblocked.
            releaseKeepLock(&keep_lock);
            output.info("Running cached {s} {s}...", .{ pkg_name, formula.version });
            return try execBinary(allocator, cached_bin, cmd_args);
        }
    }

    var ghcr = ghcr_mod.GhcrClient.init(allocator, &http);
    defer ghcr.deinit();

    // Cache slot under {cache} so `mt purge --cache` wipes it; a tmp dir otherwise.
    var keep_dest_buf: [512]u8 = undefined;
    var dest_dir: []const u8 = undefined;
    var owned_tmp: ?[]const u8 = null;
    defer if (owned_tmp) |p| {
        atomic.cleanupTempDir(p);
        allocator.free(p);
    };

    if (keep) {
        dest_dir = buildKeepCachePath(&keep_dest_buf, cache_dir, bottle.sha256) catch {
            output.err("Cache path too long for {s}", .{pkg_name});
            return error.Aborted;
        };
        // Wipe stale partial state from a prior aborted run so the
        // tar extractor never trips on pre-existing entries.
        fs_compat.deleteTreeAbsolute(dest_dir) catch {};
        fs_compat.cwd().makePath(dest_dir) catch {
            output.err("Failed to create run cache directory", .{});
            return error.Aborted;
        };
    } else {
        owned_tmp = atomic.createTempDir(allocator, "run") catch {
            output.err("Failed to create temp directory", .{});
            return error.Aborted;
        };
        dest_dir = owned_tmp.?;
    }
    // Half-extracted cache slot is poison for the next --keep run; wipe on failure.
    errdefer if (keep) fs_compat.deleteTreeAbsolute(dest_dir) catch {};

    const ghcr_prefix = "https://ghcr.io/v2/";
    var repo_buf: [256]u8 = undefined;
    var digest_buf: [128]u8 = undefined;
    var repo: []const u8 = undefined;
    var digest: []const u8 = undefined;

    if (std.mem.startsWith(u8, bottle.url, ghcr_prefix)) {
        const path = bottle.url[ghcr_prefix.len..];
        if (std.mem.indexOf(u8, path, "/blobs/")) |blobs_pos| {
            repo = std.fmt.bufPrint(&repo_buf, "{s}", .{path[0..blobs_pos]}) catch return;
            digest = std.fmt.bufPrint(&digest_buf, "{s}", .{path[blobs_pos + "/blobs/".len ..]}) catch return;
        } else return;
    } else return;

    output.info("Downloading {s} {s}...", .{ pkg_name, formula.version });
    _ = bottle_mod.download(allocator, &ghcr, &http, repo, digest, bottle.sha256, dest_dir, null) catch {
        output.err("Failed to download {s}", .{pkg_name});
        return error.Aborted;
    };

    var bin_path_buf: [512]u8 = undefined;
    const bin_path = std.fmt.bufPrint(&bin_path_buf, "{s}/{s}/{s}/bin/{s}", .{
        dest_dir,
        pkg_name,
        formula.version,
        pkg_name,
    }) catch return;

    fs_compat.accessAbsolute(bin_path, .{}) catch {
        output.err("Binary '{s}' not found in bottle", .{pkg_name});
        return error.Aborted;
    };

    {
        const f = fs_compat.openFileAbsolute(bin_path, .{ .mode = .read_write }) catch return;
        defer f.close();
        // Bottles ship with +x; chmod is belt-and-suspenders. exec below surfaces EACCES.
        f.chmod(0o755) catch {};
    }

    // Slot fully populated; let waiting peers in before we hand off to exec.
    if (keep_lock) |*lk| lk.release();
    keep_lock = null;

    if (keep) {
        output.info("Running {s} {s} (cached)...", .{ pkg_name, formula.version });
    } else {
        output.info("Running {s} {s} (ephemeral)...", .{ pkg_name, formula.version });
    }
    const stderr = fs_compat.stderrFile();
    // Separator is purely cosmetic; a closed stderr shouldn't kill the run.
    stderr.writeAll("---\n") catch {};

    try execBinary(allocator, bin_path, cmd_args);
}

fn execBinary(allocator: std.mem.Allocator, path: []const u8, cmd_args: []const []const u8) !void {
    // Build argv: [path] ++ cmd_args
    var argv_buf: [64][]const u8 = undefined;
    argv_buf[0] = path;
    const argc = @min(cmd_args.len, argv_buf.len - 1);
    for (cmd_args[0..argc], 1..) |arg, i| {
        argv_buf[i] = arg;
    }

    var child = fs_compat.Child.init(argv_buf[0 .. argc + 1], allocator);
    child.spawn() catch {
        output.err("Failed to execute binary", .{});
        return error.Aborted;
    };
    // Ephemeral run is fire-and-forget; child exit code isn't surfaced to the shell.
    _ = child.wait() catch {};
}

test "parseArgs splits at double dash" {
    const args = [_][]const u8{ "jq", "--arg", "--", "--version", "-r" };
    const parsed = parseArgs(&args).?;
    try std.testing.expectEqualStrings("jq", parsed.pkg_name);
    try std.testing.expect(!parsed.keep);
    try std.testing.expectEqual(@as(usize, 2), parsed.cmd_args.len);
    try std.testing.expectEqualStrings("--version", parsed.cmd_args[0]);
    try std.testing.expectEqualStrings("-r", parsed.cmd_args[1]);
}

test "parseArgs without double dash has no command args" {
    const args = [_][]const u8{"jq"};
    const parsed = parseArgs(&args).?;
    try std.testing.expectEqualStrings("jq", parsed.pkg_name);
    try std.testing.expect(!parsed.keep);
    try std.testing.expectEqual(@as(usize, 0), parsed.cmd_args.len);
}

test "parseArgs detects --keep before package name" {
    const args = [_][]const u8{ "--keep", "jq", "--", "--version" };
    const parsed = parseArgs(&args).?;
    try std.testing.expectEqualStrings("jq", parsed.pkg_name);
    try std.testing.expect(parsed.keep);
    try std.testing.expectEqual(@as(usize, 1), parsed.cmd_args.len);
    try std.testing.expectEqualStrings("--version", parsed.cmd_args[0]);
}

test "parseArgs detects --keep after package name" {
    const args = [_][]const u8{ "jq", "--keep", "--", "--version" };
    const parsed = parseArgs(&args).?;
    try std.testing.expectEqualStrings("jq", parsed.pkg_name);
    try std.testing.expect(parsed.keep);
    try std.testing.expectEqual(@as(usize, 1), parsed.cmd_args.len);
}

test "parseArgs returns null for empty args" {
    try std.testing.expect(parseArgs(&[_][]const u8{}) == null);
}

test "parseArgs returns null when only --keep is given" {
    try std.testing.expect(parseArgs(&[_][]const u8{"--keep"}) == null);
}

test "buildKeepCachePath joins cache_dir, sha256, and run subpath" {
    var buf: [512]u8 = undefined;
    const path = try buildKeepCachePath(&buf, "/opt/malt/cache", "deadbeef");
    try std.testing.expectEqualStrings("/opt/malt/cache/run/deadbeef", path);
}

test "buildKeepCachePath surfaces PathTooLong on overflow" {
    var buf: [16]u8 = undefined;
    try std.testing.expectError(
        error.PathTooLong,
        buildKeepCachePath(&buf, "/opt/malt/cache", "deadbeef"),
    );
}

test "buildKeepLockPath sits next to the slot, not inside it" {
    var buf: [512]u8 = undefined;
    const path = try buildKeepLockPath(&buf, "/opt/malt/cache", "deadbeef");
    try std.testing.expectEqualStrings("/opt/malt/cache/run/deadbeef.lock", path);
}

test "buildKeepLockPath surfaces PathTooLong on overflow" {
    var buf: [16]u8 = undefined;
    try std.testing.expectError(
        error.PathTooLong,
        buildKeepLockPath(&buf, "/opt/malt/cache", "deadbeef"),
    );
}
