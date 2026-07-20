//! malt — outdated refresh pipeline
//!
//! Live-audit machinery for `mt outdated` and `mt update --check`:
//! a bounded thread pool fetches the upstream latest for each
//! installed keg, the orchestrator stitches the diff together, and
//! `refreshSnapshot` writes the cached `outdated.json` so subsequent
//! invocations stay instant.

const std = @import("std");

const AppCtx = @import("../../app_ctx.zig").AppCtx;
const cask_mod = @import("../../core/cask.zig");
const formula_mod = @import("../../core/formula.zig");
const tap_mod = @import("../../core/tap.zig");
const forge = @import("../../core/forge.zig");
const sqlite = @import("../../db/sqlite.zig");
const api_mod = @import("../../net/api.zig");
const client_mod = @import("../../net/client.zig");
const pool_mod = @import("../../net/client_pool.zig");
const output = @import("../../ui/output.zig");
const install_args_mod = @import("../install/args.zig");
const install_rb_parse_mod = @import("../install/rb_parse.zig");
const rows_mod = @import("rows.zig");
const KegRow = rows_mod.KegRow;
const snap_mod = @import("snapshot.zig");
const OutdatedEntry = snap_mod.OutdatedEntry;

/// Default ceiling on concurrent API fetches. One round-trip per keg
/// dominates `mt outdated` on machines with many installed packages, so
/// we hand the work to a bounded pool the same way `cli/install` and
/// `cli/search` do.
pub const outdated_default_workers: usize = 8;

/// Env var that lets users tune the pool size (e.g. crank it on a fat
/// uplink, or lower it to one to reproduce serial behaviour).
pub const outdated_workers_env = "MALT_OUTDATED_WORKERS";

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
    const cap = env_override orelse outdated_default_workers;
    return @min(cap, jobs);
}

/// Below this we keep the single-client serial path — the pool's
/// thread-spawn + HTTP-pool init overhead is not worth it for a
/// handful of round-trips.
pub fn shouldUsePool(jobs: usize) bool {
    return jobs >= outdated_default_workers;
}

/// Recompute every outdated entry (formulas + casks) and overwrite the
/// snapshot at `{cache_dir}/outdated.json`. Best-effort: failures are
/// folded into the caller's `catch {}` so a snapshot write never blocks
/// the user-facing output that already succeeded.
pub fn refreshSnapshot(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    api: *api_mod.BrewApi,
    cache_dir: []const u8,
    workers_override: ?usize,
) !void {
    const formula_rows = try rows_mod.loadFormulaRows(allocator, db, .all);
    defer rows_mod.freeKegRows(allocator, formula_rows);
    const cask_rows = try rows_mod.loadCaskRows(allocator, db, .all);
    defer rows_mod.freeKegRows(allocator, cask_rows);

    const formulas = try collectOutdatedFormulas(ctx, allocator, db, api, cache_dir, formula_rows, workers_override);
    defer {
        for (formulas) |e| {
            allocator.free(e.name);
            allocator.free(e.installed);
            allocator.free(e.latest);
        }
        allocator.free(formulas);
    }
    const casks = try collectOutdatedCasks(ctx, allocator, db, api, cache_dir, cask_rows, workers_override);
    defer {
        for (casks) |e| {
            allocator.free(e.name);
            allocator.free(e.installed);
            allocator.free(e.latest);
        }
        allocator.free(casks);
    }

    try writeSnapshotEntries(ctx, allocator, cache_dir, formulas, casks);
}

/// Stamp `now` and write the snapshot from entries already in hand — the
/// single home for the outdated snapshot's timestamp policy and shape.
/// Callers must pass a *full* keg-set audit (formulas + casks): the write is
/// unconditional, so a narrowed audit here would persist a partial snapshot
/// and make the Outdated view silently under-report. `refresh_ok ⇒ full-keg
/// audit` is the invariant every caller upholds.
pub fn writeSnapshotEntries(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    formulas: []const OutdatedEntry,
    casks: []const OutdatedEntry,
) !void {
    try snap_mod.writeSnapshot(ctx.io, allocator, cache_dir, .{
        .generated_at_ms = std.Io.Clock.real.now(ctx.io).toMilliseconds(),
        .formulas = formulas,
        .casks = casks,
    });
}

/// Compute outdated formulas for `kegs`. Sort order follows `kegs` —
/// callers query the DB with `ORDER BY name`. Per-row API failures or
/// 404s drop silently (matches the old serial behaviour).
pub fn collectOutdatedFormulas(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    api: *api_mod.BrewApi,
    cache_dir: []const u8,
    kegs: []const KegRow,
    workers_override: ?usize,
) std.mem.Allocator.Error![]OutdatedEntry {
    return collectOutdated(ctx, allocator, db, api, cache_dir, kegs, workers_override, .formula);
}

/// Cask sibling of `collectOutdatedFormulas`. Same lifetime contract.
pub fn collectOutdatedCasks(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    api: *api_mod.BrewApi,
    cache_dir: []const u8,
    kegs: []const KegRow,
    workers_override: ?usize,
) std.mem.Allocator.Error![]OutdatedEntry {
    return collectOutdated(ctx, allocator, db, api, cache_dir, kegs, workers_override, .cask);
}

const Kind = enum { formula, cask };

/// One upstream version record parsed out of the cached version side-car.
/// `stable` is borrowed from the index bytes the map was built from, so
/// those bytes must outlive the map.
const VersionEntry = struct { stable: []const u8, revision: i64 };

/// Parse the `<name>\t<stable>\t<revision>` version side-car into a map
/// keyed by name. Keys and `stable` borrow from `index_bytes`. Malformed
/// lines (missing fields, empty name/version, non-integer revision) are
/// skipped — a corrupt line must never abort the whole audit.
fn buildVersionMap(
    allocator: std.mem.Allocator,
    index_bytes: []const u8,
) std.mem.Allocator.Error!std.StringHashMap(VersionEntry) {
    var map = std.StringHashMap(VersionEntry).init(allocator);
    errdefer map.deinit();

    var lines = std.mem.splitScalar(u8, index_bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const name = fields.next() orelse continue;
        const stable = fields.next() orelse continue;
        const rev_str = fields.next() orelse continue;
        if (name.len == 0 or stable.len == 0) continue;
        const revision = std.fmt.parseInt(i64, rev_str, 10) catch continue;
        try map.put(name, .{ .stable = stable, .revision = revision });
    }
    return map;
}

/// True when `row` resolves against the bulk version map: every formula,
/// and any cask from the core tap (or with no tap). Non-core tap casks
/// fall through to the per-HEAD `.rb` path the bulk dump can't cover.
/// Core rows (no tap or the homebrew core tap) resolve from the bulk version
/// map; third-party-tap rows fall through to the per-HEAD `.rb` path. Only the
/// tap decides — kind-independent.
fn isCorePathRow(row: KegRow) bool {
    return if (row.tap) |t| install_args_mod.isCoreTap(t) else true;
}

// Outdated policy: malt treats the tap as the source of truth. A keg is
// "outdated" whenever its revision-qualified installed version is not byte-equal
// to the current upstream version — NOT when it is strictly older. This never
// misses an upgrade (any difference surfaces); the trade-off is that if upstream
// moves backward (a yanked release), `outdated` lists it and `upgrade` follows
// the tap down. That downgrade is by design, surfaced as `old -> new` in
// `--dry-run`. Matching Homebrew's `PkgVersion` ordering instead would risk a
// divergent comparator silently skipping a real upgrade — a worse failure mode.

/// What the audit could prove about one row. `proven_current` is the only
/// answer that lets a caller skip work, so it is mintable on exactly one
/// path — see `mapDisposition`. Anything unproven is `unknown`, which costs
/// a redundant upgrade attempt; the reverse would silently skip a real one.
pub const Disposition = union(enum) {
    proven_current,
    /// Caller owns `latest`; release with `freeDisposition`.
    needs_upgrade: []u8,
    unknown,
};

/// Release a disposition's owned payload. Safe on every variant.
pub fn freeDisposition(allocator: std.mem.Allocator, d: Disposition) void {
    switch (d) {
        .needs_upgrade => |latest| allocator.free(latest),
        .proven_current, .unknown => {},
    }
}

/// Release a slice of dispositions and their payloads.
pub fn freeDispositions(allocator: std.mem.Allocator, ds: []Disposition) void {
    for (ds) |d| freeDisposition(allocator, d);
    allocator.free(ds);
}

/// Read a per-keg fetch result as a disposition. A fetch resolves the latest
/// version or it does not; it never proves a row current, so a null here is
/// `unknown` — the fetch path has no map to compare against.
fn fetchDisposition(latest: ?[]u8) Disposition {
    if (latest) |l| return .{ .needs_upgrade = l };
    return .unknown;
}

/// The only minter of `proven_current`. Core-ness is checked here rather than
/// by the caller so no future call site can route a tap row into a version-truth
/// verdict; tap rows answer to sha-truth, which this map cannot see.
fn mapDisposition(
    allocator: std.mem.Allocator,
    map: *const std.StringHashMap(VersionEntry),
    row: KegRow,
) std.mem.Allocator.Error!Disposition {
    if (!isCorePathRow(row)) return .unknown;
    const entry = map.get(row.name) orelse return .unknown;

    var latest_buf: [256]u8 = undefined;
    var installed_buf: [256]u8 = undefined;
    // pkgVersion only fails on buffer overflow. Unproven, so `unknown`:
    // reading it as current would skip a real upgrade.
    const latest = formula_mod.pkgVersion(&latest_buf, entry.stable, entry.revision) catch return .unknown;
    const installed = formula_mod.pkgVersion(&installed_buf, row.version, row.revision) catch return .unknown;
    if (std.mem.eql(u8, installed, latest)) return .proven_current;
    return .{ .needs_upgrade = try allocator.dupe(u8, latest) };
}

/// Warn that the bulk version map matched none of the installed core
/// packages — a likely upstream schema shift. Fail loud: the caller then
/// falls back to per-package fetches rather than reporting everything up
/// to date on an empty map.
fn warnVersionMapDegraded(kind: Kind, core_rows: usize) void {
    output.warn(
        "{s} version map matched none of {d} installed package(s); falling back to per-package checks",
        .{ @tagName(kind), core_rows },
    );
}

/// Per-keg network resolution (serial below the pool threshold, pooled
/// above) for the rows the map can't cover — tap casks, and every row
/// when the map is unusable. Fills `latest_versions` by index.
fn resolveViaFetch(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    head_cache: *TapHeadResolve,
    db: *sqlite.Database,
    api: *api_mod.BrewApi,
    cache_dir: []const u8,
    kegs: []const KegRow,
    workers_override: ?usize,
    kind: Kind,
    latest_versions: []?[]u8,
) std.mem.Allocator.Error!void {
    if (!shouldUsePool(kegs.len)) {
        for (kegs, 0..) |row, i| {
            latest_versions[i] = try fetchLatest(allocator, head_cache, db, api, ctx.io, ctx.environ, kind, row);
        }
    } else {
        try runPool(ctx, allocator, head_cache, db, cache_dir, kegs, workers_override, kind, latest_versions);
    }
}

/// Dispositions resolved against the bulk version index *only* — no per-keg
/// HEAD fetch. A row the index cannot prove (a tap row, a miss, a down index)
/// stays `unknown` for the caller to resolve itself.
///
/// This is the upgrade audit's resolver, distinct from `collectDispositions`
/// on two counts that both matter: it never pays the per-keg fetch this
/// feature exists to remove, and — critically — it never warms a tap's cached
/// HEAD, which a later per-keg upgrade compares against to detect a sha-only
/// move. Resolving a tap row here would make that upgrade see no change.
pub fn collectIndexDispositionsFormulas(
    allocator: std.mem.Allocator,
    api: *api_mod.BrewApi,
    kegs: []const KegRow,
) std.mem.Allocator.Error![]Disposition {
    return collectIndexDispositions(allocator, api, kegs, .formula);
}

/// Cask sibling of `collectIndexDispositionsFormulas`. Same lifetime contract.
pub fn collectIndexDispositionsCasks(
    allocator: std.mem.Allocator,
    api: *api_mod.BrewApi,
    kegs: []const KegRow,
) std.mem.Allocator.Error![]Disposition {
    return collectIndexDispositions(allocator, api, kegs, .cask);
}

fn collectIndexDispositions(
    allocator: std.mem.Allocator,
    api: *api_mod.BrewApi,
    kegs: []const KegRow,
    kind: Kind,
) std.mem.Allocator.Error![]Disposition {
    const dispositions = try allocator.alloc(Disposition, kegs.len);
    @memset(dispositions, .unknown);
    errdefer freeDispositions(allocator, dispositions);
    if (kegs.len == 0) return dispositions;

    const api_kind: api_mod.BrewApi.Kind = switch (kind) {
        .formula => .formula,
        .cask => .cask,
    };
    // A missing or unreadable index leaves every row `unknown` — identical to
    // having no audit at all, which is the pre-feature behaviour.
    const bytes = api.fetchVersionsIndex(api_kind) catch return dispositions;
    defer allocator.free(bytes);
    var map = try buildVersionMap(allocator, bytes);
    defer map.deinit();

    // `mapDisposition` already returns `unknown` for a tap row or a miss, so
    // no core-ness check is needed here — it is the sole minter of
    // `proven_current` and guards itself.
    for (kegs, 0..) |row, i| {
        dispositions[i] = try mapDisposition(allocator, &map, row);
    }
    return dispositions;
}

/// The report is a projection of the dispositions — one resolution path, so
/// `mt outdated` and any auditing caller can never disagree about a row.
fn collectOutdated(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    api: *api_mod.BrewApi,
    cache_dir: []const u8,
    kegs: []const KegRow,
    workers_override: ?usize,
    kind: Kind,
) std.mem.Allocator.Error![]OutdatedEntry {
    const dispositions = try collectDispositions(ctx, allocator, db, api, cache_dir, kegs, workers_override, kind);
    defer freeDispositions(allocator, dispositions);
    return assembleEntries(allocator, kegs, dispositions);
}

/// Resolve every keg to what the audit could prove about it, aligned 1:1 with
/// `kegs`. Callers own each `needs_upgrade` payload — release the slice with
/// `freeDispositions`.
fn collectDispositions(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    api: *api_mod.BrewApi,
    cache_dir: []const u8,
    kegs: []const KegRow,
    workers_override: ?usize,
    kind: Kind,
) std.mem.Allocator.Error![]Disposition {
    if (kegs.len == 0) return allocator.alloc(Disposition, 0);

    // Per-row verdict slot. Rows start `unknown`: a row nothing resolves stays
    // unproven, which costs a redundant upgrade rather than skipping a real one.
    const dispositions = try allocator.alloc(Disposition, kegs.len);
    @memset(dispositions, .unknown);
    errdefer freeDispositions(allocator, dispositions);

    // `needs_fetch[i]` = resolve row `i` via the per-keg network path:
    // tap casks always; every row when the map is missing or degraded.
    const needs_fetch = try allocator.alloc(bool, kegs.len);
    defer allocator.free(needs_fetch);
    @memset(needs_fetch, false);

    // Map pass — the bulk version map. Only fetched when at least one row
    // can use it; a fetch error (offline/down/schema) degrades to per-keg.
    var has_core = false;
    for (kegs) |row| {
        if (isCorePathRow(row)) {
            has_core = true;
            break;
        }
    }

    const api_kind: api_mod.BrewApi.Kind = switch (kind) {
        .formula => .formula,
        .cask => .cask,
    };

    var have_map = false;
    var map: std.StringHashMap(VersionEntry) = undefined;
    var index_bytes: ?[]const u8 = null;
    if (has_core) {
        if (api.fetchVersionsIndex(api_kind)) |bytes| {
            index_bytes = bytes;
            map = try buildVersionMap(allocator, bytes);
            have_map = true;
        } else |_| {}
    }
    defer if (index_bytes) |b| allocator.free(b);
    defer if (have_map) map.deinit();

    if (have_map) {
        var core_rows: usize = 0;
        var matched: usize = 0;
        for (kegs, 0..) |row, i| {
            if (!isCorePathRow(row)) {
                needs_fetch[i] = true; // tap cask → per-HEAD
                continue;
            }
            core_rows += 1;
            // Membership, not provability: an entry that fails to parse still
            // proves the map itself is healthy, so it must not trip the guard.
            if (map.contains(row.name)) matched += 1;
            dispositions[i] = try mapDisposition(allocator, &map, row);
            // A miss on a healthy map means "no upstream info" — unknown,
            // no per-keg refetch.
        }

        // Fail loud: core rows present but none matched → bad map.
        if (core_rows > 0 and matched == 0) {
            warnVersionMapDegraded(kind, core_rows);
            for (kegs, 0..) |row, i| {
                if (isCorePathRow(row)) needs_fetch[i] = true;
            }
        }
    } else {
        @memset(needs_fetch, true); // no map → every row via per-keg
    }

    // One dedup cache shared by every per-keg row (tap-HEAD coalescing).
    var head_cache = TapHeadResolve.init(allocator, ctx.io);
    defer head_cache.deinit();

    // Fetch pass — gather the rows still needing a network resolve and run
    // them through the (sub-)serial-or-pool path, then scatter results.
    var n_fetch: usize = 0;
    for (needs_fetch) |f| {
        if (f) n_fetch += 1;
    }
    if (n_fetch > 0) {
        const sub_kegs = try allocator.alloc(KegRow, n_fetch);
        defer allocator.free(sub_kegs);
        const sub_idx = try allocator.alloc(usize, n_fetch);
        defer allocator.free(sub_idx);
        const sub_latest = try allocator.alloc(?[]u8, n_fetch);
        defer allocator.free(sub_latest);
        @memset(sub_latest, null);
        errdefer for (sub_latest) |maybe| {
            if (maybe) |v| allocator.free(v);
        };

        var j: usize = 0;
        for (kegs, 0..) |row, i| {
            if (needs_fetch[i]) {
                sub_kegs[j] = row;
                sub_idx[j] = i;
                j += 1;
            }
        }

        try resolveViaFetch(ctx, allocator, &head_cache, db, api, cache_dir, sub_kegs, workers_override, kind, sub_latest);
        // Fetch rows are `unknown` until now (the map never wrote them), so
        // overwriting the slot cannot strand a payload.
        for (sub_idx, 0..) |orig, k| {
            dispositions[orig] = fetchDisposition(sub_latest[k]);
            sub_latest[k] = null; // ownership moved into the disposition
        }
    }

    return dispositions;
}

/// Collapse dispositions into the report's shape: only `needs_upgrade` is a
/// line. `proven_current` and `unknown` are both absent — the report cannot
/// tell them apart, which is exactly the distinction callers now can.
fn assembleEntries(
    allocator: std.mem.Allocator,
    kegs: []const KegRow,
    dispositions: []Disposition,
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
        const latest = switch (dispositions[i]) {
            .needs_upgrade => |l| l,
            .proven_current, .unknown => continue,
        };
        // Hand ownership of `latest` over to the entry; clear the
        // slot so the caller's cleanup doesn't double-free it.
        dispositions[i] = .unknown;
        errdefer allocator.free(latest);

        const name_dup = try allocator.dupe(u8, row.name);
        errdefer allocator.free(name_dup);
        // Show the keg's revision-aware version so a `1.2_1 -> 1.2_2`
        // bump reads correctly; revision 0 stays the bare `1.2`.
        var installed_buf: [256]u8 = undefined;
        const installed_str = formula_mod.pkgVersion(&installed_buf, row.version, row.revision) catch row.version;
        const installed_dup = try allocator.dupe(u8, installed_str);

        try out.append(allocator, .{
            .name = name_dup,
            .installed = installed_dup,
            .latest = latest,
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Fetch + parse the upstream latest version for `row` onto `alloc`.
/// Best-effort: network or parse failures collapse to null. Shared by
/// the serial and pool paths so the JSON-shape logic lives once.
/// `io` and `environ` are only consumed by the tap-cask branch (which
/// needs them for the per-tap HEAD resolve + raw `.rb` fetch); core-
/// API formula/cask lookups go through `api` which already wraps the
/// shared HTTP client.
fn upstreamLatest(
    alloc: std.mem.Allocator,
    head_cache: *TapHeadResolve,
    db: *sqlite.Database,
    api: *api_mod.BrewApi,
    io: std.Io,
    environ: std.process.Environ,
    kind: Kind,
    row: KegRow,
) ?[]u8 {
    return switch (kind) {
        .formula => blk: {
            // Pre-route third-party-tap formulae to the tap HEAD: the core API
            // 404s for them, same as tap casks, so the API path would silently
            // drop the row from the audit.
            if (row.tap) |tap_label| {
                if (!install_args_mod.isCoreTap(tap_label)) {
                    break :blk tapFormulaLatestVersion(alloc, head_cache, db, io, environ, tap_label, row.name, api.http);
                }
            }
            const json = api.fetchFormula(row.name) catch break :blk null;
            defer alloc.free(json);
            break :blk parseFormulaLatest(alloc, json);
        },
        .cask => blk: {
            // Pre-route to the owning tap when set: the core API 404s
            // for third-party-tap casks, so the API path would silently
            // drop the row from the audit. Same shape as `upgradeCask`.
            if (row.tap) |tap_label| {
                if (!install_args_mod.isCoreTap(tap_label)) {
                    break :blk tapCaskLatestVersion(alloc, head_cache, db, io, environ, tap_label, row.name, api.http);
                }
            }
            const json = api.fetchCask(row.name) catch break :blk null;
            defer alloc.free(json);
            var cask = cask_mod.parseCask(alloc, json) catch break :blk null;
            defer cask.deinit();
            break :blk alloc.dupe(u8, cask.version) catch null;
        },
    };
}

/// In-process dedup cache for tap-HEAD resolves during one
/// `mt outdated` invocation. N installed casks from the same tap
/// share a single underlying conditional GET — without this, the
/// worker pool fired N parallel resolves and (in the rare case
/// upstream just moved) spent N rate-limit tokens for what the
/// next invocation would coalesce to one. Cross-process caching
/// still lives in the DB's `head_etag` column.
///
/// A single mutex serialises distinct-tap resolves too — the
/// alternative (per-tap mutex + condition variable) was rejected
/// as over-engineering for the typical 1–3 distinct taps an
/// `mt outdated` actually sees. The resolver is injected so tests
/// can drive dedup mechanics without an HTTP transport.
pub const TapHeadResolve = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    /// `null` value caches a known-failing resolve so sibling workers
    /// don't retry the same dead endpoint within one invocation.
    map: std.StringHashMap(?[]const u8),

    /// Bundled userdata + fn pointer — mirrors `client.ProgressCallback`'s
    /// shape so call sites read uniformly across the codebase.
    pub const Resolver = struct {
        userdata: *anyopaque,
        resolve: *const fn (
            userdata: *anyopaque,
            alloc: std.mem.Allocator,
            tap_label: []const u8,
        ) ?[]const u8,
    };

    pub fn init(backing: std.mem.Allocator, io: std.Io) TapHeadResolve {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .io = io,
            .map = .init(backing),
        };
    }

    pub fn deinit(self: *TapHeadResolve) void {
        self.map.deinit();
        self.arena.deinit();
    }

    /// Lookup-or-resolve. The returned slice (when non-null) is borrowed
    /// from the cache's arena and stays valid for the cache's lifetime.
    /// Holds the mutex across the resolver by design: that's the
    /// invariant that turns N concurrent same-label calls into one.
    pub fn getOrResolve(
        self: *TapHeadResolve,
        tap_label: []const u8,
        resolver: Resolver,
    ) ?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.map.get(tap_label)) |maybe_sha| return maybe_sha;

        const a = self.arena.allocator();
        const sha = resolver.resolve(resolver.userdata, a, tap_label);
        // catch return sha: cache-insert OOM degrades to "no cache hit
        // next time" — sibling workers re-resolve but no correctness
        // issue. Returning null instead would hide a successful resolve.
        const key_owned = a.dupe(u8, tap_label) catch return sha;
        self.map.put(key_owned, sha) catch return sha;
        return sha;
    }
};

test "TapHeadResolve: second call for same label returns cached value (no second resolve)" {
    var cache = TapHeadResolve.init(std.testing.allocator, std.Options.debug_io);
    defer cache.deinit();

    const Counter = struct {
        var count: usize = 0;
        fn resolve(_: *anyopaque, a: std.mem.Allocator, _: []const u8) ?[]const u8 {
            count += 1;
            return a.dupe(u8, "0123456789abcdef0123456789abcdef01234567") catch null;
        }
    };
    Counter.count = 0;
    var dummy: u8 = 0;

    const a1 = cache.getOrResolve("user/repo", .{ .userdata = &dummy, .resolve = Counter.resolve });
    const a2 = cache.getOrResolve("user/repo", .{ .userdata = &dummy, .resolve = Counter.resolve });
    try std.testing.expect(a1 != null);
    try std.testing.expect(a2 != null);
    try std.testing.expectEqualStrings(a1.?, a2.?);
    try std.testing.expectEqual(@as(usize, 1), Counter.count);
}

test "TapHeadResolve: distinct labels resolve independently (1 call each)" {
    var cache = TapHeadResolve.init(std.testing.allocator, std.Options.debug_io);
    defer cache.deinit();

    const Counter = struct {
        var count: usize = 0;
        fn resolve(_: *anyopaque, a: std.mem.Allocator, label: []const u8) ?[]const u8 {
            count += 1;
            return a.dupe(u8, label) catch null;
        }
    };
    Counter.count = 0;
    var dummy: u8 = 0;

    const r: TapHeadResolve.Resolver = .{ .userdata = &dummy, .resolve = Counter.resolve };
    _ = cache.getOrResolve("user/repo-a", r);
    _ = cache.getOrResolve("user/repo-b", r);
    _ = cache.getOrResolve("user/repo-a", r);
    _ = cache.getOrResolve("user/repo-b", r);
    try std.testing.expectEqual(@as(usize, 2), Counter.count);
}

test "TapHeadResolve: caches a null result so sibling workers don't retry a dead endpoint" {
    var cache = TapHeadResolve.init(std.testing.allocator, std.Options.debug_io);
    defer cache.deinit();

    const Counter = struct {
        var count: usize = 0;
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8) ?[]const u8 {
            count += 1;
            return null;
        }
    };
    Counter.count = 0;
    var dummy: u8 = 0;

    const r: TapHeadResolve.Resolver = .{ .userdata = &dummy, .resolve = Counter.resolve };
    _ = cache.getOrResolve("user/repo", r);
    _ = cache.getOrResolve("user/repo", r);
    _ = cache.getOrResolve("user/repo", r);
    try std.testing.expectEqual(@as(usize, 1), Counter.count);
}

const ConcurrentResolveCtx = struct {
    cache: *TapHeadResolve,
    label: []const u8,
    counter: *std.atomic.Value(usize),
    /// Barrier so all N threads reach the cache call simultaneously —
    /// otherwise the first thread might finish before the rest start
    /// and the test passes for the wrong reason (single-thread serial
    /// rather than locked dedup).
    barrier: *std.atomic.Value(usize),
    expected: usize,

    fn resolve(userdata: *anyopaque, a: std.mem.Allocator, _: []const u8) ?[]const u8 {
        // Unpack the userdata pointer the cache hands back per call.
        const self: *ConcurrentResolveCtx = @ptrCast(@alignCast(userdata));
        _ = self.counter.fetchAdd(1, .acq_rel);
        return a.dupe(u8, "0123456789abcdef0123456789abcdef01234567") catch null;
    }

    fn worker(self: *ConcurrentResolveCtx) void {
        _ = self.barrier.fetchAdd(1, .acq_rel);
        while (self.barrier.load(.acquire) < self.expected) {} // spin until everyone arrived
        _ = self.cache.getOrResolve(self.label, .{ .userdata = self, .resolve = ConcurrentResolveCtx.resolve });
    }
};

test "TapHeadResolve: concurrent same-label calls resolve exactly once" {
    var cache = TapHeadResolve.init(std.testing.allocator, std.Options.debug_io);
    defer cache.deinit();

    var counter = std.atomic.Value(usize).init(0);
    var barrier = std.atomic.Value(usize).init(0);
    const thread_count: usize = 8;
    var ctxs: [thread_count]ConcurrentResolveCtx = undefined;
    for (&ctxs) |*c| c.* = .{
        .cache = &cache,
        .label = "user/repo",
        .counter = &counter,
        .barrier = &barrier,
        .expected = thread_count,
    };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads, &ctxs) |*t, *c| {
        t.* = try std.Thread.spawn(.{}, ConcurrentResolveCtx.worker, .{c});
    }
    for (threads) |t| t.join();

    // The whole point of this fix: N concurrent same-label calls collapse to 1.
    try std.testing.expectEqual(@as(usize, 1), counter.load(.acquire));
}

/// Surface a tap HEAD-resolve failure during the outdated audit. Pre-
/// fix this collapsed silently to null and the cask got classified as
/// up-to-date — a real upgrade could sit unannounced for hours when
/// the only thing wrong was a transient rate limit. The wording mirrors
/// `describeResolveError` so the install/upgrade/outdated paths share
/// one user-actionable line.
fn warnTapHeadResolveFailed(tap_label: []const u8, err: tap_mod.TapError, forge_kind: forge.Forge, host: []const u8) void {
    var rerr_buf: [512]u8 = undefined;
    output.warn(
        "Could not resolve {s}'s HEAD: {s}",
        .{ tap_label, tap_mod.describeResolveError(&rerr_buf, err, forge_kind, host) },
    );
}

/// Companion to `warnTapHeadResolveFailed` for the raw `.rb` fetch /
/// parse leg. Same intent — never silently drop a cask from the audit.
fn warnTapCaskFetchFailed(tap_label: []const u8, token: []const u8, reason: []const u8) void {
    output.warn(
        "Could not check {s}/{s} for upgrades: {s}",
        .{ tap_label, token, reason },
    );
}

/// Production resolver: the conditional-GET path with DB-cached etag.
/// Bound to the `*HeadResolverCtx` the cache passes back per call. The
/// arena `a` is the cache's arena, so returned slices live for the
/// cache's lifetime without an extra dupe at the call site.
const HeadResolverCtx = struct {
    io: std.Io,
    environ: std.process.Environ,
    db: *sqlite.Database,

    fn resolve(userdata: *anyopaque, a: std.mem.Allocator, tap_label: []const u8) ?[]const u8 {
        // Unpack the userdata pointer the cache hands back per call.
        const self: *HeadResolverCtx = @ptrCast(@alignCast(userdata));
        const urls = tap_mod.resolveTapBaseUrls(a, self.db, tap_label) catch return null;

        // catch null: a DB hiccup here just degrades to "no cached pin /
        // etag" — the resolve then runs unconditional (same as a cold
        // start), which is the right fallback.
        const cached_sha = tap_mod.getCommitSha(a, self.db, tap_label) catch null;
        const cached_etag = tap_mod.getHeadEtag(a, self.db, tap_label) catch null;

        var res = tap_mod.resolveHeadCommit(self.io, self.environ, a, urls.forge, urls.api_head_url, cached_etag) catch |err| {
            warnTapHeadResolveFailed(tap_label, err, urls.forge, urls.host);
            return null;
        };
        defer res.deinit();

        const final_sha = if (res.not_modified)
            (cached_sha orelse {
                warnTapHeadResolveFailed(tap_label, tap_mod.TapError.ResolveFailed, urls.forge, urls.host);
                return null;
            })
        else
            (res.sha orelse {
                warnTapHeadResolveFailed(tap_label, tap_mod.TapError.MalformedJson, urls.forge, urls.host);
                return null;
            });

        // Dupe into arena so the cache owns the slice after res.deinit()
        // (arena's free is a no-op so this is purely for ownership clarity).
        const sha_owned = a.dupe(u8, final_sha) catch return null;
        if (!res.not_modified) {
            if (res.etag) |et| tap_mod.updateHead(self.db, tap_label, sha_owned, et) catch {};
        }
        return sha_owned;
    }
};

/// Resolve a tap package's upstream version from its `.rb` at the tap HEAD.
/// `subtrees` are tried in order (e.g. `Formula/` then a root `<name>.rb`); the
/// first 200 wins. Null on any failure, with a one-line warning so the user
/// (and the regression skip-guards) can tell "up to date" from "couldn't reach
/// the tap". `noun` only colours the unsupported-DSL warning.
fn tapRawLatestVersion(
    alloc: std.mem.Allocator,
    head_cache: *TapHeadResolve,
    db: *sqlite.Database,
    io: std.Io,
    environ: std.process.Environ,
    tap_label: []const u8,
    name: []const u8,
    http: *client_mod.HttpClient,
    subtrees: []const forge.RawKind,
    noun: []const u8,
) ?[]u8 {
    const slash = std.mem.indexOfScalar(u8, tap_label, '/') orelse return null;
    if (slash == 0 or slash == tap_label.len - 1) return null;

    // Dedup'd HEAD resolve: N workers for the same tap pay 1 API call,
    // not N (and the rare moved-tap race costs 1 token, not N).
    var rctx = HeadResolverCtx{ .io = io, .environ = environ, .db = db };
    const fresh_sha = head_cache.getOrResolve(tap_label, .{
        .userdata = &rctx,
        .resolve = HeadResolverCtx.resolve,
    }) orelse return null;

    // The .rb fetch is per-package (different name per row), so it stays
    // out of the cache — only the tap-HEAD resolve dedups.
    const urls = tap_mod.resolveTapBaseUrls(alloc, db, tap_label) catch return null;
    defer urls.deinit(alloc);

    // Reuse the caller's pooled client (it already carries the correct
    // offline flag) so every tap row shares one kept-alive connection.
    return tapVersionFromSubtrees(alloc, http, environ, urls.forge, urls.raw_base, fresh_sha, name, subtrees, noun, tap_label);
}

/// Fetch the `.rb` via the shared `tap.fetchRawFile` leaf (first 200 wins) and
/// parse its `version`, else warn + null. The fetch loop lives in `core/tap`
/// so the upgrade dry-run shares it; the parse + messaging stay here (leaf is
/// UI-agnostic). Driven by a localhost server in tests via `raw_base`.
fn tapVersionFromSubtrees(
    alloc: std.mem.Allocator,
    http: *client_mod.HttpClient,
    environ: std.process.Environ,
    forge_kind: forge.Forge,
    raw_base: []const u8,
    sha: []const u8,
    name: []const u8,
    subtrees: []const forge.RawKind,
    noun: []const u8,
    tap_label: []const u8,
) ?[]u8 {
    var fetch = tap_mod.fetchRawFile(http, environ, forge_kind, raw_base, sha, name, subtrees) catch {
        warnTapCaskFetchFailed(tap_label, name, "Network failure while reading the .rb");
        return null;
    };
    switch (fetch) {
        .not_found => |status| {
            var status_buf: [64]u8 = undefined;
            const reason = std.fmt.bufPrint(&status_buf, "GitHub returned status {d} for the .rb", .{status}) catch "GitHub returned a non-200 status for the .rb";
            warnTapCaskFetchFailed(tap_label, name, reason);
            return null;
        },
        .found => |*rb_resp| {
            defer rb_resp.deinit();
            const rb_info = install_rb_parse_mod.parseRubyFormula(rb_resp.body) orelse {
                var dsl_buf: [96]u8 = undefined;
                const reason = std.fmt.bufPrint(&dsl_buf, "unsupported Ruby DSL shape — use `brew upgrade` for this {s}", .{noun}) catch "unsupported Ruby DSL shape";
                warnTapCaskFetchFailed(tap_label, name, reason);
                return null;
            };
            // Qualify with the .rb revision so a tap revision-only bump is
            // detected, matching the core fetch path.
            var ver_buf: [256]u8 = undefined;
            const qualified = formula_mod.pkgVersion(&ver_buf, rb_info.version, rb_info.revision) catch rb_info.version;
            return alloc.dupe(u8, qualified) catch null;
        },
    }
}

/// Tap cask: `Casks/<token>.rb` at the tap HEAD.
fn tapCaskLatestVersion(
    alloc: std.mem.Allocator,
    head_cache: *TapHeadResolve,
    db: *sqlite.Database,
    io: std.Io,
    environ: std.process.Environ,
    tap_label: []const u8,
    token: []const u8,
    http: *client_mod.HttpClient,
) ?[]u8 {
    return tapRawLatestVersion(alloc, head_cache, db, io, environ, tap_label, token, http, &.{.cask}, "cask");
}

/// Tap formula: `Formula/<name>.rb`, falling back to a root-layout `<name>.rb`.
fn tapFormulaLatestVersion(
    alloc: std.mem.Allocator,
    head_cache: *TapHeadResolve,
    db: *sqlite.Database,
    io: std.Io,
    environ: std.process.Environ,
    tap_label: []const u8,
    name: []const u8,
    http: *client_mod.HttpClient,
) ?[]u8 {
    return tapRawLatestVersion(alloc, head_cache, db, io, environ, tap_label, name, http, &.{ .formula, .formula_root }, "formula");
}

/// Serial-path single-row check. Returns a caller-owned latest-version
/// string if `row` is outdated, null otherwise.
fn fetchLatest(
    allocator: std.mem.Allocator,
    head_cache: *TapHeadResolve,
    db: *sqlite.Database,
    api: *api_mod.BrewApi,
    io: std.Io,
    environ: std.process.Environ,
    kind: Kind,
    row: KegRow,
) std.mem.Allocator.Error!?[]u8 {
    const v = upstreamLatest(allocator, head_cache, db, api, io, environ, kind, row) orelse return null;
    // Compare the revision-qualified installed string against the (now also
    // revision-qualified) upstream so a revision-only bump isn't read as bare.
    // `!eql` is deliberate: malt mirrors the tap as source of truth — see the
    // outdated-policy note above `Disposition`.
    var installed_buf: [256]u8 = undefined;
    const installed = formula_mod.pkgVersion(&installed_buf, row.version, row.revision) catch row.version;
    if (std.mem.eql(u8, installed, v)) {
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
    const stable = switch (stable_val) {
        .string => |s| s,
        else => return null,
    };
    // Qualify with the top-level revision so the fetch fallback catches a
    // revision-only bump (1.2.3 -> 1.2.3_1), mirroring the map path. Absent or
    // non-integer revision is treated as 0; an overflow degrades to the bare
    // stable rather than dropping the row.
    const revision: i64 = switch (obj.get("revision") orelse std.json.Value{ .integer = 0 }) {
        .integer => |n| n,
        else => 0,
    };
    var buf: [256]u8 = undefined;
    const qualified = formula_mod.pkgVersion(&buf, stable, revision) catch stable;
    return allocator.dupe(u8, qualified) catch null;
}

// --- Pool path ---

const WorkerCtx = struct {
    io: std.Io,
    /// Carried so tap-cask rows can resolve their owning tap's HEAD
    /// through `tap_mod.resolveHeadCommit`, which reads GitHub auth
    /// tokens from the parent process environ.
    environ: std.process.Environ,
    /// Shared dedup cache: N workers checking the same tap_label pay
    /// 1 API call across the whole `mt outdated` invocation.
    head_cache: *TapHeadResolve,
    /// Shared DB pointer for cached-etag lookup / persist. Safe under
    /// SQLite SERIALIZED mode (the build sets THREADSAFE=1) — sibling
    /// workers serialise on the per-statement mutex.
    db: *sqlite.Database,
    arena: std.heap.ArenaAllocator,
    pool: *pool_mod.HttpClientPool,
    cache_dir: []const u8,
    /// Snapshot of `ctx.mirrors.api_base` so workers inherit the
    /// mirror override without re-walking the env on a worker thread.
    api_base: []const u8,
    /// Snapshot of `ctx.offline` so workers gate fetches identically
    /// to the serial path without re-walking the env per thread.
    offline: bool,
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
        const wctx = &state.ctxs[idx];
        runOne(state.out_allocator, wctx);
    }
}

fn runOne(out_alloc: std.mem.Allocator, wctx: *WorkerCtx) void {
    const http = wctx.pool.acquire();
    defer wctx.pool.release(http);

    const arena_alloc = wctx.arena.allocator();
    var local_api = api_mod.BrewApi.init(wctx.io, arena_alloc, http, wctx.cache_dir);
    local_api.base_url = wctx.api_base;
    local_api.offline = wctx.offline;
    const latest = upstreamLatest(arena_alloc, wctx.head_cache, wctx.db, &local_api, wctx.io, wctx.environ, wctx.kind, wctx.row) orelse return;
    // Qualify the installed side so a revision-only bump isn't read as bare
    // (same fix as the serial `fetchLatest` path).
    var installed_buf: [256]u8 = undefined;
    const installed = formula_mod.pkgVersion(&installed_buf, wctx.row.version, wctx.row.revision) catch wctx.row.version;
    if (std.mem.eql(u8, installed, latest)) return;

    // Move into the caller's allocator so the result outlives `arena.deinit()`.
    wctx.out = out_alloc.dupe(u8, latest) catch |e| blk: {
        wctx.err = e;
        break :blk null;
    };
}

fn runPool(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    head_cache: *TapHeadResolve,
    db: *sqlite.Database,
    cache_dir: []const u8,
    kegs: []const KegRow,
    workers_override: ?usize,
    kind: Kind,
    latest_versions: []?[]u8,
) std.mem.Allocator.Error!void {
    const worker_count = outdatedWorkerCount(kegs.len, workers_override);
    std.debug.assert(worker_count > 0);

    var http_pool = try pool_mod.HttpClientPool.init(ctx.io, ctx.environ, allocator, worker_count);
    defer http_pool.deinit();
    http_pool.setOfflineAll(ctx.offline);

    const ctxs = try allocator.alloc(WorkerCtx, kegs.len);
    defer {
        for (ctxs) |*c| c.arena.deinit();
        allocator.free(ctxs);
    }
    // Thread-safe heap for per-row worker arenas.
    for (ctxs, 0..) |*c, i| c.* = .{
        .io = ctx.io,
        .environ = ctx.environ,
        .head_cache = head_cache,
        .db = db,
        .arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator),
        .pool = &http_pool,
        .cache_dir = cache_dir,
        .api_base = ctx.mirrors.api_base,
        .offline = ctx.offline,
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

test "WorkerCtx: per-row arena accepts testing.allocator backing without leaking" {
    // Pin the per-row dupe + KB-scale alloc + deinit shape. Production
    // backs the same arena with `smp_allocator`; the inline test
    // guarantees `testing.allocator` still works so future leak coverage
    // can land here without re-plumbing.
    // Field-only smoke: db isn't dereferenced, so an undefined ptr is
    // safe here (mirrors `.pool = undefined`). Real workers always get
    // a live DB from `runPool`.
    var wctx: WorkerCtx = .{
        .io = std.Options.debug_io,
        .environ = std.process.Environ.empty,
        .head_cache = undefined,
        .db = undefined,
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .pool = undefined,
        .cache_dir = "",
        .api_base = "",
        .offline = false,
        .row = .{ .name = "", .version = "" },
        .kind = .formula,
    };
    defer wctx.arena.deinit();

    const a = wctx.arena.allocator();
    _ = try a.dupe(u8, "wget");
    _ = try a.alloc(u8, 1024);
}

test "writeSnapshotEntries writes a snapshot the reader round-trips field-for-field" {
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

    try writeSnapshotEntries(&ctx, std.testing.allocator, cache_dir, &formulas, &casks);

    // A successful read is the version-2 assertion: `parseSnapshot` refuses any
    // other version, so a non-null result proves the leaf wrote the version-2
    // shape. The entries must survive the round-trip byte-for-byte, and the
    // timestamp policy must stamp a real (non-zero) clock reading.
    const read = snap_mod.readSnapshot(io, std.testing.allocator, cache_dir) orelse
        return error.SnapshotUnreadable;
    defer snap_mod.freeSnapshot(std.testing.allocator, read);

    try std.testing.expect(read.generated_at_ms > 0);
    try std.testing.expectEqual(@as(usize, 1), read.formulas.len);
    try std.testing.expectEqualStrings("wget", read.formulas[0].name);
    try std.testing.expectEqualStrings("1.21.3", read.formulas[0].installed);
    try std.testing.expectEqualStrings("1.21.4", read.formulas[0].latest);
    try std.testing.expectEqual(@as(usize, 1), read.casks.len);
    try std.testing.expectEqualStrings("firefox", read.casks[0].name);
    try std.testing.expectEqualStrings("120.0", read.casks[0].installed);
    try std.testing.expectEqualStrings("121.0", read.casks[0].latest);
}

test "outdatedWorkerCount caps at the default for large N" {
    try std.testing.expectEqual(
        @as(usize, outdated_default_workers),
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
    try std.testing.expect(!shouldUsePool(outdated_default_workers - 1));
    try std.testing.expect(shouldUsePool(outdated_default_workers));
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

test "warnTapHeadResolveFailed surfaces rate-limit reason with the tap label" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    output.beginStderrCapture(std.testing.allocator, &buf);
    defer output.endStderrCapture();

    warnTapHeadResolveFailed("yuzeguitarist/deck", tap_mod.TapError.RateLimited, .github, "github.com");

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "yuzeguitarist/deck") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Could not resolve") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "rate limit") != null);
}

test "warnTapHeadResolveFailed surfaces network failure for the regression skip-guards" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    output.beginStderrCapture(std.testing.allocator, &buf);
    defer output.endStderrCapture();

    warnTapHeadResolveFailed("user/repo", tap_mod.TapError.NetworkError, .github, "github.com");

    // Wording must hit both the user-facing "Could not resolve" header
    // and the existing skip-guard regex (`Network failure`) so the
    // regressions/*.sh scripts can tell a rate-limit fail from a real
    // assertion miss.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Could not resolve") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Network failure") != null);
}

test "warnTapHeadResolveFailed renders the gitlab host + token on the CLI output path" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    output.beginStderrCapture(std.testing.allocator, &buf);
    defer output.endStderrCapture();

    warnTapHeadResolveFailed("grp/tap", tap_mod.TapError.RateLimited, .gitlab, "gitlab.com");

    // The whole point: a non-github tap's resolve failure reaches stderr
    // naming its own host + token var, never GitHub's.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "grp/tap") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "gitlab.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "MALT_GITLAB_TOKEN") != null);
    // No github host or token leaked — a single "github" substring would
    // catch either (and avoids hard-coding the token literal the
    // tap-resolution-contract guard forbids outside the forge seam).
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "github") == null);
}

test "warnTapHeadResolveFailed keeps the Network-failure skip-guard phrase for gitea" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    output.beginStderrCapture(std.testing.allocator, &buf);
    defer output.endStderrCapture();

    warnTapHeadResolveFailed("team/tap", tap_mod.TapError.NetworkError, .gitea, "git.example.org");

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "git.example.org") != null);
    // The regressions/*.sh skip-guards grep "Network failure" — it must hold
    // for every forge, not just github.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Network failure") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Could not resolve") != null);
}

test "warnTapCaskFetchFailed names both the tap and the token" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    output.beginStderrCapture(std.testing.allocator, &buf);
    defer output.endStderrCapture();

    warnTapCaskFetchFailed("yuzeguitarist/deck", "deckclip", "GitHub returned status 404 for the .rb");

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "yuzeguitarist/deck") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "deckclip") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "404") != null);
}

test "buildVersionMap parses tab-delimited entries with stable and revision" {
    const idx = "wget\t1.21.4\t0\nopenssl@3\t3.2.1\t2\n";
    var map = try buildVersionMap(std.testing.allocator, idx);
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 2), map.count());
    const w = map.get("wget") orelse return error.MissingEntry;
    try std.testing.expectEqualStrings("1.21.4", w.stable);
    try std.testing.expectEqual(@as(i64, 0), w.revision);
    const o = map.get("openssl@3") orelse return error.MissingEntry;
    try std.testing.expectEqualStrings("3.2.1", o.stable);
    try std.testing.expectEqual(@as(i64, 2), o.revision);
}

test "parseFormulaLatest qualifies stable with the top-level revision" {
    const a = std.testing.allocator;
    // Revision present → revision-qualified.
    const bumped = parseFormulaLatest(a, "{\"versions\":{\"stable\":\"1.2.3\"},\"revision\":1}") orelse return error.ParseFailed;
    defer a.free(bumped);
    try std.testing.expectEqualStrings("1.2.3_1", bumped);

    // Revision absent → bare stable (revision 0).
    const bare = parseFormulaLatest(a, "{\"versions\":{\"stable\":\"1.2.3\"}}") orelse return error.ParseFailed;
    defer a.free(bare);
    try std.testing.expectEqualStrings("1.2.3", bare);
}

// A version that overflows pkgVersion's 256-byte buffer — the only way it
// fails, and the parse hole the union exists to close.
const unparseable_version = "1." ++ ("9" ** 300);

test "assembleEntries: only needs_upgrade is a line; proven_current and unknown are both absent" {
    const a = std.testing.allocator;
    const kegs = [_]KegRow{
        .{ .name = "cur", .version = "1.0" },
        .{ .name = "old", .version = "1.0" },
        .{ .name = "unk", .version = "1.0" },
    };
    var ds = [_]Disposition{
        .proven_current,
        .{ .needs_upgrade = try a.dupe(u8, "2.0") },
        .unknown,
    };
    defer for (ds) |d| freeDisposition(a, d);

    const entries = try assembleEntries(a, &kegs, &ds);
    defer {
        for (entries) |e| {
            a.free(e.name);
            a.free(e.installed);
            a.free(e.latest);
        }
        a.free(entries);
    }

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("old", entries[0].name);
    try std.testing.expectEqualStrings("2.0", entries[0].latest);
    // The payload moved into the entry; the slot must not free it again.
    try std.testing.expect(ds[1] == .unknown);
}

test "fetchDisposition: a fetch that resolved nothing is unknown, never proven_current" {
    // The old slot read null as "up to date"; the fetch path has no map, so it
    // cannot prove that — porting the null through would skip a real upgrade.
    try std.testing.expect(fetchDisposition(null) == .unknown);
}

test "fetchDisposition: a resolved latest needs upgrade and carries the version" {
    const a = std.testing.allocator;
    const latest = try a.dupe(u8, "2.0.0");
    const d = fetchDisposition(latest);
    defer freeDisposition(a, d);
    try std.testing.expect(d == .needs_upgrade);
    try std.testing.expectEqualStrings("2.0.0", d.needs_upgrade);
}

test "mapDisposition: an unparseable upstream version yields unknown, never proven_current" {
    const a = std.testing.allocator;
    var map = try buildVersionMap(a, "wget\t" ++ unparseable_version ++ "\t0\n");
    defer map.deinit();

    const d = try mapDisposition(a, &map, .{ .name = "wget", .version = unparseable_version });
    defer freeDisposition(a, d);
    try std.testing.expect(d == .unknown);
}

test "mapDisposition: a core row with byte-equal qualified versions is proven_current" {
    const a = std.testing.allocator;
    var map = try buildVersionMap(a, "wget\t1.21.4\t0\n");
    defer map.deinit();

    const d = try mapDisposition(a, &map, .{ .name = "wget", .version = "1.21.4" });
    defer freeDisposition(a, d);
    try std.testing.expect(d == .proven_current);
}

test "mapDisposition: same version with a different revision needs upgrade, not proven_current" {
    const a = std.testing.allocator;
    var map = try buildVersionMap(a, "wget\t1.21.4\t2\n");
    defer map.deinit();

    const d = try mapDisposition(a, &map, .{ .name = "wget", .version = "1.21.4", .revision = 1 });
    defer freeDisposition(a, d);
    try std.testing.expect(d == .needs_upgrade);
    try std.testing.expectEqualStrings("1.21.4_2", d.needs_upgrade);
}

test "mapDisposition: a core row missing from the map is unknown, not proven_current" {
    const a = std.testing.allocator;
    var map = try buildVersionMap(a, "curl\t8.0.0\t0\n");
    defer map.deinit();

    // The set-difference trap: absent must never read as current.
    const d = try mapDisposition(a, &map, .{ .name = "wget", .version = "1.21.4" });
    defer freeDisposition(a, d);
    try std.testing.expect(d == .unknown);
}

test "mapDisposition: a tap row is unknown even when the map claims it is current" {
    const a = std.testing.allocator;
    var map = try buildVersionMap(a, "wget\t1.21.4\t0\n");
    defer map.deinit();

    // Version-truth must not answer for a row that lives by sha-truth.
    const d = try mapDisposition(a, &map, .{ .name = "wget", .version = "1.21.4", .tap = "user/repo" });
    defer freeDisposition(a, d);
    try std.testing.expect(d == .unknown);
}

test "mapDisposition: a NULL-tap row is core and, absent from the map, is unknown" {
    const a = std.testing.allocator;
    var map = try buildVersionMap(a, "curl\t8.0.0\t0\n");
    defer map.deinit();

    const d = try mapDisposition(a, &map, .{ .name = "firefox", .version = "1.0", .tap = null });
    defer freeDisposition(a, d);
    try std.testing.expect(d == .unknown);
}

test "isCorePathRow routes core rows to the map and third-party taps per-HEAD" {
    // No tap or the homebrew core tap → bulk version map (formula and cask alike).
    try std.testing.expect(isCorePathRow(.{ .name = "wget", .version = "1" }));
    try std.testing.expect(isCorePathRow(.{ .name = "x", .version = "1", .tap = "homebrew/core" }));
    try std.testing.expect(isCorePathRow(.{ .name = "firefox", .version = "1" }));
    try std.testing.expect(isCorePathRow(.{ .name = "f", .version = "1", .tap = "homebrew/cask" }));
    // Third-party tap → per-HEAD `.rb`, for formulae as well as casks.
    try std.testing.expect(!isCorePathRow(.{ .name = "x", .version = "1", .tap = "user/repo" }));
    try std.testing.expect(!isCorePathRow(.{ .name = "f", .version = "1", .tap = "user/repo" }));
}

// Serves 404 to the first request (the `Formula/<name>.rb` probe), then the
// root-layout `.rb` to the second — exercising the `.formula_root` fallback.
const RbFallbackServer = struct {
    io: std.Io,
    listener: *std.Io.net.Server,
    root_rb: []const u8,
    idx: std.atomic.Value(usize),

    fn serve(self: *RbFallbackServer) void {
        while (true) {
            const stream = self.listener.accept(self.io) catch return;
            defer stream.close(self.io);
            var rbuf: [16 * 1024]u8 = undefined;
            var wbuf: [16 * 1024]u8 = undefined;
            var reader = stream.reader(self.io, &rbuf);
            var writer = stream.writer(self.io, &wbuf);
            var srv = std.http.Server.init(&reader.interface, &writer.interface);
            var req = srv.receiveHead() catch return;
            const first = self.idx.fetchAdd(1, .monotonic) == 0;
            if (first) {
                req.respond("", .{ .status = .not_found }) catch return; // Formula/ miss
            } else {
                req.respond(self.root_rb, .{ .status = .ok }) catch return; // root hit
            }
        }
    }
};

test "tapVersionFromSubtrees falls back to the root layout and parses the version" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    // Root-layout formula; no literal `version`, so the version is derived from
    // the url (the koekeishiya/felixkratz shape). url + sha256 are required.
    const root_rb =
        \\class Pkg < Formula
        \\  url "https://x/releases/download/v1.2.3/pkg.tar.gz"
        \\  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
        \\end
    ;
    var srv = RbFallbackServer{ .io = io, .listener = &listener, .root_rb = root_rb, .idx = std.atomic.Value(usize).init(0) };
    const thread = try std.Thread.spawn(.{}, RbFallbackServer.serve, .{&srv});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client_mod.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    defer http.deinit();

    var base_buf: [64]u8 = undefined;
    const raw_base = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});

    const v = tapVersionFromSubtrees(std.testing.allocator, &http, std.process.Environ.empty, .github, raw_base, "deadbeef", "pkg", &.{ .formula, .formula_root }, "formula", "user/repo");
    listener.deinit(io);
    thread.join();

    defer if (v) |vv| std.testing.allocator.free(vv);
    try std.testing.expect(v != null);
    try std.testing.expectEqualStrings("1.2.3", v.?); // resolved from the root `.rb`
}

test "tapVersionFromSubtrees qualifies the resolved version with the .rb revision" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    // A tap .rb whose stable is unchanged but whose revision bumped: the
    // resolved latest must carry `_2` so the fetch fallback flags the bump.
    const rev_rb =
        \\class Pkg < Formula
        \\  url "https://x/pkg-1.2.3.tar.gz"
        \\  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
        \\  version "1.2.3"
        \\  revision 2
        \\end
    ;
    var srv = RbFallbackServer{ .io = io, .listener = &listener, .root_rb = rev_rb, .idx = std.atomic.Value(usize).init(0) };
    const thread = try std.Thread.spawn(.{}, RbFallbackServer.serve, .{&srv});

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client_mod.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    defer http.deinit();

    var base_buf: [64]u8 = undefined;
    const raw_base = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});

    const v = tapVersionFromSubtrees(std.testing.allocator, &http, std.process.Environ.empty, .github, raw_base, "deadbeef", "pkg", &.{ .formula, .formula_root }, "formula", "user/repo");
    listener.deinit(io);
    thread.join();

    defer if (v) |vv| std.testing.allocator.free(vv);
    try std.testing.expect(v != null);
    try std.testing.expectEqualStrings("1.2.3_2", v.?);
}

test "tap rows reuse the caller-supplied client (the tap path constructs no HttpClient)" {
    // The reuse property is the whole point of threading the pooled client:
    // a tap row must fetch its `.rb` through the client it is handed, never a
    // per-row throwaway. Proven network-free with an offline client — only a
    // helper that actually uses the injected client honours its offline flag;
    // a re-introduced self-init would build its own online client and reach
    // the network. Both a formula and a cask row ride the same one client.
    const schema = @import("../../db/schema.zig");

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    // Seed the HEAD resolve so the row skips the network HEAD leg and reaches
    // the `.rb` fetch, where the injected client governs the outcome.
    var head_cache = TapHeadResolve.init(std.testing.allocator, io);
    defer head_cache.deinit();
    const Seed = struct {
        fn resolve(_: *anyopaque, a: std.mem.Allocator, _: []const u8) ?[]const u8 {
            return a.dupe(u8, "0123456789abcdef0123456789abcdef01234567") catch null;
        }
    };
    var dummy: u8 = 0;
    _ = head_cache.getOrResolve("user/repo", .{ .userdata = &dummy, .resolve = Seed.resolve });

    var inner: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    var http = client_mod.HttpClient.initWith(&inner, io, std.process.Environ.empty, std.testing.allocator);
    defer http.deinit();
    http.offline = true;

    const f = tapFormulaLatestVersion(std.testing.allocator, &head_cache, &db, io, std.process.Environ.empty, "user/repo", "pkg", &http);
    const c = tapCaskLatestVersion(std.testing.allocator, &head_cache, &db, io, std.process.Environ.empty, "user/repo", "tok", &http);
    if (f) |v| std.testing.allocator.free(v);
    if (c) |v| std.testing.allocator.free(v);

    // Offline injected client → the fetch short-circuits, network-free.
    try std.testing.expect(f == null);
    try std.testing.expect(c == null);
}

test "buildVersionMap skips malformed lines without aborting" {
    // Missing fields, empty version, and a non-integer revision must each
    // drop their line, not crash the parse.
    const idx = "good\t1.0\t0\nbadline\nempty\t\t0\nrev\t2.0\tnotnum\n";
    var map = try buildVersionMap(std.testing.allocator, idx);
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 1), map.count());
    try std.testing.expect(map.get("good") != null);
}

test "parseFormulaLatest pulls versions.stable from a real-shape document" {
    const json =
        \\{"name":"tree","versions":{"stable":"2.1.1","head":"HEAD","bottle":true},"oldname":null}
    ;
    const v = parseFormulaLatest(std.testing.allocator, json) orelse return error.UnexpectedNull;
    defer std.testing.allocator.free(v);
    try std.testing.expectEqualStrings("2.1.1", v);
}

test "parseFormulaLatest returns null for every malformed or missing shape" {
    // One row per shape that should collapse to null. A real upstream
    // failure should land the keg as up-to-date rather than crash the
    // pool worker — `null` is the contract.
    const cases = [_][]const u8{
        "",
        "not-json",
        // Top-level not an object.
        "[]",
        "\"a string\"",
        // No `versions` field.
        "{}",
        // `versions` is not an object.
        "{\"versions\":[]}",
        "{\"versions\":\"1.0\"}",
        // `versions` lacks `stable`.
        "{\"versions\":{\"head\":\"HEAD\"}}",
        // `stable` is not a string.
        "{\"versions\":{\"stable\":42}}",
        "{\"versions\":{\"stable\":null}}",
        "{\"versions\":{\"stable\":[\"1.0\"]}}",
    };
    for (cases) |c| {
        const got = parseFormulaLatest(std.testing.allocator, c);
        if (got) |v| {
            std.testing.allocator.free(v);
            std.debug.print("expected null for input: {s}\n", .{c});
            return error.UnexpectedValue;
        }
    }
}
