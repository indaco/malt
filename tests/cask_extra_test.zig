//! malt — extra cask coverage
//! Covers isAppRunningPub and the CaskInstaller's install/uninstall
//! short-circuit branches that run without network.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");
const cask = malt.cask;
const sqlite = malt.sqlite;
const schema = malt.schema;

fn testIo() std.Io {
    return std.Options.debug_io;
}

fn testEnviron() std.process.Environ {
    return malt.app_ctx.processEnviron();
}

/// Scratch tree under a process-unique base, so overlapping test runs cannot
/// wipe each other's fixtures.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    base: [:0]const u8,

    fn init(tag: []const u8) !Fixture {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const base = try test_io.uniqueTempPath(arena.allocator(), "cask_extra", tag);
        const base_z = try arena.allocator().dupeZ(u8, base);
        test_io.deleteTreeAbsolute(std.Options.debug_io, base_z) catch {};
        try test_io.cwd().createDirPath(std.Options.debug_io, base_z);
        return .{ .arena = arena, .base = base_z };
    }

    /// Absolute path to `sub` inside the fixture; valid until `deinit`.
    fn p(self: *Fixture, sub: []const u8) [:0]const u8 {
        return std.fmt.allocPrintSentinel(
            self.arena.allocator(),
            "{s}/{s}",
            .{ self.base, sub },
            0,
        ) catch @panic("OOM");
    }

    fn deinit(self: *Fixture) void {
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.base) catch {};
        self.arena.deinit();
    }
};

test "isAppRunningPub returns false for a path no pgrep match can cover" {
    // An impossible sentinel path — pgrep will not match, so isAppRunning
    // exits non-zero and the wrapper returns false.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = testEnviron() });
    defer threaded.deinit();
    try testing.expect(!cask.CaskInstaller.isAppRunningPub(threaded.io(), "/nonexistent/Sentinel-path-never-running.app"));
}

/// True when a live process matches `pattern`. Bracket the pattern's first byte or
/// this probe matches its own command line.
fn pgrepMatches(io: std.Io, pattern: []const u8) bool {
    var child = std.process.spawn(io, .{
        .argv = &.{ "pgrep", "-f", pattern },
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(io) catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        .signal, .stopped, .unknown => false,
    };
}

test "a concurrent probe's own command line never reads as the app running" {
    // Two uninstalls of one cask overlap: each probe carries its pattern in its argv,
    // so an unquoted one matches the other and both refuse. The stand-in below is that
    // second probe, held live for the length of the check.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();

    const path = "/nonexistent/Racing-probe-never-running.app";
    var buf: [256]u8 = undefined;
    const pattern = cask.pgrepPattern(&buf, path).?;

    const marker = "malt_probe_stand_in_marker";
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "read x", marker, pattern },
        .stdin = .pipe, // blocks on the unwritten pipe, so it stays one live process
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(io); // kill also reaps

    // Spawn→exec is async: settle before asserting, or the check passes on an absent
    // stand-in. `[m]` keeps this poll from matching itself.
    var tries: usize = 0;
    while (tries < 300 and !pgrepMatches(io, "[m]alt_probe_stand_in_marker")) : (tries += 1) {}
    try testing.expect(pgrepMatches(io, "[m]alt_probe_stand_in_marker")); // stand-in is live

    try testing.expect(!cask.CaskInstaller.isAppRunningPub(io, path));
}

test "CaskInstaller.uninstall on a missing token returns UninstallFailed" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    const prefix: [:0]const u8 = "/tmp/mcask";
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = testEnviron() });
    defer threaded.deinit();
    var installer = cask.CaskInstaller.init(threaded.io(), testEnviron(), testing.allocator, &db, prefix);
    try testing.expectError(cask.CaskError.UninstallFailed, installer.uninstall("nope-nope"));
}

test "CaskInstaller.uninstall refuses with AppRunning while the app bundle is live" {
    const test_cask_json =
        \\{"token":"running-app","name":["Running"],"version":"1.0","desc":"","homepage":"",
        \\ "url":"https://example.com/running.dmg",
        \\ "sha256":"00000000000000000000000000000000000000000000000000000000deadbeef",
        \\ "auto_updates":false,"artifacts":[{"app":["Running.app"]}]}
    ;
    var c = try cask.parseCask(testing.allocator, test_cask_json);
    defer c.deinit();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    var bundle = try Fixture.init("running_bundle");
    defer bundle.deinit();
    const app_path_z = bundle.p("Running.app");
    try test_io.makeDirAbsolute(std.Options.debug_io, app_path_z);
    try cask.recordInstall(&db, &c, app_path_z, null);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();

    // Stand in for the running .app: a live process whose argv carries the
    // bundle path so `pgrep -f` matches. `read x` blocks on the unwritten pipe,
    // so it stays a single process with no orphaned child to leak.
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "read x", app_path_z },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(io); // kill also reaps

    // Spawn→exec is async; poll until pgrep can see it. Each probe spawns
    // pgrep (~ms), so the loop self-paces without a sleep dependency.
    var tries: usize = 0;
    while (tries < 300 and !cask.CaskInstaller.isAppRunningPub(io, app_path_z)) : (tries += 1) {}

    var fx = try Fixture.init("running_prefix");
    defer fx.deinit();
    var installer = cask.CaskInstaller.init(io, testEnviron(), testing.allocator, &db, fx.base);
    // Distinct from UninstallFailed so the CLI can say "the app is running".
    try testing.expectError(cask.CaskError.AppRunning, installer.uninstall("running-app"));
}

test "CaskInstaller.isOutdated returns false for an unknown token" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    const prefix: [:0]const u8 = "/tmp/mcask2";
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = testEnviron() });
    defer threaded.deinit();
    var installer = cask.CaskInstaller.init(threaded.io(), testEnviron(), testing.allocator, &db, prefix);
    try testing.expect(!try installer.isOutdated("nope-nope", "1.0"));
}

test "CaskInstaller.install rejects a cask with an unknown artifact URL extension" {
    const unknown_cask_json =
        \\{"token":"weird","name":["Weird"],"version":"1.0",
        \\ "url":"https://example.com/payload.unknown-ext",
        \\ "sha256":"no_check","homepage":"","desc":"","auto_updates":false,"artifacts":[]}
    ;
    var c = try cask.parseCask(testing.allocator, unknown_cask_json);
    defer c.deinit();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    const prefix: [:0]const u8 = "/tmp/mc3";
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = testEnviron() });
    defer threaded.deinit();
    var installer = cask.CaskInstaller.init(threaded.io(), testEnviron(), testing.allocator, &db, prefix);
    try testing.expectError(cask.CaskError.InstallFailed, installer.install(&c));
}

test "artifact_type_override bypasses URL detection" {
    // Extensionless URL would normally fail; override lets it proceed
    // past the type gate (install still fails later, but not at the gate).
    const extensionless_json =
        \\{"token":"noext","name":["NoExt"],"version":"1.0",
        \\ "url":"https://example.com/download?build=arm",
        \\ "sha256":"no_check","homepage":"","desc":"","auto_updates":false,"artifacts":[]}
    ;
    var c = try cask.parseCask(testing.allocator, extensionless_json);
    defer c.deinit();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    var fx = try Fixture.init("override");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = testEnviron() });
    defer threaded.deinit();
    var installer = cask.CaskInstaller.init(threaded.io(), testEnviron(), testing.allocator, &db, fx.base);

    // Without override: fails at the type gate with InstallFailed
    try testing.expectError(cask.CaskError.InstallFailed, installer.install(&c));

    // With override: passes the type gate (gets further before failing)
    installer.artifact_type_override = .dmg;
    test_io.cwd().createDirPath(std.Options.debug_io, fx.p("cache/Cask")) catch {};
    const result = installer.install(&c);
    // Should fail on download, not on the type gate
    try testing.expectError(cask.CaskError.DownloadFailed, result);
}

// Locking the connection read-only after the row is staged makes the
// `removeRecord` DELETE fail at `sqlite3_step`. The previous `catch {}`
// swallowed the failure into "uninstall succeeded"; the typed error path
// gives the CLI caller something to log `db.errMsg()` for.
test "CaskInstaller.uninstall propagates removeRecord SqliteError" {
    const test_cask_json =
        \\{"token":"firefox","name":["Firefox"],"version":"123.0","desc":"","homepage":"",
        \\ "url":"https://example.com/firefox.dmg",
        \\ "sha256":"00000000000000000000000000000000000000000000000000000000deadbeef",
        \\ "auto_updates":false,"artifacts":[{"app":["Firefox.app"]}]}
    ;
    var c = try cask.parseCask(testing.allocator, test_cask_json);
    defer c.deinit();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    var bundle = try Fixture.init("uninstall_readonly_bundle");
    defer bundle.deinit();

    const app_path_z = bundle.p("Firefox.app");
    try test_io.makeDirAbsolute(std.Options.debug_io, app_path_z);

    try cask.recordInstall(&db, &c, app_path_z, null);

    // Writes now fail at step; SELECT keeps working so uninstall reaches
    // the previously-swallowed `removeRecord` call.
    try db.exec("PRAGMA query_only=ON;");

    var fx = try Fixture.init("uninstall_readonly_prefix");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = testEnviron() });
    defer threaded.deinit();
    var installer = cask.CaskInstaller.init(threaded.io(), testEnviron(), testing.allocator, &db, fx.base);

    try testing.expectError(sqlite.SqliteError.StepFailed, installer.uninstall("firefox"));
}

test "CaskInstaller.uninstall removes app_path, caskroom, cache, and the DB row" {
    const test_cask_json =
        \\{"token":"firefox","name":["Firefox"],"version":"123.0","desc":"","homepage":"",
        \\ "url":"https://example.com/firefox.dmg",
        \\ "sha256":"00000000000000000000000000000000000000000000000000000000deadbeef",
        \\ "auto_updates":false,"artifacts":[{"app":["Firefox.app"]}]}
    ;
    var c = try cask.parseCask(testing.allocator, test_cask_json);
    defer c.deinit();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    // Stage a scratch "app bundle" that uninstall will try to delete.
    var bundle = try Fixture.init("uninstall_bundle");
    defer bundle.deinit();

    const app_path_z = bundle.p("Firefox.app");
    try test_io.makeDirAbsolute(std.Options.debug_io, app_path_z);

    try cask.recordInstall(&db, &c, app_path_z, null);
    try testing.expect(cask.isInstalled(&db, "firefox"));

    var fx = try Fixture.init("uninstall_prefix");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = testEnviron() });
    defer threaded.deinit();
    var installer = cask.CaskInstaller.init(threaded.io(), testEnviron(), testing.allocator, &db, fx.base);
    try installer.uninstall("firefox");

    // DB row is gone and the staged "app bundle" has been removed.
    try testing.expect(!cask.isInstalled(&db, "firefox"));
    try testing.expectError(error.FileNotFound, test_io.openDirAbsolute(std.Options.debug_io, app_path_z, .{}));
}

// --- absent cask digest fails closed, and says so ------------------------

/// Minimal loopback origin: answers every GET with `body`. Enough to drive
/// `downloadOnly` through a real fetch without touching the network.
const BodyStub = struct { io: std.Io, listener: *std.Io.net.Server, body: []const u8 };

fn serveBody(s: *BodyStub) void {
    const stream = s.listener.accept(s.io) catch return;
    defer stream.close(s.io);
    var rbuf: [8 * 1024]u8 = undefined;
    var wbuf: [8 * 1024]u8 = undefined;
    var reader = stream.reader(s.io, &rbuf);
    var writer = stream.writer(s.io, &wbuf);
    var srv = std.http.Server.init(&reader.interface, &writer.interface);
    var req = srv.receiveHead() catch return;
    req.respond(s.body, .{}) catch return;
}

test "downloadOnly reports a missing cask digest as its own error, not a mismatch" {
    // Homebrew always emits `sha256` for a cask, so an absent one is a
    // malformed or hostile manifest. Reporting it as Sha256Mismatch sends the
    // user hunting for a corrupted download, and callers treat a mismatch as
    // transient — so a hash-less cask would re-download and fail forever.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();

    var addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    var stub = BodyStub{ .io = io, .listener = &listener, .body = "ARTIFACT BYTES" };
    const t = try std.Thread.spawn(.{}, serveBody, .{&stub});
    // Declared before the listener's, so it runs *after* it: closing the
    // listener unblocks `accept` and lets the thread exit even when the
    // assertion below fails before any request is made.
    defer t.join();
    defer listener.deinit(io);

    var fx = try Fixture.init("sha_missing");
    defer fx.deinit();
    // `downloadOnly` creates `cache/Cask` with a single-level makedir.
    try test_io.cwd().createDirPath(std.Options.debug_io, fx.p("cache"));

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    const json = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"token\":\"nosha\",\"version\":\"1.0\",\"url\":\"http://127.0.0.1:{d}/x.zip\"}}",
        .{port},
    );
    defer testing.allocator.free(json);
    var c = try cask.parseCask(testing.allocator, json);
    defer c.deinit();
    try testing.expect(c.sha256 == null);

    var installer = cask.CaskInstaller.init(io, testEnviron(), testing.allocator, &db, fx.base);
    try testing.expectError(error.Sha256Missing, installer.downloadOnly(&c));
}

test "downloadOnly reports a cleartext origin as its own error, not a download failure" {
    // A cask that opts out of hashing and is served over cleartext is the one
    // case the transport is all that stands behind the artifact. Refusing it
    // as DownloadFailed reads as a network blip and invites a retry that can
    // only fail the same way — the same trap the missing-digest case sets.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();

    var fx = try Fixture.init("cleartext_origin");
    defer fx.deinit();
    try test_io.cwd().createDirPath(std.Options.debug_io, fx.p("cache"));

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    // `.invalid` never resolves, so a guard that failed to fire would surface
    // as a connect error rather than quietly passing this test.
    var c = try cask.parseCask(
        testing.allocator,
        "{\"token\":\"cleartext\",\"version\":\"1.0\"," ++
            "\"url\":\"http://cask.invalid/x.zip\",\"sha256\":\"no_check\"}",
    );
    defer c.deinit();

    var installer = cask.CaskInstaller.init(io, testEnviron(), testing.allocator, &db, fx.base);
    try testing.expectError(error.InsecureOrigin, installer.downloadOnly(&c));
}

test "a failed cask prefetch leaves the installed app and its row intact" {
    // Both upgrade routes now fetch the replacement before they uninstall, so
    // the failure the network hands them has to be a no-op — the old app stays
    // on disk and its row stays in the DB.
    const prefetch_cask_json =
        \\{"token":"prefetch-guard","name":["Prefetch"],"version":"2.0","desc":"","homepage":"",
        \\ "url":"https://example.invalid/prefetch.dmg",
        \\ "sha256":"00000000000000000000000000000000000000000000000000000000deadbeef",
        \\ "auto_updates":false,"artifacts":[{"app":["Prefetch.app"]}]}
    ;
    var c = try cask.parseCask(testing.allocator, prefetch_cask_json);
    defer c.deinit();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    var bundle = try Fixture.init("prefetch_bundle");
    defer bundle.deinit();
    const app_path_z = bundle.p("Prefetch.app");
    try test_io.makeDirAbsolute(std.Options.debug_io, app_path_z);
    try cask.recordInstall(&db, &c, app_path_z, null);

    var fx = try Fixture.init("prefetch_prefix");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    try std.Io.Dir.cwd().createDirPath(io, fx.p("cache"));
    var installer = cask.CaskInstaller.init(io, testEnviron(), testing.allocator, &db, fx.base);
    installer.offline = true; // stands in for the dropped connection, hermetically

    try testing.expectError(cask.CaskError.DownloadFailed, installer.downloadOnly(&c));

    try std.Io.Dir.accessAbsolute(io, app_path_z, .{});
    try testing.expect(cask.isInstalled(&db, "prefetch-guard"));
}

test "an unpinned artefact fetched once survives uninstall and installs from the prefetch" {
    // The `sha256 :no_check` case the cache reuse cannot cover: nothing can
    // revalidate those bytes, so the only way an upgrade survives a failed
    // download is to fetch before destroying, then consume that fetch.
    var fx = try Fixture.init("prefetch_consume");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = testEnviron() });
    defer threaded.deinit();
    const io = threaded.io();

    const cache_dir = fx.p("cache/Cask");
    try std.Io.Dir.cwd().createDirPath(io, cache_dir);
    try std.Io.Dir.cwd().createDirPath(io, fx.p("Applications"));

    const prefetched = fx.p("cache/Cask/rolling-latest.zip");
    {
        const f = try std.Io.Dir.createFileAbsolute(io, prefetched, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "not an archive");
    }

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    var c = try cask.parseCask(testing.allocator,
        \\{"token":"rolling","name":["Rolling"],"version":"latest","url":"https://example.invalid/rolling.zip","sha256":"no_check","artifacts":[{"app":["Rolling.app"]}]}
    );
    defer c.deinit();

    const app_path = fx.p("Applications/Rolling.app");
    try std.Io.Dir.cwd().createDirPath(io, app_path);
    try cask.recordInstall(&db, &c, app_path, null);

    var installer = cask.CaskInstaller.init(io, testEnviron(), testing.allocator, &db, fx.base);
    installer.offline = true; // any re-fetch would fail loudly instead of quietly working
    installer.prefetched_artifact = prefetched;

    // The upgrade's destructive step must leave the fetched bytes behind.
    try installer.uninstall("rolling");
    try std.Io.Dir.accessAbsolute(io, prefetched, .{});

    // InstallFailed (extracting a non-archive), not DownloadFailed: the
    // install consumed the prefetch instead of reaching for the network.
    try testing.expectError(cask.CaskError.InstallFailed, installer.install(&c));
}
