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
pub const tapExists = rows_mod.tapExists;
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

/// Stitch the live keg `pinned` + `tap` onto each outdated entry,
/// appending unified render rows to `out`. Pinned/tap are DB attributes
/// (not snapshot state), so we match each entry to its keg row by name;
/// `tap` collapses a SQL NULL to `""` so the JSON field is always present
/// (matching `mt info`). An entry with no matching keg degrades to
/// unpinned/empty tap rather than failing the whole emit.
fn appendRenderRows(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(render_mod.Row),
    entries: []const OutdatedEntry,
    kegs: []const KegRow,
    kind: render_mod.Kind,
) std.mem.Allocator.Error!void {
    if (entries.len == 0) return;

    var by_name: std.StringHashMap(KegRow) = .init(allocator);
    defer by_name.deinit();
    try by_name.ensureTotalCapacity(@intCast(kegs.len));
    for (kegs) |row| by_name.putAssumeCapacity(row.name, row);

    try out.ensureUnusedCapacity(allocator, entries.len);
    for (entries) |e| {
        const row = by_name.get(e.name);
        out.appendAssumeCapacity(.{
            .name = e.name,
            .installed = e.installed,
            .latest = e.latest,
            .kind = kind,
            .pinned = if (row) |r| r.pinned else false,
            .tap = if (row) |r| (r.tap orelse "") else "",
        });
    }
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
        // membership and tap attribution live in the DB. Anything that
        // filters by them has to round-trip the DB, which means a recompute.
        if (std.mem.eql(u8, a, "--pinned-only")) return .recompute;
        if (std.mem.eql(u8, a, "--tap") or std.mem.startsWith(u8, a, "--tap=")) return .recompute;
    }
    if (!snap_present) return .recompute;
    if (isStale(snap_generated_at_ms, now_ms, max_age_hours)) return .use_snapshot_stale;
    return .use_snapshot_fresh;
}

/// Trim ASCII whitespace from a `--tap` label; return null when the
/// trimmed result is empty so the caller can fail with a precise
/// error instead of running the DB lookup against `""`.
pub fn normalizeTapLabel(label: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, label, " \t\n\r");
    if (trimmed.len == 0) return null;
    return trimmed;
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

test "appendRenderRows stitches pinned and tap onto entries by name" {
    const entries = [_]OutdatedEntry{
        .{ .name = @constCast("held"), .installed = @constCast("1.0"), .latest = @constCast("2.0") },
        .{ .name = @constCast("scoped"), .installed = @constCast("3.0"), .latest = @constCast("4.0") },
    };
    const kegs = [_]KegRow{
        .{ .name = "held", .version = "1.0", .tap = null, .pinned = true },
        .{ .name = "scoped", .version = "3.0", .tap = "user/repo", .pinned = false },
    };

    var out: std.ArrayList(render_mod.Row) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendRenderRows(std.testing.allocator, &out, &entries, &kegs, .cask);

    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings("held", out.items[0].name);
    try std.testing.expectEqual(render_mod.Kind.cask, out.items[0].kind);
    try std.testing.expect(out.items[0].pinned);
    try std.testing.expectEqualStrings("", out.items[0].tap);

    try std.testing.expectEqualStrings("scoped", out.items[1].name);
    try std.testing.expect(!out.items[1].pinned);
    try std.testing.expectEqualStrings("user/repo", out.items[1].tap);
}

test "appendRenderRows appends nothing for empty entries" {
    const kegs = [_]KegRow{.{ .name = "held", .version = "1.0", .pinned = true }};
    var out: std.ArrayList(render_mod.Row) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendRenderRows(std.testing.allocator, &out, &.{}, &kegs, .formula);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "appendRenderRows composes formula-then-cask order across two calls" {
    // Mirrors the orchestrator: formulae are appended before casks, so
    // the unified array preserves that grouping.
    const f_entries = [_]OutdatedEntry{
        .{ .name = @constCast("wget"), .installed = @constCast("1.0"), .latest = @constCast("2.0") },
    };
    const c_entries = [_]OutdatedEntry{
        .{ .name = @constCast("flux"), .installed = @constCast("0.1"), .latest = @constCast("0.2") },
    };
    const f_rows = [_]KegRow{.{ .name = "wget", .version = "1.0" }};
    const c_rows = [_]KegRow{.{ .name = "flux", .version = "0.1", .tap = "user/repo" }};

    var out: std.ArrayList(render_mod.Row) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendRenderRows(std.testing.allocator, &out, &f_entries, &f_rows, .formula);
    try appendRenderRows(std.testing.allocator, &out, &c_entries, &c_rows, .cask);

    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqual(render_mod.Kind.formula, out.items[0].kind);
    try std.testing.expectEqualStrings("wget", out.items[0].name);
    try std.testing.expectEqual(render_mod.Kind.cask, out.items[1].kind);
    try std.testing.expectEqualStrings("user/repo", out.items[1].tap);
}

test "appendRenderRows defaults to unpinned + empty tap when no keg matches" {
    const entries = [_]OutdatedEntry{
        .{ .name = @constCast("orphan"), .installed = @constCast("1.0"), .latest = @constCast("2.0") },
    };
    const kegs = [_]KegRow{};

    var out: std.ArrayList(render_mod.Row) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendRenderRows(std.testing.allocator, &out, &entries, &kegs, .formula);

    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(render_mod.Kind.formula, out.items[0].kind);
    try std.testing.expect(!out.items[0].pinned);
    try std.testing.expectEqualStrings("", out.items[0].tap);
    try std.testing.expectEqualStrings("2.0", out.items[0].latest);
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

test "planEmit recomputes when --tap narrows the scope (space form)" {
    const args = [_][]const u8{ "--tap", "user/repo" };
    try std.testing.expectEqual(EmitPlan.recompute, planEmit(&args, true, 0, 0, 24));
}

test "planEmit recomputes when --tap= narrows the scope (equals form)" {
    const args = [_][]const u8{"--tap=user/repo"};
    try std.testing.expectEqual(EmitPlan.recompute, planEmit(&args, true, 0, 0, 24));
}

test "normalizeTapLabel returns null for empty and whitespace-only labels" {
    try std.testing.expectEqual(@as(?[]const u8, null), normalizeTapLabel(""));
    try std.testing.expectEqual(@as(?[]const u8, null), normalizeTapLabel("   "));
    try std.testing.expectEqual(@as(?[]const u8, null), normalizeTapLabel("\t\n"));
}

test "normalizeTapLabel trims surrounding whitespace from a valid label" {
    try std.testing.expectEqualStrings("user/repo", normalizeTapLabel("  user/repo  ").?);
    try std.testing.expectEqualStrings("user/repo", normalizeTapLabel("user/repo").?);
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
    var tap_filter: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--cask")) {
            cask_only = true;
        } else if (std.mem.eql(u8, arg, "--formula") or std.mem.eql(u8, arg, "--formulae")) {
            formula_only = true;
        } else if (std.mem.eql(u8, arg, "--pinned-only")) {
            pinned_only = true;
        } else if (std.mem.eql(u8, arg, "--tap")) {
            if (i + 1 >= args.len) {
                output.err("--tap requires a label (e.g. `--tap user/repo`)", .{});
                return error.Aborted;
            }
            i += 1;
            tap_filter = args[i];
        } else if (std.mem.startsWith(u8, arg, "--tap=")) {
            tap_filter = arg["--tap=".len..];
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

    // Validate --tap before any cache/network I/O so a typo never
    // writes a partial snapshot or warms an API cache for nothing.
    if (tap_filter) |raw_label| {
        const label = normalizeTapLabel(raw_label) orelse {
            output.err("--tap requires a non-empty label (e.g. `--tap user/repo`)", .{});
            return error.Aborted;
        };
        tap_filter = label;
        const known = tapExists(&db, label) catch |e| {
            // Distinct from "Unknown tap": prepare/bind failed, so the
            // schema is mid-migration or the DB is malformed. Point the
            // user at the right diagnostic instead of "unknown tap".
            output.err("Could not query taps registry ({s}). Try `mt doctor`.", .{@errorName(e)});
            return error.Aborted;
        };
        if (!known) {
            output.err("Unknown tap: '{s}'. Run `mt tap` to list installed taps.", .{label});
            return error.Aborted;
        }
    }

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
            .tap = tap_filter,
        }),
    }
}

const ScopeFlags = struct {
    cask_only: bool = false,
    formula_only: bool = false,
    pinned_only: bool = false,
    /// Caller-owned slice (CLI arg); not duplicated.
    tap: ?[]const u8 = null,
};

/// Compressed `(tap, pinned_only)` state so the SQL-filter selection
/// dispatches via a single exhaustive `switch` (mirrors `list.zig`).
const FilterPick = enum { all, pinned, tap };

fn filterPick(scope: ScopeFlags) FilterPick {
    if (scope.tap != null) return .tap;
    if (scope.pinned_only) return .pinned;
    return .all;
}

/// Emit the snapshot through the live DB so an uninstalled or
/// upgraded keg never appears in the output. The keg rows are kept
/// alive alongside the filtered entries so the JSON path can read each
/// row's live `pinned`/`tap` when stitching the unified array.
fn emitFromSnapshot(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    snap: OwnedSnapshot,
    stdout: *std.Io.Writer,
    json_mode: bool,
    scope: ScopeFlags,
) !void {
    var f_rows: ?[]KegRow = null;
    defer if (f_rows) |r| freeKegRows(allocator, r);
    var f_entries: ?[]OutdatedEntry = null;
    defer if (f_entries) |e| freeEntrySlice(allocator, e);
    if (!scope.cask_only) {
        const rows = try loadFormulaRows(allocator, db, .all);
        f_rows = rows;
        f_entries = try intersectWithDb(allocator, rows, snap.formulas);
    }

    var c_rows: ?[]KegRow = null;
    defer if (c_rows) |r| freeKegRows(allocator, r);
    var c_entries: ?[]OutdatedEntry = null;
    defer if (c_entries) |e| freeEntrySlice(allocator, e);
    if (!scope.formula_only) {
        const rows = try loadCaskRows(allocator, db, .all);
        c_rows = rows;
        c_entries = try intersectWithDb(allocator, rows, snap.casks);
    }

    try emitEntries(allocator, stdout, json_mode, scope, .{
        .formula_entries = f_entries orelse &.{},
        .formula_rows = f_rows orelse &.{},
        .cask_entries = c_entries orelse &.{},
        .cask_rows = c_rows orelse &.{},
    });
}

/// The four slices `emitEntries` needs: outdated entries plus the live
/// keg rows they came from (so JSON can read `pinned`/`tap`).
const EmitSlices = struct {
    formula_entries: []const OutdatedEntry,
    formula_rows: []const KegRow,
    cask_entries: []const OutdatedEntry,
    cask_rows: []const KegRow,
};

/// Single emit point shared by the snapshot and recompute paths. JSON
/// frames one array spanning formulae + casks; human mode keeps the
/// two-section bullet output byte-identical to before.
fn emitEntries(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    json_mode: bool,
    scope: ScopeFlags,
    s: EmitSlices,
) !void {
    if (json_mode) {
        var rows: std.ArrayList(render_mod.Row) = .empty;
        defer rows.deinit(allocator);
        try appendRenderRows(allocator, &rows, s.formula_entries, s.formula_rows, .formula);
        try appendRenderRows(allocator, &rows, s.cask_entries, s.cask_rows, .cask);
        try render_mod.writeJsonArray(allocator, stdout, rows.items);
        return;
    }

    render_mod.writeFormulaEntries(stdout, s.formula_entries);
    render_mod.writeCaskEntries(stdout, s.cask_entries);
    if (summaryMessage(s.formula_entries.len, s.cask_entries.len, scope.formula_only, scope.cask_only)) |msg| {
        output.info("{s}", .{msg});
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
    http.offline = ctx.offline;
    var api = api_mod.BrewApi.init(ctx.io, allocator, &http, cache_dir);
    api.base_url = ctx.mirrors.api_base;
    api.offline = ctx.offline;

    const workers_override = parseWorkersEnv(std.process.Environ.getPosix(ctx.environ, outdated_workers_env));

    // --tap wins over --pinned-only when both are present: tap filtering
    // is the more specific intent. A combined "pinned AND tap" filter is
    // intentionally not in scope yet.
    const filter: KegFilter = switch (filterPick(scope)) {
        .all => .all,
        .pinned => .pinned_only,
        .tap => .{ .by_tap = scope.tap.? },
    };

    // Load keg rows + collect outdated entries for both kinds before
    // emitting, so the JSON path can frame one array spanning formulae
    // and casks and read each row's live `pinned`/`tap`. Rows outlive
    // the emit; `&.{}` sentinels keep `free` a no-op when scope skips a
    // kind.
    var f_rows: ?[]KegRow = null;
    defer if (f_rows) |r| freeKegRows(allocator, r);
    var f_entries: ?[]OutdatedEntry = null;
    defer if (f_entries) |e| freeEntrySlice(allocator, e);
    if (!scope.cask_only) {
        const rows = try loadFormulaRows(allocator, db, filter);
        f_rows = rows;
        f_entries = try collectOutdatedFormulas(ctx, allocator, db, &api, cache_dir, rows, workers_override);
    }

    var c_rows: ?[]KegRow = null;
    defer if (c_rows) |r| freeKegRows(allocator, r);
    var c_entries: ?[]OutdatedEntry = null;
    defer if (c_entries) |e| freeEntrySlice(allocator, e);
    if (!scope.formula_only) {
        const rows = try loadCaskRows(allocator, db, filter);
        c_rows = rows;
        c_entries = try collectOutdatedCasks(ctx, allocator, db, &api, cache_dir, rows, workers_override);
    }

    try emitEntries(allocator, stdout, json_mode, scope, .{
        .formula_entries = f_entries orelse &.{},
        .formula_rows = f_rows orelse &.{},
        .cask_entries = c_entries orelse &.{},
        .cask_rows = c_rows orelse &.{},
    });

    // Refresh the snapshot only when we walked the full keg set; any
    // narrowed recompute (pinned, tap, formula-only, cask-only) would
    // mislead the next reader. Best-effort: a write failure shouldn't
    // shadow the listing the user already saw.
    const refresh_ok = switch (filter) {
        .all => !scope.cask_only and !scope.formula_only,
        .pinned_only, .by_tap => false,
    };
    if (refresh_ok) {
        refreshSnapshot(ctx, allocator, db, &api, cache_dir, workers_override) catch {};
    }
}
