//! malt — purge command: housekeeping and nuclear-wipe scopes.
//! Refuses to run without a scope flag; full flag reference in `mt purge --help`.

const std = @import("std");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const lock_mod = @import("../db/lock.zig");
const help = @import("help.zig");

const args_mod = @import("purge/args.zig");
const wipe_mod = @import("purge/wipe.zig");
const scopes_mod = @import("purge/scopes.zig");
const util = @import("purge/util.zig");

pub const Error = args_mod.Error;
pub const Scope = args_mod.Scope;
pub const Options = args_mod.Options;
pub const Category = args_mod.Category;
pub const Target = args_mod.Target;
pub const parseArgs = args_mod.parseArgs;

pub const buildPlan = wipe_mod.buildPlan;
pub const freePlan = wipe_mod.freePlan;

pub const formatBytes = util.formatBytes;

const TierResult = util.TierResult;

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "purge")) return;

    const opts = parseArgs(args) catch {
        output.err("invalid arguments — run `mt purge --help` for usage", .{});
        return Error.InvalidArgs;
    };

    if (opts.scope.isEmpty()) {
        output.err("purge requires a scope flag — see `mt purge --help`", .{});
        output.dim("examples: mt purge --housekeeping  |  mt purge --store-orphans  |  mt purge --wipe", .{});
        return Error.NoScope;
    }

    const dry_run = output.isDryRun();
    const prefix = atomic.maltPrefix();
    const cache_dir = atomic.maltCacheDir(allocator) catch {
        output.err("failed to determine cache directory", .{});
        return Error.OpenFileFailed;
    };
    defer allocator.free(cache_dir);

    if (opts.scope.wipe) {
        try wipe_mod.runWipe(allocator, opts, prefix, cache_dir, dry_run);
        return;
    }

    // Per-scope confirmations (only those that are destructive enough to
    // warrant a typed gate).  Skipped on --dry-run to keep previews silent.
    if (!dry_run) {
        if (opts.scope.downloads) try util.confirmScope(opts.yes, "downloads", "downloads scrub");
        if (opts.scope.old_versions) try util.confirmScope(opts.yes, "old-versions", "old-versions removal");
    }

    // Optional backup before any destructive scope runs.
    if (opts.backup_path) |bp| {
        if (dry_run) {
            output.info("would write backup manifest to {s}", .{bp});
        } else {
            try wipe_mod.writeManifest(allocator, bp);
            output.success("backup manifest written to {s}", .{bp});
        }
    }

    // One shared lock for all non-wipe scopes.  Lock path may not exist
    // (fresh install with no DB) — that's fine, we proceed without.
    var lock_path_buf: [512]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_path_buf, "{s}/db/malt.lock", .{prefix}) catch return;
    var lk_maybe: ?lock_mod.LockFile = lock_mod.LockFile.acquire(lock_path, 30_000) catch null;
    defer if (lk_maybe) |*lk| lk.release();

    var grand_total: TierResult = .{};

    // unused-deps must run before store-orphans: removing a keg decrements
    // its store ref to 0, and those fresh orphans only get swept on the
    // second pass.
    if (opts.scope.unused_deps) {
        const r = try scopes_mod.runUnusedDeps(allocator, prefix, dry_run);
        grand_total.removed += r.removed;
        grand_total.bytes += r.bytes;
    }
    if (opts.scope.store_orphans) {
        const r = try scopes_mod.runStoreOrphans(allocator, prefix, dry_run);
        grand_total.removed += r.removed;
        grand_total.bytes += r.bytes;
    }
    if (opts.scope.cache) {
        const r = try scopes_mod.runCache(allocator, cache_dir, opts.cache_days, dry_run);
        grand_total.removed += r.removed;
        grand_total.bytes += r.bytes;
    }
    if (opts.scope.downloads) {
        const r = try scopes_mod.runDownloads(allocator, cache_dir, dry_run);
        grand_total.removed += r.removed;
        grand_total.bytes += r.bytes;
    }
    if (opts.scope.stale_casks) {
        const r = try scopes_mod.runStaleCasks(allocator, prefix, dry_run);
        grand_total.removed += r.removed;
        grand_total.bytes += r.bytes;
    }
    if (opts.scope.old_versions) {
        const r = try scopes_mod.runOldVersions(allocator, prefix, dry_run);
        grand_total.removed += r.removed;
        grand_total.bytes += r.bytes;
    }

    var sz_buf: [32]u8 = undefined;
    const sz = formatBytes(grand_total.bytes, &sz_buf);
    if (dry_run) {
        output.info("dry run: would remove {d} item(s), ~{s}", .{ grand_total.removed, sz });
    } else {
        output.success("removed {d} item(s), freed ~{s}", .{ grand_total.removed, sz });
    }
}
