//! Microbench for the outdated-snapshot hot path.
//!
//! Times the three operations on the snapshot read path —
//! `renderSnapshot`, `parseSnapshot`, `intersectWithDb` — across a
//! synthetic dataset sized to match a heavily-installed machine.
//!
//! Run via `just bench-snapshot`. Asserts a hard per-op budget so a
//! regression breaks the bench rather than slipping into a release.

const std = @import("std");
const malt = @import("malt");
const outdated = malt.cli_outdated;
const fs_compat = malt.fs_compat;

fn nowNs() u64 {
    return @intCast(fs_compat.nanoTimestamp());
}

/// Realistic upper bound for an active developer machine.
const N_FORMULAS: usize = 500;
/// 10% outdated is a generous worst case; most prefixes have far fewer.
const N_OUTDATED: usize = 50;
const N_CASKS: usize = 100;
const N_OUTDATED_CASKS: usize = 10;

/// Iterations per phase. Picked so each phase runs well past 100 ms on
/// the slowest realistic hardware, so the median + p95 are meaningful.
const ITERS: usize = 200;

/// Hard budgets — anything above these on a quiet macOS machine is a
/// regression worth investigating. Generous enough to absorb CI noise.
const BUDGET_RENDER_NS: u64 = 5 * std.time.ns_per_ms;
const BUDGET_PARSE_NS: u64 = 10 * std.time.ns_per_ms;
const BUDGET_INTERSECT_NS: u64 = 1 * std.time.ns_per_ms;

const Stat = struct {
    median_ns: u64,
    p95_ns: u64,
    min_ns: u64,
    max_ns: u64,
};

fn computeStat(samples: []u64) Stat {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const median = samples[samples.len / 2];
    const p95_idx = (samples.len * 95) / 100;
    return .{
        .median_ns = median,
        .p95_ns = samples[p95_idx],
        .min_ns = samples[0],
        .max_ns = samples[samples.len - 1],
    };
}

fn printStat(name: []const u8, s: Stat, budget_ns: u64) void {
    const ok = if (s.median_ns <= budget_ns) "OK" else "OVER";
    std.debug.print(
        "  {s:<14}  median={d:>7}us  p95={d:>7}us  min={d:>7}us  max={d:>7}us  budget={d:>5}us [{s}]\n",
        .{
            name,
            s.median_ns / std.time.ns_per_us,
            s.p95_ns / std.time.ns_per_us,
            s.min_ns / std.time.ns_per_us,
            s.max_ns / std.time.ns_per_us,
            budget_ns / std.time.ns_per_us,
            ok,
        },
    );
}

fn buildSyntheticEntries(
    arena: std.mem.Allocator,
    count: usize,
    name_prefix: []const u8,
) ![]outdated.OutdatedEntry {
    const out = try arena.alloc(outdated.OutdatedEntry, count);
    for (out, 0..) |*e, i| {
        e.* = .{
            .name = try std.fmt.allocPrint(arena, "{s}{d:0>4}", .{ name_prefix, i }),
            .installed = try arena.dupe(u8, "1.0.0"),
            .latest = try arena.dupe(u8, "2.0.0"),
        };
    }
    return out;
}

fn buildDbRows(
    arena: std.mem.Allocator,
    total: usize,
    name_prefix: []const u8,
) ![]outdated.KegRow {
    const out = try arena.alloc(outdated.KegRow, total);
    for (out, 0..) |*r, i| {
        r.* = .{
            .name = try std.fmt.allocPrint(arena, "{s}{d:0>4}", .{ name_prefix, i }),
            .version = "1.0.0",
        };
    }
    return out;
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    std.debug.print(
        "snapshot_bench: N_FORMULAS={d} (outdated={d}), N_CASKS={d} (outdated={d}), iters={d}\n\n",
        .{ N_FORMULAS, N_OUTDATED, N_CASKS, N_OUTDATED_CASKS, ITERS },
    );

    const formulas = try buildSyntheticEntries(arena, N_OUTDATED, "f");
    const casks = try buildSyntheticEntries(arena, N_OUTDATED_CASKS, "c");
    const db_formula_rows = try buildDbRows(arena, N_FORMULAS, "f");
    const db_cask_rows = try buildDbRows(arena, N_CASKS, "c");

    const snap: outdated.Snapshot = .{
        .generated_at_ms = 0,
        .formulas = formulas,
        .casks = casks,
    };

    // Warm the page cache + branch predictors.
    {
        const j = try outdated.renderSnapshot(alloc, snap);
        defer alloc.free(j);
        const p = try outdated.parseSnapshot(alloc, j);
        defer outdated.freeSnapshot(alloc, p);
        const f = try outdated.intersectWithDb(alloc, db_formula_rows, p.formulas);
        defer freeEntrySlice(alloc, f);
    }

    const samples = try arena.alloc(u64, ITERS);

    // --- renderSnapshot ---
    for (samples) |*s| {
        const t0 = nowNs();
        const j = try outdated.renderSnapshot(alloc, snap);
        s.* = nowNs() - t0;
        alloc.free(j);
    }
    const render_stat = computeStat(samples);

    // Render once for the parse + intersect phases.
    const json = try outdated.renderSnapshot(alloc, snap);
    defer alloc.free(json);

    // --- parseSnapshot ---
    for (samples) |*s| {
        const t0 = nowNs();
        const p = try outdated.parseSnapshot(alloc, json);
        s.* = nowNs() - t0;
        outdated.freeSnapshot(alloc, p);
    }
    const parse_stat = computeStat(samples);

    // Parse once for the intersect phase.
    const parsed = try outdated.parseSnapshot(alloc, json);
    defer outdated.freeSnapshot(alloc, parsed);

    // --- intersectWithDb (formulas: 500 DB rows × 50 snapshot entries) ---
    for (samples) |*s| {
        const t0 = nowNs();
        const f = try outdated.intersectWithDb(alloc, db_formula_rows, parsed.formulas);
        s.* = nowNs() - t0;
        freeEntrySlice(alloc, f);
    }
    const intersect_stat = computeStat(samples);

    // --- intersectWithDb (casks) ---
    for (samples) |*s| {
        const t0 = nowNs();
        const c = try outdated.intersectWithDb(alloc, db_cask_rows, parsed.casks);
        s.* = nowNs() - t0;
        freeEntrySlice(alloc, c);
    }
    const intersect_cask_stat = computeStat(samples);

    std.debug.print("phase            median       p95         min         max         budget   status\n", .{});
    std.debug.print("---------------  ----------  ----------  ----------  ----------  -------  ------\n", .{});
    printStat("render", render_stat, BUDGET_RENDER_NS);
    printStat("parse", parse_stat, BUDGET_PARSE_NS);
    printStat("intersect.f", intersect_stat, BUDGET_INTERSECT_NS);
    printStat("intersect.c", intersect_cask_stat, BUDGET_INTERSECT_NS);

    var over_budget = false;
    if (render_stat.median_ns > BUDGET_RENDER_NS) over_budget = true;
    if (parse_stat.median_ns > BUDGET_PARSE_NS) over_budget = true;
    if (intersect_stat.median_ns > BUDGET_INTERSECT_NS) over_budget = true;
    if (intersect_cask_stat.median_ns > BUDGET_INTERSECT_NS) over_budget = true;

    if (over_budget) {
        std.debug.print("\nFAIL: at least one phase exceeded its budget.\n", .{});
        std.process.exit(1);
    }
    std.debug.print("\nOK: all phases within budget.\n", .{});
}

fn freeEntrySlice(allocator: std.mem.Allocator, slice: []outdated.OutdatedEntry) void {
    for (slice) |e| {
        allocator.free(e.name);
        allocator.free(e.installed);
        allocator.free(e.latest);
    }
    allocator.free(slice);
}
