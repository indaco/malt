//! Integration tests for `cli/install/download.zig::installKegFromBottle`.
//! Each test wires the function against a real on-disk prefix so the
//! warm-store skip path is exercised end-to-end through the actual
//! `core/store` + `core/cellar` flow — the same one that install and
//! upgrade hit in production.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const formula_mod = malt.formula;
const sqlite = malt.sqlite;
const schema = malt.schema;

fn setupPrefix(suffix: []const u8) ![:0]u8 {
    const base = try test_io.uniqueTempPath(testing.allocator, "installkfb", suffix);
    defer testing.allocator.free(base);
    const path = try testing.allocator.dupeZ(u8, base);
    test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, path);
    // Mandatory layout subdirs — Cellar / store live here.
    inline for (.{ "store", "Cellar" }) |sub| {
        const dir = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ path, sub });
        defer testing.allocator.free(dir);
        try test_io.cwd().createDirPath(std.Options.debug_io, dir);
    }
    return path;
}

test "installKegFromBottle short-circuits to NoBottle when no platform bottle resolves" {
    const prefix = try setupPrefix("nobottle");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const formula_json =
        \\{
        \\  "name": "noplatform",
        \\  "full_name": "noplatform",
        \\  "tap": "homebrew/core",
        \\  "desc": "",
        \\  "homepage": "",
        \\  "versions": {"stable": "1.0"},
        \\  "revision": 0,
        \\  "dependencies": [],
        \\  "keg_only": false,
        \\  "post_install_defined": false,
        \\  "oldnames": [],
        \\  "bottle": {"stable": {"files": {}}}
        \\}
    ;
    var formula = try formula_mod.parseFormula(arena.allocator(), formula_json);
    defer formula.deinit();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    var http = malt.client.HttpClient.init(ctx.io, ctx.environ, testing.allocator);
    defer http.deinit();
    var ghcr = malt.ghcr.GhcrClient.init(ctx.io, testing.allocator, &http);
    defer ghcr.deinit();
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    var store = malt.store.Store.init(ctx.io, testing.allocator, &db, prefix);

    try testing.expectError(
        malt.install_record.InstallError.NoBottle,
        malt.install_download.installKegFromBottle(
            &ctx,
            testing.allocator,
            .{ .ghcr = &ghcr, .http = &http, .store = &store },
            &formula,
            prefix,
        ),
    );
}

test "installKegFromBottle skips the download branch when the store already holds the bottle (warm path)" {
    const prefix = try setupPrefix("warm");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    // Pre-populate /store/<sha>/ so `store.exists(sha)` is true and the
    // download branch is bypassed entirely. The bottle "contents" are a
    // single text file under name/version/ — the layout `cellar.materialize`
    // expects clonefile-copied into Cellar. The bottle declares
    // `cellar = ":any"` so the Mach-O patcher + codesign step both skip,
    // letting a plain text file through without faking a real binary.
    const sha = "ba5e" ** 16; // 64 hex chars
    const inner_dir = try std.fmt.allocPrint(testing.allocator, "{s}/store/{s}/warmpkg/1.0", .{ prefix, sha });
    defer testing.allocator.free(inner_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, inner_dir);
    {
        const filename = try std.fmt.allocPrint(testing.allocator, "{s}/README", .{inner_dir});
        defer testing.allocator.free(filename);
        const f = try test_io.cwd().createFile(std.Options.debug_io, filename, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "warm-store integration probe\n");
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // `"all"` platform key wins on every host arch — keeps this test
    // arch-independent and avoids encoding the current macOS codename
    // list in two places.
    const formula_json = try std.fmt.allocPrint(
        arena.allocator(),
        \\{{
        \\  "name": "warmpkg",
        \\  "full_name": "warmpkg",
        \\  "tap": "homebrew/core",
        \\  "desc": "",
        \\  "homepage": "",
        \\  "versions": {{"stable": "1.0"}},
        \\  "revision": 0,
        \\  "dependencies": [],
        \\  "keg_only": false,
        \\  "post_install_defined": false,
        \\  "oldnames": [],
        \\  "bottle": {{"stable": {{"files": {{"all": {{"cellar": ":any", "url": "https://ghcr.io/v2/homebrew/core/warmpkg/blobs/sha256:{s}", "sha256": "{s}"}}}}}}}}
        \\}}
    ,
        .{ sha, sha },
    );
    var formula = try formula_mod.parseFormula(arena.allocator(), formula_json);
    defer formula.deinit();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    var http = malt.client.HttpClient.init(ctx.io, ctx.environ, testing.allocator);
    defer http.deinit();
    var ghcr = malt.ghcr.GhcrClient.init(ctx.io, testing.allocator, &http);
    defer ghcr.deinit();
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var store = malt.store.Store.init(ctx.io, testing.allocator, &db, prefix);

    const result = try malt.install_download.installKegFromBottle(
        &ctx,
        testing.allocator,
        .{ .ghcr = &ghcr, .http = &http, .store = &store },
        &formula,
        prefix,
    );
    // cellar.materializeWithCellar dupes the keg path so it outlives
    // the helper's stack — production calls hand it off to the same
    // allocator that owns the formula, here the test owns it.
    defer testing.allocator.free(result.keg.path);

    // Returned sha matches what was on disk — proves the function read
    // from the formula's bottle entry rather than fabricating a value.
    try testing.expectEqualStrings(sha, result.sha256);

    // Cellar/<name>/<version>/ exists on disk — materialise ran.
    const cellar_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/warmpkg/1.0", .{prefix});
    defer testing.allocator.free(cellar_dir);
    try std.Io.Dir.accessAbsolute(std.Options.debug_io, cellar_dir, .{});

    // README copied across the clonefile boundary.
    const cellar_readme = try std.fmt.allocPrint(testing.allocator, "{s}/README", .{cellar_dir});
    defer testing.allocator.free(cellar_readme);
    try std.Io.Dir.accessAbsolute(std.Options.debug_io, cellar_readme, .{});
}

test "installKegFromBottle stamps the specific CellarError variant into cellar_diag on materialise failure" {
    const prefix = try setupPrefix("diag");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    // Pre-seed `store/<sha>/` so `installKegFromBottle` skips the
    // download branch and goes straight to `materializeWithCellar`.
    const sha = "feed" ** 16;
    const store_inner = try std.fmt.allocPrint(testing.allocator, "{s}/store/{s}", .{ prefix, sha });
    defer testing.allocator.free(store_inner);
    try test_io.cwd().createDirPath(std.Options.debug_io, store_inner);

    // A 230 + 230 char name+version overflows the cellar-path 512-byte
    // stack buffer in `materializeWithCellar`, which surfaces as
    // `CellarError.PathTooLong`. We pin that specific variant to prove
    // `cellar_diag` carries the real cause, not a generic catch-all.
    const long_name = "a" ** 230;
    const long_ver = "1" ** 230;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const formula_json = try std.fmt.allocPrint(
        arena.allocator(),
        \\{{
        \\  "name": "{s}",
        \\  "full_name": "{s}",
        \\  "tap": "homebrew/core",
        \\  "desc": "",
        \\  "homepage": "",
        \\  "versions": {{"stable": "{s}"}},
        \\  "revision": 0,
        \\  "dependencies": [],
        \\  "keg_only": false,
        \\  "post_install_defined": false,
        \\  "oldnames": [],
        \\  "bottle": {{"stable": {{"files": {{"all": {{"cellar": ":any", "url": "https://ghcr.io/v2/homebrew/core/x/blobs/sha256:{s}", "sha256": "{s}"}}}}}}}}
        \\}}
    ,
        .{ long_name, long_name, long_ver, sha, sha },
    );
    var formula = try formula_mod.parseFormula(arena.allocator(), formula_json);
    defer formula.deinit();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    var http = malt.client.HttpClient.init(ctx.io, ctx.environ, testing.allocator);
    defer http.deinit();
    var ghcr = malt.ghcr.GhcrClient.init(ctx.io, testing.allocator, &http);
    defer ghcr.deinit();
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var store = malt.store.Store.init(ctx.io, testing.allocator, &db, prefix);

    var cellar_diag: ?malt.cellar.CellarError = null;
    try testing.expectError(
        malt.install_record.InstallError.CellarFailed,
        malt.install_download.installKegFromBottle(
            &ctx,
            testing.allocator,
            .{
                .ghcr = &ghcr,
                .http = &http,
                .store = &store,
                .cellar_diag = &cellar_diag,
            },
            &formula,
            prefix,
        ),
    );
    try testing.expectEqual(
        @as(?malt.cellar.CellarError, malt.cellar.CellarError.PathTooLong),
        cellar_diag,
    );
}

// ── cold-path store claim ──────────────────────────────────────────────────
//
// The refcount bump is the store's "these bytes are claimed" marker, and it
// is only reachable on a cold commit — the warm path skips it by contract.
// So this arm serves a real bottle over a loopback registry, the same
// offline transport `bottle_download_test.zig` uses.

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
        if (std.mem.indexOf(u8, req.head.target, "/token") != null) {
            req.respond("{\"token\":\"t1\"}", .{}) catch return;
        } else if (std.mem.indexOf(u8, req.head.target, "/blobs/") != null) {
            req.respond(s.body, .{}) catch return;
        } else {
            req.respond("not found\n", .{ .status = .not_found }) catch return;
        }
    }
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

fn refRows(db: *sqlite.Database, sha: []const u8) !i64 {
    var stmt = try db.prepare("SELECT count(*) FROM store_refs WHERE store_sha256 = ?1;");
    defer stmt.finalize();
    try stmt.bindText(1, sha);
    _ = try stmt.step();
    return stmt.columnInt(0);
}

fn claimedRefs(db: *sqlite.Database, sha: []const u8) !i64 {
    var stmt = try db.prepare("SELECT count(*) FROM store_refs WHERE store_sha256 = ?1 AND refcount > 0;");
    defer stmt.finalize();
    try stmt.bindText(1, sha);
    _ = try stmt.step();
    return stmt.columnInt(0);
}

test "installKegFromBottle claims no store bytes when the materialise is refused" {
    try test_io.skipIfNoSubprocess();

    const prefix = try setupPrefix("coldrefused");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Mint a real bottle: `<name>/<version>/README`, the layout the store
    // commit and the cellar clone both expect.
    const payload = try std.fmt.allocPrint(testing.allocator, "{s}/work/coldpkg/1.0", .{prefix});
    defer testing.allocator.free(payload);
    try test_io.cwd().createDirPath(io, payload);
    const readme = try std.fmt.allocPrint(testing.allocator, "{s}/README", .{payload});
    defer testing.allocator.free(readme);
    {
        const f = try test_io.createFileAbsolute(io, readme, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "cold bottle fixture\n");
    }
    const work = try std.fmt.allocPrint(testing.allocator, "{s}/work", .{prefix});
    defer testing.allocator.free(work);
    const archive = try std.fmt.allocPrint(testing.allocator, "{s}/bottle.tar.gz", .{prefix});
    defer testing.allocator.free(archive);
    try tarCzf(&.{ "tar", "czf", archive, "-C", work, "coldpkg" });

    const body = try test_io.readFileAbsoluteAlloc(io, testing.allocator, archive, 1 << 20);
    defer testing.allocator.free(body);
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &raw, .{});
    const sha = std.fmt.bytesToHex(raw, .lower);

    // A symlinked package dir is the cheapest deterministic refusal.
    const victim = try std.fmt.allocPrint(testing.allocator, "{s}/victim", .{prefix});
    defer testing.allocator.free(victim);
    try test_io.cwd().createDirPath(io, victim);
    const pkg_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/coldpkg", .{prefix});
    defer testing.allocator.free(pkg_dir);
    try test_io.symLinkAbsolute(io, victim, pkg_dir, .{ .is_directory = true });

    var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var stub = BottleStub{ .io = io, .listener = &listener, .body = body };
    const server_thread = try std.Thread.spawn(.{}, serveBottle, .{&stub});

    var base_buf: [64]u8 = undefined;
    const base_url = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{listener.socket.address.getPort()});

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const formula_json = try std.fmt.allocPrint(
        arena.allocator(),
        \\{{
        \\  "name": "coldpkg",
        \\  "full_name": "coldpkg",
        \\  "tap": "homebrew/core",
        \\  "desc": "",
        \\  "homepage": "",
        \\  "versions": {{"stable": "1.0"}},
        \\  "revision": 0,
        \\  "dependencies": [],
        \\  "keg_only": false,
        \\  "post_install_defined": false,
        \\  "oldnames": [],
        \\  "bottle": {{"stable": {{"files": {{"all": {{"cellar": ":any", "url": "https://ghcr.io/v2/homebrew/core/coldpkg/blobs/sha256:{s}", "sha256": "{s}"}}}}}}}}
        \\}}
    ,
        .{ &sha, &sha },
    );
    var formula = try formula_mod.parseFormula(arena.allocator(), formula_json);
    defer formula.deinit();

    var inner: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    var http = malt.client.HttpClient.initWith(&inner, io, std.process.Environ.empty, testing.allocator);
    var ghcr = malt.ghcr.GhcrClient.init(io, testing.allocator, &http);
    defer ghcr.deinit();
    ghcr.base_url = base_url;

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var store = malt.store.Store.init(io, testing.allocator, &db, prefix);

    const ctx: malt.app_ctx.AppCtx = .{ .io = io, .environ = .empty };
    var cellar_diag: ?malt.cellar.CellarError = null;
    const result = malt.install_download.installKegFromBottle(
        &ctx,
        testing.allocator,
        .{ .ghcr = &ghcr, .http = &http, .store = &store, .cellar_diag = &cellar_diag },
        &formula,
        prefix,
    );

    http.deinit();
    server_thread.join();

    try testing.expectError(malt.install_record.InstallError.CellarFailed, result);
    try testing.expectEqual(
        @as(?malt.cellar.CellarError, malt.cellar.CellarError.UnsafeCellarLink),
        cellar_diag,
    );

    // Without this the assertion below would also hold for a download that
    // never happened, i.e. the cold path was really taken.
    try testing.expect(store.exists(&sha));

    // No keg row references these bytes, so nothing may claim them. Note
    // this leaves NO row, which is not the same as reclaimable: purge
    // defines an orphan as a row at refcount <= 0, and a rowless entry is
    // deliberately invisible to it. What this pins is that the refcount
    // never lies about a keg that does not exist.
    try testing.expectEqual(@as(i64, 0), try claimedRefs(&db, &sha));
    try testing.expectEqual(@as(i64, 0), try refRows(&db, &sha));
}
