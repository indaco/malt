//! malt — purge command: housekeeping and nuclear-wipe scopes.
//! Refuses to run without a scope flag; full flag reference in `mt purge --help`.

const std = @import("std");
const AppCtx = @import("../app_ctx.zig").AppCtx;
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const lock_mod = @import("../db/lock.zig");
const help = @import("help.zig");

const args_mod = @import("purge/args.zig");
const wipe_mod = @import("purge/wipe.zig");
const scopes_mod = @import("purge/scopes.zig");
const util = @import("purge/util.zig");
const report = @import("purge/report.zig");
const purge_json = @import("purge/json.zig");

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

/// Closed enum of non-wipe scopes. Field names match `Scope` so
/// `@field(opts.scope, @tagName(k))` checks selection without a
/// hand-maintained dispatch table.
const ScopeKey = enum {
    unused_deps,
    store_orphans,
    cache,
    downloads,
    stale_casks,
    old_versions,

    fn label(k: ScopeKey) []const u8 {
        return switch (k) {
            .unused_deps => "unused-deps",
            .store_orphans => "store-orphans",
            .cache => "cache",
            .downloads => "downloads",
            .stale_casks => "stale-casks",
            .old_versions => "old-versions",
        };
    }
};

/// Run order matters: unused-deps must precede store-orphans because
/// removing a keg decrements its store ref to 0, and those fresh
/// orphans only get swept on the second pass.
const scope_run_order = [_]ScopeKey{
    .unused_deps,
    .store_orphans,
    .cache,
    .downloads,
    .stale_casks,
    .old_versions,
};

pub fn execute(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(ctx, args, "purge")) return;

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

    const start_ts = std.Io.Clock.real.now(ctx.io).toMilliseconds();

    if (opts.scope.wipe) {
        purge_json.emitScopeStarted("wipe", dry_run);
        var wipe_result: util.TierResult = .{};
        // Declare in reverse-of-fire order: LIFO defer flushes
        // scope_completed → purge_complete → summary even if runWipe
        // errors (e.g. UserAborted), so consumers can rely on a strict
        // open/close bracket per command invocation.
        defer if (output.isJson()) {
            const elapsed = std.Io.Clock.real.now(ctx.io).toMilliseconds() - start_ts;
            const wipe_rows = [_]report.SummaryRow{.{
                .name = "wipe",
                .removed = @intCast(wipe_result.removed),
                .bytes = wipe_result.bytes,
            }};
            purge_json.emitSummary(
                allocator,
                dry_run,
                &wipe_rows,
                wipe_result.removed,
                wipe_result.bytes,
                elapsed,
            ) catch {};
        };
        defer purge_json.emitPurgeComplete(wipe_result.removed, wipe_result.bytes, dry_run);
        defer purge_json.emitScopeCompleted("wipe", wipe_result.removed, wipe_result.bytes, dry_run);
        wipe_result = try wipe_mod.runWipe(ctx, allocator, opts, prefix, cache_dir, dry_run);
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
            try wipe_mod.writeManifest(ctx, allocator, bp);
            output.success("backup manifest written to {s}", .{bp});
        }
    }

    // One shared lock for all non-wipe scopes.  Lock path may not exist
    // (fresh install with no DB) — that's fine, we proceed without.
    var lock_path_buf: [512]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_path_buf, "{s}/db/malt.lock", .{prefix}) catch return;
    var lk_maybe: ?lock_mod.LockFile = lock_mod.LockFile.acquire(lock_path, 30_000) catch null;
    defer if (lk_maybe) |*lk| lk.release();

    var summary = report.Summary{};
    defer summary.deinit(allocator);
    var grand_total: TierResult = .{};

    // Strict ndjson bracketing: scope_started lines always pair with a
    // scope_completed (handled per scope below) and purge_complete /
    // summary always close the stream, even if a scope errors mid-flight.
    // Declare in reverse-of-fire order: LIFO drains purge_complete first,
    // then summary.
    defer if (output.isJson()) {
        const elapsed = std.Io.Clock.real.now(ctx.io).toMilliseconds() - start_ts;
        purge_json.emitSummary(
            allocator,
            dry_run,
            summary.rows.items,
            grand_total.removed,
            grand_total.bytes,
            elapsed,
        ) catch {};
    };
    defer purge_json.emitPurgeComplete(grand_total.removed, grand_total.bytes, dry_run);

    inline for (scope_run_order) |k| {
        if (@field(opts.scope, @tagName(k))) {
            const name = comptime k.label();
            purge_json.emitScopeStarted(name, dry_run);
            var r: TierResult = .{};
            defer purge_json.emitScopeCompleted(name, r.removed, r.bytes, dry_run);
            r = try switch (k) {
                .unused_deps => scopes_mod.runUnusedDeps(ctx, allocator, prefix, dry_run),
                .store_orphans => scopes_mod.runStoreOrphans(ctx, allocator, prefix, dry_run),
                .cache => scopes_mod.runCache(ctx, allocator, cache_dir, opts.cache_days, dry_run),
                .downloads => scopes_mod.runDownloads(ctx, allocator, cache_dir, dry_run),
                .stale_casks => scopes_mod.runStaleCasks(ctx, allocator, prefix, dry_run),
                .old_versions => scopes_mod.runOldVersions(ctx, allocator, prefix, dry_run),
            };
            try summary.add(allocator, .{ .name = name, .removed = r.removed, .bytes = r.bytes });
            grand_total.removed += r.removed;
            grand_total.bytes += r.bytes;
        }
    }

    // Skip the table when only one scope ran — the per-scope footer is
    // already enough and the table would just repeat it.
    if (summary.rows.items.len > 1) summary.render();

    const item_noun = report.pluralize(grand_total.removed, "item", "items");
    var sz_buf: [32]u8 = undefined;
    const sz = formatBytes(grand_total.bytes, &sz_buf);
    if (dry_run) {
        output.info("dry run: would remove {d} {s}, ~{s}", .{ grand_total.removed, item_noun, sz });
    } else {
        output.success("removed {d} {s}, freed ~{s}", .{ grand_total.removed, item_noun, sz });
    }
}
