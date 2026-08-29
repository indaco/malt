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
const install_args = malt.install_args;
const install_download = malt.install_download;
const install_ghcr_url = malt.install_ghcr_url;
const install_rb_parse = malt.install_rb_parse;
const install_record = malt.install_record;
const sqlite = malt.sqlite;
const schema = malt.schema;
const test_io = @import("test_io");

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
        "\"arm64_sequoia\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/needs-ruby\",\"sha256\":\"7777777777777777777777777777777777777777777777777777777777777777\"}," ++
        "\"arm64_sonoma\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/needs-ruby\",\"sha256\":\"7777777777777777777777777777777777777777777777777777777777777777\"}," ++
        "\"arm64_ventura\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/needs-ruby\",\"sha256\":\"7777777777777777777777777777777777777777777777777777777777777777\"}," ++
        "\"arm64_monterey\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/needs-ruby\",\"sha256\":\"7777777777777777777777777777777777777777777777777777777777777777\"}," ++
        "\"sequoia\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/needs-ruby\",\"sha256\":\"7777777777777777777777777777777777777777777777777777777777777777\"}," ++
        "\"sonoma\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/needs-ruby\",\"sha256\":\"7777777777777777777777777777777777777777777777777777777777777777\"}," ++
        "\"ventura\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/needs-ruby\",\"sha256\":\"7777777777777777777777777777777777777777777777777777777777777777\"}," ++
        "\"monterey\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/needs-ruby\",\"sha256\":\"7777777777777777777777777777777777777777777777777777777777777777\"}" ++
        "}}}}";
}

/// Opens a fresh temp-dir SQLite DB with the current schema applied.
/// The caller is responsible for closing the returned DB and removing
/// the temp dir.
/// The temp dir lives under a process-unique base, so overlapping test runs
/// cannot wipe each other's fixtures.
const TempDb = struct {
    arena: std.heap.ArenaAllocator,
    dir: []const u8,
    db: sqlite.Database,

    fn init(tag: []const u8) !TempDb {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const dir = try test_io.uniqueTempPath(arena.allocator(), "install_test", tag);
        test_io.makeDirAbsolute(std.Options.debug_io, dir) catch {};
        var db_path_buf: [256]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/test.db", .{dir}, 0);
        var db = try sqlite.Database.open(db_path);
        errdefer db.close();
        try schema.initSchema(&db);
        return .{ .arena = arena, .dir = dir, .db = db };
    }

    fn deinit(self: *TempDb) void {
        self.db.close();
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.dir) catch {};
        self.arena.deinit();
    }
};

/// Scratch dir under a process-unique base, for the BrewApi cache roots the
/// tests seed and delete.
const TempDir = struct {
    arena: std.heap.ArenaAllocator,
    path: []const u8,

    fn init(tag: []const u8) !TempDir {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const p = try test_io.uniqueTempPath(arena.allocator(), "install_test", tag);
        test_io.makeDirAbsolute(std.Options.debug_io, p) catch {};
        return .{ .arena = arena, .path = p };
    }

    fn deinit(self: *TempDir) void {
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.path) catch {};
        self.arena.deinit();
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

test "collectFormulaJobs queues a steps-migrated formula despite post_install_defined false" {
    // The reproduction shape of the silent-skip bug: migrated formulas
    // report post_install_defined=false and carry the hook only in the
    // declarative steps array — the gate must still open.
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var tdb = try TempDb.init("postinstall_steps_accept");
    defer tdb.deinit();

    const json = "{\"name\":\"glowsteps\",\"full_name\":\"glowsteps\",\"tap\":\"homebrew/core\"," ++
        "\"desc\":\"\",\"homepage\":\"\",\"revision\":0,\"keg_only\":false," ++
        "\"post_install_defined\":false," ++
        "\"post_install_steps\":[{\"type\":\"mkdir_p\",\"path\":{\"base\":\"var\",\"path\":\"glowsteps\"}}]," ++
        "\"versions\":{\"stable\":\"1.0\"},\"dependencies\":[],\"oldnames\":[]," ++
        "\"bottle\":{\"stable\":{\"root_url\":\"https://ghcr.io/v2/homebrew/core/glowsteps/blobs\"," ++
        "\"files\":{\"all\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/glowsteps\",\"sha256\":\"8888888888888888888888888888888888888888888888888888888888888888\"}}}}}";

    var cache_fx = try TempDir.init("postinstall_steps_cache");
    defer cache_fx.deinit();
    const cache_dir = cache_fx.path;

    var http = try malt.client_pool.HttpClientPool.init(std.Options.debug_io, std.process.Environ.empty, alloc, 1);
    defer http.deinit();
    var real_http = malt.client.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, alloc);
    defer real_http.deinit();
    var api = malt.api.BrewApi.init(std.Options.debug_io, alloc, &real_http, cache_dir);

    var store_inst: malt.store.Store = undefined;

    var jobs: std.ArrayList(install_download.DownloadJob) = .empty;
    defer jobs.deinit(alloc);

    var cache = malt.deps.FormulaCache.init(alloc);
    defer cache.deinit();

    try install_download.collectFormulaJobs(
        .{ .io = std.Options.debug_io, .allocator = alloc, .api = &api, .http_pool = &http, .db = &tdb.db, .store = &store_inst, .cache = &cache, .worker_backing = alloc },
        "glowsteps",
        json,
        false,
        &jobs,
    );

    try testing.expectEqual(@as(usize, 1), jobs.items.len);
    try testing.expect(jobs.items[0].wants_post_install);
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

    var cache_fx = try TempDir.init("postinstall_accept_cache");
    defer cache_fx.deinit();
    const cache_dir = cache_fx.path;

    var http = try malt.client_pool.HttpClientPool.init(std.Options.debug_io, std.process.Environ.empty, alloc, 1);
    defer http.deinit();
    var real_http = malt.client.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, alloc);
    defer real_http.deinit();
    var api = malt.api.BrewApi.init(std.Options.debug_io, alloc, &real_http, cache_dir);

    var store_inst: malt.store.Store = undefined;

    var jobs: std.ArrayList(install_download.DownloadJob) = .empty;
    defer jobs.deinit(alloc);

    var cache = malt.deps.FormulaCache.init(alloc);
    defer cache.deinit();

    try install_download.collectFormulaJobs(
        .{ .io = std.Options.debug_io, .allocator = alloc, .api = &api, .http_pool = &http, .db = &tdb.db, .store = &store_inst, .cache = &cache, .worker_backing = alloc },
        "needs-ruby",
        json,
        false,
        &jobs,
    );

    // The formula must now be queued — the DSL interpreter handles
    // post_install after materialisation, so the guard no longer rejects.
    try testing.expectEqual(@as(usize, 1), jobs.items.len);
    try testing.expectEqualStrings("needs-ruby", jobs.items[0].name);
    try testing.expect(jobs.items[0].wants_post_install);
}

// --- Pure helper tests (no DB / network) ---

test "checkPrefixSane accepts a realistic developer-length prefix" {
    try install_args.checkPrefixSane("/Users/somebody/malt");
}

test "checkPrefixSane accepts a short prefix" {
    try install_args.checkPrefixSane("/opt/m");
}

test "checkPrefixSane rejects an absurdly long prefix" {
    const huge = "/" ++ "a" ** 300;
    try testing.expectError(install_args.PrefixError.PrefixAbsurd, install_args.checkPrefixSane(huge));
}

test "isTapFormula detects three-part user/repo/formula names" {
    try testing.expect(install_args.isTapFormula("user/repo/formula"));
    try testing.expect(!install_args.isTapFormula("formula"));
    try testing.expect(!install_args.isTapFormula("user/formula"));
    try testing.expect(!install_args.isTapFormula("a/b/c/d"));
}

test "parseTapName splits user/repo/formula" {
    const parts = install_args.parseTapName("homebrew/core/wget") orelse unreachable;
    try testing.expectEqualStrings("homebrew", parts.user);
    try testing.expectEqualStrings("core", parts.repo);
    try testing.expectEqualStrings("wget", parts.formula);
}

test "parseTapName returns null for non-tap names" {
    try testing.expect(install_args.parseTapName("wget") == null);
    try testing.expect(install_args.parseTapName("user/repo") == null);
}

test "buildGhcrRepo prepends homebrew/core" {
    var buf: [128]u8 = undefined;
    const out = try install_ghcr_url.buildGhcrRepo(&buf, "wget");
    try testing.expectEqualStrings("homebrew/core/wget", out);
}

test "buildGhcrRepo replaces @ with /" {
    var buf: [128]u8 = undefined;
    const out = try install_ghcr_url.buildGhcrRepo(&buf, "openssl@3");
    try testing.expectEqualStrings("homebrew/core/openssl/3", out);
}

test "buildGhcrRepo errors when buffer too small" {
    var buf: [4]u8 = undefined;
    try testing.expectError(error.OutOfMemory, install_ghcr_url.buildGhcrRepo(&buf, "wget"));
}

test "extractQuoted returns the quoted value after a prefix" {
    const line = "  version \"1.2.3\"";
    const value = install_rb_parse.extractQuoted(line, "version \"") orelse unreachable;
    try testing.expectEqualStrings("1.2.3", value);
}

test "extractQuoted returns null when prefix missing" {
    try testing.expect(install_rb_parse.extractQuoted("foo bar", "version \"") == null);
}

test "extractQuoted returns null when closing quote missing" {
    try testing.expect(install_rb_parse.extractQuoted("version \"unterminated", "version \"") == null);
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
    const info = install_rb_parse.parseRubyFormula(rb) orelse unreachable;
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
    const info = install_rb_parse.parseRubyFormula(rb) orelse unreachable;
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
    try testing.expect(install_rb_parse.parseRubyFormula(rb) == null);
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
    var cache = malt.deps.FormulaCache.init(testing.allocator);
    defer cache.deinit();
    const result = install_download.findFailedDep(&cache, &failed, "curl", json) orelse unreachable;
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
    var cache = malt.deps.FormulaCache.init(testing.allocator);
    defer cache.deinit();
    try testing.expect(install_download.findFailedDep(&cache, &failed, "hello", json) == null);
}

test "findFailedDep returns null on unparseable JSON" {
    var failed = std.StringHashMap(void).init(testing.allocator);
    defer failed.deinit();
    var cache = malt.deps.FormulaCache.init(testing.allocator);
    defer cache.deinit();
    try testing.expect(install_download.findFailedDep(&cache, &failed, "broken", "not-json") == null);
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
        "\"arm64_sequoia\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/arm\",\"sha256\":\"9999999999999999999999999999999999999999999999999999999999999999\"}," ++
        "\"arm64_sonoma\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/arm\",\"sha256\":\"9999999999999999999999999999999999999999999999999999999999999999\"}," ++
        "\"arm64_ventura\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/arm\",\"sha256\":\"9999999999999999999999999999999999999999999999999999999999999999\"}," ++
        "\"arm64_monterey\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/arm\",\"sha256\":\"9999999999999999999999999999999999999999999999999999999999999999\"}," ++
        "\"sequoia\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/x86\",\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"}," ++
        "\"sonoma\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/x86\",\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"}," ++
        "\"ventura\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/x86\",\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"}," ++
        "\"monterey\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/x86\",\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"}" ++
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

    var cache_fx = try TempDir.init("happy_path_cache");
    defer cache_fx.deinit();
    const cache_dir = cache_fx.path;

    var http = try malt.client_pool.HttpClientPool.init(std.Options.debug_io, std.process.Environ.empty, alloc, 1);
    defer http.deinit();
    // A real single-client HttpClient is safe because it's never touched
    // when deps.len == 0.
    var real_http = malt.client.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, alloc);
    defer real_http.deinit();
    var api = malt.api.BrewApi.init(std.Options.debug_io, alloc, &real_http, cache_dir);

    var store_inst: malt.store.Store = undefined;
    var jobs: std.ArrayList(install_download.DownloadJob) = .empty;
    defer jobs.deinit(alloc);

    var cache = malt.deps.FormulaCache.init(alloc);
    defer cache.deinit();

    try install_download.collectFormulaJobs(
        .{ .io = std.Options.debug_io, .allocator = alloc, .api = &api, .http_pool = &http, .db = &tdb.db, .store = &store_inst, .cache = &cache, .worker_backing = alloc },
        "hello",
        json,
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

    var http: malt.client_pool.HttpClientPool = undefined;
    var api: malt.api.BrewApi = undefined;
    var store_inst: malt.store.Store = undefined;
    var jobs: std.ArrayList(install_download.DownloadJob) = .empty;
    defer jobs.deinit(alloc);

    var cache = malt.deps.FormulaCache.init(alloc);
    defer cache.deinit();

    try install_download.collectFormulaJobs(
        .{ .io = std.Options.debug_io, .allocator = alloc, .api = &api, .http_pool = &http, .db = &tdb.db, .store = &store_inst, .cache = &cache, .worker_backing = alloc },
        "hello",
        json,
        false, // force=false
        &jobs,
    );

    // Nothing queued — the early-return branch we care about for coverage.
    try testing.expectEqual(@as(usize, 0), jobs.items.len);
}

test "collectFormulaJobs still queues an installed formula under --download-only" {
    // `--download-only` warms the store; an installed row proves nothing
    // about whether the current version's bottle is cached, so the
    // already-installed gate must not swallow the request.
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var tdb = try TempDb.init("dlonly_installed");
    defer tdb.deinit();

    var stmt = try tdb.db.prepare(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, install_reason)
        \\VALUES ('hello', 'hello', '1.0', 'sha', '/tmp', 'direct');
    );
    defer stmt.finalize();
    _ = try stmt.step();

    const json = bottleJsonWithoutDeps("hello");

    var http: malt.client_pool.HttpClientPool = undefined;
    var api: malt.api.BrewApi = undefined;
    var store_inst: malt.store.Store = undefined;
    var jobs: std.ArrayList(install_download.DownloadJob) = .empty;
    defer jobs.deinit(alloc);

    var cache = malt.deps.FormulaCache.init(alloc);
    defer cache.deinit();

    try install_download.collectFormulaJobs(
        .{ .io = std.Options.debug_io, .allocator = alloc, .api = &api, .http_pool = &http, .db = &tdb.db, .store = &store_inst, .cache = &cache, .worker_backing = alloc, .download_only = true },
        "hello",
        json,
        false, // force=false
        &jobs,
    );

    try testing.expectEqual(@as(usize, 1), jobs.items.len);
    try testing.expectEqualStrings("hello", jobs.items[0].name);
}

/// Seed a BrewApi cache_dir with a freshly-written formula JSON file
/// under the `formula_<name>.json` naming convention that readCache
/// honours. Used to avoid hitting the network when collectFormulaJobs
/// calls `api.fetchFormula` for dependencies.
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
        "\"arm64_sequoia\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/arm\",\"sha256\":\"9999999999999999999999999999999999999999999999999999999999999999\"}," ++
        "\"arm64_sonoma\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/arm\",\"sha256\":\"9999999999999999999999999999999999999999999999999999999999999999\"}," ++
        "\"arm64_ventura\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/arm\",\"sha256\":\"9999999999999999999999999999999999999999999999999999999999999999\"}," ++
        "\"arm64_monterey\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/arm\",\"sha256\":\"9999999999999999999999999999999999999999999999999999999999999999\"}," ++
        "\"sequoia\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/x86\",\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"}," ++
        "\"sonoma\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/x86\",\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"}," ++
        "\"ventura\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/x86\",\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"}," ++
        "\"monterey\":{\"cellar\":\":any\",\"url\":\"https://ghcr.io/v2/x86\",\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"}" ++
        "}}}}";
}

test "collectFormulaJobs queues a dep and its parent from a seeded cache" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var tdb = try TempDb.init("with_dep");
    defer tdb.deinit();

    var cache_fx = try TempDir.init("with_dep_cache");
    defer cache_fx.deinit();
    const cache_dir = cache_fx.path;

    // Seed BOTH the dep and the root formula JSON. deps.resolve re-fetches
    // the root from the API to discover its dep list (even though
    // collectFormulaJobs already parsed it), so both must hit the cache to
    // avoid the network.
    const dep_json = bottleJsonWithoutDeps("beta");
    try seedCache(cache_dir, "beta", dep_json);
    const root_json = formulaJsonWithDep("alpha", "beta");
    try seedCache(cache_dir, "alpha", root_json);

    var http_pool = try malt.client_pool.HttpClientPool.init(std.Options.debug_io, std.process.Environ.empty, alloc, 2);
    defer http_pool.deinit();
    var real_http = malt.client.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, alloc);
    defer real_http.deinit();
    var api = malt.api.BrewApi.init(std.Options.debug_io, alloc, &real_http, cache_dir);

    var store_inst: malt.store.Store = undefined;
    var jobs: std.ArrayList(install_download.DownloadJob) = .empty;
    defer jobs.deinit(alloc);

    var cache = malt.deps.FormulaCache.init(alloc);
    defer cache.deinit();

    try install_download.collectFormulaJobs(
        .{ .io = std.Options.debug_io, .allocator = alloc, .api = &api, .http_pool = &http_pool, .db = &tdb.db, .store = &store_inst, .cache = &cache, .worker_backing = alloc },
        "alpha",
        root_json,
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

    var cache_fx = try TempDir.init("dedup_cache");
    defer cache_fx.deinit();
    const cache_dir = cache_fx.path;

    const dep_json = bottleJsonWithoutDeps("beta");
    try seedCache(cache_dir, "beta", dep_json);

    const root_a = formulaJsonWithDep("alpha", "beta");
    const root_b = formulaJsonWithDep("omega", "beta");
    try seedCache(cache_dir, "alpha", root_a);
    try seedCache(cache_dir, "omega", root_b);

    var http_pool = try malt.client_pool.HttpClientPool.init(std.Options.debug_io, std.process.Environ.empty, alloc, 2);
    defer http_pool.deinit();
    var real_http = malt.client.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, alloc);
    defer real_http.deinit();
    var api = malt.api.BrewApi.init(std.Options.debug_io, alloc, &real_http, cache_dir);

    var store_inst: malt.store.Store = undefined;
    var jobs: std.ArrayList(install_download.DownloadJob) = .empty;
    defer jobs.deinit(alloc);

    var cache = malt.deps.FormulaCache.init(alloc);
    defer cache.deinit();

    const deps_ctx: install_download.InstallJobDeps = .{ .io = std.Options.debug_io, .allocator = alloc, .api = &api, .http_pool = &http_pool, .db = &tdb.db, .store = &store_inst, .cache = &cache, .worker_backing = alloc };
    try install_download.collectFormulaJobs(deps_ctx, "alpha", root_a, false, &jobs);
    try install_download.collectFormulaJobs(deps_ctx, "omega", root_b, false, &jobs);

    // beta should appear exactly once. jobs: [beta, alpha, omega]
    var beta_count: usize = 0;
    for (jobs.items) |j| {
        if (std.mem.eql(u8, j.name, "beta")) beta_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), beta_count);
    try testing.expectEqual(@as(usize, 3), jobs.items.len);
}

test "collectFormulaJobs promotes a queued dep that is later requested by name" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var tdb = try TempDb.init("promote_dep");
    defer tdb.deinit();

    var cache_fx = try TempDir.init("promote_dep_cache");
    defer cache_fx.deinit();
    const cache_dir = cache_fx.path;

    const dep_json = bottleJsonWithoutDeps("beta");
    try seedCache(cache_dir, "beta", dep_json);
    const root_json = formulaJsonWithDep("alpha", "beta");
    try seedCache(cache_dir, "alpha", root_json);

    var http_pool = try malt.client_pool.HttpClientPool.init(std.Options.debug_io, std.process.Environ.empty, alloc, 2);
    defer http_pool.deinit();
    var real_http = malt.client.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, alloc);
    defer real_http.deinit();
    var api = malt.api.BrewApi.init(std.Options.debug_io, alloc, &real_http, cache_dir);

    var store_inst: malt.store.Store = undefined;
    var jobs: std.ArrayList(install_download.DownloadJob) = .empty;
    defer jobs.deinit(alloc);

    var cache = malt.deps.FormulaCache.init(alloc);
    defer cache.deinit();

    const deps_ctx: install_download.InstallJobDeps = .{ .io = std.Options.debug_io, .allocator = alloc, .api = &api, .http_pool = &http_pool, .db = &tdb.db, .store = &store_inst, .cache = &cache, .worker_backing = alloc };
    try install_download.collectFormulaJobs(deps_ctx, "alpha", root_json, false, &jobs);
    try install_download.collectFormulaJobs(deps_ctx, "beta", dep_json, false, &jobs);

    // Queueing beta twice would send two workers at one keg directory.
    try testing.expectEqual(@as(usize, 2), jobs.items.len);

    // `is_dep` is the flag the rest of the install reads: it decides
    // `install_reason` (so `purge --unused-deps` cannot reclaim a package the
    // user asked for), whether `--only-deps` drops it, and whether
    // `--isolate-deps` withholds its binaries. A named request is not a dep.
    for (jobs.items) |j| {
        if (std.mem.eql(u8, j.name, "beta")) try testing.expect(!j.is_dep);
    }

    // Naming it a third time must still not grow the queue.
    try install_download.collectFormulaJobs(deps_ctx, "beta", dep_json, false, &jobs);
    try testing.expectEqual(@as(usize, 2), jobs.items.len);
}

test "collectFormulaJobs surfaces FormulaNotFound for unparseable JSON" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var tdb = try TempDb.init("bad_json");
    defer tdb.deinit();

    var http: malt.client_pool.HttpClientPool = undefined;
    var api: malt.api.BrewApi = undefined;
    var store_inst: malt.store.Store = undefined;
    var jobs: std.ArrayList(install_download.DownloadJob) = .empty;
    defer jobs.deinit(alloc);

    var cache = malt.deps.FormulaCache.init(alloc);
    defer cache.deinit();

    try testing.expectError(
        install_record.InstallError.FormulaNotFound,
        install_download.collectFormulaJobs(
            .{ .io = std.Options.debug_io, .allocator = alloc, .api = &api, .http_pool = &http, .db = &tdb.db, .store = &store_inst, .cache = &cache, .worker_backing = alloc },
            "broken",
            "not-a-json",
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

    var cache_fx = try TempDir.init("postinstall_db_cache");
    defer cache_fx.deinit();
    const cache_dir = cache_fx.path;

    var http = try malt.client_pool.HttpClientPool.init(std.Options.debug_io, std.process.Environ.empty, alloc, 1);
    defer http.deinit();
    var real_http = malt.client.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, alloc);
    defer real_http.deinit();
    var api = malt.api.BrewApi.init(std.Options.debug_io, alloc, &real_http, cache_dir);

    var store_inst: malt.store.Store = undefined;

    var jobs: std.ArrayList(install_download.DownloadJob) = .empty;
    defer jobs.deinit(alloc);

    var cache = malt.deps.FormulaCache.init(alloc);
    defer cache.deinit();

    _ = install_download.collectFormulaJobs(
        .{ .io = std.Options.debug_io, .allocator = alloc, .api = &api, .http_pool = &http, .db = &tdb.db, .store = &store_inst, .cache = &cache, .worker_backing = alloc },
        "needs-ruby",
        json,
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

test "collectFormulaJobs carries the _<revision> suffix in version_str" {
    // Direct coverage for issue #77: a revisioned formula must reach
    // the DownloadJob with its pkg_version (e.g. "10.47_1"), not the
    // plain `versions.stable` (e.g. "10.47"). materializeAndLink reads
    // `job.version_str` to form the Cellar dir name, so any drift
    // there re-introduces the dyld breakage.
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var tdb = try TempDb.init("rev_jobs");
    defer tdb.deinit();

    const json =
        \\{"name":"rev","full_name":"rev","tap":"homebrew/core","desc":"","homepage":"",
        \\ "versions":{"stable":"10.47"},"revision":1,"dependencies":[],"oldnames":[],
        \\ "keg_only":false,"post_install_defined":false,
        \\ "bottle":{"stable":{"root_url":"https://ghcr.io/v2/homebrew/core/rev/blobs","files":{
        \\   "arm64_sequoia":{"cellar":":any","url":"https://ghcr.io/v2/arm","sha256":"abababababababababababababababababababababababababababababababab"},
        \\   "arm64_sonoma":{"cellar":":any","url":"https://ghcr.io/v2/arm","sha256":"abababababababababababababababababababababababababababababababab"},
        \\   "arm64_ventura":{"cellar":":any","url":"https://ghcr.io/v2/arm","sha256":"abababababababababababababababababababababababababababababababab"},
        \\   "arm64_monterey":{"cellar":":any","url":"https://ghcr.io/v2/arm","sha256":"abababababababababababababababababababababababababababababababab"},
        \\   "sequoia":{"cellar":":any","url":"https://ghcr.io/v2/x86","sha256":"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd"},
        \\   "sonoma":{"cellar":":any","url":"https://ghcr.io/v2/x86","sha256":"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd"},
        \\   "ventura":{"cellar":":any","url":"https://ghcr.io/v2/x86","sha256":"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd"},
        \\   "monterey":{"cellar":":any","url":"https://ghcr.io/v2/x86","sha256":"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd"}
        \\ }}}}
    ;

    var cache_fx = try TempDir.init("rev_jobs_cache");
    defer cache_fx.deinit();
    const cache_dir = cache_fx.path;

    var http = try malt.client_pool.HttpClientPool.init(std.Options.debug_io, std.process.Environ.empty, alloc, 1);
    defer http.deinit();
    var real_http = malt.client.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, alloc);
    defer real_http.deinit();
    var api = malt.api.BrewApi.init(std.Options.debug_io, alloc, &real_http, cache_dir);

    var store_inst: malt.store.Store = undefined;
    var jobs: std.ArrayList(install_download.DownloadJob) = .empty;
    defer jobs.deinit(alloc);

    var cache = malt.deps.FormulaCache.init(alloc);
    defer cache.deinit();

    try install_download.collectFormulaJobs(
        .{ .io = std.Options.debug_io, .allocator = alloc, .api = &api, .http_pool = &http, .db = &tdb.db, .store = &store_inst, .cache = &cache, .worker_backing = alloc },
        "rev",
        json,
        false,
        &jobs,
    );

    try testing.expectEqual(@as(usize, 1), jobs.items.len);
    try testing.expectEqualStrings("10.47_1", jobs.items[0].version_str);
}

test "collectFormulaJobs leaves plain-version formulas unchanged" {
    // Regression guard: revision == 0 must NOT sprout an `_0` suffix.
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var tdb = try TempDb.init("norev_jobs");
    defer tdb.deinit();

    const json = postInstallFormulaJson(); // revision: 0 fixture.

    var cache_fx = try TempDir.init("norev_jobs_cache");
    defer cache_fx.deinit();
    const cache_dir = cache_fx.path;

    var http = try malt.client_pool.HttpClientPool.init(std.Options.debug_io, std.process.Environ.empty, alloc, 1);
    defer http.deinit();
    var real_http = malt.client.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, alloc);
    defer real_http.deinit();
    var api = malt.api.BrewApi.init(std.Options.debug_io, alloc, &real_http, cache_dir);

    var store_inst: malt.store.Store = undefined;
    var jobs: std.ArrayList(install_download.DownloadJob) = .empty;
    defer jobs.deinit(alloc);

    var cache = malt.deps.FormulaCache.init(alloc);
    defer cache.deinit();

    try install_download.collectFormulaJobs(
        .{ .io = std.Options.debug_io, .allocator = alloc, .api = &api, .http_pool = &http, .db = &tdb.db, .store = &store_inst, .cache = &cache, .worker_backing = alloc },
        "needs-ruby",
        json,
        false,
        &jobs,
    );

    try testing.expectEqual(@as(usize, 1), jobs.items.len);
    try testing.expectEqualStrings("1.0", jobs.items[0].version_str);
    try testing.expect(std.mem.indexOf(u8, jobs.items[0].version_str, "_") == null);
}

/// Three-dep fixture with unique per-dep sha so the dep-dedup path inside
/// `collectFormulaJobs` cannot collapse the dependencies into a single job.
fn formulaJsonWithThreeDeps(
    comptime name: []const u8,
    comptime a: []const u8,
    comptime b: []const u8,
    comptime c: []const u8,
) []const u8 {
    return comptime "{\"name\":\"" ++ name ++ "\"," ++
        "\"full_name\":\"" ++ name ++ "\"," ++
        "\"tap\":\"homebrew/core\"," ++
        "\"desc\":\"\",\"homepage\":\"\",\"revision\":0," ++
        "\"keg_only\":false,\"post_install_defined\":false," ++
        "\"versions\":{\"stable\":\"1.0\"}," ++
        "\"dependencies\":[\"" ++ a ++ "\",\"" ++ b ++ "\",\"" ++ c ++ "\"]," ++
        "\"oldnames\":[]," ++
        "\"bottle\":{\"stable\":{\"root_url\":\"https://ghcr.io/v2/homebrew/core/" ++ name ++ "/blobs\"," ++
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

/// A fixture digest has to be 64 lowercase hex or the parser drops the
/// bottle entry outright. Callers must keep the `comptime` on their `++`
/// chain: without it the concat lands in a stack temporary and the fixture
/// hands back a dangling slice.
fn storeKey(comptime seed: []const u8) *const [64]u8 {
    const padded = seed ++ "0" ** 64;
    return padded[0..64];
}

/// Dep fixture with a caller-supplied unique sha prefix so each dep's
/// bottle is distinguishable from its siblings.
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

test "collectFormulaJobs leaves no parsed-tree leaks under testing.allocator (>=3 deps)" {
    // BUG-009 regression guard: every per-dep std.json.Parsed (and the
    // root's) used to stay pinned for the whole install run. Here we
    // run the full 3-dep resolve path under testing.allocator and
    // free only the strings the caller knows it owns — anything else
    // that survives is a parsed-tree leak and trips the allocator.
    const alloc = testing.allocator;

    var tdb = try TempDb.init("parsed_tree_leak");
    defer tdb.deinit();

    var cache_fx = try TempDir.init("parsed_tree_leak_cache");
    defer cache_fx.deinit();
    const cache_dir = cache_fx.path;

    try seedCache(cache_dir, "dep_a", bottleJsonUniqueSha("dep_a", "aa"));
    try seedCache(cache_dir, "dep_b", bottleJsonUniqueSha("dep_b", "bb"));
    try seedCache(cache_dir, "dep_c", bottleJsonUniqueSha("dep_c", "cc"));

    const root_json = formulaJsonWithThreeDeps("root", "dep_a", "dep_b", "dep_c");
    try seedCache(cache_dir, "root", root_json);

    var http_pool = try malt.client_pool.HttpClientPool.init(std.Options.debug_io, std.process.Environ.empty, alloc, 2);
    defer http_pool.deinit();
    var real_http = malt.client.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, alloc);
    defer real_http.deinit();
    var api = malt.api.BrewApi.init(std.Options.debug_io, alloc, &real_http, cache_dir);

    var store_inst: malt.store.Store = undefined;
    var jobs: std.ArrayList(install_download.DownloadJob) = .empty;
    defer {
        // Caller-owned job strings: name/version/sha/url/cellar are duped
        // into `alloc` so collectFormulaJobs can drop the parsed tree.
        // `formula_json` is duped only for dep jobs; the main job borrows
        // the caller-supplied input literal.
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

    var cache = malt.deps.FormulaCache.init(alloc);
    defer cache.deinit();

    try install_download.collectFormulaJobs(
        .{ .io = std.Options.debug_io, .allocator = alloc, .api = &api, .http_pool = &http_pool, .db = &tdb.db, .store = &store_inst, .cache = &cache, .worker_backing = alloc },
        "root",
        root_json,
        false,
        &jobs,
    );

    // Three deps plus the root must all be queued (no dedup: every sha unique).
    try testing.expectEqual(@as(usize, 4), jobs.items.len);
    try testing.expectEqualStrings("root", jobs.items[3].name);
    try testing.expect(!jobs.items[3].is_dep);
}

test "collectFetchWorkerCount clamps to max_collect_fetch_workers" {
    // Pool invariant: the dep-fetch phase never spawns more than
    // max_collect_fetch_workers threads, even on heavy graphs (40+ deps).
    // The old one-thread-per-dep loop would scale linearly; the pool
    // caps it so threads never outnumber HTTP client pool slots.
    const cap = install_download.max_collect_fetch_workers;

    try testing.expectEqual(@as(usize, 0), install_download.collectFetchWorkerCount(0));
    try testing.expectEqual(@as(usize, 1), install_download.collectFetchWorkerCount(1));
    try testing.expectEqual(cap, install_download.collectFetchWorkerCount(cap));
    try testing.expectEqual(cap, install_download.collectFetchWorkerCount(cap + 1));
    try testing.expectEqual(cap, install_download.collectFetchWorkerCount(40));
    try testing.expectEqual(cap, install_download.collectFetchWorkerCount(128));
}

// --- dropTopLevelJobs (--only-dependencies seam) ---

/// Append a `DownloadJob` whose owned strings are duped into `alloc`.
/// `formula_json` follows the production split: dep jobs own their JSON
/// bytes (`is_dep=true`), top-level jobs borrow the caller's input
/// (`is_dep=false`).
fn appendOwnedJob(
    alloc: std.mem.Allocator,
    jobs: *std.ArrayList(install_download.DownloadJob),
    name: []const u8,
    is_dep: bool,
    borrowed_json: []const u8,
) !void {
    const formula_json: []const u8 = if (is_dep) try alloc.dupe(u8, borrowed_json) else borrowed_json;
    try jobs.append(alloc, .{
        .name = try alloc.dupe(u8, name),
        .version_str = try alloc.dupe(u8, "1.0"),
        .sha256 = try alloc.dupe(u8, "aa"),
        .bottle_url = try alloc.dupe(u8, "https://x"),
        .is_dep = is_dep,
        .keg_only = false,
        .wants_post_install = false,
        .formula_json = formula_json,
        .cellar_type = try alloc.dupe(u8, ":any"),
        .label_width = 0,
        .line_index = 0,
        .multi = null,
        .bar = null,
        .store_sha256 = "",
        .succeeded = false,
    });
}

test "dropTopLevelJobs removes the top-level job and frees its owned strings" {
    // Under testing.allocator the helper must free the dropped job's name,
    // version, sha, url, and cellar_type; otherwise the runner reports a leak.
    const alloc = testing.allocator;
    var jobs: std.ArrayList(install_download.DownloadJob) = .empty;
    defer {
        for (jobs.items) |j| {
            alloc.free(j.name);
            alloc.free(j.version_str);
            alloc.free(j.sha256);
            alloc.free(j.bottle_url);
            alloc.free(j.cellar_type);
            if (j.is_dep) alloc.free(j.formula_json);
        }
        jobs.deinit(alloc);
    }

    try appendOwnedJob(alloc, &jobs, "beta", true, "{}");
    try appendOwnedJob(alloc, &jobs, "alpha", false, "{}");

    install_download.dropTopLevelJobs(alloc, &jobs);

    try testing.expectEqual(@as(usize, 1), jobs.items.len);
    try testing.expectEqualStrings("beta", jobs.items[0].name);
    try testing.expect(jobs.items[0].is_dep);
}

test "dropTopLevelJobs is a no-op when every job is a dep" {
    const alloc = testing.allocator;
    var jobs: std.ArrayList(install_download.DownloadJob) = .empty;
    defer {
        for (jobs.items) |j| {
            alloc.free(j.name);
            alloc.free(j.version_str);
            alloc.free(j.sha256);
            alloc.free(j.bottle_url);
            alloc.free(j.cellar_type);
            if (j.is_dep) alloc.free(j.formula_json);
        }
        jobs.deinit(alloc);
    }

    try appendOwnedJob(alloc, &jobs, "beta", true, "{}");
    try appendOwnedJob(alloc, &jobs, "gamma", true, "{}");

    install_download.dropTopLevelJobs(alloc, &jobs);

    try testing.expectEqual(@as(usize, 2), jobs.items.len);
    try testing.expectEqualStrings("beta", jobs.items[0].name);
    try testing.expectEqualStrings("gamma", jobs.items[1].name);
}

test "dropTopLevelJobs preserves dep order across mixed lists" {
    // Top-level jobs are appended *after* deps in collectFormulaJobs, but
    // a multi-package install can interleave (alpha-deps, alpha, beta-deps,
    // beta). Order matters because the link phase walks deps before
    // dependents — anything out of order regresses findFailedDep.
    const alloc = testing.allocator;
    var jobs: std.ArrayList(install_download.DownloadJob) = .empty;
    defer {
        for (jobs.items) |j| {
            alloc.free(j.name);
            alloc.free(j.version_str);
            alloc.free(j.sha256);
            alloc.free(j.bottle_url);
            alloc.free(j.cellar_type);
            if (j.is_dep) alloc.free(j.formula_json);
        }
        jobs.deinit(alloc);
    }

    try appendOwnedJob(alloc, &jobs, "dep_a", true, "{}");
    try appendOwnedJob(alloc, &jobs, "alpha", false, "{}");
    try appendOwnedJob(alloc, &jobs, "dep_b", true, "{}");
    try appendOwnedJob(alloc, &jobs, "beta", false, "{}");

    install_download.dropTopLevelJobs(alloc, &jobs);

    try testing.expectEqual(@as(usize, 2), jobs.items.len);
    try testing.expectEqualStrings("dep_a", jobs.items[0].name);
    try testing.expectEqualStrings("dep_b", jobs.items[1].name);
}

// --- Stale-keg sweep: force-reinstall across a revision bump must
// drop the prior keg's DB row + its links + its dependencies + its
// on-disk dir, mirroring the upgrade path. The sweep is split in
// two so the user pin survives:
//   - `unlinkStaleKegLinks` (pre-link) clears symlinks + links rows
//   - `recordKeg` (in linkAndRecord) inherits the pin via COALESCE-MAX
//   - `dropStaleKegRows` (post-link) wipes rows + dirs
// Tests below exercise the combined sweep (the call-site shape)
// plus the narrow per-helper contracts.

fn insertKegRow(
    db: *sqlite.Database,
    name: []const u8,
    version: []const u8,
    revision: i64,
    cellar_path: []const u8,
) !i64 {
    {
        var stmt = try db.prepare(
            \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6);
        );
        defer stmt.finalize();
        try stmt.bindText(1, name);
        try stmt.bindText(2, name);
        try stmt.bindText(3, version);
        try stmt.bindInt(4, revision);
        try stmt.bindText(5, "0" ** 64);
        try stmt.bindText(6, cellar_path);
        _ = try stmt.step();
    }
    var stmt = try db.prepare("SELECT last_insert_rowid();");
    defer stmt.finalize();
    _ = try stmt.step();
    return stmt.columnInt(0);
}

fn seedKegWithBin(prefix: []const u8, name: []const u8, version: []const u8, bin_name: []const u8) ![]u8 {
    const keg = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/Cellar/{s}/{s}",
        .{ prefix, name, version },
    );
    const bin_dir = try std.fmt.allocPrint(testing.allocator, "{s}/bin", .{keg});
    defer testing.allocator.free(bin_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, bin_dir);

    const bin_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ bin_dir, bin_name });
    defer testing.allocator.free(bin_path);
    const f = try test_io.createFileAbsolute(std.Options.debug_io, bin_path, .{});
    defer f.close(std.Options.debug_io);
    try f.writeStreamingAll(std.Options.debug_io, "#!/bin/sh\necho hi\n");
    return keg;
}

fn kegRowCount(db: *sqlite.Database, name: []const u8) !i64 {
    var stmt = try db.prepare("SELECT COUNT(*) FROM kegs WHERE name = ?1;");
    defer stmt.finalize();
    try stmt.bindText(1, name);
    _ = try stmt.step();
    return stmt.columnInt(0);
}

test "stale-keg sweep (unlink + drop) clears the prior row, its symlinks, and its dir" {
    var tdb = try TempDb.init("force_sweep_db_row");
    defer tdb.deinit();
    const prefix = tdb.dir;

    const stale_keg = try seedKegWithBin(prefix, "foo", "1.0", "foo-tool");
    defer testing.allocator.free(stale_keg);
    const keep_keg = try seedKegWithBin(prefix, "foo", "2.0", "foo-tool");
    defer testing.allocator.free(keep_keg);

    const stale_id = try insertKegRow(&tdb.db, "foo", "1.0", 0, stale_keg);
    const keep_id = try insertKegRow(&tdb.db, "foo", "2.0", 0, keep_keg);

    var linker = malt.linker.Linker.init(std.Options.debug_io, testing.allocator, &tdb.db, prefix);
    try linker.link(stale_keg, "foo", stale_id, false);

    // Sanity: stale row exists, stale symlink resolves.
    try testing.expectEqual(@as(i64, 2), try kegRowCount(&tdb.db, "foo"));
    var link_buf: [512]u8 = undefined;
    const link_path = try std.fmt.bufPrint(&link_buf, "{s}/bin/foo-tool", .{prefix});
    try std.Io.Dir.accessAbsolute(std.Options.debug_io, link_path, .{});

    // Resolved version is foo 2.0. Sweep is two-phase at the call
    // site: unlink first (pre-link), drop rows + dirs second
    // (post-link). Test the combined effect.
    install.unlinkStaleKegLinks(&tdb.db, &linker, "foo", keep_keg);
    install.dropStaleKegRows(&malt.app_ctx.debug_ctx, testing.allocator, &tdb.db, "foo", keep_keg);

    // Stale row + dir + symlink all gone; keep row + dir untouched.
    try testing.expectEqual(@as(i64, 1), try kegRowCount(&tdb.db, "foo"));
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.Options.debug_io, stale_keg, .{}));
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.Options.debug_io, link_path, .{}));
    try std.Io.Dir.accessAbsolute(std.Options.debug_io, keep_keg, .{});

    // Survivor's id is the one we kept.
    var stmt = try tdb.db.prepare("SELECT id FROM kegs WHERE name = ?1;");
    defer stmt.finalize();
    try stmt.bindText(1, "foo");
    _ = try stmt.step();
    try testing.expectEqual(keep_id, stmt.columnInt(0));
}

test "stale-keg sweep is a no-op when no sibling rows exist" {
    var tdb = try TempDb.init("force_sweep_db_solo");
    defer tdb.deinit();
    const prefix = tdb.dir;

    const keep_keg = try seedKegWithBin(prefix, "bar", "1.0", "bar-tool");
    defer testing.allocator.free(keep_keg);
    _ = try insertKegRow(&tdb.db, "bar", "1.0", 0, keep_keg);

    var linker = malt.linker.Linker.init(std.Options.debug_io, testing.allocator, &tdb.db, prefix);

    install.unlinkStaleKegLinks(&tdb.db, &linker, "bar", keep_keg);
    install.dropStaleKegRows(&malt.app_ctx.debug_ctx, testing.allocator, &tdb.db, "bar", keep_keg);

    try testing.expectEqual(@as(i64, 1), try kegRowCount(&tdb.db, "bar"));
    try std.Io.Dir.accessAbsolute(std.Options.debug_io, keep_keg, .{});
}

test "stale-keg sweep tolerates a stale row whose dir is already gone" {
    var tdb = try TempDb.init("force_sweep_db_no_disk");
    defer tdb.deinit();
    const prefix = tdb.dir;

    const stale_keg = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/baz/1.0", .{prefix});
    defer testing.allocator.free(stale_keg);
    // Note: stale dir intentionally NOT created — simulate a crashed
    // prior install or a manual `rm -rf` that left only the DB row.

    const keep_keg = try seedKegWithBin(prefix, "baz", "2.0", "baz-tool");
    defer testing.allocator.free(keep_keg);

    _ = try insertKegRow(&tdb.db, "baz", "1.0", 0, stale_keg);
    _ = try insertKegRow(&tdb.db, "baz", "2.0", 0, keep_keg);

    var linker = malt.linker.Linker.init(std.Options.debug_io, testing.allocator, &tdb.db, prefix);

    install.unlinkStaleKegLinks(&tdb.db, &linker, "baz", keep_keg);
    install.dropStaleKegRows(&malt.app_ctx.debug_ctx, testing.allocator, &tdb.db, "baz", keep_keg);

    // Stale row gone even though its dir was already absent.
    try testing.expectEqual(@as(i64, 1), try kegRowCount(&tdb.db, "baz"));
}

// unlinkSameVersionKegLinks: clear the package's own prior symlinks
// before linkAndRecord runs. Without this, `linker.checkConflicts`
// rejects a same-version `--force` reinstall against a keg the user
// already has installed — the prior bug we shipped to T-044.

test "unlinkSameVersionKegLinks removes symlinks + links rows for the matching keg" {
    var tdb = try TempDb.init("force_unlink_same_ver");
    defer tdb.deinit();
    const prefix = tdb.dir;

    const keg = try seedKegWithBin(prefix, "foo", "1.0", "foo-tool");
    defer testing.allocator.free(keg);

    const keg_id = try insertKegRow(&tdb.db, "foo", "1.0", 0, keg);

    var linker = malt.linker.Linker.init(std.Options.debug_io, testing.allocator, &tdb.db, prefix);
    try linker.link(keg, "foo", keg_id, false);

    var link_buf: [512]u8 = undefined;
    const link_path = try std.fmt.bufPrint(&link_buf, "{s}/bin/foo-tool", .{prefix});
    try std.Io.Dir.accessAbsolute(std.Options.debug_io, link_path, .{});

    install.unlinkSameVersionKegLinks(&linker, &tdb.db, "foo", keg);

    // Symlink + links row gone; kegs row preserved so the subsequent
    // recordKeg INSERT OR REPLACE can inherit any pin via COALESCE.
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.Options.debug_io, link_path, .{}));
    var links_count_stmt = try tdb.db.prepare("SELECT COUNT(*) FROM links WHERE keg_id = ?1;");
    defer links_count_stmt.finalize();
    try links_count_stmt.bindInt(1, keg_id);
    _ = try links_count_stmt.step();
    try testing.expectEqual(@as(i64, 0), links_count_stmt.columnInt(0));
    try testing.expectEqual(@as(i64, 1), try kegRowCount(&tdb.db, "foo"));
}

test "unlinkSameVersionKegLinks is a no-op when no row matches the keep path" {
    var tdb = try TempDb.init("force_unlink_no_match");
    defer tdb.deinit();
    const prefix = tdb.dir;

    const keg = try seedKegWithBin(prefix, "foo", "1.0", "foo-tool");
    defer testing.allocator.free(keg);
    const keg_id = try insertKegRow(&tdb.db, "foo", "1.0", 0, keg);

    var linker = malt.linker.Linker.init(std.Options.debug_io, testing.allocator, &tdb.db, prefix);
    try linker.link(keg, "foo", keg_id, false);

    // Different cellar_path than the seeded row → must not unlink.
    const other = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/foo/2.0", .{prefix});
    defer testing.allocator.free(other);
    install.unlinkSameVersionKegLinks(&linker, &tdb.db, "foo", other);

    var link_buf: [512]u8 = undefined;
    const link_path = try std.fmt.bufPrint(&link_buf, "{s}/bin/foo-tool", .{prefix});
    try std.Io.Dir.accessAbsolute(std.Options.debug_io, link_path, .{});
}

test "unlinkSameVersionKegLinks leaves other packages untouched" {
    var tdb = try TempDb.init("force_unlink_scoped");
    defer tdb.deinit();
    const prefix = tdb.dir;

    const foo = try seedKegWithBin(prefix, "foo", "1.0", "foo-tool");
    defer testing.allocator.free(foo);
    const bar = try seedKegWithBin(prefix, "bar", "1.0", "bar-tool");
    defer testing.allocator.free(bar);

    const foo_id = try insertKegRow(&tdb.db, "foo", "1.0", 0, foo);
    const bar_id = try insertKegRow(&tdb.db, "bar", "1.0", 0, bar);

    var linker = malt.linker.Linker.init(std.Options.debug_io, testing.allocator, &tdb.db, prefix);
    try linker.link(foo, "foo", foo_id, false);
    try linker.link(bar, "bar", bar_id, false);

    install.unlinkSameVersionKegLinks(&linker, &tdb.db, "foo", foo);

    // foo's symlink gone, bar's intact.
    var foo_link_buf: [512]u8 = undefined;
    const foo_link = try std.fmt.bufPrint(&foo_link_buf, "{s}/bin/foo-tool", .{prefix});
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.Options.debug_io, foo_link, .{}));

    var bar_link_buf: [512]u8 = undefined;
    const bar_link = try std.fmt.bufPrint(&bar_link_buf, "{s}/bin/bar-tool", .{prefix});
    try std.Io.Dir.accessAbsolute(std.Options.debug_io, bar_link, .{});
}

test "stale-keg sweep wipes multiple stale rows for the same name in one pass" {
    var tdb = try TempDb.init("force_sweep_db_multi");
    defer tdb.deinit();
    const prefix = tdb.dir;

    // Realistic v5 shape after repeated force-reinstalls before this
    // fix landed: each revision left its own (name, version, revision)
    // row instead of being merged. All N-1 stale rows must go.
    const v1 = try seedKegWithBin(prefix, "qux", "1.0", "qux-tool");
    defer testing.allocator.free(v1);
    const v2 = try seedKegWithBin(prefix, "qux", "2.0", "qux-tool");
    defer testing.allocator.free(v2);
    const v3 = try seedKegWithBin(prefix, "qux", "3.0", "qux-tool");
    defer testing.allocator.free(v3);
    const keep = try seedKegWithBin(prefix, "qux", "4.0", "qux-tool");
    defer testing.allocator.free(keep);

    _ = try insertKegRow(&tdb.db, "qux", "1.0", 0, v1);
    _ = try insertKegRow(&tdb.db, "qux", "2.0", 0, v2);
    _ = try insertKegRow(&tdb.db, "qux", "3.0", 0, v3);
    _ = try insertKegRow(&tdb.db, "qux", "4.0", 0, keep);

    var linker = malt.linker.Linker.init(std.Options.debug_io, testing.allocator, &tdb.db, prefix);

    install.unlinkStaleKegLinks(&tdb.db, &linker, "qux", keep);
    install.dropStaleKegRows(&malt.app_ctx.debug_ctx, testing.allocator, &tdb.db, "qux", keep);

    try testing.expectEqual(@as(i64, 1), try kegRowCount(&tdb.db, "qux"));
    for ([_][]const u8{ v1, v2, v3 }) |stale| {
        try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.Options.debug_io, stale, .{}));
    }
    try std.Io.Dir.accessAbsolute(std.Options.debug_io, keep, .{});
}

test "stale-keg sweep leaves other packages untouched" {
    var tdb = try TempDb.init("force_sweep_db_scoped");
    defer tdb.deinit();
    const prefix = tdb.dir;

    const stale_foo = try seedKegWithBin(prefix, "foo", "1.0", "foo-tool");
    defer testing.allocator.free(stale_foo);
    const keep_foo = try seedKegWithBin(prefix, "foo", "2.0", "foo-tool");
    defer testing.allocator.free(keep_foo);
    const other = try seedKegWithBin(prefix, "qux", "1.0", "qux-tool");
    defer testing.allocator.free(other);

    _ = try insertKegRow(&tdb.db, "foo", "1.0", 0, stale_foo);
    _ = try insertKegRow(&tdb.db, "foo", "2.0", 0, keep_foo);
    _ = try insertKegRow(&tdb.db, "qux", "1.0", 0, other);

    var linker = malt.linker.Linker.init(std.Options.debug_io, testing.allocator, &tdb.db, prefix);

    install.unlinkStaleKegLinks(&tdb.db, &linker, "foo", keep_foo);
    install.dropStaleKegRows(&malt.app_ctx.debug_ctx, testing.allocator, &tdb.db, "foo", keep_foo);

    try testing.expectEqual(@as(i64, 1), try kegRowCount(&tdb.db, "foo"));
    try testing.expectEqual(@as(i64, 1), try kegRowCount(&tdb.db, "qux"));
    try std.Io.Dir.accessAbsolute(std.Options.debug_io, other, .{});
}

// The pin-preservation contract: when a user pinned the stale
// revision and force-reinstalls across a revision bump, the pin must
// migrate to the new row via `recordKeg`'s INSERT OR REPLACE
// `COALESCE-MAX` subquery. That subquery runs against the kegs
// table BEFORE the new row lands, so the stale row must still exist
// at that moment. The two-phase sweep guarantees this:
// unlinkStaleKegLinks clears the symlinks pre-link, but the row
// stays until dropStaleKegRows runs post-link.
test "two-phase sweep preserves a pin set on the stale revision through INSERT OR REPLACE" {
    var tdb = try TempDb.init("force_pin_preservation");
    defer tdb.deinit();
    const prefix = tdb.dir;

    const stale_keg = try seedKegWithBin(prefix, "foo", "1.0", "foo-tool");
    defer testing.allocator.free(stale_keg);
    const keep_keg = try seedKegWithBin(prefix, "foo", "2.0", "foo-tool");
    defer testing.allocator.free(keep_keg);

    const stale_id = try insertKegRow(&tdb.db, "foo", "1.0", 0, stale_keg);

    // Stamp the pin on the stale row, mirroring `malt pin foo`.
    {
        var pin_stmt = try tdb.db.prepare("UPDATE kegs SET pinned = 1 WHERE id = ?1;");
        defer pin_stmt.finalize();
        try pin_stmt.bindInt(1, stale_id);
        _ = try pin_stmt.step();
    }

    var linker = malt.linker.Linker.init(std.Options.debug_io, testing.allocator, &tdb.db, prefix);
    try linker.link(stale_keg, "foo", stale_id, false);

    // Pre-link: clear the stale install's symlinks so the new
    // linker.link does not collide. Row + pin flag stay.
    install.unlinkStaleKegLinks(&tdb.db, &linker, "foo", keep_keg);

    // Simulate recordKeg's INSERT OR REPLACE running against the
    // table while the stale row still carries the pin. Use the same
    // COALESCE-MAX wiring the production code uses.
    {
        var insert = try tdb.db.prepare(
            \\INSERT OR REPLACE INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, pinned)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, COALESCE((SELECT MAX(pinned) FROM kegs WHERE name = ?1), 0));
        );
        defer insert.finalize();
        try insert.bindText(1, "foo");
        try insert.bindText(2, "foo");
        try insert.bindText(3, "2.0");
        try insert.bindInt(4, 0);
        try insert.bindText(5, "0" ** 64);
        try insert.bindText(6, keep_keg);
        _ = try insert.step();
    }

    // Post-link: drop the stale row + dir. Pin already migrated to
    // the new row in the step above.
    install.dropStaleKegRows(&malt.app_ctx.debug_ctx, testing.allocator, &tdb.db, "foo", keep_keg);

    try testing.expectEqual(@as(i64, 1), try kegRowCount(&tdb.db, "foo"));

    var pin_stmt = try tdb.db.prepare("SELECT pinned FROM kegs WHERE name = ?1 LIMIT 1;");
    defer pin_stmt.finalize();
    try pin_stmt.bindText(1, "foo");
    _ = try pin_stmt.step();
    try testing.expectEqual(@as(i64, 1), pin_stmt.columnInt(0));
}
