//! malt — outdated command
//! List outdated packages.

const std = @import("std");

const AppCtx = @import("../app_ctx.zig").AppCtx;
const schema = @import("../db/schema.zig");
const sqlite = @import("../db/sqlite.zig");
const atomic = @import("../fs/atomic.zig");
const api_mod = @import("../net/api.zig");
const client_mod = @import("../net/client.zig");
const color = @import("../ui/color.zig");
const output = @import("../ui/output.zig");
const help = @import("help.zig");
const refresh_mod = @import("outdated/refresh.zig");
pub const outdated_default_workers = refresh_mod.outdated_default_workers;
pub const outdated_workers_env = refresh_mod.outdated_workers_env;
pub const parseWorkersEnv = refresh_mod.parseWorkersEnv;
pub const outdatedWorkerCount = refresh_mod.outdatedWorkerCount;
pub const shouldUsePool = refresh_mod.shouldUsePool;
pub const refreshSnapshot = refresh_mod.refreshSnapshot;
pub const collectOutdatedFormulas = refresh_mod.collectOutdatedFormulas;
pub const collectOutdatedCasks = refresh_mod.collectOutdatedCasks;
const render_mod = @import("outdated/render.zig");
const rows_mod = @import("outdated/rows.zig");
pub const KegRow = rows_mod.KegRow;
pub const KegFilter = rows_mod.KegFilter;
pub const loadFormulaRows = rows_mod.loadFormulaRows;
pub const loadCaskRows = rows_mod.loadCaskRows;
pub const freeKegRows = rows_mod.freeKegRows;
const snap_mod = @import("outdated/snapshot.zig");
pub const snapshot_default_max_age_hours = snap_mod.snapshot_default_max_age_hours;
pub const snapshot_max_age_env = snap_mod.snapshot_max_age_env;
pub const snapshot_version = snap_mod.snapshot_version;
pub const snapshot_file = snap_mod.snapshot_file;
pub const OutdatedEntry = snap_mod.OutdatedEntry;
pub const Snapshot = snap_mod.Snapshot;
pub const OwnedSnapshot = snap_mod.OwnedSnapshot;
pub const RenderError = snap_mod.RenderError;
pub const SnapshotParseError = snap_mod.SnapshotParseError;
pub const parseMaxAgeHoursEnv = snap_mod.parseMaxAgeHoursEnv;
pub const isStale = snap_mod.isStale;
pub const renderSnapshot = snap_mod.renderSnapshot;
pub const parseSnapshot = snap_mod.parseSnapshot;
pub const snapshotPath = snap_mod.snapshotPath;
pub const writeSnapshot = snap_mod.writeSnapshot;
pub const readSnapshot = snap_mod.readSnapshot;
pub const freeSnapshot = snap_mod.freeSnapshot;
const freeEntrySlice = snap_mod.freeEntrySlice;

// Worker-pool tuning + live-audit pipeline live in `outdated/refresh.zig`.
// Snapshot codec lives in `outdated/snapshot.zig`; the constants and
// public surface are re-exported below so downstream callers (and
// existing tests) keep the same `outdated_mod.X` path.
// DB row loaders live in `outdated/rows.zig`; re-exported so existing
// callers (and `tests/outdated_test.zig`) keep using `outdated_mod.X`.
/// Filter `snap_entries` against the current DB so a stale snapshot
/// never names an uninstalled or already-upgraded keg. Match key is
/// `(name, installed)`; a name-only match would let a manual upgrade
/// past `installed` still report the keg as outdated. Returns a
/// caller-owned slice; free with `freeEntrySlice` semantics.
pub fn intersectWithDb(
    allocator: std.mem.Allocator,
    db_rows: []const KegRow,
    snap_entries: []const OutdatedEntry,
) std.mem.Allocator.Error![]OutdatedEntry {
    if (snap_entries.len == 0 or db_rows.len == 0) {
        return allocator.alloc(OutdatedEntry, 0);
    }

    // O(N+M): index the snapshot by name once, then walk the DB rows
    // (which already arrive in `ORDER BY name` so emit order is stable).
    var by_name: std.StringHashMap(*const OutdatedEntry) = .init(allocator);
    defer by_name.deinit();
    try by_name.ensureTotalCapacity(@intCast(snap_entries.len));
    for (snap_entries) |*e| {
        // Names are unique per scope; a duplicate is a corrupted file,
        // so we favour the first entry rather than rejecting the read.
        const gop = by_name.getOrPutAssumeCapacity(e.name);
        if (!gop.found_existing) gop.value_ptr.* = e;
    }

    var out: std.ArrayList(OutdatedEntry) = try .initCapacity(allocator, db_rows.len);
    errdefer {
        for (out.items) |e| {
            allocator.free(e.name);
            allocator.free(e.installed);
            allocator.free(e.latest);
        }
        out.deinit(allocator);
    }

    for (db_rows) |row| {
        const e_ptr = by_name.get(row.name) orelse continue;
        const e = e_ptr.*;
        if (!std.mem.eql(u8, e.installed, row.version)) continue;
        const dup = try dupEntry(allocator, e);
        out.appendAssumeCapacity(dup);
    }
    return out.toOwnedSlice(allocator);
}

fn dupEntry(allocator: std.mem.Allocator, e: OutdatedEntry) std.mem.Allocator.Error!OutdatedEntry {
    const name = try allocator.dupe(u8, e.name);
    errdefer allocator.free(name);
    const installed = try allocator.dupe(u8, e.installed);
    errdefer allocator.free(installed);
    const latest = try allocator.dupe(u8, e.latest);
    return .{ .name = name, .installed = installed, .latest = latest };
}

/// What `mt outdated` should do for the current invocation. Picked once,
/// up front, so the dispatch is testable and the rest of `execute`
/// stays linear.
pub const EmitPlan = enum {
    /// Snapshot exists, fresh enough — read silently.
    use_snapshot_fresh,
    /// Snapshot exists, age past threshold — read but warn.
    use_snapshot_stale,
    /// Recompute live: missing snapshot, `--refresh`, or filter (e.g.
    /// `--pinned-only`) the snapshot can't satisfy.
    recompute,
};

/// Decide whether to read the snapshot or recompute. Pure; tested.
pub fn planEmit(
    args: []const []const u8,
    snap_present: bool,
    snap_generated_at_ms: i64,
    now_ms: i64,
    max_age_hours: u64,
) EmitPlan {
    for (args) |a| {
        if (std.mem.eql(u8, a, "--refresh")) return .recompute;
        // The cached snapshot is "all-installed" by construction; pinned
        // membership lives in the DB. Anything that filters by it has to
        // round-trip the DB, which means a recompute.
        if (std.mem.eql(u8, a, "--pinned-only")) return .recompute;
    }
    if (!snap_present) return .recompute;
    if (isStale(snap_generated_at_ms, now_ms, max_age_hours)) return .use_snapshot_stale;
    return .use_snapshot_fresh;
}

/// "All clear" summary line for the current scope, or null when at
/// least one outdated row was already emitted (so we never claim
/// "everything's fine" alongside a list of outdated packages).
fn summaryMessage(formula_count: usize, cask_count: usize, formula_only: bool, cask_only: bool) ?[]const u8 {
    if (formula_count != 0 or cask_count != 0) return null;
    if (formula_only) return "All formulas are up to date.";
    if (cask_only) return "All casks are up to date.";
    return "All packages are up to date.";
}

test "intersectWithDb drops snapshot entries whose keg is no longer installed" {
    const snap = [_]OutdatedEntry{
        .{ .name = @constCast("alpha"), .installed = @constCast("1.0"), .latest = @constCast("2.0") },
        .{ .name = @constCast("ghost"), .installed = @constCast("0.5"), .latest = @constCast("1.0") },
        .{ .name = @constCast("zulu"), .installed = @constCast("3.0"), .latest = @constCast("3.5") },
    };
    const db = [_]KegRow{
        .{ .name = "alpha", .version = "1.0" },
        // ghost was uninstalled since the snapshot was taken
        .{ .name = "zulu", .version = "3.0" },
    };
    const out = try intersectWithDb(std.testing.allocator, &db, &snap);
    defer freeEntrySlice(std.testing.allocator, out);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("alpha", out[0].name);
    try std.testing.expectEqualStrings("zulu", out[1].name);
}

test "intersectWithDb drops entries whose installed version no longer matches" {
    const snap = [_]OutdatedEntry{
        .{ .name = @constCast("alpha"), .installed = @constCast("1.0"), .latest = @constCast("2.0") },
    };
    const db = [_]KegRow{
        // user upgraded alpha 1.0 -> 1.5 manually; we don't know if 1.5 is
        // outdated until the snapshot is refreshed, so we drop it.
        .{ .name = "alpha", .version = "1.5" },
    };
    const out = try intersectWithDb(std.testing.allocator, &db, &snap);
    defer freeEntrySlice(std.testing.allocator, out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "intersectWithDb preserves DB ordering and ignores newly-installed kegs" {
    const snap = [_]OutdatedEntry{
        .{ .name = @constCast("bravo"), .installed = @constCast("1.0"), .latest = @constCast("2.0") },
    };
    const db = [_]KegRow{
        .{ .name = "alpha", .version = "9.9" }, // installed since snapshot, ignored
        .{ .name = "bravo", .version = "1.0" },
    };
    const out = try intersectWithDb(std.testing.allocator, &db, &snap);
    defer freeEntrySlice(std.testing.allocator, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("bravo", out[0].name);
}

test "intersectWithDb returns empty for empty inputs" {
    const empty_snap: []const OutdatedEntry = &.{};
    const empty_db: []const KegRow = &.{};
    const both = try intersectWithDb(std.testing.allocator, empty_db, empty_snap);
    defer freeEntrySlice(std.testing.allocator, both);
    try std.testing.expectEqual(@as(usize, 0), both.len);

    const some_snap = [_]OutdatedEntry{
        .{ .name = @constCast("alpha"), .installed = @constCast("1"), .latest = @constCast("2") },
    };
    const left = try intersectWithDb(std.testing.allocator, empty_db, &some_snap);
    defer freeEntrySlice(std.testing.allocator, left);
    try std.testing.expectEqual(@as(usize, 0), left.len);

    const some_db = [_]KegRow{.{ .name = "alpha", .version = "1" }};
    const right = try intersectWithDb(std.testing.allocator, &some_db, empty_snap);
    defer freeEntrySlice(std.testing.allocator, right);
    try std.testing.expectEqual(@as(usize, 0), right.len);
}

test "planEmit picks a fresh snapshot when one exists and age is below threshold" {
    const args = [_][]const u8{};
    try std.testing.expectEqual(EmitPlan.use_snapshot_fresh, planEmit(&args, true, 0, 0, 24));
}

test "planEmit warns on stale snapshots" {
    const hour_ms: i64 = 60 * 60 * 1000;
    const args = [_][]const u8{};
    try std.testing.expectEqual(
        EmitPlan.use_snapshot_stale,
        planEmit(&args, true, 0, 25 * hour_ms, 24),
    );
}

test "planEmit falls back to recompute when no snapshot is present" {
    const args = [_][]const u8{};
    try std.testing.expectEqual(EmitPlan.recompute, planEmit(&args, false, 0, 0, 24));
}

test "planEmit recomputes on --refresh even when snapshot is fresh" {
    const args = [_][]const u8{"--refresh"};
    try std.testing.expectEqual(EmitPlan.recompute, planEmit(&args, true, 0, 0, 24));
}

test "planEmit recomputes when --pinned-only narrows the scope" {
    const args = [_][]const u8{"--pinned-only"};
    try std.testing.expectEqual(EmitPlan.recompute, planEmit(&args, true, 0, 0, 24));
}

test "summaryMessage suppresses 'all up to date' when any row was printed" {
    try std.testing.expectEqual(@as(?[]const u8, null), summaryMessage(3, 0, false, false));
    try std.testing.expectEqual(@as(?[]const u8, null), summaryMessage(0, 2, false, false));
    try std.testing.expectEqual(@as(?[]const u8, null), summaryMessage(1, 1, false, false));
}

test "summaryMessage picks the message that matches the active scope" {
    try std.testing.expectEqualStrings(
        "All packages are up to date.",
        summaryMessage(0, 0, false, false).?,
    );
    try std.testing.expectEqualStrings(
        "All formulas are up to date.",
        summaryMessage(0, 0, true, false).?,
    );
    try std.testing.expectEqualStrings(
        "All casks are up to date.",
        summaryMessage(0, 0, false, true).?,
    );
}

pub fn execute(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(ctx, args, "outdated")) return;

    var cask_only = false;
    var formula_only = false;
    var pinned_only = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--cask")) {
            cask_only = true;
        } else if (std.mem.eql(u8, arg, "--formula") or std.mem.eql(u8, arg, "--formulae")) {
            formula_only = true;
        } else if (std.mem.eql(u8, arg, "--pinned-only")) {
            pinned_only = true;
        }
    }
    // `--json` and `--quiet` are stripped by the global parser in main.zig.
    const json_mode = output.isJson();

    const cache_dir = atomic.maltCacheDir(allocator) catch {
        output.err("Failed to determine cache directory", .{});
        return error.Aborted;
    };
    defer allocator.free(cache_dir);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = ctx.stdout.writer(ctx.io, &stdout_buf);
    const stdout: *std.Io.Writer = &stdout_fw.interface;
    // Flush on teardown; stdout closed by a broken pipe is normal shell usage.
    defer stdout.flush() catch {};

    const prefix = atomic.maltPrefixOrAbort();
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return;
    var db = sqlite.Database.open(db_path) catch {
        // Fresh prefix: nothing installed = nothing to be outdated.
        return;
    };
    defer db.close();
    schema.initSchema(&db) catch return;

    const max_age_hours = parseMaxAgeHoursEnv(std.process.Environ.getPosix(ctx.environ, snapshot_max_age_env)) orelse
        snapshot_default_max_age_hours;
    const snap_opt = readSnapshot(ctx.io, allocator, cache_dir);
    defer if (snap_opt) |s| freeSnapshot(allocator, s);

    const plan = planEmit(
        args,
        snap_opt != null,
        if (snap_opt) |s| s.generated_at_ms else 0,
        std.Io.Clock.real.now(ctx.io).toMilliseconds(),
        max_age_hours,
    );

    switch (plan) {
        .use_snapshot_fresh, .use_snapshot_stale => {
            if (plan == .use_snapshot_stale) {
                output.warn(
                    "Outdated snapshot is older than {d}h; run `mt update --check` to refresh.",
                    .{max_age_hours},
                );
            }
            try emitFromSnapshot(allocator, &db, snap_opt.?, stdout, json_mode, .{
                .cask_only = cask_only,
                .formula_only = formula_only,
            });
        },
        .recompute => try recomputeAndEmit(ctx, allocator, &db, cache_dir, stdout, json_mode, .{
            .cask_only = cask_only,
            .formula_only = formula_only,
            .pinned_only = pinned_only,
        }),
    }
}

const ScopeFlags = struct {
    cask_only: bool = false,
    formula_only: bool = false,
    pinned_only: bool = false,
};

/// Emit the snapshot through the live DB so an uninstalled or
/// upgraded keg never appears in the output.
fn emitFromSnapshot(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    snap: OwnedSnapshot,
    stdout: *std.Io.Writer,
    json_mode: bool,
    scope: ScopeFlags,
) !void {
    var formula_count: usize = 0;
    var cask_count: usize = 0;

    if (!scope.cask_only) {
        const rows = try loadFormulaRows(allocator, db, .all);
        defer freeKegRows(allocator, rows);
        const filtered = try intersectWithDb(allocator, rows, snap.formulas);
        defer freeEntrySlice(allocator, filtered);
        try render_mod.writeFormulaEntries(allocator, stdout, filtered, json_mode);
        formula_count = filtered.len;
    }
    if (!scope.formula_only) {
        const rows = try loadCaskRows(allocator, db, .all);
        defer freeKegRows(allocator, rows);
        const filtered = try intersectWithDb(allocator, rows, snap.casks);
        defer freeEntrySlice(allocator, filtered);
        try render_mod.writeCaskEntries(stdout, filtered, json_mode);
        cask_count = filtered.len;
    }

    if (!json_mode) {
        if (summaryMessage(formula_count, cask_count, scope.formula_only, scope.cask_only)) |msg| {
            output.info("{s}", .{msg});
        }
    }
}

fn recomputeAndEmit(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    cache_dir: []const u8,
    stdout: *std.Io.Writer,
    json_mode: bool,
    scope: ScopeFlags,
) !void {
    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, allocator);
    defer http.deinit();
    var api = api_mod.BrewApi.init(ctx.io, allocator, &http, cache_dir);

    const workers_override = parseWorkersEnv(std.process.Environ.getPosix(ctx.environ, outdated_workers_env));

    var formula_count: usize = 0;
    var cask_count: usize = 0;
    if (!scope.cask_only) {
        const filter: KegFilter = if (scope.pinned_only) .pinned_only else .all;
        formula_count = try emitOutdatedFormulas(ctx, allocator, db, &api, cache_dir, workers_override, stdout, json_mode, filter);
    }
    if (!scope.formula_only) {
        const filter: KegFilter = if (scope.pinned_only) .pinned_only else .all;
        cask_count = try emitOutdatedCasks(ctx, allocator, db, &api, cache_dir, workers_override, stdout, json_mode, filter);
    }
    // Refresh the snapshot only when we walked the full keg set; a
    // partial recompute would mislead the next reader. Best-effort:
    // a write failure shouldn't shadow the listing the user already saw.
    if (!scope.pinned_only and !scope.cask_only and !scope.formula_only) {
        refreshSnapshot(ctx, allocator, db, &api, cache_dir, workers_override) catch {};
    }

    if (!json_mode) {
        if (summaryMessage(formula_count, cask_count, scope.formula_only, scope.cask_only)) |msg| {
            output.info("{s}", .{msg});
        }
    }
}

fn emitOutdatedFormulas(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    api: *api_mod.BrewApi,
    cache_dir: []const u8,
    workers_override: ?usize,
    stdout: *std.Io.Writer,
    json_mode: bool,
    filter: KegFilter,
) !usize {
    const rows = try loadFormulaRows(allocator, db, filter);
    defer freeKegRows(allocator, rows);

    const entries = try collectOutdatedFormulas(ctx, allocator, api, cache_dir, rows, workers_override);
    defer freeEntrySlice(allocator, entries);

    try render_mod.writeFormulaEntries(allocator, stdout, entries, json_mode);
    return entries.len;
}

fn emitOutdatedCasks(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    api: *api_mod.BrewApi,
    cache_dir: []const u8,
    workers_override: ?usize,
    stdout: *std.Io.Writer,
    json_mode: bool,
    filter: KegFilter,
) !usize {
    const rows = try loadCaskRows(allocator, db, filter);
    defer freeKegRows(allocator, rows);

    const entries = try collectOutdatedCasks(ctx, allocator, api, cache_dir, rows, workers_override);
    defer freeEntrySlice(allocator, entries);

    try render_mod.writeCaskEntries(stdout, entries, json_mode);
    return entries.len;
}
