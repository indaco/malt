//! malt — search command
//! Search formulas and casks.

const std = @import("std");
const testing = std.testing;

const AppCtx = @import("../app_ctx.zig").AppCtx;
const schema = @import("../db/schema.zig");
const sqlite = @import("../db/sqlite.zig");
const atomic = @import("../fs/atomic.zig");
const api_mod = @import("../net/api.zig");
const client_mod = @import("../net/client.zig");
const color = @import("../ui/color.zig");
const output = @import("../ui/output.zig");
const help = @import("help.zig");

/// Where a `mt search` query should look. Default is local-first with a
/// fall-through to the API; explicit flags pin the choice.
pub const Scope = enum { default, installed, api, all };

/// Does this scope ever consult the local DB? Default stays brew-parity
/// (API-only) so `mt search` doesn't silently diverge for users coming
/// from `brew search`; `--installed` / `--all` / `--offline` are the
/// explicit opt-ins into the local path.
pub fn shouldRunLocal(scope: Scope) bool {
    return switch (scope) {
        .installed, .all => true,
        .default, .api => false,
    };
}

/// Should the API path run? `.installed` is the only scope that bypasses
/// it entirely; everything else (including `.default`, which mirrors
/// `brew search`) reaches for the index.
pub fn shouldRunApi(scope: Scope) bool {
    return switch (scope) {
        .default, .api, .all => true,
        .installed => false,
    };
}

/// Recognise `--installed`, `--api`, `--all` anywhere in `args`. `--all`
/// (or both `--installed` and `--api`) collapses to `.all`; absence of all
/// three returns `.default`. Other flags and positional args are ignored.
pub fn parseScope(args: []const []const u8) Scope {
    var saw_installed = false;
    var saw_api = false;
    var saw_all = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--installed")) {
            saw_installed = true;
        } else if (std.mem.eql(u8, arg, "--api")) {
            saw_api = true;
        } else if (std.mem.eql(u8, arg, "--all")) {
            saw_all = true;
        }
    }
    if (saw_all or (saw_installed and saw_api)) return .all;
    if (saw_installed) return .installed;
    if (saw_api) return .api;
    return .default;
}

/// Substring scan over `kegs.name` (`.formula`) or `casks.token` (`.cask`).
/// Returns caller-owned name slices, each individually allocated; the
/// outer slice is also caller-owned. Sorted by `name`/`token` ASC. The
/// match is case-insensitive on ASCII and runs in Zig so the SQL stays
/// wildcard-free — `LIKE` would force escaping of `_` / `%` characters
/// that `validateName` already permits in formula names.
pub fn searchLocalKind(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    kind: api_mod.BrewApi.Kind,
    query: []const u8,
) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }

    // Same 128-byte ceiling as `api.findNameMatches` so the two paths
    // reject the same pathological inputs.
    var qbuf: [128]u8 = undefined;
    if (query.len == 0 or query.len > qbuf.len) return out.toOwnedSlice(allocator);
    const qlower = std.ascii.lowerString(qbuf[0..query.len], query);

    const sql: []const u8 = switch (kind) {
        // DISTINCT collapses the per-`UNIQUE(name, version, revision)`
        // rows back to one entry per package.
        .formula => "SELECT DISTINCT name FROM kegs ORDER BY name;",
        .cask => "SELECT token FROM casks ORDER BY token;",
    };

    var stmt = try db.prepare(sql);
    defer stmt.finalize();

    while (try stmt.step()) {
        const name_z = stmt.columnText(0) orelse continue;
        const name = std.mem.sliceTo(name_z, 0);
        // Names in `kegs`/`casks` are lowercase by Homebrew convention,
        // same assumption `api.findNameMatches` makes about the API
        // index. The single case-fold above is enough.
        if (std.mem.indexOf(u8, name, qlower) == null) continue;
        const owned = try allocator.dupe(u8, name);
        errdefer allocator.free(owned);
        try out.append(allocator, owned);
    }

    return out.toOwnedSlice(allocator);
}

test "parseScope: no scope flags returns default" {
    try testing.expectEqual(Scope.default, parseScope(&.{"wget"}));
}

test "parseScope: --installed maps to installed" {
    try testing.expectEqual(Scope.installed, parseScope(&.{ "--installed", "wget" }));
}

test "parseScope: --api maps to api" {
    try testing.expectEqual(Scope.api, parseScope(&.{ "--api", "wget" }));
}

test "parseScope: --all maps to all" {
    try testing.expectEqual(Scope.all, parseScope(&.{ "--all", "wget" }));
}

test "parseScope: --installed + --api collapses to all" {
    try testing.expectEqual(Scope.all, parseScope(&.{ "--installed", "--api", "wget" }));
}

test "parseScope: ignores non-scope flags and positional args" {
    try testing.expectEqual(Scope.installed, parseScope(&.{ "--formula", "--json", "--installed", "wget" }));
}

test "shouldRunApi: default mirrors brew search and hits the API" {
    try testing.expect(shouldRunApi(.default));
}

test "shouldRunApi: installed never hits API" {
    try testing.expect(!shouldRunApi(.installed));
}

test "shouldRunApi: api and all always hit API" {
    try testing.expect(shouldRunApi(.api));
    try testing.expect(shouldRunApi(.all));
}

test "shouldRunLocal: default and api skip the local DB" {
    try testing.expect(!shouldRunLocal(.default));
    try testing.expect(!shouldRunLocal(.api));
    try testing.expect(shouldRunLocal(.installed));
    try testing.expect(shouldRunLocal(.all));
}

fn freeMatches(matches: []const []const u8) void {
    for (matches) |m| testing.allocator.free(m);
    testing.allocator.free(matches);
}

fn seedKegsAndCasks(db: *sqlite.Database) !void {
    try db.exec(
        \\INSERT INTO kegs(name, full_name, version, store_sha256, cellar_path)
        \\VALUES
        \\  ('wget', 'wget', '1.21', 'aaa', '/x/wget/1.21'),
        \\  ('wgetpaste', 'wgetpaste', '2.31', 'bbb', '/x/wgetpaste/2.31'),
        \\  ('jq', 'jq', '1.7', 'ccc', '/x/jq/1.7');
    );
    try db.exec(
        \\INSERT INTO casks(token, name, version, url)
        \\VALUES
        \\  ('firefox', 'Firefox', '120.0', 'https://x'),
        \\  ('firefox-developer-edition', 'Firefox DE', '121.0b', 'https://x'),
        \\  ('brave', 'Brave', '1.0', 'https://x');
    );
}

test "searchLocalKind on kegs returns substring hits sorted" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try seedKegsAndCasks(&db);

    const hits = try searchLocalKind(testing.allocator, &db, .formula, "wget");
    defer freeMatches(hits);

    try testing.expectEqual(@as(usize, 2), hits.len);
    try testing.expectEqualStrings("wget", hits[0]);
    try testing.expectEqualStrings("wgetpaste", hits[1]);
}

test "searchLocalKind on casks matches token substrings" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try seedKegsAndCasks(&db);

    const hits = try searchLocalKind(testing.allocator, &db, .cask, "firefox");
    defer freeMatches(hits);

    try testing.expectEqual(@as(usize, 2), hits.len);
    try testing.expectEqualStrings("firefox", hits[0]);
    try testing.expectEqualStrings("firefox-developer-edition", hits[1]);
}

test "searchLocalKind is case-insensitive on the query" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try seedKegsAndCasks(&db);

    const hits = try searchLocalKind(testing.allocator, &db, .formula, "JQ");
    defer freeMatches(hits);

    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("jq", hits[0]);
}

test "searchLocalKind returns empty slice for no hits" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try seedKegsAndCasks(&db);

    const hits = try searchLocalKind(testing.allocator, &db, .formula, "python");
    defer freeMatches(hits);

    try testing.expectEqual(@as(usize, 0), hits.len);
}

test "searchLocalKind tolerates an empty query without scanning" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try seedKegsAndCasks(&db);

    const hits = try searchLocalKind(testing.allocator, &db, .formula, "");
    defer freeMatches(hits);

    try testing.expectEqual(@as(usize, 0), hits.len);
}

test "runKindLocal flags exact when the query matches a row verbatim" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try seedKegsAndCasks(&db);

    const r = try runKindLocal(testing.allocator, &db, .formula, "jq");
    defer freeMatches(r.matches);

    try testing.expect(r.exact);
    try testing.expectEqual(@as(usize, 1), r.matches.len);
    try testing.expectEqualStrings("jq", r.matches[0]);
}

test "runKindLocal leaves exact false on a substring-only hit" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try seedKegsAndCasks(&db);

    // "get" is a substring of "wget" and "wgetpaste" but not a row.
    const r = try runKindLocal(testing.allocator, &db, .formula, "get");
    defer freeMatches(r.matches);

    try testing.expect(!r.exact);
    try testing.expectEqual(@as(usize, 2), r.matches.len);
}

test "mergeResults dedupes overlapping names and sorts the union" {
    const arena_alloc = testing.allocator;
    const local_names = try arena_alloc.alloc([]const u8, 2);
    defer arena_alloc.free(local_names);
    local_names[0] = "wget";
    local_names[1] = "jq";

    const api_names = try arena_alloc.alloc([]const u8, 3);
    defer arena_alloc.free(api_names);
    api_names[0] = "wget"; // duplicate of local
    api_names[1] = "wget2"; // API-only
    api_names[2] = "wgetpaste"; // API-only

    const merged = try mergeResults(
        arena_alloc,
        .{ .exact = true, .matches = local_names },
        .{ .exact = false, .matches = api_names },
    );
    defer arena_alloc.free(merged.matches);

    try testing.expect(merged.exact); // OR of inputs
    try testing.expectEqual(@as(usize, 4), merged.matches.len);
    try testing.expectEqualStrings("jq", merged.matches[0]);
    try testing.expectEqualStrings("wget", merged.matches[1]);
    try testing.expectEqualStrings("wget2", merged.matches[2]);
    try testing.expectEqualStrings("wgetpaste", merged.matches[3]);
}

test "mergeResults with empty local degenerates to sorted API" {
    const arena_alloc = testing.allocator;
    const api_names = try arena_alloc.alloc([]const u8, 2);
    defer arena_alloc.free(api_names);
    api_names[0] = "wget2";
    api_names[1] = "wget";

    const merged = try mergeResults(
        arena_alloc,
        .{ .exact = false, .matches = &.{} },
        .{ .exact = true, .matches = api_names },
    );
    defer arena_alloc.free(merged.matches);

    try testing.expect(merged.exact);
    try testing.expectEqual(@as(usize, 2), merged.matches.len);
    try testing.expectEqualStrings("wget", merged.matches[0]);
    try testing.expectEqualStrings("wget2", merged.matches[1]);
}

test "isOfflineRequested honours --offline" {
    const ctx: AppCtx = .{ .io = std.Options.debug_io, .environ = .empty };
    try testing.expect(isOfflineRequested(&ctx, &.{ "--offline", "wget" }));
    try testing.expect(!isOfflineRequested(&ctx, &.{ "--api", "wget" }));
}

test "isOfflineRequested reads MALT_OFFLINE truthy values" {
    inline for (.{ "MALT_OFFLINE=1", "MALT_OFFLINE=true", "MALT_OFFLINE=TRUE", "MALT_OFFLINE=True" }) |kv| {
        const entries = [_:null]?[*:0]const u8{kv.ptr};
        const env: std.process.Environ = .{ .block = .{ .slice = entries[0..1 :null] } };
        const ctx: AppCtx = .{ .io = std.Options.debug_io, .environ = env };
        try testing.expect(isOfflineRequested(&ctx, &.{"wget"}));
    }
}

test "isOfflineRequested rejects MALT_OFFLINE falsy values" {
    inline for (.{ "MALT_OFFLINE=0", "MALT_OFFLINE=", "MALT_OFFLINE=no", "MALT_OFFLINE=false" }) |kv| {
        const entries = [_:null]?[*:0]const u8{kv.ptr};
        const env: std.process.Environ = .{ .block = .{ .slice = entries[0..1 :null] } };
        const ctx: AppCtx = .{ .io = std.Options.debug_io, .environ = env };
        try testing.expect(!isOfflineRequested(&ctx, &.{"wget"}));
    }
}

/// Results for a single kind (formula or cask) of a search query.
///
/// `matches` elements are slices into `index`, so `index` must outlive
/// them. Both live in the arena owned by `execute`, freed together at
/// function exit — no explicit deinit.
const KindResults = struct {
    exact: bool = false,
    index: ?[]const u8 = null,
    matches: []const []const u8 = &.{},
};

pub fn execute(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(ctx, args, "search")) return;

    // Parse non-scope flags and the (single) positional query.
    var search_formula = false;
    var search_cask = false;
    var query: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--formula") or std.mem.eql(u8, arg, "--formulae")) {
            search_formula = true;
        } else if (std.mem.eql(u8, arg, "--cask") or std.mem.eql(u8, arg, "--casks")) {
            search_cask = true;
        } else if (arg.len > 0 and arg[0] != '-') {
            if (query == null) query = arg;
        }
    }

    const search_query = query orelse {
        output.err("Usage: mt search <query>", .{});
        return error.Aborted;
    };

    if (!search_formula and !search_cask) {
        search_formula = true;
        search_cask = true;
    }

    // T-029 slice for `search`: offline mode degrades to local-only so
    // a plane-mode user gets an answer instead of a connect timeout.
    var scope = parseScope(args);
    if (isOfflineRequested(ctx, args)) scope = .installed;

    const json_mode = output.isJson();

    // One arena per kind: the worker-thread API path keeps each
    // `KindResults` bump-pointer disjoint, and local matches join later
    // in the same arena. `smp_allocator` stays thread-safe across
    // the cask/formula worker.
    var f_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer f_arena.deinit();
    var c_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer c_arena.deinit();
    const f_alloc = f_arena.allocator();
    const c_alloc = c_arena.allocator();

    var formula: KindResults = .{};
    var cask: KindResults = .{};

    if (shouldRunLocal(scope)) {
        if (openLocalDb(ctx)) |db_opt| {
            if (db_opt) |db_in| {
                var db = db_in;
                defer db.close();
                if (search_formula) formula = runKindLocal(f_alloc, &db, .formula, search_query) catch .{};
                if (search_cask) cask = runKindLocal(c_alloc, &db, .cask, search_query) catch .{};
            }
        } else |_| {}
    }

    if (shouldRunApi(scope)) {
        const cache_dir = atomic.maltCacheDir(allocator) catch {
            output.err("Failed to determine cache directory", .{});
            return error.Aborted;
        };
        defer allocator.free(cache_dir);

        // Cask + formula API indexes are ~29 MiB / ~14 MiB on first fetch;
        // overlapping the two halves wall-clock on a cold cache, costs
        // ~ms on a warm one. `std.http.Client` is not thread-safe so each
        // worker owns its own `HttpClient`.
        var api_formula: KindResults = .{};
        var api_cask: KindResults = .{};
        if (search_formula and search_cask) {
            var cask_task: KindTask = .{
                .ctx = ctx,
                .allocator = c_alloc,
                .cache_dir = cache_dir,
                .kind = .cask,
                .query = search_query,
            };
            const worker = std.Thread.spawn(.{}, KindTask.run, .{&cask_task}) catch null;
            api_formula = runKindIsolated(ctx, f_alloc, cache_dir, .formula, search_query);
            if (worker) |w| {
                w.join();
                api_cask = cask_task.result;
            } else {
                api_cask = runKindIsolated(ctx, c_alloc, cache_dir, .cask, search_query);
            }
        } else if (search_formula) {
            api_formula = runKindIsolated(ctx, f_alloc, cache_dir, .formula, search_query);
        } else if (search_cask) {
            api_cask = runKindIsolated(ctx, c_alloc, cache_dir, .cask, search_query);
        }

        switch (scope) {
            .all => {
                if (search_formula) formula = mergeResults(f_alloc, formula, api_formula) catch api_formula;
                if (search_cask) cask = mergeResults(c_alloc, cask, api_cask) catch api_cask;
            },
            .default, .api => {
                if (search_formula) formula = api_formula;
                if (search_cask) cask = api_cask;
            },
            .installed => unreachable, // shouldRunApi(.installed) is false.
        }
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = ctx.stdout.writer(ctx.io, &stdout_buf);
    const stdout: *std.Io.Writer = &stdout_fw.interface;
    // Flush on teardown; stdout closed by a broken pipe is normal shell usage.
    defer stdout.flush() catch {};
    if (json_mode) {
        // Installed flag is JSON-only; the set lives in the formula arena,
        // freed with everything else at function exit.
        const set = loadInstalledSet(ctx, f_alloc);
        try emitJson(f_alloc, stdout, formula, cask, search_query, set);
    } else {
        emitHuman(stdout, formula, cask, search_query);
    }
}

/// `--offline` flag or `MALT_OFFLINE` env (`1` / `true`). When either
/// is active, `mt search` cannot make sense of `--api` and degrades to
/// `--installed` semantics.
pub fn isOfflineRequested(ctx: *const AppCtx, args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--offline")) return true;
    }
    const val = std.process.Environ.getPosix(ctx.environ, "MALT_OFFLINE") orelse return false;
    return std.mem.eql(u8, val, "1") or std.ascii.eqlIgnoreCase(val, "true");
}

/// Open `{prefix}/db/malt.db` for read-only search. Returns `null` when
/// the file doesn't exist yet (fresh prefix) so callers can degrade to
/// "no local matches" instead of aborting. Outer error wraps unexpected
/// `sqlite` / `schema` failures.
fn openLocalDb(ctx: *const AppCtx) !?sqlite.Database {
    const prefix = atomic.maltPrefixOrAbort();
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return null;
    _ = std.Io.Dir.cwd().statFile(ctx.io, std.mem.sliceTo(db_path, 0), .{}) catch return null;
    var db = sqlite.Database.open(db_path) catch return null;
    errdefer db.close();
    try schema.initSchema(&db);
    return db;
}

/// Local-DB counterpart to `runKindIsolated`. `exact` is set when the
/// case-folded query matches a row verbatim — same semantics the API
/// path's `api.exists` provides.
fn runKindLocal(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    kind: api_mod.BrewApi.Kind,
    query: []const u8,
) !KindResults {
    const matches = try searchLocalKind(allocator, db, kind, query);
    var qbuf: [128]u8 = undefined;
    var exact = false;
    if (query.len > 0 and query.len <= qbuf.len) {
        const qlower = std.ascii.lowerString(qbuf[0..query.len], query);
        for (matches) |m| {
            if (std.mem.eql(u8, m, qlower)) {
                exact = true;
                break;
            }
        }
    }
    return .{ .exact = exact, .index = null, .matches = matches };
}

/// Merge local + API matches for one kind (`--all` path). Deduplicates
/// by exact name and sorts ASC so the combined output reads consistently.
/// `index` is carried from the API side since the API matches still
/// reference it.
fn mergeResults(
    allocator: std.mem.Allocator,
    locals: KindResults,
    api: KindResults,
) !KindResults {
    var combined: std.ArrayList([]const u8) = .empty;
    errdefer combined.deinit(allocator);
    try combined.appendSlice(allocator, locals.matches);
    for (api.matches) |a| {
        var dup = false;
        for (locals.matches) |l| {
            if (std.mem.eql(u8, l, a)) {
                dup = true;
                break;
            }
        }
        if (!dup) try combined.append(allocator, a);
    }
    const merged = try combined.toOwnedSlice(allocator);
    std.mem.sort([]const u8, merged, {}, lessThanStr);
    return .{
        .exact = locals.exact or api.exact,
        .index = api.index,
        .matches = merged,
    };
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Run the exact + substring search for one kind with a locally-owned
/// HTTP client. Errors from the API are swallowed into empty results —
/// `mt search` is best-effort and a transient network failure should
/// not abort the whole command.
fn runKindIsolated(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    kind: api_mod.BrewApi.Kind,
    query: []const u8,
) KindResults {
    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, allocator);
    defer http.deinit();
    http.offline = ctx.offline;
    var api = api_mod.BrewApi.init(ctx.io, allocator, &http, cache_dir);
    api.base_url = ctx.mirrors.api_base;
    api.offline = ctx.offline;
    var r: KindResults = .{};
    r.exact = api.exists(query, kind) catch false;
    if (api.fetchNamesIndex(kind)) |idx| {
        r.index = idx;
        r.matches = api_mod.findNameMatches(allocator, idx, query) catch &.{};
    } else |_| {}
    return r;
}

/// Thread entry-point wrapper so `std.Thread.spawn` can call it with a
/// single pointer argument. The result is written back into the struct
/// the caller allocated on its stack, read after `join()`.
const KindTask = struct {
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    kind: api_mod.BrewApi.Kind,
    query: []const u8,
    result: KindResults = .{},

    fn run(self: *KindTask) void {
        self.result = runKindIsolated(self.ctx, self.allocator, self.cache_dir, self.kind, self.query);
    }
};

fn emitHuman(
    stdout: *std.Io.Writer,
    formula: KindResults,
    cask: KindResults,
    query: []const u8,
) void {
    writeHuman(stdout, "formula", formula, query);
    writeHuman(stdout, "cask", cask, query);

    const any = formula.exact or cask.exact or
        formula.matches.len != 0 or cask.matches.len != 0;
    if (!any and !output.isQuiet()) {
        output.info("No results found for \"{s}\"", .{query});
    }
}

/// Write substring matches for one kind, with the exact match (if any)
/// pinned to the top and deduped against the substring list. The index
/// may not yet include a brand-new formula the API already serves, so
/// relying on substring membership alone to surface exact matches would
/// under-report on the day of a new release.
fn writeHuman(
    stdout: *std.Io.Writer,
    kind: []const u8,
    r: KindResults,
    query: []const u8,
) void {
    const exact_name = exactDisplayName(query, r.matches);
    if (r.exact) writeResult(stdout, exact_name, kind);
    for (r.matches) |m| {
        if (r.exact and std.ascii.eqlIgnoreCase(m, query)) continue;
        writeResult(stdout, m, kind);
    }
}

/// Display name for the pinned exact row. Exactness is decided case-folded,
/// so echoing the raw query would mis-case the row and dodge the dedup; use
/// the canonical match instead, falling back to the query only on the
/// day-of-release case where the index doesn't yet list it.
fn exactDisplayName(query: []const u8, matches: []const []const u8) []const u8 {
    for (matches) |m| {
        if (std.ascii.eqlIgnoreCase(m, query)) return m;
    }
    return query;
}

/// One row of the unified `mt search --json` array. `installed` is derived
/// by cross-referencing the local DB so the Search tab never offers to
/// install a package that is already present.
const Result = struct {
    name: []const u8,
    kind: api_mod.BrewApi.Kind,
    installed: bool,
};

/// Installed names pulled from the local DB, split by kind. Empty when the
/// DB is absent (fresh prefix), so every `installed` reads false — correct.
/// Names are lowercase by Homebrew convention, so membership case-folds.
const InstalledSet = struct {
    formulae: []const []const u8 = &.{},
    casks: []const []const u8 = &.{},

    fn has(self: InstalledSet, kind: api_mod.BrewApi.Kind, name: []const u8) bool {
        return isInstalled(switch (kind) {
            .formula => self.formulae,
            .cask => self.casks,
        }, name);
    }
};

/// Case-insensitive membership over one kind's installed set.
fn isInstalled(set: []const []const u8, name: []const u8) bool {
    var qbuf: [128]u8 = undefined;
    if (name.len == 0 or name.len > qbuf.len) return false;
    const lower = std.ascii.lowerString(qbuf[0..name.len], name);
    for (set) |s| {
        if (std.mem.eql(u8, s, lower)) return true;
    }
    return false;
}

fn emitJson(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    formula: KindResults,
    cask: KindResults,
    query: []const u8,
    set: InstalledSet,
) !void {
    const results = try buildResults(allocator, formula, cask, query, set);
    defer allocator.free(results);
    try writeSearchJson(stdout, query, results);
}

/// Flatten the per-kind results into one ranked array — exact match first
/// (deduped against the substring list), then substrings — tagging each row
/// with its kind and installed state. Same ordering the split-key writer
/// used, so the unification is shape-only; empty kinds contribute nothing.
fn buildResults(
    allocator: std.mem.Allocator,
    formula: KindResults,
    cask: KindResults,
    query: []const u8,
    set: InstalledSet,
) ![]Result {
    var list: std.ArrayList(Result) = .empty;
    errdefer list.deinit(allocator);
    try appendKind(allocator, &list, formula, .formula, query, set);
    try appendKind(allocator, &list, cask, .cask, query, set);
    return list.toOwnedSlice(allocator);
}

fn appendKind(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Result),
    r: KindResults,
    kind: api_mod.BrewApi.Kind,
    query: []const u8,
    set: InstalledSet,
) !void {
    if (r.exact) {
        const name = exactDisplayName(query, r.matches);
        try list.append(allocator, .{ .name = name, .kind = kind, .installed = set.has(kind, name) });
    }
    for (r.matches) |m| {
        if (r.exact and std.ascii.eqlIgnoreCase(m, query)) continue;
        try list.append(allocator, .{ .name = m, .kind = kind, .installed = set.has(kind, m) });
    }
}

/// Render the versioned, unified `mt search --json` root —
/// `{"schema_version":1,"query":…,"results":[…]}`. Pure writer so the
/// byte-pinned tests need no DB or network. Casks share the array with
/// formulae, each row tagged by `type` (the `outdated` precedent).
fn writeSearchJson(w: *std.Io.Writer, query: []const u8, results: []const Result) !void {
    try output.writeSchemaVersionPrefix(w);
    try w.writeAll("\"query\":");
    try output.jsonStr(w, query);
    try w.writeAll(",\"results\":[");
    for (results, 0..) |r, i| {
        if (i != 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try output.jsonStr(w, r.name);
        try w.writeAll(switch (r.kind) {
            .formula => ",\"type\":\"formula\",\"installed\":",
            .cask => ",\"type\":\"cask\",\"installed\":",
        });
        try w.writeAll(if (r.installed) "true" else "false");
        try w.writeAll("}");
    }
    try w.writeAll("]}\n");
}

/// Build the installed set from the local DB, best-effort. A missing DB
/// (fresh prefix) or any read failure yields an empty set — every result
/// then reads `installed:false`, which is correct. Slices live in
/// `allocator`, freed with the caller's arena.
fn loadInstalledSet(ctx: *const AppCtx, allocator: std.mem.Allocator) InstalledSet {
    const db_opt = openLocalDb(ctx) catch return .{};
    var db = db_opt orelse return .{};
    defer db.close();
    return .{
        .formulae = loadInstalledKind(allocator, &db, .formula) catch &.{},
        .casks = loadInstalledKind(allocator, &db, .cask) catch &.{},
    };
}

/// Load every installed name for one kind (no substring filter) so the
/// `--json` path can flag each result's installed state. Caller owns each
/// slice; sorted ASC by the SQL.
fn loadInstalledKind(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    kind: api_mod.BrewApi.Kind,
) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }
    const sql: []const u8 = switch (kind) {
        // DISTINCT collapses per-version `kegs` rows to one per package.
        .formula => "SELECT DISTINCT name FROM kegs ORDER BY name;",
        .cask => "SELECT token FROM casks ORDER BY token;",
    };
    var stmt = try db.prepare(sql);
    defer stmt.finalize();
    while (try stmt.step()) {
        const name_z = stmt.columnText(0) orelse continue;
        const owned = try allocator.dupe(u8, std.mem.sliceTo(name_z, 0));
        errdefer allocator.free(owned);
        try out.append(allocator, owned);
    }
    return out.toOwnedSlice(allocator);
}

test "writeSearchJson wraps a mixed formula+cask array in the versioned root" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const results = [_]Result{
        .{ .name = "firefox", .kind = .cask, .installed = true },
        .{ .name = "wget", .kind = .formula, .installed = false },
    };
    try writeSearchJson(&aw.writer, "fire", &results);

    const want =
        \\{"schema_version":1,"query":"fire","results":[{"name":"firefox","type":"cask","installed":true},{"name":"wget","type":"formula","installed":false}]}
    ++ "\n";
    try testing.expectEqualStrings(want, aw.written());
}

test "writeSearchJson emits an empty results array under the versioned root" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeSearchJson(&aw.writer, "zzz", &.{});
    try testing.expectEqualStrings(
        "{\"schema_version\":1,\"query\":\"zzz\",\"results\":[]}\n",
        aw.written(),
    );
}

test "writeSearchJson escapes embedded quotes in query and name" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const results = [_]Result{
        .{ .name = "a\"b", .kind = .formula, .installed = false },
    };
    try writeSearchJson(&aw.writer, "q\"x", &results);
    try testing.expectEqualStrings(
        "{\"schema_version\":1,\"query\":\"q\\\"x\",\"results\":[{\"name\":\"a\\\"b\",\"type\":\"formula\",\"installed\":false}]}\n",
        aw.written(),
    );
}

test "writeSearchJson stays one valid JSON object with schema_version" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const results = [_]Result{
        .{ .name = "jq", .kind = .formula, .installed = true },
    };
    try writeSearchJson(&aw.writer, "jq", &results);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("schema_version").?.integer);
    try testing.expectEqualStrings("jq", parsed.value.object.get("query").?.string);
    try testing.expectEqual(@as(usize, 1), parsed.value.object.get("results").?.array.items.len);
}

test "buildResults pins the exact match first, dedupes it, and tags type" {
    const formula: KindResults = .{ .exact = true, .matches = &.{ "jq", "jqp" } };
    const cask: KindResults = .{ .exact = false, .matches = &.{"jira"} };
    const set: InstalledSet = .{ .formulae = &.{"jq"}, .casks = &.{} };

    const results = try buildResults(testing.allocator, formula, cask, "jq", set);
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(usize, 3), results.len);
    // Exact match first, then the substring-only formula, then the cask.
    try testing.expectEqualStrings("jq", results[0].name);
    try testing.expectEqual(api_mod.BrewApi.Kind.formula, results[0].kind);
    try testing.expect(results[0].installed);
    try testing.expectEqualStrings("jqp", results[1].name);
    try testing.expect(!results[1].installed);
    try testing.expectEqualStrings("jira", results[2].name);
    try testing.expectEqual(api_mod.BrewApi.Kind.cask, results[2].kind);
    try testing.expect(!results[2].installed);
}

test "buildResults collapses a mixed-case exact match to one canonical row" {
    // Query "JQ" matches canonical "jq" case-insensitively: the exact row
    // must carry the canonical name and the substring "jq" must be deduped.
    const formula: KindResults = .{ .exact = true, .matches = &.{ "jq", "jqp" } };
    const set: InstalledSet = .{ .formulae = &.{"jq"}, .casks = &.{} };

    const results = try buildResults(testing.allocator, formula, .{}, "JQ", set);
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqualStrings("jq", results[0].name);
    try testing.expect(results[0].installed);
    try testing.expectEqualStrings("jqp", results[1].name);
}

test "buildResults keeps the raw query when no match supplies a canonical name" {
    // Day-of-release: API reports exact but the substring index lacks it,
    // so the exact row falls back to the user's typed case — one row, no dup.
    const formula: KindResults = .{ .exact = true, .matches = &.{} };
    const results = try buildResults(testing.allocator, formula, .{}, "JQ", .{});
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqualStrings("JQ", results[0].name);
}

test "writeHuman collapses a mixed-case exact match to one canonical row" {
    color.setForTest(false, false);
    defer color.setForTest(null, null);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const r: KindResults = .{ .exact = true, .matches = &.{ "jq", "jqp" } };
    writeHuman(&aw.writer, "formula", r, "JQ");

    try testing.expectEqualStrings(
        "  \xe2\x96\xb8 jq (formula)\n  \xe2\x96\xb8 jqp (formula)\n",
        aw.written(),
    );
}

test "writeHuman keeps the raw query when no match supplies a canonical name" {
    // Day-of-release: API reports exact but the substring index lacks it,
    // so the human row falls back to the user's typed case — still one row.
    color.setForTest(false, false);
    defer color.setForTest(null, null);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const r: KindResults = .{ .exact = true, .matches = &.{} };
    writeHuman(&aw.writer, "formula", r, "JQ");

    try testing.expectEqualStrings("  \xe2\x96\xb8 JQ (formula)\n", aw.written());
}

test "buildResults marks an installed substring hit regardless of case" {
    const formula: KindResults = .{ .exact = false, .matches = &.{"WGet"} };
    const set: InstalledSet = .{ .formulae = &.{"wget"}, .casks = &.{} };

    const results = try buildResults(testing.allocator, formula, .{}, "get", set);
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expect(results[0].installed);
}

test "buildResults yields an empty slice when neither kind has hits" {
    const results = try buildResults(testing.allocator, .{}, .{}, "nope", .{});
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 0), results.len);
}

test "buildResults flags an installed cask on the exact match" {
    const cask: KindResults = .{ .exact = true, .matches = &.{"firefox"} };
    const set: InstalledSet = .{ .formulae = &.{}, .casks = &.{"firefox"} };

    const results = try buildResults(testing.allocator, .{}, cask, "firefox", set);
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqual(api_mod.BrewApi.Kind.cask, results[0].kind);
    try testing.expect(results[0].installed);
}

test "isInstalled rejects an over-long name instead of overflowing the fold buffer" {
    const long = "a" ** 129;
    try testing.expect(!isInstalled(&.{long}, long));
}

test "loadInstalledKind returns every installed name for the kind, sorted" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try seedKegsAndCasks(&db);

    const formulae = try loadInstalledKind(testing.allocator, &db, .formula);
    defer freeMatches(formulae);
    try testing.expectEqual(@as(usize, 3), formulae.len);
    try testing.expectEqualStrings("jq", formulae[0]);
    try testing.expectEqualStrings("wget", formulae[1]);
    try testing.expectEqualStrings("wgetpaste", formulae[2]);

    const casks = try loadInstalledKind(testing.allocator, &db, .cask);
    defer freeMatches(casks);
    try testing.expectEqual(@as(usize, 3), casks.len);
    try testing.expectEqualStrings("brave", casks[0]);
    try testing.expectEqualStrings("firefox", casks[1]);
    try testing.expectEqualStrings("firefox-developer-edition", casks[2]);
}

/// Write a single search result with the same ▸ prefix style used by `list`.
fn writeResult(stdout: *std.Io.Writer, name: []const u8, kind: []const u8) void {
    const use_color = color.isColorEnabled();
    if (use_color) stdout.writeAll(color.SemanticStyle.info.code()) catch return;
    stdout.writeAll("  \xe2\x96\xb8 ") catch return;
    if (use_color) stdout.writeAll(color.Style.reset.code()) catch return;
    stdout.writeAll(name) catch return;
    if (use_color) stdout.writeAll(color.SemanticStyle.detail.code()) catch return;
    stdout.writeAll(" (") catch return;
    stdout.writeAll(kind) catch return;
    stdout.writeAll(")") catch return;
    if (use_color) stdout.writeAll(color.Style.reset.code()) catch return;
    stdout.writeAll("\n") catch return;
}
