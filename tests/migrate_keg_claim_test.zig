//! Integration tests for the store claim `cli/migrate/keg.zig::migrateKeg`
//! takes. A `store_refs` row no keg holds is an orphan, so the claim may
//! only land once a `kegs` row actually references the bytes — otherwise a
//! retried, blocked migrate hands the warm bottle to the next sweep.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const sqlite = malt.sqlite;
const schema = malt.schema;
const migrate_keg = malt.cli_migrate_keg;

/// 64 lowercase hex, or the bottle entry is dropped by the parser.
const sha = std.mem.asBytes(&@as([16][4]u8, @splat("feed".*)));

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
            const dir = try testing.allocator.print("{s}/{s}", .{ prefix, sub });
            defer testing.allocator.free(dir);
            try test_io.cwd().createDirPath(std.Options.debug_io, dir);
        }

        const cache_dir = try testing.allocator.print("{s}/cache", .{prefix});
        errdefer testing.allocator.free(cache_dir);
        const brew_prefix = try testing.allocator.print("{s}/brew", .{prefix});
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
        try self.seedBottle(name, keg_only, ":any", null);
    }

    /// Same as `seed`, with the bottle's `cellar` tag and an optional
    /// `app.conf` in the store entry.
    fn seedBottle(self: *const Fixture, name: []const u8, keg_only: bool, cellar: []const u8, conf: ?[]const u8) !void {
        const inner = try testing.allocator.print(
            "{s}/store/{s}/{s}/1.0",
            .{ self.prefix, sha, name },
        );
        defer testing.allocator.free(inner);
        try test_io.cwd().createDirPath(std.Options.debug_io, inner);
        try self.writeFile(inner, "README", "warm store probe\n");
        if (conf) |body| try self.writeFile(inner, "app.conf", body);

        const json = try testing.allocator.print(
            \\{{"name":"{s}","full_name":"{s}","tap":"homebrew/core","desc":"","homepage":"",
            \\ "versions":{{"stable":"1.0"}},"revision":0,"dependencies":[],"keg_only":{},
            \\ "post_install_defined":false,"oldnames":[],
            \\ "bottle":{{"stable":{{"files":{{"all":{{"cellar":"{s}",
            \\   "url":"https://ghcr.io/v2/homebrew/core/{s}/blobs/sha256:{s}","sha256":"{s}"}}}}}}}}}}
        , .{ name, name, keg_only, cellar, name, sha, sha });
        defer testing.allocator.free(json);

        const api_dir = try testing.allocator.print("{s}/api", .{self.cache_dir});
        defer testing.allocator.free(api_dir);
        const filename = try testing.allocator.print("formula_{s}.json", .{name});
        defer testing.allocator.free(filename);
        try self.writeFile(api_dir, filename, json);
    }

    fn writeFile(_: *const Fixture, dir: []const u8, name: []const u8, body: []const u8) !void {
        const path = try testing.allocator.print("{s}/{s}", .{ dir, name });
        defer testing.allocator.free(path);
        const f = try test_io.cwd().createFile(std.Options.debug_io, path, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, body);
    }
};

/// A symlinked package dir is the cheapest deterministic materialise refusal.
fn plantSymlinkedPackageDir(io: std.Io, prefix: []const u8, name: []const u8) !void {
    const victim = try testing.allocator.print("{s}/victim", .{prefix});
    defer testing.allocator.free(victim);
    try test_io.cwd().createDirPath(io, victim);
    const pkg_dir = try testing.allocator.print("{s}/Cellar/{s}", .{ prefix, name });
    defer testing.allocator.free(pkg_dir);
    try test_io.symLinkAbsolute(io, victim, pkg_dir, .{ .is_directory = true });
}

fn claimed(db: *sqlite.Database) !bool {
    var stmt = try db.prepare("SELECT 1 FROM store_refs WHERE store_sha256 = ?1;");
    defer stmt.finalize();
    try stmt.bindText(1, sha);
    return try stmt.step();
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
    // Three attempts: a claim taken by any of them would be a row no keg
    // holds, and the sweep would reclaim the warm bytes the next migrate needs.
    for (0..3) |_| {
        try testing.expectEqual(
            migrate_keg.KegResult.failed_install,
            migrate_keg.migrateKeg(&ctx, h.arena.allocator(), "planted", deps),
        );
    }

    try testing.expectEqual(@as(i64, 0), try kegRows(&h.db));
    try testing.expect(!try claimed(&h.db));
}

test "a successful migrate claims the bottle" {
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
    try testing.expect(try claimed(&h.db));
}

test "re-migrating an installed keg keeps the bottle claimed" {
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

    try testing.expect(try claimed(&h.db));
}

// The claim sits after the shared record step; gating it on the link
// would leave keg-only bottles unclaimed and reclaimable while live.
test "a keg-only migrate claims the bottle" {
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
    try testing.expect(try claimed(&h.db));
}

// `std.Io.Mutex` is not recursive, so re-taking `db_mu` around the claim
// would hang every worker rather than fail a check. This drives the locked
// shape end to end so that never ships.
test "a parallel-shaped migrate claims without re-taking the worker lock" {
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

    try testing.expect(try claimed(&h.db));
}

// The bottle's own `cellar` tag fixes the prefix its text was written for.
// A tag whose prefix length differs from both host defaults shows whether
// migrate passes it on: a record sized for that prefix must be resized.
test "a migrate sizes length-prefixed text for the prefix the bottle was built under" {
    var fx = try Fixture.init("celltag");
    defer fx.deinit();
    const built = "/opt/malt-brew";
    try testing.expect(built.len != "/opt/homebrew".len and built.len != "/usr/local".len);
    const before = try testing.allocator.print("s:{d}:\"@@HOMEBREW_PREFIX@@\";", .{built.len});
    defer testing.allocator.free(before);
    try fx.seedBottle("planted", false, built ++ "/Cellar", before);

    var h: Harness = undefined;
    try initHarness(&h, &fx);
    defer h.deinit();

    const ctx = h.ctx();
    try testing.expectEqual(
        migrate_keg.KegResult.migrated,
        migrate_keg.migrateKeg(&ctx, h.arena.allocator(), "planted", h.deps(&fx)),
    );

    const path = try testing.allocator.print("{s}/Cellar/planted/1.0/app.conf", .{fx.prefix});
    defer testing.allocator.free(path);
    const got = try test_io.readFileAbsoluteAlloc(std.Options.debug_io, testing.allocator, path, 4096);
    defer testing.allocator.free(got);
    // Relocation writes the process prefix, not the fixture's.
    const live = test_io.getenv("MALT_PREFIX") orelse return error.SkipZigTest;
    try testing.expect(live.len != built.len);
    const want = try testing.allocator.print("s:{d}:\"{s}\";", .{ live.len, live });
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, got);
}

// ── cold-path cellar tag ───────────────────────────────────────────────────
//
// Rollback sizes relocated text by the tag stored with the entry, and only
// a cold migrate writes it. So this drives `migrateKeg` with an empty store
// against a loopback registry. The archive carries a tag file of its own:
// a bottle must never choose the tag that rollback trusts.

const net = std.Io.net;

const BottleStub = struct { io: std.Io, listener: *net.Server, body: []const u8 };

fn serveBottle(s: *BottleStub) void {
    const stream = s.listener.accept(s.io) catch return;
    defer stream.close(s.io);
    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(s.io, &rbuf);
    var writer = stream.writer(s.io, &wbuf);
    var srv = std.http.Server.init(&reader.interface, &writer.interface);
    while (true) {
        var req = srv.receiveHead() catch return;
        if (std.mem.find(u8, req.head.target, "/token") != null) {
            req.respond("{\"token\":\"t1\"}", .{}) catch return;
        } else if (std.mem.find(u8, req.head.target, "/blobs/") != null) {
            req.respond(s.body, .{}) catch return;
        } else {
            req.respond("not found\n", .{ .status = .not_found }) catch return;
        }
    }
}

// Wakes `serveBottle` if it is still parked in `accept`. Without it, a call
// that fails before it connects leaves `join` waiting forever.
fn knock(io: std.Io, port: u16) void {
    var addr = net.IpAddress.parseIp4("127.0.0.1", port) catch return;
    const s = addr.connect(io, .{ .mode = .stream }) catch return;
    s.close(io);
}

// `std.Options.debug_io`'s failing allocator cannot back a child spawn.
fn tarCzf(argv: []const []const u8) !void {
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{ .environ = malt.app_ctx.processEnviron() });
    defer threaded.deinit();
    var child = try std.process.spawn(threaded.io(), .{ .argv = argv, .stdout = .ignore, .stderr = .ignore });
    switch (try child.wait(threaded.io())) {
        .exited => |code| if (code != 0) return error.TarFailed,
        else => return error.TarFailed,
    }
}

test "migrateKeg stores the bottle's cellar tag for a bottle it downloads" {
    try test_io.skipIfNoSubprocess();

    var fx = try Fixture.init("coldtag");
    defer fx.deinit();

    var h: Harness = undefined;
    try initHarness(&h, &fx);
    defer h.deinit();
    const io = h.threaded.io();

    // A bottle with the layout the store commit expects, plus a tag file.
    const work = try testing.allocator.print("{s}/work", .{fx.prefix});
    defer testing.allocator.free(work);
    const payload = try testing.allocator.print("{s}/coldpkg/1.0", .{work});
    defer testing.allocator.free(payload);
    try test_io.cwd().createDirPath(io, payload);
    try fx.writeFile(payload, "README", "cold bottle fixture\n");
    try fx.writeFile(work, ".malt-cellar-tag", "/evil/Cellar\n");
    const archive = try testing.allocator.print("{s}/bottle.tar.gz", .{fx.prefix});
    defer testing.allocator.free(archive);
    try tarCzf(&.{ "tar", "czf", archive, "-C", work, "coldpkg", ".malt-cellar-tag" });

    const body = try test_io.readFileAbsoluteAlloc(io, testing.allocator, archive, 1 << 20);
    defer testing.allocator.free(body);
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &raw, .{});
    const bottle_sha = std.fmt.bytesToHex(raw, .lower);

    // The formula is cached, the store is empty: the download branch runs.
    const tag = "/opt/malt-brew/Cellar";
    const json = try testing.allocator.print(
        \\{{"name":"coldpkg","full_name":"coldpkg","tap":"homebrew/core","desc":"","homepage":"",
        \\ "versions":{{"stable":"1.0"}},"revision":0,"dependencies":[],"keg_only":false,
        \\ "post_install_defined":false,"oldnames":[],
        \\ "bottle":{{"stable":{{"files":{{"all":{{"cellar":"{s}",
        \\   "url":"https://ghcr.io/v2/homebrew/core/coldpkg/blobs/sha256:{s}","sha256":"{s}"}}}}}}}}}}
    , .{ tag, &bottle_sha, &bottle_sha });
    defer testing.allocator.free(json);
    const api_dir = try testing.allocator.print("{s}/api", .{fx.cache_dir});
    defer testing.allocator.free(api_dir);
    try fx.writeFile(api_dir, "formula_coldpkg.json", json);

    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var stub = BottleStub{ .io = io, .listener = &listener, .body = body };

    var base_buf: [64]u8 = undefined;
    const base_url = try std.mem.print(&base_buf, "http://127.0.0.1:{d}", .{listener.socket.address.getPort()});
    // Point the harness at the stub; `ghcr` holds a pointer to `h.http`.
    var inner: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    h.http.deinit();
    h.http = malt.client.HttpClient.initWith(&inner, io, .empty, testing.allocator);
    h.ghcr.base_url = base_url;

    const ctx = h.ctx();
    // No `try` between the spawn and the call, so a setup failure never frees
    // the listener under a running thread.
    const server_thread = try std.Thread.spawn(.{}, serveBottle, .{&stub});
    const result = migrate_keg.migrateKeg(&ctx, h.arena.allocator(), "coldpkg", h.deps(&fx));

    // Join before any assertion: a failure must not free the listener
    // under the serving thread. The knock ends a server that was never dialed.
    h.http.deinit();
    h.http = malt.client.HttpClient.init(io, .empty, testing.allocator);
    knock(io, listener.socket.address.getPort());
    server_thread.join();

    try testing.expectEqual(migrate_keg.KegResult.migrated, result);
    const entry = try testing.allocator.print("{s}/store/{s}", .{ fx.prefix, &bottle_sha });
    defer testing.allocator.free(entry);
    var buf: [malt.cellar_tag.buf_len]u8 = undefined;
    const got = malt.cellar_tag.read(io, entry, &bottle_sha, &buf) orelse return error.TestNoTag;
    try testing.expectEqualStrings(tag, got);
}
