//! malt — cask flight steps integration
//! Drives the declared `*_steps` phases through the installer seams a real
//! install crosses: preflight before the `.app` is placed, postflight after
//! the DB row exists, uninstall steps read back from that row. Avoids ditto
//! and the network by feeding a pre-populated extract dir.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");
const cask = malt.cask;
const sqlite = malt.sqlite;
const schema = malt.schema;

/// Scratch tree under a process-unique base; `home` sits beside the prefix
/// so a step escaping `$HOME/Library` is observable.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    base: [:0]const u8,
    home: [:0]const u8,
    environ: std.process.Environ,

    fn init(tag: []const u8) !Fixture {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const base = try a.dupeZ(u8, try test_io.uniqueTempPath(a, "flight", tag));
        const home = try std.fmt.allocPrintSentinel(a, "{s}_home", .{base}, 0);
        for ([_][]const u8{ base, home }) |dir| {
            test_io.deleteTreeAbsolute(std.Options.debug_io, dir) catch {};
            try test_io.cwd().createDirPath(std.Options.debug_io, dir);
        }
        try test_io.cwd().createDirPath(std.Options.debug_io, try std.fmt.allocPrint(a, "{s}/Library", .{home}));
        const kv = try std.fmt.allocPrintSentinel(a, "HOME={s}", .{home}, 0);
        const block = try a.allocSentinel(?[*:0]const u8, 1, null);
        block[0] = kv.ptr;
        return .{ .arena = arena, .base = base, .home = home, .environ = .{ .block = .{ .slice = block } } };
    }

    fn p(self: *Fixture, sub: []const u8) [:0]const u8 {
        return std.fmt.allocPrintSentinel(self.arena.allocator(), "{s}/{s}", .{ self.base, sub }, 0) catch @panic("OOM");
    }

    fn h(self: *Fixture, sub: []const u8) []const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "{s}/{s}", .{ self.home, sub }) catch @panic("OOM");
    }

    fn deinit(self: *Fixture) void {
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.base) catch {};
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.home) catch {};
        self.arena.deinit();
    }
};

fn putFile(io: std.Io, path: []const u8, body: []const u8) !void {
    if (test_io.path.dirname(path)) |dir| try test_io.cwd().createDirPath(io, dir);
    const f = try test_io.createFileAbsolute(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, body);
}

fn exists(io: std.Io, path: []const u8) bool {
    return if (std.Io.Dir.accessAbsolute(io, path, .{})) |_| true else |_| false;
}

const box_json =
    \\{"token":"box","name":["Box"],"version":"6.0","url":"https://example.invalid/box.zip","sha256":"no_check",
    \\ "artifacts":[
    \\  {"preflight_steps":[{"steps":[{"type":"mkdir_p","path":{"base":"home","path":"Library/Application Support/box/roms"}}]}]},
    \\  {"app":["Box.app"]},
    \\  {"postflight_steps":[{"steps":[{"type":"write","path":{"base":"home","path":"Library/box.conf"},"content":"v={{version.major}}"}]}]},
    \\  {"uninstall_postflight_steps":[{"steps":[{"type":"write","path":{"base":"home","path":"Library/box.gone"},"content":"{{token}}"}]}]}]}
;

test "preflight runs before the app is placed and postflight after the row is written" {
    var fx = try Fixture.init("phases");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = fx.environ });
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var c = try cask.parseCaskWithMajor(testing.allocator, box_json, null);
    defer c.deinit();

    const extract = fx.p("extract");
    try putFile(io, fx.p("extract/Box.app/Contents/MacOS/box"), "bin");
    try test_io.cwd().createDirPath(io, fx.p("Applications"));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var flog = cask.FlightLog.init(testing.allocator);
    defer flog.deinit();
    var installer = cask.CaskInstaller.init(io, fx.environ, testing.allocator, &db, fx.base, fx.p("cache"));
    installer.flight = .{ .log = &flog, .allocator = arena.allocator() };

    const app_path = try installer.placeExtracted(extract, fx.p("Applications"), &c);
    defer testing.allocator.free(app_path);
    try testing.expect(exists(io, fx.h("Library/Application Support/box/roms")));
    try testing.expect(exists(io, fx.p("Applications/Box.app/Contents/MacOS/box")));
    // Postflight has not run yet: the row does not exist.
    try testing.expect(!exists(io, fx.h("Library/box.conf")));

    try cask.recordInstall(&db, &c, app_path, null);
    var stored = (try cask.readFlightSteps(&db, testing.allocator, "box")) orelse return error.TestUnexpectedResult;
    defer stored.deinit();
    try testing.expect(stored.get(.preflight) != null);
    try testing.expect(stored.get(.postflight) != null);
    try testing.expect(stored.get(.uninstall_preflight) == null);
    try testing.expectEqual(@as(usize, 1), stored.get(.uninstall_postflight).?.len);

    try testing.expect(installer.runFlight("box", "6.0", c.flight_steps.get(.postflight).?, null));
    const conf = try test_io.readFileAbsoluteAlloc(io, testing.allocator, fx.h("Library/box.conf"), 64);
    defer testing.allocator.free(conf);
    try testing.expectEqualStrings("v=6", conf);
    try testing.expect(!flog.hasErrors());
}

test "uninstall postflight runs from the stored row and its effect is visible" {
    var fx = try Fixture.init("uninstall");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = fx.environ });
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var c = try cask.parseCaskWithMajor(testing.allocator, box_json, null);
    defer c.deinit();
    const app_path = fx.p("Applications/Box.app");
    try test_io.cwd().createDirPath(io, app_path);
    try cask.recordInstall(&db, &c, app_path, null);

    var stored = (try cask.readFlightSteps(&db, testing.allocator, "box")) orelse return error.TestUnexpectedResult;
    defer stored.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var flog = cask.FlightLog.init(testing.allocator);
    defer flog.deinit();
    var installer = cask.CaskInstaller.init(io, fx.environ, testing.allocator, &db, fx.base, fx.p("cache"));
    installer.flight = .{ .log = &flog, .allocator = arena.allocator() };

    try installer.uninstall("box");
    try testing.expect(!cask.isInstalled(&db, "box"));
    try testing.expect(installer.runFlight("box", "6.0", stored.get(.uninstall_postflight).?, null));
    const gone = try test_io.readFileAbsoluteAlloc(io, testing.allocator, fx.h("Library/box.gone"), 64);
    defer testing.allocator.free(gone);
    try testing.expectEqualStrings("box", gone);
}

test "a preflight that escapes its confinement aborts before the app is placed" {
    var fx = try Fixture.init("abort");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = fx.environ });
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var c = try cask.parseCaskWithMajor(testing.allocator,
        \\{"token":"evil","name":["Evil"],"version":"1","url":"https://example.invalid/evil.zip","sha256":"no_check",
        \\ "artifacts":[{"preflight_steps":[{"steps":[{"type":"write","path":{"base":"home","path":".ssh/config"},"content":"Host *"}]}]},{"app":["Evil.app"]}]}
    , null);
    defer c.deinit();

    const extract = fx.p("extract");
    try putFile(io, fx.p("extract/Evil.app/Contents/MacOS/evil"), "bin");
    try test_io.cwd().createDirPath(io, fx.p("Applications"));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var flog = cask.FlightLog.init(testing.allocator);
    defer flog.deinit();
    var installer = cask.CaskInstaller.init(io, fx.environ, testing.allocator, &db, fx.base, fx.p("cache"));
    installer.flight = .{ .log = &flog, .allocator = arena.allocator() };

    try testing.expectError(cask.CaskError.PreflightFailed, installer.placeExtracted(extract, fx.p("Applications"), &c));
    try testing.expect(flog.hasFatal());
    try testing.expect(!exists(io, fx.h(".ssh/config")));
    try testing.expect(!exists(io, fx.p("Applications/Evil.app")));
    try testing.expect(!exists(io, fx.p("Caskroom/evil")));
    try testing.expect(!cask.isInstalled(&db, "evil"));
}

/// Point the CLI at the fixture prefix; the DB, lock and cache live there.
fn enterPrefix(fx: *Fixture) !void {
    for ([_][]const u8{ "db", "cache/api", "Applications" }) |sub| try test_io.cwd().createDirPath(std.Options.debug_io, fx.p(sub));
    _ = test_io.c.setenv("MALT_PREFIX", fx.base.ptr, 1);
}

test "uninstall aborts before removing anything when the stored preflight fails" {
    var fx = try Fixture.init("cli_uninstall_abort");
    defer fx.deinit();
    try enterPrefix(&fx);
    defer _ = test_io.c.unsetenv("MALT_PREFIX");
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = fx.environ });
    defer threaded.deinit();
    const io = threaded.io();

    const app_path = fx.p("Applications/Evil.app");
    try test_io.cwd().createDirPath(io, app_path);
    {
        var db = try sqlite.Database.open(fx.p("db/malt.db"));
        defer db.close();
        try schema.initSchema(&db);
        var c = try cask.parseCaskWithMajor(testing.allocator,
            \\{"token":"evil","name":["Evil"],"version":"1","url":"https://example.invalid/evil.zip","sha256":"no_check",
            \\ "artifacts":[{"app":["Evil.app"]},
            \\  {"uninstall_preflight_steps":[{"steps":[{"type":"write","path":{"base":"home","path":".ssh/config"},"content":"Host *"}]}]}]}
        , null);
        defer c.deinit();
        try cask.recordInstall(&db, &c, app_path, null);
    }

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = io, .environ = fx.environ };
    try testing.expectError(error.Aborted, malt.cli_uninstall.execute(&ctx, arena.allocator(), &.{"evil"}));

    try testing.expect(std.mem.indexOf(u8, captured.items, "uninstall preflight steps failed for evil") != null);
    try testing.expect(exists(io, app_path));
    try testing.expect(!exists(io, fx.h(".ssh/config")));
    var db = try sqlite.Database.open(fx.p("db/malt.db"));
    defer db.close();
    try testing.expect(cask.isInstalled(&db, "evil"));
}

test "install --dry-run lists the phases and names the steps malt refuses" {
    var fx = try Fixture.init("cli_dry_run");
    defer fx.deinit();
    try enterPrefix(&fx);
    defer _ = test_io.c.unsetenv("MALT_PREFIX");
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = fx.environ });
    defer threaded.deinit();

    // Cached cask JSON is all the dry run needs; offline keeps it honest.
    try putFile(threaded.io(), fx.p("cache/api/cask_plan.json"),
        \\{"token":"plan","name":["Plan"],"version":"2.1","url":"https://example.invalid/plan.zip","sha256":"no_check",
        \\ "artifacts":[{"preflight_steps":[{"steps":[{"type":"mkdir_p","path":{"base":"home","path":"Library/plan"}}]}]},{"app":["Plan.app"]},
        \\  {"postflight_steps":[{"steps":[{"type":"run","command":{"path":"/bin/echo"},"sudo":true},{"type":"terminate_process","name":"p","match":"full"}]}]}]}
    );
    {
        var db = try sqlite.Database.open(fx.p("db/malt.db"));
        defer db.close();
        try schema.initSchema(&db);
    }

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = fx.environ, .offline = true };
    try malt.install.execute(&ctx, arena.allocator(), &.{ "--cask", "--dry-run", "plan" });

    try testing.expect(std.mem.indexOf(u8, captured.items, "would run 1 preflight step(s) for plan") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "would run 2 postflight step(s) for plan") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "unsupported step: run with sudo") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "unsupported step: terminate_process with match") != null);
    try testing.expect(!exists(threaded.io(), fx.h("Library/plan")));
}

fn runTar(argv: []const []const u8) !void {
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{ .environ = malt.app_ctx.processEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var child = try std.process.spawn(io, .{ .argv = argv, .stdout = .ignore, .stderr = .ignore });
    switch (try child.wait(io)) {
        .exited => |code| if (code != 0) return error.TarFailed,
        else => return error.TarFailed,
    }
}

test "a tarball preflight that fails leaves no Caskroom dir behind" {
    // The tarball stage IS the Caskroom version dir, so unlike zip and dmg
    // there is no scratch dir whose defer cleans it up.
    var fx = try Fixture.init("tar_abort");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = fx.environ });
    defer threaded.deinit();
    const io = threaded.io();

    try putFile(io, fx.p("src/tool"), "bin");
    try test_io.cwd().createDirPath(io, fx.p("cache/Cask"));
    try test_io.cwd().createDirPath(io, fx.p("tmp"));
    const tgz = fx.p("cache/Cask/tarcask-1.tar.gz");
    try runTar(&.{ "/usr/bin/tar", "-czf", tgz, "-C", fx.p("src"), "tool" });

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var c = try cask.parseCaskWithMajor(testing.allocator,
        \\{"token":"tarcask","name":["Tar"],"version":"1","url":"https://example.invalid/t.tar.gz","sha256":"no_check",
        \\ "artifacts":[{"preflight_steps":[{"steps":[{"type":"write","path":{"base":"home","path":".ssh/config"},"content":"x"}]}]},{"binary":["tool"]}]}
    , null);
    defer c.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var flog = cask.FlightLog.init(testing.allocator);
    defer flog.deinit();
    var installer = cask.CaskInstaller.init(io, fx.environ, testing.allocator, &db, fx.base, fx.p("cache"));
    installer.offline = true;
    installer.prefetched_artifact = tgz;
    installer.flight = .{ .log = &flog, .allocator = arena.allocator() };

    try testing.expectError(cask.CaskError.PreflightFailed, installer.install(&c));
    try testing.expect(!exists(io, fx.p("Caskroom/tarcask")));
    try testing.expect(!exists(io, fx.p("bin/tool")));
    try testing.expect(!cask.isInstalled(&db, "tarcask"));
}

test "a cask that declares a preflight cannot install through a path with no flight sink" {
    // Every installer site must wire the sink; a silent pass here would let
    // upgrade or a tap install skip the gate the cask declared.
    var fx = try Fixture.init("no_sink");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = fx.environ });
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var c = try cask.parseCaskWithMajor(testing.allocator, box_json, null);
    defer c.deinit();
    try putFile(io, fx.p("extract/Box.app/Contents/MacOS/box"), "bin");
    try test_io.cwd().createDirPath(io, fx.p("Applications"));

    var installer = cask.CaskInstaller.init(io, fx.environ, testing.allocator, &db, fx.base, fx.p("cache"));
    try testing.expectError(cask.CaskError.PreflightFailed, installer.placeExtracted(fx.p("extract"), fx.p("Applications"), &c));
    try testing.expect(!exists(io, fx.p("Applications/Box.app")));
}

test "uninstall warns about a corrupt stored row and still removes the cask" {
    var fx = try Fixture.init("cli_uninstall_corrupt");
    defer fx.deinit();
    try enterPrefix(&fx);
    defer _ = test_io.c.unsetenv("MALT_PREFIX");
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = fx.environ });
    defer threaded.deinit();
    const io = threaded.io();

    const app_path = fx.p("Applications/Bent.app");
    try test_io.cwd().createDirPath(io, app_path);
    {
        var db = try sqlite.Database.open(fx.p("db/malt.db"));
        defer db.close();
        try schema.initSchema(&db);
        var c = try cask.parseCaskWithMajor(testing.allocator,
            \\{"token":"bent","name":["Bent"],"version":"1","url":"https://example.invalid/b.zip","artifacts":[{"app":["Bent.app"]}]}
        , null);
        defer c.deinit();
        try cask.recordInstall(&db, &c, app_path, null);
        try db.exec("UPDATE casks SET flight_steps = '{\"uninstall_preflight_steps\": [' WHERE token = 'bent';");
    }

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = io, .environ = fx.environ };
    try malt.cli_uninstall.execute(&ctx, arena.allocator(), &.{"bent"});

    try testing.expect(std.mem.indexOf(u8, captured.items, "could not read the flight steps stored for bent") != null);
    try testing.expect(!exists(io, app_path));
}

test "a flight phase outcome reaches --ndjson consumers as a post_install event" {
    var flog = malt.dsl.FallbackLog.init(testing.allocator);
    defer flog.deinit();
    flog.log(.{ .formula = "box", .reason = .sandbox_violation, .detail = "/etc/x", .loc = null });

    const prior = malt.output.isNdjson();
    malt.output.setNdjson(true);
    defer malt.output.setNdjson(prior);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    malt.output.beginStdoutCapture(testing.allocator, &out);
    defer malt.output.endStdoutCapture();
    var err: std.ArrayList(u8) = .empty;
    defer err.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &err);
    defer malt.output.endStderrCapture();

    try testing.expect(!malt.install_post_install.routeFlightOutcome(testing.allocator, &flog, "box", "postflight", malt.install_sink.terminal));
    try testing.expect(std.mem.indexOf(u8, out.items, "\"event\":\"post_install\",\"name\":\"box\",\"status\":\"fatal\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"detail\":\"/etc/x\"") != null);
}

test "a rollback keeps the stored flight steps across its row swap" {
    // The synthetic cask a rollback installs declares nothing, and the
    // target version's own steps are not on record, so the row must carry
    // over what the current install stored or the later uninstall runs none.
    var fx = try Fixture.init("rollback");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = fx.environ });
    defer threaded.deinit();
    const io = threaded.io();

    try putFile(io, fx.p("src/Box.app/Contents/MacOS/box"), "bin");
    try test_io.cwd().createDirPath(io, fx.p("cache/Cask"));
    try test_io.cwd().createDirPath(io, fx.p("tmp"));
    try test_io.cwd().createDirPath(io, fx.p("Applications"));
    const zip = fx.p("cache/Cask/box-6.0.zip");
    try runTar(&.{ "/usr/bin/ditto", "-c", "-k", "--keepParent", fx.p("src/Box.app"), zip });

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var c = try cask.parseCaskWithMajor(testing.allocator, box_json, null);
    defer c.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var flog = cask.FlightLog.init(testing.allocator);
    defer flog.deinit();
    var installer = cask.CaskInstaller.init(io, fx.environ, testing.allocator, &db, fx.base, fx.p("cache"));
    installer.offline = true;
    installer.flight = .{ .log = &flog, .allocator = arena.allocator() };

    // 6.0 installs and records its history row; the casks row then moves
    // on to a newer version, as an upgrade does.
    installer.prefetched_artifact = zip;
    const app_path = try installer.install(&c);
    defer testing.allocator.free(app_path);
    try cask.recordInstall(&db, &c, app_path, null);
    try db.exec("UPDATE casks SET version = '7.0' WHERE token = 'box';");

    // rollback's own installer has no sink: the stored steps are recorded,
    // never run, or a cask with a preflight could not be rolled back.
    installer.flight = null;
    try installer.reinstallFromHistory("box", "6.0");

    const info = cask.lookupInstalled(&db, "box") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("6.0", info.version());
    var stored = (try cask.readFlightSteps(&db, testing.allocator, "box")) orelse return error.TestUnexpectedResult;
    defer stored.deinit();
    try testing.expectEqual(@as(usize, 1), stored.get(.uninstall_postflight).?.len);
}

test "a cask without flight steps stores NULL and installs as before" {
    var fx = try Fixture.init("plain");
    defer fx.deinit();
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var c = try cask.parseCaskWithMajor(testing.allocator,
        \\{"token":"plain","name":["Plain"],"version":"1","url":"https://example.invalid/p.zip","artifacts":[{"app":["P.app"]}]}
    , null);
    defer c.deinit();
    try cask.recordInstall(&db, &c, null, null);
    try testing.expect((try cask.readFlightSteps(&db, testing.allocator, "plain")) == null);
}
