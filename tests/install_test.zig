//! malt — install command tests
//!
//! Covers the early-abort branches of `collectFormulaJobs` that can be
//! exercised without a live Homebrew API. A formula with a Ruby
//! `post_install` hook must be rejected BEFORE any dep resolution or job
//! queueing so nothing is downloaded, materialised, or linked for it —
//! this test is the regression guard for that behaviour.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const install = malt.install;
const sqlite = malt.sqlite;
const schema = malt.schema;

const post_install_formula_json =
    \\{
    \\  "name": "needs-ruby",
    \\  "full_name": "needs-ruby",
    \\  "tap": "homebrew/core",
    \\  "desc": "Fixture formula with a post_install hook",
    \\  "homepage": "",
    \\  "license": "MIT",
    \\  "revision": 0,
    \\  "keg_only": false,
    \\  "post_install_defined": true,
    \\  "versions": { "stable": "1.0" },
    \\  "dependencies": ["openssl@3"],
    \\  "oldnames": [],
    \\  "bottle": {
    \\    "stable": {
    \\      "root_url": "https://ghcr.io/v2/homebrew/core/needs-ruby/blobs",
    \\      "files": {
    \\        "arm64_sequoia": { "cellar": ":any", "url": "https://ghcr.io/v2/needs-ruby", "sha256": "deadbeef" },
    \\        "x86_64_linux":  { "cellar": ":any", "url": "https://ghcr.io/v2/needs-ruby", "sha256": "deadbeef" }
    \\      }
    \\    }
    \\  }
    \\}
;

/// Opens a fresh temp-dir SQLite DB with the current schema applied.
/// The caller is responsible for closing the returned DB and removing
/// the temp dir.
const TempDb = struct {
    dir: []const u8,
    db: sqlite.Database,

    fn init(comptime tag: []const u8) !TempDb {
        const dir = "/tmp/malt_install_test_" ++ tag;
        std.fs.makeDirAbsolute(dir) catch {};
        var db_path_buf: [256]u8 = undefined;
        const db_path = try std.fmt.bufPrint(&db_path_buf, "{s}/test.db", .{dir});
        var db = try sqlite.Database.open(db_path);
        errdefer db.close();
        try schema.initSchema(&db);
        return .{ .dir = dir, .db = db };
    }

    fn deinit(self: *TempDb) void {
        self.db.close();
        std.fs.deleteTreeAbsolute(self.dir) catch {};
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

test "collectFormulaJobs rejects a formula with a post_install hook" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var tdb = try TempDb.init("postinstall_reject");
    defer tdb.deinit();

    // The post_install branch returns BEFORE the BrewApi / HttpClientPool
    // are ever touched, so passing `undefined` here is safe. If the
    // implementation ever starts reading them earlier, this test will
    // crash loudly and alert us to the regression — which is exactly
    // the guarantee we want.
    var api: malt.api.BrewApi = undefined;
    var http_pool: malt.client.HttpClientPool = undefined;
    var store_inst: malt.store.Store = undefined;

    var jobs: std.ArrayList(install.DownloadJob) = .empty;
    defer jobs.deinit(alloc);

    const result = install.collectFormulaJobs(
        alloc,
        "needs-ruby",
        post_install_formula_json,
        &api,
        &http_pool,
        &tdb.db,
        &store_inst,
        false,
        &jobs,
    );

    try testing.expectError(install.InstallError.PostInstallUnsupported, result);

    // No job — neither the main formula nor any dep — may be queued,
    // because queued jobs flow straight into the download + materialise
    // pipeline inside execute(). An empty list is the whole guarantee
    // the user is paying for.
    try testing.expectEqual(@as(usize, 0), jobs.items.len);
}

test "collectFormulaJobs rejection leaves the DB untouched" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var tdb = try TempDb.init("postinstall_db");
    defer tdb.deinit();

    var api: malt.api.BrewApi = undefined;
    var http_pool: malt.client.HttpClientPool = undefined;
    var store_inst: malt.store.Store = undefined;

    var jobs: std.ArrayList(install.DownloadJob) = .empty;
    defer jobs.deinit(alloc);

    _ = install.collectFormulaJobs(
        alloc,
        "needs-ruby",
        post_install_formula_json,
        &api,
        &http_pool,
        &tdb.db,
        &store_inst,
        false,
        &jobs,
    ) catch {};

    // kegs table must still be empty: aborting must not have recorded
    // anything about the rejected formula.
    var stmt = try tdb.db.prepare("SELECT COUNT(*) FROM kegs;");
    defer stmt.finalize();
    const has_row = try stmt.step();
    try testing.expect(has_row);
    try testing.expectEqual(@as(i64, 0), stmt.columnInt(0));
}
