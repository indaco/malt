//! malt — install command
//! Install formulas, casks, or tap formulas.
//! Implements the 9-step atomic install protocol.

const std = @import("std");
const fs_compat = @import("../fs/compat.zig");
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const lock_mod = @import("../db/lock.zig");
const formula_mod = @import("../core/formula.zig");
const cask_mod = @import("../core/cask.zig");
const bottle_mod = @import("../core/bottle.zig");
const store_mod = @import("../core/store.zig");
const cellar_mod = @import("../core/cellar.zig");
const deps_mod = @import("../core/deps.zig");
const linker_mod = @import("../core/linker.zig");
const client_mod = @import("../net/client.zig");
const ghcr_mod = @import("../net/ghcr.zig");
const api_mod = @import("../net/api.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const io_mod = @import("../ui/io.zig");
const progress_mod = @import("../ui/progress.zig");
const ruby_sub = @import("../core/ruby_subprocess.zig");
const tap_mod = @import("../core/tap.zig");
const dsl = @import("../core/dsl/root.zig");
const supervisor_mod = @import("../core/services/supervisor.zig");
const plist_mod = @import("../core/services/plist.zig");
const help = @import("help.zig");

/// Maximum safe byte length for MALT_PREFIX.
///
/// Homebrew bottles hard-code `/opt/homebrew` (13 bytes) in LC_LOAD_DYLIB
/// load-command paths. `malt` rewrites that prefix in place during
/// materialize, and the replacement path must not be longer than the
/// original or the load command will not fit its pre-allocated slot and
/// dyld will refuse to load the binary.
///
/// Keeping MALT_PREFIX ≤ 13 bytes guarantees the rewrite always fits,
/// matching the rationale called out in README.md (§"Directory Layout").
pub const max_prefix_len: usize = "/opt/homebrew".len;

pub const PrefixError = error{PrefixTooLong};

/// Refuse to proceed when MALT_PREFIX exceeds `max_prefix_len`. Exposed so
/// `mt doctor` can reuse the same rule.
/// Parsed `<repo>@<digest>` reference from a GHCR blob URL.
/// Both fields are slices into the input URL — no allocation; valid
/// for the lifetime of the caller's string.
pub const GhcrRef = struct {
    repo: []const u8,
    digest: []const u8,
};

/// Split a `https://ghcr.io/v2/<repo>/blobs/<digest>` URL into its
/// `<repo>` and `<digest>` parts, returning `null` if the URL is not
/// in that shape. Exposed so the install-phase token prefetch and the
/// per-worker blob download parse identically — a single pure helper
/// prevents the two code paths from drifting apart.
pub fn parseGhcrUrl(url: []const u8) ?GhcrRef {
    const prefix = "https://ghcr.io/v2/";
    if (!std.mem.startsWith(u8, url, prefix)) return null;
    const path = url[prefix.len..];
    const blobs_pos = std.mem.find(u8, path, "/blobs/") orelse return null;
    return .{
        .repo = path[0..blobs_pos],
        .digest = path[blobs_pos + "/blobs/".len ..],
    };
}

pub fn checkPrefixLength(prefix: []const u8) PrefixError!void {
    if (prefix.len > max_prefix_len) return error.PrefixTooLong;
}

pub const InstallError = error{
    NoPackages,
    DatabaseError,
    LockError,
    FormulaNotFound,
    CaskNotFound,
    NoBottle,
    DownloadFailed,
    StoreFailed,
    CellarFailed,
    LinkFailed,
    RecordFailed,
    /// At least one package in a multi-package install failed to materialize
    /// or was skipped because an ancestor dep failed. Returned from `execute`
    /// so `main` exits non-zero.
    PartialFailure,
    /// MALT_PREFIX is longer than the Mach-O in-place patching budget. Set
    /// before any network activity so the user can fix it without waiting on
    /// a multi-gigabyte download that will inevitably fail.
    PrefixTooLong,
    /// Formula defines a Ruby `post_install` hook that malt cannot execute.
    /// Raised before any dep resolution or job queueing so nothing is
    /// downloaded, materialised, or linked for the affected package.
    PostInstallUnsupported,
    /// `--use-system-ruby` used with multiple formulas and no explicit
    /// scope list. The flag widens the trust boundary (runs full Ruby
    /// with only OS-level sandboxing), so malt requires the user to
    /// name which formulas it should apply to when ambiguity exists.
    AmbiguousSystemRubyScope,
    /// `--local <path>` named a file that does not exist, is not a
    /// regular file, or cannot be opened. Raised before parse so the
    /// user sees the real filesystem error instead of a parser message.
    LocalFormulaNotReadable,
    /// The `.rb`'s archive URL is not `https://`. Refusing to fetch
    /// means a malicious or accidentally-committed `file://`,
    /// `ftp://`, or plaintext `http://` URL cannot be turned into an
    /// exploit just by `malt install --local`-ing the file.
    InsecureArchiveUrl,
};

/// Whether --use-system-ruby opts the named formula into the Ruby
/// post_install path. Caller carries the parsed scope from the flag.
fn useSystemRubyForFormula(scope: []const []const u8, formula_name: []const u8) bool {
    for (scope) |n| if (std.mem.eql(u8, n, formula_name)) return true;
    return false;
}

/// Post_install outcome status — surfaced to users as human text and
/// to scripted consumers as JSON when `--json` is set.
pub const PostInstallStatus = enum {
    completed,
    partially_skipped,
    ran_via_ruby,
    ruby_fallback_failed,
    fatal,
};

/// Route the post_install outcome using the fallback log as the single
/// source of truth. "completed" means zero logged entries; any
/// unknown_method / unsupported_node downgrades to the same
/// `--use-system-ruby` suggestion we show on execute-time failures so
/// users never see "completed" when statements were silently skipped.
///
/// Under `--verbose`, the skipped entries are dumped so users can tell
/// WHICH helpers fell through. Under `--json`, a single status line is
/// emitted to stdout for scripted pipelines.
///
/// Pub so the install-pure tests can drive it with a synthetic flog and
/// pin the exact output for every branch.
pub fn routePostInstallOutcome(
    allocator: std.mem.Allocator,
    name: []const u8,
    version_str: []const u8,
    prefix: []const u8,
    flog: *const dsl.FallbackLog,
    use_system_ruby_list: []const []const u8,
) void {
    const status: PostInstallStatus = blk: {
        if (flog.hasFatal()) {
            output.warn("post_install DSL failed for {s} (fatal)", .{name});
            flog.printFatal(name);
            // `--debug` also surfaces the non-fatal context so a bug
            // report includes every reason the DSL logged, not just the
            // one that aborted execution.
            if (output.isDebug()) flog.printUnknown(name);
            break :blk .fatal;
        }
        if (!flog.hasErrors()) {
            output.info("post_install completed for {s}", .{name});
            break :blk .completed;
        }
        if (useSystemRubyForFormula(use_system_ruby_list, name)) {
            output.warn("post_install DSL incomplete for {s}, falling back to system Ruby...", .{name});
            if (output.isVerbose()) flog.printUnknown(name);
            if (output.isDebug()) flog.printFatal(name);
            ruby_sub.runPostInstall(allocator, name, version_str, prefix) catch |e| {
                output.warn("post_install subprocess failed for {s}: {s}", .{ name, @errorName(e) });
                break :blk .ruby_fallback_failed;
            };
            // Symmetric with the native "completed" info so scripted users
            // see a positive signal when the Ruby escape hatch succeeded.
            output.info("post_install completed for {s} (via system Ruby)", .{name});
            break :blk .ran_via_ruby;
        }
        output.warn("{s}: post_install partially skipped (use --use-system-ruby={s} to attempt via Ruby)", .{ name, name });
        if (output.isVerbose()) flog.printUnknown(name);
        if (output.isDebug()) flog.printFatal(name);
        break :blk .partially_skipped;
    };

    if (output.isJson()) emitPostInstallJson(allocator, name, status, flog);
}

/// Write one JSON line per post_install routing decision to stdout. One
/// line per package keeps the stream pipe-friendly (`jq -c`, line-split).
fn emitPostInstallJson(
    allocator: std.mem.Allocator,
    name: []const u8,
    status: PostInstallStatus,
    flog: *const dsl.FallbackLog,
) void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll("{\"event\":\"post_install\",\"name\":") catch return;
    output.jsonStr(w, name) catch return;
    w.writeAll(",\"status\":\"") catch return;
    w.writeAll(@tagName(status)) catch return;
    w.writeAll("\",\"entries\":") catch return;
    const entries_json = flog.toJson(allocator) catch return;
    defer allocator.free(entries_json);
    w.writeAll(entries_json) catch return;
    w.writeAll("}\n") catch return;
    io_mod.stdoutWriteAll(aw.written());
}

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
fn progressBridge(ctx: *anyopaque, bytes_so_far: u64, content_length: ?u64) void {
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
fn downloadWorker(
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
    const ref = parseGhcrUrl(job.bottle_url) orelse return;
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

    // Download with transient-failure retry.
    // GHCR CDN occasionally returns truncated responses or drops connections
    // under parallel load (21-dep installs like `node` can trigger this).
    // Retry up to 3 times with exponential backoff (100ms, 400ms) before giving up.
    const max_attempts: u8 = 3;
    const retry_delays_ms = [_]u64{ 100, 400 };
    var dl_attempt: u8 = 0;
    var dl_ok = false;
    while (dl_attempt < max_attempts) : (dl_attempt += 1) {
        if (bottle_mod.download(allocator, ghcr, http, repo, digest, job.sha256, tmp_dir, progress_cb)) |_| {
            dl_ok = true;
            break;
        } else |_| {
            // Wipe the partial tmp and retry
            atomic.cleanupTempDir(tmp_dir);
            if (dl_attempt + 1 < max_attempts) {
                fs_compat.sleepNanos(retry_delays_ms[dl_attempt] * std.time.ns_per_ms);
            }
        }
    }
    if (!dl_ok) {
        bar.finish();
        output.err("  Download failed: {s} (after {d} attempts)", .{ job.name, max_attempts });
        allocator.free(tmp_dir);
        // Thread worker: caller inspects DownloadJob.success rather than
        // receiving an error — exit the worker, let the coordinator abort.
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

    // Pre-flight: refuse the install if MALT_PREFIX is longer than the
    // Mach-O in-place patching budget. We catch this BEFORE any network
    // activity so users do not spend minutes downloading bottles that are
    // guaranteed to fail at patch time.
    checkPrefixLength(prefix) catch |err| switch (err) {
        error.PrefixTooLong => {
            output.err(
                "MALT_PREFIX '{s}' is {d} bytes, which exceeds the {d}-byte budget for Mach-O in-place patching.",
                .{ prefix, prefix.len, max_prefix_len },
            );
            output.err("Homebrew bottles hard-code `/opt/homebrew` (13 bytes) in LC_LOAD_DYLIB", .{});
            output.err("entries, and malt replaces that prefix in place — the replacement must", .{});
            output.err("not be longer or dyld will fail to load the binaries at runtime.", .{});
            output.err("Set MALT_PREFIX to a shorter path (e.g. /opt/malt or /tmp/mt) and retry.", .{});
            return InstallError.PrefixTooLong;
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
        var repo_set: std.StringHashMapUnmanaged(void) = .empty;
        defer repo_set.deinit(allocator);
        for (all_jobs.items) |*job| {
            if (job.succeeded) continue;
            const ref = parseGhcrUrl(job.bottle_url) orelse continue;
            repo_set.put(allocator, ref.repo, {}) catch {};
        }
        if (repo_set.count() > 0) {
            var repos: std.ArrayList([]const u8) = .empty;
            defer repos.deinit(allocator);
            repos.ensureTotalCapacity(allocator, repo_set.count()) catch {};
            var it = repo_set.keyIterator();
            while (it.next()) |k| repos.append(allocator, k.*) catch {};
            const pre_http = http_pool.acquire();
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
    defer {
        for (mats) |m| {
            if (m.keg_path.len > 0) std.heap.c_allocator.free(m.keg_path);
        }
        allocator.free(mats);
    }
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

        if (!job.succeeded) {
            output.err("Download failed for {s}, skipping", .{job.name});
            failed_kegs.put(job.name, {}) catch {};
            failed_count += 1;
            continue;
        }

        if (!mats[i].ok) {
            const err = mats[i].err orelse cellar_mod.CellarError.CloneFailed;
            output.err(
                "Failed to materialize {s}: {s} ({s})",
                .{ job.name, @errorName(err), cellar_mod.describeError(err) },
            );
            failed_kegs.put(job.name, {}) catch {};
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
            failed_kegs.put(job.name, {}) catch {};
            failed_count += 1;
            continue;
        }

        linkAndRecord(allocator, job, mats[i].keg_path, &db, &linker, prefix) catch {
            // The underlying error was already logged with a tag by
            // linkAndRecord — just record that this job failed so its
            // dependents in the rest of the loop get skipped above.
            failed_kegs.put(job.name, {}) catch {};
            failed_count += 1;
            continue;
        };

        // Execute post_install: try DSL interpreter first, fall back to
        // system Ruby subprocess when --use-system-ruby is set.
        if (job.post_install_defined) post_install: {
            // Try to locate the .rb source file for DSL extraction
            const tap_path = ruby_sub.findHomebrewCoreTap();
            var rb_buf: [1024]u8 = undefined;
            const rb_path = if (tap_path) |tp| ruby_sub.resolveFormulaRbPath(&rb_buf, tp, job.name) else null;

            if (rb_path) |src_path| {
                if (ruby_sub.extractPostInstallBody(allocator, src_path)) |post_install_src| {
                    defer allocator.free(post_install_src);

                    var formula = formula_mod.parseFormula(allocator, job.formula_json) catch {
                        output.warn("post_install: failed to parse formula for {s}", .{job.name});
                        break :post_install;
                    };
                    defer formula.deinit();

                    var flog = dsl.FallbackLog.init(allocator);
                    defer flog.deinit();

                    // Error from execute is already reflected in `flog`;
                    // the outcome router uses the log as the source of
                    // truth so silent-skips downgrade the same as hard
                    // failures instead of reading as "completed".
                    dsl.executePostInstall(allocator, &formula, post_install_src, prefix, &flog) catch {};
                    routePostInstallOutcome(allocator, job.name, job.version_str, prefix, &flog, use_system_ruby_list);
                    break :post_install;
                }
            }

            // No local .rb source — try fetching from GitHub
            if (ruby_sub.fetchPostInstallFromGitHub(allocator, job.name)) |post_install_src| {
                defer allocator.free(post_install_src);

                var formula = formula_mod.parseFormula(allocator, job.formula_json) catch {
                    output.warn("post_install: failed to parse formula for {s}", .{job.name});
                    break :post_install;
                };
                defer formula.deinit();

                var flog = dsl.FallbackLog.init(allocator);
                defer flog.deinit();

                dsl.executePostInstall(allocator, &formula, post_install_src, prefix, &flog) catch {};
                routePostInstallOutcome(allocator, job.name, job.version_str, prefix, &flog, use_system_ruby_list);
                break :post_install;
            }

            // No source available — fall back to subprocess or skip
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
    if (!force and isInstalled(db, formula.name)) {
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

        const threads = allocator.alloc(std.Thread, deps.len) catch return InstallError.DownloadFailed;
        defer allocator.free(threads);

        var spawned: usize = 0;
        for (deps, 0..) |dep, i| {
            if (dep.already_installed) continue;
            if (std.Thread.spawn(.{}, FetchFormulaCtx.run, .{&ctxs[i]})) |t| {
                threads[spawned] = t;
                spawned += 1;
            } else |_| {
                // Spawn failure → run inline on the caller thread.
                ctxs[i].run();
            }
        }
        for (threads[0..spawned]) |t| t.join();

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

/// Result of a parallel materialize worker. `keg_path` is owned via
/// `std.heap.c_allocator` (thread-safe) and must be freed by the caller.
const MaterializeResult = struct {
    ok: bool,
    keg_path: []const u8,
    err: ?cellar_mod.CellarError,
};

/// Shared state for a bounded work-stealing thread pool that executes
/// the materialize phase. `next_idx` hands out jobs atomically so
/// workers grab the next available job until the queue is drained —
/// natural load-balancing without waves.
const MaterializePool = struct {
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
fn materializePoolWorker(pool: *MaterializePool) void {
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

/// Record a keg in the database. Returns the keg_id.
pub fn recordKeg(
    db: *sqlite.Database,
    formula: *const formula_mod.Formula,
    store_sha256: []const u8,
    cellar_path: []const u8,
    install_reason: []const u8,
) !i64 {
    db.beginTransaction() catch return InstallError.RecordFailed;
    errdefer db.rollback();

    var stmt = db.prepare(
        "INSERT OR REPLACE INTO kegs (name, full_name, version, revision, tap, store_sha256, cellar_path, install_reason)" ++
            " VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);",
    ) catch return InstallError.RecordFailed;
    defer stmt.finalize();

    stmt.bindText(1, formula.name) catch return InstallError.RecordFailed;
    stmt.bindText(2, formula.full_name) catch return InstallError.RecordFailed;
    stmt.bindText(3, formula.version) catch return InstallError.RecordFailed;
    stmt.bindInt(4, formula.revision) catch return InstallError.RecordFailed;
    stmt.bindText(5, formula.tap) catch return InstallError.RecordFailed;
    stmt.bindText(6, store_sha256) catch return InstallError.RecordFailed;
    stmt.bindText(7, cellar_path) catch return InstallError.RecordFailed;
    stmt.bindText(8, install_reason) catch return InstallError.RecordFailed;

    _ = stmt.step() catch return InstallError.RecordFailed;

    // Get last inserted row id
    const keg_id = getLastInsertId(db) catch return InstallError.RecordFailed;

    db.commit() catch return InstallError.RecordFailed;

    return keg_id;
}

/// Delete a keg record from the database (rollback helper).
pub fn deleteKeg(db: *sqlite.Database, keg_id: i64) void {
    var stmt = db.prepare("DELETE FROM kegs WHERE id = ?1;") catch return;
    defer stmt.finalize();
    stmt.bindInt(1, keg_id) catch return;
    _ = stmt.step() catch {};
}

/// Record dependencies for a keg.
pub fn recordDeps(db: *sqlite.Database, keg_id: i64, formula: *const formula_mod.Formula) void {
    for (formula.dependencies) |dep_name| {
        var stmt = db.prepare(
            "INSERT OR IGNORE INTO dependencies (keg_id, dep_name, dep_type) VALUES (?1, ?2, 'runtime');",
        ) catch continue;
        defer stmt.finalize();

        stmt.bindInt(1, keg_id) catch continue;
        stmt.bindText(2, dep_name) catch continue;
        _ = stmt.step() catch {};
    }
}

/// Get the last inserted row id from SQLite.
fn getLastInsertId(db: *sqlite.Database) !i64 {
    var stmt = db.prepare("SELECT last_insert_rowid();") catch return InstallError.RecordFailed;
    defer stmt.finalize();
    const has_row = stmt.step() catch return InstallError.RecordFailed;
    if (!has_row) return InstallError.RecordFailed;
    return stmt.columnInt(0);
}

/// Check if a formula is already installed.
pub fn isInstalled(db: *sqlite.Database, name: []const u8) bool {
    var stmt = db.prepare("SELECT id FROM kegs WHERE name = ?1 LIMIT 1;") catch return false;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return false;
    return stmt.step() catch false;
}

/// Ensure all required directories under prefix exist.
pub fn ensureDirs(prefix: []const u8) !void {
    // Create the prefix directory itself first (e.g. /opt/malt)
    fs_compat.makeDirAbsolute(prefix) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => {
            output.err("Cannot create prefix directory {s} — you may need: sudo mkdir -p {s} && sudo chown $USER {s}", .{ prefix, prefix, prefix });
            return error.Aborted;
        },
    };

    const subdirs = [_][]const u8{
        "store",
        "Cellar",
        "Caskroom",
        "opt",
        "bin",
        "lib",
        "include",
        "share",
        "sbin",
        "etc",
        "tmp",
        "cache",
        "db",
    };

    for (subdirs) |subdir| {
        var buf: [512]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ prefix, subdir }) catch continue;
        fs_compat.makeDirAbsolute(dir_path) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => continue,
        };
    }
}

/// Build GHCR repo path from formula name, replacing @ with /
pub fn buildGhcrRepo(buf: []u8, name: []const u8) ![]const u8 {
    // Replace @ with / for versioned formulas (openssl@3 -> homebrew/core/openssl/3)
    var pos: usize = 0;
    const prefix_str = "homebrew/core/";
    if (pos + prefix_str.len > buf.len) return error.OutOfMemory;
    @memcpy(buf[pos .. pos + prefix_str.len], prefix_str);
    pos += prefix_str.len;

    for (name) |ch| {
        if (pos >= buf.len) return error.OutOfMemory;
        buf[pos] = if (ch == '@') '/' else ch;
        pos += 1;
    }
    return buf[0..pos];
}

/// Check if a package name is a tap formula (user/repo/formula format).
pub fn isTapFormula(name: []const u8) bool {
    var slash_count: u32 = 0;
    for (name) |ch| {
        if (ch == '/') slash_count += 1;
    }
    return slash_count == 2;
}

/// Shape-based detection for a local `.rb` path argument (e.g.
/// `./wget.rb`, `/tmp/wget.rb`, `~/f/wget.rb`, `a/b/c/d.rb`). Pure:
/// no filesystem access, no allocation.
///
/// Tie-break with tap-form: the `.rb` suffix always wins. A bare tap
/// slug `user/repo/formula` has no suffix; `user/repo/formula.rb` is
/// treated as a path so the user does not get a confusing 404 from the
/// tap resolver.
pub fn isLocalFormulaPath(arg: []const u8) bool {
    if (!std.mem.endsWith(u8, arg, ".rb")) return false;
    if (arg.len == 0) return false;
    if (arg[0] == '/' or arg[0] == '~' or arg[0] == '.') return true;
    // Any embedded separator also flags it as a path (e.g. "a/b/c.rb").
    for (arg) |ch| if (ch == '/' or ch == '\\') return true;
    // Bare `wget.rb` with no separator is NOT auto-detected; require
    // `--local` to avoid shadowing a same-named formula on the API.
    return false;
}

/// Parse a tap formula name into user, repo, formula components.
pub fn parseTapName(name: []const u8) ?struct { user: []const u8, repo: []const u8, formula: []const u8 } {
    const first_slash = std.mem.findScalar(u8, name, '/') orelse return null;
    const rest = name[first_slash + 1 ..];
    const second_slash = std.mem.findScalar(u8, rest, '/') orelse return null;
    return .{
        .user = name[0..first_slash],
        .repo = rest[0..second_slash],
        .formula = rest[second_slash + 1 ..],
    };
}

/// Maximum size of a `.rb` formula file that `malt install --local`
/// will read. Real Homebrew formulas top out well below this (the
/// current heaviest, `llvm.rb`, is ~60 KB). The cap bounds the single
/// TOCTOU-safe read so a hostile symlink cannot force malt to slurp an
/// unbounded file before parsing.
pub const max_local_formula_bytes: usize = 1 * 1024 * 1024;

/// Post-parse payload shared by the tap and local-file install paths.
/// Slices point into caller-owned memory (parsed `.rb`, interpolated
/// URL buffer) and must outlive `materializeRubyFormula`.
const ResolvedRubyFormula = struct {
    /// Short formula name — becomes the Cellar dir, bin basename, and
    /// `kegs.name` column.
    name: []const u8,
    /// Full origin identifier stored in `kegs.full_name`. Tap slugs
    /// carry the `user/repo/formula` form; local installs carry the
    /// realpath so `mt list` shows where the `.rb` came from.
    full_name: []const u8,
    /// Label for the `kegs.tap` column and, optionally, `tap_mod.add`.
    tap_label: []const u8,
    version: []const u8,
    /// Archive URL post `#{version}` interpolation.
    url: []const u8,
    sha256: []const u8,
    /// When set, the tap is registered in the DB (mirrors the original
    /// tap install behaviour). Local installs leave this null so they
    /// never pollute the tap list.
    tap_registration: ?TapRegistration = null,
};

const TapRegistration = struct {
    url: []const u8,
    commit_sha: []const u8,
};

/// Install a tap formula by fetching the Ruby formula from GitHub and
/// extracting URL + SHA256 for the current platform.
fn installTapFormula(
    allocator: std.mem.Allocator,
    pkg_name: []const u8,
    db: *sqlite.Database,
    linker: *linker_mod.Linker,
    prefix: []const u8,
    dry_run: bool,
    force: bool,
) !void {
    const parts = parseTapName(pkg_name) orelse {
        output.err("Invalid tap formula format: {s}", .{pkg_name});
        return InstallError.FormulaNotFound;
    };

    output.info("Resolving tap {s}/{s}/{s}...", .{ parts.user, parts.repo, parts.formula });

    // Determine the commit SHA to fetch against. Prefer the pin
    // already in the DB (set at tap-add or last --refresh); if no pin
    // exists yet, resolve HEAD once and record it below. Refuses to
    // build a URL from a floating HEAD at install time.
    var tap_slug_buf: [128]u8 = undefined;
    const tap_slug = std.fmt.bufPrint(&tap_slug_buf, "{s}/{s}", .{ parts.user, parts.repo }) catch
        return InstallError.FormulaNotFound;
    const commit_sha = blk: {
        if ((tap_mod.getCommitSha(allocator, db, tap_slug) catch null)) |cached| {
            break :blk cached;
        }
        break :blk tap_mod.resolveHeadCommit(allocator, parts.user, parts.repo) catch {
            output.err("Could not resolve {s}'s HEAD commit — refusing to install from a floating HEAD.", .{tap_slug});
            return InstallError.FormulaNotFound;
        };
    };
    defer allocator.free(commit_sha);

    var http = client_mod.HttpClient.init(allocator);
    defer http.deinit();

    // Try Formula/ first, then Casks/
    var url_buf: [512]u8 = undefined;
    const rb_url = std.fmt.bufPrint(&url_buf, "https://raw.githubusercontent.com/{s}/homebrew-{s}/{s}/Formula/{s}.rb", .{
        parts.user,
        parts.repo,
        commit_sha,
        parts.formula,
    }) catch return InstallError.FormulaNotFound;

    var resp = http.get(rb_url) catch {
        output.err("Cannot fetch tap from GitHub", .{});
        return InstallError.FormulaNotFound;
    };

    if (resp.status != 200) {
        resp.deinit();
        // Try Casks/ directory
        const cask_url = std.fmt.bufPrint(&url_buf, "https://raw.githubusercontent.com/{s}/homebrew-{s}/{s}/Casks/{s}.rb", .{
            parts.user,
            parts.repo,
            commit_sha,
            parts.formula,
        }) catch return InstallError.FormulaNotFound;

        resp = http.get(cask_url) catch {
            output.err("Cannot fetch tap from GitHub", .{});
            return InstallError.FormulaNotFound;
        };
    }
    defer resp.deinit();

    if (resp.status != 200) {
        output.err("Tap formula/cask not found: {s}", .{pkg_name});
        return InstallError.FormulaNotFound;
    }

    // Parse the Ruby formula to extract name, version, URL, SHA256 for current arch
    const rb = parseRubyFormula(resp.body) orelse {
        output.err("Cannot parse tap formula (Ruby format). Use: brew install {s}", .{pkg_name});
        return InstallError.FormulaNotFound;
    };

    // Interpolate #{version} in URL if present
    var final_url_buf: [512]u8 = undefined;
    const final_url = interpolateVersion(&final_url_buf, rb.url, rb.version);

    var tap_buf: [128]u8 = undefined;
    const tap_name = std.fmt.bufPrint(&tap_buf, "{s}/{s}", .{ parts.user, parts.repo }) catch
        return InstallError.FormulaNotFound;
    var tap_url_buf: [256]u8 = undefined;
    const tap_url = std.fmt.bufPrint(&tap_url_buf, "https://github.com/{s}", .{tap_name}) catch
        return InstallError.FormulaNotFound;

    const resolved = ResolvedRubyFormula{
        .name = parts.formula,
        .full_name = pkg_name,
        .tap_label = tap_name,
        .version = rb.version,
        .url = final_url,
        .sha256 = rb.sha256,
        .tap_registration = .{ .url = tap_url, .commit_sha = commit_sha },
    };
    try materializeRubyFormula(allocator, resolved, &http, db, linker, prefix, dry_run, force);
}

/// Install a formula from a local `.rb` file on disk. Gated by the
/// explicit `--local` flag (or autodetection with warning). Reads the
/// file once with a size cap so a hostile symlink cannot force an
/// unbounded read, parses via the same `parseRubyFormula` the tap path
/// uses, and then hands off to the shared materialize helper.
///
/// `pkg_arg` is the argument as typed (possibly relative, possibly with
/// `~/`); the canonical realpath used for messages and DB storage is
/// derived inside the function.
fn installLocalFormula(
    allocator: std.mem.Allocator,
    pkg_arg: []const u8,
    db: *sqlite.Database,
    linker: *linker_mod.Linker,
    prefix: []const u8,
    dry_run: bool,
    force: bool,
) !void {
    // Expand a leading `~/` to `$HOME` so the common "drop it in
    // your dotfiles" path works without requiring shell expansion.
    var home_buf: [fs_compat.max_path_bytes]u8 = undefined;
    const expanded = expandTildePath(&home_buf, pkg_arg) orelse {
        output.err("Cannot resolve home directory for '{s}'", .{pkg_arg});
        return InstallError.LocalFormulaNotReadable;
    };

    // Canonicalise once via open+F_GETPATH. This both checks the file
    // exists AND gives us a symlink-free absolute path for audit
    // messages and the kegs row — defeating the "relative path in a
    // shared Brewfile" footgun.
    var real_buf: [fs_compat.max_path_bytes]u8 = undefined;
    const realpath = fs_compat.cwd().realpath(expanded, &real_buf) catch {
        output.err("Cannot open local formula: {s}", .{pkg_arg});
        return InstallError.LocalFormulaNotReadable;
    };

    // Security warning on every install — the `.rb` is a code-execution
    // vector (parse is pure, but post_install + the archive URL trust
    // this file). Printing the realpath surfaces hidden /tmp or
    // world-writable locations to an attentive reader.
    output.warn("Installing from local file '{s}'. Only install .rb files you trust.", .{realpath});

    // Reject non-regular files outright (directory, socket, device)
    // before allocating a read buffer.
    const f = fs_compat.openFileAbsolute(realpath, .{ .mode = .read_only }) catch {
        output.err("Cannot open local formula: {s}", .{realpath});
        return InstallError.LocalFormulaNotReadable;
    };
    defer f.close();
    const st = f.stat() catch {
        output.err("Cannot stat local formula: {s}", .{realpath});
        return InstallError.LocalFormulaNotReadable;
    };
    if (st.kind != .file) {
        output.err("Local formula is not a regular file: {s}", .{realpath});
        return InstallError.LocalFormulaNotReadable;
    }
    if (st.size > max_local_formula_bytes) {
        output.err("Local formula exceeds {d}-byte read cap: {s}", .{ max_local_formula_bytes, realpath });
        return InstallError.LocalFormulaNotReadable;
    }

    // Advisory: warn if the file is world-writable or owned by a
    // different user. `--local` is already the trust gate so we don't
    // block — but we make the risk visible on the same line style as
    // the primary security warning.
    if (fstatRisk(f)) |risk| switch (risk) {
        .world_writable => output.warn("Local formula is world-writable — any local user could rewrite it between reads.", .{}),
        .other_owner => output.warn("Local formula is not owned by you — another account wrote this file.", .{}),
    };

    const body = f.readToEndAlloc(allocator, max_local_formula_bytes) catch {
        output.err("Cannot read local formula: {s}", .{realpath});
        return InstallError.LocalFormulaNotReadable;
    };
    defer allocator.free(body);

    // Parse the Ruby formula to extract name, version, URL, SHA256 for current arch
    const rb = parseRubyFormula(body) orelse {
        output.err("Cannot parse local formula (missing version/url/sha256): {s}", .{realpath});
        return InstallError.FormulaNotFound;
    };

    // Formula name comes from the basename minus `.rb` — mirrors
    // Homebrew's convention where `wget.rb` installs `wget`. This is
    // the canonical surface for the cellar path, bin name, and DB row.
    const base = std.fs.path.basename(realpath);
    if (!std.mem.endsWith(u8, base, ".rb") or base.len <= 3) {
        output.err("Local formula must end in .rb: {s}", .{realpath});
        return InstallError.LocalFormulaNotReadable;
    }
    const name = base[0 .. base.len - 3];

    var final_url_buf: [512]u8 = undefined;
    const final_url = interpolateVersion(&final_url_buf, rb.url, rb.version);

    const resolved = ResolvedRubyFormula{
        .name = name,
        .full_name = realpath,
        .tap_label = "local",
        .version = rb.version,
        .url = final_url,
        .sha256 = rb.sha256,
        // No tap_registration — never pollute `mt tap` with a local path.
    };

    var http = client_mod.HttpClient.init(allocator);
    defer http.deinit();
    try materializeRubyFormula(allocator, resolved, &http, db, linker, prefix, dry_run, force);
}

/// True only when `url` is a well-formed `https://` URL with a host
/// component. The local-install path uses this to reject scheme
/// smuggling (file://, ftp://, data:) and downgrade attempts (http://)
/// before we ever hand the URL to the HTTP client. Strict lower-case
/// match keeps the allowlist tamper-resistant; real tap formulas never
/// use mixed-case schemes.
pub fn isAllowedArchiveUrl(url: []const u8) bool {
    const prefix = "https://";
    if (!std.mem.startsWith(u8, url, prefix)) return false;
    const host_and_path = url[prefix.len..];
    // Reject `https://` with nothing after, or a leading slash that
    // would collapse the authority component.
    if (host_and_path.len == 0) return false;
    if (host_and_path[0] == '/') return false;
    return true;
}

/// True when the given error has already surfaced a specific,
/// user-facing `output.err` line from inside the install helpers, so
/// the dispatch-loop shouldn't add a generic "Failed to install X: E"
/// summary on top. Kept next to the helpers it mirrors so adding a new
/// announced error type can't forget this call site.
pub fn localErrorIsAnnounced(e: anyerror) bool {
    return switch (e) {
        InstallError.LocalFormulaNotReadable,
        InstallError.InsecureArchiveUrl,
        InstallError.FormulaNotFound,
        InstallError.DownloadFailed,
        InstallError.CellarFailed,
        => true,
        else => false,
    };
}

/// Ordered set of advisory risk labels that may fire on a `.rb` file
/// the user asked to install. `world_writable` dominates `other_owner`
/// because any local account can win the TOCTOU race while only the
/// owner can edit a 0o644 file. Pure enum — no allocation, trivially
/// table-testable (see `describeLocalPermissionRisk`).
pub const LocalPermissionRisk = enum { world_writable, other_owner };

/// Classify a local formula's filesystem metadata into at most one
/// advisory risk label. Returns null when the file is plausibly safe
/// (owned by the effective user and not world-writable). The caller
/// uses the result to emit a single extra `⚠` line — never to block
/// the install, since `--local` is itself the explicit trust decision.
pub fn describeLocalPermissionRisk(mode: u32, file_uid: u32, effective_uid: u32) ?LocalPermissionRisk {
    if (mode & 0o002 != 0) return .world_writable;
    if (file_uid != effective_uid) return .other_owner;
    return null;
}

/// Thin wrapper that pulls raw POSIX `st_mode`/`st_uid` from the
/// already-opened handle and routes them through the pure predicate.
/// `Stat` in `std.Io` doesn't surface uid or mode bits directly, so a
/// libc `fstat(2)` is the path of least resistance on macOS.
fn fstatRisk(f: fs_compat.File) ?LocalPermissionRisk {
    var raw: std.c.Stat = undefined;
    if (std.c.fstat(f.inner.handle, &raw) != 0) return null;
    const effective = std.c.geteuid();
    return describeLocalPermissionRisk(@intCast(raw.mode), @intCast(raw.uid), @intCast(effective));
}

/// Constant-time equality for byte slices. Used on the SHA256
/// comparison so a network-positioned attacker cannot mount a byte-by-
/// byte timing oracle against the expected hash. Returns false
/// immediately on length mismatch (the length itself is not a secret).
pub fn constantTimeEql(comptime T: type, a: []const T, b: []const T) bool {
    if (a.len != b.len) return false;
    var diff: T = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

/// Interpolate `#{version}` inside a URL. Falls back to the raw URL if
/// the buffer is too small (bufPrint error) — the caller's SHA check
/// will then fail fast if the server serves a different asset.
pub fn interpolateVersion(buf: []u8, url: []const u8, version: []const u8) []const u8 {
    const version_needle = "#" ++ "{version}";
    if (std.mem.indexOf(u8, url, version_needle)) |pos| {
        const before = url[0..pos];
        const after = url[pos + version_needle.len ..];
        return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ before, version, after }) catch url;
    }
    return url;
}

/// Expand a leading `~/` to `$HOME/...`. Returns the input unchanged
/// when no tilde prefix is present. Returns null when `$HOME` is
/// needed but unset.
pub fn expandTildePath(buf: []u8, arg: []const u8) ?[]const u8 {
    if (arg.len < 2 or arg[0] != '~' or arg[1] != '/') return arg;
    const home = fs_compat.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ home, arg[1..] }) catch null;
}

/// Shared "from parsed `.rb` to linked keg" path, used by the tap and
/// local installers. Does the network fetch for the archive, SHA256
/// verification, cellar materialisation, and DB + linker commit.
fn materializeRubyFormula(
    allocator: std.mem.Allocator,
    resolved: ResolvedRubyFormula,
    http: *client_mod.HttpClient,
    db: *sqlite.Database,
    linker: *linker_mod.Linker,
    prefix: []const u8,
    dry_run: bool,
    force: bool,
) !void {
    output.info("Found {s} {s}", .{ resolved.name, resolved.version });

    if (dry_run) {
        output.info("Dry run: would install {s} {s} from {s}", .{ resolved.name, resolved.version, resolved.url });
        return;
    }

    // Skip silently when the keg is already present (unless --force).
    if (!force and isInstalled(db, resolved.name)) {
        output.info("{s} is already installed", .{resolved.name});
        return;
    }

    // Refuse any scheme other than `https://`. A `.rb` that smuggled
    // `http://` (downgrade), `file:///etc/passwd`, `ftp://`, or a data
    // URI would otherwise be trusted by the HTTP client. Enforced for
    // every caller of this helper — tap and local share the check.
    if (!isAllowedArchiveUrl(resolved.url)) {
        output.err("Refusing to fetch non-HTTPS archive URL for {s}: {s}", .{ resolved.name, resolved.url });
        return InstallError.InsecureArchiveUrl;
    }

    // Stream with a progress bar, matching formula/cask downloads.
    var bar = progress_mod.ProgressBar.init(resolved.name, 0);
    var download_resp = http.getWithHeaders(resolved.url, &.{}, .{
        .context = @ptrCast(&bar),
        .func = &progressBridge,
    }) catch {
        bar.finish();
        output.err("Failed to download {s}", .{resolved.name});
        return InstallError.DownloadFailed;
    };
    defer download_resp.deinit();
    bar.finish();

    if (download_resp.status != 200) {
        output.err("Download failed with status {d}", .{download_resp.status});
        return InstallError.DownloadFailed;
    }

    // Verify SHA256 before anything touches the filesystem.
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(download_resp.body, &hash, .{});
    var hex_buf: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (hash, 0..) |b, i| {
        hex_buf[i * 2] = hex_chars[b >> 4];
        hex_buf[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    const computed: []const u8 = &hex_buf;

    // Constant-time compare on the SHA256: a stock `mem.eql` leaks
    // per-byte progress via timing, giving an adaptive attacker a
    // byte-by-byte oracle against the expected hash.
    if (!constantTimeEql(u8, computed, resolved.sha256)) {
        output.err("SHA256 mismatch for {s}", .{resolved.name});
        return InstallError.DownloadFailed;
    }

    // Extract to Cellar directly (tap-style binaries are simple archives).
    var cellar_buf: [512]u8 = undefined;
    const cellar_path = std.fmt.bufPrint(&cellar_buf, "{s}/Cellar/{s}/{s}", .{ prefix, resolved.name, resolved.version }) catch
        return InstallError.CellarFailed;

    var parent_buf: [512]u8 = undefined;
    const parent = std.fmt.bufPrint(&parent_buf, "{s}/Cellar/{s}", .{ prefix, resolved.name }) catch
        return InstallError.CellarFailed;
    fs_compat.makeDirAbsolute(parent) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return InstallError.CellarFailed,
    };
    fs_compat.makeDirAbsolute(cellar_path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return InstallError.CellarFailed,
    };

    var bin_buf: [512]u8 = undefined;
    const bin_path = std.fmt.bufPrint(&bin_buf, "{s}/bin", .{cellar_path}) catch
        return InstallError.CellarFailed;
    fs_compat.makeDirAbsolute(bin_path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return InstallError.CellarFailed,
    };

    // Pick archive kind from the URL suffix; reject unknown formats
    // rather than feeding them to tar and printing a generic "failed".
    const TapArchive = enum { tar_gz, tar_xz, zip };
    const kind: ?TapArchive = blk: {
        if (std.mem.endsWith(u8, resolved.url, ".tar.gz") or std.mem.endsWith(u8, resolved.url, ".tgz")) break :blk .tar_gz;
        if (std.mem.endsWith(u8, resolved.url, ".tar.xz")) break :blk .tar_xz;
        if (std.mem.endsWith(u8, resolved.url, ".zip")) break :blk .zip;
        break :blk null;
    };
    const archive_kind = kind orelse {
        output.err("Unsupported archive format for {s}: {s}", .{ resolved.name, resolved.url });
        output.err("Supported formats: .tar.gz, .tar.xz, .zip.", .{});
        return InstallError.DownloadFailed;
    };
    const ext: []const u8 = switch (archive_kind) {
        .tar_gz => ".tar.gz",
        .tar_xz => ".tar.xz",
        .zip => ".zip",
    };
    var tmp_buf: [512]u8 = undefined;
    const tmp_archive = std.fmt.bufPrint(&tmp_buf, "{s}/tmp/tap_download{s}", .{ prefix, ext }) catch
        return InstallError.DownloadFailed;

    const tmp_file = fs_compat.createFileAbsolute(tmp_archive, .{}) catch return InstallError.DownloadFailed;
    tmp_file.writeAll(download_resp.body) catch {
        tmp_file.close();
        return InstallError.DownloadFailed;
    };
    tmp_file.close();
    defer fs_compat.cwd().deleteFile(tmp_archive) catch {};

    const archive_mod = @import("../fs/archive.zig");
    switch (archive_kind) {
        .tar_gz => archive_mod.extractTarGz(tmp_archive, cellar_path) catch {
            output.err("Failed to extract archive for {s}", .{resolved.name});
            return InstallError.CellarFailed;
        },
        .tar_xz => archive_mod.extractTarXzFile(tmp_archive, cellar_path) catch {
            output.err("Failed to extract .tar.xz archive for {s}", .{resolved.name});
            return InstallError.CellarFailed;
        },
        .zip => archive_mod.extractZip(tmp_archive, cellar_path) catch {
            output.err("Failed to extract .zip archive for {s}", .{resolved.name});
            return InstallError.CellarFailed;
        },
    }

    // Promote the binary to bin/ (GoReleaser may extract directly or
    // into a subdirectory — walk to handle both).
    {
        var cellar_dir = fs_compat.openDirAbsolute(cellar_path, .{ .iterate = true }) catch return InstallError.CellarFailed;
        defer cellar_dir.close();

        var walker = cellar_dir.walk(allocator) catch return InstallError.CellarFailed;
        defer walker.deinit();

        while (walker.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            const basename = std.fs.path.basename(entry.path);
            if (std.mem.eql(u8, basename, resolved.name)) {
                const dest_name = std.fmt.bufPrint(&tmp_buf, "bin/{s}", .{basename}) catch continue;
                cellar_dir.copyFile(entry.path, cellar_dir, dest_name, .{}) catch continue;
                const bin_file = cellar_dir.openFile(dest_name, .{ .mode = .read_write }) catch continue;
                defer bin_file.close();
                bin_file.chmod(0o755) catch {};
                break;
            }
        }
    }

    output.info("Linking {s}...", .{resolved.name});

    // Single DB transaction: keg row → optional tap registration →
    // linker work → commit. `errdefer rollback` unwinds cleanly if any
    // step fails before commit.
    db.beginTransaction() catch return InstallError.RecordFailed;
    errdefer db.rollback();

    var keg_id: i64 = 0;
    {
        var stmt = db.prepare(
            "INSERT OR REPLACE INTO kegs (name, full_name, version, tap, store_sha256, cellar_path, install_reason)" ++
                " VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'direct');",
        ) catch return InstallError.RecordFailed;
        defer stmt.finalize();
        stmt.bindText(1, resolved.name) catch return InstallError.RecordFailed;
        stmt.bindText(2, resolved.full_name) catch return InstallError.RecordFailed;
        stmt.bindText(3, resolved.version) catch return InstallError.RecordFailed;
        stmt.bindText(4, resolved.tap_label) catch return InstallError.RecordFailed;
        stmt.bindText(5, resolved.sha256) catch return InstallError.RecordFailed;
        stmt.bindText(6, cellar_path) catch return InstallError.RecordFailed;
        _ = stmt.step() catch return InstallError.RecordFailed;

        keg_id = getLastInsertId(db) catch return InstallError.RecordFailed;

        if (resolved.tap_registration) |t| {
            // `COALESCE` in tap_mod.add pins the commit on first install
            // and leaves later pins untouched.
            tap_mod.add(db, resolved.tap_label, t.url, t.commit_sha) catch {};
        }
    }

    linker.link(cellar_path, resolved.name, keg_id) catch {
        output.warn("Some links for {s} could not be created", .{resolved.name});
    };
    linker.linkOpt(resolved.name, resolved.version) catch {
        output.warn("Could not create opt link for {s}", .{resolved.name});
    };

    db.commit() catch return InstallError.RecordFailed;

    output.success("{s} {s} installed", .{ resolved.name, resolved.version });
}

/// Minimal Ruby formula parser for GoReleaser-style formulas.
/// Extracts version, URL, and SHA256 for the current platform.
pub const RubyFormulaInfo = struct {
    version: []const u8,
    url: []const u8,
    sha256: []const u8,
};

pub fn parseRubyFormula(rb_content: []const u8) ?RubyFormulaInfo {
    const is_arm = @import("../macho/codesign.zig").isArm64();

    var version: ?[]const u8 = null;
    var url: ?[]const u8 = null;
    var sha256: ?[]const u8 = null;

    // State machine: look for the right CPU section
    var in_correct_section = false;
    var in_macos = false;

    var line_start: usize = 0;
    for (rb_content, 0..) |ch, idx| {
        if (ch == '\n' or idx == rb_content.len - 1) {
            const line_end = if (ch == '\n') idx else idx + 1;
            const line = std.mem.trim(u8, rb_content[line_start..line_end], " \t\r");
            line_start = idx + 1;

            // Extract version (global)
            if (version == null) {
                if (extractQuoted(line, "version \"")) |v| {
                    version = v;
                }
            }

            // Track on_macos block
            if (std.mem.indexOf(u8, line, "on_macos") != null) {
                in_macos = true;
            }

            // Track CPU section (Formula style: Hardware::CPU, Cask style: on_arm/on_intel)
            if (in_macos) {
                if (is_arm and (std.mem.indexOf(u8, line, "Hardware::CPU.arm?") != null or
                    std.mem.indexOf(u8, line, "on_arm") != null))
                {
                    in_correct_section = true;
                } else if (!is_arm and (std.mem.indexOf(u8, line, "Hardware::CPU.intel?") != null or
                    std.mem.indexOf(u8, line, "on_intel") != null))
                {
                    in_correct_section = true;
                }
            }

            // Extract URL and SHA256 within the correct section
            if (in_correct_section) {
                if (url == null) {
                    if (extractQuoted(line, "url \"")) |u| {
                        url = u;
                    }
                }
                if (sha256 == null) {
                    if (extractQuoted(line, "sha256 \"")) |s| {
                        sha256 = s;
                    }
                }
            }

            // If we have both, stop
            if (url != null and sha256 != null) break;
        }
    }

    // Fallback: if no CPU-specific section found, try global url/sha256
    if (url == null or sha256 == null) {
        var ls: usize = 0;
        for (rb_content, 0..) |ch, idx| {
            if (ch == '\n' or idx == rb_content.len - 1) {
                const le = if (ch == '\n') idx else idx + 1;
                const ln = std.mem.trim(u8, rb_content[ls..le], " \t\r");
                ls = idx + 1;

                if (url == null) {
                    if (extractQuoted(ln, "url \"")) |u| url = u;
                }
                if (sha256 == null) {
                    if (extractQuoted(ln, "sha256 \"")) |s| sha256 = s;
                }
            }
        }
    }

    if (version != null and url != null and sha256 != null) {
        return .{ .version = version.?, .url = url.?, .sha256 = sha256.? };
    }
    return null;
}

pub fn extractQuoted(line: []const u8, prefix: []const u8) ?[]const u8 {
    _, const after = std.mem.cut(u8, line, prefix) orelse return null;
    const body, _ = std.mem.cut(u8, after, "\"") orelse return null;
    return body;
}
