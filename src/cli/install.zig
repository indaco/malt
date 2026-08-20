//! malt — install command.
//! 9-step atomic install protocol for formulas, casks, and tap formulas.
//!
//! Thin orchestrator: `execute` parses argv, `installAll` is the non-argv
//! seam, and the rest is per-step `pub fn` + private helpers shared across
//! `install/*` siblings. The install/* submodules are reachable via
//! `lib.zig` (`install_args`, `install_download`, etc.) for tests; in-
//! process production callers reach this file only for `execute`,
//! `installAll`, and the cellar/link helpers below.

const std = @import("std");

const AppCtx = @import("../app_ctx.zig").AppCtx;
const cask_mod = @import("../core/cask.zig");
const cellar_mod = @import("../core/cellar.zig");
const deps_mod = @import("../core/deps.zig");
const formula_mod = @import("../core/formula.zig");
const linker_mod = @import("../core/linker.zig");
const plist_mod = @import("../core/services/plist.zig");
const supervisor_mod = @import("../core/services/supervisor.zig");
const signals = @import("../core/signals.zig");
const store_mod = @import("../core/store.zig");
const lock_mod = @import("../db/lock.zig");
const lock_report = @import("lock_report.zig");
const schema = @import("../db/schema.zig");
const sqlite = @import("../db/sqlite.zig");
const atomic = @import("../fs/atomic.zig");
const api_mod = @import("../net/api.zig");
const client_mod = @import("../net/client.zig");
const pool_mod = @import("../net/client_pool.zig");
const ghcr_mod = @import("../net/ghcr.zig");
const output = @import("../ui/output.zig");
const progress_mod = @import("../ui/progress.zig");
const help = @import("help.zig");
const args_mod = @import("install/args.zig");
const max_prefix_sane_len = args_mod.max_prefix_sane_len;
const checkPrefixSane = args_mod.checkPrefixSane;
const isTapFormula = args_mod.isTapFormula;
const isLocalFormulaPath = args_mod.isLocalFormulaPath;
const isSelfInstall = args_mod.isSelfInstall;
const download_mod = @import("install/download.zig");
const DownloadJob = download_mod.DownloadJob;
const collectFormulaJobs = download_mod.collectFormulaJobs;
const findFailedDep = download_mod.findFailedDep;
const dropTopLevelJobs = download_mod.dropTopLevelJobs;
const assignDownloadLineIndices = download_mod.assignDownloadLineIndices;
const MaterializeResult = download_mod.MaterializeResult;
const InstallPool = download_mod.InstallPool;
const installPoolWorker = download_mod.installPoolWorker;
const progressBridge = download_mod.progressBridge;
const ghcr_url_mod = @import("install/ghcr_url.zig");
const parseGhcrUrl = ghcr_url_mod.parseGhcrUrl;
const local_mod = @import("install/local.zig");
const installTapFormula = local_mod.installTapFormula;
const installLocalFormula = local_mod.installLocalFormula;
const post_install_mod = @import("install/post_install.zig");
const drive = post_install_mod.drive;
const rb_parse_mod = @import("install/rb_parse.zig");
const record_mod = @import("install/record.zig");
const InstallError = record_mod.InstallError;
/// Re-exported so `main`'s dispatch handler can exit quietly on an
/// already-printed install/upgrade failure (see `isReportedInstallError`).
pub const isReportedInstallError = record_mod.isReportedInstallError;
const recordKeg = record_mod.recordKeg;
const deleteKeg = record_mod.deleteKeg;
const recordDeps = record_mod.recordDeps;
const ensureDirs = record_mod.ensureDirs;
const localErrorIsAnnounced = record_mod.localErrorIsAnnounced;
const sink_mod = @import("install/sink.zig");
const OutputSink = sink_mod.OutputSink;

// Internal aliases for names the orchestrator body uses. Names not in
// this block are reached via their submodule (`args_mod.X`, etc.) or
// only consumed by tests through `lib.install_<sub>.X`.
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
    // The gate runs before the pipeline validates anything, so a dot-entry
    // like `.` or `..` would otherwise resolve to a directory that always
    // exists and report a bogus "already installed".
    if (name.len == 0 or name[0] == '.') return false;
    api_mod.validateName(name) catch return false;
    var buf: [512]u8 = undefined;
    const cellar_path = std.fmt.bufPrint(&buf, "{s}/Cellar/{s}", .{ prefix, name }) catch return false;
    std.Io.Dir.accessAbsolute(ctx.io, cellar_path, .{}) catch return false;
    return true;
}

/// Open `<prefix>/db/malt.db` only when it is already there. `Database.open`
/// carries `SQLITE_OPEN_CREATE`, and the fast path must not bring the DB
/// into existence just by probing it.
fn openExistingDb(ctx: *const AppCtx, prefix: []const u8) ?sqlite.Database {
    var buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&buf, "{s}/db/malt.db", .{prefix}, 0) catch return null;
    std.Io.Dir.accessAbsolute(ctx.io, path, .{}) catch return null;
    return sqlite.Database.open(path) catch null;
}

/// Presence probe for a `--cask` name. The `casks` row is the marker rather
/// than `Caskroom/<token>`: `recordCaskroom` is best-effort, so the
/// directory can be absent under a genuinely installed cask.
fn caskPresent(ctx: *const AppCtx, prefix: []const u8, token: []const u8) bool {
    var db = openExistingDb(ctx, prefix) orelse return false;
    defer db.close();
    return cask_mod.isInstalled(&db, token);
}

/// Presence probe for the `owner/repo/leaf` form, which resolves to either
/// a keg or a cask. The row's `tap` must match in both cases - without
/// that, `owner/repo/jq` would claim the homebrew/core `jq` as its own.
fn tapPackagePresent(ctx: *const AppCtx, prefix: []const u8, name: []const u8) bool {
    const parts = args_mod.parseTapName(name) orelse return false;

    var slug_buf: [256]u8 = undefined;
    const slug = std.fmt.bufPrint(&slug_buf, "{s}/{s}", .{ parts.user, parts.repo }) catch return false;

    var db = openExistingDb(ctx, prefix) orelse return false;
    defer db.close();

    // Cask by row alone; its Caskroom dir is best-effort. Keg by row plus
    // the Cellar entry, same as the plain-formula probe.
    if (local_mod.tapCaskRecorded(&db, parts.formula, slug)) return true;
    return kegPresent(ctx, prefix, parts.formula) and
        local_mod.tapKegRecorded(&db, parts.formula, slug);
}

/// Route one package name to the probe that matches how it would install.
/// Mirrors the slow path's dispatch order (tap form wins over `--cask`) so
/// the gate can never answer for a different install kind than the one the
/// pipeline would take. `--download-only` never reaches here: it vetoes the
/// gate outright, because warming a cache is work an installed package does
/// not excuse.
fn alreadyInstalled(ctx: *const AppCtx, prefix: []const u8, pkg: []const u8, flags: args_mod.InstallFlags) bool {
    if (isTapFormula(pkg)) return tapPackagePresent(ctx, prefix, pkg);
    if (flags.force_cask) return caskPresent(ctx, prefix, pkg);
    return kegPresent(ctx, prefix, pkg);
}

/// Read-only DB probe used by the fast-path gate. Returns true iff any
/// named pkg currently has `install_reason='dependency'` AND
/// `bin_isolated=1` — i.e. the user is asking us to promote a dep keg
/// the install pipeline must then re-link bin/sbin for. Quiet on
/// errors: a missing DB is the empty case, not a failure to surface.
fn anyNamedNeedsPromotion(ctx: *const AppCtx, prefix: []const u8, packages: []const []const u8) bool {
    var db = openExistingDb(ctx, prefix) orelse return false;
    defer db.close();

    var stmt = db.prepare(
        "SELECT 1 FROM kegs WHERE name=?1 AND install_reason='dependency' AND bin_isolated=1 LIMIT 1;",
    ) catch return false;
    defer stmt.finalize();

    for (packages) |pkg| {
        // Tap kegs are recorded under their leaf name, so the tap form has
        // to be reduced before it can match a row.
        const keg_name = if (args_mod.parseTapName(pkg)) |p| p.formula else pkg;
        stmt.reset() catch return false;
        stmt.bindText(1, keg_name) catch return false;
        if (stmt.step() catch false) return true;
    }
    return false;
}

/// Promote one named keg if it is currently an isolated dep: re-link
/// bin/sbin, then clear `bin_isolated` and set `install_reason='direct'`.
/// FS work happens before the DB update so a link failure leaves the
/// row's prior `bin_isolated=1` intact — coherent with the (still
/// absent) bin/sbin links and recoverable on retry.
fn promoteIsolatedDepIfAny(
    db: *sqlite.Database,
    linker: *linker_mod.Linker,
    name: []const u8,
) bool {
    var sel = db.prepare(
        "SELECT id, cellar_path FROM kegs WHERE name=?1 AND install_reason='dependency' AND bin_isolated=1 LIMIT 1;",
    ) catch return false;
    defer sel.finalize();
    sel.bindText(1, name) catch return false;
    const ok = sel.step() catch false;
    if (!ok) return false;
    const keg_id = sel.columnInt(0);
    const cellar_ptr = sel.columnText(1) orelse return false;
    const cellar = std.mem.sliceTo(cellar_ptr, 0);

    linker.link(cellar, name, keg_id, false) catch return false;
    // opt link already present on a promoted dep; best-effort refresh. The
    // dir is named by pkg_version (`<version>_<revision>`), so derive the
    // leaf from cellar_path — raw `version` would dangle for a revisioned dep.
    linker.linkOpt(name, std.fs.path.basename(cellar)) catch {};

    var upd = db.prepare(
        "UPDATE kegs SET install_reason='direct', bin_isolated=0 WHERE id=?1;",
    ) catch return false;
    defer upd.finalize();
    upd.bindInt(1, keg_id) catch return false;
    _ = upd.step() catch return false;

    return true;
}

pub const InstallAllOpts = struct {
    /// Treat every package as a cask; equivalent to `--cask`.
    cask: bool = false,
    /// Caller already owns `malt.lock` on a separate fd. BSD `flock` is
    /// per-fd, so re-entering `execute` from the same process would
    /// otherwise EAGAIN-loop against its own hold and 30 s-timeout with
    /// the misleading "another mt process is running" error.
    skip_lock: bool = false,
    /// Equivalent to `--isolate-deps` on the argv form. Mirrored on the
    /// opts struct so the bundle runner can opt in without spelling
    /// the flag out.
    isolate_deps: bool = false,
    /// Where per-keg human output goes. Defaults to the terminal sink
    /// (behaviour identical to `mt install`); the bundle runner passes a
    /// silent sink so its `Report` is the only channel.
    sink: OutputSink = sink_mod.terminal,
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
    // Build the typed flags directly — the bundle callers pass validated
    // package names, so there is nothing to re-scan or refuse in `parse`.
    return runInstall(ctx, allocator, packages, installFlagsFromOpts(opts), .{ .skip_lock = opts.skip_lock, .sink = opts.sink });
}

/// Map the non-argv `InstallAllOpts` onto the typed flags the argv path
/// would have parsed from `--cask` / `--isolate-deps`. Keeps the bundle
/// entry a struct construction instead of an argv round-trip.
fn installFlagsFromOpts(opts: InstallAllOpts) args_mod.InstallFlags {
    return .{ .force_cask = opts.cask, .isolate_deps = opts.isolate_deps };
}

/// Internal options that don't have an argv form. Kept private so the
/// non-argv flags (currently just lock ownership) stay an in-process
/// contract instead of leaking into the user-visible flag surface.
const ExecuteOpts = struct {
    skip_lock: bool = false,
    /// Where per-keg human output goes. Terminal for the argv path; the
    /// bundle runner threads a silent sink in via `installAll`.
    sink: OutputSink = sink_mod.terminal,
};

/// `allocator` must be an arena (see `installAll`).
pub fn execute(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8) !void {
    return executeWithOpts(ctx, allocator, args, .{});
}

/// Map a leaf refusal to its verbatim, caller-owned sink line + return code.
/// The rules live in `install/args.zig`; the words live here (the
/// `checkPrefixSane` precedent). Shared so the argv path and the struct-first
/// path emit byte-identical refusals. Always returns an error.
fn reportInstallRefusal(sink: OutputSink, refusal: args_mod.Refusal) anyerror {
    switch (refusal.err) {
        .local_requires_path => sink.err("--local requires a path to a .rb file", .{}),
        .local_with_cask => sink.err("--local cannot be combined with --cask (a .rb file is never a cask)", .{}),
        .local_with_formula => sink.err("--local already selects formula mode; drop --formula", .{}),
        .local_with_system_ruby => sink.err("--local does not run post_install; --use-system-ruby has no effect and is refused", .{}),
        .download_only_with_only_deps => sink.err("--download-only cannot be combined with --only-deps", .{}),
        .no_packages => sink.err("No package names specified", .{}),
        .self_install => sink.err("Refusing to install malt itself ('{s}'). Use 'mt version update' to upgrade.", .{refusal.arg}),
        .ambiguous_system_ruby_scope => sink.err(
            "--use-system-ruby needs a scope when multiple packages are installed; use --use-system-ruby={s}[,<name>...]",
            .{refusal.arg},
        ),
    }
    return switch (refusal.err) {
        .no_packages => InstallError.NoPackages,
        .ambiguous_system_ruby_scope => InstallError.AmbiguousSystemRubyScope,
        // `error.Aborted` per the main.zig contract — avoids a raw stack trace.
        .local_requires_path,
        .local_with_cask,
        .local_with_formula,
        .local_with_system_ruby,
        .download_only_with_only_deps,
        .self_install,
        => error.Aborted,
    };
}

fn executeWithOpts(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    exec_opts: ExecuteOpts,
) !void {
    if (help.showIfRequested(ctx, args, "install")) return;

    // Single emission seam for this run; default forwards to `ui/output`.
    const sink = exec_opts.sink;

    // Parse + validate argv in the leaf: the rules live there, the words
    // stay caller-owned (the `checkPrefixSane` precedent). Each refusal maps
    // to its verbatim sink line + return code below. A scoped arena backs the
    // parsed package/scope slices; it stays alive across `runInstall` and is
    // reclaimed here even when the caller's allocator isn't itself an arena.
    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const parsed = switch (try args_mod.parse(parse_arena.allocator(), args)) {
        .ok => |p| p,
        .invalid => |v| return reportInstallRefusal(sink, v),
    };

    // Global side effects the UI-agnostic leaf can't apply: `--quiet` / `--json`
    // are surfaced by `parse` and applied once here.
    if (parsed.quiet) output.setQuiet(true);
    if (parsed.json) output.setMode(.json);

    return runInstall(ctx, allocator, parsed.packages, parsed.flags, exec_opts);
}

/// Struct-first install core shared by the argv path (`executeWithOpts`)
/// and the bundle path (`installAll`). Both hand it resolved packages +
/// typed flags; the only remaining orchestrator-owned flag fold is the
/// global `--dry-run` (consumed by main.zig), OR-ed in here.
fn runInstall(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    packages: []const []const u8,
    flags_in: args_mod.InstallFlags,
    exec_opts: ExecuteOpts,
) !void {
    const sink = exec_opts.sink;

    // Install-contract guard shared with the argv path (which ran it inside
    // `parse`). On the struct-first path it is the only place a self-install
    // or an empty list is refused, keeping both entry points symmetric.
    if (args_mod.checkInstallable(packages)) |refusal| return reportInstallRefusal(sink, refusal);

    // Resolve the dual-source dry-run once, for both entry points: the
    // per-command `--dry-run` flag OR the global `--dry-run` main.zig consumed.
    var flags = flags_in;
    flags.dry_run = flags.dry_run or output.isDryRun();

    // Initialize infrastructure
    const prefix = atomic.maltPrefixOrAbort();

    // Absurdly long prefixes overflow install_name_tool's load-command slots.
    checkPrefixSane(prefix) catch |err| switch (err) {
        error.PrefixAbsurd => {
            sink.err(
                "MALT_PREFIX '{s}' is {d} bytes, beyond the {d}-byte sanity cap.",
                .{ prefix, prefix.len, max_prefix_sane_len },
            );
            sink.err("Set MALT_PREFIX to a reasonable path and retry.", .{});
            return InstallError.PrefixAbsurd;
        },
    };

    // Idempotent fast path — skip DB / lock / HTTP setup when every named
    // arg is already installed. Flags that change semantics
    // (--force / --local / --dry-run / --only-deps) route to the regular
    // flow, as do `.rb`-path args: a local formula can change on disk with
    // no version bump, so it must be re-read. All-or-nothing on multi-arg
    // keeps the gate state-free.
    const fastpath_eligible = flags.fastpathEligible();
    if (fastpath_eligible) fast: {
        for (packages) |pkg| {
            if (isLocalFormulaPath(pkg)) break :fast;
            if (!alreadyInstalled(ctx, prefix, pkg, flags)) break :fast;
        }
        // Promotion target — a named pkg currently recorded as an
        // isolated dependency — needs `install_reason` cleared and
        // bin/sbin symlinks materialised. That work fails open the DB
        // and the lock, so it lives in the slow path; here we just
        // gate the early return.
        if (anyNamedNeedsPromotion(ctx, prefix, packages)) break :fast;
        for (packages) |pkg| {
            sink.info("{s} is already installed", .{pkg});
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
        sink.err("Failed to open database at {s}", .{db_path});
        return InstallError.DatabaseError;
    };
    defer db.close();

    // Initialize schema
    schema.initSchema(&db) catch {
        sink.err("Failed to initialize database schema", .{});
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
        lk = lock_mod.LockFile.acquire(ctx.io, lock_path, 30000) catch |e| switch (e) {
            // The DB is already open here, so db/ exists — DirMissing can't occur.
            error.DirMissing => return InstallError.LockError,
            // Emit via the sink so bundle mode stays quiet, with the same
            // per-error diagnostic the other commands surface.
            else => {
                var msg_buf: [512]u8 = undefined;
                sink.err("{s}", .{lock_report.acquireFailureMessage(&msg_buf, e, prefix)});
                return InstallError.LockError;
            },
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
    http.offline = ctx.offline;

    // 4-slot worker pool — same budget as the materialize pool; enough to
    // saturate cold installs while reusing TLS contexts.
    var http_pool = pool_mod.HttpClientPool.init(ctx.io, ctx.environ, allocator, 4) catch {
        sink.err("Failed to initialise HTTP client pool", .{});
        return InstallError.DownloadFailed;
    };
    defer http_pool.deinit();
    http_pool.setOfflineAll(ctx.offline);

    // Set up API client
    var cache_dir_buf: [512]u8 = undefined;
    // Pin the unreachable: prefix is sanity-capped + format suffix is fixed,
    // so a future bump to either side fails the build instead of the catch.
    comptime std.debug.assert(max_prefix_sane_len + "/cache".len + 1 <= cache_dir_buf.len);
    const cache_dir = std.fmt.bufPrint(&cache_dir_buf, "{s}/cache", .{prefix}) catch unreachable;
    var api = api_mod.BrewApi.init(ctx.io, allocator, &http, cache_dir);
    api.base_url = ctx.mirrors.api_base;
    api.offline = ctx.offline;

    // Set up GHCR client
    var ghcr = ghcr_mod.GhcrClient.init(ctx.io, allocator, &http);
    ghcr.base_url = ctx.mirrors.bottle_base;
    defer ghcr.deinit();

    // Set up store + linker
    var store = store_mod.Store.init(ctx.io, allocator, &db, prefix);
    var linker = linker_mod.Linker.init(ctx.io, allocator, &db, prefix);

    // Promote any named pkg currently recorded as an isolated dep.
    // Done before resolution so the subsequent flow sees the post-
    // promotion state ("direct + present") and `collectFormulaJobs`
    // correctly short-circuits without re-downloading the keg.
    for (packages) |pkg_name| {
        if (promoteIsolatedDepIfAny(&db, &linker, pkg_name)) {
            sink.success("{s} promoted to direct: bin/sbin links restored", .{pkg_name});
        }
    }

    // One parsed-formula cache for the whole run; single free site.
    var formula_cache = deps_mod.FormulaCache.init(allocator);
    defer formula_cache.deinit();

    // ── Collect all download jobs across all packages ────────────────
    var all_jobs: std.ArrayList(DownloadJob) = .empty;
    defer all_jobs.deinit(allocator);

    // Shared across resolution + link so a dispatch-time miss
    // surfaces the same PartialFailure the bottle phase already does.
    var failed_count: usize = 0;

    // Check for Ctrl-C before resolution phase
    if (signals.isInterrupted()) {
        sink.warn("Interrupted before resolution.", .{});
        return;
    }

    for (packages) |pkg_name| {
        // Check for Ctrl-C between packages during resolution
        if (signals.isInterrupted()) {
            sink.warn("Interrupted during resolution.", .{});
            // Surface counted misses so a Ctrl-C after some packages
            // already failed dispatch still exits non-zero.
            if (failed_count > 0) return InstallError.PartialFailure;
            return;
        }

        // Path wins over tap-form when `.rb` is present — a typo like
        // `user/repo/foo.rb` hits local-file error, not a GitHub 404.
        if (flags.local_only or isLocalFormulaPath(pkg_name)) {
            installLocalFormula(ctx, allocator, pkg_name, &db, &linker, prefix, flags.dry_run, flags.force, sink) catch |e| {
                // Skip the generic summary when the inner error line already
                // told the user what went wrong.
                if (!localErrorIsAnnounced(e)) {
                    sink.err("Failed to install {s}: {s}", .{ pkg_name, @errorName(e) });
                }
                failed_count += 1;
            };
            continue;
        }

        // Handle tap formulas separately (they don't use GHCR)
        if (isTapFormula(pkg_name)) {
            installTapFormula(ctx, allocator, pkg_name, &db, &linker, prefix, flags.dry_run, flags.force, flags.download_only, sink) catch |e| {
                // A source-build refusal already printed an actionable line
                // plus the `brew install` hint, so don't bury it under a
                // generic summary that just repeats the error enum name.
                // (installTapFormula's error set is wider than InstallError,
                // so this checks the one value rather than localErrorIsAnnounced.)
                if (e != InstallError.BuildFromSourceUnsupported) {
                    sink.err("Failed to install {s}: {s}", .{ pkg_name, @errorName(e) });
                }
                failed_count += 1;
            };
            continue;
        }

        // Try formula
        if (!flags.force_cask) {
            const formula_json = api.fetchFormula(pkg_name) catch |fetch_err| {
                // Offline misses route straight to a typed "snapshot
                // didn't have it" line instead of falling through to a
                // cask probe that would also miss with the same noise.
                if (fetch_err == api_mod.ApiError.OfflineRequired) {
                    sink.err("offline mode: formula '{s}' not cached", .{pkg_name});
                    failed_count += 1;
                    continue;
                }
                if (flags.force_formula) {
                    if (mapApiFetchError(fetch_err) != null) {
                        sink.err("Cannot reach Homebrew API for formula '{s}'", .{pkg_name});
                    } else {
                        sink.err("Formula '{s}' not found", .{pkg_name});
                    }
                    failed_count += 1;
                    continue;
                }
                // Try cask
                installCask(ctx, allocator, pkg_name, &db, &api, flags, sink) catch |e| {
                    if (e == api_mod.ApiError.OfflineRequired) {
                        sink.err("offline mode: '{s}' not cached as formula or cask", .{pkg_name});
                    } else {
                        sink.err("Failed to install {s}: {s}", .{ pkg_name, @errorName(e) });
                    }
                    failed_count += 1;
                };
                continue;
            };

            // Skip the cask read+parse when no cask is cached — single stat.
            if (!flags.force_formula and api.cachedExists(pkg_name, .cask)) {
                if (api.fetchCask(pkg_name)) |cask_json| {
                    allocator.free(cask_json);
                    sink.info("{s} exists as both a formula and a cask. Installing formula. Use --cask to install the cask instead.", .{pkg_name});
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
                .worker_backing = std.heap.smp_allocator,
                .sink = sink,
                .download_only = flags.download_only,
            }, pkg_name, formula_json, flags.force, &all_jobs) catch |e| {
                sink.err("Failed to resolve {s}: {s}", .{ pkg_name, @errorName(e) });
                failed_count += 1;
                continue;
            };
            output.emitNdjsonEvent(.resolved, pkg_name, null);
        } else {
            installCask(ctx, allocator, pkg_name, &db, &api, flags, sink) catch |e| {
                sink.err("Failed to install {s}: {s}", .{ pkg_name, @errorName(e) });
                failed_count += 1;
            };
        }
    }

    // top-level skipped; deps still recorded for GC. Surviving jobs keep
    // `is_dep=true`, so `linkAndRecord` writes `install_reason='dependency'`
    // and `mt purge --unused-deps` reclaims them once nothing direct retains them.
    if (flags.only_deps) dropTopLevelJobs(allocator, &all_jobs);

    if (all_jobs.items.len == 0) {
        // Resolution-only failures never reach the link loop's trailing
        // PartialFailure; surface it here so the exit code matches the
        // printed error. Clean empty runs (cask-only happy path) keep 0.
        if (failed_count > 0) return InstallError.PartialFailure;
        return;
    }

    if (flags.dry_run) {
        sink.info("Dry run: would install {d} package(s):", .{all_jobs.items.len});
        for (all_jobs.items) |job| {
            const tag: []const u8 = if (job.is_dep) " (dependency)" else "";
            sink.info("  {s} {s}{s}", .{ job.name, job.version_str, tag });
            // No transition outcome to report on a plan-only run.
            output.emitNdjsonEvent(.would_install, job.name, null);
        }
        // Mixed runs (one cached + one 404) print a partial plan; mirror
        // the empty-list gate so the exit code still reflects the miss.
        if (failed_count > 0) return InstallError.PartialFailure;
        return;
    }

    // ── Parallel download + materialize phase ────────────────────────
    // One bounded pool drives `installKegFromBottle` per keg, overlapping
    // download I/O with codesign CPU inside each worker rather than
    // staging them across two pools.

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

    // Results live across the pool join + the serial link phase below.
    const mats = allocator.alloc(MaterializeResult, all_jobs.items.len) catch
        return InstallError.CellarFailed;
    defer allocator.free(mats);
    for (mats) |*m| m.* = .{ .ok = false, .err = null };

    // `--download-only`: emit per-job `download_started` from the main
    // thread before the pool spawns so consumers see a deterministic
    // pre-fetch line. Paired with `download_complete` after the join.
    if (flags.download_only and output.isNdjson()) {
        for (all_jobs.items) |job| {
            output.emitNdjsonEvent(.download_started, job.name, null);
        }
    }

    // `--force` pre-materialize: clonefile refuses to overwrite a populated
    // keg dir, so wipe the resolved-version dir up front. Destructive DB +
    // symlink cleanup is deferred to the serial link phase so a materialize
    // crash leaves the user's prior keg + row intact for the revision-bump
    // case. Pin survives because `recordKeg` inherits via COALESCE-MAX on
    // `pinned` by name.
    if (flags.pruneForReinstall()) {
        for (all_jobs.items) |job| {
            pruneCellarForReinstall(ctx, prefix, job.name, job.version_str);
        }
    }

    {
        if (to_download > 0) {
            if (to_download == 1) {
                sink.info("Downloading 1 bottle...", .{});
            } else {
                sink.info("Downloading {d} bottles...", .{to_download});
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
        }

        // Multi-progress + bars only exist when at least one job downloads.
        // Warm-only installs skip terminal setup entirely; their pool
        // workers materialise without a progress callback. A non-terminal
        // sink (bundle) skips bars too — the global progress mode is
        // set-once and can't be quieted mid-run.
        var multi: ?progress_mod.MultiProgress = if (sink.show_progress and to_download > 0)
            progress_mod.MultiProgress.init(assignDownloadLineIndices(all_jobs.items))
        else
            null;
        // Anchor the DECSET pair to scope exit so an early return between
        // here and the worker join doesn't leave the terminal in DECRESET.
        defer if (multi) |*m| m.finish();

        var bars: []progress_mod.ProgressBar = &.{};
        defer if (bars.len > 0) allocator.free(bars);

        if (multi) |*m| {
            if (allocator.alloc(progress_mod.ProgressBar, m.total_lines)) |s| {
                bars = s;
            } else |_| {}
            var bar_idx: usize = 0;
            for (all_jobs.items) |*job| {
                if (job.succeeded) continue;
                job.multi = m;
                if (bar_idx < bars.len) {
                    bars[bar_idx] = progress_mod.ProgressBar.init(job.name, 0);
                    bars[bar_idx].label_width = max_name_len;
                    bars[bar_idx].line_index = job.line_index;
                    bars[bar_idx].multi = m;
                    job.bar = &bars[bar_idx];
                    // Draw the initial frame now so this line is not blank
                    // while the worker is waiting to be scheduled.
                    bars[bar_idx].update(0);
                    bar_idx += 1;
                }
            }
            // Hand the group its bars so the first worker to observe a resize
            // repaints every row at the new width. `bars` may be shorter than
            // the slice if alloc partially failed; pass the populated prefix.
            m.bars = bars[0..bar_idx];
        }

        // 4-worker cap — overlap download I/O with codesign CPU inside each
        // worker. Unbounded spawn regressed warm ffmpeg via page-cache +
        // codesign contention.
        const max_workers: usize = 4;
        const worker_count = @min(max_workers, all_jobs.items.len);

        var pool_ctx: InstallPool = .{
            .ctx = ctx,
            .next_idx = std.atomic.Value(usize).init(0),
            .jobs = all_jobs.items,
            .prefix = prefix,
            .ghcr = &ghcr,
            .http_pool = &http_pool,
            .store = &store,
            .cache = &formula_cache,
            .results = mats,
            .worker_backing = std.heap.smp_allocator,
            .download_only = flags.download_only,
            .sink = sink,
        };

        const pool_threads = allocator.alloc(std.Thread, worker_count) catch
            return InstallError.CellarFailed;
        defer allocator.free(pool_threads);

        var spawned: usize = 0;
        for (0..worker_count) |_| {
            if (std.Thread.spawn(.{}, installPoolWorker, .{&pool_ctx})) |t| {
                pool_threads[spawned] = t;
                spawned += 1;
            } else |_| {
                // Fall back to inline execution if spawn fails. The pool
                // loop will pick up remaining jobs on this thread.
                installPoolWorker(&pool_ctx);
            }
        }
        for (pool_threads[0..spawned]) |t| t.join();
    }

    // Emit from the main thread so ndjson order is deterministic
    // regardless of worker interleaving. Cross-keg invariant: every
    // succeeded job's `downloaded/extracted/stored` triple lands
    // before any `materialized` event — `.materialized` fires from
    // the serial link phase below so it stays interleaved with the
    // per-keg `linked/recorded` pair the consumers already expect.
    if (output.isNdjson()) {
        for (all_jobs.items) |job| {
            if (!job.succeeded) continue;
            output.emitNdjsonEvent(.downloaded, job.name, "ok");
            output.emitNdjsonEvent(.extracted, job.name, "ok");
            output.emitNdjsonEvent(.stored, job.name, "ok");
        }
    }

    // --download-only stops here. Skip the serial link phase and surface
    // each warmed bottle's `<prefix>/store/<sha>` path so a follow-up
    // real install can consume the bytes.
    if (flags.download_only) {
        for (all_jobs.items) |job| {
            if (!job.succeeded) {
                output.emitNdjsonEvent(.download_complete, job.name, "failed");
                sink.err("Download failed for {s}", .{job.name});
                failed_count += 1;
                continue;
            }
            output.emitNdjsonEvent(.download_complete, job.name, "ok");
            sink.success("{s} {s} downloaded to {s}/store/{s}", .{
                job.name,
                job.version_str,
                prefix,
                job.store_sha256,
            });
        }
        // Symmetric with the link-phase trailer: surface a non-zero exit
        // when any bottle failed to download or any dispatch-time miss
        // was already counted upstream.
        if (failed_count > 0) return InstallError.PartialFailure;
        return;
    }

    // Check for Ctrl-C between the pool and the serial link phase
    if (signals.isInterrupted()) {
        sink.warn("Interrupted. Cleaning up...", .{});
        // Pool already joined; pull its `!job.succeeded` results into
        // failed_count before bailing so the exit code reflects any
        // bottle that failed to download alongside earlier dispatch misses.
        for (all_jobs.items) |job| {
            if (!job.succeeded) failed_count += 1;
        }
        if (failed_count > 0) return InstallError.PartialFailure;
        return;
    }

    // ── Serial link + record phase ──────────────────────────────────
    // Runs in dep order so `findFailedDep` propagates failures down the
    // graph; linker + SQLite writes cannot be parallelised.
    var failed_kegs = std.StringHashMap(void).init(allocator);
    defer failed_kegs.deinit();

    for (all_jobs.items, 0..) |*job, i| {
        if (signals.isInterrupted()) {
            sink.warn("Interrupted. Stopping install.", .{});
            break;
        }

        // OOM on failed-keg bookkeeping must not be swallowed: the subsequent
        // findFailedDep check relies on this map, and a silent drop would
        // let dependents install on top of a broken graph.
        if (!job.succeeded) {
            sink.err("Download failed for {s}, skipping", .{job.name});
            try failed_kegs.put(job.name, {});
            failed_count += 1;
            continue;
        }

        if (!mats[i].ok) {
            const err = mats[i].err orelse cellar_mod.CellarError.CloneFailed;
            var msg_buf: [256]u8 = undefined;
            const msg = formatMaterializeFailure(&msg_buf, job.name, err);
            sink.err("{s}", .{msg});
            output.emitNdjsonEvent(.materialized, job.name, "failed");
            try failed_kegs.put(job.name, {});
            failed_count += 1;
            continue;
        }
        output.emitNdjsonEvent(.materialized, job.name, "ok");

        // Failed-dep → skip: installing on a broken graph yields a dyld-unresolvable
        // keg. Remove the already-materialised keg so orphans don't linger.
        if (findFailedDep(&formula_cache, &failed_kegs, job.name, job.formula_json)) |failed_dep| {
            sink.warn(
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
        if (flags.force) {
            unlinkSameVersionKegLinks(&linker, &db, job.name, mats[i].kegPath());
            unlinkStaleKegLinks(&db, &linker, job.name, mats[i].kegPath());
        }

        linkAndRecord(ctx.io, allocator, job, mats[i].kegPath(), &db, &linker, prefix, &formula_cache, flags, sink) catch {
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
        if (flags.force) {
            dropStaleKegRows(ctx, allocator, &db, job.name, mats[i].kegPath());
            pruneOtherCellarVersionsForReinstall(ctx, allocator, prefix, job.name, job.version_str);
        }

        if (job.wants_post_install) {
            drive(ctx, allocator, job.name, job.version_str, job.formula_json, prefix, flags.system_ruby, &formula_cache, sink);
        }

        // ca-certificates' macOS post_install can't run natively, so the
        // shipped Mozilla bundle is linked into etc/<name>/cert.pem here.
        // No-op for every keg that ships no CA bundle.
        post_install_mod.provisionShippedCaBundle(ctx.io, prefix, job.name);
    }

    if (failed_count > 0) {
        const pkg_word: []const u8 = if (failed_count == 1) "package" else "packages";
        sink.err(
            "{d} {s} failed to install. See errors above.",
            .{ failed_count, pkg_word },
        );
        return InstallError.PartialFailure;
    }
}

/// Link + record a materialised keg. Must run serially: linker conflict
/// checks read live symlink state and SQLite is single-writer.
///
/// The keg's `bin_isolated` is `flags.isolatesDep(job.is_dep)` so direct
/// kegs always land in PATH even under `--isolate-deps` — the contract is
/// "isolate transitive deps, never the named package."
fn linkAndRecord(
    io: std.Io,
    allocator: std.mem.Allocator,
    job: *DownloadJob,
    keg_path: []const u8,
    db: *sqlite.Database,
    linker: *linker_mod.Linker,
    prefix: []const u8,
    cache: *deps_mod.FormulaCache,
    flags: args_mod.InstallFlags,
    sink: OutputSink,
) !void {
    const reason: []const u8 = if (job.is_dep) "dependency" else "direct";
    const bin_isolated = flags.isolatesDep(job.is_dep);

    // Cache hit on the warm path; miss only happens for jobs whose JSON
    // never reached collectFormulaJobs (none today).
    const formula = cache.get(job.name) orelse blk: {
        break :blk cache.getOrParse(job.name, job.formula_json) catch |err| {
            sink.err("Failed to parse formula for {s}: {s}", .{ job.name, @errorName(err) });
            cellar_mod.remove(io, prefix, job.name, job.version_str) catch {};
            return InstallError.CellarFailed;
        };
    };

    // Check for symlink conflicts before linking. The probe must mirror
    // the link policy — otherwise an isolated dep would trigger a
    // spurious bin/sbin conflict against a keg whose bins were never
    // linked in the first place.
    if (!job.keg_only) {
        const conflicts = linker.checkConflicts(keg_path, bin_isolated) catch &.{};
        if (conflicts.len > 0) {
            sink.err("{s}: {d} symlink conflict(s) detected:", .{ job.name, conflicts.len });
            for (conflicts) |conflict| {
                sink.err("  {s} already linked by {s}", .{ conflict.link_path, conflict.existing_keg });
            }
            sink.err("Use --force to overwrite, or uninstall the conflicting package first.", .{});
            cellar_mod.remove(io, prefix, job.name, job.version_str) catch {};
            return InstallError.LinkFailed;
        }
    }

    // Link + record
    if (!job.keg_only) {
        const keg_id = recordKeg(db, formula, job.store_sha256, keg_path, reason, bin_isolated, .{}) catch |err| {
            sink.err("Failed to record {s} in database: {s}", .{ job.name, @errorName(err) });
            cellar_mod.remove(io, prefix, job.name, job.version_str) catch {};
            return InstallError.RecordFailed;
        };

        linker.link(keg_path, job.name, keg_id, bin_isolated) catch |err| {
            sink.err("Failed to link {s}: {s}", .{ job.name, @errorName(err) });
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
        linker.linkOpt(job.name, job.version_str) catch |e| {
            sink.warn("opt link for {s} failed: {s} — dependents may fail to load at runtime", .{ job.name, @errorName(e) });
        };
        recordDeps(db, keg_id, formula);
    } else {
        const keg_id = recordKeg(db, formula, job.store_sha256, keg_path, reason, bin_isolated, .{}) catch |err| {
            sink.err("Failed to record {s} in database: {s}", .{ job.name, @errorName(err) });
            cellar_mod.remove(io, prefix, job.name, job.version_str) catch {};
            return InstallError.RecordFailed;
        };
        // keg-only has no public link phase to roll back.
        output.emitNdjsonEvent(.recorded, job.name, "ok");
        linker.linkOpt(job.name, job.version_str) catch |e| {
            sink.warn("opt link for {s} failed: {s} — dependents may fail to load at runtime", .{ job.name, @errorName(e) });
        };
        recordDeps(db, keg_id, formula);
    }
    maybeRegisterService(io, allocator, db, formula, prefix, sink);
    // Annotate keg-only packages inline so the single line reads as success,
    // not as a "not linking" warning paired with a separate ✓.
    const keg_only_suffix: []const u8 = if (job.keg_only) " (keg-only — dependency only)" else "";
    sink.success("{s} {s} installed{s}", .{ job.name, job.version_str, keg_only_suffix });
}

/// Register a launchd service when the formula carries a `service:` block.
/// Best-effort: failures warn but don't fail the install.
fn maybeRegisterService(
    io: std.Io,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    formula: *const formula_mod.Formula,
    prefix: []const u8,
    sink: OutputSink,
) void {
    const def = formula.service orelse return;
    if (def.run.len == 0) return;

    // The Homebrew API renders service paths as `$HOMEBREW_PREFIX/…`; launchd
    // does not expand the token and the validator rejects it, so resolve it to
    // malt's prefix here. Scratch strings live in a scoped arena — `register`
    // renders them into the plist and DB before it returns.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var label_buf: [256]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "com.malt.{s}", .{formula.name}) catch return;

    const run = aa.alloc([]const u8, def.run.len) catch return;
    for (def.run, 0..) |arg, i| run[i] = plist_mod.expandPrefix(aa, arg, prefix) catch return;

    const working_dir = if (def.working_dir) |wd|
        (plist_mod.expandPrefix(aa, wd, prefix) catch return)
    else
        null;

    var stdout_buf: [512]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    const stdout_path = if (def.log_path) |lp|
        (plist_mod.expandPrefix(aa, lp, prefix) catch return)
    else
        (std.fmt.bufPrint(&stdout_buf, "{s}/var/log/{s}.out", .{ prefix, formula.name }) catch return);
    const stderr_path = if (def.error_log_path) |elp|
        (plist_mod.expandPrefix(aa, elp, prefix) catch return)
    else
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
        .program_args = run,
        .working_dir = working_dir,
        .stdout_path = stdout_path,
        .stderr_path = stderr_path,
        .schedule = def.schedule,
        .keep_alive = def.keep_alive,
    };

    supervisor_mod.register(.{ .allocator = allocator, .io = io, .db = db }, spec, formula.name, false, cellar_path, prefix) catch |err| {
        sink.warn("could not register service for {s}: {s}", .{ formula.name, @errorName(err) });
    };
}

/// Classify a Homebrew-API fetch failure. Network-layer failures map
/// to `NetworkError` so the user-facing summary names the real cause
/// instead of the path-specific "not found" fallback. `null` means
/// the caller picks its own fallback (formula vs. cask). Exhaustive
/// so a new `ApiError` tag fails compilation here.
fn mapApiFetchError(e: api_mod.ApiError) ?InstallError {
    return switch (e) {
        error.ApiUnreachable => InstallError.NetworkError,
        error.NotFound,
        error.InvalidResponse,
        error.InvalidName,
        error.CacheError,
        error.OfflineRequired,
        error.OutOfMemory,
        => null,
    };
}

/// Classify a failed artifact-URL resolution. A walk that never completed
/// says nothing about the cask's format, so `.unknown` stays reserved for a
/// URL malt actually resolved and could not classify.
fn mapHeadResolveError(e: anyerror) InstallError {
    // OOM is handled by the caller: it is not a property of the URL.
    return switch (e) {
        // Both mean the artifact would be fetched in the clear.
        error.InsecureUrlScheme, error.TlsDowngradeRefused => InstallError.InsecureArchiveUrl,
        else => InstallError.NetworkError,
    };
}

/// HEAD-based fallback for extensionless cask URLs.
/// Follows redirects to discover the real file extension. The walk's own
/// error reaches the caller, which reports it before classifying.
fn resolveCaskArtifactViaHead(ctx: *const AppCtx, allocator: std.mem.Allocator, url: []const u8) !cask_mod.ArtifactType {
    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, allocator);
    defer http.deinit();
    http.offline = ctx.offline;

    var resolved = try http.headResolved(url);
    defer resolved.deinit();

    return cask_mod.resolveArtifactType(allocator, resolved.final_url, resolved.content_disposition);
}

/// Gate the system-wide `sudo installer -pkg … -target /` escalation a PKG
/// cask needs. Shared by every verb that can reach it — install, upgrade,
/// rollback — so the confirmation is identical everywhere. `sudo` reads the
/// password from the controlling terminal, so off a TTY the spawn stalls and
/// then fails with a captured, post-mortem error; refuse up front with an
/// actionable message instead. On a TTY, require an explicit confirmation
/// before touching the whole system. Emits via the global `output` sink (the
/// caller may print its own warn first). Returns true only when the escalation
/// may proceed; on refusal the reason is already reported.
pub fn confirmPkgSudo(token: []const u8) bool {
    if (!output.stdinIsInteractive()) {
        output.err("{s} is a PKG cask: it needs an interactive terminal for the sudo password. Re-run in a terminal.", .{token});
        return false;
    }
    if (!output.confirmTyped("y", "This runs `sudo installer -target /` and installs system-wide. Continue? [y/N] ")) {
        output.warn("Skipped {s}: PKG install not confirmed.", .{token});
        return false;
    }
    return true;
}

/// Install a cask (DMG, ZIP, or PKG). Under `flags.download_only`, the
/// flow stops after `<prefix>/cache/Cask/<file>` is sha-verified — no
/// `/Applications` writes, no DB inserts.
fn installCask(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    token: []const u8,
    db: *sqlite.Database,
    api: *api_mod.BrewApi,
    flags: args_mod.InstallFlags,
    sink: OutputSink,
) !void {
    // Callers that legitimately bypass the fast path would otherwise fetch
    // just to discover there is nothing to do. The post-parse check below
    // stays for a cask that ever renames its token.
    if (!flags.download_only and cask_mod.isInstalled(db, token)) {
        sink.info("{s} is already installed", .{token});
        return;
    }

    const cask_json = api.fetchCask(token) catch |e| {
        // Propagate the typed OfflineRequired so the outer dispatch
        // surfaces the snapshot-miss message instead of "not found".
        if (e == api_mod.ApiError.OfflineRequired) return e;
        if (mapApiFetchError(e)) |mapped| {
            sink.err("Cannot reach Homebrew API for cask '{s}'", .{token});
            return mapped;
        }
        sink.err("Cask '{s}' not found", .{token});
        return InstallError.CaskNotFound;
    };
    defer allocator.free(cask_json);

    var cask = cask_mod.parseCask(allocator, cask_json) catch {
        sink.err("Failed to parse cask JSON for '{s}'", .{token});
        return InstallError.CaskNotFound;
    };
    defer cask.deinit();

    // `--download-only` deliberately ignores `isInstalled` so a user can
    // refresh the cached artefact ahead of an `mt upgrade` even when an
    // older revision is on disk. The real install path keeps the
    // "already installed" short-circuit.
    if (!flags.download_only and cask_mod.isInstalled(db, cask.token)) {
        sink.info("{s} is already installed", .{cask.token});
        return;
    }

    var artifact_type = cask_mod.artifactTypeFromUrl(cask.url);

    // Extensionless URLs (e.g. download APIs that 302 to the real file):
    // resolve via HEAD to discover the final URL and Content-Disposition.
    if (artifact_type == .unknown) {
        artifact_type = resolveCaskArtifactViaHead(ctx, allocator, cask.url) catch |e| switch (e) {
            // Report the walk's own error — "NetworkError" would say less than
            // the message already does.
            error.OutOfMemory => return e,
            else => {
                sink.err("Could not resolve the download URL for '{s}': {s} — URL: {s}", .{ cask.token, @errorName(e), cask.url });
                return mapHeadResolveError(e);
            },
        };
    }

    if (flags.dry_run) {
        sink.info("Dry run: would install cask {s} {s} ({s})", .{
            cask.token,
            cask.version,
            @tagName(artifact_type),
        });
        return;
    }

    if (artifact_type == .unknown) {
        sink.err("Unsupported cask format for '{s}' — URL: {s}", .{ cask.token, cask.url });
        sink.err("malt supports .dmg, .zip, .pkg, .tar.gz, and .tar.xz casks. Use: brew install --cask {s}", .{cask.token});
        return InstallError.CaskNotFound;
    }

    // PKG casks escalate to `sudo installer -target /`. Warn, then gate the
    // escalation on a live TTY + confirmation before any download. `--download-only`
    // never escalates, so it skips the gate.
    if (artifact_type == .pkg) {
        sink.warn("{s} is a PKG cask and requires sudo to install via macOS Installer.", .{cask.token});
        if (!flags.download_only and !confirmPkgSudo(cask.token)) return InstallError.CaskNotFound;
    }

    const prefix = atomic.maltPrefixOrAbort();

    var installer = cask_mod.CaskInstaller.init(ctx.io, ctx.environ, allocator, db, prefix);
    installer.artifact_type_override = artifact_type;
    installer.offline = ctx.offline;

    // Progress bar for cask download, rendered as a one-line group so it
    // disables autowrap and restores on exit. A non-terminal sink (bundle)
    // skips setup entirely — the global progress mode is set-once and
    // can't be quieted mid-run.
    var sp: ?progress_mod.SingleBar = if (sink.show_progress) progress_mod.SingleBar.init(cask.token, 0) else null;
    defer if (sp) |*s| s.finish();
    if (sp) |*s| {
        installer.progress = .{
            .context = @ptrCast(s.bind()),
            .func = &progressBridge,
        };
    }

    if (flags.download_only) {
        output.emitNdjsonEvent(.download_started, cask.token, null);
        const cache_path = installer.downloadOnly(&cask) catch |e| {
            if (sp) |*s| s.bar.finish();
            output.emitNdjsonEvent(.download_complete, cask.token, "failed");
            sink.err("Failed to download cask {s}: {s}", .{ cask.token, @errorName(e) });
            return InstallError.CaskNotFound;
        };
        if (sp) |*s| s.bar.finish();
        defer allocator.free(cache_path);
        output.emitNdjsonEvent(.download_complete, cask.token, "ok");
        sink.success("{s} {s} downloaded to {s}", .{ cask.token, cask.version, cache_path });
        return;
    }

    sink.info("Installing cask {s} {s}...", .{ cask.token, cask.version });

    const app_path = installer.install(&cask) catch |e| {
        if (sp) |*s| s.bar.finish();
        // Surface the specific cause (Sha256Mismatch, DownloadFailed, …) —
        // users can't act on a bare "failed to install".
        sink.err("Failed to install cask {s}: {s}", .{ cask.token, @errorName(e) });
        return InstallError.CaskNotFound;
    };
    if (sp) |*s| s.bar.finish();

    // Core API casks have no third-party tap origin to record.
    cask_mod.recordInstall(db, &cask, app_path, null) catch {
        sink.warn("Failed to record cask {s} in database", .{cask.token});
    };
    allocator.free(app_path);

    sink.success("{s} {s} installed", .{ cask.token, cask.version });
}

// Format the user-facing materialize-failure line. Trivial cellar tags
// (where describeError == @errorName) drop the parenthetical so the
// message reads `Failed to materialize X: CloneFailed` instead of
// `Failed to materialize X: CloneFailed (CloneFailed)`.
fn formatMaterializeFailure(buf: []u8, name: []const u8, err: cellar_mod.CellarError) []const u8 {
    const tag = @errorName(err);
    const desc = cellar_mod.describeError(err);
    const result = if (std.mem.eql(u8, tag, desc))
        std.fmt.bufPrint(buf, "Failed to materialize {s}: {s}", .{ name, tag })
    else
        std.fmt.bufPrint(buf, "Failed to materialize {s}: {s} ({s})", .{ name, tag, desc });
    // Overflow only fires on pathologically long names; fall back to a
    // truncated form rather than swallowing the failure silently.
    return result catch "Failed to materialize <truncated>";
}

// ── inline unit tests ──────────────────────────────────────────────────────

const fs_test_io = std.Options.debug_io;

fn rmrf(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(fs_test_io, path) catch {};
}

var scratch_seq: std.atomic.Value(u32) = .init(0);

/// Scratch tree under a process- and call-unique base: overlapping test runs
/// share /tmp and would otherwise delete each other's fixtures.
const Scratch = struct {
    arena: std.heap.ArenaAllocator,
    base: [:0]const u8,

    fn init(comptime tag: []const u8) !Scratch {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const base = try std.fmt.allocPrintSentinel(
            arena.allocator(),
            "/tmp/malt_" ++ tag ++ "_{d}_{d}",
            .{ std.c.getpid(), scratch_seq.fetchAdd(1, .monotonic) },
            0,
        );
        rmrf(base);
        return .{ .arena = arena, .base = base };
    }

    /// Absolute path to `sub` (leading slash included) inside the scratch
    /// tree; valid until `deinit`.
    fn p(self: *Scratch, sub: []const u8) [:0]const u8 {
        return std.fmt.allocPrintSentinel(
            self.arena.allocator(),
            "{s}{s}",
            .{ self.base, sub },
            0,
        ) catch @panic("OOM");
    }

    fn deinit(self: *Scratch) void {
        rmrf(self.base);
        self.arena.deinit();
    }
};

test "installFlagsFromOpts matches what the --cask --isolate-deps argv path parsed" {
    // Byte-parity oracle for dropping the argv round-trip: the flags built
    // directly from InstallAllOpts must equal what parse() derived from the
    // synthesised `--cask --isolate-deps` argv, and set nothing else.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = switch (try args_mod.parse(arena.allocator(), &.{ "--cask", "--isolate-deps", "wget" })) {
        .ok => |p| p,
        .invalid => return error.TestUnexpectedResult,
    };
    const direct = installFlagsFromOpts(.{ .cask = true, .isolate_deps = true });
    try std.testing.expectEqual(parsed.flags.force_cask, direct.force_cask);
    try std.testing.expectEqual(parsed.flags.isolate_deps, direct.isolate_deps);
    try std.testing.expectEqual(parsed.flags.force, direct.force);
    try std.testing.expectEqual(parsed.flags.force_formula, direct.force_formula);
    try std.testing.expectEqual(parsed.flags.dry_run, direct.dry_run);
    try std.testing.expectEqual(parsed.flags.local_only, direct.local_only);
    try std.testing.expectEqual(parsed.flags.only_deps, direct.only_deps);
    try std.testing.expectEqual(parsed.flags.download_only, direct.download_only);
    try std.testing.expectEqual(parsed.flags.system_ruby.len, direct.system_ruby.len);
}

test "promoteIsolatedDepIfAny opt-links the revisioned dir, not the raw version" {
    // Isolated dep at version 1.3 revision 1 lives on disk as
    // Cellar/zlib/1.3_1. Promotion must point opt/zlib at that dir; a
    // raw-version opt link (Cellar/zlib/1.3) would dangle.
    const testing = std.testing;
    const allocator = testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("promote_rev");
    defer s.deinit();
    const prefix = s.base;

    const keg_lib = s.p("/Cellar/zlib/1.3_1/lib");
    try std.Io.Dir.cwd().createDirPath(io, keg_lib);
    const db_dir = s.p("/db");
    try std.Io.Dir.cwd().createDirPath(io, db_dir);

    const db_path = s.p("/db/malt.db");
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);
    var ins_buf: [std.fs.max_path_bytes + 256]u8 = undefined;
    const insert = try std.fmt.bufPrintSentinel(
        &ins_buf,
        "INSERT INTO kegs(name,full_name,version,revision,store_sha256,cellar_path,install_reason,bin_isolated) " ++
            "VALUES('zlib','zlib','1.3',1,'sha','{s}/Cellar/zlib/1.3_1','dependency',1);",
        .{prefix},
        0,
    );
    try db.exec(insert);

    var linker = linker_mod.Linker.init(io, allocator, &db, prefix);
    try testing.expect(promoteIsolatedDepIfAny(&db, &linker, "zlib"));

    // opt/zlib must resolve (accessAbsolute follows the symlink; a
    // dangling link would surface FileNotFound).
    const opt = s.p("/opt/zlib");
    try std.Io.Dir.accessAbsolute(io, opt, .{});

    // …and the row is promoted: direct + no longer bin-isolated.
    var row = try db.prepare("SELECT install_reason, bin_isolated FROM kegs WHERE name='zlib';");
    defer row.finalize();
    try testing.expect(try row.step());
    try testing.expectEqualStrings("direct", std.mem.sliceTo(row.columnText(0).?, 0));
    try testing.expectEqual(@as(i64, 0), row.columnInt(1));
}

test "mapApiFetchError surfaces ApiUnreachable as NetworkError" {
    // Pre-fix the bottle/cask paths collapsed any fetch failure to a
    // path-specific "not found" tag, so the dispatch summary said
    // FormulaNotFound or CaskNotFound when the cause was a flaky DNS.
    try std.testing.expectEqual(InstallError.NetworkError, mapApiFetchError(error.ApiUnreachable).?);
}

test "mapHeadResolveError reports a dead walk as a network failure, not a format one" {
    try std.testing.expectEqual(InstallError.NetworkError, mapHeadResolveError(error.RequestFailed));
    try std.testing.expectEqual(InstallError.NetworkError, mapHeadResolveError(error.OfflineRequired));
    try std.testing.expectEqual(InstallError.NetworkError, mapHeadResolveError(error.HttpRedirectLocationMissing));
}

test "mapHeadResolveError keeps a cleartext artifact URL distinct from a network failure" {
    try std.testing.expectEqual(InstallError.InsecureArchiveUrl, mapHeadResolveError(error.InsecureUrlScheme));
    try std.testing.expectEqual(InstallError.InsecureArchiveUrl, mapHeadResolveError(error.TlsDowngradeRefused));
}

test "mapApiFetchError leaves other ApiError variants for the path's own fallback" {
    try std.testing.expect(mapApiFetchError(error.NotFound) == null);
    try std.testing.expect(mapApiFetchError(error.OfflineRequired) == null);
    try std.testing.expect(mapApiFetchError(error.InvalidResponse) == null);
    try std.testing.expect(mapApiFetchError(error.InvalidName) == null);
    try std.testing.expect(mapApiFetchError(error.CacheError) == null);
}

test "formatMaterializeFailure: trivial tag drops the parenthetical" {
    var buf: [256]u8 = undefined;
    const msg = formatMaterializeFailure(&buf, "lld@21", cellar_mod.CellarError.CloneFailed);
    try std.testing.expectEqualStrings("Failed to materialize lld@21: CloneFailed", msg);
}

test "formatMaterializeFailure: action-hint tag keeps the parenthetical prose" {
    var buf: [256]u8 = undefined;
    const msg = formatMaterializeFailure(&buf, "pkg", cellar_mod.CellarError.InstallNameToolMissing);
    try std.testing.expect(std.mem.startsWith(u8, msg, "Failed to materialize pkg: InstallNameToolMissing ("));
    try std.testing.expect(std.mem.endsWith(u8, msg, ")"));
    try std.testing.expect(std.mem.indexOf(u8, msg, "install_name_tool not found on PATH") != null);
}

test "kegPresent returns true only when <prefix>/Cellar/<name> exists" {
    const testing = std.testing;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: AppCtx = .{ .io = threaded.io(), .environ = .empty };

    var s = try Scratch.init("kegpresent");
    defer s.deinit();
    const prefix = s.base;
    try std.Io.Dir.cwd().createDirPath(ctx.io, prefix);

    try testing.expect(!kegPresent(&ctx, prefix, "ghost"));

    const keg = s.p("/Cellar/ghost");
    try std.Io.Dir.cwd().createDirPath(ctx.io, keg);

    try testing.expect(kegPresent(&ctx, prefix, "ghost"));
    try testing.expect(!kegPresent(&ctx, prefix, "other"));
}

// `--download-only` must never mutate the installed cellar. The bottle
// path ran the `--force` prune ahead of its download-only early return,
// so `mt install --download-only --force <same-version>` deleteTree'd an
// installed keg and never re-materialized it. The prune is now gated on
// `InstallFlags.pruneForReinstall`, which vetoes the prune under
// download-only. (The prune loops all jobs, so a multi-dep target would
// wipe every dependency's cellar; one assertion on the primary keg
// suffices. The pure decision matrix is unit-tested in install/args.zig.)
test "install: --download-only suppresses the --force reinstall prune" {
    const testing = std.testing;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: AppCtx = .{ .io = threaded.io(), .environ = .empty };

    var s = try Scratch.init("dlonly_force");
    defer s.deinit();
    const prefix = s.base;
    try std.Io.Dir.cwd().createDirPath(ctx.io, prefix);

    const keg = s.p("/Cellar/wget/1.21");
    try std.Io.Dir.cwd().createDirPath(ctx.io, keg);

    // download-only gate is false → prune skipped → keg survives.
    if ((args_mod.InstallFlags{ .force = true, .download_only = true }).pruneForReinstall())
        pruneCellarForReinstall(&ctx, prefix, "wget", "1.21");
    try std.Io.Dir.accessAbsolute(ctx.io, keg, .{});

    // plain --force gate is true → prune runs → keg gone.
    if ((args_mod.InstallFlags{ .force = true }).pruneForReinstall())
        pruneCellarForReinstall(&ctx, prefix, "wget", "1.21");
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(ctx.io, keg, .{}));
}

// `--force` that resolves to a new revision (e.g. 10.47 → 10.47_1)
// must not orphan the prior keg dir: doctor walks the whole Cellar
// tree and would flag the abandoned unpatched binaries forever.
test "pruneOtherCellarVersionsForReinstall removes sibling versions but keeps the named one" {
    const testing = std.testing;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: AppCtx = .{ .io = threaded.io(), .environ = .empty };

    var s = try Scratch.init("prune_siblings");
    defer s.deinit();
    const prefix = s.base;
    try std.Io.Dir.cwd().createDirPath(ctx.io, prefix);

    const old_keg = s.p("/Cellar/pcre2/10.47/bin");
    try std.Io.Dir.cwd().createDirPath(ctx.io, old_keg);

    const new_keg = s.p("/Cellar/pcre2/10.47_1/bin");
    try std.Io.Dir.cwd().createDirPath(ctx.io, new_keg);

    pruneOtherCellarVersionsForReinstall(&ctx, testing.allocator, prefix, "pcre2", "10.47_1");

    const old_root = s.p("/Cellar/pcre2/10.47");
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(ctx.io, old_root, .{}));

    const new_root = s.p("/Cellar/pcre2/10.47_1");
    try std.Io.Dir.accessAbsolute(ctx.io, new_root, .{});
}

test "pruneOtherCellarVersionsForReinstall is a no-op when only the kept version exists" {
    const testing = std.testing;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: AppCtx = .{ .io = threaded.io(), .environ = .empty };

    var s = try Scratch.init("prune_siblings_solo");
    defer s.deinit();
    const prefix = s.base;
    try std.Io.Dir.cwd().createDirPath(ctx.io, prefix);

    const keep_keg = s.p("/Cellar/libgit2/1.9.3/lib");
    try std.Io.Dir.cwd().createDirPath(ctx.io, keep_keg);

    pruneOtherCellarVersionsForReinstall(&ctx, testing.allocator, prefix, "libgit2", "1.9.3");

    const keep_root = s.p("/Cellar/libgit2/1.9.3");
    try std.Io.Dir.accessAbsolute(ctx.io, keep_root, .{});
}

test "pruneOtherCellarVersionsForReinstall is a no-op when the package dir does not exist" {
    const testing = std.testing;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: AppCtx = .{ .io = threaded.io(), .environ = .empty };

    var s = try Scratch.init("prune_siblings_absent");
    defer s.deinit();
    const prefix = s.base;
    try std.Io.Dir.cwd().createDirPath(ctx.io, prefix);

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

    var s = try Scratch.init("prune_siblings_many");
    defer s.deinit();
    const prefix = s.base;
    try std.Io.Dir.cwd().createDirPath(ctx.io, prefix);

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

    var s = try Scratch.init("prune_siblings_files");
    defer s.deinit();
    const prefix = s.base;
    try std.Io.Dir.cwd().createDirPath(ctx.io, prefix);

    const pkg_path = s.p("/Cellar/pcre2");
    try std.Io.Dir.cwd().createDirPath(ctx.io, pkg_path);

    const stray = s.p("/Cellar/pcre2/.DS_Store");
    {
        const f = try std.Io.Dir.cwd().createFile(ctx.io, stray, .{});
        defer f.close(ctx.io);
        try f.writeStreamingAll(ctx.io, "stray");
    }

    const keep_keg = s.p("/Cellar/pcre2/10.47_1/bin");
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

    var s = try Scratch.init("prune_siblings_nokeep");
    defer s.deinit();
    const prefix = s.base;
    try std.Io.Dir.cwd().createDirPath(ctx.io, prefix);

    const stale = s.p("/Cellar/pcre2/10.47/bin");
    try std.Io.Dir.cwd().createDirPath(ctx.io, stale);

    pruneOtherCellarVersionsForReinstall(&ctx, testing.allocator, prefix, "pcre2", "10.47_1");

    const stale_root = s.p("/Cellar/pcre2/10.47");
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(ctx.io, stale_root, .{}));
}
