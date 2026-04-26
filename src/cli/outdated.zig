//! malt — outdated command
//! List outdated packages.

const std = @import("std");
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const atomic = @import("../fs/atomic.zig");
const fs_compat = @import("../fs/compat.zig");
const output = @import("../ui/output.zig");
const io_mod = @import("../ui/io.zig");
const api_mod = @import("../net/api.zig");
const client_mod = @import("../net/client.zig");
const cask_mod = @import("../core/cask.zig");
const color = @import("../ui/color.zig");
const help = @import("help.zig");

/// Default ceiling on concurrent API fetches. One round-trip per keg
/// dominates `mt outdated` on machines with many installed packages, so
/// we hand the work to a bounded pool the same way `cli/install` and
/// `cli/search` do.
pub const OUTDATED_DEFAULT_WORKERS: usize = 8;

/// Env var that lets users tune the pool size (e.g. crank it on a fat
/// uplink, or lower it to one to reproduce serial behaviour).
pub const OUTDATED_WORKERS_ENV = "MALT_OUTDATED_WORKERS";

/// Default max age (hours) for the cached `outdated.json` snapshot. Picked
/// to match the analysis doc: "shell-prompt integrations want instant
/// startup; ~daily refresh is plenty for security awareness".
pub const SNAPSHOT_DEFAULT_MAX_AGE_HOURS: u64 = 24;

/// Env var override for `SNAPSHOT_DEFAULT_MAX_AGE_HOURS`. Same lenient
/// parsing rules as `OUTDATED_WORKERS_ENV`.
pub const SNAPSHOT_MAX_AGE_ENV = "MALT_OUTDATED_MAX_AGE";

/// On-disk snapshot version. Mismatched snapshots are treated as misses
/// so a downgrade never tries to read a future shape.
pub const SNAPSHOT_VERSION: u32 = 1;

/// Snapshot filename under `{cache}/`.
pub const SNAPSHOT_FILE = "outdated.json";

/// One row of the installed-package list fed to the worker pool.
pub const KegRow = struct {
    name: []const u8,
    version: []const u8,
};

/// Scope filter for `loadFormulaRows`. `--pinned-only` swaps in a
/// pinned-row SQL so the audit path never round-trips the API for kegs
/// that aren't being protected from upgrade.
pub const KegFilter = enum { all, pinned_only };

/// Result row for a single outdated package. All slices are owned by
/// the caller's allocator.
pub const OutdatedEntry = struct {
    name: []u8,
    installed: []u8,
    latest: []u8,
};

/// Cached `mt outdated` result. Snapshot trades freshness for instant
/// startup so shell-prompt integrations don't pay an API round-trip per
/// shell. All slices are owned by the parser's allocator (or by the
/// caller, when assembling an in-memory snapshot from `OutdatedEntry`).
pub const Snapshot = struct {
    /// `std.time.milliTimestamp()` at the moment the snapshot was generated.
    generated_at_ms: i64,
    formulas: []const OutdatedEntry,
    casks: []const OutdatedEntry,
};

/// Parse the worker-count override env var. Anything non-positive or
/// non-numeric falls back to the default — matches the lenient style
/// the rest of the CLI uses for tuning knobs.
pub fn parseWorkersEnv(s: ?[]const u8) ?usize {
    const raw = s orelse return null;
    if (raw.len == 0) return null;
    const n = std.fmt.parseInt(usize, raw, 10) catch return null;
    if (n == 0) return null;
    return n;
}

/// Resolve the snapshot max-age threshold (in hours) from an env value.
/// Returns `null` for unset / empty / non-numeric so the caller can apply
/// `SNAPSHOT_DEFAULT_MAX_AGE_HOURS`; preserves an explicit `"0"` as `0`
/// so users who set the env to 0 actually get "always stale".
pub fn parseMaxAgeHoursEnv(s: ?[]const u8) ?u64 {
    const raw = s orelse return null;
    if (raw.len == 0) return null;
    return std.fmt.parseInt(u64, raw, 10) catch null;
}

/// True when `now_ms - generated_at_ms` exceeds the threshold. Future-
/// dated snapshots (clock skew) are treated as fresh — better than
/// surprising the user with a "stale" warning right after `mt update`.
pub fn isStale(generated_at_ms: i64, now_ms: i64, max_age_hours: u64) bool {
    if (now_ms <= generated_at_ms) return false;
    const age_ms: u64 = @intCast(now_ms - generated_at_ms);
    // Saturating multiply: a pathological env value (e.g. u64 max) folds
    // to "never stale" rather than wrapping to 0 and reporting fresh
    // snapshots as stale.
    const max_ms = std.math.mul(u64, max_age_hours, 60 * 60 * 1000) catch std.math.maxInt(u64);
    return age_ms > max_ms;
}

pub const RenderError = error{ OutOfMemory, WriteFailed };

/// Render `snap` as a UTF-8 JSON document. Caller owns the returned
/// slice. Shape: `{ "version": N, "generated_at_ms": ms, "formulas":
/// [...], "casks": [...] }` — small enough to stream, stable enough to
/// parse on a downgrade.
pub fn renderSnapshot(allocator: std.mem.Allocator, snap: Snapshot) RenderError![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.print("{{\"version\":{d},\"generated_at_ms\":{d},\"formulas\":[", .{ SNAPSHOT_VERSION, snap.generated_at_ms });
    for (snap.formulas, 0..) |e, i| {
        if (i != 0) try w.writeAll(",");
        try writeEntryJson(w, e);
    }
    try w.writeAll("],\"casks\":[");
    for (snap.casks, 0..) |e, i| {
        if (i != 0) try w.writeAll(",");
        try writeEntryJson(w, e);
    }
    try w.writeAll("]}");

    return aw.toOwnedSlice();
}

fn writeEntryJson(w: *std.Io.Writer, e: OutdatedEntry) !void {
    try w.writeAll("{\"name\":");
    try output.jsonStr(w, e.name);
    try w.writeAll(",\"installed\":");
    try output.jsonStr(w, e.installed);
    try w.writeAll(",\"latest\":");
    try output.jsonStr(w, e.latest);
    try w.writeAll("}");
}

/// Owned snapshot returned by `parseSnapshot`. Free with `freeSnapshot`.
/// Holds its own copy of every string so it outlives the parser arena.
pub const OwnedSnapshot = struct {
    generated_at_ms: i64,
    formulas: []OutdatedEntry,
    casks: []OutdatedEntry,
};

/// Per-string cap so a tampered snapshot can't push `std.json` into
/// an N-MiB allocation. Real names/versions are well under 256 bytes.
const snapshot_max_value_len: usize = 4 * 1024;

/// Typed schema avoids the `std.json.Value` tree; allocation is bounded
/// by the input size + the per-string cap above.
const SnapshotDoc = struct {
    version: u32,
    generated_at_ms: i64,
    formulas: []const EntryDoc,
    casks: []const EntryDoc,
};

const EntryDoc = struct {
    name: []const u8,
    installed: []const u8,
    latest: []const u8,
};

pub const SnapshotParseError = error{ InvalidSnapshot, OutOfMemory };

pub fn parseSnapshot(allocator: std.mem.Allocator, bytes: []const u8) SnapshotParseError!OwnedSnapshot {
    const opts: std.json.ParseOptions = .{
        .ignore_unknown_fields = true,
        .max_value_len = snapshot_max_value_len,
        // Force allocation so `max_value_len` applies to every string;
        // the default `.alloc_if_needed` borrows un-escaped values from
        // the input buffer and bypasses the cap.
        .allocate = .alloc_always,
    };
    const parsed = std.json.parseFromSlice(SnapshotDoc, allocator, bytes, opts) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSnapshot,
    };
    defer parsed.deinit();

    if (parsed.value.version != SNAPSHOT_VERSION) return error.InvalidSnapshot;

    const formulas = try dupEntryDocs(allocator, parsed.value.formulas);
    errdefer freeEntrySlice(allocator, formulas);
    const casks = try dupEntryDocs(allocator, parsed.value.casks);

    return .{
        .generated_at_ms = parsed.value.generated_at_ms,
        .formulas = formulas,
        .casks = casks,
    };
}

fn dupEntryDocs(
    allocator: std.mem.Allocator,
    docs: []const EntryDoc,
) std.mem.Allocator.Error![]OutdatedEntry {
    const out = try allocator.alloc(OutdatedEntry, docs.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |e| {
            allocator.free(e.name);
            allocator.free(e.installed);
            allocator.free(e.latest);
        }
        allocator.free(out);
    }
    for (docs) |d| {
        const name = try allocator.dupe(u8, d.name);
        errdefer allocator.free(name);
        const installed = try allocator.dupe(u8, d.installed);
        errdefer allocator.free(installed);
        const latest = try allocator.dupe(u8, d.latest);
        out[filled] = .{ .name = name, .installed = installed, .latest = latest };
        filled += 1;
    }
    return out;
}

fn freeEntrySlice(allocator: std.mem.Allocator, slice: []OutdatedEntry) void {
    for (slice) |e| {
        allocator.free(e.name);
        allocator.free(e.installed);
        allocator.free(e.latest);
    }
    allocator.free(slice);
}

/// Resolve the absolute snapshot path under `cache_dir`. Caller frees.
pub fn snapshotPath(allocator: std.mem.Allocator, cache_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ cache_dir, SNAPSHOT_FILE });
}

/// Atomically write `snap` to `{cache_dir}/outdated.json`. Creates the
/// cache dir if missing — `mt update --check` may run before any other
/// command has touched the cache.
pub fn writeSnapshot(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    snap: Snapshot,
) !void {
    // Best-effort: a real error here gets surfaced by atomicWriteFile below.
    fs_compat.cwd().makePath(cache_dir) catch {};

    const path = try snapshotPath(allocator, cache_dir);
    defer allocator.free(path);
    const json = try renderSnapshot(allocator, snap);
    defer allocator.free(json);
    try atomic.atomicWriteFile(path, json);
}

/// Realistic snapshots are tens of KiB; 1 MiB refuses any inflated file
/// before bytes reach `std.json`.
const snapshot_read_cap: usize = 1 * 1024 * 1024;

/// Read the snapshot at `{cache_dir}/outdated.json`. Snapshot trades
/// freshness for instant startup; on any read or parse failure we
/// return null so callers fall back to a live recompute.
pub fn readSnapshot(allocator: std.mem.Allocator, cache_dir: []const u8) ?OwnedSnapshot {
    const path = snapshotPath(allocator, cache_dir) catch return null;
    defer allocator.free(path);
    const bytes = fs_compat.readFileAbsoluteAlloc(allocator, path, snapshot_read_cap) catch return null;
    defer allocator.free(bytes);
    return parseSnapshot(allocator, bytes) catch null;
}

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

/// Recompute every outdated entry (formulas + casks) and overwrite the
/// snapshot at `{cache_dir}/outdated.json`. Best-effort: failures are
/// folded into the caller's `catch {}` so a snapshot write never blocks
/// the user-facing output that already succeeded.
pub fn refreshSnapshot(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    api: *api_mod.BrewApi,
    cache_dir: []const u8,
    workers_override: ?usize,
) !void {
    const formula_rows = try loadFormulaRows(allocator, db, .all);
    defer freeKegRows(allocator, formula_rows);
    const cask_rows = try loadCaskRows(allocator, db, .all);
    defer freeKegRows(allocator, cask_rows);

    const formulas = try collectOutdatedFormulas(allocator, api, cache_dir, formula_rows, workers_override);
    defer {
        for (formulas) |e| {
            allocator.free(e.name);
            allocator.free(e.installed);
            allocator.free(e.latest);
        }
        allocator.free(formulas);
    }
    const casks = try collectOutdatedCasks(allocator, api, cache_dir, cask_rows, workers_override);
    defer {
        for (casks) |e| {
            allocator.free(e.name);
            allocator.free(e.installed);
            allocator.free(e.latest);
        }
        allocator.free(casks);
    }

    try writeSnapshot(allocator, cache_dir, .{
        .generated_at_ms = fs_compat.milliTimestamp(),
        .formulas = formulas,
        .casks = casks,
    });
}

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

/// Free both arrays + every duped string in `snap`.
pub fn freeSnapshot(allocator: std.mem.Allocator, snap: OwnedSnapshot) void {
    freeEntrySlice(allocator, snap.formulas);
    freeEntrySlice(allocator, snap.casks);
}

/// Resolve the actual worker count for `jobs`. Capped at `jobs` so we
/// never spawn idle workers, and at the env override (or the default
/// ceiling) so we never starve the network.
pub fn outdatedWorkerCount(jobs: usize, env_override: ?usize) usize {
    const cap = env_override orelse OUTDATED_DEFAULT_WORKERS;
    return @min(cap, jobs);
}

/// Below this we keep the single-client serial path — the pool's
/// thread-spawn + HTTP-pool init overhead is not worth it for a
/// handful of round-trips.
pub fn shouldUsePool(jobs: usize) bool {
    return jobs >= OUTDATED_DEFAULT_WORKERS;
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

test "outdatedWorkerCount caps at the default for large N" {
    try std.testing.expectEqual(
        @as(usize, OUTDATED_DEFAULT_WORKERS),
        outdatedWorkerCount(50, null),
    );
}

test "outdatedWorkerCount returns N when N is below the default" {
    try std.testing.expectEqual(@as(usize, 3), outdatedWorkerCount(3, null));
    try std.testing.expectEqual(@as(usize, 0), outdatedWorkerCount(0, null));
}

test "outdatedWorkerCount respects env overrides above and below the default" {
    try std.testing.expectEqual(@as(usize, 4), outdatedWorkerCount(50, 4));
    // Power-user override: env wins over the default ceiling.
    try std.testing.expectEqual(@as(usize, 16), outdatedWorkerCount(50, 16));
}

test "shouldUsePool flips at the default-worker boundary" {
    try std.testing.expect(!shouldUsePool(0));
    try std.testing.expect(!shouldUsePool(OUTDATED_DEFAULT_WORKERS - 1));
    try std.testing.expect(shouldUsePool(OUTDATED_DEFAULT_WORKERS));
    try std.testing.expect(shouldUsePool(50));
}

test "parseWorkersEnv parses a positive integer" {
    try std.testing.expectEqual(@as(?usize, 4), parseWorkersEnv("4"));
    try std.testing.expectEqual(@as(?usize, 16), parseWorkersEnv("16"));
}

test "parseWorkersEnv rejects null, empty, zero, and non-numeric values" {
    try std.testing.expectEqual(@as(?usize, null), parseWorkersEnv(null));
    try std.testing.expectEqual(@as(?usize, null), parseWorkersEnv(""));
    try std.testing.expectEqual(@as(?usize, null), parseWorkersEnv("0"));
    try std.testing.expectEqual(@as(?usize, null), parseWorkersEnv("abc"));
    try std.testing.expectEqual(@as(?usize, null), parseWorkersEnv("-3"));
}

test "parseMaxAgeHoursEnv yields null for null/empty/garbage so callers default" {
    try std.testing.expectEqual(@as(?u64, null), parseMaxAgeHoursEnv(null));
    try std.testing.expectEqual(@as(?u64, null), parseMaxAgeHoursEnv(""));
    try std.testing.expectEqual(@as(?u64, null), parseMaxAgeHoursEnv("nope"));
    try std.testing.expectEqual(@as(?u64, null), parseMaxAgeHoursEnv("-3"));
}

test "parseMaxAgeHoursEnv preserves explicit 0 as 'always stale'" {
    // The user reaches for 0 to opt out of caching; treating it as
    // 'fall back to default' would silently re-enable the snapshot.
    try std.testing.expectEqual(@as(?u64, 0), parseMaxAgeHoursEnv("0"));
}

test "parseMaxAgeHoursEnv parses positive integers verbatim" {
    try std.testing.expectEqual(@as(?u64, 1), parseMaxAgeHoursEnv("1"));
    try std.testing.expectEqual(@as(?u64, 12), parseMaxAgeHoursEnv("12"));
    try std.testing.expectEqual(@as(?u64, 168), parseMaxAgeHoursEnv("168"));
}

test "renderSnapshot emits the canonical JSON shape" {
    const formulas = [_]OutdatedEntry{
        .{ .name = @constCast("alpha"), .installed = @constCast("1.0"), .latest = @constCast("2.0") },
    };
    const casks = [_]OutdatedEntry{
        .{ .name = @constCast("beta"), .installed = @constCast("3.0"), .latest = @constCast("3.5") },
    };
    const snap: Snapshot = .{
        .generated_at_ms = 1_700_000_000_000,
        .formulas = &formulas,
        .casks = &casks,
    };
    const json = try renderSnapshot(std.testing.allocator, snap);
    defer std.testing.allocator.free(json);

    const want =
        \\{"version":1,"generated_at_ms":1700000000000,"formulas":[{"name":"alpha","installed":"1.0","latest":"2.0"}],"casks":[{"name":"beta","installed":"3.0","latest":"3.5"}]}
    ;
    try std.testing.expectEqualStrings(want, json);
}

test "parseSnapshot round-trips a rendered snapshot" {
    const formulas = [_]OutdatedEntry{
        .{ .name = @constCast("alpha"), .installed = @constCast("1.0"), .latest = @constCast("2.0") },
        .{ .name = @constCast("bravo"), .installed = @constCast("3.0"), .latest = @constCast("3.5") },
    };
    const casks = [_]OutdatedEntry{
        .{ .name = @constCast("charlie"), .installed = @constCast("9.0"), .latest = @constCast("9.5") },
    };
    const snap: Snapshot = .{
        .generated_at_ms = 1_700_000_000_000,
        .formulas = &formulas,
        .casks = &casks,
    };
    const json = try renderSnapshot(std.testing.allocator, snap);
    defer std.testing.allocator.free(json);

    const parsed = try parseSnapshot(std.testing.allocator, json);
    defer freeSnapshot(std.testing.allocator, parsed);

    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), parsed.generated_at_ms);
    try std.testing.expectEqual(@as(usize, 2), parsed.formulas.len);
    try std.testing.expectEqualStrings("alpha", parsed.formulas[0].name);
    try std.testing.expectEqualStrings("1.0", parsed.formulas[0].installed);
    try std.testing.expectEqualStrings("2.0", parsed.formulas[0].latest);
    try std.testing.expectEqualStrings("bravo", parsed.formulas[1].name);
    try std.testing.expectEqual(@as(usize, 1), parsed.casks.len);
    try std.testing.expectEqualStrings("charlie", parsed.casks[0].name);
    try std.testing.expectEqualStrings("9.5", parsed.casks[0].latest);
}

test "parseSnapshot rejects mismatched version, missing fields, garbage" {
    try std.testing.expectError(error.InvalidSnapshot, parseSnapshot(std.testing.allocator, ""));
    try std.testing.expectError(error.InvalidSnapshot, parseSnapshot(std.testing.allocator, "not-json"));
    // Future schema version: refuse rather than guess.
    try std.testing.expectError(
        error.InvalidSnapshot,
        parseSnapshot(std.testing.allocator, "{\"version\":99,\"generated_at_ms\":0,\"formulas\":[],\"casks\":[]}"),
    );
    // Missing required field.
    try std.testing.expectError(
        error.InvalidSnapshot,
        parseSnapshot(std.testing.allocator, "{\"version\":1,\"formulas\":[],\"casks\":[]}"),
    );
    // Wrong type for formulas.
    try std.testing.expectError(
        error.InvalidSnapshot,
        parseSnapshot(std.testing.allocator, "{\"version\":1,\"generated_at_ms\":0,\"formulas\":\"x\",\"casks\":[]}"),
    );
}

test "parseSnapshot bounds per-string allocation against tampered input" {
    // Build a JSON document with a single name field exceeding the
    // per-value cap. The typed parser must reject it without inflating
    // memory to the size of the malicious string.
    const oversized_len = snapshot_max_value_len + 1;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, "{\"version\":1,\"generated_at_ms\":0,\"formulas\":[{\"name\":\"");
    try buf.appendNTimes(std.testing.allocator, 'a', oversized_len);
    try buf.appendSlice(std.testing.allocator, "\",\"installed\":\"1\",\"latest\":\"2\"}],\"casks\":[]}");

    try std.testing.expectError(
        error.InvalidSnapshot,
        parseSnapshot(std.testing.allocator, buf.items),
    );
}

test "parseSnapshot tolerates unknown forward-compatible fields" {
    // Adding a field server-side shouldn't invalidate existing snapshots.
    const json =
        \\{"version":1,"generated_at_ms":0,"formulas":[],"casks":[],"future":42}
    ;
    const parsed = try parseSnapshot(std.testing.allocator, json);
    defer freeSnapshot(std.testing.allocator, parsed);
    try std.testing.expectEqual(@as(usize, 0), parsed.formulas.len);
}

test "renderSnapshot handles empty formula and cask lists" {
    const snap: Snapshot = .{
        .generated_at_ms = 0,
        .formulas = &[_]OutdatedEntry{},
        .casks = &[_]OutdatedEntry{},
    };
    const json = try renderSnapshot(std.testing.allocator, snap);
    defer std.testing.allocator.free(json);

    const want =
        \\{"version":1,"generated_at_ms":0,"formulas":[],"casks":[]}
    ;
    try std.testing.expectEqualStrings(want, json);
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

test "isStale flips at the max-age boundary in milliseconds" {
    const hour_ms: i64 = 60 * 60 * 1000;
    // Same instant -> fresh.
    try std.testing.expect(!isStale(0, 0, 24));
    // Exactly at the boundary -> still fresh.
    try std.testing.expect(!isStale(0, 24 * hour_ms, 24));
    // One ms past the boundary -> stale.
    try std.testing.expect(isStale(0, 24 * hour_ms + 1, 24));
    // Future-dated snapshot (clock skew) -> treated as fresh.
    try std.testing.expect(!isStale(100 * hour_ms, 0, 24));
    // Custom threshold honoured.
    try std.testing.expect(isStale(0, 2 * hour_ms, 1));
    try std.testing.expect(!isStale(0, 1 * hour_ms, 2));
}

test "isStale with max_age_hours == 0 marks any non-zero age as stale" {
    try std.testing.expect(!isStale(0, 0, 0));
    try std.testing.expect(isStale(0, 1, 0));
}

test "isStale folds a u64-overflowing threshold to 'never stale'" {
    // A pathological MALT_OUTDATED_MAX_AGE shouldn't wrap to 0 ms and
    // report otherwise-fresh snapshots as stale.
    try std.testing.expect(!isStale(0, std.math.maxInt(i64), std.math.maxInt(u64)));
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

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "outdated")) return;

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
    var stdout_fw = io_mod.stdoutFile().writer(io_mod.ctx(), &stdout_buf);
    const stdout: *std.Io.Writer = &stdout_fw.interface;
    // Flush on teardown; stdout closed by a broken pipe is normal shell usage.
    defer stdout.flush() catch {};

    const prefix = atomic.maltPrefix();
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return;
    var db = sqlite.Database.open(db_path) catch {
        // Fresh prefix: nothing installed = nothing to be outdated.
        return;
    };
    defer db.close();
    schema.initSchema(&db) catch return;

    const max_age_hours = parseMaxAgeHoursEnv(fs_compat.getenv(SNAPSHOT_MAX_AGE_ENV)) orelse
        SNAPSHOT_DEFAULT_MAX_AGE_HOURS;
    const snap_opt = readSnapshot(allocator, cache_dir);
    defer if (snap_opt) |s| freeSnapshot(allocator, s);

    const plan = planEmit(
        args,
        snap_opt != null,
        if (snap_opt) |s| s.generated_at_ms else 0,
        fs_compat.milliTimestamp(),
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
        .recompute => try recomputeAndEmit(allocator, &db, cache_dir, stdout, json_mode, .{
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
        try writeFormulaEntries(allocator, stdout, filtered, json_mode);
        formula_count = filtered.len;
    }
    if (!scope.formula_only) {
        const rows = try loadCaskRows(allocator, db, .all);
        defer freeKegRows(allocator, rows);
        const filtered = try intersectWithDb(allocator, rows, snap.casks);
        defer freeEntrySlice(allocator, filtered);
        try writeCaskEntries(stdout, filtered, json_mode);
        cask_count = filtered.len;
    }

    if (!json_mode) {
        if (summaryMessage(formula_count, cask_count, scope.formula_only, scope.cask_only)) |msg| {
            output.info("{s}", .{msg});
        }
    }
}

fn recomputeAndEmit(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    cache_dir: []const u8,
    stdout: *std.Io.Writer,
    json_mode: bool,
    scope: ScopeFlags,
) !void {
    var http = client_mod.HttpClient.init(allocator);
    defer http.deinit();
    var api = api_mod.BrewApi.init(allocator, &http, cache_dir);

    const workers_override = parseWorkersEnv(fs_compat.getenv(OUTDATED_WORKERS_ENV));

    var formula_count: usize = 0;
    var cask_count: usize = 0;
    if (!scope.cask_only) {
        const filter: KegFilter = if (scope.pinned_only) .pinned_only else .all;
        formula_count = try emitOutdatedFormulas(allocator, db, &api, cache_dir, workers_override, stdout, json_mode, filter);
    }
    if (!scope.formula_only) {
        const filter: KegFilter = if (scope.pinned_only) .pinned_only else .all;
        cask_count = try emitOutdatedCasks(allocator, db, &api, cache_dir, workers_override, stdout, json_mode, filter);
    }
    // Refresh the snapshot only when we walked the full keg set; a
    // partial recompute would mislead the next reader. Best-effort:
    // a write failure shouldn't shadow the listing the user already saw.
    if (!scope.pinned_only and !scope.cask_only and !scope.formula_only) {
        refreshSnapshot(allocator, db, &api, cache_dir, workers_override) catch {};
    }

    if (!json_mode) {
        if (summaryMessage(formula_count, cask_count, scope.formula_only, scope.cask_only)) |msg| {
            output.info("{s}", .{msg});
        }
    }
}

/// Load installed formula rows, optionally narrowed to pinned-only.
/// Caller frees with `freeKegRows`. Exposed for tests + the audit path
/// in `cli/upgrade`; both want the same SQL choice.
pub fn loadFormulaRows(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    filter: KegFilter,
) ![]KegRow {
    const sql: [:0]const u8 = switch (filter) {
        .all => "SELECT name, version FROM kegs ORDER BY name;",
        .pinned_only => "SELECT name, version FROM kegs WHERE pinned = 1 ORDER BY name;",
    };
    return loadKegRows(allocator, db, sql);
}

/// Cask sibling of `loadFormulaRows`. Same lifetime contract; pinned
/// filter swaps in `WHERE pinned = 1` so `--pinned-only` walks the
/// pinned-cask audit path symmetrically with formulas.
pub fn loadCaskRows(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    filter: KegFilter,
) ![]KegRow {
    const sql: [:0]const u8 = switch (filter) {
        .all => "SELECT token, version FROM casks ORDER BY token;",
        .pinned_only => "SELECT token, version FROM casks WHERE pinned = 1 ORDER BY token;",
    };
    return loadKegRows(allocator, db, sql);
}

/// Caller-side free for any rows returned by `loadFormulaRows` /
/// `loadCaskRows`. Pairs with the allocator passed in.
pub fn freeKegRows(allocator: std.mem.Allocator, rows: []KegRow) void {
    for (rows) |r| {
        allocator.free(r.name);
        allocator.free(r.version);
    }
    allocator.free(rows);
}

fn loadKegRows(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    sql: [:0]const u8,
) ![]KegRow {
    var stmt = db.prepare(sql) catch return &.{};
    defer stmt.finalize();

    var rows: std.ArrayList(KegRow) = .empty;
    errdefer {
        for (rows.items) |r| {
            allocator.free(r.name);
            allocator.free(r.version);
        }
        rows.deinit(allocator);
    }
    while (stmt.step() catch false) {
        const name_ptr = stmt.columnText(0) orelse continue;
        const ver_ptr = stmt.columnText(1);
        const name_slice = std.mem.sliceTo(name_ptr, 0);
        const ver_slice = if (ver_ptr) |v| std.mem.sliceTo(v, 0) else "0";
        const name_dup = try allocator.dupe(u8, name_slice);
        errdefer allocator.free(name_dup);
        const ver_dup = try allocator.dupe(u8, ver_slice);
        try rows.append(allocator, .{ .name = name_dup, .version = ver_dup });
    }
    return rows.toOwnedSlice(allocator);
}

fn emitOutdatedFormulas(
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

    const entries = try collectOutdatedFormulas(allocator, api, cache_dir, rows, workers_override);
    defer freeEntries(allocator, entries);

    try writeFormulaEntries(allocator, stdout, entries, json_mode);
    return entries.len;
}

fn emitOutdatedCasks(
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

    const entries = try collectOutdatedCasks(allocator, api, cache_dir, rows, workers_override);
    defer freeEntries(allocator, entries);

    try writeCaskEntries(stdout, entries, json_mode);
    return entries.len;
}

fn freeEntries(allocator: std.mem.Allocator, entries: []OutdatedEntry) void {
    for (entries) |e| {
        allocator.free(e.name);
        allocator.free(e.installed);
        allocator.free(e.latest);
    }
    allocator.free(entries);
}

fn writeFormulaEntries(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    entries: []const OutdatedEntry,
    json_mode: bool,
) !void {
    if (json_mode) {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("[");
        for (entries, 0..) |e, i| {
            if (i != 0) try w.writeAll(",");
            try w.writeAll("{\"name\":");
            try output.jsonStr(w, e.name);
            try w.writeAll(",\"installed\":");
            try output.jsonStr(w, e.installed);
            try w.writeAll(",\"latest\":");
            try output.jsonStr(w, e.latest);
            try w.writeAll(",\"type\":\"formula\"}");
        }
        try w.writeAll("]\n");
        stdout.writeAll(aw.written()) catch return;
        return;
    }

    for (entries) |e| writeEntry(stdout, e, null);
}

fn writeCaskEntries(
    stdout: *std.Io.Writer,
    entries: []const OutdatedEntry,
    json_mode: bool,
) !void {
    if (json_mode) {
        for (entries) |e| {
            stdout.writeAll("{\"name\":") catch continue;
            output.jsonStr(stdout, e.name) catch continue;
            stdout.writeAll(",\"installed\":") catch continue;
            output.jsonStr(stdout, e.installed) catch continue;
            stdout.writeAll(",\"latest\":") catch continue;
            output.jsonStr(stdout, e.latest) catch continue;
            stdout.writeAll(",\"type\":\"cask\"}\n") catch continue;
        }
        return;
    }

    for (entries) |e| writeEntry(stdout, e, "cask");
}

/// Match the `mt list` / `mt search` row shape: cyan bullet, plain
/// name, dimmed `(installed)`, warn-coloured `< latest`, and an
/// optional dim `[kind]` tag for casks. Honours `NO_COLOR` / pipes
/// automatically via `color.isColorEnabled()`.
fn writeEntry(stdout: *std.Io.Writer, e: OutdatedEntry, kind_tag: ?[]const u8) void {
    if (output.isQuiet()) {
        stdout.writeAll(e.name) catch return;
        stdout.writeAll("\n") catch return;
        return;
    }

    writeBullet(stdout);
    stdout.writeAll(e.name) catch return;
    writeStyledSpan(stdout, color.SemanticStyle.detail.code(), " (", e.installed, ")");
    writeStyledSpan(stdout, color.SemanticStyle.warn.code(), " < ", e.latest, "");
    if (kind_tag) |t| writeStyledSpan(stdout, color.SemanticStyle.detail.code(), " [", t, "]");
    stdout.writeAll("\n") catch return;
}

fn writeBullet(stdout: *std.Io.Writer) void {
    if (color.isColorEnabled()) {
        stdout.writeAll(color.SemanticStyle.info.code()) catch return;
        stdout.writeAll("  \xe2\x96\xb8 ") catch return;
        stdout.writeAll(color.Style.reset.code()) catch return;
    } else {
        stdout.writeAll("  \xe2\x96\xb8 ") catch return;
    }
}

fn writeStyledSpan(
    stdout: *std.Io.Writer,
    style_code: []const u8,
    open: []const u8,
    body: []const u8,
    close: []const u8,
) void {
    const use_color = color.isColorEnabled();
    if (use_color) stdout.writeAll(style_code) catch return;
    stdout.writeAll(open) catch return;
    stdout.writeAll(body) catch return;
    stdout.writeAll(close) catch return;
    if (use_color) stdout.writeAll(color.Style.reset.code()) catch return;
}

/// Compute outdated formulas for `kegs`. Sort order follows `kegs` —
/// callers query the DB with `ORDER BY name`. Per-row API failures or
/// 404s drop silently (matches the old serial behaviour).
pub fn collectOutdatedFormulas(
    allocator: std.mem.Allocator,
    api: *api_mod.BrewApi,
    cache_dir: []const u8,
    kegs: []const KegRow,
    workers_override: ?usize,
) std.mem.Allocator.Error![]OutdatedEntry {
    return collectOutdated(allocator, api, cache_dir, kegs, workers_override, .formula);
}

/// Cask sibling of `collectOutdatedFormulas`. Same lifetime contract.
pub fn collectOutdatedCasks(
    allocator: std.mem.Allocator,
    api: *api_mod.BrewApi,
    cache_dir: []const u8,
    kegs: []const KegRow,
    workers_override: ?usize,
) std.mem.Allocator.Error![]OutdatedEntry {
    return collectOutdated(allocator, api, cache_dir, kegs, workers_override, .cask);
}

const Kind = enum { formula, cask };

fn collectOutdated(
    allocator: std.mem.Allocator,
    api: *api_mod.BrewApi,
    cache_dir: []const u8,
    kegs: []const KegRow,
    workers_override: ?usize,
    kind: Kind,
) std.mem.Allocator.Error![]OutdatedEntry {
    if (kegs.len == 0) return allocator.alloc(OutdatedEntry, 0);

    // Per-row latest-version slot. Workers fill `latest_versions[i]`
    // with a caller-allocator-owned string when row `i` is outdated;
    // null otherwise. Indexed-write keeps the pool free of locks.
    const latest_versions = try allocator.alloc(?[]u8, kegs.len);
    defer allocator.free(latest_versions);
    @memset(latest_versions, null);
    errdefer for (latest_versions) |maybe| {
        if (maybe) |v| allocator.free(v);
    };

    if (!shouldUsePool(kegs.len)) {
        for (kegs, 0..) |row, i| {
            latest_versions[i] = try fetchLatest(allocator, api, kind, row);
        }
    } else {
        try runPool(allocator, cache_dir, kegs, workers_override, kind, latest_versions);
    }

    return assembleEntries(allocator, kegs, latest_versions);
}

fn assembleEntries(
    allocator: std.mem.Allocator,
    kegs: []const KegRow,
    latest_versions: []?[]u8,
) std.mem.Allocator.Error![]OutdatedEntry {
    var out: std.ArrayList(OutdatedEntry) = try .initCapacity(allocator, kegs.len);
    errdefer {
        for (out.items) |e| {
            allocator.free(e.name);
            allocator.free(e.installed);
            allocator.free(e.latest);
        }
        out.deinit(allocator);
    }

    for (kegs, 0..) |row, i| {
        const latest = latest_versions[i] orelse continue;
        // Hand ownership of `latest` over to the entry; clear the
        // slot so the errdefer above doesn't double-free it.
        latest_versions[i] = null;
        errdefer allocator.free(latest);

        const name_dup = try allocator.dupe(u8, row.name);
        errdefer allocator.free(name_dup);
        const installed_dup = try allocator.dupe(u8, row.version);

        try out.append(allocator, .{
            .name = name_dup,
            .installed = installed_dup,
            .latest = latest,
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Fetch + parse the upstream latest version for `name` onto `alloc`.
/// Best-effort: network or parse failures collapse to null. Shared by
/// the serial and pool paths so the JSON-shape logic lives once.
fn upstreamLatest(
    alloc: std.mem.Allocator,
    api: *api_mod.BrewApi,
    kind: Kind,
    name: []const u8,
) ?[]u8 {
    return switch (kind) {
        .formula => blk: {
            const json = api.fetchFormula(name) catch break :blk null;
            defer alloc.free(json);
            break :blk parseFormulaLatest(alloc, json);
        },
        .cask => blk: {
            const json = api.fetchCask(name) catch break :blk null;
            defer alloc.free(json);
            var cask = cask_mod.parseCask(alloc, json) catch break :blk null;
            defer cask.deinit();
            break :blk alloc.dupe(u8, cask.version) catch null;
        },
    };
}

/// Serial-path single-row check. Returns a caller-owned latest-version
/// string if `row` is outdated, null otherwise.
fn fetchLatest(
    allocator: std.mem.Allocator,
    api: *api_mod.BrewApi,
    kind: Kind,
    row: KegRow,
) std.mem.Allocator.Error!?[]u8 {
    const v = upstreamLatest(allocator, api, kind, row.name) orelse return null;
    if (std.mem.eql(u8, row.version, v)) {
        allocator.free(v);
        return null;
    }
    return v;
}

/// Pull `versions.stable` out of a Homebrew formula JSON document.
/// Returns a fresh caller-owned copy or null if the field is missing /
/// the document is malformed.
fn parseFormulaLatest(allocator: std.mem.Allocator, json_bytes: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const versions_val = obj.get("versions") orelse return null;
    const versions_obj = switch (versions_val) {
        .object => |o| o,
        else => return null,
    };
    const stable_val = versions_obj.get("stable") orelse return null;
    return switch (stable_val) {
        .string => |s| allocator.dupe(u8, s) catch null,
        else => null,
    };
}

// --- Pool path ---

const WorkerCtx = struct {
    arena: std.heap.ArenaAllocator,
    pool: *client_mod.HttpClientPool,
    cache_dir: []const u8,
    row: KegRow,
    kind: Kind,
    /// Result allocated on the **caller** allocator so it survives
    /// arena teardown. Null = up-to-date or fetch failed.
    out: ?[]u8 = null,
    /// Out-of-memory from caller-allocator dupe; surfaced after join.
    /// Other failures stay silent to match the serial behaviour.
    err: ?std.mem.Allocator.Error = null,
};

const PoolState = struct {
    next_idx: std.atomic.Value(usize),
    ctxs: []WorkerCtx,
    out_allocator: std.mem.Allocator,
};

fn poolWorker(state: *PoolState) void {
    while (true) {
        const idx = state.next_idx.fetchAdd(1, .acq_rel);
        if (idx >= state.ctxs.len) return;
        const ctx = &state.ctxs[idx];
        runOne(state.out_allocator, ctx);
    }
}

fn runOne(out_alloc: std.mem.Allocator, ctx: *WorkerCtx) void {
    const http = ctx.pool.acquire();
    defer ctx.pool.release(http);

    const arena_alloc = ctx.arena.allocator();
    var local_api = api_mod.BrewApi.init(arena_alloc, http, ctx.cache_dir);
    const latest = upstreamLatest(arena_alloc, &local_api, ctx.kind, ctx.row.name) orelse return;
    if (std.mem.eql(u8, ctx.row.version, latest)) return;

    // Move into the caller's allocator so the result outlives `arena.deinit()`.
    ctx.out = out_alloc.dupe(u8, latest) catch |e| blk: {
        ctx.err = e;
        break :blk null;
    };
}

fn runPool(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    kegs: []const KegRow,
    workers_override: ?usize,
    kind: Kind,
    latest_versions: []?[]u8,
) std.mem.Allocator.Error!void {
    const worker_count = outdatedWorkerCount(kegs.len, workers_override);
    std.debug.assert(worker_count > 0);

    var http_pool = try client_mod.HttpClientPool.init(allocator, worker_count);
    defer http_pool.deinit();

    const ctxs = try allocator.alloc(WorkerCtx, kegs.len);
    defer {
        for (ctxs) |*c| c.arena.deinit();
        allocator.free(ctxs);
    }
    for (ctxs, 0..) |*c, i| c.* = .{
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .pool = &http_pool,
        .cache_dir = cache_dir,
        .row = kegs[i],
        .kind = kind,
    };

    var state: PoolState = .{
        .next_idx = std.atomic.Value(usize).init(0),
        .ctxs = ctxs,
        .out_allocator = allocator,
    };

    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);

    var spawned: usize = 0;
    for (0..worker_count) |_| {
        if (std.Thread.spawn(.{}, poolWorker, .{&state})) |t| {
            threads[spawned] = t;
            spawned += 1;
        } else |_| {
            // Spawn failure: drain remaining work inline on this thread.
            poolWorker(&state);
        }
    }
    for (threads[0..spawned]) |t| t.join();

    // Move every successful out into the caller's slot first so the
    // caller's errdefer can free partial-success memory if we then
    // surface a worker OOM.
    for (ctxs, 0..) |c, i| {
        latest_versions[i] = c.out;
    }
    for (ctxs) |c| {
        if (c.err) |e| return e;
    }
}
