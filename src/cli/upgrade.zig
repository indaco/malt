//! malt — upgrade command
//! Upgrade installed packages and casks.

const std = @import("std");

const AppCtx = @import("../app_ctx.zig").AppCtx;
const cask_mod = @import("../core/cask.zig");
const cellar_mod = @import("../core/cellar.zig");
const deps_mod = @import("../core/deps.zig");
const formula_mod = @import("../core/formula.zig");
const linker_mod = @import("../core/linker.zig");
const store_mod = @import("../core/store.zig");
const tap_mod = @import("../core/tap.zig");
const forge = @import("../core/forge.zig");
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
const install_args_mod = @import("install/args.zig");
const install_download_mod = @import("install/download.zig");
const install_local_mod = @import("install/local.zig");
const install_rb_parse_mod = @import("install/rb_parse.zig");
const install_record_mod = @import("install/record.zig");
const InstallError = install_record_mod.InstallError;
const install_sink_mod = @import("install/sink.zig");
const install_mod = @import("install.zig");
const pin_mod = @import("pin.zig");

const UpgradeFlag = enum { quiet, cask, formula, dry_run, force, pinned, isolate_deps };

const upgrade_flag_map = std.StaticStringMap(UpgradeFlag).initComptime(.{
    .{ "-q", .quiet },
    .{ "--quiet", .quiet },
    .{ "--cask", .cask },
    .{ "--formula", .formula },
    .{ "--dry-run", .dry_run },
    .{ "--force", .force },
    .{ "-f", .force },
    .{ "--pinned", .pinned },
    .{ "--isolate-deps", .isolate_deps },
    // Long-form alias matching the `--only-dependencies` / `--only-deps`
    // shape so the flag surface stays predictable.
    .{ "--isolate-dependencies", .isolate_deps },
});

/// True when this name should be skipped due to a user pin. Pure gate so
/// the `--force` semantics are testable without dragging in the API.
/// `audit_mode` lets `--pinned --dry-run` walk pinned kegs end-to-end so
/// the user can see the drift; without that escape, every row would
/// short-circuit before the API check.
pub fn pinSkip(db: *sqlite.Database, name: []const u8, force: bool, audit_mode: bool) bool {
    if (force or audit_mode) return false;
    return pin_mod.isPinned(db, name);
}

pub fn execute(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(ctx, args, "upgrade")) return;

    var cask_only = false;
    var formula_only = false;
    var dry_run = output.isDryRun();
    var force = false;
    var pinned_only = false;
    // Applies only to deps newly introduced by this upgrade — existing
    // kegs replay their stored `bin_isolated` regardless of the flag.
    var isolate_deps = false;
    var pkg_name: ?[]const u8 = null;

    // StaticStringMap + exhaustive switch: every flag routes to a handler.
    for (args) |arg| {
        if (upgrade_flag_map.get(arg)) |flag| switch (flag) {
            .quiet => output.setQuiet(true),
            .cask => cask_only = true,
            .formula => formula_only = true,
            .dry_run => dry_run = true,
            .force => force = true,
            .pinned => pinned_only = true,
            .isolate_deps => isolate_deps = true,
        } else if (arg.len > 0 and arg[0] != '-') {
            if (pkg_name == null) pkg_name = arg;
        }
    }

    if (pinned_only) {
        // Without --dry-run or --force the audit would just print
        // "pinned, skipped" for every row - refuse rather than waste cycles.
        if (!dry_run and !force) {
            output.err("--pinned requires --dry-run (audit) or --force (override)", .{});
            return error.Aborted;
        }
    }

    // Open DB + API
    const prefix = atomic.maltPrefixOrAbort();

    var lock_path_buf: [512]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_path_buf, "{s}/db/malt.lock", .{prefix}) catch return;
    var lk = lock_mod.LockFile.acquire(ctx.io, lock_path, 5000) catch {
        // Fresh prefix: no `db/` yet = nothing installed, nothing to
        // upgrade. Exit 0 silently rather than treating the missing
        // lock directory as contention with another process.
        if (dry_run) return;
        output.err("Could not acquire lock. Another malt process may be running.", .{});
        return error.Aborted;
    };
    defer lk.release(ctx.io);
    // LIFO: install_complete fires before lk.release. Inline gate keeps
    // the deferred call out of the default paths.
    defer if (output.isNdjson()) output.emitNdjsonEvent(.install_complete, "", null);
    output.emitNdjsonEvent(.lock_acquired, "", null);

    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return;
    var db = sqlite.Database.open(db_path) catch {
        // Same degradation as `list`/`outdated` — missing DB on a fresh
        // prefix is empty state, not an error.
        return;
    };
    defer db.close();
    schema.initSchema(&db) catch return;

    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, allocator);
    defer http.deinit();
    http.offline = ctx.offline;

    var cache_dir_buf: [512]u8 = undefined;
    const cache_dir = std.fmt.bufPrint(&cache_dir_buf, "{s}/cache", .{prefix}) catch return;
    var api = api_mod.BrewApi.init(ctx.io, allocator, &http, cache_dir);
    api.base_url = ctx.mirrors.api_base;
    api.offline = ctx.offline;

    // Per-package errors must not be swallowed: a batch that fails every
    // item used to exit 0, hiding the failure from CI. We aggregate here
    // and surface error.Aborted so main.zig maps it to a non-zero exit.
    var any_failed = false;

    if (pkg_name) |name| {
        // Upgrade a specific package — try formula first, then cask
        if (!cask_only) {
            if (isFormulaInstalled(&db, name)) {
                upgradeFormula(ctx, allocator, name, &db, &api, &http, prefix, dry_run, force, pinned_only, isolate_deps) catch {
                    any_failed = true;
                };
                if (any_failed) return error.Aborted;
                return;
            }
        }
        // Not a formula (or --cask): try cask
        upgradeCask(ctx, allocator, name, &db, &api, prefix, dry_run, force, pinned_only) catch {
            any_failed = true;
        };
    } else {
        // Upgrade all
        if (!cask_only) {
            upgradeAllFormulas(ctx, allocator, &db, &api, &http, prefix, dry_run, force, pinned_only, isolate_deps) catch {
                any_failed = true;
            };
        }
        if (!formula_only) {
            upgradeAllCasks(ctx, allocator, &db, &api, prefix, dry_run, force, pinned_only) catch {
                any_failed = true;
            };
        }
    }

    if (any_failed) return error.Aborted;
}

// ---------------------------------------------------------------------------
// Formula upgrade
// ---------------------------------------------------------------------------

/// Upgrade a single installed formula with rollback safety.
///
/// Flow:
/// 1. Fetch latest version from API, compare with installed.
/// 2. Download + materialize new version to Cellar.
/// 3. Unlink old symlinks, create new ones atomically.
/// 4. Update DB (new keg record).
/// 5. On failure at ANY step after old symlinks are removed: restore old links.
/// 6. Only remove old Cellar entry after the new version is fully switched.
fn upgradeFormula(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    name: []const u8,
    db: *sqlite.Database,
    api: *api_mod.BrewApi,
    http: *client_mod.HttpClient,
    prefix: [:0]const u8,
    dry_run: bool,
    force: bool,
    audit_mode: bool,
    isolate_deps: bool,
) !void {
    // Honor pins before any network or filesystem work — the whole
    // point is that a pinned keg never gets touched. Audit mode
    // (`--pinned --dry-run`) walks pinned kegs end-to-end so the user
    // sees the drift, but the dry-run gate still blocks any mutation.
    if (pinSkip(db, name, force, audit_mode)) {
        output.dim("{s} is pinned, skipped", .{name});
        // Distinguishes "skipped by policy" from "command never ran".
        output.emitNdjsonEvent(.pinned, name, null);
        return;
    }

    // Step 1: Look up installed version from DB. `bin_isolated` is
    // read so the upgraded row replays the user's prior isolation
    // intent without re-passing a flag.
    var find_stmt = db.prepare(
        "SELECT id, version, revision, store_sha256, cellar_path, tap, bin_isolated FROM kegs WHERE name = ?1 LIMIT 1;",
    ) catch return;
    defer find_stmt.finalize();
    find_stmt.bindText(1, name) catch return;

    const found = find_stmt.step() catch false;
    if (!found) {
        output.err("{s} is not installed as a formula", .{name});
        return error.Aborted;
    }

    const old_keg_id = find_stmt.columnInt(0);
    const old_ver_ptr = find_stmt.columnText(1);
    const old_revision = find_stmt.columnInt(2);
    const old_sha_ptr = find_stmt.columnText(3);
    const old_cellar_ptr = find_stmt.columnText(4);
    const tap_ptr = find_stmt.columnText(5);
    const replay_bin_isolated = find_stmt.columnInt(6) != 0;
    const old_version = if (old_ver_ptr) |v| std.mem.sliceTo(v, 0) else "unknown";
    const old_sha256 = if (old_sha_ptr) |s| std.mem.sliceTo(s, 0) else "";
    const old_cellar_path = if (old_cellar_ptr) |c| std.mem.sliceTo(c, 0) else "";
    const tap_label = if (tap_ptr) |t| std.mem.sliceTo(t, 0) else "";

    // Tap-installed formulas come from `<user>/<repo>` repos, not the
    // homebrew/core API. Route them through the tap-aware upgrade path
    // before touching `formulae.brew.sh`. Dupe the tap label so the
    // slice survives across statements that reuse the SQLite buffer.
    if (!install_args_mod.isCoreTap(tap_label)) {
        const tap_owned = allocator.dupe(u8, tap_label) catch return error.Aborted;
        defer allocator.free(tap_owned);
        return upgradeTapFormula(ctx, allocator, name, tap_owned, db, prefix, dry_run, force, audit_mode);
    }

    // Reconstruct the revision-aware path label for the old keg so
    // cellar_mod.remove / linker calls target the actual on-disk dir.
    var old_pkgver_buf: [128]u8 = undefined;
    const old_pkg_version = formula_mod.pkgVersion(&old_pkgver_buf, old_version, old_revision) catch old_version;

    // Step 2: Fetch latest formula from API
    const formula_json = api.fetchFormula(name) catch {
        output.err("Could not fetch formula info for {s}", .{name});
        return error.Aborted;
    };
    defer allocator.free(formula_json);

    var formula = formula_mod.parseFormula(allocator, formula_json) catch {
        output.err("Failed to parse formula JSON for {s}", .{name});
        return error.Aborted;
    };
    defer formula.deinit();

    // Compare versions
    if (std.mem.eql(u8, old_pkg_version, formula.pkg_version)) {
        output.skip("{s} is already at latest version {s}", .{ name, formula.pkg_version });
        output.emitNdjsonEvent(.up_to_date, name, null);
        return;
    }

    if (dry_run) {
        output.info("Dry run: would upgrade {s} {s} -> {s}", .{ name, old_version, formula.pkg_version });
        // Same vocabulary across install/upgrade/migrate — one parser fits all.
        output.emitNdjsonEvent(.would_install, name, null);
        return;
    }

    output.info("Upgrading {s} {s} -> {s}...", .{ name, old_version, formula.pkg_version });
    output.emitNdjsonEvent(.resolved, name, null);

    // Bottles bake LC_LOAD_DYLIB paths against their own dep set, so a
    // dep introduced after the previously-installed version must be
    // materialised before the new bottle relocates / links — otherwise
    // dyld errors at first use (e.g. curl 8.20 added libngtcp2 that
    // 8.19 did not have).
    //
    // Self-heal `opt/<dep>` for every transitive dep before the BFS
    // probe: the install fast-path treats a present Cellar dir as
    // "already installed" and would otherwise short-circuit a re-link
    // when only the symlink was wiped. After this loop, the strict
    // probe in `collectMissingDepNames` only flags genuinely
    // cellar-missing deps for re-fetching.
    for (formula.dependencies) |dep_name| {
        deps_mod.ensureOptLink(ctx.io, db, prefix, dep_name);
    }
    {
        const missing = collectMissingDepNames(ctx.io, allocator, db, formula.dependencies) catch &.{};
        defer if (missing.len > 0) allocator.free(missing);
        if (missing.len > 0) {
            output.info("Installing new dep(s) for {s} ({d})...", .{ name, missing.len });
            // Re-enter installAll while we already own malt.lock above:
            // BSD flock is per-fd, so without skip_lock the inner acquire
            // would EAGAIN-loop on our own hold and 30 s-timeout as
            // misleading "Another mt process is running" contention.
            install_mod.installAll(ctx, allocator, missing, .{
                .skip_lock = true,
                .isolate_deps = isolate_deps,
            }) catch {
                output.err("Could not install new dep(s) for {s}", .{name});
                return error.Aborted;
            };
        }
    }

    // Steps 3–5: download + cellar materialize via the shared install
    // pipeline. One primitive means upgrade inherits the install path's
    // retry-with-backoff and `:any` skip-relocation hot path for free.
    var ghcr = ghcr_mod.GhcrClient.init(ctx.io, allocator, http);
    ghcr.base_url = ctx.mirrors.bottle_base;
    defer ghcr.deinit();

    var store = store_mod.Store.init(ctx.io, allocator, db, prefix);

    // One-line group so the upgrade bar disables autowrap and restores on
    // exit, instead of the old setup-free bar that stacked when over-width.
    var sp = progress_mod.SingleBar.init(name, 0);
    defer sp.finish();
    const fetch = install_download_mod.installKegFromBottle(
        ctx,
        allocator,
        .{ .ghcr = &ghcr, .http = http, .store = &store, .bar = sp.bind() },
        &formula,
        prefix,
    ) catch |e| {
        if (e == InstallError.NoBottle) {
            output.err("No bottle available for {s} on this platform", .{name});
        } else if (e == InstallError.CellarFailed) {
            output.err("Failed to materialize {s}", .{name});
            output.emitNdjsonEvent(.materialized, name, "failed");
        }
        return error.Aborted;
    };
    const new_keg = fetch.keg;

    // Emit even on warm-cache so the cold/warm event sequence matches.
    if (output.isNdjson()) {
        output.emitNdjsonEvent(.downloaded, name, "ok");
        output.emitNdjsonEvent(.extracted, name, "ok");
        output.emitNdjsonEvent(.stored, name, "ok");
    }
    output.emitNdjsonEvent(.materialized, name, "ok");

    // Steps 6–8 (DB part): atomic. unlink-old → recordKeg → link-new →
    // deleteKeg-old run inside a single SQLite transaction so a partial
    // failure cannot leave kegs/links half-mutated. On any error inside
    // the txn we ROLLBACK first, then run filesystem rollback (re-link
    // old version, remove the new cellar dir) so the user can retry the
    // upgrade against a consistent on-disk + DB state.
    var linker = linker_mod.Linker.init(ctx.io, allocator, db, prefix);
    db.beginTransaction() catch |txn_err| {
        output.err(
            "Could not begin DB transaction for {s}: {s} ({s})",
            .{ name, @errorName(txn_err), db.errMsg() },
        );
        cellar_mod.remove(ctx.io, prefix, formula.name, formula.pkg_version) catch {};
        return error.Aborted;
    };

    const new_keg_id = upgradeDbAtomic(db, &linker, old_keg_id, &formula, fetch.sha256, new_keg.path, replay_bin_isolated) catch |db_err| {
        output.err(
            "Failed to record new version of {s} in database: {s} ({s})",
            .{ name, @errorName(db_err), db.errMsg() },
        );
        db.rollback();
        // FS rollback: the txn restored old keg/links rows; we still
        // need to recreate the old symlinks (FS isn't transactional)
        // and drop the freshly-materialized new cellar dir.
        restoreOldLinks(db, &linker, old_cellar_path, name, old_keg_id, replay_bin_isolated);
        cellar_mod.remove(ctx.io, prefix, formula.name, formula.pkg_version) catch {};
        return error.Aborted;
    };

    db.commit() catch |commit_err| {
        output.err(
            "Failed to commit upgrade for {s}: {s} ({s})",
            .{ name, @errorName(commit_err), db.errMsg() },
        );
        db.rollback();
        // best-effort FS cleanup before falling back to the old version.
        linker.unlink(new_keg_id) catch {};
        restoreOldLinks(db, &linker, old_cellar_path, name, old_keg_id, replay_bin_isolated);
        cellar_mod.remove(ctx.io, prefix, formula.name, formula.pkg_version) catch {};
        return error.Aborted;
    };

    // emit only after the txn commits — earlier emits would lie if a
    // later step inside the txn rolled the recorded/linked state back.
    output.emitNdjsonEvent(.linked, name, "ok");
    output.emitNdjsonEvent(.recorded, name, "ok");

    // opt symlink isn't convenience: dependents' LC_LOAD_DYLIB entries point
    // into <prefix>/opt/<name>/lib/... — a silent miss surfaces at runtime.
    linker.linkOpt(formula.name, formula.pkg_version) catch |e| {
        output.warn("opt link for {s} failed: {s} — dependents may fail to load at runtime", .{ formula.name, @errorName(e) });
    };

    // Step 8 (FS-only tail): drop the now-replaced cellar entry.
    cellar_mod.remove(ctx.io, prefix, name, old_pkg_version) catch {
        output.warn("Could not remove old cellar entry for {s} {s}", .{ name, old_pkg_version });
    };
    // Also remove parent if empty
    {
        var parent_buf: [512]u8 = undefined;
        const parent_path = std.fmt.bufPrint(&parent_buf, "{s}/Cellar/{s}", .{ prefix, name }) catch "";
        if (parent_path.len > 0) {
            // rmdir fails if other versions still live here — that is the intended guard.
            std.Io.Dir.cwd().deleteDir(ctx.io, parent_path) catch {};
        }
    }

    if (old_sha256.len > 0) {
        // refcount is advisory; upgrade is already complete on disk.
        store.decrementRef(old_sha256) catch {};
    }

    output.success("{s} upgraded to {s}", .{ name, formula.pkg_version });
}

/// Upgrade a tap-installed formula. The reported `tap_label` is
/// `<user>/<repo>` (the value `kegs.tap` carries for everything that did
/// not come from `homebrew/core`). We re-resolve the tap's HEAD commit,
/// short-circuit when the pin already points there, and otherwise bump
/// the pin and re-enter `installTapFormula` with `force = true` so the
/// shared materialise/link path picks up the new revision. Tap casks
/// reach the same delegate via `upgradeTapCaskFallback`.
fn upgradeTapFormula(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    name: []const u8,
    tap_label: []const u8,
    db: *sqlite.Database,
    prefix: [:0]const u8,
    dry_run: bool,
    force: bool,
    audit_mode: bool,
) !void {
    if (pinSkip(db, name, force, audit_mode)) {
        output.dim("{s} is pinned, skipped", .{name});
        output.emitNdjsonEvent(.pinned, name, null);
        return;
    }

    const slash = std.mem.indexOfScalar(u8, tap_label, '/') orelse {
        output.err("Cannot parse tap '{s}' for {s}", .{ tap_label, name });
        return error.Aborted;
    };
    if (slash == 0 or slash == tap_label.len - 1) {
        output.err("Cannot parse tap '{s}' for {s}", .{ tap_label, name });
        return error.Aborted;
    }

    const urls = try tap_mod.resolveTapBaseUrls(allocator, db, tap_label);
    defer urls.deinit(allocator);

    // `mt upgrade` asks GitHub "has HEAD moved?". Sending the cached
    // etag lets a stable tap answer 304 for free — same outcome as
    // before (we still see whether the sha moved) without burning a
    // rate-limit token.
    const cached_sha_opt = tap_mod.getCommitSha(allocator, db, tap_label) catch null;
    defer if (cached_sha_opt) |s| allocator.free(s);
    const cached_etag_opt = tap_mod.getHeadEtag(allocator, db, tap_label) catch null;
    defer if (cached_etag_opt) |e| allocator.free(e);

    var head_res = tap_mod.resolveHeadCommit(ctx.io, ctx.environ, allocator, urls.api_head_url, cached_etag_opt) catch |e| {
        output.err("Could not resolve {s} HEAD: {s}", .{ tap_label, tap_mod.describeResolveError(e) });
        return error.Aborted;
    };
    defer head_res.deinit();

    // 304 → cached_sha is still authoritative. 200 → use the fresh sha
    // and persist (sha, etag) below so the next round can short-circuit.
    const fresh_sha = if (head_res.not_modified)
        (cached_sha_opt orelse {
            output.err("Could not resolve {s} HEAD: 304 without cached sha", .{tap_label});
            return error.Aborted;
        })
    else
        (head_res.sha orelse {
            output.err("Could not resolve {s} HEAD: empty response", .{tap_label});
            return error.Aborted;
        });
    const same_commit = if (cached_sha_opt) |c| std.mem.eql(u8, c, fresh_sha) else false;

    if (!force and same_commit) {
        output.skip("{s} is already at latest tap commit", .{name});
        output.emitNdjsonEvent(.up_to_date, name, null);
        return;
    }

    if (dry_run) {
        const short_len = @min(@as(usize, 8), fresh_sha.len);
        output.info("Dry run: would refresh tap {s} to {s} for {s}", .{ tap_label, fresh_sha[0..short_len], name });
        output.emitNdjsonEvent(.would_install, name, null);
        return;
    }

    // Persist the new pin BEFORE installTapFormula reads it. Use add()
    // so a missing tap row (legacy install) is created instead of erroring.
    // (owner, repo) routes through `effectiveOwnerRepo` so the synthesis
    // used at HEAD resolve time matches the row that records the pin.
    {
        const pair = tap_mod.effectiveOwnerRepo(allocator, db, tap_label, "github.com") catch {
            output.err("Could not pin {s} to {s}", .{ tap_label, fresh_sha });
            return error.Aborted;
        };
        defer pair.deinit(allocator);
        tap_mod.add(db, tap_label, pair.owner, pair.repo, fresh_sha) catch {
            output.err("Could not pin {s} to {s}", .{ tap_label, fresh_sha });
            return error.Aborted;
        };
    }
    // Refresh the etag on 200 so the next upgrade short-circuits. On 304
    // the etag we already hold is by definition still current.
    if (!head_res.not_modified) {
        if (head_res.etag) |et| tap_mod.updateHead(db, tap_label, fresh_sha, et) catch {};
    }

    const full_name = std.fmt.allocPrint(allocator, "{s}/{s}", .{ tap_label, name }) catch return error.Aborted;
    defer allocator.free(full_name);

    var linker = linker_mod.Linker.init(ctx.io, allocator, db, prefix);
    install_local_mod.installTapFormula(ctx, allocator, full_name, db, &linker, prefix, dry_run, true, false, install_sink_mod.terminal) catch {
        output.err("Failed to upgrade tap formula {s}", .{full_name});
        return error.Aborted;
    };
}

/// Distinguishes "this tap doesn't own the cask" from "the upgrade
/// attempt failed". The probe loop in `upgradeTapCaskFallback` continues
/// on either — the pre-routed call from `upgradeCask` continues only on
/// the latter (a 404 against a recorded `casks.tap` is user-facing).
const TapRouteError = error{ NotInTap, Aborted };

/// Upgrade a cask whose owning tap is known. Fetches the tap's
/// `Casks/<token>.rb` once to read the new version, short-circuits when
/// the cask is already at that version, and otherwise drives the same
/// uninstall + tap re-install sequence the install path uses. Centralises
/// the version check so we never re-download the artifact for a cask
/// whose tap hasn't bumped its version.
fn upgradeRoutedTapCask(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    token: []const u8,
    tap_label: []const u8,
    installed_version: []const u8,
    db: *sqlite.Database,
    prefix: [:0]const u8,
    dry_run: bool,
    force: bool,
) TapRouteError!void {
    const slash = std.mem.indexOfScalar(u8, tap_label, '/') orelse return error.Aborted;
    if (slash == 0 or slash == tap_label.len - 1) return error.Aborted;

    const urls = tap_mod.resolveTapBaseUrls(allocator, db, tap_label) catch return error.Aborted;
    defer urls.deinit(allocator);

    // Send the cached etag so a stable tap 304s for free; on 200 we
    // still pick up the moved sha. Same error shape as `upgradeTapFormula`
    // so probe-loop callers can grep for the resolve failure consistently.
    const cached_sha_opt = tap_mod.getCommitSha(allocator, db, tap_label) catch null;
    defer if (cached_sha_opt) |s| allocator.free(s);
    const cached_etag_opt = tap_mod.getHeadEtag(allocator, db, tap_label) catch null;
    defer if (cached_etag_opt) |e| allocator.free(e);

    var head_res = tap_mod.resolveHeadCommit(ctx.io, ctx.environ, allocator, urls.api_head_url, cached_etag_opt) catch |e| {
        output.err("Could not resolve {s} HEAD: {s}", .{ tap_label, tap_mod.describeResolveError(e) });
        return error.Aborted;
    };
    defer head_res.deinit();
    const fresh_sha = if (head_res.not_modified)
        (cached_sha_opt orelse return error.Aborted)
    else
        (head_res.sha orelse return error.Aborted);

    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, allocator);
    defer http.deinit();
    http.offline = ctx.offline;

    var rb_url_buf: [512]u8 = undefined;
    const rb_url = forge.rawFileUrl(&rb_url_buf, .github, urls.raw_base, fresh_sha, .cask, token) catch return error.Aborted;

    var rb_resp = http.get(rb_url) catch |e| {
        output.err("Could not fetch {s} from tap {s}: {s}", .{ token, tap_label, @errorName(e) });
        return error.Aborted;
    };
    defer rb_resp.deinit();
    if (rb_resp.status != 200) return error.NotInTap;

    const rb_info = install_rb_parse_mod.parseRubyFormula(rb_resp.body) orelse return error.NotInTap;

    if (!force and std.mem.eql(u8, installed_version, rb_info.version)) {
        output.skip("{s} is already at latest version {s}", .{ token, rb_info.version });
        output.emitNdjsonEvent(.up_to_date, token, null);
        return;
    }

    if (dry_run) {
        output.info("Dry run: would upgrade cask {s} {s} -> {s}", .{ token, installed_version, rb_info.version });
        output.emitNdjsonEvent(.would_install, token, null);
        return;
    }

    // Persist the new pin BEFORE installTapFormula reads it via
    // `tap_mod.getCommitSha`. Same pattern as `upgradeTapFormula`.
    {
        const pair = tap_mod.effectiveOwnerRepo(allocator, db, tap_label, "github.com") catch {
            output.err("Could not pin {s} to {s}", .{ tap_label, fresh_sha });
            return error.Aborted;
        };
        defer pair.deinit(allocator);
        tap_mod.add(db, tap_label, pair.owner, pair.repo, fresh_sha) catch {
            output.err("Could not pin {s} to {s}", .{ tap_label, fresh_sha });
            return error.Aborted;
        };
    }
    // On 200, refresh the etag so the next round can 304. On 304 the
    // cached etag is by definition still current.
    if (!head_res.not_modified) {
        if (head_res.etag) |et| tap_mod.updateHead(db, tap_label, fresh_sha, et) catch {};
    }

    output.info("Upgrading {s} {s} -> {s}...", .{ token, installed_version, rb_info.version });

    // Snapshot the pin so a force-upgrade preserves the user's hold.
    const was_pinned = pin_mod.isPinned(db, token);

    // Single DB transaction across uninstall + install + recordInstall.
    // Mirrors the core-API path in `upgradeCask` so a partial failure
    // can't leave the casks row missing once the new app is on disk.
    var installer = cask_mod.CaskInstaller.init(ctx.io, ctx.environ, allocator, db, prefix);
    installer.offline = ctx.offline;
    db.beginTransaction() catch |txn_err| {
        output.err("Could not begin DB transaction for {s}: {s} ({s})", .{ token, @errorName(txn_err), db.errMsg() });
        return error.Aborted;
    };

    installer.uninstall(token) catch |un_err| {
        output.err("Failed to remove old version of {s}: {s}", .{ token, @errorName(un_err) });
        db.rollback();
        return error.Aborted;
    };

    const full_name = std.fmt.allocPrint(allocator, "{s}/{s}", .{ tap_label, token }) catch {
        db.rollback();
        return error.Aborted;
    };
    defer allocator.free(full_name);

    // `installTapCask` (not `installTapFormula`) so the resolver
    // never enters the Formula/ probe that would open a nested DB
    // transaction inside our outer one.
    var linker = linker_mod.Linker.init(ctx.io, allocator, db, prefix);
    install_local_mod.installTapCask(ctx, allocator, full_name, db, &linker, prefix, dry_run, true, install_sink_mod.terminal) catch |in_err| {
        output.err("Failed to upgrade tap cask {s}: {s}", .{ full_name, @errorName(in_err) });
        db.rollback();
        return error.Aborted;
    };

    db.commit() catch |commit_err| {
        output.err("Failed to commit upgrade for cask {s}: {s} ({s})", .{ token, @errorName(commit_err), db.errMsg() });
        db.rollback();
        return error.Aborted;
    };

    if (was_pinned) _ = pin_mod.setPinned(db, token, true) catch {};
}

/// Backfill the `casks.tap` column once we've discovered the owning tap
/// via the probe loop. Idempotent (`WHERE tap IS NULL`); failures are
/// non-fatal — the row stays NULL and we re-probe on the next upgrade.
pub fn backfillCaskTap(db: *sqlite.Database, token: []const u8, tap_label: []const u8) void {
    var stmt = db.prepare("UPDATE casks SET tap = ?1 WHERE token = ?2 AND tap IS NULL;") catch return;
    defer stmt.finalize();
    stmt.bindText(1, tap_label) catch return;
    stmt.bindText(2, token) catch return;
    _ = stmt.step() catch {};
}

/// Probe registered taps for a cask token whose row in `casks` has no
/// recorded tap origin (legacy v5 install, pre-schema-v6). Returns true
/// if a tap claimed the token and the upgrade resolved (installed *or*
/// skipped at the matching version); returns false if no third-party
/// tap had `Casks/<token>.rb` so the caller can surface the original
/// "removed upstream" error. On a successful match the column is
/// backfilled so the next upgrade pre-routes directly.
fn upgradeTapCaskFallback(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    token: []const u8,
    installed_version: []const u8,
    db: *sqlite.Database,
    prefix: [:0]const u8,
    dry_run: bool,
    force: bool,
) bool {
    const taps = tap_mod.list(allocator, db) catch return false;
    defer {
        for (taps) |t| {
            allocator.free(t.name);
            allocator.free(t.url);
            allocator.free(t.host);
            if (t.commit_sha) |s| allocator.free(s);
        }
        allocator.free(taps);
    }

    for (taps) |t| {
        if (install_args_mod.isCoreTap(t.name)) continue;

        upgradeRoutedTapCask(ctx, allocator, token, t.name, installed_version, db, prefix, dry_run, force) catch |e| switch (e) {
            // Either "tap doesn't own this token" or "something went
            // wrong with this tap" — neither is fatal to the probe.
            error.NotInTap, error.Aborted => continue,
        };

        // The owning tap is now known. recordInstall sets `casks.tap`
        // automatically for the install branch; backfillCaskTap covers
        // the version-match-skip branch where no recordInstall ran.
        backfillCaskTap(db, token, t.name);
        return true;
    }

    return false;
}

/// Run the DB-mutating steps of a formula upgrade — caller owns the
/// surrounding transaction. Order is load-bearing: old links must be
/// DELETEd before the new keg is INSERTed so the new symlinks can take
/// over the same `link_path`s without tripping the UNIQUE index, and
/// the old keg row stays alive until last so the FS rollback path can
/// still find its `cellar_path`. On error the caller rolls back and
/// runs `restoreOldLinks` + cellar cleanup.
pub fn upgradeDbAtomic(
    db: *sqlite.Database,
    linker: *linker_mod.Linker,
    old_keg_id: i64,
    formula: *const formula_mod.Formula,
    store_sha256: []const u8,
    new_cellar_path: []const u8,
    bin_isolated: bool,
) !i64 {
    try linker.unlink(old_keg_id);
    // `in_transaction = true` so the upgrade wrapper's outer BEGIN/COMMIT
    // owns atomicity for unlink → record → link → delete; the unified
    // recordKeg never nests BEGIN IMMEDIATE here.
    //
    // `install_reason` stays whatever the prior row carried — upgrade
    // never changes the keg's role, only its version. A dep that the
    // user opted into isolation stays isolated; a direct keg keeps its
    // bin links.
    const prior_reason: []const u8 = blk: {
        var stmt = db.prepare("SELECT install_reason FROM kegs WHERE id = ?1 LIMIT 1;") catch break :blk "direct";
        defer stmt.finalize();
        stmt.bindInt(1, old_keg_id) catch break :blk "direct";
        const ok = stmt.step() catch false;
        if (!ok) break :blk "direct";
        if (stmt.columnText(0)) |t| {
            const s = std.mem.sliceTo(t, 0);
            if (std.mem.eql(u8, s, "dependency")) break :blk "dependency";
        }
        break :blk "direct";
    };
    const new_keg_id = try install_record_mod.recordKeg(
        db,
        formula,
        store_sha256,
        new_cellar_path,
        prior_reason,
        bin_isolated,
        .{ .in_transaction = true },
    );
    try linker.link(new_cellar_path, formula.name, new_keg_id, bin_isolated);
    install_record_mod.deleteKeg(db, old_keg_id);
    return new_keg_id;
}

/// Re-link old version during rollback. Replays the old row's
/// `bin_isolated` so a partially-rolled-back keg matches the user's
/// prior intent.
fn restoreOldLinks(
    _: *sqlite.Database,
    linker: *linker_mod.Linker,
    old_cellar_path: []const u8,
    name: []const u8,
    old_keg_id: i64,
    bin_isolated: bool,
) void {
    if (old_cellar_path.len == 0) return;
    linker.link(old_cellar_path, name, old_keg_id, bin_isolated) catch {
        output.err("CRITICAL: Failed to restore old symlinks for {s}. Manual intervention may be required.", .{name});
    };
}

/// Check if a formula is installed.
fn isFormulaInstalled(db: *sqlite.Database, name: []const u8) bool {
    var stmt = db.prepare("SELECT id FROM kegs WHERE name = ?1 LIMIT 1;") catch return false;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return false;
    return stmt.step() catch false;
}

/// Upgrade all outdated formulas. Returns error.Aborted if any individual
/// upgrade failed so the caller can propagate a non-zero exit.
fn upgradeAllFormulas(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    api: *api_mod.BrewApi,
    http: *client_mod.HttpClient,
    prefix: [:0]const u8,
    dry_run: bool,
    force: bool,
    pinned_only: bool,
    isolate_deps: bool,
) !void {
    const sql: [:0]const u8 = if (pinned_only)
        "SELECT name, version FROM kegs WHERE pinned = 1 ORDER BY name;"
    else
        "SELECT name, version FROM kegs ORDER BY name;";
    var stmt = db.prepare(sql) catch return;
    defer stmt.finalize();

    // Collect names first to avoid holding the statement open during upgrade
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    while (stmt.step() catch false) {
        const name_ptr = stmt.columnText(0) orelse continue;
        const name_slice = std.mem.sliceTo(name_ptr, 0);
        const owned = allocator.dupe(u8, name_slice) catch continue;
        names.append(allocator, owned) catch {
            allocator.free(owned);
            continue;
        };
    }

    if (names.items.len == 0) {
        // Quiet on the audit path: "no pinned kegs" is the normal idle state.
        if (!pinned_only) output.info("No formulas installed.", .{});
        return;
    }

    // Count separately from the name list so an OOM on the names append
    // cannot hide a failure from the summary/exit-code contract.
    var failed_count: usize = 0;
    var failed_names: std.ArrayList([]const u8) = .empty;
    defer failed_names.deinit(allocator);

    for (names.items) |name| {
        upgradeFormula(ctx, allocator, name, db, api, http, prefix, dry_run, force, pinned_only, isolate_deps) catch {
            failed_count += 1;
            // failed_count is the authoritative counter; list is for UX only.
            failed_names.append(allocator, name) catch {};
        };
    }

    if (failed_count > 0) {
        const word: []const u8 = if (failed_count == 1) "formula" else "formulas";
        output.err("{d} {s} failed to upgrade:", .{ failed_count, word });
        for (failed_names.items) |name| output.err("  - {s}", .{name});
        return error.Aborted;
    }
}

// ---------------------------------------------------------------------------
// Cask upgrade
// ---------------------------------------------------------------------------

fn upgradeCask(ctx: *const AppCtx, allocator: std.mem.Allocator, token: []const u8, db: *sqlite.Database, api: *api_mod.BrewApi, prefix: [:0]const u8, dry_run: bool, force: bool, audit_mode: bool) !void {
    if (pinSkip(db, token, force, audit_mode)) {
        output.dim("{s} is pinned, skipped", .{token});
        output.emitNdjsonEvent(.pinned, token, null);
        return;
    }

    const installed = cask_mod.lookupInstalled(db, token) orelse {
        output.err("{s} is not installed as a cask", .{token});
        return error.Aborted;
    };

    // Pre-route when the recorded `casks.tap` points at a third-party
    // tap — saves the multi-tap probe loop and, more importantly, the
    // version compare runs against the owning tap's `.rb` before any
    // DMG download starts. Legacy rows (NULL tap, pre-v6 install) and
    // core-API casks fall through to the API path below.
    if (installed.tap()) |tap_label| {
        if (!install_args_mod.isCoreTap(tap_label)) {
            upgradeRoutedTapCask(ctx, allocator, token, tap_label, installed.version(), db, prefix, dry_run, force) catch |e| switch (e) {
                error.NotInTap => {
                    output.err("Cask {s} is no longer in tap {s}", .{ token, tap_label });
                    return error.Aborted;
                },
                error.Aborted => return error.Aborted,
            };
            return;
        }
    }

    // Fetch latest version. Casks have no `tap` column populated on
    // legacy installs, so we still fall back to probing every registered
    // third-party tap if the core API 404s — the probe also backfills
    // `casks.tap` for the next invocation.
    const cask_json = api.fetchCask(token) catch {
        if (upgradeTapCaskFallback(ctx, allocator, token, installed.version(), db, prefix, dry_run, force)) return;
        output.err("Could not fetch cask info for {s}", .{token});
        return error.Aborted;
    };
    defer allocator.free(cask_json);

    var parsed_cask = cask_mod.parseCask(allocator, cask_json) catch {
        output.err("Failed to parse cask JSON for {s}", .{token});
        return error.Aborted;
    };
    defer parsed_cask.deinit();

    const installed_version = installed.version();
    if (std.mem.eql(u8, installed_version, parsed_cask.version)) {
        output.skip("{s} is already at latest version {s}", .{ token, parsed_cask.version });
        output.emitNdjsonEvent(.up_to_date, token, null);
        return;
    }

    if (dry_run) {
        output.info("Dry run: would upgrade cask {s} {s} -> {s}", .{ token, installed_version, parsed_cask.version });
        output.emitNdjsonEvent(.would_install, token, null);
        return;
    }

    output.info("Upgrading {s} {s} -> {s}...", .{ token, installed_version, parsed_cask.version });

    // Snapshot the pin BEFORE uninstall removes the cask row; re-apply
    // after recordInstall so a `--force` upgrade preserves the user's hold.
    const was_pinned = pin_mod.isPinned(db, token);

    // Atomic DB section (uninstall's DELETE + recordInstall's INSERT OR
    // REPLACE) so a partial failure can't leave the casks row missing
    // when the new app is already on disk. The malt.lock fileguards
    // against other malt writers, so holding the SQLite txn across the
    // (potentially slow) install is harmless to other connections.
    var installer = cask_mod.CaskInstaller.init(ctx.io, ctx.environ, allocator, db, prefix);
    installer.offline = ctx.offline;
    db.beginTransaction() catch |txn_err| {
        output.err(
            "Could not begin DB transaction for {s}: {s} ({s})",
            .{ token, @errorName(txn_err), db.errMsg() },
        );
        return error.Aborted;
    };

    installer.uninstall(token) catch |un_err| {
        output.err(
            "Failed to remove old version of {s}: {s}",
            .{ token, @errorName(un_err) },
        );
        db.rollback();
        return error.Aborted;
    };

    const app_path = installer.install(&parsed_cask) catch |in_err| {
        output.err(
            "Failed to install new version of {s}: {s}",
            .{ token, @errorName(in_err) },
        );
        db.rollback();
        return error.Aborted;
    };

    // Reaching this point implies the core Homebrew API served the
    // cask, so the tap origin stays NULL. Tap-installed casks pre-route
    // to `upgradeTapCask` and never get here.
    cask_mod.recordInstall(db, &parsed_cask, app_path, null) catch |rec_err| {
        output.err(
            "Failed to record cask {s} in database: {s} ({s})",
            .{ token, @errorName(rec_err), db.errMsg() },
        );
        db.rollback();
        allocator.free(app_path);
        return error.Aborted;
    };
    allocator.free(app_path);

    db.commit() catch |commit_err| {
        output.err(
            "Failed to commit upgrade for cask {s}: {s} ({s})",
            .{ token, @errorName(commit_err), db.errMsg() },
        );
        db.rollback();
        return error.Aborted;
    };

    if (was_pinned) {
        // Best-effort: a missing pin restore is a UX regression, not data
        // loss — the cask itself is upgraded and recorded.
        _ = pin_mod.setPinned(db, token, true) catch {};
    }

    output.success("{s} upgraded to {s}", .{ token, parsed_cask.version });
}

fn upgradeAllCasks(ctx: *const AppCtx, allocator: std.mem.Allocator, db: *sqlite.Database, api: *api_mod.BrewApi, prefix: [:0]const u8, dry_run: bool, force: bool, pinned_only: bool) !void {
    const sql: [:0]const u8 = if (pinned_only)
        "SELECT token, version FROM casks WHERE pinned = 1 ORDER BY token;"
    else
        "SELECT token, version FROM casks ORDER BY token;";
    var stmt = db.prepare(sql) catch return;
    defer stmt.finalize();

    // Collect tokens first so we can free the statement before driving
    // per-cask upgrades; each upgrade opens its own statements.
    var tokens: std.ArrayList([]const u8) = .empty;
    defer {
        for (tokens.items) |t| allocator.free(t);
        tokens.deinit(allocator);
    }

    while (stmt.step() catch false) {
        const token_ptr = stmt.columnText(0) orelse continue;
        const token_slice = std.mem.sliceTo(token_ptr, 0);
        const owned = allocator.dupe(u8, token_slice) catch continue;
        tokens.append(allocator, owned) catch {
            allocator.free(owned);
            continue;
        };
    }

    if (tokens.items.len == 0) {
        // Quiet on the audit path: "no pinned casks" is the normal idle state.
        if (!pinned_only) output.info("All casks are up to date.", .{});
        return;
    }

    var failed_count: usize = 0;
    var failed_tokens: std.ArrayList([]const u8) = .empty;
    defer failed_tokens.deinit(allocator);

    for (tokens.items) |token| {
        upgradeCask(ctx, allocator, token, db, api, prefix, dry_run, force, pinned_only) catch {
            failed_count += 1;
            // failed_count is authoritative; list is for UX only.
            failed_tokens.append(allocator, token) catch {};
        };
    }

    if (failed_count > 0) {
        const word: []const u8 = if (failed_count == 1) "cask" else "casks";
        output.err("{d} {s} failed to upgrade:", .{ failed_count, word });
        for (failed_tokens.items) |token| output.err("  - {s}", .{token});
        return error.Aborted;
    }
}

/// Filter `dep_names` to those not yet recorded in `kegs`. Caller owns
/// the outer slice; the entries borrow from `dep_names`.
///
/// This is the seam upgrade uses to catch transitive deps that the
/// previously-installed bottle didn't have but the new bottle does
/// (e.g. curl 8.20 introduces a runtime dep on libngtcp2 that wasn't
/// part of curl 8.19's dep set).
pub fn collectMissingDepNames(
    io: std.Io,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    dep_names: []const []const u8,
) ![][]const u8 {
    var missing: std.ArrayList([]const u8) = .empty;
    errdefer missing.deinit(allocator);

    // Strict check: a DB row alone does not count - the cellar dir and
    // opt symlink must also resolve. The install path's BFS uses the
    // same predicate, so an opt-link nuked under a previously-installed
    // dep self-heals through both `mt install` and `mt upgrade`.
    for (dep_names) |n| {
        if (!deps_mod.isInstalled(io, db, n)) try missing.append(allocator, n);
    }
    return missing.toOwnedSlice(allocator);
}

// `collectMissingDepNames` now consults the filesystem (cellar_path +
// opt symlink), so coverage lives in `tests/upgrade_test.zig` where a
// real MALT_PREFIX fixture is available.
