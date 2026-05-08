//! Bounded worker pool for `mt migrate --parallel`. Workers do the
//! per-keg migrate work concurrently; sqlite writes serialise through
//! a shared mutex so transactions stay atomic across threads.

const std = @import("std");
const AppCtx = @import("../../app_ctx.zig").AppCtx;
const sqlite = @import("../../db/sqlite.zig");
const store_mod = @import("../../core/store.zig");
const linker_mod = @import("../../core/linker.zig");
const client_mod = @import("../../net/client.zig");
const ghcr_mod = @import("../../net/ghcr.zig");
const api_mod = @import("../../net/api.zig");
const output = @import("../../ui/output.zig");
const progress_mod = @import("../../ui/progress.zig");
const main_mod = @import("../../main.zig");
const keg_mod = @import("keg.zig");
const manifest_mod = @import("manifest.zig");
const post_install_queue_mod = @import("post_install_queue.zig");

/// 4 matches the install-side HTTP client pool; higher just queues on TLS contexts.
pub const default_workers: u32 = 4;

/// Bound stack/FD usage under hostile env values.
pub const max_workers: u32 = 32;

/// Clamps to `[1, max_workers]` so a typo never spawns hundreds of threads.
/// Takes the env reading via the caller so tests pin behaviour without `setenv`.
pub fn workerCountFromEnv(env_value: ?[]const u8) u32 {
    const raw = env_value orelse return default_workers;
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return default_workers;
    const parsed = std.fmt.parseInt(u32, trimmed, 10) catch return default_workers;
    return std.math.clamp(parsed, 1, max_workers);
}

/// Read `MALT_MIGRATE_PARALLEL_WORKERS` from the live environment.
pub fn workerCountFromLiveEnv(ctx: *const AppCtx) u32 {
    return workerCountFromEnv(std.process.Environ.getPosix(ctx.environ, "MALT_MIGRATE_PARALLEL_WORKERS"));
}

/// Extra threads beyond the job count would just spin on an empty queue.
pub fn boundWorkerCount(requested: u32, jobs: usize) u32 {
    if (jobs == 0) return 0;
    const j: u32 = if (jobs > max_workers) max_workers else @intCast(jobs);
    return @min(requested, j);
}

/// Outcome plus name so the orchestrator can drain into the same
/// per-category lists the serial path uses.
pub const KegOutcome = struct {
    name: []const u8,
    result: keg_mod.KegResult,
};

/// Workers download+materialise lock-free; `db_mu` and `manifest_mu`
/// serialise the post-success persistence so concurrent successes can
/// flush without racing.
pub const Pool = struct {
    app_ctx: *const AppCtx,
    next_idx: std.atomic.Value(usize),
    keg_names: []const []const u8,
    outcomes: []KegOutcome,

    cache_dir: []const u8,
    prefix: []const u8,
    homebrew_prefix: []const u8,
    use_system_ruby_scope: []const []const u8,

    http_pool: *client_mod.HttpClientPool,
    store: *store_mod.Store,
    linker: *linker_mod.Linker,
    db: *sqlite.Database,
    db_mu: *std.Io.Mutex,

    manifest: *manifest_mod.Manifest,
    manifest_mu: *std.Io.Mutex,
    manifest_path: []const u8,
    manifest_allocator: std.mem.Allocator,

    post_install_queue: *post_install_queue_mod.Queue,

    /// Per-keg bar pointer. Length matches `keg_names`; an entry is null
    /// when the orchestrator pre-filtered that keg (already installed
    /// per manifest+DB at run start) and didn't reserve a multi-progress
    /// line for it. Non-null entries point into a bars slice owned by
    /// the orchestrator; that slice outlives every worker.
    bar_for_keg: []const ?*progress_mod.ProgressBar = &.{},
};

/// Per-iteration arena + borrowed http client matches the per-worker
/// pattern in `cli/install/download.zig` so TLS contexts stay warm
/// without sharing mutable state across threads.
fn worker(pool: *Pool) void {
    const io = pool.app_ctx.io;
    while (true) {
        const idx = pool.next_idx.fetchAdd(1, .acq_rel);
        if (idx >= pool.keg_names.len) return;
        const keg_name = pool.keg_names[idx];

        const bar: ?*progress_mod.ProgressBar = if (idx < pool.bar_for_keg.len)
            pool.bar_for_keg[idx]
        else
            null;

        // Manifest+DB check runs before the interrupt check so a keg that
        // was already installed surfaces as `.skipped_installed` even when
        // Ctrl-C fires mid-run; reversing the order would demote real
        // skips to `.cancelled` and lie about on-disk state.
        pool.manifest_mu.lockUncancelable(io);
        const in_manifest = pool.manifest.contains(keg_name);
        pool.manifest_mu.unlock(io);
        // DB cross-check guards against a stale manifest after `mt
        // uninstall` — see the matching note in cli/migrate.zig. Read runs
        // outside `db_mu` because build.zig links SQLite with
        // `SQLITE_THREADSAFE=1` (Serialized mode); without that flag this
        // probe would race the worker writes that hold `db_mu`.
        if (in_manifest and keg_mod.isInstalled(pool.db, keg_name)) {
            pool.outcomes[idx] = .{ .name = keg_name, .result = .skipped_installed };
            continue;
        }

        if (main_mod.isInterrupted()) {
            pool.outcomes[idx] = .{ .name = keg_name, .result = .cancelled };
            continue;
        }

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const http = pool.http_pool.acquire();
        defer pool.http_pool.release(http);
        var api = api_mod.BrewApi.init(io, a, http, pool.cache_dir);
        var ghcr = ghcr_mod.GhcrClient.init(io, a, http);
        defer ghcr.deinit();

        const result = keg_mod.migrateKeg(pool.app_ctx, a, keg_name, .{
            .api = &api,
            .ghcr = &ghcr,
            .http = http,
            .store = pool.store,
            .linker = pool.linker,
            .db = pool.db,
            .prefix = pool.prefix,
            .homebrew_prefix = pool.homebrew_prefix,
            .use_system_ruby_scope = pool.use_system_ruby_scope,
            .db_mu = pool.db_mu,
            .post_install_queue = pool.post_install_queue,
            .bar = bar,
        });
        if (bar) |b| b.finish();
        pool.outcomes[idx] = .{ .name = keg_name, .result = result };

        if (result == .migrated) {
            pool.manifest_mu.lockUncancelable(io);
            pool.manifest.add(keg_name) catch |e| {
                output.warn("Resume manifest update failed for {s}: {s}", .{ keg_name, @errorName(e) });
            };
            pool.manifest.writeAtomic(io, pool.manifest_allocator, pool.manifest_path) catch |e| {
                output.warn("Resume manifest write failed: {s}", .{@errorName(e)});
            };
            pool.manifest_mu.unlock(io);
        }
    }
}

/// Falls back to inline drain on spawn failure so a thread-spawn refusal
/// still completes the queue — same defensive pattern as `MaterializePool`.
pub fn run(allocator: std.mem.Allocator, pool: *Pool, worker_count: u32) !void {
    if (pool.keg_names.len == 0) return;

    const threads = allocator.alloc(std.Thread, worker_count) catch {
        // Fall back to inline drain — single-threaded, but correct.
        worker(pool);
        return;
    };
    defer allocator.free(threads);

    var spawned: usize = 0;
    var i: usize = 0;
    while (i < worker_count) : (i += 1) {
        if (std.Thread.spawn(.{}, worker, .{pool})) |t| {
            threads[spawned] = t;
            spawned += 1;
        } else |_| {
            worker(pool);
        }
    }
    for (threads[0..spawned]) |t| t.join();
}

// ── Inline unit tests ──────────────────────────────────────────────

test "workerCountFromEnv returns default when env is null" {
    try std.testing.expectEqual(default_workers, workerCountFromEnv(null));
}

test "workerCountFromEnv returns default on empty / whitespace" {
    try std.testing.expectEqual(default_workers, workerCountFromEnv(""));
    try std.testing.expectEqual(default_workers, workerCountFromEnv("   "));
}

test "workerCountFromEnv parses a numeric value" {
    try std.testing.expectEqual(@as(u32, 8), workerCountFromEnv("8"));
    try std.testing.expectEqual(@as(u32, 1), workerCountFromEnv("1"));
}

test "workerCountFromEnv falls back to default on garbage" {
    try std.testing.expectEqual(default_workers, workerCountFromEnv("not-a-number"));
    try std.testing.expectEqual(default_workers, workerCountFromEnv("4abc"));
}

test "workerCountFromEnv clamps to max_workers ceiling" {
    try std.testing.expectEqual(max_workers, workerCountFromEnv("9999"));
}

test "workerCountFromEnv clamps zero to one (a 0-thread pool would deadlock)" {
    try std.testing.expectEqual(@as(u32, 1), workerCountFromEnv("0"));
}

test "boundWorkerCount caps by job count" {
    try std.testing.expectEqual(@as(u32, 2), boundWorkerCount(4, 2));
    try std.testing.expectEqual(@as(u32, 4), boundWorkerCount(4, 10));
    try std.testing.expectEqual(@as(u32, 0), boundWorkerCount(4, 0));
}

// Pre-set SIGINT with an empty manifest: every slot falls through the
// manifest+DB short-circuit and lands on the interrupt arm, so the
// summary can tell "you cancelled before I touched it" from "I had it
// already." The DB pointer stays `undefined` because the empty manifest
// short-circuits the `and` before any DB query runs.
test "worker interrupt branch routes untouched kegs to .cancelled" {
    main_mod.setInterruptedForTest(true);
    defer main_mod.setInterruptedForTest(false);

    const app_ctx_mod = @import("../../app_ctx.zig");
    const names = [_][]const u8{ "a", "b", "c" };
    var outcomes: [names.len]KegOutcome = undefined;
    for (&outcomes, 0..) |*o, i| o.* = .{ .name = names[i], .result = .cancelled };

    var manifest = manifest_mod.Manifest.init(std.testing.allocator);
    defer manifest.deinit();
    var manifest_mu: std.Io.Mutex = .init;
    var db_mu: std.Io.Mutex = .init;

    var pool: Pool = .{
        .app_ctx = &app_ctx_mod.debug_ctx,
        .next_idx = std.atomic.Value(usize).init(0),
        .keg_names = &names,
        .outcomes = &outcomes,
        .cache_dir = "",
        .prefix = "",
        .homebrew_prefix = "",
        .use_system_ruby_scope = &.{},
        .http_pool = undefined,
        .store = undefined,
        .linker = undefined,
        .db = undefined,
        .db_mu = &db_mu,
        .manifest = &manifest,
        .manifest_mu = &manifest_mu,
        .manifest_path = "",
        .manifest_allocator = std.testing.allocator,
        .post_install_queue = undefined,
    };
    try run(std.testing.allocator, &pool, 2);

    for (outcomes) |o| try std.testing.expectEqual(keg_mod.KegResult.cancelled, o.result);
}
