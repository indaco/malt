//! malt — per-invocation parsed-formula cache tests.
//!
//! Pins the contract that during a single install run, every dependency's
//! formula JSON is parsed exactly once. A 6-formula synthetic graph (1
//! root + 5 deps) drives the full BFS + parallel-fetch + post-process
//! path through `collectFormulaJobs`; the shared cache's `parse_count`
//! must end at 6 — one parse per unique name — so the warm-install hot
//! path no longer pays the 2-3× re-parse it used to.

const std = @import("std");
const testing = std.testing;

const malt = @import("malt");
const install_download = malt.install_download;
const deps_mod = malt.deps;
const sqlite = malt.sqlite;
const schema = malt.schema;
const test_io = @import("test_io");

/// A shared path would let one run's `deleteTree` wipe the other's seeded API
/// cache, which then silently falls through to the real network and 404s.
fn uniqueTempPath(allocator: std.mem.Allocator, tag: []const u8) ![]const u8 {
    return test_io.uniqueTempPath(allocator, "parse_cache_test", tag);
}

const TempDb = struct {
    allocator: std.mem.Allocator,
    dir: []const u8,
    db: sqlite.Database,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !TempDb {
        const dir = try uniqueTempPath(allocator, tag);
        errdefer allocator.free(dir);
        // Wipe leftover test.db / test.db-wal / test.db-shm from a prior
        // run; a stale SHM makes the WAL pragma flake on re-open.
        test_io.deleteTreeAbsolute(std.Options.debug_io, dir) catch {};
        test_io.makeDirAbsolute(std.Options.debug_io, dir) catch {};
        var db_path_buf: [256]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/test.db", .{dir}, 0);
        var db = try sqlite.Database.open(db_path);
        errdefer db.close();
        try schema.initSchema(&db);
        return .{ .allocator = allocator, .dir = dir, .db = db };
    }

    fn deinit(self: *TempDb) void {
        self.db.close();
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.dir) catch {};
        self.allocator.free(self.dir);
    }
};

fn seedCache(cache_dir: []const u8, name: []const u8, json: []const u8) !void {
    var api_buf: [512]u8 = undefined;
    const api_dir = try std.fmt.bufPrint(&api_buf, "{s}/api", .{cache_dir});
    test_io.makeDirAbsolute(std.Options.debug_io, api_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/api/formula_{s}.json", .{ cache_dir, name });
    const f = try test_io.cwd().createFile(std.Options.debug_io, path, .{});
    defer f.close(std.Options.debug_io);
    try f.writeStreamingAll(std.Options.debug_io, json);
}

/// A fixture digest has to be 64 lowercase hex or the parser drops the
/// bottle entry outright. Callers must keep the `comptime` on their `++`
/// chain: without it the concat lands in a stack temporary and the fixture
/// hands back a dangling slice.
fn storeKey(comptime seed: []const u8) *const [64]u8 {
    const padded = seed ++ "0" ** 64;
    return padded[0..64];
}

/// Unique sha per dep so the dedup branch can't collapse jobs.
fn bottleJsonUniqueSha(comptime name: []const u8, comptime tag: []const u8) []const u8 {
    return comptime "{\"name\":\"" ++ name ++ "\"," ++
        "\"full_name\":\"" ++ name ++ "\"," ++
        "\"tap\":\"homebrew/core\"," ++
        "\"desc\":\"\",\"homepage\":\"\",\"revision\":0," ++
        "\"keg_only\":false,\"post_install_defined\":false," ++
        "\"versions\":{\"stable\":\"1.0\"}," ++
        "\"dependencies\":[],\"oldnames\":[]," ++
        "\"bottle\":{\"stable\":{\"root_url\":\"https://ghcr.io/v2/homebrew/core/" ++ name ++ "/blobs\"," ++
        "\"files\":{" ++
        "\"arm64_sequoia\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/" ++ name ++ "-arm\",\"sha256\":\"" ++ storeKey(tag ++ "a") ++ "\"}," ++
        "\"arm64_sonoma\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/" ++ name ++ "-arm\",\"sha256\":\"" ++ storeKey(tag ++ "a") ++ "\"}," ++
        "\"arm64_ventura\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/" ++ name ++ "-arm\",\"sha256\":\"" ++ storeKey(tag ++ "a") ++ "\"}," ++
        "\"arm64_monterey\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/" ++ name ++ "-arm\",\"sha256\":\"" ++ storeKey(tag ++ "a") ++ "\"}," ++
        "\"sequoia\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/" ++ name ++ "-x86\",\"sha256\":\"" ++ storeKey(tag ++ "e") ++ "\"}," ++
        "\"sonoma\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/" ++ name ++ "-x86\",\"sha256\":\"" ++ storeKey(tag ++ "e") ++ "\"}," ++
        "\"ventura\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/" ++ name ++ "-x86\",\"sha256\":\"" ++ storeKey(tag ++ "e") ++ "\"}," ++
        "\"monterey\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/" ++ name ++ "-x86\",\"sha256\":\"" ++ storeKey(tag ++ "e") ++ "\"}" ++
        "}}}}";
}

fn rootJsonWithFiveDeps() []const u8 {
    return comptime "{\"name\":\"root\"," ++
        "\"full_name\":\"root\"," ++
        "\"tap\":\"homebrew/core\"," ++
        "\"desc\":\"\",\"homepage\":\"\",\"revision\":0," ++
        "\"keg_only\":false,\"post_install_defined\":false," ++
        "\"versions\":{\"stable\":\"1.0\"}," ++
        "\"dependencies\":[\"d_a\",\"d_b\",\"d_c\",\"d_d\",\"d_e\"]," ++
        "\"oldnames\":[]," ++
        "\"bottle\":{\"stable\":{\"root_url\":\"https://ghcr.io/v2/homebrew/core/root/blobs\"," ++
        "\"files\":{" ++
        "\"arm64_sequoia\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/root-arm\",\"sha256\":\"" ++ storeKey("b0") ++ "\"}," ++
        "\"arm64_sonoma\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/root-arm\",\"sha256\":\"" ++ storeKey("b0") ++ "\"}," ++
        "\"arm64_ventura\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/root-arm\",\"sha256\":\"" ++ storeKey("b0") ++ "\"}," ++
        "\"arm64_monterey\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/root-arm\",\"sha256\":\"" ++ storeKey("b0") ++ "\"}," ++
        "\"sequoia\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/root-x86\",\"sha256\":\"" ++ storeKey("b1") ++ "\"}," ++
        "\"sonoma\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/root-x86\",\"sha256\":\"" ++ storeKey("b1") ++ "\"}," ++
        "\"ventura\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/root-x86\",\"sha256\":\"" ++ storeKey("b1") ++ "\"}," ++
        "\"monterey\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/root-x86\",\"sha256\":\"" ++ storeKey("b1") ++ "\"}" ++
        "}}}}";
}

test "collectFormulaJobs parses each formula exactly once via shared cache" {
    const alloc = testing.allocator;

    var tdb = try TempDb.init(alloc, "six_dep_cache");
    defer tdb.deinit();

    const cache_dir = try uniqueTempPath(alloc, "six_dep_cache_apicache");
    defer alloc.free(cache_dir);
    test_io.deleteTreeAbsolute(std.Options.debug_io, cache_dir) catch {};
    test_io.makeDirAbsolute(std.Options.debug_io, cache_dir) catch {};
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, cache_dir) catch {};

    const root_json = rootJsonWithFiveDeps();
    try seedCache(cache_dir, "root", root_json);
    try seedCache(cache_dir, "d_a", bottleJsonUniqueSha("d_a", "aa"));
    try seedCache(cache_dir, "d_b", bottleJsonUniqueSha("d_b", "bb"));
    try seedCache(cache_dir, "d_c", bottleJsonUniqueSha("d_c", "cc"));
    try seedCache(cache_dir, "d_d", bottleJsonUniqueSha("d_d", "dd"));
    try seedCache(cache_dir, "d_e", bottleJsonUniqueSha("d_e", "ee"));

    var http_pool = try malt.client_pool.HttpClientPool.init(std.Options.debug_io, std.process.Environ.empty, alloc, 2);
    defer http_pool.deinit();
    var real_http = malt.client.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, alloc);
    defer real_http.deinit();
    var api = malt.api.BrewApi.init(std.Options.debug_io, alloc, &real_http, cache_dir);

    var store_inst: malt.store.Store = undefined;
    var jobs: std.ArrayList(install_download.DownloadJob) = .empty;
    defer {
        for (jobs.items) |job| {
            alloc.free(job.name);
            alloc.free(job.version_str);
            alloc.free(job.sha256);
            alloc.free(job.bottle_url);
            alloc.free(job.cellar_type);
            if (job.is_dep) alloc.free(job.formula_json);
        }
        jobs.deinit(alloc);
    }

    var formula_cache = deps_mod.FormulaCache.init(alloc);
    defer formula_cache.deinit();

    try install_download.collectFormulaJobs(
        .{
            .io = std.Options.debug_io,
            .allocator = alloc,
            .api = &api,
            .http_pool = &http_pool,
            .db = &tdb.db,
            .store = &store_inst,
            .cache = &formula_cache,
            .worker_backing = alloc,
        },
        "root",
        root_json,
        false,
        &jobs,
    );

    // 1 root + 5 deps, all queued (shas unique → no dedup).
    try testing.expectEqual(@as(usize, 6), jobs.items.len);

    // Parse-once invariant: BFS, post-process, and findFailedDep all hit cache.
    try testing.expectEqual(@as(usize, 6), formula_cache.parse_count);
}

test "FormulaCache.init/deinit makes no allocations on the empty path" {
    // Cask / local / tap installs never touch `collectFormulaJobs`; the
    // cache is created at the top of `execute` regardless. Pin the
    // contract that the unused path costs zero allocator round-trips.
    var cache = deps_mod.FormulaCache.init(std.testing.failing_allocator);
    cache.deinit();
}

test "FormulaCache holds at most one entry per unique dep across the run" {
    // Memory-bound regression guard: the cache must hold exactly one
    // typed Formula per unique name, not duplicate copies on warm
    // re-fetches. A 6-dep graph caps at 6 entries, full stop.
    const alloc = testing.allocator;

    var tdb = try TempDb.init(alloc, "bound");
    defer tdb.deinit();

    const cache_dir = try uniqueTempPath(alloc, "bound_apicache");
    defer alloc.free(cache_dir);
    test_io.deleteTreeAbsolute(std.Options.debug_io, cache_dir) catch {};
    test_io.makeDirAbsolute(std.Options.debug_io, cache_dir) catch {};
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, cache_dir) catch {};

    const root_json = rootJsonWithFiveDeps();
    try seedCache(cache_dir, "root", root_json);
    try seedCache(cache_dir, "d_a", bottleJsonUniqueSha("d_a", "aa"));
    try seedCache(cache_dir, "d_b", bottleJsonUniqueSha("d_b", "bb"));
    try seedCache(cache_dir, "d_c", bottleJsonUniqueSha("d_c", "cc"));
    try seedCache(cache_dir, "d_d", bottleJsonUniqueSha("d_d", "dd"));
    try seedCache(cache_dir, "d_e", bottleJsonUniqueSha("d_e", "ee"));

    var http_pool = try malt.client_pool.HttpClientPool.init(std.Options.debug_io, std.process.Environ.empty, alloc, 2);
    defer http_pool.deinit();
    var real_http = malt.client.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, alloc);
    defer real_http.deinit();
    var api = malt.api.BrewApi.init(std.Options.debug_io, alloc, &real_http, cache_dir);

    var store_inst: malt.store.Store = undefined;
    var jobs: std.ArrayList(install_download.DownloadJob) = .empty;
    defer {
        for (jobs.items) |job| {
            alloc.free(job.name);
            alloc.free(job.version_str);
            alloc.free(job.sha256);
            alloc.free(job.bottle_url);
            alloc.free(job.cellar_type);
            if (job.is_dep) alloc.free(job.formula_json);
        }
        jobs.deinit(alloc);
    }

    var formula_cache = deps_mod.FormulaCache.init(alloc);
    defer formula_cache.deinit();

    try install_download.collectFormulaJobs(
        .{
            .io = std.Options.debug_io,
            .allocator = alloc,
            .api = &api,
            .http_pool = &http_pool,
            .db = &tdb.db,
            .store = &store_inst,
            .cache = &formula_cache,
            .worker_backing = alloc,
        },
        "root",
        root_json,
        false,
        &jobs,
    );

    try testing.expectEqual(@as(usize, 6), formula_cache.entryCount());
}

test "resolve walks deps for JSON missing the name field" {
    // Tolerance regression guard: `parseFormula` requires a `name` field,
    // but the BFS must still walk minimal `{"dependencies":[...]}` JSON
    // so synthetic fixtures and any upstream API quirk keep resolving.
    const alloc = testing.allocator;

    const cache_dir = try uniqueTempPath(alloc, "no_name_apicache");
    defer alloc.free(cache_dir);
    test_io.deleteTreeAbsolute(std.Options.debug_io, cache_dir) catch {};
    test_io.makeDirAbsolute(std.Options.debug_io, cache_dir) catch {};
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, cache_dir) catch {};

    var api_buf: [512]u8 = undefined;
    const api_dir = try std.fmt.bufPrint(&api_buf, "{s}/api", .{cache_dir});
    try test_io.makeDirAbsolute(std.Options.debug_io, api_dir);

    // Minimal JSON — no `name` field. The cache cannot type-parse this,
    // but BFS still needs the dep list.
    const root_json = "{\"dependencies\":[\"leaf_one\",\"leaf_two\"]}";
    var root_buf: [512]u8 = undefined;
    const root_path = try std.fmt.bufPrint(&root_buf, "{s}/api/formula_thin.json", .{cache_dir});
    {
        const f = try test_io.cwd().createFile(std.Options.debug_io, root_path, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, root_json);
    }

    inline for (.{ "leaf_one", "leaf_two" }) |leaf| {
        var leaf_buf: [512]u8 = undefined;
        const leaf_path = try std.fmt.bufPrint(&leaf_buf, "{s}/api/formula_{s}.json", .{ cache_dir, leaf });
        const f = try test_io.cwd().createFile(std.Options.debug_io, leaf_path, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "{\"dependencies\":[]}");
    }

    var http = malt.client.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, alloc);
    defer http.deinit();
    var api = malt.api.BrewApi.init(std.Options.debug_io, alloc, &http, cache_dir);

    var tdb = try TempDb.init(alloc, "no_name");
    defer tdb.deinit();

    var formula_cache = deps_mod.FormulaCache.init(alloc);
    defer formula_cache.deinit();

    const result = try deps_mod.resolve(std.Options.debug_io, alloc, "thin", &api, &tdb.db, &formula_cache);
    defer {
        for (result) |d| alloc.free(d.name);
        if (result.len > 0) alloc.free(result);
    }

    try testing.expectEqual(@as(usize, 2), result.len);
    // The fallback path does not pollute the cache — only typed parses
    // get a slot. parse_count stays at 0 for malformed root JSON.
    try testing.expectEqual(@as(usize, 0), formula_cache.parse_count);
}

test "FormulaCache.getOrParse is safe under concurrent callers" {
    // Concurrency guard: workers may someday call into the cache (e.g.
    // future parallel-fetch fold). With the mutex, every duplicate-name
    // miss collapses to a single parse no matter how many threads race.
    const alloc = testing.allocator;
    var cache = deps_mod.FormulaCache.init(alloc);
    defer cache.deinit();

    const json = "{\"name\":\"hot\"," ++
        "\"versions\":{\"stable\":\"1.0\"}," ++
        "\"dependencies\":[],\"oldnames\":[]}";

    const Worker = struct {
        fn run(c: *deps_mod.FormulaCache, j: []const u8) void {
            var i: usize = 0;
            while (i < 64) : (i += 1) {
                _ = c.getOrParse("hot", j) catch return;
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &cache, json });
    for (threads) |t| t.join();

    try testing.expectEqual(@as(usize, 1), cache.parse_count);
    try testing.expectEqual(@as(usize, 1), cache.entryCount());
}

test "shared deps across multi-package install collapse to one parse" {
    // `mt install wget ffmpeg` runs collectFormulaJobs twice with the
    // same cache. Any dep both pull (e.g. openssl@3) must parse exactly
    // once across the whole run — the cross-call dedup is the second
    // half of the per-invocation parse-once guarantee.
    const alloc = testing.allocator;

    var tdb = try TempDb.init(alloc, "multi_pkg");
    defer tdb.deinit();

    const cache_dir = try uniqueTempPath(alloc, "multi_pkg_apicache");
    defer alloc.free(cache_dir);
    test_io.deleteTreeAbsolute(std.Options.debug_io, cache_dir) catch {};
    test_io.makeDirAbsolute(std.Options.debug_io, cache_dir) catch {};
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, cache_dir) catch {};

    // Two roots ("alpha", "omega") that share one dep ("shared_lib").
    const alpha_json = comptime "{\"name\":\"alpha\"," ++
        "\"versions\":{\"stable\":\"1.0\"}," ++
        "\"dependencies\":[\"shared_lib\"]," ++
        "\"oldnames\":[]," ++
        "\"bottle\":{\"stable\":{\"root_url\":\"https://ghcr.io/v2/homebrew/core/alpha/blobs\",\"files\":{" ++
        "\"arm64_sequoia\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/alpha-arm\",\"sha256\":\"" ++ storeKey("a0") ++ "\"}," ++
        "\"arm64_sonoma\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/alpha-arm\",\"sha256\":\"" ++ storeKey("a0") ++ "\"}," ++
        "\"arm64_ventura\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/alpha-arm\",\"sha256\":\"" ++ storeKey("a0") ++ "\"}," ++
        "\"arm64_monterey\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/alpha-arm\",\"sha256\":\"" ++ storeKey("a0") ++ "\"}," ++
        "\"sequoia\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/alpha-x86\",\"sha256\":\"" ++ storeKey("a1") ++ "\"}," ++
        "\"sonoma\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/alpha-x86\",\"sha256\":\"" ++ storeKey("a1") ++ "\"}," ++
        "\"ventura\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/alpha-x86\",\"sha256\":\"" ++ storeKey("a1") ++ "\"}," ++
        "\"monterey\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/alpha-x86\",\"sha256\":\"" ++ storeKey("a1") ++ "\"}" ++
        "}}}}";
    const omega_json = comptime "{\"name\":\"omega\"," ++
        "\"versions\":{\"stable\":\"1.0\"}," ++
        "\"dependencies\":[\"shared_lib\"]," ++
        "\"oldnames\":[]," ++
        "\"bottle\":{\"stable\":{\"root_url\":\"https://ghcr.io/v2/homebrew/core/omega/blobs\",\"files\":{" ++
        "\"arm64_sequoia\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/omega-arm\",\"sha256\":\"" ++ storeKey("c0") ++ "\"}," ++
        "\"arm64_sonoma\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/omega-arm\",\"sha256\":\"" ++ storeKey("c0") ++ "\"}," ++
        "\"arm64_ventura\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/omega-arm\",\"sha256\":\"" ++ storeKey("c0") ++ "\"}," ++
        "\"arm64_monterey\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/omega-arm\",\"sha256\":\"" ++ storeKey("c0") ++ "\"}," ++
        "\"sequoia\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/omega-x86\",\"sha256\":\"" ++ storeKey("c1") ++ "\"}," ++
        "\"sonoma\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/omega-x86\",\"sha256\":\"" ++ storeKey("c1") ++ "\"}," ++
        "\"ventura\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/omega-x86\",\"sha256\":\"" ++ storeKey("c1") ++ "\"}," ++
        "\"monterey\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/omega-x86\",\"sha256\":\"" ++ storeKey("c1") ++ "\"}" ++
        "}}}}";
    try seedCache(cache_dir, "alpha", alpha_json);
    try seedCache(cache_dir, "omega", omega_json);
    try seedCache(cache_dir, "shared_lib", bottleJsonUniqueSha("shared_lib", "0a"));

    var http_pool = try malt.client_pool.HttpClientPool.init(std.Options.debug_io, std.process.Environ.empty, alloc, 2);
    defer http_pool.deinit();
    var real_http = malt.client.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, alloc);
    defer real_http.deinit();
    var api = malt.api.BrewApi.init(std.Options.debug_io, alloc, &real_http, cache_dir);

    var store_inst: malt.store.Store = undefined;
    var jobs: std.ArrayList(install_download.DownloadJob) = .empty;
    defer {
        for (jobs.items) |job| {
            alloc.free(job.name);
            alloc.free(job.version_str);
            alloc.free(job.sha256);
            alloc.free(job.bottle_url);
            alloc.free(job.cellar_type);
            if (job.is_dep) alloc.free(job.formula_json);
        }
        jobs.deinit(alloc);
    }

    var formula_cache = deps_mod.FormulaCache.init(alloc);
    defer formula_cache.deinit();

    const ctx: install_download.InstallJobDeps = .{
        .io = std.Options.debug_io,
        .allocator = alloc,
        .api = &api,
        .http_pool = &http_pool,
        .db = &tdb.db,
        .store = &store_inst,
        .cache = &formula_cache,
        .worker_backing = alloc,
    };

    try install_download.collectFormulaJobs(ctx, "alpha", alpha_json, false, &jobs);
    try install_download.collectFormulaJobs(ctx, "omega", omega_json, false, &jobs);

    // 3 unique formulas (alpha, omega, shared_lib); shared_lib parses once.
    try testing.expectEqual(@as(usize, 3), formula_cache.parse_count);
    try testing.expectEqual(@as(usize, 3), formula_cache.entryCount());
    // shared_lib appears in jobs exactly once (sha-based dedup in collectFormulaJobs).
    var shared_count: usize = 0;
    for (jobs.items) |j| {
        if (std.mem.eql(u8, j.name, "shared_lib")) shared_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), shared_count);
}

test "findFailedDep reads from cache without re-parsing the JSON" {
    const alloc = testing.allocator;

    var cache = deps_mod.FormulaCache.init(alloc);
    defer cache.deinit();

    const json =
        \\{
        \\  "name": "curl",
        \\  "full_name": "curl",
        \\  "tap": "",
        \\  "desc": "",
        \\  "homepage": "",
        \\  "revision": 0,
        \\  "keg_only": false,
        \\  "post_install_defined": false,
        \\  "versions": { "stable": "1.0" },
        \\  "dependencies": ["libssh2", "openssl@3", "zstd"],
        \\  "oldnames": []
        \\}
    ;

    _ = try cache.getOrParse("curl", json);
    try testing.expectEqual(@as(usize, 1), cache.parse_count);

    var failed = std.StringHashMap(void).init(alloc);
    defer failed.deinit();
    try failed.put("openssl@3", {});

    const result = install_download.findFailedDep(&cache, &failed, "curl", json) orelse
        return error.TestExpectedFailedDep;
    try testing.expectEqualStrings("openssl@3", result);

    // Lookup hit the cache; no second parse.
    try testing.expectEqual(@as(usize, 1), cache.parse_count);
}

const Seed = struct { name: []const u8, json: []const u8 };

/// Seeds `seeds` into a fresh API cache and runs `collectFormulaJobs` for the
/// first seed. Caller frees `jobs` with `freeJobs`.
const CollectOpts = struct {
    offline: bool = false,
    only_deps: bool = false,
    /// Allocator for the collect itself (and `jobs`); setup stays on `alloc`.
    collect_alloc: ?std.mem.Allocator = null,
    /// Backs the dependency-prefetch workers; defaults to `alloc`.
    worker_backing: ?std.mem.Allocator = null,
};

fn collectFirst(
    alloc: std.mem.Allocator,
    tag: []const u8,
    seeds: []const Seed,
    opts: CollectOpts,
    jobs: *std.ArrayList(install_download.DownloadJob),
) !void {
    const offline = opts.offline;
    const collect_alloc = opts.collect_alloc orelse alloc;
    var tdb = try TempDb.init(alloc, tag);
    defer tdb.deinit();

    const cache_dir = try uniqueTempPath(alloc, tag);
    defer alloc.free(cache_dir);
    test_io.deleteTreeAbsolute(std.Options.debug_io, cache_dir) catch {};
    test_io.makeDirAbsolute(std.Options.debug_io, cache_dir) catch {};
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, cache_dir) catch {};
    for (seeds) |s| {
        try seedCache(cache_dir, s.name, s.json);
        if (offline) try ageCacheEntry(cache_dir, s.name);
    }

    var http_pool = try malt.client_pool.HttpClientPool.init(std.Options.debug_io, std.process.Environ.empty, alloc, 2);
    defer http_pool.deinit();
    var real_http = malt.client.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, alloc);
    defer real_http.deinit();
    var api = malt.api.BrewApi.init(std.Options.debug_io, collect_alloc, &real_http, cache_dir);
    api.offline = offline;
    // A dead loopback port: any fetch that ignores offline fails fast here.
    if (offline) api.base_url = "http://127.0.0.1:9";

    var store_inst: malt.store.Store = undefined;
    var formula_cache = deps_mod.FormulaCache.init(alloc);
    defer formula_cache.deinit();

    return install_download.collectFormulaJobs(.{
        .io = std.Options.debug_io,
        .allocator = collect_alloc,
        .api = &api,
        .http_pool = &http_pool,
        .db = &tdb.db,
        .store = &store_inst,
        .cache = &formula_cache,
        .worker_backing = opts.worker_backing orelse alloc,
        .only_deps = opts.only_deps,
    }, seeds[0].name, seeds[0].json, false, jobs);
}

/// Past the API cache TTL, so only an offline read may serve it.
fn ageCacheEntry(cache_dir: []const u8, name: []const u8) !void {
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/api/formula_{s}.json", .{ cache_dir, name });
    const f = try test_io.cwd().openFile(std.Options.debug_io, path, .{ .mode = .write_only });
    defer f.close(std.Options.debug_io);
    try f.setTimestamps(std.Options.debug_io, .{
        .access_timestamp = .{ .new = .{ .nanoseconds = 0 } },
        .modify_timestamp = .{ .new = .{ .nanoseconds = 0 } },
    });
}

fn freeJobs(alloc: std.mem.Allocator, jobs: *std.ArrayList(install_download.DownloadJob)) void {
    for (jobs.items) |job| {
        alloc.free(job.name);
        alloc.free(job.version_str);
        alloc.free(job.sha256);
        alloc.free(job.bottle_url);
        alloc.free(job.cellar_type);
        if (job.is_dep) alloc.free(job.formula_json);
    }
    jobs.deinit(alloc);
}

/// `json` with its empty dependency list replaced by `deps`.
fn withDeps(comptime json: []const u8, comptime deps: []const u8) []const u8 {
    const empty = "\"dependencies\":[]";
    const at = comptime std.mem.indexOf(u8, json, empty).?;
    return comptime json[0..at] ++ "\"dependencies\":[" ++ deps ++ "]" ++ json[at + empty.len ..];
}

/// A control byte in the version: the record parser refuses it.
fn refusedRecord(comptime name: []const u8, comptime tag: []const u8) []const u8 {
    const valid = comptime bottleJsonUniqueSha(name, tag);
    const stable = "\"stable\":\"1.0\"";
    const at = comptime std.mem.indexOf(u8, valid, stable).?;
    return comptime valid[0..at] ++ "\"stable\":\"1.\\r\"" ++ valid[at + stable.len ..];
}

/// `p` must fail with `want`, name `refused` on stderr, and queue nothing.
fn expectParentRefused(tag: []const u8, seeds: []const Seed, refused: []const u8, want: anyerror) !void {
    const alloc = testing.allocator;

    const prior_quiet = malt.output.isQuiet();
    malt.output.setQuiet(false);
    defer malt.output.setQuiet(prior_quiet);
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(alloc);
    malt.output.beginStderrCapture(alloc, &captured);
    defer malt.output.endStderrCapture();

    var jobs: std.ArrayList(install_download.DownloadJob) = .empty;
    defer freeJobs(alloc, &jobs);

    try testing.expectError(want, collectFirst(alloc, tag, seeds, .{}, &jobs));

    try testing.expectEqual(@as(usize, 0), jobs.items.len);
    const line = try std.fmt.allocPrint(alloc, "Cannot install p: dependency {s} ", .{refused});
    defer alloc.free(line);
    try testing.expect(std.mem.indexOf(u8, captured.items, line) != null);
}

// `q_ok` is listed before the refused dep, so a check made while queueing
// would already have queued it: nothing may reach the plan.
test "collectFormulaJobs refuses the parent of a dependency whose record is refused" {
    try expectParentRefused("refused_dep_record", &.{
        .{ .name = "p", .json = withDeps(bottleJsonUniqueSha("p", "c0"), "\"q_ok\",\"q_bad\"") },
        .{ .name = "q_ok", .json = bottleJsonUniqueSha("q_ok", "c1") },
        .{ .name = "q_bad", .json = refusedRecord("q_bad", "c2") },
    }, "q_bad", error.DependencyFailed);
}

test "collectFormulaJobs names an out-of-memory prefetch instead of calling the dependency unfetchable" {
    const alloc = testing.allocator;
    const prior_quiet = malt.output.isQuiet();
    malt.output.setQuiet(false);
    defer malt.output.setQuiet(prior_quiet);
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(alloc);
    malt.output.beginStderrCapture(alloc, &captured);
    defer malt.output.endStderrCapture();

    var jobs: std.ArrayList(install_download.DownloadJob) = .empty;
    defer freeJobs(alloc, &jobs);

    // Offline keeps a wrongful network fallback off the wire.
    try testing.expectError(error.DependencyFailed, collectFirst(alloc, "prefetch_oom", &.{
        .{ .name = "p", .json = withDeps(bottleJsonUniqueSha("p", "e0"), "\"q_ok\"") },
        .{ .name = "q_ok", .json = bottleJsonUniqueSha("q_ok", "e1") },
    }, .{ .offline = true, .worker_backing = std.testing.failing_allocator }, &jobs));
    try testing.expect(std.mem.indexOf(u8, captured.items, "dependency q_ok could not be fetched: OutOfMemory") != null);
}

test "collectFormulaJobs refuses the parent of a dependency with no bottle" {
    const no_bottle =
        \\{"name":"q_nob","full_name":"q_nob","tap":"homebrew/core","desc":"","homepage":"",
        \\"revision":0,"keg_only":false,"post_install_defined":false,
        \\"versions":{"stable":"1.0"},"dependencies":[],"oldnames":[],"bottle":{}}
    ;
    try expectParentRefused("refused_dep_bottle", &.{
        .{ .name = "p", .json = withDeps(bottleJsonUniqueSha("p", "c0"), "\"q_ok\",\"q_nob\"") },
        .{ .name = "q_ok", .json = bottleJsonUniqueSha("q_ok", "c1") },
        .{ .name = "q_nob", .json = no_bottle },
    }, "q_nob", error.DependencyFailed);
}

// The refused record sits two levels down, reached only through a valid dep.
test "collectFormulaJobs refuses the parent of a refused transitive dependency" {
    try expectParentRefused("refused_dep_transitive", &.{
        .{ .name = "p", .json = withDeps(bottleJsonUniqueSha("p", "c0"), "\"q_ok\"") },
        .{ .name = "q_ok", .json = withDeps(bottleJsonUniqueSha("q_ok", "c1"), "\"q_bad\"") },
        .{ .name = "q_bad", .json = refusedRecord("q_bad", "c2") },
    }, "q_bad", error.DependencyFailed);
}

// The refusal must not turn a stale offline cache into "could not be
// fetched": offline serves a cached record at any age.
test "collectFormulaJobs queues a stale cached dependency when offline" {
    const alloc = testing.allocator;
    var jobs: std.ArrayList(install_download.DownloadJob) = .empty;
    defer freeJobs(alloc, &jobs);

    try collectFirst(alloc, "offline_stale_dep", &.{
        .{ .name = "p", .json = withDeps(bottleJsonUniqueSha("p", "c0"), "\"q_ok\"") },
        .{ .name = "q_ok", .json = bottleJsonUniqueSha("q_ok", "c1") },
    }, .{ .offline = true }, &jobs);

    try testing.expectEqual(@as(usize, 2), jobs.items.len);
}

fn noBottleRecord(comptime name: []const u8) []const u8 {
    return comptime "{\"name\":\"" ++ name ++ "\",\"full_name\":\"" ++ name ++ "\"," ++
        "\"tap\":\"homebrew/core\",\"desc\":\"\",\"homepage\":\"\",\"revision\":0," ++
        "\"keg_only\":false,\"post_install_defined\":false,\"versions\":{\"stable\":\"1.0\"}," ++
        "\"dependencies\":[],\"oldnames\":[],\"bottle\":{}}";
}

test "collectFormulaJobs queues none of a bottle-less parent's deps" {
    const alloc = testing.allocator;
    var jobs: std.ArrayList(install_download.DownloadJob) = .empty;
    defer freeJobs(alloc, &jobs);

    try testing.expectError(error.NoBottle, collectFirst(alloc, "nobottle_parent", &.{
        .{ .name = "p", .json = withDeps(noBottleRecord("p"), "\"q_ok\"") },
        .{ .name = "q_ok", .json = bottleJsonUniqueSha("q_ok", "c1") },
    }, .{}, &jobs));
    try testing.expectEqual(@as(usize, 0), jobs.items.len);
}

// --only-deps never installs the parent, so its deps still go ahead.
test "collectFormulaJobs still queues a bottle-less parent's deps under --only-deps" {
    const alloc = testing.allocator;
    var jobs: std.ArrayList(install_download.DownloadJob) = .empty;
    defer freeJobs(alloc, &jobs);

    try testing.expectError(error.NoBottle, collectFirst(alloc, "nobottle_parent_only_deps", &.{
        .{ .name = "p", .json = withDeps(noBottleRecord("p"), "\"q_ok\"") },
        .{ .name = "q_ok", .json = bottleJsonUniqueSha("q_ok", "c1") },
    }, .{ .only_deps = true }, &jobs));
    try testing.expectEqual(@as(usize, 1), jobs.items.len);
    try testing.expectEqualStrings("q_ok", jobs.items[0].name);
}

/// A job another package queued earlier in the same run.
fn earlierJob(a: std.mem.Allocator) !install_download.DownloadJob {
    return .{
        .name = try a.dupe(u8, "earlier"),
        .version_str = try a.dupe(u8, "1.0"),
        .sha256 = try a.dupe(u8, "e0"),
        .bottle_url = try a.dupe(u8, "https://example.invalid/earlier"),
        .is_dep = false,
        .keg_only = false,
        .wants_post_install = false,
        .formula_json = "",
        .cellar_type = try a.dupe(u8, ":any"),
        .label_width = 0,
        .line_index = 0,
        .multi = null,
        .bar = null,
        .store_sha256 = "",
        .succeeded = false,
    };
}

// Every allocation in turn fails: a failed collect must drop only its own
// jobs, keep the ones earlier packages queued, and leak nothing.
test "collectFormulaJobs drops only its own jobs when an allocation fails" {
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();

    const seeds: []const Seed = &.{
        .{ .name = "p", .json = withDeps(bottleJsonUniqueSha("p", "c0"), "\"q_a\",\"q_b\"") },
        .{ .name = "q_a", .json = bottleJsonUniqueSha("q_a", "c1") },
        .{ .name = "q_b", .json = bottleJsonUniqueSha("q_b", "c2") },
    };
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const fa = failing.allocator();
        var jobs: std.ArrayList(install_download.DownloadJob) = .empty;
        defer freeJobs(fa, &jobs);
        try jobs.append(testing.allocator, try earlierJob(testing.allocator));

        if (collectFirst(testing.allocator, "oom_rollback", seeds, .{ .collect_alloc = fa }, &jobs)) |_| {
            if (!failing.has_induced_failure) break;
        } else |_| {
            try testing.expectEqual(@as(usize, 1), jobs.items.len);
            try testing.expectEqualStrings("earlier", jobs.items[0].name);
        }
    }
    // The sweep must have reached past the queueing, not stopped at setup.
    try testing.expect(fail_index > 3);
}
