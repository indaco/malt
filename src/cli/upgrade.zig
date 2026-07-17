//! malt — upgrade command
//! Upgrade installed packages and casks.

const std = @import("std");

const AppCtx = @import("../app_ctx.zig").AppCtx;
const cask_mod = @import("../core/cask.zig");
const cellar_mod = @import("../core/cellar.zig");
const signals = @import("../core/signals.zig");
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
const lock_report = @import("lock_report.zig");
const install_args_mod = @import("install/args.zig");
const install_download_mod = @import("install/download.zig");
const install_local_mod = @import("install/local.zig");
const install_rb_parse_mod = @import("install/rb_parse.zig");
const install_record_mod = @import("install/record.zig");
const InstallError = install_record_mod.InstallError;
const install_sink_mod = @import("install/sink.zig");
const post_install_mod = @import("install/post_install.zig");
const install_mod = @import("install.zig");
const outdated_mod = @import("outdated.zig");
const pin_mod = @import("pin.zig");

const OutdatedEntry = outdated_mod.OutdatedEntry;

const UpgradeFlag = enum { quiet, cask, formula, dry_run, force, pinned, isolate_deps, use_system_ruby };

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
    // Recognised only to refuse it with a pointed message: a bare flag
    // would widen the Ruby trust boundary to every outdated keg.
    .{ "--use-system-ruby", .use_system_ruby },
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

/// Aggregate outcome counters for a bulk `mt upgrade` run. The *presence*
/// of a `*Tally` (vs `null`) threaded into the per-package functions is
/// also the bulk-mode signal: it suppresses the per-package "already
/// current" line so a mostly-current machine summarises instead of
/// narrating every row. The named path passes `null` and keeps its lines.
const Tally = struct {
    upgraded: usize = 0,
    would_upgrade: usize = 0,
    up_to_date: usize = 0,
    pinned: usize = 0,
    failed: usize = 0,

    fn checked(self: Tally) usize {
        return self.upgraded + self.would_upgrade + self.up_to_date + self.pinned + self.failed;
    }

    /// Render the one-line footer into `buf`. Dry-run swaps "upgraded" for
    /// "would upgrade"; the failed clause appears only when something failed.
    /// `·` (U+00B7) separators match the dim-detail style and render under
    /// both `NO_COLOR` and `MALT_NO_EMOJI`.
    fn summaryLine(self: Tally, buf: []u8, dry_run: bool) []const u8 {
        const action_count = if (dry_run) self.would_upgrade else self.upgraded;
        const action_word = if (dry_run) "would upgrade" else "upgraded";
        const head = std.fmt.bufPrint(buf, "{d} checked · {d} {s} · {d} up to date · {d} pinned", .{
            self.checked(), action_count, action_word, self.up_to_date, self.pinned,
        }) catch return buf[0..0];
        if (self.failed == 0) return head;
        const tail = std.fmt.bufPrint(buf[head.len..], " · {d} failed", .{self.failed}) catch return head;
        return buf[0 .. head.len + tail.len];
    }
};

/// Print the bulk-run footer once, after both the formula and cask passes.
/// Silent when nothing was checked (empty prefix) so it never prints a
/// `0 checked …` line under the existing "No formulas installed." message.
fn printSummary(tally: Tally, dry_run: bool) void {
    if (tally.checked() == 0) return;
    var buf: [160]u8 = undefined;
    output.notice("{s}", .{tally.summaryLine(&buf, dry_run)});
}

/// Side-channel collector for a full `mt upgrade --dry-run`. `Tally` is
/// counters only, so the would-upgrade *rows* are gathered here as
/// snapshot-shaped `OutdatedEntry`s to warm the shared `outdated.json`.
/// `tainted` trips at any decision point that cannot emit a snapshot-shaped
/// row (tap formulas decide by commit sha, not version): the caller then
/// skips the warm rather than persist a snapshot that under-reports.
const EntrySink = struct {
    allocator: std.mem.Allocator,
    formulas: std.ArrayList(OutdatedEntry) = .empty,
    casks: std.ArrayList(OutdatedEntry) = .empty,
    tainted: bool = false,

    fn init(allocator: std.mem.Allocator) EntrySink {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *EntrySink) void {
        freeEntries(self.allocator, &self.formulas);
        freeEntries(self.allocator, &self.casks);
    }

    /// Formula would-upgrade row: `installed` is revision-qualified
    /// (`1.2_2`, not bare `1.2`) so the warmed entry matches
    /// `assembleEntries` byte-for-byte.
    fn collectFormula(self: *EntrySink, name: []const u8, version: []const u8, revision: i64, latest: []const u8) void {
        var buf: [256]u8 = undefined;
        const installed = formula_mod.pkgVersion(&buf, version, revision) catch version;
        self.append(&self.formulas, name, installed, latest);
    }

    /// Cask would-upgrade row: casks have no revision, so `installed` is
    /// the bare recorded version — the same shape `assembleEntries` emits
    /// for a `0 AS revision` cask row.
    fn collectCask(self: *EntrySink, token: []const u8, installed: []const u8, latest: []const u8) void {
        self.append(&self.casks, token, installed, latest);
    }

    /// Dupe the three fields into the sink's allocator. A dupe/append
    /// failure taints the sink: a dropped row would silently under-report,
    /// so the caller must skip the warm rather than persist a partial set.
    fn append(self: *EntrySink, list: *std.ArrayList(OutdatedEntry), name: []const u8, installed: []const u8, latest: []const u8) void {
        const entry = dupEntry(self.allocator, name, installed, latest) catch {
            self.tainted = true;
            return;
        };
        list.append(self.allocator, entry) catch {
            freeEntry(self.allocator, entry);
            self.tainted = true;
        };
    }
};

fn dupEntry(allocator: std.mem.Allocator, name: []const u8, installed: []const u8, latest: []const u8) !OutdatedEntry {
    const n = try allocator.dupe(u8, name);
    errdefer allocator.free(n);
    const i = try allocator.dupe(u8, installed);
    errdefer allocator.free(i);
    const l = try allocator.dupe(u8, latest);
    return .{ .name = n, .installed = i, .latest = l };
}

fn freeEntry(allocator: std.mem.Allocator, e: OutdatedEntry) void {
    allocator.free(e.name);
    allocator.free(e.installed);
    allocator.free(e.latest);
}

fn freeEntries(allocator: std.mem.Allocator, list: *std.ArrayList(OutdatedEntry)) void {
    for (list.items) |e| freeEntry(allocator, e);
    list.deinit(allocator);
}

/// Gate the snapshot warm to a *complete* dry-run audit. A narrowed run
/// (names, `--cask`/`--formula`, `--pinned`), a failed walk, or a tainted
/// collector would each persist a partial snapshot and make the Outdated
/// view silently under-report — so every one vetoes the write. A real
/// (non-dry-run) upgrade never warms: the pre-upgrade set is stale the
/// instant kegs mutate. It prunes instead — see `pruneSnapshot`, which
/// subtracts the moved kegs rather than persisting a stale set.
const WarmGate = struct {
    dry_run: bool = false,
    has_names: bool = false,
    cask_only: bool = false,
    formula_only: bool = false,
    pinned_only: bool = false,
    walk_failed: bool = false,
    tainted: bool = false,
};

fn shouldWarmSnapshot(g: WarmGate) bool {
    return g.dry_run and !g.has_names and !g.cask_only and !g.formula_only and
        !g.pinned_only and !g.walk_failed and !g.tainted;
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
    // Collect every positional, mirroring `install`: tokens borrow from
    // `args` (process-lifetime), so no dup is needed.
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    // Scoped opt-in for the post-install Ruby fallback, same contract as
    // `migrate`: named kegs only, never a blanket flag.
    var use_system_ruby_bare = false;
    var use_system_ruby_scope: std.ArrayList([]const u8) = .empty;
    defer use_system_ruby_scope.deinit(allocator);

    // StaticStringMap + exhaustive switch: every flag routes to a handler.
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--use-system-ruby=")) {
            const list = arg["--use-system-ruby=".len..];
            var it = std.mem.splitScalar(u8, list, ',');
            while (it.next()) |n| {
                if (n.len > 0) use_system_ruby_scope.append(allocator, n) catch return error.OutOfMemory;
            }
        } else if (upgrade_flag_map.get(arg)) |flag| switch (flag) {
            .quiet => output.setQuiet(true),
            .cask => cask_only = true,
            .formula => formula_only = true,
            .dry_run => dry_run = true,
            .force => force = true,
            .pinned => pinned_only = true,
            .isolate_deps => isolate_deps = true,
            .use_system_ruby => use_system_ruby_bare = true,
        } else if (arg.len > 0 and arg[0] != '-') {
            names.append(allocator, arg) catch return error.OutOfMemory;
        }
    }

    if (use_system_ruby_bare) {
        output.err("a bare --use-system-ruby would apply to every outdated keg — name them: --use-system-ruby=<name>,...", .{});
        return error.Aborted;
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
    var lk = lock_mod.LockFile.acquire(ctx.io, lock_path, 5000) catch |e| switch (e) {
        // Fresh prefix: no `db/` yet = nothing installed, nothing to
        // upgrade. Exit 0 silently rather than treating the missing
        // lock directory as contention with another process.
        error.DirMissing => return,
        // dry_run audits stay quiet on any other failure; otherwise tell
        // the user exactly what went wrong.
        else => {
            if (dry_run) return;
            lock_report.reportAcquireFailure(e, prefix);
            return error.Aborted;
        },
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
    var app_running = false; // a named cask refused because its app is live
    var other_failed = false; // any failure that is not the app-running refusal

    if (names.items.len == 0) {
        // Upgrade all. A live `*Tally` threaded down both passes is also
        // the bulk-mode signal: per-package "already current" lines are
        // suppressed in favour of one summary footer printed below.
        var tally: Tally = .{};
        // Collect the would-upgrade rows only when a warm could actually
        // fire: a full, unnarrowed dry-run. The sink threads down both
        // passes alongside `tally`; a real upgrade or any narrowing passes
        // `null` so nothing is gathered.
        var sink: EntrySink = .init(allocator);
        defer sink.deinit();
        const warm_candidate = dry_run and !cask_only and !formula_only and !pinned_only;
        const sink_ptr: ?*EntrySink = if (warm_candidate) &sink else null;
        if (!cask_only) {
            upgradeAllFormulas(ctx, allocator, &db, &api, &http, prefix, dry_run, force, pinned_only, isolate_deps, use_system_ruby_scope.items, &tally, sink_ptr) catch {
                any_failed = true;
            };
        }
        if (!formula_only) {
            upgradeAllCasks(ctx, allocator, &db, &api, prefix, dry_run, force, pinned_only, &tally, sink_ptr) catch {
                any_failed = true;
            };
        }
        printSummary(tally, dry_run);

        // Best-effort warm of the shared outdated snapshot from the dry-run's
        // own audit — a cache-write failure never changes exit code or output.
        // Reuses the `{prefix}/cache` dir already resolved above.
        if (shouldWarmSnapshot(.{
            .dry_run = dry_run,
            .cask_only = cask_only,
            .formula_only = formula_only,
            .pinned_only = pinned_only,
            .walk_failed = any_failed,
            .tainted = sink.tainted,
        })) {
            outdated_mod.writeSnapshotEntries(ctx, allocator, cache_dir, sink.formulas.items, sink.casks.items) catch {};
        }
    } else {
        // Upgrade each named package — formula first, then cask. A failed
        // or aborted name aggregates into `any_failed` and the loop moves
        // on, so one bad name never abandons the rest of the batch. `null`
        // tally keeps each named package's per-package line and no footer.
        for (names.items) |name| {
            if (!cask_only and isFormulaInstalled(&db, name)) {
                upgradeFormula(ctx, allocator, name, &db, &api, &http, prefix, dry_run, force, pinned_only, isolate_deps, use_system_ruby_scope.items, null, null) catch {
                    any_failed = true;
                    other_failed = true;
                };
                continue;
            }
            // Not a formula (or --cask): try cask
            upgradeCask(ctx, allocator, name, &db, &api, prefix, dry_run, force, pinned_only, null, null) catch |e| {
                any_failed = true;
                if (e == error.AppRunning) app_running = true else other_failed = true;
            };
        }
    }

    // A real upgrade moved kegs, so the shared snapshot now lists packages at
    // versions they no longer carry. Reconcile it against the DB — one call
    // covers both branches above, including the named path. Best-effort: a
    // cache write must not fail an upgrade that already succeeded. A dry-run
    // mutates nothing, so it has nothing to reconcile.
    if (!dry_run) outdated_mod.pruneSnapshot(ctx.io, allocator, &db, cache_dir);

    // A batch whose only failure was a live cask app exits with the dedicated
    // code so the TUI can footer the real cause; any other failure (even mixed
    // in) stays the generic abort.
    if (any_failed) {
        if (app_running and !other_failed) return error.AppRunning;
        return error.Aborted;
    }
}

// ---------------------------------------------------------------------------
// Formula upgrade
// ---------------------------------------------------------------------------

/// The installed keg row `upgradeFormula` needs after its DB lookup.
/// Text columns are owned copies so the lookup statement can be finalized
/// immediately — see `readOldKeg`.
const OldKeg = struct {
    keg_id: i64,
    version: []const u8,
    revision: i64,
    sha256: []const u8,
    cellar_path: []const u8,
    tap: []const u8,
    bin_isolated: bool,

    fn deinit(self: *OldKeg, allocator: std.mem.Allocator) void {
        allocator.free(self.version);
        allocator.free(self.sha256);
        allocator.free(self.cellar_path);
        allocator.free(self.tap);
    }
};

/// Read the installed keg row for `name` into owned storage, finalizing the
/// statement before returning so no read snapshot outlives the call. Holding
/// a stepped-open statement pins this connection's WAL read snapshot; the
/// re-entrant dep install then opens a second connection that advances the
/// WAL, and the parent's later writes can no longer promote the stale
/// snapshot to a writer (SQLITE_BUSY). Returns null when no row matches.
fn readOldKeg(allocator: std.mem.Allocator, db: *sqlite.Database, name: []const u8) !?OldKeg {
    var stmt = try db.prepare(
        "SELECT id, version, revision, store_sha256, cellar_path, tap, bin_isolated FROM kegs WHERE name = ?1 LIMIT 1;",
    );
    defer stmt.finalize();
    try stmt.bindText(1, name);
    if (!(try stmt.step())) return null;

    const version = try allocator.dupe(u8, if (stmt.columnText(1)) |v| std.mem.sliceTo(v, 0) else "unknown");
    errdefer allocator.free(version);
    const sha256 = try allocator.dupe(u8, if (stmt.columnText(3)) |s| std.mem.sliceTo(s, 0) else "");
    errdefer allocator.free(sha256);
    const cellar_path = try allocator.dupe(u8, if (stmt.columnText(4)) |cp| std.mem.sliceTo(cp, 0) else "");
    errdefer allocator.free(cellar_path);
    const tap = try allocator.dupe(u8, if (stmt.columnText(5)) |t| std.mem.sliceTo(t, 0) else "");

    return .{
        .keg_id = stmt.columnInt(0),
        .version = version,
        .revision = stmt.columnInt(2),
        .sha256 = sha256,
        .cellar_path = cellar_path,
        .tap = tap,
        .bin_isolated = stmt.columnInt(6) != 0,
    };
}

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
    use_system_ruby: []const []const u8,
    tally: ?*Tally,
    sink: ?*EntrySink,
) !void {
    // Honor pins before any network or filesystem work — the whole
    // point is that a pinned keg never gets touched. Audit mode
    // (`--pinned --dry-run`) walks pinned kegs end-to-end so the user
    // sees the drift, but the dry-run gate still blocks any mutation.
    if (pinSkip(db, name, force, audit_mode)) {
        // `skip` (not `dim`) so the held-back pin shares the `·` glyph of
        // the up-to-date family instead of the `▸` upgrade glyph.
        output.skip("{s} is pinned, skipped", .{name});
        // Distinguishes "skipped by policy" from "command never ran".
        output.emitNdjsonEvent(.pinned, name, null);
        if (tally) |t| t.pinned += 1;
        return;
    }

    // Read the keg row into owned storage and release its read snapshot
    // before the dep re-entry (why: see readOldKeg). `bin_isolated` replays
    // the user's prior isolation intent without re-passing a flag.
    var old = (readOldKeg(allocator, db, name) catch return error.Aborted) orelse {
        output.err("{s} is not installed as a formula", .{name});
        return error.Aborted;
    };
    defer old.deinit(allocator);

    // Tap-installed formulas come from `<user>/<repo>` repos, not the
    // homebrew/core API. Route them through the tap-aware upgrade path
    // before touching `formulae.brew.sh`. `old.tap` is owned and lives
    // until this function returns, so it is safe to pass across the call.
    if (!install_args_mod.isCoreTap(old.tap)) {
        return upgradeTapFormula(ctx, allocator, name, old.tap, old.version, old.revision, db, prefix, dry_run, force, audit_mode, tally, sink);
    }

    // Reconstruct the revision-aware path label for the old keg so
    // cellar_mod.remove / linker calls target the actual on-disk dir.
    var old_pkgver_buf: [128]u8 = undefined;
    const old_pkg_version = formula_mod.pkgVersion(&old_pkgver_buf, old.version, old.revision) catch old.version;

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

    // Compare versions. On the bulk path (tally present) the "already
    // current" line is suppressed — the footer tallies it instead — but the
    // NDJSON event is always emitted so the machine stream is unchanged.
    if (std.mem.eql(u8, old_pkg_version, formula.pkg_version)) {
        if (tally) |t| t.up_to_date += 1 else output.skip("{s} is already at latest version {s}", .{ name, formula.pkg_version });
        output.emitNdjsonEvent(.up_to_date, name, null);
        return;
    }

    if (dry_run) {
        if (tally) |t| t.would_upgrade += 1;
        if (sink) |s| s.collectFormula(name, old.version, old.revision, formula.pkg_version);
        output.info("Dry run: would upgrade {s} {s} -> {s}", .{ name, old.version, formula.pkg_version });
        // Same vocabulary across install/upgrade/migrate — one parser fits all.
        output.emitNdjsonEvent(.would_install, name, null);
        return;
    }

    output.info("Upgrading {s} {s} -> {s}...", .{ name, old.version, formula.pkg_version });
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

    const new_keg_id = upgradeDbAtomic(db, &linker, old.keg_id, &formula, fetch.sha256, new_keg.path, old.bin_isolated) catch |db_err| {
        output.err(
            "Failed to record new version of {s} in database: {s} ({s})",
            .{ name, @errorName(db_err), db.errMsg() },
        );
        db.rollback();
        // FS rollback: the txn restored old keg/links rows; we still
        // need to recreate the old symlinks (FS isn't transactional)
        // and drop the freshly-materialized new cellar dir.
        restoreOldLinks(db, &linker, old.cellar_path, name, old.keg_id, old.bin_isolated);
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
        restoreOldLinks(db, &linker, old.cellar_path, name, old.keg_id, old.bin_isolated);
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

    if (old.sha256.len > 0) {
        // refcount is advisory; upgrade is already complete on disk.
        store.decrementRef(old.sha256) catch {};
    }

    // Same post-install contract as `mt install`: the fresh keg's hook
    // (declarative steps or Ruby body) runs against the new version, and
    // the shipped CA bundle is re-linked for kegs that carry one.
    if (formula.hasPostInstallHook()) {
        post_install_mod.drive(ctx, allocator, name, formula.pkg_version, formula_json, prefix, use_system_ruby, null, install_sink_mod.terminal);
    }
    post_install_mod.provisionShippedCaBundle(ctx.io, prefix, name);

    output.success("{s} upgraded to {s}", .{ name, formula.pkg_version });
    if (tally) |t| t.upgraded += 1;
}

/// How a dry-run tap formula feeds the snapshot warm. `taint` degrades the
/// whole run to a full recompute (never a partial warm); `skip` is a sha-only
/// move the tap `.rb` proves current; `collect` is a genuine would-upgrade row.
const TapWarmDecision = enum { collect, skip, taint };

/// null `upstream` (fetch/parse failed) taints rather than skips: without a
/// version we cannot prove the row current, and skipping it would silently
/// under-report a genuinely-outdated tap keg — a taint re-audits everything
/// instead. A match is current (skip); a difference is outdated (collect),
/// mirroring the audit's `!eql` filter so both agree on tap version-truth.
fn tapWarmDecision(upstream: ?[]const u8, installed: []const u8) TapWarmDecision {
    const up = upstream orelse return .taint;
    return if (std.mem.eql(u8, up, installed)) .skip else .collect;
}

test "tapWarmDecision: null taints, equal skips, differing collects" {
    try std.testing.expectEqual(TapWarmDecision.taint, tapWarmDecision(null, "1.2.0"));
    try std.testing.expectEqual(TapWarmDecision.skip, tapWarmDecision("1.2.0", "1.2.0"));
    try std.testing.expectEqual(TapWarmDecision.collect, tapWarmDecision("1.3.0", "1.2.0"));
    // Revision-qualified strings compare byte-for-byte, so a revision-only
    // bump (`1.2.0` vs `1.2.0_1`) is a collect, not a skip.
    try std.testing.expectEqual(TapWarmDecision.collect, tapWarmDecision("1.2.0_1", "1.2.0"));
}

/// Resolve a tap formula's upstream version from its `.rb` at `sha`, for the
/// dry-run warm. Reuses the shared `tap.fetchRawFile` leaf; the parse is local
/// (the outdated audit taints differently, so per-caller failure policy stays
/// here). Null on any fetch/parse failure so the caller degrades to a taint.
fn tapFormulaUpstreamVersion(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    forge_kind: forge.Forge,
    raw_base: []const u8,
    sha: []const u8,
    name: []const u8,
) ?[]u8 {
    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, allocator);
    defer http.deinit();
    var fetch = tap_mod.fetchRawFile(&http, ctx.environ, forge_kind, raw_base, sha, name, &.{ .formula, .formula_root }) catch return null;
    switch (fetch) {
        .not_found => return null,
        .found => |*resp| {
            defer resp.deinit();
            const rb_info = install_rb_parse_mod.parseRubyFormula(resp.body) orelse return null;
            var ver_buf: [256]u8 = undefined;
            const qualified = formula_mod.pkgVersion(&ver_buf, rb_info.version, rb_info.revision) catch rb_info.version;
            return allocator.dupe(u8, qualified) catch null;
        },
    }
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
    installed_version: []const u8,
    installed_revision: i64,
    db: *sqlite.Database,
    prefix: [:0]const u8,
    dry_run: bool,
    force: bool,
    audit_mode: bool,
    tally: ?*Tally,
    sink: ?*EntrySink,
) !void {
    if (pinSkip(db, name, force, audit_mode)) {
        output.skip("{s} is pinned, skipped", .{name});
        output.emitNdjsonEvent(.pinned, name, null);
        if (tally) |t| t.pinned += 1;
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

    var rerr_buf: [512]u8 = undefined;
    var head_res = tap_mod.resolveHeadCommit(ctx.io, ctx.environ, allocator, urls.forge, urls.api_head_url, cached_etag_opt) catch |e| {
        output.err("Could not resolve {s} HEAD: {s}", .{ tap_label, tap_mod.describeResolveError(&rerr_buf, e, urls.forge, urls.host) });
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
        if (tally) |t| t.up_to_date += 1 else output.skip("{s} is already at latest tap commit", .{name});
        output.emitNdjsonEvent(.up_to_date, name, null);
        return;
    }

    if (dry_run) {
        if (tally) |t| t.would_upgrade += 1;
        // The would-upgrade set is sha-driven (so `mt upgrade` still refreshes
        // on any HEAD move); the snapshot warm must be version-truth to match
        // `mt outdated`. Resolve the tap `.rb` version so a sha-only move no
        // longer taints the whole warm — only a real version bump lands a row.
        if (sink) |s| {
            var qbuf: [256]u8 = undefined;
            const installed = formula_mod.pkgVersion(&qbuf, installed_version, installed_revision) catch installed_version;
            const upstream = tapFormulaUpstreamVersion(ctx, allocator, urls.forge, urls.raw_base, fresh_sha, name);
            defer if (upstream) |u| allocator.free(u);
            switch (tapWarmDecision(upstream, installed)) {
                .taint => s.tainted = true, // fetch/parse failure → full recompute
                .skip => {}, // sha-only move: legitimately current
                .collect => s.collectFormula(name, installed_version, installed_revision, upstream.?),
            }
        }
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
    if (tally) |t| t.upgraded += 1;
}

/// Distinguishes "this tap doesn't own the cask" from "the upgrade
/// attempt failed". The probe loop in `upgradeTapCaskFallback` continues
/// on either — the pre-routed call from `upgradeCask` continues only on
/// the latter (a 404 against a recorded `casks.tap` is user-facing).
const TapRouteError = error{ NotInTap, Aborted, AppRunning };

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
    tally: ?*Tally,
    sink: ?*EntrySink,
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

    var rerr_buf: [512]u8 = undefined;
    var head_res = tap_mod.resolveHeadCommit(ctx.io, ctx.environ, allocator, urls.forge, urls.api_head_url, cached_etag_opt) catch |e| {
        output.err("Could not resolve {s} HEAD: {s}", .{ tap_label, tap_mod.describeResolveError(&rerr_buf, e, urls.forge, urls.host) });
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
    const rb_url = forge.rawFileUrl(&rb_url_buf, urls.forge, urls.raw_base, fresh_sha, .cask, token) catch return error.Aborted;

    var rb_resp = tap_mod.getRawFile(&http, ctx.environ, urls.forge, rb_url) catch |e| {
        output.err("Could not fetch {s} from tap {s}: {s}", .{ token, tap_label, @errorName(e) });
        return error.Aborted;
    };
    defer rb_resp.deinit();
    if (rb_resp.status != 200) return error.NotInTap;

    const rb_info = install_rb_parse_mod.parseRubyFormula(rb_resp.body) orelse return error.NotInTap;

    if (!force and std.mem.eql(u8, installed_version, rb_info.version)) {
        if (tally) |t| t.up_to_date += 1 else output.skip("{s} is already at latest version {s}", .{ token, rb_info.version });
        output.emitNdjsonEvent(.up_to_date, token, null);
        return;
    }

    if (dry_run) {
        if (tally) |t| t.would_upgrade += 1;
        if (sink) |s| {
            // Qualify with the .rb revision to match `assembleEntries`'
            // tap-cask latest (`pkgVersion(version, revision)`).
            var latest_buf: [256]u8 = undefined;
            const latest = formula_mod.pkgVersion(&latest_buf, rb_info.version, rb_info.revision) catch rb_info.version;
            s.collectCask(token, installed_version, latest);
        }
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
        db.rollback();
        if (un_err == error.AppRunning) {
            output.err("Cannot upgrade {s}: the app is running. Quit it and try again.", .{token});
            return error.AppRunning;
        }
        output.err("Failed to remove old version of {s}: {s}", .{ token, @errorName(un_err) });
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
    if (tally) |t| t.upgraded += 1;
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
    tally: ?*Tally,
    sink: ?*EntrySink,
) error{AppRunning}!bool {
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

        upgradeRoutedTapCask(ctx, allocator, token, t.name, installed_version, db, prefix, dry_run, force, tally, sink) catch |e| switch (e) {
            // Either "tap doesn't own this token" or "something went
            // wrong with this tap" — neither is fatal to the probe.
            error.NotInTap, error.Aborted => continue,
            // The owning tap was found and refused: propagate, don't keep probing.
            error.AppRunning => return error.AppRunning,
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
    // Re-record the upgraded keg's runtime deps on the new id: deleteKeg
    // wipes the old keg's `dependencies` rows, and without rebuilding them
    // the keg ends up edge-less — `cleanup`'s orphan scan would then reap
    // a still-live dependency. Same call the install/migrate paths make.
    install_record_mod.recordDeps(db, new_keg_id, formula);
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
    use_system_ruby: []const []const u8,
    tally: *Tally,
    sink: ?*EntrySink,
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
        // Stop between packages on Ctrl-C; the in-flight fetch is torn down by
        // http.cancel, this keeps us from starting the next one.
        if (signals.isInterrupted()) break;
        upgradeFormula(ctx, allocator, name, db, api, http, prefix, dry_run, force, pinned_only, isolate_deps, use_system_ruby, tally, sink) catch {
            failed_count += 1;
            tally.failed += 1;
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

fn upgradeCask(ctx: *const AppCtx, allocator: std.mem.Allocator, token: []const u8, db: *sqlite.Database, api: *api_mod.BrewApi, prefix: [:0]const u8, dry_run: bool, force: bool, audit_mode: bool, tally: ?*Tally, sink: ?*EntrySink) !void {
    if (pinSkip(db, token, force, audit_mode)) {
        output.skip("{s} is pinned, skipped", .{token});
        output.emitNdjsonEvent(.pinned, token, null);
        if (tally) |t| t.pinned += 1;
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
            upgradeRoutedTapCask(ctx, allocator, token, tap_label, installed.version(), db, prefix, dry_run, force, tally, sink) catch |e| switch (e) {
                error.NotInTap => {
                    output.err("Cask {s} is no longer in tap {s}", .{ token, tap_label });
                    return error.Aborted;
                },
                error.AppRunning => return error.AppRunning, // already explained; keep the distinct code
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
        if (try upgradeTapCaskFallback(ctx, allocator, token, installed.version(), db, prefix, dry_run, force, tally, sink)) return;
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
        if (tally) |t| t.up_to_date += 1 else output.skip("{s} is already at latest version {s}", .{ token, parsed_cask.version });
        output.emitNdjsonEvent(.up_to_date, token, null);
        return;
    }

    if (dry_run) {
        if (tally) |t| t.would_upgrade += 1;
        if (sink) |s| s.collectCask(token, installed_version, parsed_cask.version);
        output.info("Dry run: would upgrade cask {s} {s} -> {s}", .{ token, installed_version, parsed_cask.version });
        output.emitNdjsonEvent(.would_install, token, null);
        return;
    }

    // A PKG-cask upgrade re-runs `sudo installer -target /`. Gate it on a live
    // terminal + confirmation here, before the uninstall below, so a refusal
    // off a TTY leaves the installed version untouched.
    if (cask_mod.artifactTypeFromUrl(parsed_cask.url) == .pkg) {
        output.warn("{s} is a PKG cask and requires sudo to install via macOS Installer.", .{token});
        if (!install_mod.confirmPkgSudo(token)) return error.Aborted;
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
        db.rollback();
        if (un_err == error.AppRunning) {
            output.err("Cannot upgrade {s}: the app is running. Quit it and try again.", .{token});
            return error.AppRunning;
        }
        output.err(
            "Failed to remove old version of {s}: {s}",
            .{ token, @errorName(un_err) },
        );
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
    if (tally) |t| t.upgraded += 1;
}

fn upgradeAllCasks(ctx: *const AppCtx, allocator: std.mem.Allocator, db: *sqlite.Database, api: *api_mod.BrewApi, prefix: [:0]const u8, dry_run: bool, force: bool, pinned_only: bool, tally: *Tally, sink: ?*EntrySink) !void {
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
        if (signals.isInterrupted()) break;
        upgradeCask(ctx, allocator, token, db, api, prefix, dry_run, force, pinned_only, tally, sink) catch {
            failed_count += 1;
            tally.failed += 1;
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

const color = @import("../ui/color.zig");

test "EntrySink.collectFormula qualifies installed with revision and routes by kind" {
    var sink = EntrySink.init(std.testing.allocator);
    defer sink.deinit();

    sink.collectFormula("foo", "1.2", 3, "1.3");
    sink.collectFormula("baz", "2.5", 0, "2.6");
    sink.collectCask("bar", "4.0", "4.1");

    try std.testing.expect(!sink.tainted);
    try std.testing.expectEqual(@as(usize, 2), sink.formulas.items.len);
    try std.testing.expectEqual(@as(usize, 1), sink.casks.items.len);
    // Revision-qualified installed is the load-bearing shape-parity invariant:
    // a bare `1.2` would make the warmed snapshot diverge from `mt outdated`.
    try std.testing.expectEqualStrings("foo", sink.formulas.items[0].name);
    try std.testing.expectEqualStrings("1.2_3", sink.formulas.items[0].installed);
    try std.testing.expectEqualStrings("1.3", sink.formulas.items[0].latest);
    // Revision 0 stays bare — `2.5`, never `2.5_0`.
    try std.testing.expectEqualStrings("2.5", sink.formulas.items[1].installed);
    try std.testing.expectEqualStrings("bar", sink.casks.items[0].name);
    try std.testing.expectEqualStrings("4.0", sink.casks.items[0].installed);
}

test "shouldWarmSnapshot warms only a clean full no-args dry-run" {
    try std.testing.expect(shouldWarmSnapshot(.{ .dry_run = true }));
    // A real upgrade never warms — the pre-upgrade set is stale once kegs mutate.
    try std.testing.expect(!shouldWarmSnapshot(.{ .dry_run = false }));
    // Any narrowing or incompleteness persists a partial snapshot → veto.
    try std.testing.expect(!shouldWarmSnapshot(.{ .dry_run = true, .has_names = true }));
    try std.testing.expect(!shouldWarmSnapshot(.{ .dry_run = true, .cask_only = true }));
    try std.testing.expect(!shouldWarmSnapshot(.{ .dry_run = true, .formula_only = true }));
    try std.testing.expect(!shouldWarmSnapshot(.{ .dry_run = true, .pinned_only = true }));
    try std.testing.expect(!shouldWarmSnapshot(.{ .dry_run = true, .walk_failed = true }));
    try std.testing.expect(!shouldWarmSnapshot(.{ .dry_run = true, .tainted = true }));
}

test "Tally.checked sums every outcome bucket" {
    const t: Tally = .{ .upgraded = 1, .would_upgrade = 2, .up_to_date = 45, .pinned = 1, .failed = 3 };
    try std.testing.expectEqual(@as(usize, 52), t.checked());
}

test "summaryLine renders a real run with no failures" {
    var buf: [128]u8 = undefined;
    const t: Tally = .{ .upgraded = 1, .up_to_date = 45, .pinned = 1 };
    try std.testing.expectEqualStrings(
        "47 checked · 1 upgraded · 45 up to date · 1 pinned",
        t.summaryLine(&buf, false),
    );
}

test "summaryLine swaps in 'would upgrade' under dry-run" {
    var buf: [128]u8 = undefined;
    const t: Tally = .{ .would_upgrade = 1, .up_to_date = 45, .pinned = 1 };
    try std.testing.expectEqualStrings(
        "47 checked · 1 would upgrade · 45 up to date · 1 pinned",
        t.summaryLine(&buf, true),
    );
}

test "summaryLine appends a failed clause only when something failed" {
    var buf: [128]u8 = undefined;
    const t: Tally = .{ .upgraded = 1, .up_to_date = 44, .pinned = 1, .failed = 1 };
    try std.testing.expectEqualStrings(
        "47 checked · 1 upgraded · 44 up to date · 1 pinned · 1 failed",
        t.summaryLine(&buf, false),
    );
}

test "summaryLine renders an all-failed run" {
    var buf: [128]u8 = undefined;
    const t: Tally = .{ .failed = 3 };
    try std.testing.expectEqualStrings(
        "3 checked · 0 upgraded · 0 up to date · 0 pinned · 3 failed",
        t.summaryLine(&buf, false),
    );
}

test "printSummary stays silent when nothing was checked" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const prior_quiet = output.isQuiet();
    output.setQuiet(false);
    output.beginStderrCapture(std.testing.allocator, &buf);
    defer {
        output.endStderrCapture();
        output.setQuiet(prior_quiet);
    }

    printSummary(.{}, false);
    try std.testing.expectEqualStrings("", buf.items);
}

test "printSummary emits one notice footer for a non-empty run" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const prior_quiet = output.isQuiet();
    color.setForTest(false, false);
    output.setQuiet(false);
    output.beginStderrCapture(std.testing.allocator, &buf);
    defer {
        output.endStderrCapture();
        color.setForTest(null, null);
        output.setQuiet(prior_quiet);
    }

    printSummary(.{ .upgraded = 1, .up_to_date = 45, .pinned = 1 }, false);
    try std.testing.expectEqualStrings("  i 47 checked · 1 upgraded · 45 up to date · 1 pinned\n", buf.items);
}

// `--quiet` predates this footer and stays the one knob that silences
// success/notice lines — the summary must vanish under it too.
test "printSummary respects --quiet" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const prior_quiet = output.isQuiet();
    output.setQuiet(true);
    output.beginStderrCapture(std.testing.allocator, &buf);
    defer {
        output.endStderrCapture();
        output.setQuiet(prior_quiet);
    }

    printSummary(.{ .upgraded = 1, .up_to_date = 2 }, false);
    try std.testing.expectEqualStrings("", buf.items);
}

// `upgradeDbAtomic` records the new keg and deletes the old one, whose
// `dependencies` rows go with it. Without re-recording the edges on the
// new keg id, the upgraded keg ends up with zero deps — and the next
// `cleanup` (which trusts the `dependencies` table) reaps a still-live
// runtime dependency as an orphan. Pin both halves: the surviving edge
// and `findOrphans` excluding the dep it points at.
test "upgradeDbAtomic re-records dependency edges so cleanup keeps live runtime deps" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    // direct keg (jq) → dependency keg (oniguruma), plus the edge.
    try db.exec(
        \\INSERT INTO kegs (id, name, full_name, version, store_sha256, cellar_path, install_reason)
        \\VALUES (1, 'jq', 'jq', '1.7', 'sha-jq-old', '/c/jq/1.7', 'direct'),
        \\       (2, 'oniguruma', 'oniguruma', '6.9', 'sha-onig', '/c/oniguruma/6.9', 'dependency');
    );
    try db.exec("INSERT INTO dependencies (keg_id, dep_name) VALUES (1, 'oniguruma');");

    // New jq formula (version bump) still declaring oniguruma as a dep.
    const json =
        \\{"name":"jq","full_name":"jq","tap":"homebrew/core","desc":"","homepage":"","license":null,"revision":0,"keg_only":false,"post_install_defined":false,"versions":{"stable":"1.7.1"},"dependencies":["oniguruma"]}
    ;
    var formula = try formula_mod.parseFormula(std.testing.allocator, json);
    defer formula.deinit();

    // link/unlink no-op against a non-existent prefix/cellar — this test
    // exercises the DB transaction, not the filesystem.
    var linker = linker_mod.Linker.init(std.Options.debug_io, std.testing.allocator, &db, "/nonexistent/malt-prefix");

    try db.beginTransaction();
    errdefer db.rollback();
    const new_keg_id = try upgradeDbAtomic(&db, &linker, 1, &formula, "sha-jq-new", "/nonexistent/Cellar/jq/1.7.1", false);
    try db.commit();

    // The edge must survive on the new keg id.
    {
        var stmt = try db.prepare(
            \\SELECT d.dep_name FROM dependencies d
            \\JOIN kegs k ON k.id = d.keg_id
            \\WHERE k.name = 'jq';
        );
        defer stmt.finalize();
        try std.testing.expect(try stmt.step());
        const dep = stmt.columnText(0) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("oniguruma", std.mem.sliceTo(dep, 0));
    }
    try std.testing.expect(new_keg_id != 1);

    // …so cleanup's orphan scan must not classify oniguruma as unused.
    const orphans = try deps_mod.findOrphans(std.testing.allocator, &db);
    defer {
        for (orphans) |o| std.testing.allocator.free(o);
        std.testing.allocator.free(orphans);
    }
    for (orphans) |o| {
        try std.testing.expect(!std.mem.eql(u8, o, "oniguruma"));
    }
}

// A stepped-open lookup statement pins connection A's WAL read snapshot.
// When the re-entrant dep install opens a second connection and advances the
// WAL, A can no longer promote its stale snapshot to a writer and gets an
// immediate SQLITE_BUSY (the busy handler is skipped for this self-deadlock)
// — the failure this bug produced. `readOldKeg` copies the row into owned
// storage and finalizes the statement first, so the parent stays writable.
test "readOldKeg releases the WAL read snapshot before a second connection advances the WAL" {
    const io = std.Options.debug_io;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var bb: [std.fs.max_path_bytes]u8 = undefined;
    const base = bb[0..try std.Io.Dir.realPath(tmp.dir, io, &bb)];
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&pbuf, "{s}/kegs.db", .{base});

    // Connection A stands in for the parent upgrade connection.
    var a = try sqlite.Database.open(path);
    defer a.close();
    try schema.initSchema(&a);
    try a.exec(
        \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, bin_isolated)
        \\VALUES ('foo', 'foo', '1.0', 0, 'sha-foo', '/c/foo/1.0', 1);
    );

    // Control: prove the mechanism. A stepped-open lookup pins A's snapshot;
    // a second connection committing a write then poisons A's own write.
    {
        var pin = try a.prepare("SELECT id FROM kegs WHERE name = ?1 LIMIT 1;");
        defer pin.finalize();
        try pin.bindText(1, "foo");
        try std.testing.expect(try pin.step()); // read snapshot now held open

        var b = try sqlite.Database.open(path);
        defer b.close();
        try b.exec("INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path) VALUES ('dep', 'dep', '1', 's', '/c');");

        try std.testing.expectError(sqlite.SqliteError.Busy, a.beginTransaction());
        a.rollback(); // BEGIN never took hold; keep A clean for the fix path
    }

    // Fix: readOldKeg copies the row and finalizes before the WAL advances.
    var old = (try readOldKeg(alloc, &a, "foo")).?;
    defer old.deinit(alloc);
    try std.testing.expectEqualStrings("1.0", old.version);
    try std.testing.expectEqualStrings("sha-foo", old.sha256);
    try std.testing.expect(old.bin_isolated);

    {
        var b = try sqlite.Database.open(path);
        defer b.close();
        try b.exec("INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path) VALUES ('dep2', 'dep2', '1', 's2', '/c2');");
    }

    // The parent's write must still succeed — no stale snapshot to promote.
    try a.beginTransaction();
    try a.exec("UPDATE kegs SET pinned = 1 WHERE name = 'foo';");
    try a.commit();
}

test "readOldKeg returns null when the formula is not installed" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try std.testing.expect((try readOldKeg(std.testing.allocator, &db, "absent")) == null);
}

test "readOldKeg surfaces an allocation failure instead of swallowing it" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path)
        \\VALUES ('foo', 'foo', '1.0', 'sha', '/c/foo/1.0');
    );
    // A dup that OOMs must propagate (the bulk caller maps it to a counted
    // failure) — not vanish as a silent success. fail_index 0 also proves the
    // errdefer chain frees nothing on the first failed dup.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, readOldKeg(failing.allocator(), &db, "foo"));
}

test "readOldKeg maps a NULL tap column to an owned empty string" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    // Core kegs carry a NULL tap; the owned copy must be a real, freeable "".
    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, tap)
        \\VALUES ('foo', 'foo', '1.0', 'sha', '/c/foo/1.0', NULL);
    );
    var old = (try readOldKeg(std.testing.allocator, &db, "foo")).?;
    defer old.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", old.tap);
    try std.testing.expect(install_args_mod.isCoreTap(old.tap));
}

test "upgradeAllFormulas stops between packages once interrupted" {
    const alloc = std.testing.allocator;
    const ctx = @import("../app_ctx.zig").debug_ctx;

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    // Two core kegs so the loop must iterate more than once; NULL tap keeps
    // them on the offline-failing homebrew/core fetch path.
    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, tap)
        \\VALUES ('aaa', 'aaa', '1.0', 's1', '/c/aaa/1.0', NULL),
        \\       ('bbb', 'bbb', '1.0', 's2', '/c/bbb/1.0', NULL);
    );

    // Offline so each fetch fails instantly from a cache miss — no network.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cbuf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_dir = cbuf[0..try std.Io.Dir.realPath(tmp.dir, ctx.io, &cbuf)];

    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, alloc);
    defer http.deinit();
    http.offline = true;
    var api = api_mod.BrewApi.init(ctx.io, alloc, &http, cache_dir);
    api.offline = true;

    // Fire on the 2nd interrupt poll: iteration 1 processes `aaa`, iteration 2
    // sees the flag and must break before touching `bbb`.
    const prior = signals.isInterrupted();
    defer signals.setInterruptedForTest(prior);
    signals.setInterruptedForTest(false);
    signals.armInterruptAfterForTest(2);
    defer signals.armInterruptAfterForTest(0);

    var tally: Tally = .{};
    upgradeAllFormulas(&ctx, alloc, &db, &api, &http, "/opt/malt", true, false, false, false, &.{}, &tally, null) catch {};

    // Only the first keg was attempted; the interrupt stopped the loop.
    try std.testing.expectEqual(@as(usize, 1), tally.checked());
}

test "upgradeAllFormulas processes nothing when interrupted before the loop" {
    const alloc = std.testing.allocator;
    const ctx = @import("../app_ctx.zig").debug_ctx;

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, tap)
        \\VALUES ('aaa', 'aaa', '1.0', 's1', '/c/aaa/1.0', NULL);
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cbuf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_dir = cbuf[0..try std.Io.Dir.realPath(tmp.dir, ctx.io, &cbuf)];
    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, alloc);
    defer http.deinit();
    http.offline = true;
    var api = api_mod.BrewApi.init(ctx.io, alloc, &http, cache_dir);
    api.offline = true;

    const prior = signals.isInterrupted();
    defer signals.setInterruptedForTest(prior);
    signals.setInterruptedForTest(true);

    var tally: Tally = .{};
    upgradeAllFormulas(&ctx, alloc, &db, &api, &http, "/opt/malt", true, false, false, false, &.{}, &tally, null) catch {};

    try std.testing.expectEqual(@as(usize, 0), tally.checked());
}

test "upgradeAllCasks stops between casks once interrupted" {
    const alloc = std.testing.allocator;
    const ctx = @import("../app_ctx.zig").debug_ctx;

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    // Two core casks (NULL tap) so the loop iterates and each falls to the
    // offline-failing core-API fetch path — no network, no registered taps.
    try db.exec(
        \\INSERT INTO casks (token, name, version, url) VALUES
        \\  ('aaa', 'aaa', '1.0', 'https://example/aaa'),
        \\  ('bbb', 'bbb', '1.0', 'https://example/bbb');
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cbuf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_dir = cbuf[0..try std.Io.Dir.realPath(tmp.dir, ctx.io, &cbuf)];
    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, alloc);
    defer http.deinit();
    http.offline = true;
    var api = api_mod.BrewApi.init(ctx.io, alloc, &http, cache_dir);
    api.offline = true;

    // Fire on the 2nd poll: cask `aaa` is attempted, `bbb` is skipped.
    const prior = signals.isInterrupted();
    defer signals.setInterruptedForTest(prior);
    signals.setInterruptedForTest(false);
    signals.armInterruptAfterForTest(2);
    defer signals.armInterruptAfterForTest(0);

    var tally: Tally = .{};
    upgradeAllCasks(&ctx, alloc, &db, &api, "/opt/malt", true, false, false, &tally, null) catch {};

    try std.testing.expectEqual(@as(usize, 1), tally.checked());
}
