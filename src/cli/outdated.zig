//! malt — outdated command
//! List outdated packages.

const std = @import("std");

const AppCtx = @import("../app_ctx.zig").AppCtx;
const formula_mod = @import("../core/formula.zig");
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
pub const writeSnapshotEntries = refresh_mod.writeSnapshotEntries;
pub const collectOutdatedFormulas = refresh_mod.collectOutdatedFormulas;
pub const collectOutdatedCasks = refresh_mod.collectOutdatedCasks;
pub const Disposition = refresh_mod.Disposition;
pub const freeDisposition = refresh_mod.freeDisposition;
pub const freeDispositions = refresh_mod.freeDispositions;
pub const collectIndexDispositionsFormulas = refresh_mod.collectIndexDispositionsFormulas;
pub const collectIndexDispositionsCasks = refresh_mod.collectIndexDispositionsCasks;
const render_mod = @import("outdated/render.zig");
const rows_mod = @import("outdated/rows.zig");
pub const KegRow = rows_mod.KegRow;
pub const KegFilter = rows_mod.KegFilter;
pub const loadFormulaRows = rows_mod.loadFormulaRows;
pub const loadCaskRows = rows_mod.loadCaskRows;
pub const freeKegRows = rows_mod.freeKegRows;
pub const tapExists = rows_mod.tapExists;
const snap_mod = @import("outdated/snapshot.zig");
pub const snapshot_default_max_age_minutes = snap_mod.snapshot_default_max_age_minutes;
pub const snapshot_max_age_env = snap_mod.snapshot_max_age_env;
pub const snapshot_version = snap_mod.snapshot_version;
pub const snapshot_file = snap_mod.snapshot_file;
pub const OutdatedEntry = snap_mod.OutdatedEntry;
pub const Snapshot = snap_mod.Snapshot;
pub const OwnedSnapshot = snap_mod.OwnedSnapshot;
pub const RenderError = snap_mod.RenderError;
pub const SnapshotParseError = snap_mod.SnapshotParseError;
pub const parseMaxAgeMinutesEnv = snap_mod.parseMaxAgeMinutesEnv;
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
        // Snapshot `installed` is revision-qualified (assembleEntries); rebuild
        // the same string from the bare DB version + revision so revisioned
        // kegs match. Overflow degrades to the bare version, matching the write
        // side's fallback.
        var installed_buf: [256]u8 = undefined;
        const installed = formula_mod.pkgVersion(&installed_buf, row.version, row.revision) catch row.version;
        if (!std.mem.eql(u8, e.installed, installed)) continue;
        const dup = try dupEntry(allocator, e);
        out.appendAssumeCapacity(dup);
    }
    return out.toOwnedSlice(allocator);
}

/// Reconcile the cached snapshot against the live DB, dropping entries whose
/// keg has moved past the `installed` the snapshot recorded. `mt upgrade` is
/// the caller: it mutates kegs without touching the file, and the TUI's warm
/// read parses that file raw — so an unreconciled snapshot paints a
/// just-upgraded package as outdated until the background audit lands.
///
/// Reuses `intersectWithDb`, so the file converges on exactly what the
/// DB-filtering reader would print; each array is matched against its own
/// table, so a token that is both a formula and a cask cannot cross over.
/// `generated_at_ms` is preserved — survivors keep the lease they earned
/// rather than a falsely extended one.
///
/// Best-effort and all-or-nothing: a load failure abandons the prune outright.
/// `intersectWithDb` yields an empty set for zero rows, so degrading a failed
/// load to "no rows" would persist an empty array and silently under-report
/// every package — hence `catch return` before the single write, never a
/// partial one.
pub fn pruneSnapshot(io: std.Io, allocator: std.mem.Allocator, db: *sqlite.Database, cache_dir: []const u8) void {
    // A missing or unparseable snapshot is left alone: an upgrade run knows
    // only what it touched and must never synthesise a whole file.
    const snap = readSnapshot(io, allocator, cache_dir) orelse return;
    defer freeSnapshot(allocator, snap);

    const f_rows = loadFormulaRows(allocator, db, .all) catch return;
    defer freeKegRows(allocator, f_rows);
    const c_rows = loadCaskRows(allocator, db, .all) catch return;
    defer freeKegRows(allocator, c_rows);

    const f_entries = intersectWithDb(allocator, f_rows, snap.formulas) catch return;
    defer freeEntrySlice(allocator, f_entries);
    const c_entries = intersectWithDb(allocator, c_rows, snap.casks) catch return;
    defer freeEntrySlice(allocator, c_entries);

    writeSnapshot(io, allocator, cache_dir, .{
        .generated_at_ms = snap.generated_at_ms,
        .formulas = f_entries,
        .casks = c_entries,
    }) catch {};
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
    offline: bool,
    snap_generated_at_ms: i64,
    now_ms: i64,
    max_age_minutes: u64,
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
    if (!isStale(snap_generated_at_ms, now_ms, max_age_minutes)) return .use_snapshot_fresh;
    // Past the TTL: refresh live so `mt outdated` tracks the same ~5-minute
    // freshness as `mt upgrade`. Offline can't refresh, so serve the best data
    // we have — a stale-but-complete cached read beats silently under-reporting.
    return if (offline) .use_snapshot_stale else .recompute;
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

test "intersectWithDb keeps a revision-bumped formula" {
    // Snapshot writes `installed` revision-qualified (pkgVersion), but the DB
    // keeps the bare version + separate revision; the match must reconstruct
    // the qualified string so revisioned kegs survive the intersect.
    const snap = [_]OutdatedEntry{
        .{ .name = @constCast("foo"), .installed = @constCast("1.2.3_1"), .latest = @constCast("1.3.0") },
    };
    const db = [_]KegRow{
        .{ .name = "foo", .version = "1.2.3", .revision = 1 },
    };
    const out = try intersectWithDb(std.testing.allocator, &db, &snap);
    defer freeEntrySlice(std.testing.allocator, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("foo", out[0].name);
    try std.testing.expectEqualStrings("1.2.3_1", out[0].installed);
}

/// Seed a temp cache dir + in-memory DB for the `pruneSnapshot` tests.
const PruneEnv = struct {
    tmp: std.testing.TmpDir,
    db: sqlite.Database,
    buf: [std.fs.max_path_bytes]u8 = undefined,
    len: usize = 0,

    fn init() !PruneEnv {
        var env: PruneEnv = .{ .tmp = std.testing.tmpDir(.{}), .db = try sqlite.Database.open(":memory:") };
        try schema.initSchema(&env.db);
        env.len = try std.Io.Dir.realPath(env.tmp.dir, std.Options.debug_io, &env.buf);
        return env;
    }

    /// Derived on call: `init` returns by value, so a stored slice would
    /// point into the moved-from copy's buffer.
    fn dir(self: *const PruneEnv) []const u8 {
        return self.buf[0..self.len];
    }

    fn deinit(self: *PruneEnv) void {
        self.db.close();
        self.tmp.cleanup();
    }
};

test "pruneSnapshot drops an upgraded keg, keeps an untouched one, and preserves the lease" {
    // The whole point: `mt upgrade jq` moves the keg but the TUI's warm read
    // parses the snapshot raw, so an unreconciled file paints jq as outdated.
    // wget must survive — a plain delete would cost it a needless audit.
    const a = std.testing.allocator;
    const io = std.Options.debug_io;
    var env = try PruneEnv.init();
    defer env.deinit();

    try env.db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path)
        \\VALUES ('jq', 'jq', '1.8.0', 's', '/c'), ('wget', 'wget', '1.24', 's', '/c');
    );
    const stamp: i64 = 1_700_000_000_000;
    try writeSnapshot(io, a, env.dir(), .{
        .generated_at_ms = stamp,
        .formulas = &.{
            .{ .name = @constCast("jq"), .installed = @constCast("1.7.1"), .latest = @constCast("1.8.0") },
            .{ .name = @constCast("wget"), .installed = @constCast("1.24"), .latest = @constCast("1.25") },
        },
        .casks = &.{},
    });

    pruneSnapshot(io, a, &env.db, env.dir());

    const snap = readSnapshot(io, a, env.dir()).?;
    defer freeSnapshot(a, snap);
    try std.testing.expectEqual(@as(usize, 1), snap.formulas.len);
    try std.testing.expectEqualStrings("wget", snap.formulas[0].name);
    // A re-stamp would grant the survivor a 5-minute lease it never earned.
    try std.testing.expectEqual(stamp, snap.generated_at_ms);
}

test "pruneSnapshot matches each array against its own table" {
    // A token installed as both a formula and a cask must not let one array's
    // upgrade drop the other's still-valid entry.
    const a = std.testing.allocator;
    const io = std.Options.debug_io;
    var env = try PruneEnv.init();
    defer env.deinit();

    try env.db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path)
        \\VALUES ('docker', 'docker', '27.0', 's', '/c');
    );
    try env.db.exec(
        \\INSERT INTO casks (token, name, version, url)
        \\VALUES ('docker', 'Docker', '4.30', 'https://example.invalid/d.dmg');
    );
    try writeSnapshot(io, a, env.dir(), .{
        .generated_at_ms = 1,
        // the formula moved 26.0 -> 27.0; the cask never budged
        .formulas = &.{
            .{ .name = @constCast("docker"), .installed = @constCast("26.0"), .latest = @constCast("27.0") },
        },
        .casks = &.{
            .{ .name = @constCast("docker"), .installed = @constCast("4.30"), .latest = @constCast("4.31") },
        },
    });

    pruneSnapshot(io, a, &env.db, env.dir());

    const snap = readSnapshot(io, a, env.dir()).?;
    defer freeSnapshot(a, snap);
    try std.testing.expectEqual(@as(usize, 0), snap.formulas.len);
    try std.testing.expectEqual(@as(usize, 1), snap.casks.len);
    try std.testing.expectEqualStrings("docker", snap.casks[0].name);
}

test "pruneSnapshot keeps a pinned keg an upgrade refused to move" {
    // A pin veto reports success without upgrading, so the entry is still
    // genuinely outdated — pruning it would silently under-report.
    const a = std.testing.allocator;
    const io = std.Options.debug_io;
    var env = try PruneEnv.init();
    defer env.deinit();

    try env.db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, pinned)
        \\VALUES ('held', 'held', '1.0', 's', '/c', 1);
    );
    try writeSnapshot(io, a, env.dir(), .{
        .generated_at_ms = 1,
        .formulas = &.{
            .{ .name = @constCast("held"), .installed = @constCast("1.0"), .latest = @constCast("2.0") },
        },
        .casks = &.{},
    });

    pruneSnapshot(io, a, &env.db, env.dir());

    const snap = readSnapshot(io, a, env.dir()).?;
    defer freeSnapshot(a, snap);
    try std.testing.expectEqual(@as(usize, 1), snap.formulas.len);
    try std.testing.expectEqualStrings("held", snap.formulas[0].name);
}

test "pruneSnapshot never synthesises a snapshot that was not there" {
    // An upgrade run knows only what it touched; writing a file from that
    // partial view is the under-reporting the plan warm gate exists to veto.
    const a = std.testing.allocator;
    const io = std.Options.debug_io;
    var env = try PruneEnv.init();
    defer env.deinit();

    pruneSnapshot(io, a, &env.db, env.dir());
    try std.testing.expect(readSnapshot(io, a, env.dir()) == null);
}

test "intersectWithDb drops a keg whose revision moved past the snapshot" {
    // Match key is the revision-aware installed string, so a manual revision
    // upgrade (1.2.3_1 -> 1.2.3_2) past the snapshot still re-drops the entry.
    const snap = [_]OutdatedEntry{
        .{ .name = @constCast("foo"), .installed = @constCast("1.2.3_1"), .latest = @constCast("1.3.0") },
    };
    const db = [_]KegRow{
        .{ .name = "foo", .version = "1.2.3", .revision = 2 },
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
    try std.testing.expectEqual(EmitPlan.use_snapshot_fresh, planEmit(&args, true, false, 0, 0, 24));
}

test "planEmit recomputes a stale snapshot when online" {
    // The TTL is a refresh trigger, not just a warning: past it, `mt outdated`
    // refreshes live so it can't disagree with the always-live `mt upgrade`.
    const minute_ms: i64 = 60 * 1000;
    const args = [_][]const u8{};
    try std.testing.expectEqual(
        EmitPlan.recompute,
        planEmit(&args, true, false, 0, 25 * minute_ms, 24),
    );
}

test "planEmit serves a stale snapshot offline rather than under-reporting" {
    // Offline can't refresh; a complete cached read beats a recompute that
    // would silently drop every formula it can't fetch.
    const minute_ms: i64 = 60 * 1000;
    const args = [_][]const u8{};
    try std.testing.expectEqual(
        EmitPlan.use_snapshot_stale,
        planEmit(&args, true, true, 0, 25 * minute_ms, 24),
    );
}

test "planEmit falls back to recompute when no snapshot is present" {
    const args = [_][]const u8{};
    try std.testing.expectEqual(EmitPlan.recompute, planEmit(&args, false, false, 0, 0, 24));
}

test "planEmit recomputes on --refresh even when snapshot is fresh" {
    const args = [_][]const u8{"--refresh"};
    try std.testing.expectEqual(EmitPlan.recompute, planEmit(&args, true, false, 0, 0, 24));
}

test "planEmit recomputes when --pinned-only narrows the scope" {
    const args = [_][]const u8{"--pinned-only"};
    try std.testing.expectEqual(EmitPlan.recompute, planEmit(&args, true, false, 0, 0, 24));
}

test "planEmit recomputes when --tap narrows the scope (space form)" {
    const args = [_][]const u8{ "--tap", "user/repo" };
    try std.testing.expectEqual(EmitPlan.recompute, planEmit(&args, true, false, 0, 0, 24));
}

test "planEmit recomputes when --tap= narrows the scope (equals form)" {
    const args = [_][]const u8{"--tap=user/repo"};
    try std.testing.expectEqual(EmitPlan.recompute, planEmit(&args, true, false, 0, 0, 24));
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

test "warmSnapshotFromRecompute writes the in-hand entries on a full-keg walk" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const ctx: AppCtx = .{ .io = io, .environ = .empty };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_dir = base_buf[0..try std.Io.Dir.realPath(tmp.dir, io, &base_buf)];

    const formulas = [_]OutdatedEntry{
        .{ .name = @constCast("wget"), .installed = @constCast("1.21.3"), .latest = @constCast("1.21.4") },
    };
    const casks = [_]OutdatedEntry{
        .{ .name = @constCast("firefox"), .installed = @constCast("120.0"), .latest = @constCast("121.0") },
    };

    warmSnapshotFromRecompute(&ctx, std.testing.allocator, cache_dir, .all, .{}, &formulas, &casks);

    const read = readSnapshot(io, std.testing.allocator, cache_dir) orelse
        return error.SnapshotUnreadable;
    defer snap_mod.freeSnapshot(std.testing.allocator, read);
    try std.testing.expectEqual(@as(usize, 1), read.formulas.len);
    try std.testing.expectEqualStrings("wget", read.formulas[0].name);
    try std.testing.expectEqualStrings("1.21.4", read.formulas[0].latest);
    try std.testing.expectEqual(@as(usize, 1), read.casks.len);
    try std.testing.expectEqualStrings("firefox", read.casks[0].name);
}

test "warmSnapshotFromRecompute writes no snapshot on a narrowed walk" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const ctx: AppCtx = .{ .io = io, .environ = .empty };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_dir = base_buf[0..try std.Io.Dir.realPath(tmp.dir, io, &base_buf)];

    const formulas = [_]OutdatedEntry{
        .{ .name = @constCast("wget"), .installed = @constCast("1.21.3"), .latest = @constCast("1.21.4") },
    };

    // A pinned/tap/formula-only walk is not the full keg set; warming from it
    // would persist a partial snapshot the next reader would trust as complete.
    warmSnapshotFromRecompute(&ctx, std.testing.allocator, cache_dir, .pinned_only, .{ .pinned_only = true }, &formulas, &.{});

    try std.testing.expect(readSnapshot(io, std.testing.allocator, cache_dir) == null);
}

test "warmSnapshotFromRecompute gate is closed for every narrowed walk, not just pinned" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const ctx: AppCtx = .{ .io = io, .environ = .empty };

    const entries = [_]OutdatedEntry{
        .{ .name = @constCast("wget"), .installed = @constCast("1.21.3"), .latest = @constCast("1.21.4") },
    };

    // Every scope that audited a subset must leave the snapshot alone. Covering
    // the whole switch guards against a future filter flipping the gate open.
    const narrowed = [_]struct { filter: KegFilter, scope: ScopeFlags }{
        .{ .filter = .all, .scope = .{ .formula_only = true } },
        .{ .filter = .all, .scope = .{ .cask_only = true } },
        .{ .filter = .{ .by_tap = "user/repo" }, .scope = .{ .tap = "user/repo" } },
    };
    for (narrowed) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var base_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cache_dir = base_buf[0..try std.Io.Dir.realPath(tmp.dir, io, &base_buf)];

        warmSnapshotFromRecompute(&ctx, std.testing.allocator, cache_dir, case.filter, case.scope, &entries, &entries);
        try std.testing.expect(readSnapshot(io, std.testing.allocator, cache_dir) == null);
    }
}

test "warmSnapshotFromRecompute writes an empty snapshot when a full walk finds nothing outdated" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const ctx: AppCtx = .{ .io = io, .environ = .empty };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_dir = base_buf[0..try std.Io.Dir.realPath(tmp.dir, io, &base_buf)];

    // The zero-keg full recompute: an empty audit still writes, so a later
    // cached read serves "nothing outdated" instead of a stale snapshot.
    warmSnapshotFromRecompute(&ctx, std.testing.allocator, cache_dir, .all, .{}, &.{}, &.{});

    const read = readSnapshot(io, std.testing.allocator, cache_dir) orelse
        return error.SnapshotUnreadable;
    defer snap_mod.freeSnapshot(std.testing.allocator, read);
    try std.testing.expectEqual(@as(usize, 0), read.formulas.len);
    try std.testing.expectEqual(@as(usize, 0), read.casks.len);
}

test "warmSnapshotFromRecompute swallows a write failure without crashing" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const ctx: AppCtx = .{ .io = io, .environ = .empty };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try std.Io.Dir.realPath(tmp.dir, io, &base_buf)];

    // Point cache_dir at a regular file so writing `<dir>/outdated.json` hits
    // ENOTDIR. The best-effort gate must absorb the failure so a snapshot
    // hiccup never sinks the recompute the user already saw, and leave nothing
    // half-written behind.
    (try tmp.dir.createFile(io, "not_a_dir", .{})).close(io);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_as_dir = try std.fmt.bufPrint(&path_buf, "{s}/not_a_dir", .{base});
    warmSnapshotFromRecompute(&ctx, std.testing.allocator, file_as_dir, .all, .{}, &.{}, &.{});
    try std.testing.expect(readSnapshot(io, std.testing.allocator, file_as_dir) == null);
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
        if (std.mem.eql(u8, arg, "--cask") or std.mem.eql(u8, arg, "--casks")) {
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

    const max_age_minutes = parseMaxAgeMinutesEnv(std.process.Environ.getPosix(ctx.environ, snapshot_max_age_env)) orelse
        snapshot_default_max_age_minutes;
    const snap_opt = readSnapshot(ctx.io, allocator, cache_dir);
    defer if (snap_opt) |s| freeSnapshot(allocator, s);

    const plan = planEmit(
        args,
        snap_opt != null,
        ctx.offline,
        if (snap_opt) |s| s.generated_at_ms else 0,
        std.Io.Clock.real.now(ctx.io).toMilliseconds(),
        max_age_minutes,
    );

    switch (plan) {
        .use_snapshot_fresh, .use_snapshot_stale => {
            if (plan == .use_snapshot_stale) {
                output.warn(
                    "Offline: serving a cached outdated snapshot older than {d}m; reconnect and re-run to refresh.",
                    .{max_age_minutes},
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

    // Warm the shared snapshot from the entries we just audited instead of
    // re-auditing the same keg set inside `refreshSnapshot`.
    warmSnapshotFromRecompute(ctx, allocator, cache_dir, filter, scope, f_entries orelse &.{}, c_entries orelse &.{});
}

fn warmSnapshotFromRecompute(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    filter: KegFilter,
    scope: ScopeFlags,
    f_entries: []const OutdatedEntry,
    c_entries: []const OutdatedEntry,
) void {
    // Warm only from a full-keg walk. The snapshot's readers — the cached
    // `mt outdated` serve path and the TUI Outdated tab — treat it as the
    // whole outdated set: they filter it against the live DB but never
    // re-expand it, so anything absent reads as "up to date". A narrowed
    // recompute (pinned, tap, formula-only, cask-only) audits only a subset,
    // so persisting it here would silently under-report every keg it skipped.
    // `refresh_ok ⇒ full-keg audit` is the invariant that prevents that.
    const refresh_ok = switch (filter) {
        .all => !scope.cask_only and !scope.formula_only,
        .pinned_only, .by_tap => false,
    };
    if (!refresh_ok) return;

    // Best-effort: a write failure must not shadow the listing the user
    // already saw. The entries are the recompute's own audit, so this warms
    // the snapshot without the second full audit `refreshSnapshot` would run.
    writeSnapshotEntries(ctx, allocator, cache_dir, f_entries, c_entries) catch {};
}
