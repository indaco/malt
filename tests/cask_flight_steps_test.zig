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

/// Counts the human lines a phase reports, by level.
const Capture = struct {
    warns: usize = 0,
    errs: usize = 0,

    fn sink(self: *Capture) malt.install_sink.OutputSink {
        return .{ .ctx = self, .writeInfo = swallow, .writeWarn = warn, .writeSuccess = swallow, .writeErr = err, .show_progress = false };
    }
    fn warn(ctx: ?*anyopaque, _: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(ctx.?));
        self.warns += 1;
    }
    fn err(ctx: ?*anyopaque, _: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(ctx.?));
        self.errs += 1;
    }
    fn swallow(_: ?*anyopaque, _: []const u8) void {}
};

/// The link itself, not what it points at: `exists` follows it.
fn linkExists(io: std.Io, path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    return if (std.Io.Dir.readLinkAbsolute(io, path, &buf)) |_| true else |_| false;
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

test "an install that fails before staging reports no preflight" {
    // The caller routes the preflight only when it ran: a cask that declares
    // one but never downloaded has no phase to report, and an empty log
    // would read as a completed one.
    var fx = try Fixture.init("no_preflight");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = fx.environ });
    defer threaded.deinit();
    const io = threaded.io();

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
    installer.flight = .{ .log = &flog, .allocator = arena.allocator() };
    installer.offline = true;

    try testing.expectError(error.DownloadFailed, installer.install(&c));
    try testing.expect(!installer.preflight_ran);
    try testing.expect(!exists(io, fx.h("Library/Application Support/box/roms")));
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

test "uninstall --force removes the cask past a stored preflight that cannot pass" {
    // The steps are frozen at install time: a preflight that fails forever
    // would otherwise wedge the cask with no CLI way out.
    var fx = try Fixture.init("cli_uninstall_force");
    defer fx.deinit();
    try enterPrefix(&fx);
    defer _ = test_io.c.unsetenv("MALT_PREFIX");
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = fx.environ });
    defer threaded.deinit();
    const io = threaded.io();

    const app_path = fx.p("Applications/Stuck.app");
    try test_io.cwd().createDirPath(io, app_path);
    {
        var db = try sqlite.Database.open(fx.p("db/malt.db"));
        defer db.close();
        try schema.initSchema(&db);
        var c = try cask.parseCaskWithMajor(testing.allocator,
            \\{"token":"stuck","name":["Stuck"],"version":"1","url":"https://example.invalid/stuck.zip","sha256":"no_check",
            \\ "artifacts":[{"app":["Stuck.app"]},
            \\  {"uninstall_preflight_steps":[{"steps":[{"type":"run","command":{"base":"staged_path","path":"uninstall.sh"}}]}]}]}
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
    try testing.expectError(error.Aborted, malt.cli_uninstall.execute(&ctx, arena.allocator(), &.{"stuck"}));
    try testing.expect(exists(io, app_path));

    try malt.cli_uninstall.execute(&ctx, arena.allocator(), &.{ "stuck", "--force" });
    try testing.expect(std.mem.indexOf(u8, captured.items, "--force: removing stuck") != null);
    try testing.expect(!exists(io, app_path));
    var db = try sqlite.Database.open(fx.p("db/malt.db"));
    defer db.close();
    try testing.expect(!cask.isInstalled(&db, "stuck"));
}

/// A digest-pinned zip of `Box.app` at `<cache>/Cask/box-<ver>.zip`; the
/// installer reuses it without a network round trip.
fn seedBoxZip(io: std.Io, fx: *Fixture, version: []const u8) ![]const u8 {
    const a = fx.arena.allocator();
    const src = try std.fmt.allocPrint(a, "src-{s}/Box.app", .{version});
    try putFile(io, fx.p(try std.fmt.allocPrint(a, "{s}/Contents/MacOS/box", .{src})), version);
    const zip = fx.p(try std.fmt.allocPrint(a, "cache/Cask/box-{s}.zip", .{version}));
    try runTar(&.{ "/usr/bin/ditto", "-c", "-k", "--keepParent", fx.p(src), zip });
    const digest = try cask.hashFileSha256(io, zip);
    return try a.dupe(u8, &digest);
}

test "an upgrade whose incoming preflight fails puts the old version back" {
    // The old bundle is gone by the time the new preflight runs, and SQLite
    // cannot roll a directory back, so the upgrade reinstalls it from history.
    var fx = try Fixture.init("cli_upgrade_restore");
    defer fx.deinit();
    try enterPrefix(&fx);
    defer _ = test_io.c.unsetenv("MALT_PREFIX");
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = fx.environ });
    defer threaded.deinit();
    const io = threaded.io();
    const a = fx.arena.allocator();
    try test_io.cwd().createDirPath(io, fx.p("cache/Cask"));
    try test_io.cwd().createDirPath(io, fx.p("tmp"));

    const sha1 = try seedBoxZip(io, &fx, "1.0");
    const sha2 = try seedBoxZip(io, &fx, "2.0");
    const app_path = fx.p("Applications/Box.app");
    try putFile(io, fx.p("Applications/Box.app/Contents/MacOS/box"), "1.0");
    {
        var db = try sqlite.Database.open(fx.p("db/malt.db"));
        defer db.close();
        try schema.initSchema(&db);
        var c1 = try cask.parseCaskWithMajor(testing.allocator, try std.fmt.allocPrint(a,
            \\{{"token":"box","name":["Box"],"version":"1.0","url":"https://example.invalid/box-1.0.zip","sha256":"{s}","artifacts":[{{"app":["Box.app"]}}]}}
        , .{sha1}), null);
        defer c1.deinit();
        try cask.recordInstall(&db, &c1, app_path, null);
        try cask.recordCaskVersion(&db, "box", "1.0", c1.url, c1.sha256, "zip", fx.p("cache/Cask/box-1.0.zip"));
    }
    // The API answer for the new version: its preflight escapes confinement.
    try putFile(io, fx.p("cache/api/cask_box.json"), try std.fmt.allocPrint(a,
        \\{{"token":"box","name":["Box"],"version":"2.0","url":"https://example.invalid/box-2.0.zip","sha256":"{s}",
        \\ "artifacts":[{{"preflight_steps":[{{"steps":[{{"type":"write","path":{{"base":"home","path":".ssh/config"}},"content":"x"}}]}}]}},{{"app":["Box.app"]}}]}}
    , .{sha2}));

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = io, .environ = fx.environ, .offline = true };
    try testing.expectError(error.Aborted, malt.upgrade.execute(&ctx, arena.allocator(), &.{ "--cask", "box" }));

    try testing.expect(std.mem.indexOf(u8, captured.items, "preflight steps failed for box") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "box 1.0 is back in place") != null);
    const body = try test_io.readFileAbsoluteAlloc(io, testing.allocator, fx.p("Applications/Box.app/Contents/MacOS/box"), 16);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("1.0", body);
    try testing.expect(!exists(io, fx.h(".ssh/config")));
    var db = try sqlite.Database.open(fx.p("db/malt.db"));
    defer db.close();
    const info = cask.lookupInstalled(&db, "box") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("1.0", info.version());
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
        \\  {"postflight_steps":[{"steps":[{"type":"run","command":{"path":"/bin/echo"},"sudo":true},{"type":"terminate_process","name":"p","match":"full"},{"type":"run","command":{"path":"/bin/echo"},"network_access":true},
        \\   {"type":"run","command":{"base":"home","path":"Library/plan/hook"}}]}]}]}
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
    try testing.expect(std.mem.indexOf(u8, captured.items, "would run 4 postflight step(s) for plan") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "unsupported step: run with sudo") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "unsupported step: run with network_access") != null);
    // A full-path match is honoured now, so the plan no longer flags it.
    try testing.expect(std.mem.indexOf(u8, captured.items, "terminate_process") == null);
    // The plan lints against the real HOME, as the install will resolve it.
    try testing.expect(std.mem.indexOf(u8, captured.items, "run command base home") == null);
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

test "a tarball that yields neither a binary nor an app leaves no Caskroom dir behind" {
    // Same stage-is-the-Caskroom shape as the preflight case above, but the
    // failure comes after extraction: a rollback of a version whose stanzas
    // are not on record, or a payload without the promised executable.
    var fx = try Fixture.init("tar_no_artifact");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = fx.environ });
    defer threaded.deinit();
    const io = threaded.io();

    try putFile(io, fx.p("src/README"), "no executable here");
    try test_io.cwd().createDirPath(io, fx.p("cache/Cask"));
    try test_io.cwd().createDirPath(io, fx.p("tmp"));
    const tgz = fx.p("cache/Cask/tarcask-1.tar.gz");
    try runTar(&.{ "/usr/bin/tar", "-czf", tgz, "-C", fx.p("src"), "README" });

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var c = try cask.parseCaskWithMajor(testing.allocator,
        \\{"token":"tarcask","name":["Tar"],"version":"1","url":"https://example.invalid/t.tar.gz","sha256":"no_check"}
    , null);
    defer c.deinit();

    var installer = cask.CaskInstaller.init(io, fx.environ, testing.allocator, &db, fx.base, fx.p("cache"));
    installer.offline = true;
    installer.prefetched_artifact = tgz;

    try testing.expectError(cask.CaskError.InstallFailed, installer.install(&c));
    try testing.expect(!exists(io, fx.p("Caskroom/tarcask")));
}

test "a tarball app cask whose declared binary is missing leaves no Caskroom dir behind" {
    // The tarball stage is the Caskroom version dir and stays after the
    // bundle is promoted, so a link failure one frame up must reclaim it.
    var fx = try Fixture.init("tar_appdir_partial");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = fx.environ });
    defer threaded.deinit();
    const io = threaded.io();

    try putFile(io, fx.p("src/Editor.app/Contents/MacOS/editor"), "bin");
    try test_io.cwd().createDirPath(io, fx.p("cache/Cask"));
    try test_io.cwd().createDirPath(io, fx.p("tmp"));
    try test_io.cwd().createDirPath(io, fx.p("Applications"));
    const tgz = fx.p("cache/Cask/editor-1.tar.gz");
    try runTar(&.{ "/usr/bin/tar", "-czf", tgz, "-C", fx.p("src"), "Editor.app" });

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var c = try cask.parseCaskWithMajor(testing.allocator,
        \\{"token":"editor","name":["Editor"],"version":"1","url":"https://example.invalid/e.tar.gz","sha256":"no_check",
        \\ "artifacts":[{"app":["Editor.app"]},{"binary":["$APPDIR/Editor.app/Contents/MacOS/missing"],"target":"missing"}]}
    , null);
    defer c.deinit();

    var installer = cask.CaskInstaller.init(io, fx.environ, testing.allocator, &db, fx.base, fx.p("cache"));
    installer.offline = true;
    installer.prefetched_artifact = tgz;

    try testing.expectError(cask.CaskError.InstallFailed, installer.install(&c));
    try testing.expect(!exists(io, fx.p("Applications/Editor.app")));
    try testing.expect(!exists(io, fx.p("Caskroom/editor")));
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

    try testing.expect(!malt.install_post_install.routeFlightOutcome(testing.allocator, &flog, "box", .uninstall_postflight, malt.install_sink.terminal));
    // The phase key is what tells one upgrade's several events apart.
    try testing.expect(std.mem.indexOf(u8, out.items, "\"event\":\"post_install\",\"name\":\"box\",\"phase\":\"uninstall_postflight\",\"status\":\"fatal\"") != null);
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

test "a phase whose context cannot be built is reported as a failure, not an empty success" {
    var fx = try Fixture.init("ctx_oom");
    defer fx.deinit();
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    var flog = cask.FlightLog.init(testing.allocator);
    defer flog.deinit();
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var installer = cask.CaskInstaller.init(std.Options.debug_io, fx.environ, testing.allocator, &db, fx.base, fx.p("cache"));
    installer.flight = .{ .log = &flog, .allocator = failing.allocator() };
    var c = try cask.parseCaskWithMajor(testing.allocator, box_json, null);
    defer c.deinit();

    try testing.expect(!installer.runFlight("box", "6.0", c.flight_steps.get(.preflight).?, null));
    try testing.expect(flog.hasFatal());
}

test "a preflight step that cannot write aborts the install before the app is placed" {
    if (std.c.geteuid() == 0) return error.SkipZigTest; // root ignores the mode
    var fx = try Fixture.init("pre_eacces");
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

    // A read-only $HOME/Library: the ROM dir the preflight makes cannot land.
    const lib = try std.fmt.allocPrintSentinel(fx.arena.allocator(), "{s}/Library", .{fx.home}, 0);
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(lib, 0o555));
    defer _ = std.c.chmod(lib, 0o755);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var flog = cask.FlightLog.init(testing.allocator);
    defer flog.deinit();
    var installer = cask.CaskInstaller.init(io, fx.environ, testing.allocator, &db, fx.base, fx.p("cache"));
    installer.flight = .{ .log = &flog, .allocator = arena.allocator() };

    try testing.expectError(error.PreflightFailed, installer.placeExtracted(fx.p("extract"), fx.p("Applications"), &c));
    try testing.expect(flog.hasFatal());
    try testing.expect(!exists(io, fx.p("Applications/Box.app")));
}

test "a postflight step that cannot write fails the phase instead of passing its gate" {
    if (std.c.geteuid() == 0) return error.SkipZigTest;
    var fx = try Fixture.init("post_eacces");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = fx.environ });
    defer threaded.deinit();
    const io = threaded.io();
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    var c = try cask.parseCaskWithMajor(testing.allocator, box_json, null);
    defer c.deinit();

    const lib = try std.fmt.allocPrintSentinel(fx.arena.allocator(), "{s}/Library", .{fx.home}, 0);
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(lib, 0o555));
    defer _ = std.c.chmod(lib, 0o755);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var flog = cask.FlightLog.init(testing.allocator);
    defer flog.deinit();
    var installer = cask.CaskInstaller.init(io, fx.environ, testing.allocator, &db, fx.base, fx.p("cache"));
    installer.flight = .{ .log = &flog, .allocator = arena.allocator() };

    try testing.expect(!installer.runFlight("box", "6.0", c.flight_steps.get(.postflight).?, null));
    try testing.expect(flog.hasFatal());
    try testing.expect(!exists(io, fx.h("Library/box.conf")));
}

test "an uninstall link that cannot be removed fails the uninstall phase" {
    if (std.c.geteuid() == 0) return error.SkipZigTest;
    var fx = try Fixture.init("uninst_eacces");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = fx.environ });
    defer threaded.deinit();
    const io = threaded.io();
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    var c = try cask.parseCaskWithMajor(testing.allocator,
        \\{"token":"box","name":["Box"],"version":"6.0","url":"https://example.invalid/box.zip","sha256":"no_check",
        \\ "artifacts":[{"postflight_steps":[{"steps":[{"type":"symlink","source":{"base":"staged_path","path":"libbox.dylib"},
        \\   "target":{"path":"{{HOMEBREW_PREFIX}}/lib/libbox.dylib"},"uninstall":true}]}]}]}
    , null);
    defer c.deinit();

    // The link the postflight placed, in a directory that no longer lets it go.
    try test_io.cwd().createDirPath(io, fx.p("lib"));
    try std.Io.Dir.symLinkAbsolute(io, fx.p("Caskroom/box/6.0/libbox.dylib"), fx.p("lib/libbox.dylib"), .{});
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(fx.p("lib"), 0o555));
    defer _ = std.c.chmod(fx.p("lib"), 0o755);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var flog = cask.FlightLog.init(testing.allocator);
    defer flog.deinit();
    var installer = cask.CaskInstaller.init(io, fx.environ, testing.allocator, &db, fx.base, fx.p("cache"));
    installer.flight = .{ .log = &flog, .allocator = arena.allocator() };

    installer.runFlightUninstall("box", "6.0", c.flight_steps.get(.postflight).?);
    try testing.expect(flog.hasFatal());
    try testing.expect(linkExists(io, fx.p("lib/libbox.dylib")));
}

test "cask uninstall still clears postflight links after a preflight link will not go" {
    if (std.c.geteuid() == 0) return error.SkipZigTest;
    var fx = try Fixture.init("uninst_phases");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = fx.environ });
    defer threaded.deinit();
    const io = threaded.io();
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var c = try cask.parseCaskWithMajor(testing.allocator,
        \\{"token":"box","name":["Box"],"version":"6.0","url":"https://example.invalid/box.zip","sha256":"no_check",
        \\ "artifacts":[{"app":["Box.app"]},
        \\  {"preflight_steps":[{"steps":[{"type":"symlink","source":{"base":"staged_path","path":"liba.dylib"},
        \\   "target":{"path":"{{HOMEBREW_PREFIX}}/lib/ro/liba.dylib"},"uninstall":true}]}]},
        \\  {"postflight_steps":[{"steps":[{"type":"symlink","source":{"base":"staged_path","path":"libb.dylib"},
        \\   "target":{"path":"{{HOMEBREW_PREFIX}}/lib/libb.dylib"},"uninstall":true}]}]}]}
    , null);
    defer c.deinit();
    try cask.recordInstall(&db, &c, fx.p("Applications/Box.app"), null);
    var stored = (try cask.readFlightSteps(&db, testing.allocator, "box")) orelse return error.TestUnexpectedResult;
    defer stored.deinit();

    // Both links as the install left them; the preflight one can no longer go.
    try test_io.cwd().createDirPath(io, fx.p("lib/ro"));
    try std.Io.Dir.symLinkAbsolute(io, fx.p("Caskroom/box/6.0/liba.dylib"), fx.p("lib/ro/liba.dylib"), .{});
    try std.Io.Dir.symLinkAbsolute(io, fx.p("Caskroom/box/6.0/libb.dylib"), fx.p("lib/libb.dylib"), .{});
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(fx.p("lib/ro"), 0o555));
    defer _ = std.c.chmod(fx.p("lib/ro"), 0o755);

    var flight = malt.install_post_install.Flight.init(testing.allocator);
    defer flight.deinit();
    var installer = cask.CaskInstaller.init(io, fx.environ, testing.allocator, &db, fx.base, fx.p("cache"));
    installer.flight = flight.sink();

    var lines: Capture = .{};
    flight.runUninstallMode(&installer, "box", "6.0", &stored, lines.sink());
    try testing.expect(flight.log.hasFatal());
    try testing.expect(linkExists(io, fx.p("lib/ro/liba.dylib")));
    try testing.expect(!linkExists(io, fx.p("lib/libb.dylib")));
    // The cask is gone and the command succeeds: the leftover is a warning,
    // not an error line on an exit-0 run.
    try testing.expectEqual(@as(usize, 0), lines.errs);
    try testing.expect(lines.warns > 0);
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

/// A zip artefact for `token` whose top-level entry is `<App>.app`, placed
/// where an upgrade's prefetch looks first, so the whole flow stays offline.
fn seedZipArtifact(fx: *Fixture, io: std.Io, token: []const u8, version: []const u8, app: []const u8) ![64]u8 {
    const a = fx.arena.allocator();
    const stage = try std.fmt.allocPrint(a, "{s}/stage-{s}/{s}", .{ fx.base, version, app });
    try putFile(io, try std.fmt.allocPrint(a, "{s}/Contents/MacOS/bin", .{stage}), version);
    const zip = try std.fmt.allocPrint(a, "{s}/cache/Cask/{s}-{s}.zip", .{ fx.base, token, version });
    try test_io.cwd().createDirPath(io, fx.p("cache/Cask"));
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/usr/bin/ditto", "-c", "-k", test_io.path.dirname(stage).?, zip },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.ZipFixtureFailed;
    const bytes = try test_io.readFileAbsoluteAlloc(io, testing.allocator, zip, 1 << 20);
    defer testing.allocator.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "upgrade runs the outgoing version's uninstall steps and the new version's postflight" {
    var fx = try Fixture.init("upgrade");
    defer fx.deinit();
    _ = test_io.c.setenv("MALT_PREFIX", fx.base.ptr, 1);
    defer _ = test_io.c.unsetenv("MALT_PREFIX");
    const a = fx.arena.allocator();
    // The appdir is pinned under the fixture so the swap never reaches the
    // real /Applications.
    const appdir = fx.p("Applications");
    const block = try a.allocSentinel(?[*:0]const u8, 2, null);
    block[0] = (try std.fmt.allocPrintSentinel(a, "HOME={s}", .{fx.home}, 0)).ptr;
    block[1] = (try std.fmt.allocPrintSentinel(a, "MALT_APPDIR={s}", .{appdir}, 0)).ptr;
    const environ: std.process.Environ = .{ .block = .{ .slice = block } };
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = environ });
    defer threaded.deinit();
    const io = threaded.io();

    const v1_json =
        \\{"token":"plain","name":["Plain"],"version":"1.0","url":"https://example.invalid/plain-1.0.zip","sha256":"no_check",
        \\ "artifacts":[{"app":["Plain.app"]},
        \\  {"postflight_steps":[{"steps":[{"type":"symlink","source":{"base":"staged_path","path":"libplain.1.0.dylib"},
        \\    "target":{"path":"{{HOMEBREW_PREFIX}}/lib/libplain.1.dylib"},"uninstall":true}]}]},
        \\  {"uninstall_postflight_steps":[{"steps":[{"type":"write","path":{"base":"home","path":"Library/plain.gone"},"content":"{{version}}"}]}]}]}
    ;
    // The installer stages under `<prefix>/tmp`, which `mt` creates at init.
    try test_io.cwd().createDirPath(io, fx.p("tmp"));
    const sha = try seedZipArtifact(&fx, io, "plain", "2.0", "Plain.app");
    const v2_json = try std.fmt.allocPrint(a,
        \\{{"token":"plain","name":["Plain"],"version":"2.0","url":"https://example.invalid/plain-2.0.zip","sha256":"{s}",
        \\ "artifacts":[{{"app":["Plain.app"]}},
        \\  {{"postflight_steps":[{{"steps":[{{"type":"write","path":{{"base":"home","path":"Library/plain.conf"}},"content":"v={{{{version}}}}"}}]}}]}}]}}
    , .{sha});
    try putFile(io, fx.p("cache/api/cask_plain.json"), v2_json);

    // The installed version on disk and in the row, steps stored as install does.
    const old_app = try std.fmt.allocPrint(a, "{s}/Plain.app", .{appdir});
    try putFile(io, try std.fmt.allocPrint(a, "{s}/Contents/MacOS/bin", .{old_app}), "1.0");
    {
        try test_io.cwd().createDirPath(io, fx.p("db"));
        var db = try sqlite.Database.open(fx.p("db/malt.db"));
        defer db.close();
        try schema.initSchema(&db);
        var c1 = try cask.parseCaskWithMajor(testing.allocator, v1_json, null);
        defer c1.deinit();
        try cask.recordInstall(&db, &c1, old_app, null);
        // The link v1's postflight placed, as the install left it.
        try test_io.cwd().createDirPath(io, fx.p("lib"));
        try std.Io.Dir.symLinkAbsolute(io, fx.p("Caskroom/plain/1.0/libplain.1.0.dylib"), fx.p("lib/libplain.1.dylib"), .{});
    }

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    const prior_quiet = malt.output.isQuiet();
    malt.output.setQuiet(false);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer {
        malt.output.endStderrCapture();
        malt.output.setQuiet(prior_quiet);
    }
    const ctx: malt.app_ctx.AppCtx = .{ .io = io, .environ = environ, .offline = true };
    malt.upgrade.execute(&ctx, testing.allocator, &.{ "--cask", "plain" }) catch |e| {
        std.debug.print("{s}\n", .{captured.items});
        return e;
    };

    const gone = try test_io.readFileAbsoluteAlloc(io, testing.allocator, fx.h("Library/plain.gone"), 64);
    defer testing.allocator.free(gone);
    try testing.expectEqualStrings("1.0", gone);
    const conf = try test_io.readFileAbsoluteAlloc(io, testing.allocator, fx.h("Library/plain.conf"), 64);
    defer testing.allocator.free(conf);
    try testing.expectEqualStrings("v=2.0", conf);
    const placed = try test_io.readFileAbsoluteAlloc(io, testing.allocator, try std.fmt.allocPrint(a, "{s}/Contents/MacOS/bin", .{old_app}), 64);
    defer testing.allocator.free(placed);
    try testing.expectEqualStrings("2.0", placed);
    // v1 asked for its link to go with it.
    try testing.expect(!linkExists(io, fx.p("lib/libplain.1.dylib")));
}

test "upgrade refuses a running app before any stored step can act" {
    var fx = try Fixture.init("upgrade_running");
    defer fx.deinit();
    _ = test_io.c.setenv("MALT_PREFIX", fx.base.ptr, 1);
    defer _ = test_io.c.unsetenv("MALT_PREFIX");
    const a = fx.arena.allocator();
    const appdir = fx.p("Applications");
    const block = try a.allocSentinel(?[*:0]const u8, 2, null);
    block[0] = (try std.fmt.allocPrintSentinel(a, "HOME={s}", .{fx.home}, 0)).ptr;
    block[1] = (try std.fmt.allocPrintSentinel(a, "MALT_APPDIR={s}", .{appdir}, 0)).ptr;
    const environ: std.process.Environ = .{ .block = .{ .slice = block } };
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = environ });
    defer threaded.deinit();
    const io = threaded.io();

    const v1_json =
        \\{"token":"live","name":["Live"],"version":"1.0","url":"https://example.invalid/live-1.0.zip","sha256":"no_check",
        \\ "artifacts":[{"app":["Live.app"]},
        \\  {"postflight_steps":[{"steps":[{"type":"symlink","source":{"base":"staged_path","path":"liblive.1.0.dylib"},
        \\    "target":{"path":"{{HOMEBREW_PREFIX}}/lib/liblive.1.dylib"},"uninstall":true}]}]},
        \\  {"uninstall_preflight_steps":[{"steps":[{"type":"write","path":{"base":"home","path":"Library/live.pre"},"content":"ran"}]}]}]}
    ;
    try test_io.cwd().createDirPath(io, fx.p("tmp"));
    const sha = try seedZipArtifact(&fx, io, "live", "2.0", "Live.app");
    try putFile(io, fx.p("cache/api/cask_live.json"), try std.fmt.allocPrint(a,
        \\{{"token":"live","name":["Live"],"version":"2.0","url":"https://example.invalid/live-2.0.zip","sha256":"{s}","artifacts":[{{"app":["Live.app"]}}]}}
    , .{sha}));

    const old_app = try std.fmt.allocPrint(a, "{s}/Live.app", .{appdir});
    const exe = try std.fmt.allocPrint(a, "{s}/Contents/MacOS/live", .{old_app});
    try putFile(io, exe, "");
    {
        try test_io.cwd().createDirPath(io, fx.p("db"));
        var db = try sqlite.Database.open(fx.p("db/malt.db"));
        defer db.close();
        try schema.initSchema(&db);
        var c1 = try cask.parseCaskWithMajor(testing.allocator, v1_json, null);
        defer c1.deinit();
        try cask.recordInstall(&db, &c1, old_app, null);
        try test_io.cwd().createDirPath(io, fx.p("lib"));
        try std.Io.Dir.symLinkAbsolute(io, fx.p("Caskroom/live/1.0/liblive.1.0.dylib"), fx.p("lib/liblive.1.dylib"), .{});
    }

    // What `isAppRunning` sees: a process whose command line names the bundle.
    var child = try std.process.spawn(io, .{ .argv = &.{ "/usr/bin/tail", "-f", exe }, .stdout = .ignore, .stderr = .ignore });
    defer child.kill(io); // kill also reaps

    const prior_quiet = malt.output.isQuiet();
    malt.output.setQuiet(true);
    defer malt.output.setQuiet(prior_quiet);
    const ctx: malt.app_ctx.AppCtx = .{ .io = io, .environ = environ, .offline = true };
    try testing.expectError(error.AppRunning, malt.upgrade.execute(&ctx, testing.allocator, &.{ "--cask", "live" }));

    // Refused before the stored phases: the link and the row are as they were.
    try testing.expect(linkExists(io, fx.p("lib/liblive.1.dylib")));
    try testing.expect(!exists(io, fx.h("Library/live.pre")));
    var db = try sqlite.Database.open(fx.p("db/malt.db"));
    defer db.close();
    try testing.expectEqualStrings("1.0", cask.lookupInstalled(&db, "live").?.version());
}

test "uninstall drops the symlink a postflight placed and declared for removal" {
    var fx = try Fixture.init("uninstall_symlink");
    defer fx.deinit();
    _ = test_io.c.setenv("MALT_PREFIX", fx.base.ptr, 1);
    defer _ = test_io.c.unsetenv("MALT_PREFIX");
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = fx.environ });
    defer threaded.deinit();
    const io = threaded.io();

    const json =
        \\{"token":"box","name":["Box"],"version":"6.0","url":"https://example.invalid/box.zip","sha256":"no_check",
        \\ "artifacts":[{"app":["Box.app"]},
        \\  {"postflight_steps":[{"steps":[
        \\    {"type":"symlink","source":{"base":"staged_path","path":"libbox.6.0.dylib"},"target":{"path":"{{HOMEBREW_PREFIX}}/lib/libbox.6.dylib"},"uninstall":true},
        \\    {"type":"symlink","source":{"base":"staged_path","path":"box"},"target":{"path":"{{HOMEBREW_PREFIX}}/bin/box"}}]}]}]}
    ;
    const app_path = fx.p("Applications/Box.app");
    try putFile(io, fx.p("Applications/Box.app/Contents/MacOS/box"), "bin");
    try putFile(io, fx.p("Caskroom/box/6.0/libbox.6.0.dylib"), "lib");
    {
        try test_io.cwd().createDirPath(io, fx.p("db"));
        var db = try sqlite.Database.open(fx.p("db/malt.db"));
        defer db.close();
        try schema.initSchema(&db);
        var c = try cask.parseCaskWithMajor(testing.allocator, json, null);
        defer c.deinit();
        try cask.recordInstall(&db, &c, app_path, null);

        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var flog = cask.FlightLog.init(testing.allocator);
        defer flog.deinit();
        var installer = cask.CaskInstaller.init(io, fx.environ, testing.allocator, &db, fx.base, fx.p("cache"));
        installer.flight = .{ .log = &flog, .allocator = arena.allocator() };
        try testing.expect(installer.runFlight("box", "6.0", c.flight_steps.get(.postflight).?, null));
    }
    try testing.expect(linkExists(io, fx.p("lib/libbox.6.dylib")));

    const ctx: malt.app_ctx.AppCtx = .{ .io = io, .environ = fx.environ, .offline = true };
    try malt.cli_uninstall.execute(&ctx, testing.allocator, &.{ "--cask", "box" });

    try testing.expect(!exists(io, app_path));
    try testing.expect(!linkExists(io, fx.p("lib/libbox.6.dylib")));
    // Declared without `uninstall`: upstream leaves it, so does malt.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = try std.Io.Dir.readLinkAbsolute(io, fx.p("bin/box"), &buf);
}

// --- routed tap-cask upgrade over a loopback forge ---------------------------

const net = std.Io.net;
const head_sha = "0123456789abcdef0123456789abcdef01234567";

/// A gitea-shaped forge on loopback: answers the HEAD probe and serves one
/// cask `.rb`; anything else 404s. Runs until a connection carrying no
/// request (the test's knock) tells it the client is done.
const Forge = struct {
    io: std.Io,
    listener: *net.Server,
    rb: []const u8,

    fn serve(f: *Forge) void {
        while (true) {
            const stream = f.listener.accept(f.io) catch return;
            defer stream.close(f.io);
            var rbuf: [16 * 1024]u8 = undefined;
            var wbuf: [16 * 1024]u8 = undefined;
            var reader = stream.reader(f.io, &rbuf);
            var writer = stream.writer(f.io, &wbuf);
            var srv = std.http.Server.init(&reader.interface, &writer.interface);
            // A connection carrying no request is the knock: the test is done.
            var req = srv.receiveHead() catch return;
            const target = req.head.target;
            // One request per connection: an idle kept-alive one would park
            // this single-threaded server and stall the next client's dial.
            if (std.mem.indexOf(u8, target, "/api/v1/repos/grp/tap/commits") != null) {
                req.respond("[{\"sha\":\"" ++ head_sha ++ "\"}]", .{ .keep_alive = false }) catch {};
            } else if (std.mem.endsWith(u8, target, "/Casks/plain.rb")) {
                req.respond(f.rb, .{ .keep_alive = false }) catch {};
            } else {
                req.respond("", .{ .status = .not_found, .keep_alive = false }) catch {};
            }
        }
    }

    fn knock(io: std.Io, port: u16) void {
        var addr = net.IpAddress.parseIp4("127.0.0.1", port) catch return;
        const s = addr.connect(io, .{ .mode = .stream }) catch return;
        s.close(io);
    }
};

/// The pieces every routed-upgrade test shares: a prefix whose appdir is
/// pinned inside it, a loopback forge, a tap row aimed at it, and `plain`
/// 1.0 installed from that tap with its flight steps stored.
const TapUpgradeRig = struct {
    fx: Fixture,
    threaded: std.Io.Threaded,
    environ: std.process.Environ,
    listener: net.Server,
    forge: Forge,
    thread: std.Thread,
    port: u16,

    fn init(tag: []const u8, comptime rb_fmt: []const u8, zip_app: []const u8) !*TapUpgradeRig {
        const rig = try testing.allocator.create(TapUpgradeRig);
        errdefer testing.allocator.destroy(rig);
        rig.fx = try Fixture.init(tag);
        const a = rig.fx.arena.allocator();
        const appdir = rig.fx.p("Applications");
        const block = try a.allocSentinel(?[*:0]const u8, 2, null);
        block[0] = (try std.fmt.allocPrintSentinel(a, "HOME={s}", .{rig.fx.home}, 0)).ptr;
        block[1] = (try std.fmt.allocPrintSentinel(a, "MALT_APPDIR={s}", .{appdir}, 0)).ptr;
        rig.environ = .{ .block = .{ .slice = block } };
        rig.threaded = .init(testing.allocator, .{ .environ = rig.environ });
        const io_ = rig.threaded.io();

        var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
        rig.listener = try addr.listen(io_, .{ .reuse_address = true });
        rig.port = rig.listener.socket.address.getPort();

        // The 2.0 artefact is digest-pinned and already cached, so the
        // forge never has to serve bytes and the prefetch is a cache hit.
        try test_io.cwd().createDirPath(io_, rig.fx.p("tmp"));
        const sha = try seedZipArtifact(&rig.fx, io_, "plain", "2.0", zip_app);
        rig.forge = .{ .io = io_, .listener = &rig.listener, .rb = try std.fmt.allocPrint(a, rb_fmt, .{sha}) };
        rig.thread = try std.Thread.spawn(.{}, Forge.serve, .{&rig.forge});

        const v1_json =
            \\{"token":"plain","name":["Plain"],"version":"1.0","url":"https://example.invalid/plain-1.0.zip","sha256":"no_check",
            \\ "artifacts":[{"app":["Plain.app"]},
            \\  {"postflight_steps":[{"steps":[{"type":"symlink","source":{"base":"staged_path","path":"libplain.1.0.dylib"},
            \\    "target":{"path":"{{HOMEBREW_PREFIX}}/lib/libplain.1.dylib"},"uninstall":true}]}]},
            \\  {"uninstall_postflight_steps":[{"steps":[{"type":"write","path":{"base":"home","path":"Library/plain.gone"},"content":"{{version}}"}]}]}]}
        ;
        const old_app = try std.fmt.allocPrint(a, "{s}/Plain.app", .{appdir});
        try putFile(io_, try std.fmt.allocPrint(a, "{s}/Contents/MacOS/bin", .{old_app}), "1.0");
        try test_io.cwd().createDirPath(io_, rig.fx.p("db"));
        var db = try sqlite.Database.open(rig.fx.p("db/malt.db"));
        defer db.close();
        try schema.initSchema(&db);
        const host = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{rig.port});
        try malt.tap.addWithForge(&db, "grp/tap", "grp", "tap", host, .gitea, head_sha);
        var c1 = try cask.parseCaskWithMajor(testing.allocator, v1_json, null);
        defer c1.deinit();
        try cask.recordInstall(&db, &c1, old_app, "grp/tap");
        try test_io.cwd().createDirPath(io_, rig.fx.p("lib"));
        try std.Io.Dir.symLinkAbsolute(io_, rig.fx.p("Caskroom/plain/1.0/libplain.1.0.dylib"), rig.fx.p("lib/libplain.1.dylib"), .{});
        return rig;
    }

    fn io(rig: *TapUpgradeRig) std.Io {
        return rig.threaded.io();
    }

    fn deinit(rig: *TapUpgradeRig) void {
        Forge.knock(rig.io(), rig.port);
        rig.thread.join();
        rig.listener.deinit(rig.io());
        rig.threaded.deinit();
        rig.fx.deinit();
        testing.allocator.destroy(rig);
    }
};

// The artefact is digest-pinned and pre-cached, so its URL is never dialled.
const plain_rb =
    \\cask "plain" do
    \\  version "2.0"
    \\  sha256 "{s}"
    \\  url "https://example.invalid/plain-2.0.zip"
    \\  app "Plain.app"
    \\end
;

test "a tap-routed upgrade runs the outgoing version's stored steps around the swap" {
    const rig = try TapUpgradeRig.init("tap_upgrade", plain_rb, "Plain.app");
    defer rig.deinit();
    const io = rig.io();
    var fx = &rig.fx;
    _ = test_io.c.setenv("MALT_PREFIX", fx.base.ptr, 1);
    defer _ = test_io.c.unsetenv("MALT_PREFIX");

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    const prior_quiet = malt.output.isQuiet();
    malt.output.setQuiet(false);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer {
        malt.output.endStderrCapture();
        malt.output.setQuiet(prior_quiet);
    }
    const ctx: malt.app_ctx.AppCtx = .{ .io = io, .environ = rig.environ, .offline = false };
    malt.upgrade.execute(&ctx, testing.allocator, &.{ "--cask", "plain" }) catch |e| {
        std.debug.print("{s}\n", .{captured.items});
        return e;
    };

    const gone = try test_io.readFileAbsoluteAlloc(io, testing.allocator, fx.h("Library/plain.gone"), 64);
    defer testing.allocator.free(gone);
    try testing.expectEqualStrings("1.0", gone);
    try testing.expect(!linkExists(io, fx.p("lib/libplain.1.dylib")));
    const placed = try test_io.readFileAbsoluteAlloc(io, testing.allocator, fx.p("Applications/Plain.app/Contents/MacOS/bin"), 64);
    defer testing.allocator.free(placed);
    try testing.expectEqualStrings("2.0", placed);
    var db = try sqlite.Database.open(fx.p("db/malt.db"));
    defer db.close();
    const row = cask.lookupInstalled(&db, "plain").?;
    try testing.expectEqualStrings("2.0", row.version());
    try testing.expectEqualStrings("grp/tap", row.tap().?);
}

test "a tap-routed upgrade whose install fails puts the old version back" {
    // The 2.0 payload names the wrong bundle, so placement fails after the
    // old version is already gone.
    const rig = try TapUpgradeRig.init("tap_upgrade_restore", plain_rb, "Other.app");
    defer rig.deinit();
    const io = rig.io();
    var fx = &rig.fx;
    _ = test_io.c.setenv("MALT_PREFIX", fx.base.ptr, 1);
    defer _ = test_io.c.unsetenv("MALT_PREFIX");

    // What a real 1.0 install leaves behind for a restore: its history row
    // and its digest-pinned artefact in the cache.
    const sha1 = try seedZipArtifact(fx, io, "plain", "1.0", "Plain.app");
    {
        var db = try sqlite.Database.open(fx.p("db/malt.db"));
        defer db.close();
        try cask.recordCaskVersion(&db, "plain", "1.0", "https://example.invalid/plain-1.0.zip", &sha1, "zip", fx.p("cache/Cask/plain-1.0.zip"));
    }

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    const prior_quiet = malt.output.isQuiet();
    malt.output.setQuiet(false);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer {
        malt.output.endStderrCapture();
        malt.output.setQuiet(prior_quiet);
    }
    const ctx: malt.app_ctx.AppCtx = .{ .io = io, .environ = rig.environ, .offline = false };
    const outcome = blk: {
        // ditto reports the missing bundle on the inherited stderr; park
        // fd 2 on /dev/null only for the call so the runner's output stays
        // clean and the assert below still speaks.
        const saved = std.c.dup(std.posix.STDERR_FILENO);
        if (saved < 0) return error.Unexpected;
        defer _ = std.c.close(saved);
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY });
        if (devnull < 0) return error.Unexpected;
        defer _ = std.c.close(devnull);
        if (std.c.dup2(devnull, std.posix.STDERR_FILENO) < 0) return error.Unexpected;
        defer _ = std.c.dup2(saved, std.posix.STDERR_FILENO);
        break :blk malt.upgrade.execute(&ctx, testing.allocator, &.{ "--cask", "plain" });
    };
    try testing.expectError(error.Aborted, outcome);
    try testing.expect(std.mem.indexOf(u8, captured.items, "plain 1.0 is back in place") != null);

    const bin = try test_io.readFileAbsoluteAlloc(io, testing.allocator, fx.p("Applications/Plain.app/Contents/MacOS/bin"), 64);
    defer testing.allocator.free(bin);
    try testing.expectEqualStrings("1.0", bin);
    var db = try sqlite.Database.open(fx.p("db/malt.db"));
    defer db.close();
    const row = cask.lookupInstalled(&db, "plain").?;
    try testing.expectEqualStrings("1.0", row.version());
    try testing.expectEqualStrings("grp/tap", row.tap().?);
}

test "uninstall --force still refuses a running app before any stored step acts" {
    var fx = try Fixture.init("uninstall_force_running");
    defer fx.deinit();
    _ = test_io.c.setenv("MALT_PREFIX", fx.base.ptr, 1);
    defer _ = test_io.c.unsetenv("MALT_PREFIX");
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = fx.environ });
    defer threaded.deinit();
    const io = threaded.io();

    const json =
        \\{"token":"live","name":["Live"],"version":"1.0","url":"https://example.invalid/live.zip","sha256":"no_check",
        \\ "artifacts":[{"app":["Live.app"]},
        \\  {"postflight_steps":[{"steps":[{"type":"symlink","source":{"base":"staged_path","path":"liblive.1.0.dylib"},
        \\    "target":{"path":"{{HOMEBREW_PREFIX}}/lib/liblive.1.dylib"},"uninstall":true}]}]},
        \\  {"uninstall_preflight_steps":[{"steps":[{"type":"write","path":{"base":"home","path":"Library/live.pre"},"content":"ran"}]}]}]}
    ;
    const app_path = fx.p("Applications/Live.app");
    const exe = fx.p("Applications/Live.app/Contents/MacOS/live");
    try putFile(io, exe, "");
    {
        try test_io.cwd().createDirPath(io, fx.p("db"));
        var db = try sqlite.Database.open(fx.p("db/malt.db"));
        defer db.close();
        try schema.initSchema(&db);
        var c = try cask.parseCaskWithMajor(testing.allocator, json, null);
        defer c.deinit();
        try cask.recordInstall(&db, &c, app_path, null);
        try test_io.cwd().createDirPath(io, fx.p("lib"));
        try std.Io.Dir.symLinkAbsolute(io, fx.p("Caskroom/live/1.0/liblive.1.0.dylib"), fx.p("lib/liblive.1.dylib"), .{});
    }
    var child = try std.process.spawn(io, .{ .argv = &.{ "/usr/bin/tail", "-f", exe }, .stdout = .ignore, .stderr = .ignore });
    defer child.kill(io); // kill also reaps

    const prior_quiet = malt.output.isQuiet();
    malt.output.setQuiet(true);
    defer malt.output.setQuiet(prior_quiet);
    const ctx: malt.app_ctx.AppCtx = .{ .io = io, .environ = fx.environ, .offline = true };
    // `--force` overrides dependents; it never removed a live app, and now
    // it does not run the stored phases on one either.
    try testing.expectError(error.Aborted, malt.cli_uninstall.execute(&ctx, testing.allocator, &.{ "--cask", "--force", "live" }));

    try testing.expect(linkExists(io, fx.p("lib/liblive.1.dylib")));
    try testing.expect(!exists(io, fx.h("Library/live.pre")));
    try testing.expect(exists(io, exe));
    var db = try sqlite.Database.open(fx.p("db/malt.db"));
    defer db.close();
    try testing.expect(cask.isInstalled(&db, "live"));
}

test "rollback runs the outgoing version's uninstall steps and drops its declared symlink" {
    var fx = try Fixture.init("rollback_phases");
    defer fx.deinit();
    _ = test_io.c.setenv("MALT_PREFIX", fx.base.ptr, 1);
    defer _ = test_io.c.unsetenv("MALT_PREFIX");
    const a = fx.arena.allocator();
    const appdir = fx.p("Applications");
    const block = try a.allocSentinel(?[*:0]const u8, 2, null);
    block[0] = (try std.fmt.allocPrintSentinel(a, "HOME={s}", .{fx.home}, 0)).ptr;
    block[1] = (try std.fmt.allocPrintSentinel(a, "MALT_APPDIR={s}", .{appdir}, 0)).ptr;
    const environ: std.process.Environ = .{ .block = .{ .slice = block } };
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = environ });
    defer threaded.deinit();
    const io = threaded.io();

    // 2.0 is installed with steps on record; 1.0 is in history with its
    // artefact cached, which is all a rollback needs.
    try test_io.cwd().createDirPath(io, fx.p("tmp"));
    const sha1 = try seedZipArtifact(&fx, io, "plain", "1.0", "Plain.app");
    const v2_json =
        \\{"token":"plain","name":["Plain"],"version":"2.0","url":"https://example.invalid/plain-2.0.zip","sha256":"no_check",
        \\ "artifacts":[{"app":["Plain.app"]},
        \\  {"postflight_steps":[{"steps":[{"type":"symlink","source":{"base":"staged_path","path":"libplain.{{version}}.dylib"},
        \\    "target":{"path":"{{HOMEBREW_PREFIX}}/lib/libplain.dylib"},"uninstall":true}]}]},
        \\  {"uninstall_postflight_steps":[{"steps":[{"type":"write","path":{"base":"home","path":"Library/plain.gone"},"content":"{{version}}"}]}]}]}
    ;
    const app = try std.fmt.allocPrint(a, "{s}/Plain.app", .{appdir});
    try putFile(io, try std.fmt.allocPrint(a, "{s}/Contents/MacOS/bin", .{app}), "2.0");
    {
        try test_io.cwd().createDirPath(io, fx.p("db"));
        var db = try sqlite.Database.open(fx.p("db/malt.db"));
        defer db.close();
        try schema.initSchema(&db);
        var c2 = try cask.parseCaskWithMajor(testing.allocator, v2_json, null);
        defer c2.deinit();
        try cask.recordInstall(&db, &c2, app, null);
        try cask.recordCaskVersion(&db, "plain", "1.0", "https://example.invalid/plain-1.0.zip", &sha1, "zip", fx.p("cache/Cask/plain-1.0.zip"));
        // The link 2.0's postflight placed, as the install left it.
        try test_io.cwd().createDirPath(io, fx.p("lib"));
        try std.Io.Dir.symLinkAbsolute(io, fx.p("Caskroom/plain/2.0/libplain.2.0.dylib"), fx.p("lib/libplain.dylib"), .{});
    }

    const prior_quiet = malt.output.isQuiet();
    malt.output.setQuiet(true);
    defer malt.output.setQuiet(prior_quiet);
    const ctx: malt.app_ctx.AppCtx = .{ .io = io, .environ = environ, .offline = true };
    try malt.cli_rollback.execute(&ctx, testing.allocator, &.{ "plain", "--to", "1.0" });

    // A later uninstall would expand the source with 1.0 and never match
    // this link, so it has to go now, while 2.0 is the version leaving.
    try testing.expect(!linkExists(io, fx.p("lib/libplain.dylib")));
    const gone = try test_io.readFileAbsoluteAlloc(io, testing.allocator, fx.h("Library/plain.gone"), 64);
    defer testing.allocator.free(gone);
    try testing.expectEqualStrings("2.0", gone);
    const bin = try test_io.readFileAbsoluteAlloc(io, testing.allocator, try std.fmt.allocPrint(a, "{s}/Contents/MacOS/bin", .{app}), 64);
    defer testing.allocator.free(bin);
    try testing.expectEqualStrings("1.0", bin);
    var db = try sqlite.Database.open(fx.p("db/malt.db"));
    defer db.close();
    try testing.expectEqualStrings("1.0", cask.lookupInstalled(&db, "plain").?.version());
}
