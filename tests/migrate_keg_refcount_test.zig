//! Integration tests for the store claim `cli/migrate/keg.zig::migrateKeg`
//! takes. The refcount is what keeps a bottle's bytes out of every reclaim
//! path, so it may only be bumped once a `kegs` row actually references
//! them — otherwise a retried, blocked migrate pins those bytes forever.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const sqlite = malt.sqlite;
const schema = malt.schema;
const migrate_keg = malt.cli_migrate_keg;

/// 64 lowercase hex, or the bottle entry is dropped by the parser.
const sha = "feed" ** 16;

const Fixture = struct {
    prefix: []const u8,
    cache_dir: []const u8,
    brew_prefix: []const u8,

    /// Per-test unique paths: on a shared fixture dir, concurrent runs
    /// wipe each other's seeded cache and fall through to the network.
    fn init(tag: []const u8) !Fixture {
        const prefix = try test_io.uniqueTempPath(testing.allocator, "migratekegref", tag);
        errdefer testing.allocator.free(prefix);
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

        inline for (.{ "store", "Cellar", "opt", "bin", "lib", "cache/api" }) |sub| {
            const dir = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ prefix, sub });
            defer testing.allocator.free(dir);
            try test_io.cwd().createDirPath(std.Options.debug_io, dir);
        }

        const cache_dir = try std.fmt.allocPrint(testing.allocator, "{s}/cache", .{prefix});
        errdefer testing.allocator.free(cache_dir);
        const brew_prefix = try std.fmt.allocPrint(testing.allocator, "{s}/brew", .{prefix});
        errdefer testing.allocator.free(brew_prefix);

        return .{ .prefix = prefix, .cache_dir = cache_dir, .brew_prefix = brew_prefix };
    }

    fn deinit(self: *Fixture) void {
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.prefix) catch {};
        testing.allocator.free(self.brew_prefix);
        testing.allocator.free(self.cache_dir);
        testing.allocator.free(self.prefix);
    }

    /// Warm store + cached formula: `migrateKeg` then reaches materialise
    /// without touching the network.
    fn seed(self: *const Fixture, name: []const u8, keg_only: bool) !void {
        const inner = try std.fmt.allocPrint(
            testing.allocator,
            "{s}/store/{s}/{s}/1.0",
            .{ self.prefix, sha, name },
        );
        defer testing.allocator.free(inner);
        try test_io.cwd().createDirPath(std.Options.debug_io, inner);
        try self.writeFile(inner, "README", "warm store probe\n");

        const json = try std.fmt.allocPrint(testing.allocator,
            \\{{"name":"{s}","full_name":"{s}","tap":"homebrew/core","desc":"","homepage":"",
            \\ "versions":{{"stable":"1.0"}},"revision":0,"dependencies":[],"keg_only":{},
            \\ "post_install_defined":false,"oldnames":[],
            \\ "bottle":{{"stable":{{"files":{{"all":{{"cellar":":any",
            \\   "url":"https://ghcr.io/v2/homebrew/core/{s}/blobs/sha256:{s}","sha256":"{s}"}}}}}}}}}}
        , .{ name, name, keg_only, name, sha, sha });
        defer testing.allocator.free(json);

        const api_dir = try std.fmt.allocPrint(testing.allocator, "{s}/api", .{self.cache_dir});
        defer testing.allocator.free(api_dir);
        const filename = try std.fmt.allocPrint(testing.allocator, "formula_{s}.json", .{name});
        defer testing.allocator.free(filename);
        try self.writeFile(api_dir, filename, json);
    }

    fn writeFile(_: *const Fixture, dir: []const u8, name: []const u8, body: []const u8) !void {
        const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name });
        defer testing.allocator.free(path);
        const f = try test_io.cwd().createFile(std.Options.debug_io, path, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, body);
    }
};

/// A symlinked package dir is the cheapest deterministic materialise refusal.
fn plantSymlinkedPackageDir(io: std.Io, prefix: []const u8, name: []const u8) !void {
    const victim = try std.fmt.allocPrint(testing.allocator, "{s}/victim", .{prefix});
    defer testing.allocator.free(victim);
    try test_io.cwd().createDirPath(io, victim);
    const pkg_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/{s}", .{ prefix, name });
    defer testing.allocator.free(pkg_dir);
    try test_io.symLinkAbsolute(io, victim, pkg_dir, .{ .is_directory = true });
}

fn claimedRefs(db: *sqlite.Database) !i64 {
    var stmt = try db.prepare(
        "SELECT COALESCE(SUM(refcount), 0) FROM store_refs WHERE store_sha256 = ?1;",
    );
    defer stmt.finalize();
    try stmt.bindText(1, sha);
    _ = try stmt.step();
    return stmt.columnInt(0);
}

fn kegRows(db: *sqlite.Database) !i64 {
    var stmt = try db.prepare("SELECT count(*) FROM kegs;");
    defer stmt.finalize();
    _ = try stmt.step();
    return stmt.columnInt(0);
}

const Harness = struct {
    /// `migrateKeg` frees the formula JSON its `BrewApi` allocated and
    /// leaves the returned keg path to the caller's allocator, so both
    /// share one arena here — as they share one allocator in production.
    arena: std.heap.ArenaAllocator,
    threaded: std.Io.Threaded,
    http: malt.client.HttpClient,
    ghcr: malt.ghcr.GhcrClient,
    api: malt.api.BrewApi,
    db: sqlite.Database,
    store: malt.store.Store,
    linker: malt.linker.Linker,

    fn ctx(self: *Harness) malt.app_ctx.AppCtx {
        return .{ .io = self.threaded.io(), .environ = .empty };
    }

    /// `db_mu` non-null is the `--parallel` shape: the worker lock is
    /// taken around the record + claim region.
    fn parallelDeps(self: *Harness, fx: *const Fixture, mu: *std.Io.Mutex) migrate_keg.MigrateDeps {
        var d = self.deps(fx);
        d.db_mu = mu;
        return d;
    }

    fn deps(self: *Harness, fx: *const Fixture) migrate_keg.MigrateDeps {
        return .{
            .api = &self.api,
            .ghcr = &self.ghcr,
            .http = &self.http,
            .store = &self.store,
            .linker = &self.linker,
            .db = &self.db,
            .prefix = fx.prefix,
            .homebrew_prefix = fx.brew_prefix,
            .use_system_ruby_scope = &.{},
        };
    }

    fn deinit(self: *Harness) void {
        self.ghcr.deinit();
        self.http.deinit();
        self.db.close();
        self.threaded.deinit();
        self.arena.deinit();
    }
};

/// `Harness` self-references through pointers, so it has to be filled in
/// place rather than returned by value.
fn initHarness(h: *Harness, fx: *const Fixture) !void {
    h.arena = std.heap.ArenaAllocator.init(testing.allocator);
    h.threaded = .init(testing.allocator, .{});
    const io = h.threaded.io();
    h.http = malt.client.HttpClient.init(io, .empty, testing.allocator);
    h.ghcr = malt.ghcr.GhcrClient.init(io, testing.allocator, &h.http);
    h.api = malt.api.BrewApi.init(io, h.arena.allocator(), &h.http, fx.cache_dir);
    h.db = try sqlite.Database.open(":memory:");
    try schema.initSchema(&h.db);
    h.store = malt.store.Store.init(io, testing.allocator, &h.db, fx.prefix);
    h.linker = malt.linker.Linker.init(io, testing.allocator, &h.db, fx.prefix);
}

test "a refused migrate claims no store bytes, however often it is retried" {
    var fx = try Fixture.init("refused");
    defer fx.deinit();
    try fx.seed("planted", false);

    var h: Harness = undefined;
    try initHarness(&h, &fx);
    defer h.deinit();

    try plantSymlinkedPackageDir(h.threaded.io(), fx.prefix, "planted");

    const ctx = h.ctx();
    const deps = h.deps(&fx);
    // Three attempts: one stranded bump is a bug, three is the inflation
    // that no reclaim path can ever drain.
    for (0..3) |_| {
        try testing.expectEqual(
            migrate_keg.KegResult.failed_install,
            migrate_keg.migrateKeg(&ctx, h.arena.allocator(), "planted", deps),
        );
    }

    try testing.expectEqual(@as(i64, 0), try kegRows(&h.db));
    try testing.expectEqual(@as(i64, 0), try claimedRefs(&h.db));
}

test "a successful migrate claims the bottle exactly once" {
    var fx = try Fixture.init("ok");
    defer fx.deinit();
    try fx.seed("planted", false);

    var h: Harness = undefined;
    try initHarness(&h, &fx);
    defer h.deinit();

    const ctx = h.ctx();
    const deps = h.deps(&fx);
    try testing.expectEqual(
        migrate_keg.KegResult.migrated,
        migrate_keg.migrateKeg(&ctx, h.arena.allocator(), "planted", deps),
    );

    try testing.expectEqual(@as(i64, 1), try kegRows(&h.db));
    try testing.expectEqual(@as(i64, 1), try claimedRefs(&h.db));
}

test "re-migrating an installed keg does not claim the bottle a second time" {
    var fx = try Fixture.init("again");
    defer fx.deinit();
    try fx.seed("planted", false);

    var h: Harness = undefined;
    try initHarness(&h, &fx);
    defer h.deinit();

    const ctx = h.ctx();
    const deps = h.deps(&fx);
    try testing.expectEqual(
        migrate_keg.KegResult.migrated,
        migrate_keg.migrateKeg(&ctx, h.arena.allocator(), "planted", deps),
    );
    try testing.expectEqual(
        migrate_keg.KegResult.skipped_installed,
        migrate_keg.migrateKeg(&ctx, h.arena.allocator(), "planted", deps),
    );

    try testing.expectEqual(@as(i64, 1), try claimedRefs(&h.db));
}

// The claim sits after both record branches; moving it inside the linked
// one would leave keg-only bottles unclaimed and reclaimable while live.
test "a keg-only migrate claims the bottle exactly once" {
    var fx = try Fixture.init("kegonly");
    defer fx.deinit();
    try fx.seed("planted", true);

    var h: Harness = undefined;
    try initHarness(&h, &fx);
    defer h.deinit();

    const ctx = h.ctx();
    const deps = h.deps(&fx);
    try testing.expectEqual(
        migrate_keg.KegResult.migrated,
        migrate_keg.migrateKeg(&ctx, h.arena.allocator(), "planted", deps),
    );

    try testing.expectEqual(@as(i64, 1), try kegRows(&h.db));
    try testing.expectEqual(@as(i64, 1), try claimedRefs(&h.db));
}

// `std.Io.Mutex` is not recursive, so routing the claim back through
// `incrementRefLocked` here would hang every worker rather than fail a
// check. This drives the locked shape end to end so that never ships.
test "a parallel-shaped migrate claims once without re-taking the worker lock" {
    var fx = try Fixture.init("parallel");
    defer fx.deinit();
    try fx.seed("planted", false);

    var h: Harness = undefined;
    try initHarness(&h, &fx);
    defer h.deinit();

    var db_mu: std.Io.Mutex = .init;
    const ctx = h.ctx();
    const deps = h.parallelDeps(&fx, &db_mu);
    try testing.expectEqual(
        migrate_keg.KegResult.migrated,
        migrate_keg.migrateKeg(&ctx, h.arena.allocator(), "planted", deps),
    );

    // Released, not still held by the run that just finished.
    try testing.expect(db_mu.tryLock());
    db_mu.unlock(h.threaded.io());

    try testing.expectEqual(@as(i64, 1), try claimedRefs(&h.db));
}
