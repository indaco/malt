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
pub fn shouldRunApi(scope: Scope, has_local_hit: bool) bool {
    _ = has_local_hit;
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
        // DISTINCT collapses the per-version `UNIQUE(name, version)` rows
        // back to one entry per package.
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
    try testing.expect(shouldRunApi(.default, false));
    try testing.expect(shouldRunApi(.default, true));
}

test "shouldRunApi: installed never hits API" {
    try testing.expect(!shouldRunApi(.installed, false));
    try testing.expect(!shouldRunApi(.installed, true));
}

test "shouldRunApi: api and all always hit API" {
    try testing.expect(shouldRunApi(.api, true));
    try testing.expect(shouldRunApi(.api, false));
    try testing.expect(shouldRunApi(.all, true));
    try testing.expect(shouldRunApi(.all, false));
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

    const has_local_hit = formula.exact or cask.exact or
        formula.matches.len != 0 or cask.matches.len != 0;

    if (shouldRunApi(scope, has_local_hit)) {
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
            .installed => unreachable, // shouldRunApi(.installed, …) is false.
        }
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = ctx.stdout.writer(ctx.io, &stdout_buf);
    const stdout: *std.Io.Writer = &stdout_fw.interface;
    // Flush on teardown; stdout closed by a broken pipe is normal shell usage.
    defer stdout.flush() catch {};
    if (json_mode) {
        try emitJson(stdout, search_formula, search_cask, formula, cask, search_query);
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
    var api = api_mod.BrewApi.init(ctx.io, allocator, &http, cache_dir);
    api.base_url = ctx.mirrors.api_base;
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
    if (r.exact) writeResult(stdout, query, kind);
    for (r.matches) |m| {
        if (r.exact and std.mem.eql(u8, m, query)) continue;
        writeResult(stdout, m, kind);
    }
}

fn emitJson(
    stdout: *std.Io.Writer,
    search_formula: bool,
    search_cask: bool,
    formula: KindResults,
    cask: KindResults,
    query: []const u8,
) !void {
    try stdout.writeAll("{");
    if (search_formula) {
        try stdout.writeAll("\"formulae\":[");
        try writeJson(stdout, "name", formula, query);
        try stdout.writeAll("]");
    }
    if (search_cask) {
        if (search_formula) try stdout.writeAll(",");
        try stdout.writeAll("\"casks\":[");
        try writeJson(stdout, "token", cask, query);
        try stdout.writeAll("]");
    }
    try stdout.writeAll("}\n");
}

fn writeJson(w: *std.Io.Writer, field: []const u8, r: KindResults, query: []const u8) !void {
    var first = true;
    if (r.exact) {
        try writeJsonObj(w, field, query);
        first = false;
    }
    for (r.matches) |m| {
        if (r.exact and std.mem.eql(u8, m, query)) continue;
        if (!first) try w.writeAll(",");
        try writeJsonObj(w, field, m);
        first = false;
    }
}

fn writeJsonObj(w: *std.Io.Writer, field: []const u8, value: []const u8) !void {
    try w.writeAll("{\"");
    try w.writeAll(field);
    try w.writeAll("\":");
    try output.jsonStr(w, value);
    try w.writeAll("}");
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
