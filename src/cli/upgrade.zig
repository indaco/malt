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
const audit_mod = @import("upgrade/audit.zig");
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

/// True when phase 1 may fold a row itself instead of handing it to phase 2.
/// Only rows phase 2 would have called `.up_to_date` qualify: a held row
/// reports `.pinned` and belongs in that footer column, so it falls through.
/// The pin arm mirrors `pinSkip` over the row's own `pinned` column, which
/// the audit already loaded — no per-row re-query.
fn phase1Folds(d: outdated_mod.Disposition, row: outdated_mod.KegRow, force: bool, audit_mode: bool) bool {
    if (pinnedHolds(row, force, audit_mode)) return false;
    return audit_mod.skips(d, force);
}

/// True when a pin holds this row back from phase 2. `--force` and the
/// `--pinned` audit walk pins deliberately, so they clear it. The plan warm
/// mirrors this: a held row never reaches the sink in phase 2.
fn pinnedHolds(row: outdated_mod.KegRow, force: bool, audit_mode: bool) bool {
    return row.pinned and !force and !audit_mode;
}

/// What a per-package upgrade decided. Returned rather than reported as a
/// side effect, so a caller can fold it into a counter, a progress line, or
/// a cache prune without the upgrade functions knowing which. Failures stay
/// on the error channel — `error.Aborted` / `error.AppRunning` — so the
/// exit-code split survives untouched.
const Outcome = enum { upgraded, would_upgrade, up_to_date, pinned };

/// Aggregate counters for a bulk `mt upgrade` run, folded from the
/// per-package `Outcome`s. Whether to *print* per-package lines is a
/// separate `bulk` flag: a bulk run suppresses the "already current" line
/// so a mostly-current machine summarises instead of narrating every row,
/// while the named path keeps its lines and folds nothing.
const Tally = struct {
    upgraded: usize = 0,
    would_upgrade: usize = 0,
    up_to_date: usize = 0,
    pinned: usize = 0,
    failed: usize = 0,

    /// Fold one package's outcome into the run's counters — the single
    /// place an `Outcome` becomes a number. Failures never reach here:
    /// they stay on the error channel and the loops count them directly.
    fn fold(self: *Tally, o: Outcome) void {
        switch (o) {
            .upgraded => self.upgraded += 1,
            .would_upgrade => self.would_upgrade += 1,
            .up_to_date => self.up_to_date += 1,
            .pinned => self.pinned += 1,
        }
    }

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

/// The one-line heads-up `upgrade` prints on a backward move, else null.
/// Advisory, not a consent gate: it takes no `force`, so a reader cannot
/// turn it into a refusal. `incomparable` stays silent — a guessed
/// direction would cry wolf on every unusual version string.
fn downgradeWarning(buf: []u8, name: []const u8, installed: []const u8, upstream: []const u8) ?[]const u8 {
    if (formula_mod.relate(installed, upstream) != .older) return null;
    // Bounded inputs (a keg name and two version labels); on the impossible
    // overflow, drop the advisory rather than fail an upgrade over a heads-up.
    return std.fmt.bufPrint(buf, "{s} is moving backward: {s} -> {s} (undo with `mt rollback {s}`)", .{ name, installed, upstream, name }) catch null;
}

/// Print the backward-move heads-up at a compare site when the move is
/// backward. Not gated on `bulk`: the rare backward move is the exception
/// bulk quieting should not swallow. Advisory — the caller upgrades anyway.
fn warnIfBackward(name: []const u8, installed: []const u8, upstream: []const u8) void {
    // ponytail: may fire on a date-scheme forward move (both sides open with
    // digits); accepted, not fixed here — see relate's pinned limitation.
    var buf: [256]u8 = undefined;
    if (downgradeWarning(&buf, name, installed, upstream)) |w| output.warn("{s}", .{w});
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

/// Inputs to the snapshot-warm decision. `full_keg` already encodes
/// "unnarrowed" — a `--cask`/`--formula`/`--pinned` or named run clears it —
/// so the gate reads the plan, not the flags.
const WarmGate = struct {
    dry_run: bool = false,
    full_keg: bool = false,
    walk_failed: bool = false,
    tainted: bool = false,
};

/// Warm only a complete, clean dry-run. A failed walk or a tainted collector
/// veto, since either would persist a partial, under-reporting snapshot. A
/// real upgrade never warms; it prunes instead (`pruneSnapshot`), the
/// pre-upgrade set being stale the instant kegs mutate.
fn warmsSnapshot(g: WarmGate) bool {
    return g.dry_run and g.full_keg and !g.walk_failed and !g.tainted;
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
    var any_upgraded = false; // at least one keg actually moved — gates the prune

    if (names.items.len == 0) {
        // Upgrade all. Both passes fold their per-package outcomes into one
        // `Tally` and run in bulk mode, so per-package "already current"
        // lines give way to the single summary footer printed below.
        var tally: Tally = .{};
        // Collect the would-upgrade rows only when a warm could actually
        // fire: a full, unnarrowed dry-run. The sink threads down both
        // passes alongside `tally`; a real upgrade or any narrowing passes
        // `null` so nothing is gathered.
        var sink: EntrySink = .init(allocator);
        defer sink.deinit();

        // Phase 1: ask upstream about every installed row in one request
        // instead of one blocking round trip per package. A row the index
        // proves current is folded below without ever reaching phase 2;
        // everything else falls through to today's exact per-package path.
        const scope: audit_mod.Scope = .{
            .cask_only = cask_only,
            .formula_only = formula_only,
            .pinned_only = pinned_only,
        };
        // An audit that cannot even read its rows leaves nothing to upgrade —
        // the same outcome as the SQL failure this replaced.
        var f_plan: audit_mod.Plan = if (cask_only) .empty else audit_mod.audit(allocator, &db, &api, .formula, scope) catch .empty;
        defer f_plan.deinit(allocator);
        var c_plan: audit_mod.Plan = if (formula_only) .empty else audit_mod.audit(allocator, &db, &api, .cask, scope) catch .empty;
        defer c_plan.deinit(allocator);

        const checking = f_plan.rows.len + c_plan.rows.len;
        if (checking > 0) output.info("Checking {d} packages...", .{checking});

        // The warm gate reads the plan rather than the flags: a narrowed
        // audit must never persist a snapshot of the rows it did look at.
        // Both plans carry the same verdict; `or` picks the live one when a
        // narrowing or a failed audit left the other empty.
        const full_keg = f_plan.full_keg or c_plan.full_keg;
        const sink_ptr: ?*EntrySink = if (dry_run and full_keg) &sink else null;
        if (!cask_only) {
            upgradeAllFormulas(ctx, allocator, &db, &api, &http, prefix, dry_run, force, pinned_only, isolate_deps, use_system_ruby_scope.items, f_plan, &tally, sink_ptr) catch {
                any_failed = true;
            };
        }
        if (!formula_only) {
            upgradeAllCasks(ctx, allocator, &db, &api, prefix, dry_run, force, pinned_only, c_plan, &tally, sink_ptr) catch {
                any_failed = true;
            };
        }
        printSummary(tally, dry_run);
        any_upgraded = tally.upgraded > 0;

        // Best-effort warm of the shared outdated snapshot from the dry-run's
        // own audit — a cache-write failure never changes exit code or output.
        // Reuses the `{prefix}/cache` dir already resolved above.
        if (warmsSnapshot(.{ .dry_run = dry_run, .full_keg = full_keg, .walk_failed = any_failed, .tainted = sink.tainted })) {
            outdated_mod.writeSnapshotEntries(ctx, allocator, cache_dir, sink.formulas.items, sink.casks.items) catch {};
        }
    } else {
        // Upgrade each named package — formula first, then cask. A failed
        // or aborted name aggregates into `any_failed` and the loop moves
        // on, so one bad name never abandons the rest of the batch. Not a
        // bulk run, so each named package keeps its per-package line and
        // there is no footer; the outcome itself is nothing to fold here.
        for (names.items) |name| {
            if (!cask_only and isFormulaInstalled(&db, name)) {
                const outcome = upgradeFormula(ctx, allocator, name, &db, &api, &http, prefix, dry_run, force, pinned_only, isolate_deps, use_system_ruby_scope.items, false, null) catch {
                    any_failed = true;
                    other_failed = true;
                    continue;
                };
                if (outcome == .upgraded) any_upgraded = true;
                continue;
            }
            // Not a formula (or --cask): try cask
            const outcome = upgradeCask(ctx, allocator, name, &db, &api, prefix, dry_run, force, pinned_only, false, null) catch |e| {
                any_failed = true;
                if (e == error.AppRunning) app_running = true else other_failed = true;
                continue;
            };
            if (outcome == .upgraded) any_upgraded = true;
        }
    }

    // Only a run that actually moved a keg has anything to reconcile: the
    // snapshot now lists packages at versions they no longer carry. A run that
    // upgraded nothing — every package current, all pinned, all failed — must
    // leave the file alone, or `mt upgrade` would rewrite a cache it did not
    // invalidate. One call covers both branches above, the named path
    // included. Best-effort: a cache write never fails an upgrade that already
    // succeeded.
    //
    // No `!dry_run` needed: every path returns `.would_upgrade` from behind its
    // dry-run guard and never reaches `.upgraded`, so a dry-run cannot set this.
    if (any_upgraded) outdated_mod.pruneSnapshot(ctx.io, allocator, &db, cache_dir);

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
    bulk: bool,
    sink: ?*EntrySink,
) !Outcome {
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
        return .pinned;
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
        return upgradeTapFormula(ctx, allocator, name, old.tap, old.version, old.revision, db, prefix, dry_run, force, audit_mode, bulk, sink);
    }

    // Reconstruct the revision-aware path label for the old keg so
    // cellar_mod.remove / linker calls target the actual on-disk dir. It is
    // also what the skip compare and the upgrade lines below must use: both
    // sides have to be qualified or a revision move renders inverted.
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

    // Compare versions through the shared currency policy. On the bulk path the
    // "already current" line is suppressed — the footer tallies it instead — but
    // the NDJSON event is always emitted so the machine stream is unchanged.
    if (formula_mod.isCurrent(old.version, old.revision, formula.pkg_version) == .current) {
        if (!bulk) output.skip("{s} is already at latest version {s}", .{ name, formula.pkg_version });
        output.emitNdjsonEvent(.up_to_date, name, null);
        return .up_to_date;
    }

    warnIfBackward(name, old_pkg_version, formula.pkg_version);

    if (dry_run) {
        if (sink) |s| s.collectFormula(name, old.version, old.revision, formula.pkg_version);
        output.info("Dry run: would upgrade {s} {s} -> {s}", .{ name, old_pkg_version, formula.pkg_version });
        // Same vocabulary across install/upgrade/migrate — one parser fits all.
        output.emitNdjsonEvent(.would_install, name, null);
        return .would_upgrade;
    }

    output.info("Upgrading {s} {s} -> {s}...", .{ name, old_pkg_version, formula.pkg_version });
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
    return .upgraded;
}

/// How a dry-run tap formula feeds the snapshot warm. `taint` degrades the
/// whole run to a full recompute (never a partial warm); `skip` is a sha-only
/// move the tap `.rb` proves current; `collect` is a genuine would-upgrade row.
const TapWarmDecision = enum { collect, skip, taint };

/// Equality — not ordering — is the definition of outdated; the normative
/// statement lives in `src/cli/outdated/refresh.zig` and is not restated here.
///
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
    bulk: bool,
    sink: ?*EntrySink,
) !Outcome {
    if (pinSkip(db, name, force, audit_mode)) {
        output.skip("{s} is pinned, skipped", .{name});
        output.emitNdjsonEvent(.pinned, name, null);
        return .pinned;
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

    // Third policy, deliberately not the version policy: a tap formula upgrades
    // on tap content, so a `.rb` edit with no version bump still reinstalls.
    // Stated to users in `upgrade_help` (`src/cli/help.zig`); the version rule it
    // differs from is the note in `src/cli/outdated/refresh.zig`.
    if (!force and same_commit) {
        if (!bulk) output.skip("{s} is already at latest tap commit", .{name});
        output.emitNdjsonEvent(.up_to_date, name, null);
        return .up_to_date;
    }

    if (dry_run) {
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
        return .would_upgrade;
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
    return .upgraded;
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
    bulk: bool,
    sink: ?*EntrySink,
) TapRouteError!Outcome {
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
        if (!bulk) output.skip("{s} is already at latest version {s}", .{ token, rb_info.version });
        output.emitNdjsonEvent(.up_to_date, token, null);
        return .up_to_date;
    }

    warnIfBackward(token, installed_version, rb_info.version);

    if (dry_run) {
        // Bare, like the skip decision above: this warms the snapshot that
        // `outdated` reads, and a cask's installed version can never carry a
        // revision to match a qualified one against.
        if (sink) |s| s.collectCask(token, installed_version, rb_info.version);
        output.info("Dry run: would upgrade cask {s} {s} -> {s}", .{ token, installed_version, rb_info.version });
        output.emitNdjsonEvent(.would_install, token, null);
        return .would_upgrade;
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
    return .upgraded;
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
    bulk: bool,
    sink: ?*EntrySink,
) error{AppRunning}!?Outcome {
    const taps = tap_mod.list(allocator, db) catch return null;
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

        const outcome = upgradeRoutedTapCask(ctx, allocator, token, t.name, installed_version, db, prefix, dry_run, force, bulk, sink) catch |e| switch (e) {
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
        return outcome;
    }

    return null;
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
    plan: audit_mod.Plan,
    tally: *Tally,
    sink: ?*EntrySink,
) !void {
    if (plan.rows.len == 0) {
        // Quiet on the audit path: "no pinned kegs" is the normal idle state.
        if (!pinned_only) output.info("No formulas installed.", .{});
        return;
    }

    // Count separately from the name list so an OOM on the names append
    // cannot hide a failure from the summary/exit-code contract.
    var failed_count: usize = 0;
    var failed_names: std.ArrayList([]const u8) = .empty;
    defer failed_names.deinit(allocator);

    for (plan.rows, plan.dispositions) |row, d| {
        // Stop between packages on Ctrl-C; the in-flight fetch is torn down by
        // http.cancel, this keeps us from starting the next one.
        if (signals.isInterrupted()) break;
        if (phase1Folds(d, row, force, pinned_only)) {
            // Fold, never drop: the footer counts every package. The event
            // still streams so the machine-readable output is unchanged.
            output.emitNdjsonEvent(.up_to_date, row.name, null);
            tally.fold(.up_to_date);
            continue;
        }
        // `upgradeFormula` fetches every `needs_upgrade` row anyway (it needs the
        // full formula for the bottle), so let its own dry-run collect, keyed on
        // the fetched version, be the sole snapshot writer. Pre-seeding from the
        // index bought no fetch and only leaked the index target when the two
        // caches skewed inside their shared TTL.
        if (upgradeFormula(ctx, allocator, row.name, db, api, http, prefix, dry_run, force, pinned_only, isolate_deps, use_system_ruby, true, sink)) |o| {
            tally.fold(o);
        } else |_| {
            failed_count += 1;
            tally.failed += 1;
            // failed_count is the authoritative counter; list is for UX only.
            failed_names.append(allocator, row.name) catch {};
        }
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

fn upgradeCask(ctx: *const AppCtx, allocator: std.mem.Allocator, token: []const u8, db: *sqlite.Database, api: *api_mod.BrewApi, prefix: [:0]const u8, dry_run: bool, force: bool, audit_mode: bool, bulk: bool, sink: ?*EntrySink) !Outcome {
    if (pinSkip(db, token, force, audit_mode)) {
        output.skip("{s} is pinned, skipped", .{token});
        output.emitNdjsonEvent(.pinned, token, null);
        return .pinned;
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
            return upgradeRoutedTapCask(ctx, allocator, token, tap_label, installed.version(), db, prefix, dry_run, force, bulk, sink) catch |e| switch (e) {
                error.NotInTap => {
                    output.err("Cask {s} is no longer in tap {s}", .{ token, tap_label });
                    return error.Aborted;
                },
                error.AppRunning => return error.AppRunning, // already explained; keep the distinct code
                error.Aborted => return error.Aborted,
            };
        }
    }

    // Fetch latest version. Casks have no `tap` column populated on
    // legacy installs, so we still fall back to probing every registered
    // third-party tap if the core API 404s — the probe also backfills
    // `casks.tap` for the next invocation.
    const cask_json = api.fetchCask(token) catch {
        if (try upgradeTapCaskFallback(ctx, allocator, token, installed.version(), db, prefix, dry_run, force, bulk, sink)) |o| return o;
        output.err("Could not fetch cask info for {s}", .{token});
        return error.Aborted;
    };
    defer allocator.free(cask_json);

    var parsed_cask = cask_mod.parseCask(allocator, cask_json) catch {
        output.err("Failed to parse cask JSON for {s}", .{token});
        return error.Aborted;
    };
    defer parsed_cask.deinit();

    // Bare on both sides, and correct only because a cask carries no revision
    // anywhere — the formula leg has to qualify both sides to obey the same
    // policy (see `src/cli/outdated/refresh.zig`). Should a cask ever gain a
    // revision, this compare and the prints below go wrong together.
    const installed_version = installed.version();
    if (formula_mod.isCurrent(installed_version, 0, parsed_cask.version) == .current) {
        if (!bulk) output.skip("{s} is already at latest version {s}", .{ token, parsed_cask.version });
        output.emitNdjsonEvent(.up_to_date, token, null);
        return .up_to_date;
    }

    warnIfBackward(token, installed_version, parsed_cask.version);

    if (dry_run) {
        if (sink) |s| s.collectCask(token, installed_version, parsed_cask.version);
        output.info("Dry run: would upgrade cask {s} {s} -> {s}", .{ token, installed_version, parsed_cask.version });
        output.emitNdjsonEvent(.would_install, token, null);
        return .would_upgrade;
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
    return .upgraded;
}

fn upgradeAllCasks(ctx: *const AppCtx, allocator: std.mem.Allocator, db: *sqlite.Database, api: *api_mod.BrewApi, prefix: [:0]const u8, dry_run: bool, force: bool, pinned_only: bool, plan: audit_mod.Plan, tally: *Tally, sink: ?*EntrySink) !void {
    if (plan.rows.len == 0) {
        // Quiet on the audit path: "no pinned casks" is the normal idle state.
        if (!pinned_only) output.info("All casks are up to date.", .{});
        return;
    }

    var failed_count: usize = 0;
    var failed_tokens: std.ArrayList([]const u8) = .empty;
    defer failed_tokens.deinit(allocator);

    for (plan.rows, plan.dispositions) |row, d| {
        if (signals.isInterrupted()) break;
        if (phase1Folds(d, row, force, pinned_only)) {
            output.emitNdjsonEvent(.up_to_date, row.name, null);
            tally.fold(.up_to_date);
            continue;
        }
        // Symmetric with the formula walk: `upgradeCask` fetches the cask
        // document to install it, so its own dry-run collect (keyed on the
        // fetched version) is the sole snapshot writer, with no index pre-seed
        // to skew.
        if (upgradeCask(ctx, allocator, row.name, db, api, prefix, dry_run, force, pinned_only, true, sink)) |o| {
            tally.fold(o);
        } else |_| {
            failed_count += 1;
            tally.failed += 1;
            // failed_count is authoritative; list is for UX only.
            failed_tokens.append(allocator, row.name) catch {};
        }
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

const fs_test_io = std.Options.debug_io;

var scratch_seq: std.atomic.Value(u32) = .init(0);

/// Stands in for `std.testing.tmpDir`, which builds under `.zig-cache` — a
/// tree the build system owns and rewrites underneath a concurrent test run.
/// The base is process- and call-unique so overlapping runs sharing /tmp
/// cannot delete each other's fixtures.
const Scratch = struct {
    arena: std.heap.ArenaAllocator,
    base: [:0]const u8,
    dir: std.Io.Dir,

    fn init(comptime tag: []const u8) !Scratch {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const raw = try std.fmt.allocPrintSentinel(
            arena.allocator(),
            "/tmp/malt_" ++ tag ++ "_{d}_{d}",
            .{ std.c.getpid(), scratch_seq.fetchAdd(1, .monotonic) },
            0,
        );
        std.Io.Dir.cwd().deleteTree(fs_test_io, raw) catch {};
        try std.Io.Dir.cwd().createDirPath(fs_test_io, raw);
        // /tmp is a symlink to /private/tmp on macOS; resolve once so paths
        // the code under test returns compare equal to `base`.
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        var d = try std.Io.Dir.cwd().openDir(fs_test_io, raw, .{});
        errdefer d.close(fs_test_io);
        const n = try std.Io.Dir.realPath(d, fs_test_io, &buf);
        const base = try arena.allocator().dupeZ(u8, buf[0..n]);
        return .{ .arena = arena, .base = base, .dir = d };
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
        self.dir.close(fs_test_io);
        std.Io.Dir.cwd().deleteTree(fs_test_io, self.base) catch {};
        self.arena.deinit();
    }
};

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

test "warmsSnapshot warms only a clean, unnarrowed dry-run" {
    // The gate reads the plan's `full_keg` instead of re-deriving narrowing
    // from flags: a `--cask`/`--formula`/`--pinned` run clears `full_keg`
    // (proven in audit's own tests), and a cleared plan can never warm.
    try std.testing.expect(warmsSnapshot(.{ .dry_run = true, .full_keg = true }));
    // A real upgrade never warms — the pre-upgrade set is stale once kegs mutate.
    try std.testing.expect(!warmsSnapshot(.{ .full_keg = true }));
    // A narrowed audit (full_keg cleared) would persist a partial snapshot.
    try std.testing.expect(!warmsSnapshot(.{ .dry_run = true }));
    // A failed walk or a tainted collector each veto the write.
    try std.testing.expect(!warmsSnapshot(.{ .dry_run = true, .full_keg = true, .walk_failed = true }));
    try std.testing.expect(!warmsSnapshot(.{ .dry_run = true, .full_keg = true, .tainted = true }));
}

test "each narrowing clears full_keg so the plan warm is refused" {
    // The live temptation: the audit is natively narrowable, so a `--pinned`,
    // `--cask` or `--formula` plan must never license a snapshot warm. Ties
    // scope → full_keg → gate end to end, per the ordering constraint.
    const alloc = std.testing.allocator;
    const ctx = @import("../app_ctx.zig").debug_ctx;

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try db.exec("INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, pinned) VALUES ('held', 'held', '1.0', 'sha', '/cellar/held/1.0', 1);");

    var s = try Scratch.init("narrow_clears_full_keg");
    defer s.deinit();
    const cache_dir = s.base;
    try writeTestVersionsIndex(cache_dir, .formula, "held\t2.0\t0\n");

    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, alloc);
    defer http.deinit();
    var api = api_mod.BrewApi.init(ctx.io, alloc, &http, cache_dir);

    for ([_]audit_mod.Scope{
        .{ .pinned_only = true },
        .{ .cask_only = true },
        .{ .formula_only = true },
    }) |scope| {
        var plan = try audit_mod.audit(alloc, &db, &api, .formula, scope);
        defer plan.deinit(alloc);
        try std.testing.expect(!plan.full_keg);
        try std.testing.expect(!warmsSnapshot(.{ .dry_run = true, .full_keg = plan.full_keg }));
    }
}

test "Tally.fold routes each outcome to its own counter" {
    // The fold is the one place an Outcome becomes a number; a variant landing
    // in the wrong bucket would misreport the footer for a whole run.
    var t: Tally = .{};
    t.fold(.upgraded);
    t.fold(.upgraded);
    t.fold(.would_upgrade);
    t.fold(.up_to_date);
    t.fold(.pinned);
    try std.testing.expectEqual(@as(usize, 2), t.upgraded);
    try std.testing.expectEqual(@as(usize, 1), t.would_upgrade);
    try std.testing.expectEqual(@as(usize, 1), t.up_to_date);
    try std.testing.expectEqual(@as(usize, 1), t.pinned);
    try std.testing.expectEqual(@as(usize, 0), t.failed);
    try std.testing.expectEqual(@as(usize, 5), t.checked());
}

test "Tally.fold never invents a failure — that stays on the error channel" {
    // There is deliberately no `.failed` outcome: a failed upgrade returns an
    // error, which is what keeps error.AppRunning distinct from error.Aborted
    // for the exit code. Only the loops count failures, from the error arm.
    var t: Tally = .{};
    inline for (.{ .upgraded, .would_upgrade, .up_to_date, .pinned }) |o| t.fold(o);
    try std.testing.expectEqual(@as(usize, 0), t.failed);

    // A run that folds successes *and* catches a failure still summarises both.
    t.failed += 1;
    var buf: [160]u8 = undefined;
    try std.testing.expectEqualStrings(
        "5 checked · 1 upgraded · 1 up to date · 1 pinned · 1 failed",
        t.summaryLine(&buf, false),
    );
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

test "downgradeWarning speaks up on a backward move and stays silent otherwise" {
    var buf: [256]u8 = undefined;

    // A backward move: the whole point of the warning. Must name both
    // versions and point at the undo so the line stands on its own.
    const w = downgradeWarning(&buf, "tree", "2.2.1", "2.2.0") orelse
        return error.ExpectedWarning;
    try std.testing.expect(std.mem.indexOf(u8, w, "2.2.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, "2.2.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, "rollback") != null);

    // The ordinary forward path runs on every upgrade of every package;
    // one stray line here is a daily regression for everyone.
    try std.testing.expect(downgradeWarning(&buf, "tree", "2.2.0", "2.2.1") == null);
    // Equal versions never reach here in practice, but must not warn.
    try std.testing.expect(downgradeWarning(&buf, "tree", "2.2.1", "2.2.1") == null);
    // The give-up arm is what makes this safe for casks and odd taps.
    try std.testing.expect(downgradeWarning(&buf, "tree", "1.0rc2", "1.0") == null);
    // A revision-only rewind is still a backward move: the qualified label
    // matches what upgrade compares, so it must warn and name that label.
    const rev = downgradeWarning(&buf, "tree", "1.2.3_2", "1.2.3_1") orelse
        return error.ExpectedWarning;
    try std.testing.expect(std.mem.indexOf(u8, rev, "1.2.3_2") != null);
    try std.testing.expect(std.mem.indexOf(u8, rev, "1.2.3_1") != null);
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
    const alloc = std.testing.allocator;

    var s = try Scratch.init("read_old_keg_wal");
    defer s.deinit();
    const path = s.p("/kegs.db");

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
    var s = try Scratch.init("formulas_interrupt_between");
    defer s.deinit();
    const cache_dir = s.base;

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
    var plan = try audit_mod.audit(alloc, &db, &api, .formula, .{});
    defer plan.deinit(alloc);
    upgradeAllFormulas(&ctx, alloc, &db, &api, &http, "/opt/malt", true, false, false, false, &.{}, plan, &tally, null) catch {};

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

    var s = try Scratch.init("formulas_interrupt_before");
    defer s.deinit();
    const cache_dir = s.base;
    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, alloc);
    defer http.deinit();
    http.offline = true;
    var api = api_mod.BrewApi.init(ctx.io, alloc, &http, cache_dir);
    api.offline = true;

    const prior = signals.isInterrupted();
    defer signals.setInterruptedForTest(prior);
    signals.setInterruptedForTest(true);

    var tally: Tally = .{};
    var plan = try audit_mod.audit(alloc, &db, &api, .formula, .{});
    defer plan.deinit(alloc);
    upgradeAllFormulas(&ctx, alloc, &db, &api, &http, "/opt/malt", true, false, false, false, &.{}, plan, &tally, null) catch {};

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

    var s = try Scratch.init("casks_interrupt_between");
    defer s.deinit();
    const cache_dir = s.base;
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
    var plan = try audit_mod.audit(alloc, &db, &api, .cask, .{});
    defer plan.deinit(alloc);
    upgradeAllCasks(&ctx, alloc, &db, &api, "/opt/malt", true, false, false, plan, &tally, null) catch {};

    try std.testing.expectEqual(@as(usize, 1), tally.checked());
}

test "phase 1 folds a proven-current row itself" {
    const row: outdated_mod.KegRow = .{ .name = "alpha", .version = "1.0" };
    try std.testing.expect(phase1Folds(.proven_current, row, false, false));
}

test "phase 1 leaves a pinned row to phase 2 so it reports as pinned, not up to date" {
    // The footer counts `pinned` and `up to date` in separate columns, and
    // `upgradeFormula` reports a held row as `.pinned` before it looks at any
    // version. Folding it here would move it to the wrong column.
    const row: outdated_mod.KegRow = .{ .name = "alpha", .version = "1.0", .pinned = true };
    try std.testing.expect(!phase1Folds(.proven_current, row, false, false));
}

test "phase 1 folds a pinned row under --pinned, which walks pins deliberately" {
    // `--pinned` is the audit mode that exists to walk held kegs, so the pin
    // no longer diverts the outcome and phase 2 would report `.up_to_date`.
    const row: outdated_mod.KegRow = .{ .name = "alpha", .version = "1.0", .pinned = true };
    try std.testing.expect(phase1Folds(.proven_current, row, false, true));
}

test "phase 1 folds nothing under --force" {
    const plain: outdated_mod.KegRow = .{ .name = "alpha", .version = "1.0" };
    const held: outdated_mod.KegRow = .{ .name = "beta", .version = "1.0", .pinned = true };
    try std.testing.expect(!phase1Folds(.proven_current, plain, true, false));
    try std.testing.expect(!phase1Folds(.proven_current, held, true, false));
}

test "phase 1 never folds an unproven row" {
    var latest = [_]u8{ '9', '.', '9' };
    const row: outdated_mod.KegRow = .{ .name = "alpha", .version = "1.0" };
    for ([_]bool{ false, true }) |audit_mode| {
        try std.testing.expect(!phase1Folds(.unknown, row, false, audit_mode));
        try std.testing.expect(!phase1Folds(.{ .needs_upgrade = &latest }, row, false, audit_mode));
    }
}

/// Plant the version side-car the audit reads, so these tests resolve from
/// disk. `http.offline` stays on: nothing here may reach the network.
fn writeTestVersionsIndex(cache_dir: []const u8, kind: audit_mod.Kind, body: []const u8) !void {
    const io = std.Options.debug_io;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}/api", .{cache_dir});
    std.Io.Dir.createDirAbsolute(io, dir, .default_dir) catch {};
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = try std.fmt.bufPrint(&path_buf, "{s}/api/versions_{s}.txt", .{ cache_dir, @tagName(kind) });
    const f = try std.Io.Dir.cwd().createFile(io, p, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, body);
}

/// Plant the cached formula document phase 2 reads, so an `unknown` row can
/// resolve to a would-upgrade offline of any network. `parseFormula` needs
/// only name + `versions.stable`.
fn writeTestFormulaCache(cache_dir: []const u8, name: []const u8, stable: []const u8) !void {
    const io = std.Options.debug_io;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}/api", .{cache_dir});
    std.Io.Dir.createDirAbsolute(io, dir, .default_dir) catch {};
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = try std.fmt.bufPrint(&path_buf, "{s}/api/formula_{s}.json", .{ cache_dir, name });
    const f = try std.Io.Dir.cwd().createFile(io, p, .{});
    defer f.close(io);
    var body_buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "{{\"name\":\"{s}\",\"versions\":{{\"stable\":\"{s}\"}}}}", .{ name, stable });
    try f.writeStreamingAll(io, body);
}

/// Cask sibling of `writeTestFormulaCache`; `parseCask` needs token, version
/// and url, so phase 2 can resolve a would-upgrade cask offline of the network.
fn writeTestCaskCache(cache_dir: []const u8, token: []const u8, version: []const u8) !void {
    const io = std.Options.debug_io;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}/api", .{cache_dir});
    std.Io.Dir.createDirAbsolute(io, dir, .default_dir) catch {};
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = try std.fmt.bufPrint(&path_buf, "{s}/api/cask_{s}.json", .{ cache_dir, token });
    const f = try std.Io.Dir.cwd().createFile(io, p, .{});
    defer f.close(io);
    var body_buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "{{\"token\":\"{s}\",\"version\":\"{s}\",\"url\":\"https://example.com/x.dmg\"}}", .{ token, version });
    try f.writeStreamingAll(io, body);
}

test "the warmed formula set collects each fetched row once, freed once" {
    // The per-package fetch is the sole snapshot writer: a `needs_upgrade` row
    // and an `unknown` row the index never listed both land from the fetch,
    // while a `proven_current` row is excluded before the fetch runs. The result
    // must be exactly the two would-upgrade rows, each once, and the test
    // allocator proves it all frees once.
    const alloc = std.testing.allocator;
    const ctx = @import("../app_ctx.zig").debug_ctx;

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path) VALUES
        \\  ('cur', 'cur', '5.0', 'sha', '/cellar/cur/5.0'),
        \\  ('miss', 'miss', '1.0', 'sha', '/cellar/miss/1.0'),
        \\  ('up', 'up', '1.0', 'sha', '/cellar/up/1.0');
    );

    var s = try Scratch.init("warm_formula_merge");
    defer s.deinit();
    const cache_dir = s.base;
    // Index lists `cur` (current) and `up` (behind); `miss` is absent.
    try writeTestVersionsIndex(cache_dir, .formula, "cur\t5.0\t0\nup\t2.0\t0\n");
    // The fetch runs for every non-current row: `miss` and `up`.
    try writeTestFormulaCache(cache_dir, "miss", "3.0");
    try writeTestFormulaCache(cache_dir, "up", "2.0");

    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, alloc);
    defer http.deinit();
    var api = api_mod.BrewApi.init(ctx.io, alloc, &http, cache_dir);

    var plan = try audit_mod.audit(alloc, &db, &api, .formula, .{});
    defer plan.deinit(alloc);
    try std.testing.expect(plan.dispositions[0] == .proven_current); // cur
    try std.testing.expect(plan.dispositions[1] == .unknown); // miss
    try std.testing.expectEqualStrings("2.0", plan.dispositions[2].needs_upgrade); // up

    var sink = EntrySink.init(alloc);
    defer sink.deinit();
    var tally: Tally = .{};
    try upgradeAllFormulas(&ctx, alloc, &db, &api, &http, "/opt/malt", true, false, false, false, &.{}, plan, &tally, &sink);

    // Exactly the two would-upgrade rows: `miss` then `up`, in row order, each
    // present once from the fetch. `cur` contributes nothing.
    try std.testing.expectEqual(@as(usize, 2), sink.formulas.items.len);
    try std.testing.expectEqualStrings("miss", sink.formulas.items[0].name);
    try std.testing.expectEqualStrings("3.0", sink.formulas.items[0].latest);
    try std.testing.expectEqualStrings("up", sink.formulas.items[1].name);
    try std.testing.expectEqualStrings("2.0", sink.formulas.items[1].latest);
    try std.testing.expect(!sink.tainted);
    try std.testing.expectEqual(@as(usize, 1), tally.up_to_date); // cur
    try std.testing.expectEqual(@as(usize, 2), tally.would_upgrade); // miss + up
}

test "the warmed cask set collects each fetched row once, freed once" {
    // The cask walker is separate code from the formula one, so its half is
    // proven independently: `up` (index-behind) and `miss` (index-absent) both
    // land once from the fetch; `cur` (proven current) contributes nothing.
    const alloc = std.testing.allocator;
    const ctx = @import("../app_ctx.zig").debug_ctx;

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try db.exec(
        \\INSERT INTO casks (token, name, version, url) VALUES
        \\  ('cur', 'cur', '5.0', 'https://example/cur'),
        \\  ('miss', 'miss', '1.0', 'https://example/miss'),
        \\  ('up', 'up', '1.0', 'https://example/up');
    );

    var s = try Scratch.init("warm_cask_merge");
    defer s.deinit();
    const cache_dir = s.base;
    try writeTestVersionsIndex(cache_dir, .cask, "cur\t5.0\t0\nup\t2.0\t0\n");
    try writeTestCaskCache(cache_dir, "miss", "3.0");
    try writeTestCaskCache(cache_dir, "up", "2.0");

    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, alloc);
    defer http.deinit();
    var api = api_mod.BrewApi.init(ctx.io, alloc, &http, cache_dir);

    var plan = try audit_mod.audit(alloc, &db, &api, .cask, .{});
    defer plan.deinit(alloc);
    try std.testing.expect(plan.dispositions[0] == .proven_current); // cur
    try std.testing.expect(plan.dispositions[1] == .unknown); // miss
    try std.testing.expectEqualStrings("2.0", plan.dispositions[2].needs_upgrade); // up

    var sink = EntrySink.init(alloc);
    defer sink.deinit();
    var tally: Tally = .{};
    try upgradeAllCasks(&ctx, alloc, &db, &api, "/opt/malt", true, false, false, plan, &tally, &sink);

    try std.testing.expectEqual(@as(usize, 2), sink.casks.items.len);
    try std.testing.expectEqualStrings("miss", sink.casks.items[0].name);
    try std.testing.expectEqualStrings("3.0", sink.casks.items[0].latest);
    try std.testing.expectEqualStrings("up", sink.casks.items[1].name);
    try std.testing.expectEqualStrings("2.0", sink.casks.items[1].latest);
    try std.testing.expect(!sink.tainted);
    try std.testing.expectEqual(@as(usize, 1), tally.up_to_date); // cur
    try std.testing.expectEqual(@as(usize, 2), tally.would_upgrade); // miss + up
}

test "a proven-current row is folded into the footer, not dropped from it" {
    // The count is the point: on a mostly-current machine every excluded row
    // must still reach `checked()`, or the footer reports 2 on a 200-package
    // box. Nothing here touches the network — both rows resolve from the
    // planted index and neither reaches phase 2.
    const alloc = std.testing.allocator;
    const ctx = @import("../app_ctx.zig").debug_ctx;

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path) VALUES
        \\  ('alpha', 'alpha', '1.0', 'sha', '/cellar/alpha/1.0'),
        \\  ('beta', 'beta', '2.0', 'sha', '/cellar/beta/2.0');
    );

    var s = try Scratch.init("proven_current_fold");
    defer s.deinit();
    const cache_dir = s.base;
    try writeTestVersionsIndex(cache_dir, .formula, "alpha\t1.0\t0\nbeta\t2.0\t0\n");

    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, alloc);
    defer http.deinit();
    http.offline = true; // phase 2 would fail loudly rather than dial out
    var api = api_mod.BrewApi.init(ctx.io, alloc, &http, cache_dir);

    var plan = try audit_mod.audit(alloc, &db, &api, .formula, .{});
    defer plan.deinit(alloc);

    var tally: Tally = .{};
    try upgradeAllFormulas(&ctx, alloc, &db, &api, &http, "/opt/malt", true, false, false, false, &.{}, plan, &tally, null);

    try std.testing.expectEqual(@as(usize, 2), tally.checked());
    try std.testing.expectEqual(@as(usize, 2), tally.up_to_date);
    try std.testing.expectEqual(@as(usize, 0), tally.failed);
}

test "--force sends an index-proven-current row to phase 2 instead of folding it" {
    // Force must reach phase 2 for every row: the same `alpha` the index proves
    // current is folded without force (test above) and here must not be. With
    // the client offline, reaching phase 2 fails loudly — so a `failed` count
    // (not `up_to_date`) is the proof force defeated the fold at the loop, not
    // just at the pure gate.
    const alloc = std.testing.allocator;
    const ctx = @import("../app_ctx.zig").debug_ctx;

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try db.exec("INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path) VALUES ('alpha', 'alpha', '1.0', 'sha', '/cellar/alpha/1.0');");

    var s = try Scratch.init("force_defeats_fold");
    defer s.deinit();
    const cache_dir = s.base;
    try writeTestVersionsIndex(cache_dir, .formula, "alpha\t1.0\t0\n");

    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, alloc);
    defer http.deinit();
    http.offline = true;
    var api = api_mod.BrewApi.init(ctx.io, alloc, &http, cache_dir);

    var plan = try audit_mod.audit(alloc, &db, &api, .formula, .{});
    defer plan.deinit(alloc);
    try std.testing.expect(plan.dispositions[0] == .proven_current);

    // force = true (8th positional).
    var tally: Tally = .{};
    upgradeAllFormulas(&ctx, alloc, &db, &api, &http, "/opt/malt", true, true, false, false, &.{}, plan, &tally, null) catch {};

    try std.testing.expectEqual(@as(usize, 0), tally.up_to_date);
    try std.testing.expectEqual(@as(usize, 1), tally.failed);
    try std.testing.expectEqual(@as(usize, 1), tally.checked());
}

test "a pinned row still reports as pinned even when the index proves it current" {
    // Phase 2 reports a held row `.pinned` before it looks at a version, and
    // the footer counts pinned separately. Folding it as up-to-date here
    // would silently move it to the wrong column.
    const alloc = std.testing.allocator;
    const ctx = @import("../app_ctx.zig").debug_ctx;

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try db.exec("INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, pinned) VALUES ('held', 'held', '1.0', 'sha', '/cellar/held/1.0', 1);");

    var s = try Scratch.init("pinned_row_reports_pinned");
    defer s.deinit();
    const cache_dir = s.base;
    try writeTestVersionsIndex(cache_dir, .formula, "held\t1.0\t0\n");

    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, alloc);
    defer http.deinit();
    http.offline = true;
    var api = api_mod.BrewApi.init(ctx.io, alloc, &http, cache_dir);

    var plan = try audit_mod.audit(alloc, &db, &api, .formula, .{});
    defer plan.deinit(alloc);
    try std.testing.expect(plan.dispositions[0] == .proven_current);

    var tally: Tally = .{};
    try upgradeAllFormulas(&ctx, alloc, &db, &api, &http, "/opt/malt", true, false, false, false, &.{}, plan, &tally, null);

    try std.testing.expectEqual(@as(usize, 1), tally.pinned);
    try std.testing.expectEqual(@as(usize, 0), tally.up_to_date);
    try std.testing.expectEqual(@as(usize, 1), tally.checked());
}

test "a proven-current cask is folded into the footer via the cask token path" {
    // The cask loop folds by `row.name` = token and emits its own ndjson.
    // Formulae and casks diverge elsewhere (tap fallback, revisions), so the
    // fold is proven against `upgradeAllCasks`, not inferred from the formula
    // side. NULL-tap casks resolve from the bulk index like any core row.
    const alloc = std.testing.allocator;
    const ctx = @import("../app_ctx.zig").debug_ctx;

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try db.exec(
        \\INSERT INTO casks (token, name, version, url) VALUES
        \\  ('cur', 'cur', '1.0', 'https://example/cur'),
        \\  ('cur2', 'cur2', '2.0', 'https://example/cur2');
    );

    var s = try Scratch.init("proven_current_cask_fold");
    defer s.deinit();
    const cache_dir = s.base;
    try writeTestVersionsIndex(cache_dir, .cask, "cur\t1.0\t0\ncur2\t2.0\t0\n");

    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, alloc);
    defer http.deinit();
    http.offline = true; // phase 2 would fail loudly rather than dial out
    var api = api_mod.BrewApi.init(ctx.io, alloc, &http, cache_dir);

    var plan = try audit_mod.audit(alloc, &db, &api, .cask, .{});
    defer plan.deinit(alloc);

    var tally: Tally = .{};
    try upgradeAllCasks(&ctx, alloc, &db, &api, "/opt/malt", true, false, false, plan, &tally, null);

    try std.testing.expectEqual(@as(usize, 2), tally.up_to_date);
    try std.testing.expectEqual(@as(usize, 2), tally.checked());
    try std.testing.expectEqual(@as(usize, 0), tally.failed);
}

test "a pinned cask still reports as pinned even when the index proves it current" {
    const alloc = std.testing.allocator;
    const ctx = @import("../app_ctx.zig").debug_ctx;

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try db.exec("INSERT INTO casks (token, name, version, url, pinned) VALUES ('held', 'held', '1.0', 'https://example/held', 1);");

    var s = try Scratch.init("pinned_cask_reports_pinned");
    defer s.deinit();
    const cache_dir = s.base;
    try writeTestVersionsIndex(cache_dir, .cask, "held\t1.0\t0\n");

    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, alloc);
    defer http.deinit();
    http.offline = true;
    var api = api_mod.BrewApi.init(ctx.io, alloc, &http, cache_dir);

    var plan = try audit_mod.audit(alloc, &db, &api, .cask, .{});
    defer plan.deinit(alloc);
    try std.testing.expect(plan.dispositions[0] == .proven_current);

    var tally: Tally = .{};
    try upgradeAllCasks(&ctx, alloc, &db, &api, "/opt/malt", true, false, false, plan, &tally, null);

    try std.testing.expectEqual(@as(usize, 1), tally.pinned);
    try std.testing.expectEqual(@as(usize, 0), tally.up_to_date);
    try std.testing.expectEqual(@as(usize, 1), tally.checked());
}

test "a row missing from the index is still handed to phase 2, never skipped" {
    // The partial-miss trap: the degraded-map guard only fires when *nothing*
    // matched, so a half-populated index is silent. The unmatched row must
    // still be attempted — here it fails against the offline client, which
    // proves it reached phase 2 rather than being folded away at exit 0.
    const alloc = std.testing.allocator;
    const ctx = @import("../app_ctx.zig").debug_ctx;

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path) VALUES
        \\  ('known', 'known', '1.0', 'sha', '/cellar/known/1.0'),
        \\  ('unlisted', 'unlisted', '1.0', 'sha', '/cellar/unlisted/1.0');
    );

    var s = try Scratch.init("unlisted_row_phase2");
    defer s.deinit();
    const cache_dir = s.base;
    // `unlisted` is absent — a partial map, not a total miss.
    try writeTestVersionsIndex(cache_dir, .formula, "known\t1.0\t0\n");

    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, alloc);
    defer http.deinit();
    http.offline = true;
    var api = api_mod.BrewApi.init(ctx.io, alloc, &http, cache_dir);

    var plan = try audit_mod.audit(alloc, &db, &api, .formula, .{});
    defer plan.deinit(alloc);
    try std.testing.expect(plan.dispositions[0] == .proven_current); // known
    try std.testing.expect(plan.dispositions[1] == .unknown); // unlisted

    var tally: Tally = .{};
    upgradeAllFormulas(&ctx, alloc, &db, &api, &http, "/opt/malt", true, false, false, false, &.{}, plan, &tally, null) catch {};

    try std.testing.expectEqual(@as(usize, 1), tally.up_to_date);
    try std.testing.expectEqual(@as(usize, 1), tally.failed);
    try std.testing.expectEqual(@as(usize, 2), tally.checked());
}

test "a pinned needs_upgrade row stays out of the warm, as phase 2's pinSkip would keep it" {
    // A held-but-outdated row reports `.pinned` in phase 2 and never collects,
    // so the plan warm must skip it too or the snapshot would gain a row the
    // sink never had. `held` is pinned and the index proves it behind.
    const alloc = std.testing.allocator;
    const ctx = @import("../app_ctx.zig").debug_ctx;

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try db.exec("INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, pinned) VALUES ('held', 'held', '1.0', 'sha', '/cellar/held/1.0', 1);");

    var s = try Scratch.init("pinned_outdated_no_warm");
    defer s.deinit();
    const cache_dir = s.base;
    try writeTestVersionsIndex(cache_dir, .formula, "held\t2.0\t0\n");

    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, alloc);
    defer http.deinit();
    http.offline = true;
    var api = api_mod.BrewApi.init(ctx.io, alloc, &http, cache_dir);

    var plan = try audit_mod.audit(alloc, &db, &api, .formula, .{});
    defer plan.deinit(alloc);
    try std.testing.expectEqualStrings("2.0", plan.dispositions[0].needs_upgrade);

    var sink = EntrySink.init(alloc);
    defer sink.deinit();
    var tally: Tally = .{};
    upgradeAllFormulas(&ctx, alloc, &db, &api, &http, "/opt/malt", true, false, false, false, &.{}, plan, &tally, &sink) catch {};

    try std.testing.expectEqual(@as(usize, 0), sink.formulas.items.len);
    try std.testing.expectEqual(@as(usize, 1), tally.pinned);
}

test "the dry-run snapshot follows the fetch, not the index, when the two skew" {
    // The index and the per-package fetch can disagree for a `needs_upgrade` row
    // inside the shared TTL. The persisted snapshot must record the fetch's
    // verdict (the one the install actually follows), not the stale index
    // target. `now_current` reads current from its fetch (dropped from the
    // snapshot); `still_behind` reads a fetch target that differs from the index
    // (collected at the fetch's value, not the index's).
    const alloc = std.testing.allocator;
    const ctx = @import("../app_ctx.zig").debug_ctx;

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path) VALUES
        \\  ('now_current', 'now_current', '1.0', 'sha', '/cellar/now_current/1.0'),
        \\  ('still_behind', 'still_behind', '1.0', 'sha', '/cellar/still_behind/1.0');
    );

    var s = try Scratch.init("snapshot_follows_fetch");
    defer s.deinit();
    const cache_dir = s.base;
    // Index: both look behind, and `still_behind`'s target (4.0) is not the one
    // the fetch will resolve.
    try writeTestVersionsIndex(cache_dir, .formula, "now_current\t2.0\t0\nstill_behind\t4.0\t0\n");
    // Fetch: `now_current` is actually current; `still_behind` is behind at 3.0.
    try writeTestFormulaCache(cache_dir, "now_current", "1.0");
    try writeTestFormulaCache(cache_dir, "still_behind", "3.0");

    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, alloc);
    defer http.deinit();
    var api = api_mod.BrewApi.init(ctx.io, alloc, &http, cache_dir);

    var plan = try audit_mod.audit(alloc, &db, &api, .formula, .{});
    defer plan.deinit(alloc);
    try std.testing.expectEqualStrings("2.0", plan.dispositions[0].needs_upgrade); // index target
    try std.testing.expectEqualStrings("4.0", plan.dispositions[1].needs_upgrade); // index target

    var sink = EntrySink.init(alloc);
    defer sink.deinit();
    var tally: Tally = .{};
    try upgradeAllFormulas(&ctx, alloc, &db, &api, &http, "/opt/malt", true, false, false, false, &.{}, plan, &tally, &sink);

    // `now_current` is gone (the fetch folds it up_to_date); `still_behind` is
    // recorded at the fetch's 3.0, never the index's 4.0.
    try std.testing.expectEqual(@as(usize, 1), sink.formulas.items.len);
    try std.testing.expectEqualStrings("still_behind", sink.formulas.items[0].name);
    try std.testing.expectEqualStrings("3.0", sink.formulas.items[0].latest);
    try std.testing.expectEqual(@as(usize, 1), tally.up_to_date); // now_current
    try std.testing.expectEqual(@as(usize, 1), tally.would_upgrade); // still_behind
}

test "the dry-run cask snapshot follows the fetch, not the index, when the two skew" {
    // Cask sibling of the formula case: the cask walker is separate code, so the
    // skew must be proven against it too. `now_current` reads current from its
    // fetch (dropped); `still_behind` is recorded at the fetch's 3.0, not the
    // index's 4.0. Casks carry no revision, so both sides compare bare.
    const alloc = std.testing.allocator;
    const ctx = @import("../app_ctx.zig").debug_ctx;

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try db.exec(
        \\INSERT INTO casks (token, name, version, url) VALUES
        \\  ('now_current', 'now_current', '1.0', 'https://example/now_current'),
        \\  ('still_behind', 'still_behind', '1.0', 'https://example/still_behind');
    );

    var s = try Scratch.init("cask_snapshot_follows_fetch");
    defer s.deinit();
    const cache_dir = s.base;
    try writeTestVersionsIndex(cache_dir, .cask, "now_current\t2.0\t0\nstill_behind\t4.0\t0\n");
    try writeTestCaskCache(cache_dir, "now_current", "1.0");
    try writeTestCaskCache(cache_dir, "still_behind", "3.0");

    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, alloc);
    defer http.deinit();
    var api = api_mod.BrewApi.init(ctx.io, alloc, &http, cache_dir);

    var plan = try audit_mod.audit(alloc, &db, &api, .cask, .{});
    defer plan.deinit(alloc);
    try std.testing.expectEqualStrings("2.0", plan.dispositions[0].needs_upgrade); // index target
    try std.testing.expectEqualStrings("4.0", plan.dispositions[1].needs_upgrade); // index target

    var sink = EntrySink.init(alloc);
    defer sink.deinit();
    var tally: Tally = .{};
    try upgradeAllCasks(&ctx, alloc, &db, &api, "/opt/malt", true, false, false, plan, &tally, &sink);

    try std.testing.expectEqual(@as(usize, 1), sink.casks.items.len);
    try std.testing.expectEqualStrings("still_behind", sink.casks.items[0].name);
    try std.testing.expectEqualStrings("3.0", sink.casks.items[0].latest);
    try std.testing.expectEqual(@as(usize, 1), tally.up_to_date); // now_current
    try std.testing.expectEqual(@as(usize, 1), tally.would_upgrade); // still_behind
}
