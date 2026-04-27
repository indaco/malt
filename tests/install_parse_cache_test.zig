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
const install = malt.install;
const deps_mod = malt.deps;
const sqlite = malt.sqlite;
const schema = malt.schema;

const TempDb = struct {
    dir: []const u8,
    db: sqlite.Database,

    fn init(comptime tag: []const u8) !TempDb {
        const dir = "/tmp/malt_parse_cache_test_" ++ tag;
        malt.fs_compat.makeDirAbsolute(dir) catch {};
        var db_path_buf: [256]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/test.db", .{dir}, 0);
        var db = try sqlite.Database.open(db_path);
        errdefer db.close();
        try schema.initSchema(&db);
        return .{ .dir = dir, .db = db };
    }

    fn deinit(self: *TempDb) void {
        self.db.close();
        malt.fs_compat.deleteTreeAbsolute(self.dir) catch {};
    }
};

fn seedCache(cache_dir: []const u8, name: []const u8, json: []const u8) !void {
    var api_buf: [512]u8 = undefined;
    const api_dir = try std.fmt.bufPrint(&api_buf, "{s}/api", .{cache_dir});
    malt.fs_compat.makeDirAbsolute(api_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/api/formula_{s}.json", .{ cache_dir, name });
    const f = try malt.fs_compat.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(json);
}

/// Unique sha per dep so the dedup branch can't collapse jobs.
fn bottleJsonUniqueSha(comptime name: []const u8, comptime tag: []const u8) []const u8 {
    return "{\"name\":\"" ++ name ++ "\"," ++
        "\"full_name\":\"" ++ name ++ "\"," ++
        "\"tap\":\"homebrew/core\"," ++
        "\"desc\":\"\",\"homepage\":\"\",\"revision\":0," ++
        "\"keg_only\":false,\"post_install_defined\":false," ++
        "\"versions\":{\"stable\":\"1.0\"}," ++
        "\"dependencies\":[],\"oldnames\":[]," ++
        "\"bottle\":{\"stable\":{\"root_url\":\"https://ghcr.io/v2/homebrew/core/" ++ name ++ "/blobs\"," ++
        "\"files\":{" ++
        "\"arm64_sequoia\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/" ++ name ++ "-arm\",\"sha256\":\"" ++ tag ++ "a\"}," ++
        "\"arm64_sonoma\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/" ++ name ++ "-arm\",\"sha256\":\"" ++ tag ++ "a\"}," ++
        "\"arm64_ventura\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/" ++ name ++ "-arm\",\"sha256\":\"" ++ tag ++ "a\"}," ++
        "\"arm64_monterey\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/" ++ name ++ "-arm\",\"sha256\":\"" ++ tag ++ "a\"}," ++
        "\"sequoia\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/" ++ name ++ "-x86\",\"sha256\":\"" ++ tag ++ "x\"}," ++
        "\"sonoma\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/" ++ name ++ "-x86\",\"sha256\":\"" ++ tag ++ "x\"}," ++
        "\"ventura\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/" ++ name ++ "-x86\",\"sha256\":\"" ++ tag ++ "x\"}," ++
        "\"monterey\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/" ++ name ++ "-x86\",\"sha256\":\"" ++ tag ++ "x\"}" ++
        "}}}}";
}

fn rootJsonWithFiveDeps() []const u8 {
    return "{\"name\":\"root\"," ++
        "\"full_name\":\"root\"," ++
        "\"tap\":\"homebrew/core\"," ++
        "\"desc\":\"\",\"homepage\":\"\",\"revision\":0," ++
        "\"keg_only\":false,\"post_install_defined\":false," ++
        "\"versions\":{\"stable\":\"1.0\"}," ++
        "\"dependencies\":[\"d_a\",\"d_b\",\"d_c\",\"d_d\",\"d_e\"]," ++
        "\"oldnames\":[]," ++
        "\"bottle\":{\"stable\":{\"root_url\":\"https://ghcr.io/v2/homebrew/core/root/blobs\"," ++
        "\"files\":{" ++
        "\"arm64_sequoia\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/root-arm\",\"sha256\":\"r0\"}," ++
        "\"arm64_sonoma\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/root-arm\",\"sha256\":\"r0\"}," ++
        "\"arm64_ventura\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/root-arm\",\"sha256\":\"r0\"}," ++
        "\"arm64_monterey\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/root-arm\",\"sha256\":\"r0\"}," ++
        "\"sequoia\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/root-x86\",\"sha256\":\"r1\"}," ++
        "\"sonoma\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/root-x86\",\"sha256\":\"r1\"}," ++
        "\"ventura\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/root-x86\",\"sha256\":\"r1\"}," ++
        "\"monterey\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/root-x86\",\"sha256\":\"r1\"}" ++
        "}}}}";
}

test "collectFormulaJobs parses each formula exactly once via shared cache" {
    const alloc = testing.allocator;

    var tdb = try TempDb.init("six_dep_cache");
    defer tdb.deinit();

    const cache_dir = "/tmp/malt_parse_cache_test_six_dep_cache_apicache";
    malt.fs_compat.deleteTreeAbsolute(cache_dir) catch {};
    malt.fs_compat.makeDirAbsolute(cache_dir) catch {};
    defer malt.fs_compat.deleteTreeAbsolute(cache_dir) catch {};

    const root_json = rootJsonWithFiveDeps();
    try seedCache(cache_dir, "root", root_json);
    try seedCache(cache_dir, "d_a", bottleJsonUniqueSha("d_a", "aa"));
    try seedCache(cache_dir, "d_b", bottleJsonUniqueSha("d_b", "bb"));
    try seedCache(cache_dir, "d_c", bottleJsonUniqueSha("d_c", "cc"));
    try seedCache(cache_dir, "d_d", bottleJsonUniqueSha("d_d", "dd"));
    try seedCache(cache_dir, "d_e", bottleJsonUniqueSha("d_e", "ee"));

    var http_pool = try malt.client.HttpClientPool.init(alloc, 2);
    defer http_pool.deinit();
    var real_http = malt.client.HttpClient.init(alloc);
    defer real_http.deinit();
    var api = malt.api.BrewApi.init(alloc, &real_http, cache_dir);

    var store_inst: malt.store.Store = undefined;
    var jobs: std.ArrayList(install.DownloadJob) = .empty;
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

    try install.collectFormulaJobs(
        .{
            .allocator = alloc,
            .api = &api,
            .http_pool = &http_pool,
            .db = &tdb.db,
            .store = &store_inst,
            .cache = &formula_cache,
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

    var tdb = try TempDb.init("bound");
    defer tdb.deinit();

    const cache_dir = "/tmp/malt_parse_cache_test_bound_apicache";
    malt.fs_compat.deleteTreeAbsolute(cache_dir) catch {};
    malt.fs_compat.makeDirAbsolute(cache_dir) catch {};
    defer malt.fs_compat.deleteTreeAbsolute(cache_dir) catch {};

    const root_json = rootJsonWithFiveDeps();
    try seedCache(cache_dir, "root", root_json);
    try seedCache(cache_dir, "d_a", bottleJsonUniqueSha("d_a", "aa"));
    try seedCache(cache_dir, "d_b", bottleJsonUniqueSha("d_b", "bb"));
    try seedCache(cache_dir, "d_c", bottleJsonUniqueSha("d_c", "cc"));
    try seedCache(cache_dir, "d_d", bottleJsonUniqueSha("d_d", "dd"));
    try seedCache(cache_dir, "d_e", bottleJsonUniqueSha("d_e", "ee"));

    var http_pool = try malt.client.HttpClientPool.init(alloc, 2);
    defer http_pool.deinit();
    var real_http = malt.client.HttpClient.init(alloc);
    defer real_http.deinit();
    var api = malt.api.BrewApi.init(alloc, &real_http, cache_dir);

    var store_inst: malt.store.Store = undefined;
    var jobs: std.ArrayList(install.DownloadJob) = .empty;
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

    try install.collectFormulaJobs(
        .{
            .allocator = alloc,
            .api = &api,
            .http_pool = &http_pool,
            .db = &tdb.db,
            .store = &store_inst,
            .cache = &formula_cache,
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

    const cache_dir = "/tmp/malt_parse_cache_test_no_name_apicache";
    malt.fs_compat.deleteTreeAbsolute(cache_dir) catch {};
    malt.fs_compat.makeDirAbsolute(cache_dir) catch {};
    defer malt.fs_compat.deleteTreeAbsolute(cache_dir) catch {};

    var api_buf: [512]u8 = undefined;
    const api_dir = try std.fmt.bufPrint(&api_buf, "{s}/api", .{cache_dir});
    try malt.fs_compat.makeDirAbsolute(api_dir);

    // Minimal JSON — no `name` field. The cache cannot type-parse this,
    // but BFS still needs the dep list.
    const root_json = "{\"dependencies\":[\"leaf_one\",\"leaf_two\"]}";
    var root_buf: [512]u8 = undefined;
    const root_path = try std.fmt.bufPrint(&root_buf, "{s}/api/formula_thin.json", .{cache_dir});
    {
        const f = try malt.fs_compat.cwd().createFile(root_path, .{});
        defer f.close();
        try f.writeAll(root_json);
    }

    inline for (.{ "leaf_one", "leaf_two" }) |leaf| {
        var leaf_buf: [512]u8 = undefined;
        const leaf_path = try std.fmt.bufPrint(&leaf_buf, "{s}/api/formula_{s}.json", .{ cache_dir, leaf });
        const f = try malt.fs_compat.cwd().createFile(leaf_path, .{});
        defer f.close();
        try f.writeAll("{\"dependencies\":[]}");
    }

    var http = malt.client.HttpClient.init(alloc);
    defer http.deinit();
    var api = malt.api.BrewApi.init(alloc, &http, cache_dir);

    var tdb = try TempDb.init("no_name");
    defer tdb.deinit();

    var formula_cache = deps_mod.FormulaCache.init(alloc);
    defer formula_cache.deinit();

    const result = try deps_mod.resolve(alloc, "thin", &api, &tdb.db, &formula_cache);
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

    var tdb = try TempDb.init("multi_pkg");
    defer tdb.deinit();

    const cache_dir = "/tmp/malt_parse_cache_test_multi_pkg_apicache";
    malt.fs_compat.deleteTreeAbsolute(cache_dir) catch {};
    malt.fs_compat.makeDirAbsolute(cache_dir) catch {};
    defer malt.fs_compat.deleteTreeAbsolute(cache_dir) catch {};

    // Two roots ("alpha", "omega") that share one dep ("shared_lib").
    const alpha_json = "{\"name\":\"alpha\"," ++
        "\"versions\":{\"stable\":\"1.0\"}," ++
        "\"dependencies\":[\"shared_lib\"]," ++
        "\"oldnames\":[]," ++
        "\"bottle\":{\"stable\":{\"root_url\":\"https://ghcr.io/v2/homebrew/core/alpha/blobs\",\"files\":{" ++
        "\"arm64_sequoia\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/alpha-arm\",\"sha256\":\"a0\"}," ++
        "\"arm64_sonoma\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/alpha-arm\",\"sha256\":\"a0\"}," ++
        "\"arm64_ventura\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/alpha-arm\",\"sha256\":\"a0\"}," ++
        "\"arm64_monterey\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/alpha-arm\",\"sha256\":\"a0\"}," ++
        "\"sequoia\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/alpha-x86\",\"sha256\":\"a1\"}," ++
        "\"sonoma\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/alpha-x86\",\"sha256\":\"a1\"}," ++
        "\"ventura\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/alpha-x86\",\"sha256\":\"a1\"}," ++
        "\"monterey\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/alpha-x86\",\"sha256\":\"a1\"}" ++
        "}}}}";
    const omega_json = "{\"name\":\"omega\"," ++
        "\"versions\":{\"stable\":\"1.0\"}," ++
        "\"dependencies\":[\"shared_lib\"]," ++
        "\"oldnames\":[]," ++
        "\"bottle\":{\"stable\":{\"root_url\":\"https://ghcr.io/v2/homebrew/core/omega/blobs\",\"files\":{" ++
        "\"arm64_sequoia\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/omega-arm\",\"sha256\":\"o0\"}," ++
        "\"arm64_sonoma\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/omega-arm\",\"sha256\":\"o0\"}," ++
        "\"arm64_ventura\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/omega-arm\",\"sha256\":\"o0\"}," ++
        "\"arm64_monterey\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/omega-arm\",\"sha256\":\"o0\"}," ++
        "\"sequoia\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/omega-x86\",\"sha256\":\"o1\"}," ++
        "\"sonoma\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/omega-x86\",\"sha256\":\"o1\"}," ++
        "\"ventura\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/omega-x86\",\"sha256\":\"o1\"}," ++
        "\"monterey\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/omega-x86\",\"sha256\":\"o1\"}" ++
        "}}}}";
    try seedCache(cache_dir, "alpha", alpha_json);
    try seedCache(cache_dir, "omega", omega_json);
    try seedCache(cache_dir, "shared_lib", bottleJsonUniqueSha("shared_lib", "ss"));

    var http_pool = try malt.client.HttpClientPool.init(alloc, 2);
    defer http_pool.deinit();
    var real_http = malt.client.HttpClient.init(alloc);
    defer real_http.deinit();
    var api = malt.api.BrewApi.init(alloc, &real_http, cache_dir);

    var store_inst: malt.store.Store = undefined;
    var jobs: std.ArrayList(install.DownloadJob) = .empty;
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

    const ctx: install.InstallJobDeps = .{
        .allocator = alloc,
        .api = &api,
        .http_pool = &http_pool,
        .db = &tdb.db,
        .store = &store_inst,
        .cache = &formula_cache,
    };

    try install.collectFormulaJobs(ctx, "alpha", alpha_json, false, &jobs);
    try install.collectFormulaJobs(ctx, "omega", omega_json, false, &jobs);

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

    const result = install.findFailedDep(&cache, &failed, "curl", json) orelse
        return error.TestExpectedFailedDep;
    try testing.expectEqualStrings("openssl@3", result);

    // Lookup hit the cache; no second parse.
    try testing.expectEqual(@as(usize, 1), cache.parse_count);
}
