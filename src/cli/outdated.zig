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
    // `--pinned-only` covers both formulas and casks now that the casks
    // table has its own `pinned` column. The flag narrows the rows each
    // section loads, but does not narrow the scope.
    // `--json` and `--quiet` are stripped by the global parser in main.zig.
    const json_mode = output.isJson();

    // Open DB
    const prefix = atomic.maltPrefix();
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return;
    var db = sqlite.Database.open(db_path) catch {
        // Fresh prefix: nothing installed = nothing to be outdated.
        return;
    };
    defer db.close();
    schema.initSchema(&db) catch return;

    const cache_dir = atomic.maltCacheDir(allocator) catch {
        output.err("Failed to determine cache directory", .{});
        return error.Aborted;
    };
    defer allocator.free(cache_dir);

    var http = client_mod.HttpClient.init(allocator);
    defer http.deinit();
    var api = api_mod.BrewApi.init(allocator, &http, cache_dir);

    const workers_override = parseWorkersEnv(fs_compat.getenv(OUTDATED_WORKERS_ENV));

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = io_mod.stdoutFile().writer(io_mod.ctx(), &stdout_buf);
    const stdout: *std.Io.Writer = &stdout_fw.interface;
    // Flush on teardown; stdout closed by a broken pipe is normal shell usage.
    defer stdout.flush() catch {};

    var formula_count: usize = 0;
    var cask_count: usize = 0;
    if (!cask_only) {
        const filter: KegFilter = if (pinned_only) .pinned_only else .all;
        formula_count = try emitOutdatedFormulas(allocator, &db, &api, cache_dir, workers_override, stdout, json_mode, filter);
    }
    if (!formula_only) {
        const filter: KegFilter = if (pinned_only) .pinned_only else .all;
        cask_count = try emitOutdatedCasks(allocator, &db, &api, cache_dir, workers_override, stdout, json_mode, filter);
    }

    // Single end-of-run summary so we never print "All casks are up to
    // date" next to a list of outdated formulas. Suppressed in JSON
    // mode and under `--quiet` (handled by `output.info`).
    if (!json_mode) {
        if (summaryMessage(formula_count, cask_count, formula_only, cask_only)) |msg| {
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
