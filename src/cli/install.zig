//! malt — install command.
//! 9-step atomic install protocol for formulas, casks, and tap formulas.

const std = @import("std");

const AppCtx = @import("../app_ctx.zig").AppCtx;
const cask_mod = @import("../core/cask.zig");
const cellar_mod = @import("../core/cellar.zig");
const deps_mod = @import("../core/deps.zig");
const formula_mod = @import("../core/formula.zig");
const linker_mod = @import("../core/linker.zig");
const plist_mod = @import("../core/services/plist.zig");
const supervisor_mod = @import("../core/services/supervisor.zig");
const store_mod = @import("../core/store.zig");
const lock_mod = @import("../db/lock.zig");
const schema = @import("../db/schema.zig");
const sqlite = @import("../db/sqlite.zig");
const atomic = @import("../fs/atomic.zig");
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
pub const isCoreTap = args_mod.isCoreTap;
pub const isLocalFormulaPath = args_mod.isLocalFormulaPath;
pub const isSelfInstall = args_mod.isSelfInstall;
pub const parseTapName = args_mod.parseTapName;
pub const isAllowedArchiveUrl = args_mod.isAllowedArchiveUrl;
pub const interpolateVersion = args_mod.interpolateVersion;
pub const interpolateUrl = args_mod.interpolateUrl;
pub const expandTildePath = args_mod.expandTildePath;
const download_mod = @import("install/download.zig");
pub const DownloadJob = download_mod.DownloadJob;
pub const MAX_COLLECT_FETCH_WORKERS = download_mod.MAX_COLLECT_FETCH_WORKERS;
pub const collectFetchWorkerCount = download_mod.collectFetchWorkerCount;
pub const collectFormulaJobs = download_mod.collectFormulaJobs;
pub const InstallJobDeps = download_mod.InstallJobDeps;
pub const findFailedDep = download_mod.findFailedDep;
pub const dropTopLevelJobs = download_mod.dropTopLevelJobs;
pub const assignDownloadLineIndices = download_mod.assignDownloadLineIndices;
pub const isDeterministicDownloadError = download_mod.isDeterministicDownloadError;
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
pub const parseCaskBinary = local_mod.parseCaskBinary;
pub const parseCaskApp = local_mod.parseCaskApp;
pub const tapCaskArtifactKind = local_mod.tapCaskArtifactKind;
pub const extractQuoted = local_mod.extractQuoted;
const installTapFormula = local_mod.installTapFormula;
const installLocalFormula = local_mod.installLocalFormula;
const post_install_mod = @import("install/post_install.zig");
pub const PostInstallStatus = post_install_mod.PostInstallStatus;
pub const routePostInstallOutcome = post_install_mod.routePostInstallOutcome;
pub const DslPostInstallOutcome = post_install_mod.DslPostInstallOutcome;
pub const executeDslPostInstall = post_install_mod.executeDslPostInstall;
pub const drive = post_install_mod.drive;
const record_mod = @import("install/record.zig");
pub const InstallError = record_mod.InstallError;

/// Wipe `<prefix>/Cellar/<name>/<version>` so a `--force` reinstall can
/// re-materialize on top of it. No-op when the dir is missing or the
/// path overflows the buffer; failures are best-effort because the
/// follow-up materialize step surfaces real errors with full context.
pub fn pruneCellarForReinstall(ctx: *const AppCtx, prefix: []const u8, name: []const u8, version: []const u8) void {
    var cellar_buf: [512]u8 = undefined;
    const cellar_path = std.fmt.bufPrint(&cellar_buf, "{s}/Cellar/{s}/{s}", .{ prefix, name, version }) catch return;
    std.Io.Dir.cwd().deleteTree(ctx.io, cellar_path) catch {};
}

/// Unlink the on-disk symlinks AND drop the `links` rows for every
/// `kegs` row of `name` whose `cellar_path` differs from
/// `keep_cellar_path` — i.e. the prior install at an other
/// version/revision. The `kegs` row + its `dependencies` rows stay
/// in place so the subsequent `recordKeg` INSERT OR REPLACE sees the
/// stale row's `pinned` flag through COALESCE-MAX. The row drop
/// itself is handled by `dropStaleKegRows` after `linkAndRecord`
/// commits the new row.
///
/// Pre-link companion to `unlinkSameVersionKegLinks`: between the
/// two, every same-name prior install's symlinks are cleared before
/// `linker.checkConflicts` runs, so a `--force` reinstall does not
/// trip on its own predecessor.
///
/// Best-effort: per-row errors are swallowed; the next `doctor`
/// pass surfaces anything we could not reach.
pub fn unlinkStaleKegLinks(
    db: *sqlite.Database,
    linker: *linker_mod.Linker,
    name: []const u8,
    keep_cellar_path: []const u8,
) void {
    var stmt = db.prepare("SELECT id FROM kegs WHERE name = ?1 AND cellar_path != ?2;") catch return;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return;
    stmt.bindText(2, keep_cellar_path) catch return;

    while (stmt.step() catch false) {
        const id = stmt.columnInt(0);
        linker.unlink(id) catch {};
    }
}

/// Drop the DB rows + on-disk dirs for every `kegs` row of `name`
/// whose `cellar_path` differs from `keep_cellar_path`. Pairs with
/// `unlinkStaleKegLinks` (which clears the symlinks before
/// `linkAndRecord`) so this post-link step only has to handle the
/// row + dependencies + cellar dir teardown.
///
/// Pin preservation: callers must run this AFTER `recordKeg`'s
/// INSERT OR REPLACE has executed, so the COALESCE-MAX subquery
/// inside that INSERT still sees the stale row's `pinned` flag and
/// can inherit it. Running this before `recordKeg` would leave the
/// new row with `pinned=0` for users who pinned the prior revision.
///
/// Best-effort: per-row errors are swallowed; the next `doctor`
/// pass surfaces anything we could not reach.
pub fn dropStaleKegRows(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    name: []const u8,
    keep_cellar_path: []const u8,
) void {
    const StaleRow = struct { id: i64, path: []u8 };
    var stale: std.ArrayList(StaleRow) = .empty;
    defer {
        for (stale.items) |s| allocator.free(s.path);
        stale.deinit(allocator);
    }

    {
        var stmt = db.prepare("SELECT id, cellar_path FROM kegs WHERE name = ?1 AND cellar_path != ?2;") catch return;
        defer stmt.finalize();
        stmt.bindText(1, name) catch return;
        stmt.bindText(2, keep_cellar_path) catch return;

        while (stmt.step() catch false) {
            const id = stmt.columnInt(0);
            const path_raw = stmt.columnText(1) orelse continue;
            const path = std.mem.sliceTo(path_raw, 0);
            const dup = allocator.dupe(u8, path) catch continue;
            stale.append(allocator, .{ .id = id, .path = dup }) catch {
                allocator.free(dup);
                continue;
            };
        }
    }

    for (stale.items) |s| {
        deleteDependencyRows(db, s.id);
        deleteKegRowOnly(db, s.id);
        std.Io.Dir.cwd().deleteTree(ctx.io, s.path) catch {};
    }
}

/// Unlink the on-disk symlinks AND drop the `links` rows for any
/// `kegs` row whose `(name, cellar_path)` matches the keg we are
/// about to re-install (i.e. same version / revision as the new
/// resolved keg). The `kegs` row itself is left in place so the
/// subsequent `recordKeg` INSERT OR REPLACE can inherit the user
/// pin via COALESCE-MAX on `pinned`.
///
/// This closes the `--force` linker-conflict path: without the
/// pre-link unlink, `linker.checkConflicts` sees the prior install's
/// symlinks under `<prefix>/{bin,lib,...}` (still pointing at the
/// freshly re-materialized cellar_path) and aborts with
/// `Use --force to overwrite, or uninstall the conflicting package
/// first.` — even though the user already passed `--force`.
///
/// Best-effort: per-row errors are swallowed; the next `doctor`
/// pass surfaces anything we could not reach.
pub fn unlinkSameVersionKegLinks(
    linker: *linker_mod.Linker,
    db: *sqlite.Database,
    name: []const u8,
    keep_cellar_path: []const u8,
) void {
    var stmt = db.prepare("SELECT id FROM kegs WHERE name = ?1 AND cellar_path = ?2 LIMIT 1;") catch return;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return;
    stmt.bindText(2, keep_cellar_path) catch return;
    if (!(stmt.step() catch false)) return;
    const keg_id = stmt.columnInt(0);
    linker.unlink(keg_id) catch {};
}

fn deleteDependencyRows(db: *sqlite.Database, keg_id: i64) void {
    var stmt = db.prepare("DELETE FROM dependencies WHERE keg_id = ?1;") catch return;
    defer stmt.finalize();
    stmt.bindInt(1, keg_id) catch return;
    _ = stmt.step() catch {};
}

fn deleteKegRowOnly(db: *sqlite.Database, keg_id: i64) void {
    var stmt = db.prepare("DELETE FROM kegs WHERE id = ?1;") catch return;
    defer stmt.finalize();
    stmt.bindInt(1, keg_id) catch return;
    _ = stmt.step() catch {};
}

/// Wipe every `<prefix>/Cellar/<name>/*` entry except `keep_version`.
/// Safety net for orphan dirs that have no `kegs` row pointing at
/// them — legacy installs, crashed runs, manual `mkdir`. The DB-
/// driven cleanup in `unlinkStaleKegLinks` + `dropStaleKegRows`
/// covers the common "force-reinstall across a revision bump" case;
/// this one catches the residue. Best-effort otherwise: per-entry
/// errors are swallowed because the materialize step still covers
/// real failures.
///
/// Names are collected before any deletion: POSIX leaves readdir
/// behavior undefined while entries are being unlinked, and APFS
/// readdir is buffered so a partial-page refresh can drop entries.
pub fn pruneOtherCellarVersionsForReinstall(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    prefix: []const u8,
    name: []const u8,
    keep_version: []const u8,
) void {
    var pkg_buf: [512]u8 = undefined;
    const pkg_path = std.fmt.bufPrint(&pkg_buf, "{s}/Cellar/{s}", .{ prefix, name }) catch return;

    var pkg_dir = std.Io.Dir.openDirAbsolute(ctx.io, pkg_path, .{ .iterate = true }) catch return;
    defer pkg_dir.close(ctx.io);

    var stale: std.ArrayList([]u8) = .empty;
    defer {
        for (stale.items) |s| allocator.free(s);
        stale.deinit(allocator);
    }

    var it = pkg_dir.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, keep_version)) continue;
        const dup = allocator.dupe(u8, entry.name) catch continue;
        stale.append(allocator, dup) catch {
            allocator.free(dup);
            continue;
        };
    }

    for (stale.items) |version_name| {
        var version_buf: [512]u8 = undefined;
        const version_path = std.fmt.bufPrint(
            &version_buf,
            "{s}/{s}",
            .{ pkg_path, version_name },
        ) catch continue;
        std.Io.Dir.cwd().deleteTree(ctx.io, version_path) catch {};
    }
}

/// Single-`stat` probe of `<prefix>/Cellar/<name>`. uninstall tears
/// down the parent when the last version goes; an orphan empty dir is
/// `mt doctor --fix` territory rather than something to paper over.
fn kegPresent(ctx: *const AppCtx, prefix: []const u8, name: []const u8) bool {
    var buf: [512]u8 = undefined;
    const cellar_path = std.fmt.bufPrint(&buf, "{s}/Cellar/{s}", .{ prefix, name }) catch return false;
    std.Io.Dir.accessAbsolute(ctx.io, cellar_path, .{}) catch return false;
    return true;
}

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
    /// Caller already owns `malt.lock` on a separate fd. BSD `flock` is
    /// per-fd, so re-entering `execute` from the same process would
    /// otherwise EAGAIN-loop against its own hold and 30 s-timeout with
    /// the misleading "another mt process is running" error.
    skip_lock: bool = false,
};

/// Non-argv primitive used by `core/bundle/runner.zig` via its injected
/// `Dispatcher`. Argv parsing stays in `execute`; this seam is what lets
/// core/bundle share orchestration without importing `cli/*`.
///
/// `allocator` must be an arena: dep-job per-string fields are not freed
/// individually (only top-level jobs are scrubbed by `dropTopLevelJobs`).
pub fn installAll(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    packages: []const []const u8,
    opts: InstallAllOpts,
) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    if (opts.cask) try argv.append(allocator, "--cask");
    for (packages) |p| try argv.append(allocator, p);
    return executeWithOpts(ctx, allocator, argv.items, .{ .skip_lock = opts.skip_lock });
}

/// Internal options that don't have an argv form. Kept private so the
/// non-argv flags (currently just lock ownership) stay an in-process
/// contract instead of leaking into the user-visible flag surface.
const ExecuteOpts = struct {
    skip_lock: bool = false,
};

const InstallFlag = enum {
    cask,
    formula,
    dry_run,
    force,
    local,
    use_system_ruby,
    quiet,
    json,
    only_dependencies,
};

const install_flag_map = std.StaticStringMap(InstallFlag).initComptime(.{
    .{ "--cask", .cask },
    .{ "--formula", .formula },
    .{ "--dry-run", .dry_run },
    .{ "--force", .force },
    .{ "--local", .local },
    .{ "--use-system-ruby", .use_system_ruby },
    .{ "--quiet", .quiet },
    .{ "-q", .quiet },
    .{ "--json", .json },
    .{ "--only-dependencies", .only_dependencies },
});

/// `allocator` must be an arena (see `installAll`).
pub fn execute(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8) !void {
    return executeWithOpts(ctx, allocator, args, .{});
}

fn executeWithOpts(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    exec_opts: ExecuteOpts,
) !void {
    if (help.showIfRequested(ctx, args, "install")) return;

    // Parse flags
    var packages: std.ArrayList([]const u8) = .empty;
    defer packages.deinit(allocator);
    var force_cask = false;
    var force_formula = false;
    // Honour the global `--dry-run` flag consumed by main.zig, while still
    // allowing programmatic callers to pass `--dry-run` directly in `args`.
    var dry_run = output.isDryRun();
    var force = false;
    // Scoped `--use-system-ruby` — a bare flag with multiple formulas would
    // let a DSL parse failure on one silently widen Ruby trust across the rest.
    var use_system_ruby_bare = false;
    var use_system_ruby_scope: std.ArrayList([]const u8) = .empty;
    defer use_system_ruby_scope.deinit(allocator);
    // `--local` forces .rb-path interpretation — explicit trust opt-in in
    // argv instead of shape-based autodetection.
    var local_only = false;
    // brew parity: resolve the dep graph, bail before the requested package's
    // materialise+link. Deps stay marked `dependency` for `mt purge --unused-deps`.
    var only_dependencies = false;

    // StaticStringMap + exhaustive switch: the compiler checks every flag
    // has a handler, so adding a new variant without wiring it fails to build.
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--use-system-ruby=")) {
            const list = arg["--use-system-ruby=".len..];
            var it = std.mem.splitScalar(u8, list, ',');
            while (it.next()) |name| {
                if (name.len > 0) try use_system_ruby_scope.append(allocator, name);
            }
            continue;
        }
        if (install_flag_map.get(arg)) |flag| switch (flag) {
            .cask => force_cask = true,
            .formula => force_formula = true,
            .dry_run => dry_run = true,
            .force => force = true,
            .local => local_only = true,
            .use_system_ruby => use_system_ruby_bare = true,
            .quiet => output.setQuiet(true),
            .json => output.setMode(.json),
            .only_dependencies => only_dependencies = true,
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            packages.append(allocator, arg) catch return error.OutOfMemory;
        }
    }

    if (local_only and packages.items.len == 0) {
        // `error.Aborted` per the main.zig contract — avoids a raw stack trace.
        output.err("--local requires a path to a .rb file", .{});
        return error.Aborted;
    }

    // Refuse ambiguous argv so `--local` cannot silently drop another mode.
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

    // Refuse self-install in every shape the dispatcher accepts.
    // `mt version update` is the supported upgrade channel; letting
    // install proceed would relink `<prefix>/bin/malt` outside its
    // rev/origin tracking.
    for (packages.items) |pkg| {
        if (isSelfInstall(pkg)) {
            output.err("Refusing to install malt itself ('{s}'). Use 'mt version update' to upgrade.", .{pkg});
            return error.Aborted;
        }
    }

    // Bare `--use-system-ruby` only valid for a single formula; otherwise
    // require an explicit scope.
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
    const prefix = atomic.maltPrefixOrAbort();

    // Absurdly long prefixes overflow install_name_tool's load-command slots.
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

    // Idempotent fast path — skip DB / lock / HTTP setup when every named
    // arg already has a Cellar entry. Flags that change semantics
    // (--force / --cask / --local / --dry-run / --only-dependencies) and
    // tap-form / .rb-path args route to the regular flow. All-or-nothing
    // on multi-arg keeps the gate state-free.
    const fastpath_eligible = !force and !force_cask and !local_only and
        !dry_run and !only_dependencies;
    if (fastpath_eligible) fast: {
        for (packages.items) |pkg| {
            if (isTapFormula(pkg) or isLocalFormulaPath(pkg)) break :fast;
            if (!kegPresent(ctx, prefix, pkg)) break :fast;
        }
        for (packages.items) |pkg| {
            output.info("{s} is already installed", .{pkg});
            // Fast-path skips the protocol; positive signal so consumers
            // can tell idempotent success from "command never ran".
            output.emitNdjsonEvent(.already_installed, pkg, null);
        }
        return;
    }

    // Ensure required directories exist (Step 0)
    ensureDirs(ctx, prefix) catch return error.Aborted;

    // Open database
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch
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

    // Acquire lock (Step 1) — skipped when the caller already owns it.
    // BSD `flock` is per-fd, so a re-entry from the same process (e.g.
    // upgrade -> installAll for missing transitive deps) would
    // EAGAIN-loop against its own hold and time out as fake contention.
    var lk: ?lock_mod.LockFile = null;
    if (!exec_opts.skip_lock) {
        var lock_path_buf: [512]u8 = undefined;
        const lock_path = std.fmt.bufPrint(&lock_path_buf, "{s}/db/malt.lock", .{prefix}) catch
            return InstallError.LockError;
        lk = lock_mod.LockFile.acquire(ctx.io, lock_path, 30000) catch {
            output.err("Another mt process is running. Wait or run mt doctor.", .{});
            return InstallError.LockError;
        };
        output.emitNdjsonEvent(.lock_acquired, "", null);
    }
    defer if (lk) |*l| l.release(ctx.io);
    // LIFO: install_complete must precede release in the deferred chain,
    // and the outer holder owns the matching pair when we skipped here.
    defer if (lk != null and output.isNdjson()) output.emitNdjsonEvent(.install_complete, "", null);

    // Main-thread HTTP client; workers borrow from `http_pool` instead.
    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, allocator);
    defer http.deinit();

    // 4-slot worker pool — same budget as the materialize pool; enough to
    // saturate cold installs while reusing TLS contexts.
    var http_pool = client_mod.HttpClientPool.init(ctx.io, ctx.environ, allocator, 4) catch {
        output.err("Failed to initialise HTTP client pool", .{});
        return InstallError.DownloadFailed;
    };
    defer http_pool.deinit();

    // Set up API client
    var cache_dir_buf: [512]u8 = undefined;
    const cache_dir = std.fmt.bufPrint(&cache_dir_buf, "{s}/cache", .{prefix}) catch return;
    var api = api_mod.BrewApi.init(ctx.io, allocator, &http, cache_dir);

    // Set up GHCR client
    var ghcr = ghcr_mod.GhcrClient.init(ctx.io, allocator, &http);
    defer ghcr.deinit();

    // Set up store + linker
    var store = store_mod.Store.init(ctx.io, allocator, &db, prefix);
    var linker = linker_mod.Linker.init(ctx.io, allocator, &db, prefix);

    // One parsed-formula cache for the whole run; single free site.
    var formula_cache = deps_mod.FormulaCache.init(allocator);
    defer formula_cache.deinit();

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

        // Path wins over tap-form when `.rb` is present — a typo like
        // `user/repo/foo.rb` hits local-file error, not a GitHub 404.
        if (local_only or isLocalFormulaPath(pkg_name)) {
            installLocalFormula(ctx, allocator, pkg_name, &db, &linker, prefix, dry_run, force) catch |e| {
                // Skip the generic summary when the inner error line already
                // told the user what went wrong.
                if (!localErrorIsAnnounced(e)) {
                    output.err("Failed to install {s}: {s}", .{ pkg_name, @errorName(e) });
                }
            };
            continue;
        }

        // Handle tap formulas separately (they don't use GHCR)
        if (isTapFormula(pkg_name)) {
            installTapFormula(ctx, allocator, pkg_name, &db, &linker, prefix, dry_run, force) catch |e| {
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
                installCask(ctx, allocator, pkg_name, &db, &api, dry_run) catch |e| {
                    output.err("Failed to install {s}: {s}", .{ pkg_name, @errorName(e) });
                };
                continue;
            };

            // Skip the cask read+parse when no cask is cached — single stat.
            if (!force_formula and api.cachedExists(pkg_name, .cask)) {
                if (api.fetchCask(pkg_name)) |cask_json| {
                    allocator.free(cask_json);
                    output.info("{s} exists as both a formula and a cask. Installing formula. Use --cask to install the cask instead.", .{pkg_name});
                } else |_| {}
            }

            // Collect jobs for this formula + its deps
            collectFormulaJobs(.{
                .io = ctx.io,
                .allocator = allocator,
                .api = &api,
                .http_pool = &http_pool,
                .db = &db,
                .store = &store,
                .cache = &formula_cache,
            }, pkg_name, formula_json, force, &all_jobs) catch |e| {
                output.err("Failed to resolve {s}: {s}", .{ pkg_name, @errorName(e) });
                continue;
            };
            output.emitNdjsonEvent(.resolved, pkg_name, null);
        } else {
            installCask(ctx, allocator, pkg_name, &db, &api, dry_run) catch |e| {
                output.err("Failed to install {s}: {s}", .{ pkg_name, @errorName(e) });
            };
        }
    }

    // top-level skipped; deps still recorded for GC. Surviving jobs keep
    // `is_dep=true`, so `linkAndRecord` writes `install_reason='dependency'`
    // and `mt purge --unused-deps` reclaims them once nothing direct retains them.
    if (only_dependencies) dropTopLevelJobs(allocator, &all_jobs);

    if (all_jobs.items.len == 0) return;

    if (dry_run) {
        output.info("Dry run: would install {d} package(s):", .{all_jobs.items.len});
        for (all_jobs.items) |job| {
            const tag: []const u8 = if (job.is_dep) " (dependency)" else "";
            output.info("  {s} {s}{s}", .{ job.name, job.version_str, tag });
            // No transition outcome to report on a plan-only run.
            output.emitNdjsonEvent(.would_install, job.name, null);
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

        // Fold every repo into one multi-scope `/token` round-trip; workers
        // hit the cache instead of racing. Bookkeeping OOM must propagate —
        // only the token fetch itself is best-effort.
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
            defer http_pool.release(pre_http);
            // Best-effort cache warm — any failure (OOM or network) is
            // absorbed so workers fall back to per-repo fetchToken calls.
            ghcr.prefetchTokens(pre_http, repos.items) catch {};
        }

        // Set up multi-progress: assign line indices and create coordinator
        const download_index = assignDownloadLineIndices(all_jobs.items);
        var multi = progress_mod.MultiProgress.init(download_index);
        // Anchor the DECSET pair to scope exit so an early return between
        // here and the worker join doesn't leave the terminal in DECRESET.
        defer multi.finish();

        // Main-thread bar allocation — draw an initial frame on every line
        // before workers spawn, and keep pointers stable for them.
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
                ctx.io, allocator, &ghcr, &http_pool, &store, job,
            }) catch {
                downloadWorker(ctx.io, allocator, &ghcr, &http_pool, &store, job);
                continue;
            };
            threads.append(allocator, t) catch {
                t.join();
                continue;
            };
        }

        for (threads.items) |t| t.join();
    }

    // Emit from the main thread so ndjson order is deterministic
    // regardless of worker interleaving.
    if (output.isNdjson()) {
        for (all_jobs.items) |job| {
            if (!job.succeeded) continue;
            output.emitNdjsonEvent(.downloaded, job.name, "ok");
            output.emitNdjsonEvent(.extracted, job.name, "ok");
            output.emitNdjsonEvent(.stored, job.name, "ok");
        }
    }

    // Check for Ctrl-C between download and materialize phases
    if (main_mod.isInterrupted()) {
        output.warn("Interrupted. Cleaning up...", .{});
        return;
    }

    // `--force` pre-materialize: the cellar's clonefile/copy refuses
    // to overwrite a populated dir, so wipe the resolved-version dir
    // up front. The destructive part of the cleanup — dropping stale
    // DB rows, unlinking prior symlinks, sweeping orphan dirs — is
    // deferred to the serial link phase below so a materialize crash
    // leaves the user's prior keg + row intact for the revision-bump
    // case. Pin survives because INSERT OR REPLACE in `recordKeg`
    // inherits via COALESCE-MAX on `pinned` by name.
    if (force) {
        for (all_jobs.items) |job| {
            pruneCellarForReinstall(ctx, prefix, job.name, job.version_str);
        }
    }

    // ── Parallel materialize phase ──────────────────────────────────
    // Materialize steps are per-keg independent; shared state is deferred
    // to the serial link phase. 4-worker cap — unbounded spawn regressed
    // warm ffmpeg via page-cache + codesign contention.
    const mats = allocator.alloc(MaterializeResult, all_jobs.items.len) catch
        return InstallError.CellarFailed;
    defer allocator.free(mats);
    for (mats) |*m| m.* = .{ .ok = false, .err = null };

    {
        const max_workers: usize = 4;
        const worker_count = @min(max_workers, all_jobs.items.len);

        var pool_ctx: MaterializePool = .{
            .io = ctx.io,
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
    // Runs in dep order so `findFailedDep` propagates failures down the
    // graph; linker + SQLite writes cannot be parallelised.
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
            output.emitNdjsonEvent(.materialized, job.name, "failed");
            try failed_kegs.put(job.name, {});
            failed_count += 1;
            continue;
        }
        output.emitNdjsonEvent(.materialized, job.name, "ok");

        // Failed-dep → skip: installing on a broken graph yields a dyld-unresolvable
        // keg. Remove the already-materialised keg so orphans don't linger.
        if (findFailedDep(&formula_cache, &failed_kegs, job.name, job.formula_json)) |failed_dep| {
            output.warn(
                "Skipping {s}: dependency {s} failed to install",
                .{ job.name, failed_dep },
            );
            // orphan keg cleanup; user already sees the skip warning above.
            cellar_mod.remove(ctx.io, prefix, job.name, job.version_str) catch {};
            try failed_kegs.put(job.name, {});
            failed_count += 1;
            continue;
        }

        // `--force` pre-link: clear every same-name prior install's
        // symlinks so `linker.checkConflicts` sees a clean state in
        // `linkAndRecord` below. Rows + dependencies + dirs stay so
        // `recordKeg`'s COALESCE-MAX subquery can still inherit the
        // user pin from the prior row.
        if (force) {
            unlinkSameVersionKegLinks(&linker, &db, job.name, mats[i].kegPath());
            unlinkStaleKegLinks(&db, &linker, job.name, mats[i].kegPath());
        }

        linkAndRecord(ctx.io, allocator, job, mats[i].kegPath(), &db, &linker, prefix, &formula_cache) catch {
            // The underlying error was already logged with a tag by
            // linkAndRecord — just record that this job failed so its
            // dependents in the rest of the loop get skipped above.
            try failed_kegs.put(job.name, {});
            failed_count += 1;
            continue;
        };

        // `--force` post-link: now that `recordKeg` has inserted the
        // new row (and inherited any pin via COALESCE-MAX), it is
        // safe to drop the prior other-version rows + their dirs.
        // Disk safety net catches any cellar dir without a row.
        if (force) {
            dropStaleKegRows(ctx, allocator, &db, job.name, mats[i].kegPath());
            pruneOtherCellarVersionsForReinstall(ctx, allocator, prefix, job.name, job.version_str);
        }

        if (job.post_install_defined) {
            drive(ctx, allocator, job.name, job.version_str, job.formula_json, prefix, use_system_ruby_list, &formula_cache);
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

/// Link + record a materialised keg. Must run serially: linker conflict
/// checks read live symlink state and SQLite is single-writer.
fn linkAndRecord(
    io: std.Io,
    allocator: std.mem.Allocator,
    job: *DownloadJob,
    keg_path: []const u8,
    db: *sqlite.Database,
    linker: *linker_mod.Linker,
    prefix: []const u8,
    cache: *deps_mod.FormulaCache,
) !void {
    const reason: []const u8 = if (job.is_dep) "dependency" else "direct";

    // Cache hit on the warm path; miss only happens for jobs whose JSON
    // never reached collectFormulaJobs (none today).
    const formula = cache.get(job.name) orelse blk: {
        break :blk cache.getOrParse(job.name, job.formula_json) catch |err| {
            output.err("Failed to parse formula for {s}: {s}", .{ job.name, @errorName(err) });
            cellar_mod.remove(io, prefix, job.name, job.version_str) catch {};
            return InstallError.CellarFailed;
        };
    };

    // Check for symlink conflicts before linking
    if (!job.keg_only) {
        const conflicts = linker.checkConflicts(keg_path) catch &.{};
        if (conflicts.len > 0) {
            output.err("{s}: {d} symlink conflict(s) detected:", .{ job.name, conflicts.len });
            for (conflicts) |conflict| {
                output.err("  {s} already linked by {s}", .{ conflict.link_path, conflict.existing_keg });
            }
            output.err("Use --force to overwrite, or uninstall the conflicting package first.", .{});
            cellar_mod.remove(io, prefix, job.name, job.version_str) catch {};
            return InstallError.LinkFailed;
        }
    }

    // Link + record
    if (!job.keg_only) {
        const keg_id = recordKeg(db, formula, job.store_sha256, keg_path, reason) catch |err| {
            output.err("Failed to record {s} in database: {s}", .{ job.name, @errorName(err) });
            cellar_mod.remove(io, prefix, job.name, job.version_str) catch {};
            return InstallError.RecordFailed;
        };

        linker.link(keg_path, job.name, keg_id) catch |err| {
            output.err("Failed to link {s}: {s}", .{ job.name, @errorName(err) });
            output.emitNdjsonEvent(.linked, job.name, "failed");
            // Rollback: unlink what was partially created + remove DB record + cellar.
            linker.unlink(keg_id) catch {};
            deleteKeg(db, keg_id);
            cellar_mod.remove(io, prefix, job.name, job.version_str) catch {};
            return InstallError.LinkFailed;
        };
        // `recorded` after both succeed — link rollback undoes the keg
        // row, so an early emit would lie if `linked:failed` follows.
        output.emitNdjsonEvent(.linked, job.name, "ok");
        output.emitNdjsonEvent(.recorded, job.name, "ok");
        linker.linkOpt(job.name, job.version_str) catch {};
        recordDeps(db, keg_id, formula);
    } else {
        const keg_id = recordKeg(db, formula, job.store_sha256, keg_path, reason) catch |err| {
            output.err("Failed to record {s} in database: {s}", .{ job.name, @errorName(err) });
            cellar_mod.remove(io, prefix, job.name, job.version_str) catch {};
            return InstallError.RecordFailed;
        };
        // keg-only has no public link phase to roll back.
        output.emitNdjsonEvent(.recorded, job.name, "ok");
        linker.linkOpt(job.name, job.version_str) catch {};
        recordDeps(db, keg_id, formula);
    }
    maybeRegisterService(io, allocator, db, formula, prefix);
    // Annotate keg-only packages inline so the single line reads as success,
    // not as a "not linking" warning paired with a separate ✓.
    const keg_only_suffix: []const u8 = if (job.keg_only) " (keg-only — dependency only)" else "";
    output.success("{s} {s} installed{s}", .{ job.name, job.version_str, keg_only_suffix });
}

/// Register a launchd service when the formula carries a `service:` block.
/// Best-effort: failures warn but don't fail the install.
fn maybeRegisterService(
    io: std.Io,
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
        // launchd creates the file on first run; missing dir surfaces there.
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
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

    supervisor_mod.register(.{ .allocator = allocator, .io = io, .db = db }, spec, formula.name, false, cellar_path, prefix) catch |err| {
        output.warn("could not register service for {s}: {s}", .{ formula.name, @errorName(err) });
    };
}

/// HEAD-based fallback for extensionless cask URLs.
/// Follows redirects to discover the real file extension.
fn resolveCaskArtifactViaHead(ctx: *const AppCtx, allocator: std.mem.Allocator, url: []const u8) cask_mod.ArtifactType {
    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, allocator);
    defer http.deinit();

    var resolved = http.headResolved(url) catch return .unknown;
    defer resolved.deinit();

    return cask_mod.resolveArtifactType(allocator, resolved.final_url, resolved.content_disposition);
}

/// Install a cask (DMG, ZIP, or PKG).
fn installCask(
    ctx: *const AppCtx,
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
        artifact_type = resolveCaskArtifactViaHead(ctx, allocator, cask.url);
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

    const prefix = atomic.maltPrefixOrAbort();

    var installer = cask_mod.CaskInstaller.init(ctx.io, ctx.environ, allocator, db, prefix);
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

    // Core API casks have no third-party tap origin to record.
    cask_mod.recordInstall(db, &cask, app_path, null) catch {
        output.warn("Failed to record cask {s} in database", .{cask.token});
    };
    allocator.free(app_path);

    output.success("{s} {s} installed", .{ cask.token, cask.version });
}

test "kegPresent returns true only when <prefix>/Cellar/<name> exists" {
    const testing = std.testing;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: AppCtx = .{ .io = threaded.io(), .environ = .empty };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ts = std.Io.Clock.real.now(ctx.io).toNanoseconds();
    const prefix = try std.fmt.bufPrint(
        &path_buf,
        "/tmp/malt_kegpresent_{d}",
        .{ts},
    );
    std.Io.Dir.cwd().deleteTree(ctx.io, prefix) catch {};
    try std.Io.Dir.cwd().createDirPath(ctx.io, prefix);
    defer std.Io.Dir.cwd().deleteTree(ctx.io, prefix) catch {};

    try testing.expect(!kegPresent(&ctx, prefix, "ghost"));

    var keg_buf: [std.fs.max_path_bytes]u8 = undefined;
    const keg = try std.fmt.bufPrint(&keg_buf, "{s}/Cellar/ghost", .{prefix});
    try std.Io.Dir.cwd().createDirPath(ctx.io, keg);

    try testing.expect(kegPresent(&ctx, prefix, "ghost"));
    try testing.expect(!kegPresent(&ctx, prefix, "other"));
}

// `--force` that resolves to a new revision (e.g. 10.47 → 10.47_1)
// must not orphan the prior keg dir: doctor walks the whole Cellar
// tree and would flag the abandoned unpatched binaries forever.
test "pruneOtherCellarVersionsForReinstall removes sibling versions but keeps the named one" {
    const testing = std.testing;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: AppCtx = .{ .io = threaded.io(), .environ = .empty };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ts = std.Io.Clock.real.now(ctx.io).toNanoseconds();
    const prefix = try std.fmt.bufPrint(&path_buf, "/tmp/malt_prune_siblings_{d}", .{ts});
    std.Io.Dir.cwd().deleteTree(ctx.io, prefix) catch {};
    try std.Io.Dir.cwd().createDirPath(ctx.io, prefix);
    defer std.Io.Dir.cwd().deleteTree(ctx.io, prefix) catch {};

    var old_buf: [std.fs.max_path_bytes]u8 = undefined;
    const old_keg = try std.fmt.bufPrint(&old_buf, "{s}/Cellar/pcre2/10.47/bin", .{prefix});
    try std.Io.Dir.cwd().createDirPath(ctx.io, old_keg);

    var new_buf: [std.fs.max_path_bytes]u8 = undefined;
    const new_keg = try std.fmt.bufPrint(&new_buf, "{s}/Cellar/pcre2/10.47_1/bin", .{prefix});
    try std.Io.Dir.cwd().createDirPath(ctx.io, new_keg);

    pruneOtherCellarVersionsForReinstall(&ctx, testing.allocator, prefix, "pcre2", "10.47_1");

    var old_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const old_root = try std.fmt.bufPrint(&old_root_buf, "{s}/Cellar/pcre2/10.47", .{prefix});
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(ctx.io, old_root, .{}));

    var new_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const new_root = try std.fmt.bufPrint(&new_root_buf, "{s}/Cellar/pcre2/10.47_1", .{prefix});
    try std.Io.Dir.accessAbsolute(ctx.io, new_root, .{});
}

test "pruneOtherCellarVersionsForReinstall is a no-op when only the kept version exists" {
    const testing = std.testing;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: AppCtx = .{ .io = threaded.io(), .environ = .empty };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ts = std.Io.Clock.real.now(ctx.io).toNanoseconds();
    const prefix = try std.fmt.bufPrint(&path_buf, "/tmp/malt_prune_siblings_solo_{d}", .{ts});
    std.Io.Dir.cwd().deleteTree(ctx.io, prefix) catch {};
    try std.Io.Dir.cwd().createDirPath(ctx.io, prefix);
    defer std.Io.Dir.cwd().deleteTree(ctx.io, prefix) catch {};

    var keep_buf: [std.fs.max_path_bytes]u8 = undefined;
    const keep_keg = try std.fmt.bufPrint(&keep_buf, "{s}/Cellar/libgit2/1.9.3/lib", .{prefix});
    try std.Io.Dir.cwd().createDirPath(ctx.io, keep_keg);

    pruneOtherCellarVersionsForReinstall(&ctx, testing.allocator, prefix, "libgit2", "1.9.3");

    var keep_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const keep_root = try std.fmt.bufPrint(&keep_root_buf, "{s}/Cellar/libgit2/1.9.3", .{prefix});
    try std.Io.Dir.accessAbsolute(ctx.io, keep_root, .{});
}

test "pruneOtherCellarVersionsForReinstall is a no-op when the package dir does not exist" {
    const testing = std.testing;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: AppCtx = .{ .io = threaded.io(), .environ = .empty };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ts = std.Io.Clock.real.now(ctx.io).toNanoseconds();
    const prefix = try std.fmt.bufPrint(&path_buf, "/tmp/malt_prune_siblings_absent_{d}", .{ts});
    std.Io.Dir.cwd().deleteTree(ctx.io, prefix) catch {};
    try std.Io.Dir.cwd().createDirPath(ctx.io, prefix);
    defer std.Io.Dir.cwd().deleteTree(ctx.io, prefix) catch {};

    // No `Cellar/ghost` ever created — sweep must not fault, panic, or leak.
    pruneOtherCellarVersionsForReinstall(&ctx, testing.allocator, prefix, "ghost", "1.0");
}

// A user holding several prior revisions (pinned at name level, repeated
// force-reinstalls across revisions) is the realistic shape behind the
// original report. All N-1 stale dirs must go in one sweep.
test "pruneOtherCellarVersionsForReinstall sweeps multiple stale siblings in one pass" {
    const testing = std.testing;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: AppCtx = .{ .io = threaded.io(), .environ = .empty };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ts = std.Io.Clock.real.now(ctx.io).toNanoseconds();
    const prefix = try std.fmt.bufPrint(&path_buf, "/tmp/malt_prune_siblings_many_{d}", .{ts});
    std.Io.Dir.cwd().deleteTree(ctx.io, prefix) catch {};
    try std.Io.Dir.cwd().createDirPath(ctx.io, prefix);
    defer std.Io.Dir.cwd().deleteTree(ctx.io, prefix) catch {};

    const versions = [_][]const u8{ "10.46", "10.47", "10.47_1", "10.48" };
    for (versions) |v| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = try std.fmt.bufPrint(&buf, "{s}/Cellar/pcre2/{s}/bin", .{ prefix, v });
        try std.Io.Dir.cwd().createDirPath(ctx.io, dir);
    }

    pruneOtherCellarVersionsForReinstall(&ctx, testing.allocator, prefix, "pcre2", "10.48");

    for (versions) |v| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = try std.fmt.bufPrint(&buf, "{s}/Cellar/pcre2/{s}", .{ prefix, v });
        if (std.mem.eql(u8, v, "10.48")) {
            try std.Io.Dir.accessAbsolute(ctx.io, root, .{});
        } else {
            try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(ctx.io, root, .{}));
        }
    }
}

// Stray non-directory entries under `Cellar/<name>/` (e.g. a leftover
// `.DS_Store` or a user-created marker file) must be left alone. The
// sweep targets version dirs, not arbitrary cleanup.
test "pruneOtherCellarVersionsForReinstall ignores non-directory entries" {
    const testing = std.testing;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: AppCtx = .{ .io = threaded.io(), .environ = .empty };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ts = std.Io.Clock.real.now(ctx.io).toNanoseconds();
    const prefix = try std.fmt.bufPrint(&path_buf, "/tmp/malt_prune_siblings_files_{d}", .{ts});
    std.Io.Dir.cwd().deleteTree(ctx.io, prefix) catch {};
    try std.Io.Dir.cwd().createDirPath(ctx.io, prefix);
    defer std.Io.Dir.cwd().deleteTree(ctx.io, prefix) catch {};

    var pkg_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pkg_path = try std.fmt.bufPrint(&pkg_buf, "{s}/Cellar/pcre2", .{prefix});
    try std.Io.Dir.cwd().createDirPath(ctx.io, pkg_path);

    var stray_buf: [std.fs.max_path_bytes]u8 = undefined;
    const stray = try std.fmt.bufPrint(&stray_buf, "{s}/.DS_Store", .{pkg_path});
    {
        const f = try std.Io.Dir.cwd().createFile(ctx.io, stray, .{});
        defer f.close(ctx.io);
        try f.writeStreamingAll(ctx.io, "stray");
    }

    var keep_buf: [std.fs.max_path_bytes]u8 = undefined;
    const keep_keg = try std.fmt.bufPrint(&keep_buf, "{s}/10.47_1/bin", .{pkg_path});
    try std.Io.Dir.cwd().createDirPath(ctx.io, keep_keg);

    pruneOtherCellarVersionsForReinstall(&ctx, testing.allocator, prefix, "pcre2", "10.47_1");

    try std.Io.Dir.accessAbsolute(ctx.io, stray, .{});
}

// Realistic call-site shape: `pruneCellarForReinstall` runs first and
// removes the keep_version dir, then the sweep runs against a state
// where keep_version no longer exists on disk. Sweep must still wipe
// the stale siblings without faulting on the missing target.
test "pruneOtherCellarVersionsForReinstall tolerates keep_version absent on disk" {
    const testing = std.testing;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: AppCtx = .{ .io = threaded.io(), .environ = .empty };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ts = std.Io.Clock.real.now(ctx.io).toNanoseconds();
    const prefix = try std.fmt.bufPrint(&path_buf, "/tmp/malt_prune_siblings_nokeep_{d}", .{ts});
    std.Io.Dir.cwd().deleteTree(ctx.io, prefix) catch {};
    try std.Io.Dir.cwd().createDirPath(ctx.io, prefix);
    defer std.Io.Dir.cwd().deleteTree(ctx.io, prefix) catch {};

    var stale_buf: [std.fs.max_path_bytes]u8 = undefined;
    const stale = try std.fmt.bufPrint(&stale_buf, "{s}/Cellar/pcre2/10.47/bin", .{prefix});
    try std.Io.Dir.cwd().createDirPath(ctx.io, stale);

    pruneOtherCellarVersionsForReinstall(&ctx, testing.allocator, prefix, "pcre2", "10.47_1");

    var stale_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const stale_root = try std.fmt.bufPrint(&stale_root_buf, "{s}/Cellar/pcre2/10.47", .{prefix});
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(ctx.io, stale_root, .{}));
}
