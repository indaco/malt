//! malt — install command tests
//!
//! Covers the early-abort branches of `collectFormulaJobs` that can be
//! exercised without a live Homebrew API, and verifies that formulae
//! with a `post_install` hook are now allowed through the job-collection
//! phase (the DSL interpreter handles post_install after materialisation).

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const install = malt.install;
const sqlite = malt.sqlite;
const schema = malt.schema;

/// Fixture formula with `post_install_defined: true` and no dependencies.
/// Empty deps ensure the parallel-fetch phase is skipped so the test can
/// pass `undefined` for the HttpClientPool without crashing.
fn postInstallFormulaJson() []const u8 {
    return "{\"name\":\"needs-ruby\"," ++
        "\"full_name\":\"needs-ruby\"," ++
        "\"tap\":\"homebrew/core\"," ++
        "\"desc\":\"Fixture formula with a post_install hook\"," ++
        "\"homepage\":\"\",\"revision\":0," ++
        "\"keg_only\":false,\"post_install_defined\":true," ++
        "\"versions\":{\"stable\":\"1.0\"}," ++
        "\"dependencies\":[],\"oldnames\":[]," ++
        "\"bottle\":{\"stable\":{\"root_url\":\"https://ghcr.io/v2/homebrew/core/needs-ruby/blobs\"," ++
        "\"files\":{" ++
        "\"arm64_sequoia\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/needs-ruby\",\"sha256\":\"deadbeef\"}," ++
        "\"arm64_sonoma\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/needs-ruby\",\"sha256\":\"deadbeef\"}," ++
        "\"arm64_ventura\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/needs-ruby\",\"sha256\":\"deadbeef\"}," ++
        "\"arm64_monterey\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/needs-ruby\",\"sha256\":\"deadbeef\"}," ++
        "\"sequoia\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/needs-ruby\",\"sha256\":\"deadbeef\"}," ++
        "\"sonoma\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/needs-ruby\",\"sha256\":\"deadbeef\"}," ++
        "\"ventura\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/needs-ruby\",\"sha256\":\"deadbeef\"}," ++
        "\"monterey\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/needs-ruby\",\"sha256\":\"deadbeef\"}" ++
        "}}}}";
}

/// Opens a fresh temp-dir SQLite DB with the current schema applied.
/// The caller is responsible for closing the returned DB and removing
/// the temp dir.
const TempDb = struct {
    dir: []const u8,
    db: sqlite.Database,

    fn init(comptime tag: []const u8) !TempDb {
        const dir = "/tmp/malt_install_test_" ++ tag;
        malt.fs_compat.makeDirAbsolute(dir) catch {};
        var db_path_buf: [256]u8 = undefined;
        const db_path = try std.fmt.bufPrint(&db_path_buf, "{s}/test.db", .{dir});
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

// Formula.deinit() doesn't free derived allocations (bottle_files map,
// dependencies slice, oldnames), so collectFormulaJobs — which calls
// parseFormula on our behalf — leaks if we hand it the testing allocator
// directly. Using an arena mirrors the pattern in tests/formula_test.zig
// and avoids false-positive leak reports from testing.allocator.
fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

test "collectFormulaJobs queues a formula with a post_install hook" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var tdb = try TempDb.init("postinstall_accept");
    defer tdb.deinit();

    // The fixture has no dependencies, so the parallel-fetch phase is
    // skipped and the API / pool pointers are never dereferenced.
    const json = postInstallFormulaJson();

    const cache_dir = "/tmp/malt_install_test_postinstall_accept_cache";
    malt.fs_compat.makeDirAbsolute(cache_dir) catch {};
    defer malt.fs_compat.deleteTreeAbsolute(cache_dir) catch {};

    var http = try malt.client.HttpClientPool.init(alloc, 1);
    defer http.deinit();
    var real_http = malt.client.HttpClient.init(alloc);
    defer real_http.deinit();
    var api = malt.api.BrewApi.init(alloc, &real_http, cache_dir);

    var store_inst: malt.store.Store = undefined;

    var jobs: std.ArrayList(install.DownloadJob) = .empty;
    defer jobs.deinit(alloc);

    try install.collectFormulaJobs(
        alloc,
        "needs-ruby",
        json,
        &api,
        &http,
        &tdb.db,
        &store_inst,
        false,
        &jobs,
    );

    // The formula must now be queued — the DSL interpreter handles
    // post_install after materialisation, so the guard no longer rejects.
    try testing.expectEqual(@as(usize, 1), jobs.items.len);
    try testing.expectEqualStrings("needs-ruby", jobs.items[0].name);
    try testing.expect(jobs.items[0].post_install_defined);
}

// --- Pure helper tests (no DB / network) ---

test "checkPrefixLength accepts prefix at the limit" {
    try install.checkPrefixLength("/opt/homebrew");
}

test "checkPrefixLength accepts a short prefix" {
    try install.checkPrefixLength("/opt/m");
}

test "checkPrefixLength rejects a too-long prefix" {
    try testing.expectError(
        install.PrefixError.PrefixTooLong,
        install.checkPrefixLength("/opt/homebrew-longer"),
    );
}

test "isTapFormula detects three-part user/repo/formula names" {
    try testing.expect(install.isTapFormula("user/repo/formula"));
    try testing.expect(!install.isTapFormula("formula"));
    try testing.expect(!install.isTapFormula("user/formula"));
    try testing.expect(!install.isTapFormula("a/b/c/d"));
}

test "parseTapName splits user/repo/formula" {
    const parts = install.parseTapName("homebrew/core/wget") orelse unreachable;
    try testing.expectEqualStrings("homebrew", parts.user);
    try testing.expectEqualStrings("core", parts.repo);
    try testing.expectEqualStrings("wget", parts.formula);
}

test "parseTapName returns null for non-tap names" {
    try testing.expect(install.parseTapName("wget") == null);
    try testing.expect(install.parseTapName("user/repo") == null);
}

test "buildGhcrRepo prepends homebrew/core" {
    var buf: [128]u8 = undefined;
    const out = try install.buildGhcrRepo(&buf, "wget");
    try testing.expectEqualStrings("homebrew/core/wget", out);
}

test "buildGhcrRepo replaces @ with /" {
    var buf: [128]u8 = undefined;
    const out = try install.buildGhcrRepo(&buf, "openssl@3");
    try testing.expectEqualStrings("homebrew/core/openssl/3", out);
}

test "buildGhcrRepo errors when buffer too small" {
    var buf: [4]u8 = undefined;
    try testing.expectError(error.OutOfMemory, install.buildGhcrRepo(&buf, "wget"));
}

test "extractQuoted returns the quoted value after a prefix" {
    const line = "  version \"1.2.3\"";
    const value = install.extractQuoted(line, "version \"") orelse unreachable;
    try testing.expectEqualStrings("1.2.3", value);
}

test "extractQuoted returns null when prefix missing" {
    try testing.expect(install.extractQuoted("foo bar", "version \"") == null);
}

test "extractQuoted returns null when closing quote missing" {
    try testing.expect(install.extractQuoted("version \"unterminated", "version \"") == null);
}

test "parseRubyFormula extracts version url and sha from a platform block" {
    const rb =
        \\class Malt < Formula
        \\  desc "test"
        \\  version "1.0.0"
        \\  on_macos do
        \\    on_arm do
        \\      url "https://example.com/malt-arm.tar.gz"
        \\      sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\    end
        \\    on_intel do
        \\      url "https://example.com/malt-x86.tar.gz"
        \\      sha256 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        \\    end
        \\  end
        \\end
    ;
    const info = install.parseRubyFormula(rb) orelse unreachable;
    try testing.expectEqualStrings("1.0.0", info.version);
    try testing.expect(std.mem.startsWith(u8, info.url, "https://example.com/malt-"));
    try testing.expect(info.sha256.len == 64);
}

test "parseRubyFormula fallback uses global url and sha when no platform block" {
    const rb =
        \\class Simple < Formula
        \\  version "2.0.0"
        \\  url "https://example.com/simple.tar.gz"
        \\  sha256 "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
        \\end
    ;
    const info = install.parseRubyFormula(rb) orelse unreachable;
    try testing.expectEqualStrings("2.0.0", info.version);
    try testing.expectEqualStrings("https://example.com/simple.tar.gz", info.url);
}

test "parseRubyFormula returns null when version missing" {
    const rb =
        \\class Broken < Formula
        \\  url "https://example.com/x.tar.gz"
        \\  sha256 "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
        \\end
    ;
    try testing.expect(install.parseRubyFormula(rb) == null);
}

test "findFailedDep reports the first dep already known-broken" {
    var failed = std.StringHashMap(void).init(testing.allocator);
    defer failed.deinit();
    try failed.put("openssl@3", {});

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
    const result = install.findFailedDep(&failed, json) orelse unreachable;
    try testing.expectEqualStrings("openssl@3", result);
}

test "findFailedDep returns null when no dep is known-broken" {
    var failed = std.StringHashMap(void).init(testing.allocator);
    defer failed.deinit();
    try failed.put("not-a-dep", {});

    const json =
        \\{
        \\  "name": "hello",
        \\  "full_name": "hello",
        \\  "tap": "",
        \\  "desc": "",
        \\  "homepage": "",
        \\  "revision": 0,
        \\  "keg_only": false,
        \\  "post_install_defined": false,
        \\  "versions": { "stable": "1.0" },
        \\  "dependencies": [],
        \\  "oldnames": []
        \\}
    ;
    try testing.expect(install.findFailedDep(&failed, json) == null);
}

test "findFailedDep returns null on unparseable JSON" {
    var failed = std.StringHashMap(void).init(testing.allocator);
    defer failed.deinit();
    try testing.expect(install.findFailedDep(&failed, "not-json") == null);
}

// --- collectFormulaJobs happy path (seeded BrewApi cache, no network) ---

fn bottleJsonWithoutDeps(comptime name: []const u8) []const u8 {
    // Cover every macOS platform candidate so resolveBottle picks one
    // regardless of host arch + release.
    return "{\"name\":\"" ++ name ++ "\"," ++
        "\"full_name\":\"" ++ name ++ "\"," ++
        "\"tap\":\"homebrew/core\"," ++
        "\"desc\":\"\",\"homepage\":\"\",\"revision\":0," ++
        "\"keg_only\":false,\"post_install_defined\":false," ++
        "\"versions\":{\"stable\":\"1.0\"}," ++
        "\"dependencies\":[],\"oldnames\":[]," ++
        "\"bottle\":{\"stable\":{\"root_url\":\"https://ghcr.io/v2/homebrew/core/" ++ name ++ "/blobs\"," ++
        "\"files\":{" ++
        "\"arm64_sequoia\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/arm\",\"sha256\":\"aa\"}," ++
        "\"arm64_sonoma\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/arm\",\"sha256\":\"aa\"}," ++
        "\"arm64_ventura\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/arm\",\"sha256\":\"aa\"}," ++
        "\"arm64_monterey\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/arm\",\"sha256\":\"aa\"}," ++
        "\"sequoia\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/x86\",\"sha256\":\"xx\"}," ++
        "\"sonoma\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/x86\",\"sha256\":\"xx\"}," ++
        "\"ventura\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/x86\",\"sha256\":\"xx\"}," ++
        "\"monterey\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/x86\",\"sha256\":\"xx\"}" ++
        "}}}}";
}

test "collectFormulaJobs queues the main formula when nothing is installed" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var tdb = try TempDb.init("happy_path");
    defer tdb.deinit();

    // No dependencies and no post_install hook → happy path. The API and
    // store pointers are never dereferenced on this branch because the
    // empty dep list skips the parallel-fetch phase.
    const json = bottleJsonWithoutDeps("hello");

    const cache_dir = "/tmp/malt_install_test_happy_path_cache";
    malt.fs_compat.makeDirAbsolute(cache_dir) catch {};
    defer malt.fs_compat.deleteTreeAbsolute(cache_dir) catch {};

    var http = try malt.client.HttpClientPool.init(alloc, 1);
    defer http.deinit();
    // A real single-client HttpClient is safe because it's never touched
    // when deps.len == 0.
    var real_http = malt.client.HttpClient.init(alloc);
    defer real_http.deinit();
    var api = malt.api.BrewApi.init(alloc, &real_http, cache_dir);

    var store_inst: malt.store.Store = undefined;
    var jobs: std.ArrayList(install.DownloadJob) = .empty;
    defer jobs.deinit(alloc);

    try install.collectFormulaJobs(
        alloc,
        "hello",
        json,
        &api,
        &http,
        &tdb.db,
        &store_inst,
        false,
        &jobs,
    );

    try testing.expectEqual(@as(usize, 1), jobs.items.len);
    try testing.expectEqualStrings("hello", jobs.items[0].name);
    try testing.expectEqualStrings("1.0", jobs.items[0].version_str);
    try testing.expect(!jobs.items[0].is_dep);
}

test "collectFormulaJobs no-ops when the formula is already installed" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var tdb = try TempDb.init("already_installed");
    defer tdb.deinit();

    // Seed the kegs table so isInstalled() returns true.
    var stmt = try tdb.db.prepare(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, install_reason)
        \\VALUES ('hello', 'hello', '1.0', 'sha', '/tmp', 'direct');
    );
    defer stmt.finalize();
    _ = try stmt.step();

    const json = bottleJsonWithoutDeps("hello");

    var http: malt.client.HttpClientPool = undefined;
    var api: malt.api.BrewApi = undefined;
    var store_inst: malt.store.Store = undefined;
    var jobs: std.ArrayList(install.DownloadJob) = .empty;
    defer jobs.deinit(alloc);

    try install.collectFormulaJobs(
        alloc,
        "hello",
        json,
        &api,
        &http,
        &tdb.db,
        &store_inst,
        false, // force=false
        &jobs,
    );

    // Nothing queued — the early-return branch we care about for coverage.
    try testing.expectEqual(@as(usize, 0), jobs.items.len);
}

/// Seed a BrewApi cache_dir with a freshly-written formula JSON file
/// under the `formula_<name>.json` naming convention that readCache
/// honours. Used to avoid hitting the network when collectFormulaJobs
/// calls `api.fetchFormula` for dependencies.
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

fn formulaJsonWithDep(comptime name: []const u8, comptime dep: []const u8) []const u8 {
    return "{\"name\":\"" ++ name ++ "\"," ++
        "\"full_name\":\"" ++ name ++ "\"," ++
        "\"tap\":\"homebrew/core\"," ++
        "\"desc\":\"\",\"homepage\":\"\",\"revision\":0," ++
        "\"keg_only\":false,\"post_install_defined\":false," ++
        "\"versions\":{\"stable\":\"1.0\"}," ++
        "\"dependencies\":[\"" ++ dep ++ "\"],\"oldnames\":[]," ++
        "\"bottle\":{\"stable\":{\"root_url\":\"https://ghcr.io/v2/homebrew/core/" ++ name ++ "/blobs\"," ++
        "\"files\":{" ++
        "\"arm64_sequoia\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/arm\",\"sha256\":\"aa\"}," ++
        "\"arm64_sonoma\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/arm\",\"sha256\":\"aa\"}," ++
        "\"arm64_ventura\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/arm\",\"sha256\":\"aa\"}," ++
        "\"arm64_monterey\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/arm\",\"sha256\":\"aa\"}," ++
        "\"sequoia\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/x86\",\"sha256\":\"xx\"}," ++
        "\"sonoma\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/x86\",\"sha256\":\"xx\"}," ++
        "\"ventura\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/x86\",\"sha256\":\"xx\"}," ++
        "\"monterey\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/x86\",\"sha256\":\"xx\"}" ++
        "}}}}";
}

test "collectFormulaJobs queues a dep and its parent from a seeded cache" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var tdb = try TempDb.init("with_dep");
    defer tdb.deinit();

    const cache_dir = "/tmp/malt_install_test_with_dep_cache";
    malt.fs_compat.deleteTreeAbsolute(cache_dir) catch {};
    malt.fs_compat.makeDirAbsolute(cache_dir) catch {};
    defer malt.fs_compat.deleteTreeAbsolute(cache_dir) catch {};

    // Seed BOTH the dep and the root formula JSON. deps.resolve re-fetches
    // the root from the API to discover its dep list (even though
    // collectFormulaJobs already parsed it), so both must hit the cache to
    // avoid the network.
    const dep_json = bottleJsonWithoutDeps("beta");
    try seedCache(cache_dir, "beta", dep_json);
    const root_json = formulaJsonWithDep("alpha", "beta");
    try seedCache(cache_dir, "alpha", root_json);

    var http_pool = try malt.client.HttpClientPool.init(alloc, 2);
    defer http_pool.deinit();
    var real_http = malt.client.HttpClient.init(alloc);
    defer real_http.deinit();
    var api = malt.api.BrewApi.init(alloc, &real_http, cache_dir);

    var store_inst: malt.store.Store = undefined;
    var jobs: std.ArrayList(install.DownloadJob) = .empty;
    defer jobs.deinit(alloc);

    try install.collectFormulaJobs(
        alloc,
        "alpha",
        root_json,
        &api,
        &http_pool,
        &tdb.db,
        &store_inst,
        false,
        &jobs,
    );

    // Expect 2 jobs: beta (dep) first, then alpha (main formula).
    try testing.expectEqual(@as(usize, 2), jobs.items.len);
    try testing.expectEqualStrings("beta", jobs.items[0].name);
    try testing.expect(jobs.items[0].is_dep);
    try testing.expectEqualStrings("alpha", jobs.items[1].name);
    try testing.expect(!jobs.items[1].is_dep);
}

test "collectFormulaJobs deduplicates deps already queued by a prior call" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var tdb = try TempDb.init("dedup_dep");
    defer tdb.deinit();

    const cache_dir = "/tmp/malt_install_test_dedup_cache";
    malt.fs_compat.deleteTreeAbsolute(cache_dir) catch {};
    malt.fs_compat.makeDirAbsolute(cache_dir) catch {};
    defer malt.fs_compat.deleteTreeAbsolute(cache_dir) catch {};

    const dep_json = bottleJsonWithoutDeps("beta");
    try seedCache(cache_dir, "beta", dep_json);

    const root_a = formulaJsonWithDep("alpha", "beta");
    const root_b = formulaJsonWithDep("omega", "beta");
    try seedCache(cache_dir, "alpha", root_a);
    try seedCache(cache_dir, "omega", root_b);

    var http_pool = try malt.client.HttpClientPool.init(alloc, 2);
    defer http_pool.deinit();
    var real_http = malt.client.HttpClient.init(alloc);
    defer real_http.deinit();
    var api = malt.api.BrewApi.init(alloc, &real_http, cache_dir);

    var store_inst: malt.store.Store = undefined;
    var jobs: std.ArrayList(install.DownloadJob) = .empty;
    defer jobs.deinit(alloc);

    try install.collectFormulaJobs(alloc, "alpha", root_a, &api, &http_pool, &tdb.db, &store_inst, false, &jobs);
    try install.collectFormulaJobs(alloc, "omega", root_b, &api, &http_pool, &tdb.db, &store_inst, false, &jobs);

    // beta should appear exactly once. jobs: [beta, alpha, omega]
    var beta_count: usize = 0;
    for (jobs.items) |j| {
        if (std.mem.eql(u8, j.name, "beta")) beta_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), beta_count);
    try testing.expectEqual(@as(usize, 3), jobs.items.len);
}

test "collectFormulaJobs surfaces FormulaNotFound for unparseable JSON" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var tdb = try TempDb.init("bad_json");
    defer tdb.deinit();

    var http: malt.client.HttpClientPool = undefined;
    var api: malt.api.BrewApi = undefined;
    var store_inst: malt.store.Store = undefined;
    var jobs: std.ArrayList(install.DownloadJob) = .empty;
    defer jobs.deinit(alloc);

    try testing.expectError(
        install.InstallError.FormulaNotFound,
        install.collectFormulaJobs(
            alloc,
            "broken",
            "not-a-json",
            &api,
            &http,
            &tdb.db,
            &store_inst,
            false,
            &jobs,
        ),
    );
}

test "collectFormulaJobs with post_install leaves the DB untouched" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var tdb = try TempDb.init("postinstall_db");
    defer tdb.deinit();

    const json = postInstallFormulaJson();

    const cache_dir = "/tmp/malt_install_test_postinstall_db_cache";
    malt.fs_compat.makeDirAbsolute(cache_dir) catch {};
    defer malt.fs_compat.deleteTreeAbsolute(cache_dir) catch {};

    var http = try malt.client.HttpClientPool.init(alloc, 1);
    defer http.deinit();
    var real_http = malt.client.HttpClient.init(alloc);
    defer real_http.deinit();
    var api = malt.api.BrewApi.init(alloc, &real_http, cache_dir);

    var store_inst: malt.store.Store = undefined;

    var jobs: std.ArrayList(install.DownloadJob) = .empty;
    defer jobs.deinit(alloc);

    _ = install.collectFormulaJobs(
        alloc,
        "needs-ruby",
        json,
        &api,
        &http,
        &tdb.db,
        &store_inst,
        false,
        &jobs,
    ) catch {};

    // collectFormulaJobs only queues download jobs — it never writes to
    // the DB. The kegs table must still be empty.
    var stmt = try tdb.db.prepare("SELECT COUNT(*) FROM kegs;");
    defer stmt.finalize();
    const has_row = try stmt.step();
    try testing.expect(has_row);
    try testing.expectEqual(@as(i64, 0), stmt.columnInt(0));
}
