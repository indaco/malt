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
