//! malt — font-cask uninstall integration
//! A font cask records its `.malt-fonts` manifest path as `app_path`. Uninstall
//! must read that manifest and unlink each placed font before wiping the
//! Caskroom — otherwise the glyphs orphan in the Fonts dir. A missing manifest
//! must not abort uninstall. Non-font casks keep the deleteTree(app_path) path.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");
const cask = malt.cask;
const cask_font = malt.cask_font;
const sqlite = malt.sqlite;
const schema = malt.schema;

fn testEnviron() std.process.Environ {
    return malt.app_ctx.processEnviron();
}

fn putFile(io: std.Io, path: []const u8, body: []const u8) !void {
    if (test_io.path.dirname(path)) |dir| try test_io.cwd().createDirPath(io, dir);
    const f = try test_io.createFileAbsolute(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, body);
}

const font_cask_json =
    \\{"token":"font-x","name":["FontX"],"version":"1.0","desc":"","homepage":"",
    \\ "url":"https://example.com/x.zip","sha256":"no_check","auto_updates":false,
    \\ "artifacts":[{"font":["A.ttf"]},{"font":["B.ttf"]}]}
;

fn newInstaller(threaded: *std.Io.Threaded, db: *sqlite.Database, prefix: [:0]const u8) cask.CaskInstaller {
    return cask.CaskInstaller.init(threaded.io(), testEnviron(), testing.allocator, db, prefix);
}

/// Scratch tree under a process-unique base, so overlapping test runs cannot
/// wipe each other's fixtures.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    base: [:0]const u8,

    fn init(tag: []const u8) !Fixture {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const base = try test_io.uniqueTempPath(arena.allocator(), "font_uninstall", tag);
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

test "uninstall unlinks every font listed in the manifest, then drops Caskroom and the DB row" {
    const io = std.Options.debug_io;
    var fx = try Fixture.init("basic");
    defer fx.deinit();
    const prefix = fx.base;

    // Reconstruct the post-install on-disk state without driving a real
    // install: two placed fonts plus the manifest that records them.
    const font_a = fx.p("Fonts/A.ttf");
    const font_b = fx.p("Fonts/B.ttf");
    try putFile(io, font_a, "AAA");
    try putFile(io, font_b, "BBB");
    const manifest_path = fx.p("Caskroom/font-x/1.0/" ++ cask_font.MANIFEST_NAME);
    const manifest_body = try std.fmt.allocPrint(testing.allocator, "{s}\n{s}", .{ font_a, font_b });
    defer testing.allocator.free(manifest_body);
    try cask_font.writeManifest(io, manifest_path, manifest_body);

    var c = try cask.parseCask(testing.allocator, font_cask_json);
    defer c.deinit();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try cask.recordInstall(&db, &c, manifest_path, null);
    try testing.expect(cask.isInstalled(&db, "font-x"));

    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = testEnviron() });
    defer threaded.deinit();
    var installer = newInstaller(&threaded, &db, prefix);

    try installer.uninstall("font-x");

    // Every manifested font is gone, the Caskroom (and the manifest) is wiped,
    // and the DB row is cleared.
    try testing.expectError(error.FileNotFound, test_io.openFileAbsolute(io, font_a, .{}));
    try testing.expectError(error.FileNotFound, test_io.openFileAbsolute(io, font_b, .{}));
    try testing.expectError(error.FileNotFound, test_io.openDirAbsolute(io, fx.p("Caskroom/font-x"), .{}));
    try testing.expect(!cask.isInstalled(&db, "font-x"));
}

test "uninstall removes only manifested fonts and tolerates a stale entry" {
    const io = std.Options.debug_io;
    var fx = try Fixture.init("precise");
    defer fx.deinit();
    const prefix = fx.base;

    const font_a = fx.p("Fonts/A.ttf");
    try putFile(io, font_a, "AAA"); // manifested, present
    try putFile(io, fx.p("Fonts/Keep.ttf"), "KEEP"); // a co-resident font from another cask

    // The manifest also lists a font that was already manually deleted; the
    // stale entry must not abort uninstall, and Keep.ttf (never recorded here)
    // must survive — the manifest is the exact record of what this cask placed.
    const manifest_path = fx.p("Caskroom/font-x/1.0/" ++ cask_font.MANIFEST_NAME);
    const manifest_body = try std.fmt.allocPrint(testing.allocator, "{s}\n{s}", .{ font_a, fx.p("Fonts/Gone.ttf") });
    defer testing.allocator.free(manifest_body);
    try cask_font.writeManifest(io, manifest_path, manifest_body);

    var c = try cask.parseCask(testing.allocator, font_cask_json);
    defer c.deinit();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try cask.recordInstall(&db, &c, manifest_path, null);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = testEnviron() });
    defer threaded.deinit();
    var installer = newInstaller(&threaded, &db, prefix);

    try installer.uninstall("font-x");

    try testing.expectError(error.FileNotFound, test_io.openFileAbsolute(io, font_a, .{}));
    try expectKept(io, fx.p("Fonts/Keep.ttf"), "KEEP");
    try testing.expect(!cask.isInstalled(&db, "font-x"));
}

fn expectKept(io: std.Io, path: []const u8, body: []const u8) !void {
    const got = try test_io.readFileAbsoluteAlloc(io, testing.allocator, path, 4096);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(body, got);
}

test "uninstall survives a missing manifest and still clears the DB row" {
    var fx = try Fixture.init("drift");
    defer fx.deinit();
    const prefix = fx.base;

    // The Caskroom (and its manifest) was manually nuked: app_path points at a
    // manifest that no longer exists. Uninstall must treat this as "nothing to
    // unlink" and still finish cleaning the DB row.
    const manifest_path = fx.p("Caskroom/font-x/1.0/" ++ cask_font.MANIFEST_NAME);

    var c = try cask.parseCask(testing.allocator, font_cask_json);
    defer c.deinit();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try cask.recordInstall(&db, &c, manifest_path, null);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = testEnviron() });
    defer threaded.deinit();
    var installer = newInstaller(&threaded, &db, prefix);

    try installer.uninstall("font-x");
    try testing.expect(!cask.isInstalled(&db, "font-x"));
}
