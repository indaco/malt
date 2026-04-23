//! malt — install command
//! Install formulas, casks, or tap formulas.
//! Implements the 9-step atomic install protocol.

const std = @import("std");

const cask_mod = @import("../core/cask.zig");
const cellar_mod = @import("../core/cellar.zig");
const formula_mod = @import("../core/formula.zig");
const linker_mod = @import("../core/linker.zig");
const ruby_sub = @import("../core/ruby_subprocess.zig");
const plist_mod = @import("../core/services/plist.zig");
const supervisor_mod = @import("../core/services/supervisor.zig");
const store_mod = @import("../core/store.zig");
const lock_mod = @import("../db/lock.zig");
const schema = @import("../db/schema.zig");
const sqlite = @import("../db/sqlite.zig");
const atomic = @import("../fs/atomic.zig");
const fs_compat = @import("../fs/compat.zig");
const api_mod = @import("../net/api.zig");
const client_mod = @import("../net/client.zig");
const ghcr_mod = @import("../net/ghcr.zig");
const output = @import("../ui/output.zig");
const progress_mod = @import("../ui/progress.zig");
const help = @import("help.zig");
const args_mod = @import("install/args.zig");
pub const max_prefix_sane_len = args_mod.max_prefix_sane_len;
pub const PrefixError = args_mod.PrefixError;
pub const checkPrefixSane = args_mod.checkPrefixSane;
pub const isTapFormula = args_mod.isTapFormula;
pub const isLocalFormulaPath = args_mod.isLocalFormulaPath;
pub const parseTapName = args_mod.parseTapName;
pub const isAllowedArchiveUrl = args_mod.isAllowedArchiveUrl;
pub const interpolateVersion = args_mod.interpolateVersion;
pub const expandTildePath = args_mod.expandTildePath;
const download_mod = @import("install/download.zig");
pub const DownloadJob = download_mod.DownloadJob;
pub const MAX_COLLECT_FETCH_WORKERS = download_mod.MAX_COLLECT_FETCH_WORKERS;
pub const collectFetchWorkerCount = download_mod.collectFetchWorkerCount;
pub const collectFormulaJobs = download_mod.collectFormulaJobs;
pub const findFailedDep = download_mod.findFailedDep;
const progressBridge = download_mod.progressBridge;
const downloadWorker = download_mod.downloadWorker;
const MaterializeResult = download_mod.MaterializeResult;
const MaterializePool = download_mod.MaterializePool;
const materializePoolWorker = download_mod.materializePoolWorker;
const ghcr_url_mod = @import("install/ghcr_url.zig");
pub const GhcrRef = ghcr_url_mod.GhcrRef;
pub const parseGhcrUrl = ghcr_url_mod.parseGhcrUrl;
pub const buildGhcrRepo = ghcr_url_mod.buildGhcrRepo;
const local_mod = @import("install/local.zig");
pub const max_local_formula_bytes = local_mod.max_local_formula_bytes;
pub const LocalPermissionRisk = local_mod.LocalPermissionRisk;
pub const describeLocalPermissionRisk = local_mod.describeLocalPermissionRisk;
pub const RubyFormulaInfo = local_mod.RubyFormulaInfo;
pub const parseRubyFormula = local_mod.parseRubyFormula;
pub const extractQuoted = local_mod.extractQuoted;
const installTapFormula = local_mod.installTapFormula;
const installLocalFormula = local_mod.installLocalFormula;
const post_install_mod = @import("install/post_install.zig");
pub const PostInstallStatus = post_install_mod.PostInstallStatus;
pub const routePostInstallOutcome = post_install_mod.routePostInstallOutcome;
pub const DslPostInstallOutcome = post_install_mod.DslPostInstallOutcome;
pub const executeDslPostInstall = post_install_mod.executeDslPostInstall;
const useSystemRubyForFormula = post_install_mod.useSystemRubyForFormula;
const record_mod = @import("install/record.zig");
pub const InstallError = record_mod.InstallError;
pub const localErrorIsAnnounced = record_mod.localErrorIsAnnounced;
pub const recordKeg = record_mod.recordKeg;
pub const deleteKeg = record_mod.deleteKeg;
pub const recordDeps = record_mod.recordDeps;
pub const isInstalled = record_mod.isInstalled;
pub const ensureDirs = record_mod.ensureDirs;
pub const constantTimeEql = record_mod.constantTimeEql;

pub const InstallAllOpts = struct {
    /// Treat every package as a cask; equivalent to `--cask`.
    cask: bool = false,
};

/// Non-argv primitive used by `core/bundle/runner.zig` via its injected
/// `Dispatcher`. Argv parsing stays in `execute`; this seam is what lets
/// core/bundle share orchestration without importing `cli/*`.
pub fn installAll(
    allocator: std.mem.Allocator,
    packages: []const []const u8,
    opts: InstallAllOpts,
) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    if (opts.cask) try argv.append(allocator, "--cask");
    for (packages) |p| try argv.append(allocator, p);
    return execute(allocator, argv.items);
}

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "install")) return;

    // Parse flags
    var packages: std.ArrayList([]const u8) = .empty;
    defer packages.deinit(allocator);
    var force_cask = false;
    var force_formula = false;
    // Honour the global `--dry-run` flag consumed by main.zig, while still
    // allowing programmatic callers to pass `--dry-run` directly in `args`.
    var dry_run = output.isDryRun();
    var force = false;
    // `--use-system-ruby` scope: the audit flagged a session-wide flag
    // as an auto-fallback trust widener. We keep the flag ergonomic
    // when a single formula is installed (bare flag implies that
    // formula) but require an explicit `--use-system-ruby=name[,name]`
    // list when multiple formulas are queued, so a DSL parse failure
    // on one never enables Ruby for the rest.
    var use_system_ruby_bare = false;
    var use_system_ruby_scope: std.ArrayList([]const u8) = .empty;
    defer use_system_ruby_scope.deinit(allocator);
    // `--local` forces every positional argument to be interpreted as a
    // path to a `.rb` file. The flag is the explicit opt-in that
    // captures the "I trust this file" decision in argv, rather than
    // leaving it to shape-based autodetection.
    var local_only = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--cask")) {
            force_cask = true;
        } else if (std.mem.eql(u8, arg, "--formula")) {
            force_formula = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--local")) {
            local_only = true;
        } else if (std.mem.eql(u8, arg, "--use-system-ruby")) {
            use_system_ruby_bare = true;
        } else if (std.mem.startsWith(u8, arg, "--use-system-ruby=")) {
            const list = arg["--use-system-ruby=".len..];
            var it = std.mem.splitScalar(u8, list, ',');
            while (it.next()) |name| {
                if (name.len > 0) try use_system_ruby_scope.append(allocator, name);
            }
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            output.setQuiet(true);
        } else if (std.mem.eql(u8, arg, "--json")) {
            output.setMode(.json);
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            packages.append(allocator, arg) catch return error.OutOfMemory;
        }
    }

    if (local_only and packages.items.len == 0) {
        // User-facing argv error — emit the one-liner and exit clean.
        // Returning `error.Aborted` (per the main.zig contract) avoids
        // the "error: LocalFormulaMissingPath" stack trace that raw
        // InstallError variants trigger.
        output.err("--local requires a path to a .rb file", .{});
        return error.Aborted;
    }

    // `--local` conflicts with other mode flags. Rather than silently
    // letting path-shape detection win, refuse ambiguous argv up front
    // so "install --local --cask ./foo.rb" cannot quietly drop the
    // cask pathway or vice versa.
    if (local_only) {
        if (force_cask) {
            output.err("--local cannot be combined with --cask (a .rb file is never a cask)", .{});
            return error.Aborted;
        }
        if (force_formula) {
            output.err("--local already selects formula mode; drop --formula", .{});
            return error.Aborted;
        }
        if (use_system_ruby_bare or use_system_ruby_scope.items.len > 0) {
            output.err("--local does not run post_install; --use-system-ruby has no effect and is refused", .{});
            return error.Aborted;
        }
    }

    if (packages.items.len == 0) {
        output.err("No package names specified", .{});
        return InstallError.NoPackages;
    }

    // Disambiguate bare `--use-system-ruby`: accept it as shorthand
    // when exactly one formula was listed; otherwise the user must
    // name which formulas should get the wider path.
    if (use_system_ruby_bare) {
        if (packages.items.len == 1) {
            try use_system_ruby_scope.append(allocator, packages.items[0]);
        } else {
            output.err(
                "--use-system-ruby needs a scope when multiple packages are installed; use --use-system-ruby={s}[,<name>...]",
                .{packages.items[0]},
            );
            return InstallError.AmbiguousSystemRubyScope;
        }
    }
    const use_system_ruby_list: []const []const u8 = use_system_ruby_scope.items;

    // Initialize infrastructure
    const prefix = atomic.maltPrefix();

    // Sanity cap: refuse absurdly long prefixes before any network
    // activity. Realistic values sail through — install_name_tool grows
    // overflowing load-command slots into the bottle's __LINKEDIT
    // padding.
    checkPrefixSane(prefix) catch |err| switch (err) {
        error.PrefixAbsurd => {
            output.err(
                "MALT_PREFIX '{s}' is {d} bytes, beyond the {d}-byte sanity cap.",
                .{ prefix, prefix.len, max_prefix_sane_len },
            );
            output.err("Set MALT_PREFIX to a reasonable path and retry.", .{});
            return InstallError.PrefixAbsurd;
        },
    };

    // Ensure required directories exist (Step 0)
    ensureDirs(prefix) catch return error.Aborted;

    // Open database
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrint(&db_path_buf, "{s}/db/malt.db", .{prefix}) catch
        return InstallError.DatabaseError;
    var db = sqlite.Database.open(db_path) catch {
        output.err("Failed to open database at {s}", .{db_path});
        return InstallError.DatabaseError;
    };
    defer db.close();

    // Initialize schema
    schema.initSchema(&db) catch {
        output.err("Failed to initialize database schema", .{});
        return InstallError.DatabaseError;
    };

    // Acquire lock (Step 1)
    var lock_path_buf: [512]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_path_buf, "{s}/db/malt.lock", .{prefix}) catch
        return InstallError.LockError;
    var lk = lock_mod.LockFile.acquire(lock_path, 30000) catch {
        output.err("Another mt process is running. Wait or run mt doctor.", .{});
        return InstallError.LockError;
    };
    defer lk.release();

    // Set up HTTP client (single-threaded main-thread use — formula
    // lookups, cask probe, top-level `fetchFormula`). Worker threads
    // borrow from the pool below instead of touching this instance.
    var http = client_mod.HttpClient.init(allocator);
    defer http.deinit();

    // Shared HTTP client pool for worker threads. Each worker
    // (download + parallel resolve) borrows an idle client for the
    // duration of one request so TLS contexts are reused across
    // calls. 4 slots is the same budget the P5 materialize pool uses
    // and is enough to saturate cold installs on typical machines.
    var http_pool = client_mod.HttpClientPool.init(allocator, 4) catch {
        output.err("Failed to initialise HTTP client pool", .{});
        return InstallError.DownloadFailed;
    };
    defer http_pool.deinit();

    // Set up API client
    var cache_dir_buf: [512]u8 = undefined;
    const cache_dir = std.fmt.bufPrint(&cache_dir_buf, "{s}/cache", .{prefix}) catch return;
    var api = api_mod.BrewApi.init(allocator, &http, cache_dir);

    // Set up GHCR client
    var ghcr = ghcr_mod.GhcrClient.init(allocator, &http);
    defer ghcr.deinit();

    // Set up store + linker
    var store = store_mod.Store.init(allocator, &db, prefix);
    var linker = linker_mod.Linker.init(allocator, &db, prefix);

    // ── Collect all download jobs across all packages ────────────────
    var all_jobs: std.ArrayList(DownloadJob) = .empty;
    defer all_jobs.deinit(allocator);

    // Check for Ctrl-C before resolution phase
    const main_mod = @import("../main.zig");
    if (main_mod.isInterrupted()) {
        output.warn("Interrupted before resolution.", .{});
        return;
    }

    for (packages.items) |pkg_name| {
        // Check for Ctrl-C between packages during resolution
        if (main_mod.isInterrupted()) {
            output.warn("Interrupted during resolution.", .{});
            return;
        }

        // Local .rb path (explicit via --local, or shape-detected — a
        // leading `.`/`/`/`~` or embedded slash plus a `.rb` suffix).
        // Path wins over tap-form when `.rb` is present so a typo like
        // `user/repo/foo.rb` gets a clean local-file error instead of
        // a confusing GitHub 404.
        if (local_only or isLocalFormulaPath(pkg_name)) {
            installLocalFormula(allocator, pkg_name, &db, &linker, prefix, dry_run, force) catch |e| {
                // The inner function has already emitted a specific
                // error line (missing file, insecure URL, parse
                // failure, …). Only append the generic summary for
                // errors whose internal message didn't cover the
                // "what" — keeps single-package failures from printing
                // two red lines for one problem.
                if (!localErrorIsAnnounced(e)) {
                    output.err("Failed to install {s}: {s}", .{ pkg_name, @errorName(e) });
                }
            };
            continue;
        }

        // Handle tap formulas separately (they don't use GHCR)
        if (isTapFormula(pkg_name)) {
            installTapFormula(allocator, pkg_name, &db, &linker, prefix, dry_run, force) catch |e| {
                output.err("Failed to install {s}: {s}", .{ pkg_name, @errorName(e) });
            };
            continue;
        }

        // Try formula
        if (!force_cask) {
            const formula_json = api.fetchFormula(pkg_name) catch {
                if (force_formula) {
                    output.err("Formula '{s}' not found", .{pkg_name});
                    continue;
                }
                // Try cask
                installCask(allocator, pkg_name, &db, &api, dry_run) catch |e| {
                    output.err("Failed to install {s}: {s}", .{ pkg_name, @errorName(e) });
                };
                continue;
            };

            // Check if name also exists as a cask — warn about ambiguity
            if (!force_formula) {
                if (api.fetchCask(pkg_name)) |cask_json| {
                    allocator.free(cask_json);
                    output.info("{s} exists as both a formula and a cask. Installing formula. Use --cask to install the cask instead.", .{pkg_name});
                } else |_| {}
            }

            // Collect jobs for this formula + its deps
            collectFormulaJobs(allocator, pkg_name, formula_json, &api, &http_pool, &db, &store, force, &all_jobs) catch |e| {
                output.err("Failed to resolve {s}: {s}", .{ pkg_name, @errorName(e) });
                continue;
            };
        } else {
            installCask(allocator, pkg_name, &db, &api, dry_run) catch |e| {
                output.err("Failed to install {s}: {s}", .{ pkg_name, @errorName(e) });
            };
        }
    }

    if (all_jobs.items.len == 0) return;

    if (dry_run) {
        output.info("Dry run: would install {d} package(s):", .{all_jobs.items.len});
        for (all_jobs.items) |job| {
            const tag: []const u8 = if (job.is_dep) " (dependency)" else "";
            output.info("  {s} {s}{s}", .{ job.name, job.version_str, tag });
        }
        return;
    }

    // ── Parallel download phase ──────────────────────────────────────

    // Compute max label width for aligned progress bars
    var max_name_len: u8 = 0;
    for (all_jobs.items) |job| {
        const len: u8 = @intCast(@min(job.name.len, 255));
        if (len > max_name_len) max_name_len = len;
    }
    for (all_jobs.items) |*job| {
        job.label_width = max_name_len;
    }

    var to_download: u32 = 0;
    for (all_jobs.items) |*job| {
        if (store.exists(job.sha256)) {
            job.store_sha256 = job.sha256;
            job.succeeded = true;
        } else {
            to_download += 1;
        }
    }

    if (to_download > 0) {
        if (to_download == 1) {
            output.info("Downloading 1 bottle...", .{});
        } else {
            output.info("Downloading {d} bottles...", .{to_download});
        }

        // GHCR token prefetch: fold every distinct repo in the batch
        // into a single multi-scope `/token` round-trip so each
        // download worker hits the cache instead of racing its own
        // token fetch. On a 12-dep install this turns 12 sequential
        // token round-trips into 1. `prefetchTokens` is best-effort;
        // on any error we leave the cache empty and workers fall back
        // to per-repo fetches (the old behaviour, one round-trip each).
        // OOM during prefetch bookkeeping must not be swallowed: subsequent
        // install phases depend on allocator integrity. Token prefetch itself
        // stays best-effort — a cache miss falls back to per-worker fetches.
        var repo_set: std.StringHashMapUnmanaged(void) = .empty;
        defer repo_set.deinit(allocator);
        for (all_jobs.items) |*job| {
            if (job.succeeded) continue;
            const ref = parseGhcrUrl(job.bottle_url) orelse continue;
            try repo_set.put(allocator, ref.repo, {});
        }
        if (repo_set.count() > 0) {
            var repos: std.ArrayList([]const u8) = .empty;
            defer repos.deinit(allocator);
            try repos.ensureTotalCapacity(allocator, repo_set.count());
            var it = repo_set.keyIterator();
            while (it.next()) |k| try repos.append(allocator, k.*);
            const pre_http = http_pool.acquire();
            // Best-effort cache warm — any failure (OOM or network) is
            // absorbed so workers fall back to per-repo fetchToken calls.
            ghcr.prefetchTokens(pre_http, repos.items) catch {};
            http_pool.release(pre_http);
        }

        // Set up multi-progress: assign line indices and create coordinator
        var download_index: u8 = 0;
        for (all_jobs.items) |*job| {
            if (!job.succeeded) {
                job.line_index = download_index;
                download_index += 1;
            }
        }
        var multi = progress_mod.MultiProgress.init(download_index);

        // Allocate all progress bars in the main thread so we can render an
        // initial frame on every reserved line BEFORE spawning workers. This
        // avoids a blank row when a later worker thread is scheduled before
        // an earlier one. Bars live in a stable slice so the pointers we
        // hand to worker threads remain valid.
        var bars: []progress_mod.ProgressBar = &.{};
        if (allocator.alloc(progress_mod.ProgressBar, download_index)) |s| {
            bars = s;
        } else |_| {}
        defer if (bars.len > 0) allocator.free(bars);

        var bar_idx: usize = 0;
        for (all_jobs.items) |*job| {
            if (job.succeeded) continue;
            job.multi = &multi;
            if (bar_idx < bars.len) {
                bars[bar_idx] = progress_mod.ProgressBar.init(job.name, 0);
                bars[bar_idx].label_width = max_name_len;
                bars[bar_idx].line_index = job.line_index;
                bars[bar_idx].multi = &multi;
                job.bar = &bars[bar_idx];
                // Draw the initial frame now so this line is not blank while
                // the worker is waiting to be scheduled.
                bars[bar_idx].update(0);
                bar_idx += 1;
            }
        }

        var threads: std.ArrayList(std.Thread) = .empty;
        defer threads.deinit(allocator);

        for (all_jobs.items) |*job| {
            if (job.succeeded) {
                continue;
            }
            const t = std.Thread.spawn(.{}, downloadWorker, .{
                allocator, &ghcr, &http_pool, &store, job,
            }) catch {
                downloadWorker(allocator, &ghcr, &http_pool, &store, job);
                continue;
            };
            threads.append(allocator, t) catch {
                t.join();
                continue;
            };
        }

        for (threads.items) |t| t.join();
        multi.finish();
    }

    // Check for Ctrl-C between download and materialize phases
    if (main_mod.isInterrupted()) {
        output.warn("Interrupted. Cleaning up...", .{});
        return;
    }

    // ── Parallel materialize phase ──────────────────────────────────
    //
    // Each materialize step (clonefile + Mach-O patch + codesign) is
    // independent — workers never touch each other's keg paths. Shared
    // state (linker conflict check, SQLite INSERTs, `failed_kegs`) is
    // deferred to the serial link phase below.
    //
    // The old flow ran `materializeAndLink` serially per job, which on
    // cold installs of large formulae like ffmpeg (11 deps) added up to
    // ~3 s of back-to-back materialize work.
    //
    // **Bounded** pool — max 4 workers. Unbounded parallelism (one
    // thread per job) turned into page-cache thrashing and codesign
    // subprocess contention on warm ffmpeg, regressing that workload
    // ~160 ms. Four workers preserves the cold-install speedup (I/O
    // and subprocess wait overlap) while keeping cache pressure low.
    const mats = allocator.alloc(MaterializeResult, all_jobs.items.len) catch
        return InstallError.CellarFailed;
    // Two defers (LIFO): the keg-path loop needs `mats` alive, so free the
    // outer slice last. Splits the two allocator contracts into distinct
    // statements so the reader doesn't have to track which slice came from
    // which allocator.
    defer allocator.free(mats);
    defer for (mats) |m| {
        if (m.keg_path.len > 0) std.heap.c_allocator.free(m.keg_path);
    };
    for (mats) |*m| m.* = .{ .ok = false, .keg_path = &[_]u8{}, .err = null };

    {
        const max_workers: usize = 4;
        const worker_count = @min(max_workers, all_jobs.items.len);

        var pool_ctx: MaterializePool = .{
            .next_idx = std.atomic.Value(usize).init(0),
            .jobs = all_jobs.items,
            .prefix = prefix,
            .results = mats,
        };

        const pool_threads = allocator.alloc(std.Thread, worker_count) catch
            return InstallError.CellarFailed;
        defer allocator.free(pool_threads);

        var spawned: usize = 0;
        for (0..worker_count) |_| {
            if (std.Thread.spawn(.{}, materializePoolWorker, .{&pool_ctx})) |t| {
                pool_threads[spawned] = t;
                spawned += 1;
            } else |_| {
                // Fall back to inline execution if spawn fails. The pool
                // loop will pick up remaining jobs on this thread.
                materializePoolWorker(&pool_ctx);
            }
        }
        for (pool_threads[0..spawned]) |t| t.join();
    }

    // ── Serial link + record phase ──────────────────────────────────
    //
    // Runs in dep order (the jobs list came out of `collectFormulaJobs`
    // dep-sorted) so `findFailedDep` correctly propagates failures down
    // the graph. Linker conflict checks and SQLite writes are not
    // thread-safe, so this phase cannot be parallelised.
    var failed_kegs = std.StringHashMap(void).init(allocator);
    defer failed_kegs.deinit();
    var failed_count: usize = 0;

    for (all_jobs.items, 0..) |*job, i| {
        if (main_mod.isInterrupted()) {
            output.warn("Interrupted. Stopping install.", .{});
            break;
        }

        // OOM on failed-keg bookkeeping must not be swallowed: the subsequent
        // findFailedDep check relies on this map, and a silent drop would
        // let dependents install on top of a broken graph.
        if (!job.succeeded) {
            output.err("Download failed for {s}, skipping", .{job.name});
            try failed_kegs.put(job.name, {});
            failed_count += 1;
            continue;
        }

        if (!mats[i].ok) {
            const err = mats[i].err orelse cellar_mod.CellarError.CloneFailed;
            output.err(
                "Failed to materialize {s}: {s} ({s})",
                .{ job.name, @errorName(err), cellar_mod.describeError(err) },
            );
            try failed_kegs.put(job.name, {});
            failed_count += 1;
            continue;
        }

        // Skip if any runtime dep has already failed — installing on top of a
        // broken dep graph produces a keg that dyld cannot resolve at runtime.
        // The keg has already been materialised into the Cellar by a worker;
        // remove it before continuing so we do not leave orphans behind.
        if (findFailedDep(&failed_kegs, job.formula_json)) |failed_dep| {
            output.warn(
                "Skipping {s}: dependency {s} failed to install",
                .{ job.name, failed_dep },
            );
            cellar_mod.remove(prefix, job.name, job.version_str) catch {};
            try failed_kegs.put(job.name, {});
            failed_count += 1;
            continue;
        }

        linkAndRecord(allocator, job, mats[i].keg_path, &db, &linker, prefix) catch {
            // The underlying error was already logged with a tag by
            // linkAndRecord — just record that this job failed so its
            // dependents in the rest of the loop get skipped above.
            try failed_kegs.put(job.name, {});
            failed_count += 1;
            continue;
        };

        // Execute post_install: try DSL interpreter first, fall back to
        // system Ruby subprocess when --use-system-ruby is set.
        if (job.post_install_defined) post_install: {
            // Locate a DSL source: local tap first, GitHub fetch second.
            const dsl_src: ?[]const u8 = blk: {
                const tap_path = ruby_sub.findHomebrewCoreTap();
                var rb_buf: [1024]u8 = undefined;
                const rb_path = if (tap_path) |tp|
                    ruby_sub.resolveFormulaRbPath(&rb_buf, tp, job.name)
                else
                    null;
                if (rb_path) |sp| {
                    if (ruby_sub.extractPostInstallBody(allocator, sp)) |s| break :blk s;
                }
                break :blk ruby_sub.fetchPostInstallFromGitHub(allocator, job.name);
            };

            if (dsl_src) |src| {
                defer allocator.free(src);
                switch (executeDslPostInstall(allocator, job, src, prefix, use_system_ruby_list)) {
                    .handled => break :post_install,
                    // parse_failed leaves the DSL path unusable — fall through
                    // so the system-Ruby fallback still has a chance to run.
                    .parse_failed => {},
                }
            }

            // No usable DSL source — fall back to subprocess or skip.
            if (useSystemRubyForFormula(use_system_ruby_list, job.name)) {
                output.warn("Running post_install for {s} via system Ruby...", .{job.name});
                ruby_sub.runPostInstall(allocator, job.name, job.version_str, prefix) catch |e| {
                    output.warn("post_install failed for {s}: {s}", .{ job.name, @errorName(e) });
                };
            } else {
                output.warn("{s}: post_install skipped (use --use-system-ruby={s} or brew install {s})", .{ job.name, job.name, job.name });
            }
        }
    }

    if (failed_count > 0) {
        const pkg_word: []const u8 = if (failed_count == 1) "package" else "packages";
        output.err(
            "{d} {s} failed to install. See errors above.",
            .{ failed_count, pkg_word },
        );
        return InstallError.PartialFailure;
    }
}

/// Main-thread link + record phase for a single job that already had
/// its bottle materialised into the Cellar by a worker. Parses the
/// formula JSON, checks symlink conflicts, creates symlinks, and
/// writes the keg + dependency rows into the DB.
///
/// Must run serially — linker conflict checking reads the current
/// symlink state and SQLite writes are not safe from multiple writers.
fn linkAndRecord(
    allocator: std.mem.Allocator,
    job: *DownloadJob,
    keg_path: []const u8,
    db: *sqlite.Database,
    linker: *linker_mod.Linker,
    prefix: []const u8,
) !void {
    const reason: []const u8 = if (job.is_dep) "dependency" else "direct";

    // Parse formula for DB recording
    var formula = formula_mod.parseFormula(allocator, job.formula_json) catch |err| {
        output.err("Failed to parse formula for {s}: {s}", .{ job.name, @errorName(err) });
        cellar_mod.remove(prefix, job.name, job.version_str) catch {};
        return InstallError.CellarFailed;
    };
    defer formula.deinit();

    // Check for symlink conflicts before linking
    if (!job.keg_only) {
        const conflicts = linker.checkConflicts(keg_path) catch &.{};
        if (conflicts.len > 0) {
            output.err("{s}: {d} symlink conflict(s) detected:", .{ job.name, conflicts.len });
            for (conflicts) |conflict| {
                output.err("  {s} already linked by {s}", .{ conflict.link_path, conflict.existing_keg });
            }
            output.err("Use --force to overwrite, or uninstall the conflicting package first.", .{});
            cellar_mod.remove(prefix, job.name, job.version_str) catch {};
            return InstallError.LinkFailed;
        }
    }

    // Link + record
    if (!job.keg_only) {
        const keg_id = recordKeg(db, &formula, job.store_sha256, keg_path, reason) catch |err| {
            output.err("Failed to record {s} in database: {s}", .{ job.name, @errorName(err) });
            cellar_mod.remove(prefix, job.name, job.version_str) catch {};
            return InstallError.RecordFailed;
        };

        linker.link(keg_path, job.name, keg_id) catch |err| {
            output.err("Failed to link {s}: {s}", .{ job.name, @errorName(err) });
            // Rollback: unlink what was partially created + remove DB record + cellar
            linker.unlink(keg_id) catch {};
            deleteKeg(db, keg_id);
            cellar_mod.remove(prefix, job.name, job.version_str) catch {};
            return InstallError.LinkFailed;
        };
        linker.linkOpt(job.name, job.version_str) catch {};
        recordDeps(db, keg_id, &formula);
    } else {
        const keg_id = recordKeg(db, &formula, job.store_sha256, keg_path, reason) catch |err| {
            output.err("Failed to record {s} in database: {s}", .{ job.name, @errorName(err) });
            cellar_mod.remove(prefix, job.name, job.version_str) catch {};
            return InstallError.RecordFailed;
        };
        linker.linkOpt(job.name, job.version_str) catch {};
        recordDeps(db, keg_id, &formula);
    }
    maybeRegisterService(allocator, db, &formula, prefix);
    // Annotate keg-only packages inline so the single line reads as success,
    // not as a "not linking" warning paired with a separate ✓.
    const keg_only_suffix: []const u8 = if (job.keg_only) " (keg-only — dependency only)" else "";
    output.success("{s} {s} installed{s}", .{ job.name, job.version_str, keg_only_suffix });
}

/// Register a launchd service when the formula carries a `service:` block.
/// Best-effort: failures only emit a warning so they don't fail the install.
/// Path validation (interpreter bait, path escape, argv caps) is run
/// inside `supervisor.register` against the formula's cellar + the
/// install prefix.
fn maybeRegisterService(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    formula: *const formula_mod.Formula,
    prefix: []const u8,
) void {
    const def = formula.service orelse return;
    if (def.run.len == 0) return;

    var label_buf: [256]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "com.malt.{s}", .{formula.name}) catch return;

    var stdout_buf: [512]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    const stdout_path = def.log_path orelse
        (std.fmt.bufPrint(&stdout_buf, "{s}/var/log/{s}.out", .{ prefix, formula.name }) catch return);
    const stderr_path = def.error_log_path orelse
        (std.fmt.bufPrint(&stderr_buf, "{s}/var/log/{s}.err", .{ prefix, formula.name }) catch return);

    // Ensure the log directory exists.
    var log_dir_buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&log_dir_buf, "{s}/var/log", .{prefix})) |dir| {
        fs_compat.cwd().makePath(dir) catch {};
    } else |_| {}

    var cellar_buf: [512]u8 = undefined;
    const cellar_path = std.fmt.bufPrint(
        &cellar_buf,
        "{s}/Cellar/{s}/{s}",
        .{ prefix, formula.name, formula.pkg_version },
    ) catch return;

    const spec: plist_mod.ServiceSpec = .{
        .label = label,
        .program_args = def.run,
        .working_dir = def.working_dir,
        .stdout_path = stdout_path,
        .stderr_path = stderr_path,
        .run_at_load = def.run_at_load,
        .keep_alive = def.keep_alive,
    };

    supervisor_mod.register(allocator, db, spec, formula.name, false, cellar_path, prefix) catch |err| {
        output.warn("could not register service for {s}: {s}", .{ formula.name, @errorName(err) });
    };
}

/// HEAD-based fallback for extensionless cask URLs.
/// Follows redirects to discover the real file extension.
fn resolveCaskArtifactViaHead(allocator: std.mem.Allocator, url: []const u8) cask_mod.ArtifactType {
    var http = client_mod.HttpClient.init(allocator);
    defer http.deinit();

    var resolved = http.headResolved(url) catch return .unknown;
    defer resolved.deinit();

    return cask_mod.resolveArtifactType(allocator, resolved.final_url, resolved.content_disposition);
}

/// Install a cask (DMG, ZIP, or PKG).
fn installCask(
    allocator: std.mem.Allocator,
    token: []const u8,
    db: *sqlite.Database,
    api: *api_mod.BrewApi,
    dry_run: bool,
) !void {
    const cask_json = api.fetchCask(token) catch {
        output.err("Cask '{s}' not found", .{token});
        return InstallError.CaskNotFound;
    };
    defer allocator.free(cask_json);

    var cask = cask_mod.parseCask(allocator, cask_json) catch {
        output.err("Failed to parse cask JSON for '{s}'", .{token});
        return InstallError.CaskNotFound;
    };
    defer cask.deinit();

    // Check if already installed
    if (cask_mod.isInstalled(db, cask.token)) {
        output.info("{s} is already installed", .{cask.token});
        return;
    }

    var artifact_type = cask_mod.artifactTypeFromUrl(cask.url);

    // Extensionless URLs (e.g. download APIs that 302 to the real file):
    // resolve via HEAD to discover the final URL and Content-Disposition.
    if (artifact_type == .unknown) {
        artifact_type = resolveCaskArtifactViaHead(allocator, cask.url);
    }

    if (dry_run) {
        output.info("Dry run: would install cask {s} {s} ({s})", .{
            cask.token,
            cask.version,
            @tagName(artifact_type),
        });
        return;
    }

    if (artifact_type == .unknown) {
        output.err("Unsupported cask format for '{s}' — URL: {s}", .{ cask.token, cask.url });
        output.err("malt supports .dmg, .zip, and .pkg casks. Use: brew install --cask {s}", .{cask.token});
        return InstallError.CaskNotFound;
    }

    // Warn for PKG casks (require sudo)
    if (artifact_type == .pkg) {
        output.warn("{s} is a PKG cask and requires sudo to install via macOS Installer.", .{cask.token});
    }

    output.info("Installing cask {s} {s}...", .{ cask.token, cask.version });

    const prefix = atomic.maltPrefix();
    var installer = cask_mod.CaskInstaller.init(allocator, db, prefix);
    installer.artifact_type_override = artifact_type;

    // Progress bar for cask download
    var bar = progress_mod.ProgressBar.init(cask.token, 0);
    installer.progress = .{
        .context = @ptrCast(&bar),
        .func = &progressBridge,
    };

    const app_path = installer.install(&cask) catch |e| {
        bar.finish();
        // Surface the specific cause (Sha256Mismatch, DownloadFailed, …) —
        // users can't act on a bare "failed to install".
        output.err("Failed to install cask {s}: {s}", .{ cask.token, @errorName(e) });
        return InstallError.CaskNotFound;
    };
    bar.finish();

    // Record in DB with install path
    cask_mod.recordInstall(db, &cask, app_path) catch {
        output.warn("Failed to record cask {s} in database", .{cask.token});
    };
    allocator.free(app_path);

    output.success("{s} {s} installed", .{ cask.token, cask.version });
}
