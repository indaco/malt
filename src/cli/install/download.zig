//! Parallel download + materialize machinery for `cli/install.zig`.
//! Owns `DownloadJob`, the per-job worker entry points, and the bounded
//! worker pools used by `collectFormulaJobs` and the execute flow.

const std = @import("std");
const fs_compat = @import("../../fs/compat.zig");
const sqlite = @import("../../db/sqlite.zig");
const formula_mod = @import("../../core/formula.zig");
const bottle_mod = @import("../../core/bottle.zig");
const store_mod = @import("../../core/store.zig");
const cellar_mod = @import("../../core/cellar.zig");
const deps_mod = @import("../../core/deps.zig");
const client_mod = @import("../../net/client.zig");
const ghcr_mod = @import("../../net/ghcr.zig");
const api_mod = @import("../../net/api.zig");
const atomic = @import("../../fs/atomic.zig");
const output = @import("../../ui/output.zig");
const progress_mod = @import("../../ui/progress.zig");

const ghcr_url = @import("ghcr_url.zig");
const record = @import("record.zig");

const InstallError = record.InstallError;

/// A bottle download job for parallel processing.
///
/// Public so integration tests can construct an empty jobs list and assert
/// that `collectFormulaJobs` early-return branches leave it untouched.
pub const DownloadJob = struct {
    name: []const u8,
    version_str: []const u8,
    sha256: []const u8,
    bottle_url: []const u8,
    is_dep: bool,
    keg_only: bool,
    post_install_defined: bool,
    formula_json: []const u8,
    /// Cellar type from bottle metadata (e.g. ":any", ":any_skip_relocation").
    /// Used to skip Mach-O patching for relocatable bottles.
    cellar_type: []const u8,
    /// Alignment width for progress bar labels (max name length across all jobs).
    label_width: u8,
    /// Line index within the multi-progress group.
    line_index: u8,
    /// Shared multi-progress state for coordinated rendering.
    multi: ?*progress_mod.MultiProgress,
    /// Progress bar owned by the main thread. Created before workers are spawned
    /// so every reserved line is drawn immediately, avoiding an empty row when a
    /// later worker thread is scheduled before an earlier one.
    bar: ?*progress_mod.ProgressBar,
    /// Set after download completes
    store_sha256: []const u8,
    succeeded: bool,
};

/// Bridge between ProgressCallback and ProgressBar.
pub fn progressBridge(ctx: *anyopaque, bytes_so_far: u64, content_length: ?u64) void {
    const bar: *progress_mod.ProgressBar = @ptrCast(@alignCast(ctx));
    if (content_length) |total| {
        if (bar.total == 0) bar.total = total;
    }
    // Clamp to total to prevent >100% when Content-Length reflects compressed size
    const clamped = if (bar.total > 0) @min(bytes_so_far, bar.total) else bytes_so_far;
    bar.update(clamped);
}

/// Download a bottle and commit to store. Runs in a worker thread.
/// `http_pool` is shared across all download workers — each worker
/// borrows a client for the duration of a single blob download and
/// releases it so another worker can reuse the same TLS context.
pub fn downloadWorker(
    _: std.mem.Allocator,
    ghcr: *ghcr_mod.GhcrClient,
    http_pool: *client_mod.HttpClientPool,
    store: *store_mod.Store,
    job: *DownloadJob,
) void {
    // Each thread gets its own arena — the parent arena is not thread-safe.
    var thread_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer thread_arena.deinit();
    const allocator = thread_arena.allocator();

    // Skip if already in store
    if (store.exists(job.sha256)) {
        job.store_sha256 = job.sha256;
        job.succeeded = true;
        return;
    }

    // Extract repo + digest from bottle URL via the shared parser so
    // the token-prefetch path in `execute` can collect scopes without
    // duplicating this logic. Slices borrow from `job.bottle_url`,
    // which outlives the worker.
    const ref = ghcr_url.parseGhcrUrl(job.bottle_url) orelse return;
    const repo = ref.repo;
    const digest = ref.digest;

    // Create temp dir
    const tmp_dir = atomic.createTempDir(allocator, job.name) catch return;

    // The progress bar was created and pre-rendered by the main thread so that
    // every reserved line has content even before this worker starts producing
    // bytes. We just feed updates into it via the progress callback.
    const bar = job.bar orelse return;
    const progress_cb = client_mod.ProgressCallback{
        .context = @ptrCast(bar),
        .func = &progressBridge,
    };

    // Borrow a client from the shared pool for the duration of this
    // download. The pool blocks if all clients are in use by other
    // workers, then hands us one with its TLS context already warm.
    const http = http_pool.acquire();
    defer http_pool.release(http);

    const max_attempts: u8 = 3;
    const retry_delays_ms = [_]u64{ 100, 400 };
    var dl_attempt: u8 = 0;
    var dl_ok = false;
    var last_err: bottle_mod.BottleError = bottle_mod.BottleError.DownloadFailed;
    while (dl_attempt < max_attempts) : (dl_attempt += 1) {
        if (bottle_mod.download(allocator, ghcr, http, repo, digest, job.sha256, tmp_dir, progress_cb)) |_| {
            dl_ok = true;
            break;
        } else |dl_err| {
            last_err = dl_err;
            atomic.cleanupTempDir(tmp_dir);
            if (dl_err == bottle_mod.BottleError.DownloadPermanent) {
                output.err("  {s}: permanent HTTP error (404/410), not retrying", .{job.name});
                break;
            }
            if (dl_err == bottle_mod.BottleError.ExtractionFailed or
                dl_err == bottle_mod.BottleError.Sha256Mismatch or
                dl_err == bottle_mod.BottleError.PathTooLong)
            {
                output.err("  {s}: {s}", .{ job.name, @errorName(dl_err) });
                break;
            }
            if (dl_attempt + 1 < max_attempts) {
                fs_compat.sleepNanos(retry_delays_ms[dl_attempt] * std.time.ns_per_ms);
            }
        }
    }
    if (!dl_ok) {
        bar.finish();
        if (dl_attempt >= max_attempts) {
            output.err("  {s}: {s} (after {d} attempts)", .{ job.name, @errorName(last_err), max_attempts });
        }
        allocator.free(tmp_dir);
        return;
    }
    bar.finish();

    // Commit to store
    store.commitFrom(job.sha256, tmp_dir) catch {
        atomic.cleanupTempDir(tmp_dir);
        allocator.free(tmp_dir);
        return;
    };
    allocator.free(tmp_dir);

    store.incrementRef(job.sha256) catch |e| {
        std.log.warn("refcount increment failed for {s}: {s}", .{ job.sha256, @errorName(e) });
    };

    job.store_sha256 = job.sha256;
    job.succeeded = true;
}

/// Per-dep worker context for parallel formula fetching. Owns its own
/// `ArenaAllocator` backed by `page_allocator` so workers never touch
/// a shared bump-pointer — matches the `downloadWorker` pattern and
/// removes the last cross-thread allocator on the resolve path.
///
/// Why the pool on the HTTP side: creating a fresh `HttpClient` per
/// worker paid a full TLS context + cert store setup per dep. For
/// cold installs of packages with many deps (ffmpeg has 11) that
/// overhead compounds; the pool lets workers reuse warm TLS contexts.
///
/// `result` is a slice inside `arena`, so the caller must dupe it
/// into a longer-lived allocator before `arena.deinit()`.
const FetchFormulaCtx = struct {
    arena: std.heap.ArenaAllocator,
    pool: *client_mod.HttpClientPool,
    cache_dir: []const u8,
    dep_name: []const u8,
    result: ?[]const u8 = null,

    fn run(self: *FetchFormulaCtx) void {
        const http = self.pool.acquire();
        defer self.pool.release(http);
        var local_api = api_mod.BrewApi.init(self.arena.allocator(), http, self.cache_dir);
        self.result = local_api.fetchFormula(self.dep_name) catch null;
    }
};

/// Maximum concurrent workers for the dep-fetch phase of
/// `collectFormulaJobs`. Matches the install-time HTTP client pool so
/// workers never block on `pool.acquire` — extra workers would just sit
/// idle waiting for a client.
pub const MAX_COLLECT_FETCH_WORKERS: usize = 4;

/// Bounded worker count for a given dep-fetch load. Exposed so tests
/// can pin the "no more than N threads" invariant without scraping
/// `std.Thread.spawn` call counts.
pub fn collectFetchWorkerCount(deps_to_fetch: usize) usize {
    return @min(MAX_COLLECT_FETCH_WORKERS, deps_to_fetch);
}

/// Shared state for the dep-fetch pool. Mirrors `MaterializePool`: a
/// single atomic index hands out `ctxs` slots to workers until the
/// array is drained. Already-installed deps are skipped in-thread.
const FetchJobsPool = struct {
    next_idx: std.atomic.Value(usize),
    ctxs: []FetchFormulaCtx,
    deps: []const deps_mod.ResolvedDep,
};

/// Thread entry-point for the bounded dep-fetch pool. Each worker
/// grabs the next `ctxs` index atomically and runs the fetch until the
/// index passes the end, skipping deps that are already installed.
fn collectFetchPoolWorker(pool: *FetchJobsPool) void {
    while (true) {
        const idx = pool.next_idx.fetchAdd(1, .acq_rel);
        if (idx >= pool.ctxs.len) return;
        if (pool.deps[idx].already_installed) continue;
        pool.ctxs[idx].run();
    }
}

/// Job-owned strings duped out of a parsed formula so its
/// `std.json.Parsed` arena can be released as soon as
/// `collectFormulaJobs` is done reading it. Lifetime matches the
/// `DownloadJob` — freed by the install flow after the job completes.
const JobStrings = struct {
    name: []u8,
    version_str: []u8,
    sha256: []u8,
    bottle_url: []u8,
    cellar_type: []u8,

    fn freeAll(self: JobStrings, a: std.mem.Allocator) void {
        a.free(self.name);
        a.free(self.version_str);
        a.free(self.sha256);
        a.free(self.bottle_url);
        a.free(self.cellar_type);
    }
};

/// Dupe the five borrowed slices that a `DownloadJob` needs from a
/// parsed formula, so the parsed tree can be deinited immediately.
/// Rolls back on partial failure via errdefer chain.
fn dupeJobStrings(
    a: std.mem.Allocator,
    f: *const formula_mod.Formula,
    b: formula_mod.BottleFile,
) !JobStrings {
    const name = try a.dupe(u8, f.name);
    errdefer a.free(name);
    const version_str = try a.dupe(u8, f.pkg_version);
    errdefer a.free(version_str);
    const sha256 = try a.dupe(u8, b.sha256);
    errdefer a.free(sha256);
    const bottle_url = try a.dupe(u8, b.url);
    errdefer a.free(bottle_url);
    const cellar_type = try a.dupe(u8, b.cellar);
    return .{
        .name = name,
        .version_str = version_str,
        .sha256 = sha256,
        .bottle_url = bottle_url,
        .cellar_type = cellar_type,
    };
}

/// Collect download jobs for a formula and all its dependencies.
/// Appends to the shared jobs list for parallel download.
///
/// Public so integration tests can exercise the early-abort branches
/// (already-installed, post_install_defined) with a real SQLite DB and
/// without a live Homebrew API connection.
pub fn collectFormulaJobs(
    allocator: std.mem.Allocator,
    pkg_name: []const u8,
    formula_json: []const u8,
    api: *api_mod.BrewApi,
    http_pool: *client_mod.HttpClientPool,
    db: *sqlite.Database,
    store: *store_mod.Store,
    force: bool,
    jobs: *std.ArrayList(DownloadJob),
) !void {
    _ = store;

    // Single arena for every parsed formula — root + each dep — so the
    // std.json.Parsed trees and all the supplementary allocations made
    // by `parseFormula` (dependencies/oldnames/service.run/pkg_version)
    // are released at function exit. BUG-009 used to pin every parsed
    // tree for the whole install run (~500 KB on ffmpeg).
    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const parse_alloc = parse_arena.allocator();

    var formula = formula_mod.parseFormula(parse_alloc, formula_json) catch |e| {
        output.err("Failed to parse formula JSON for '{s}': {s}", .{ pkg_name, @errorName(e) });
        return InstallError.FormulaNotFound;
    };

    // Check if already installed
    if (!force and record.isInstalled(db, formula.name)) {
        output.info("{s} is already installed", .{formula.name});
        return;
    }

    // Resolve dependencies. `deps_mod.resolve` forwards the allocator
    // into `api.fetchFormula`, whose bytes come from `api.allocator`
    // (the same caller allocator) — so the allocator here must match
    // `allocator`, not `parse_arena.allocator()`, otherwise free on
    // the API-allocated bytes is a no-op on the arena.
    const deps = deps_mod.resolve(allocator, formula.name, api, db) catch &.{};
    defer {
        for (deps) |d| allocator.free(d.name);
        // `catch &.{}` yields a static empty slice with no backing
        // allocation — freeing it would be "invalid free" on safe
        // allocators.
        if (deps.len > 0) allocator.free(deps);
    }

    // Keep each already-installed dep's opt/ symlink pointing at its Cellar.
    const heal_prefix = atomic.maltPrefix();
    for (deps) |dep| {
        if (!dep.already_installed) continue;
        deps_mod.ensureOptLink(db, heal_prefix, dep.name);
    }

    // Fetch every dep's formula JSON **in parallel**. Each worker
    // borrows a client from the shared `http_pool` for the duration
    // of its request so TLS contexts are reused across deps.
    //
    // Allocator strategy (S7): each worker owns a `FetchFormulaCtx`
    // with its own `ArenaAllocator` on `page_allocator` — no shared
    // bump-pointer across threads. JSON bodies live in the worker's
    // arena until after `join`, then get duped into the caller's
    // `allocator` so they outlive the per-worker deinit.
    const dep_jsons = allocator.alloc(?[]const u8, deps.len) catch return InstallError.DownloadFailed;
    defer allocator.free(dep_jsons);
    @memset(dep_jsons, null);

    if (deps.len > 0) {
        const ctxs = allocator.alloc(FetchFormulaCtx, deps.len) catch return InstallError.DownloadFailed;
        defer {
            for (ctxs) |*c| c.arena.deinit();
            allocator.free(ctxs);
        }
        for (ctxs, 0..) |*c, i| {
            c.* = .{
                .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
                .pool = http_pool,
                .cache_dir = api.cache_dir,
                .dep_name = deps[i].name,
            };
        }

        // Bounded pool: one-thread-per-dep over-allocated stacks and
        // queued on the 4-slot HTTP client pool anyway. Workers share
        // an atomic index and drain `ctxs` — same pattern as
        // `materializePoolWorker`.
        var to_fetch: usize = 0;
        for (deps) |d| {
            if (!d.already_installed) to_fetch += 1;
        }

        if (to_fetch > 0) {
            const worker_count = collectFetchWorkerCount(to_fetch);
            var pool_ctx: FetchJobsPool = .{
                .next_idx = std.atomic.Value(usize).init(0),
                .ctxs = ctxs,
                .deps = deps,
            };

            const threads = allocator.alloc(std.Thread, worker_count) catch
                return InstallError.DownloadFailed;
            defer allocator.free(threads);

            var spawned: usize = 0;
            for (0..worker_count) |_| {
                if (std.Thread.spawn(.{}, collectFetchPoolWorker, .{&pool_ctx})) |t| {
                    threads[spawned] = t;
                    spawned += 1;
                } else |_| {
                    // Spawn failure → drain remaining work inline.
                    collectFetchPoolWorker(&pool_ctx);
                }
            }
            for (threads[0..spawned]) |t| t.join();
        }

        // Dupe each fetched JSON into the caller's allocator so the
        // memory outlives per-worker `arena.deinit()` — downstream
        // parses and eventually `allocator.free`s these bytes.
        for (ctxs, 0..) |*c, i| {
            if (c.result) |bytes| {
                dep_jsons[i] = allocator.dupe(u8, bytes) catch null;
            }
        }
    }

    // Add deps as jobs — serial post-processing (parse + dedup + append)
    // using the JSONs we fetched above.
    for (deps, 0..) |dep, i| {
        if (dep.already_installed) continue;
        const dep_json = dep_jsons[i] orelse continue;

        // dep_json is moved into the job on success; any continue path
        // before that transfer must free the bytes.
        var dep_json_consumed = false;
        defer if (!dep_json_consumed) allocator.free(dep_json);

        var dep_formula = formula_mod.parseFormula(parse_alloc, dep_json) catch continue;
        const dep_bottle = formula_mod.resolveBottle(parse_alloc, &dep_formula) catch continue;

        // Check for duplicate (another top-level pkg may share a dep)
        var is_dup = false;
        for (jobs.items) |existing| {
            if (std.mem.eql(u8, existing.sha256, dep_bottle.sha256)) {
                is_dup = true;
                break;
            }
        }
        if (is_dup) continue;

        // Dupe the five borrowed slices out of the parsed tree into
        // the caller allocator so parse_arena can release the tree.
        const strs = dupeJobStrings(allocator, &dep_formula, dep_bottle) catch continue;

        jobs.append(allocator, .{
            .name = strs.name,
            // pkg_version folds in the `_N` revision suffix so cellar
            // paths match the bottle's baked-in LC_LOAD_DYLIB entries.
            .version_str = strs.version_str,
            .sha256 = strs.sha256,
            .bottle_url = strs.bottle_url,
            .is_dep = true,
            .keg_only = dep_formula.keg_only,
            .post_install_defined = dep_formula.post_install_defined,
            .formula_json = dep_json,
            .cellar_type = strs.cellar_type,
            .label_width = 0,
            .line_index = 0,
            .multi = null,
            .bar = null,
            .store_sha256 = "",
            .succeeded = false,
        }) catch {
            strs.freeAll(allocator);
            continue;
        };
        dep_json_consumed = true;
    }

    // Add main formula
    const bottle = formula_mod.resolveBottle(parse_alloc, &formula) catch {
        output.err("No bottle available for {s} on this platform", .{formula.name});
        return InstallError.NoBottle;
    };

    const main_strs = dupeJobStrings(allocator, &formula, bottle) catch return InstallError.DownloadFailed;
    errdefer main_strs.freeAll(allocator);

    jobs.append(allocator, .{
        .name = main_strs.name,
        // Same reason as the dep branch above: the cellar dir name
        // must carry the `_N` suffix when revision > 0.
        .version_str = main_strs.version_str,
        .sha256 = main_strs.sha256,
        .bottle_url = main_strs.bottle_url,
        .is_dep = false,
        .keg_only = formula.keg_only,
        .post_install_defined = formula.post_install_defined,
        .formula_json = formula_json,
        .cellar_type = main_strs.cellar_type,
        .label_width = 0,
        .line_index = 0,
        .multi = null,
        .bar = null,
        .store_sha256 = "",
        .succeeded = false,
    }) catch return InstallError.DownloadFailed;

    const pkg_word: []const u8 = if (jobs.items.len == 1) "package" else "packages";
    output.info("Resolved {s} {s} ({d} {s})", .{ formula.name, formula.version, jobs.items.len, pkg_word });
}

/// Return the first dep name of `formula_json` that appears in `failed_kegs`,
/// or null if none did. Used to short-circuit jobs whose dependency graph is
/// already broken so we do not leave half-installed kegs behind.
///
/// Errors during parse are treated as "no known failed dep" — we would rather
/// attempt the install and let materialize surface the real problem than
/// silently skip over a parser hiccup.
pub fn findFailedDep(
    failed_kegs: *std.StringHashMap(void),
    formula_json: []const u8,
) ?[]const u8 {
    var tmp_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer tmp_arena.deinit();
    const a = tmp_arena.allocator();

    var parsed = formula_mod.parseFormula(a, formula_json) catch return null;
    defer parsed.deinit();

    for (parsed.dependencies) |dep_name| {
        if (failed_kegs.contains(dep_name)) {
            // The slice `dep_name` lives inside the temp arena which is about
            // to be freed. Look up the same key inside the map's storage to
            // return a slice with a stable lifetime (the map owns its keys
            // indirectly via the job.name slices stored at insert time).
            if (failed_kegs.getKey(dep_name)) |stable| return stable;
            return dep_name;
        }
    }
    return null;
}

/// Result of a parallel materialize worker. `keg_path` is owned via
/// `std.heap.c_allocator` (thread-safe) and must be freed by the caller.
pub const MaterializeResult = struct {
    ok: bool,
    keg_path: []const u8,
    err: ?cellar_mod.CellarError,
};

/// Shared state for a bounded work-stealing thread pool that executes
/// the materialize phase. `next_idx` hands out jobs atomically so
/// workers grab the next available job until the queue is drained —
/// natural load-balancing without waves.
pub const MaterializePool = struct {
    next_idx: std.atomic.Value(usize),
    jobs: []DownloadJob,
    prefix: []const u8,
    results: []MaterializeResult,
};

/// Thread entry-point for the bounded materialize pool. Each worker
/// loops grabbing the next job index atomically and running
/// `materializeOne` on it until the index passes the end of the jobs
/// array. The pool is capped at 4 workers (see the call site in
/// `execute`) to keep file-I/O and codesign-subprocess contention low.
pub fn materializePoolWorker(pool: *MaterializePool) void {
    while (true) {
        const idx = pool.next_idx.fetchAdd(1, .acq_rel);
        if (idx >= pool.jobs.len) return;
        const job = &pool.jobs[idx];
        if (!job.succeeded) continue;
        materializeOne(job, pool.prefix, &pool.results[idx]);
    }
}

/// Runs the clonefile + Mach-O patching + codesign pipeline for one
/// job and stores the result. Thread-safe because each call operates
/// on its own keg path (different name/version) and the cellar
/// module's I/O paths never overlap between jobs.
///
/// Uses a per-call arena for short-lived allocations (walker, patcher
/// buffers, etc.) and `std.heap.c_allocator` for the single long-lived
/// output — the keg path — so it survives arena teardown.
fn materializeOne(
    job: *DownloadJob,
    prefix: []const u8,
    result: *MaterializeResult,
) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const tmp_allocator = arena.allocator();

    const keg = cellar_mod.materializeWithCellar(
        tmp_allocator,
        prefix,
        job.store_sha256,
        job.name,
        job.version_str,
        job.cellar_type,
    ) catch |err| {
        result.* = .{ .ok = false, .keg_path = &[_]u8{}, .err = err };
        return;
    };

    // Dup keg.path to a long-lived thread-safe allocator because the
    // arena is about to deinit.
    const durable_path = std.heap.c_allocator.dupe(u8, keg.path) catch {
        result.* = .{ .ok = false, .keg_path = &[_]u8{}, .err = cellar_mod.CellarError.OutOfMemory };
        return;
    };

    result.* = .{ .ok = true, .keg_path = durable_path, .err = null };
}
