//! malt — font-cask install integration
//! Drives the post-extraction dispatch seam: a font cask routes to the
//! cask_font leaf (placing files + recording a Caskroom manifest) while a
//! normal app zip stays on the unchanged .app promotion path. Avoids ditto
//! extraction and the network by feeding a pre-populated extract dir.

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

/// Materialize a fixture file (and its parents) inside the extract dir.
fn putFile(io: std.Io, path: []const u8, body: []const u8) !void {
    if (test_io.path.dirname(path)) |dir| try test_io.cwd().createDirPath(io, dir);
    const f = try test_io.createFileAbsolute(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, body);
}

fn expectFileBody(io: std.Io, path: []const u8, body: []const u8) !void {
    const got = try test_io.readFileAbsoluteAlloc(io, testing.allocator, path, 4096);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(body, got);
}

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
        const base = try test_io.uniqueTempPath(arena.allocator(), "font_install", tag);
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

test "placeExtracted routes a font cask: places files and returns the Caskroom manifest path" {
    const io = std.Options.debug_io;
    // Non-default prefix → resolveFontsDir lands in <prefix>/Fonts, isolating
    // the test from the real ~/Library/Fonts.
    var fx = try Fixture.init("basic");
    defer fx.deinit();
    const prefix = fx.base;

    const extract = fx.p("extract");
    try putFile(io, fx.p("extract/ttf/FiraCode-Bold.ttf"), "BOLD");
    try putFile(io, fx.p("extract/HackNerdFont-Regular.ttf"), "HACK");

    const cask_json =
        \\{"token":"font-fira-code","name":["FiraCode"],"version":"6.2","desc":"","homepage":"",
        \\ "url":"https://example.com/FiraCode.zip","sha256":"no_check","auto_updates":false,
        \\ "artifacts":[
        \\   {"font":["ttf/FiraCode-Bold.ttf"],"target":"/$HOME/Library/Fonts/FiraCode-Bold.ttf"},
        \\   {"font":["HackNerdFont-Regular.ttf"]}
        \\ ]}
    ;
    var c = try cask.parseCask(testing.allocator, cask_json);
    defer c.deinit();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = testEnviron() });
    defer threaded.deinit();
    var installer = newInstaller(&threaded, &db, prefix);

    // app_dir is irrelevant on the font path; pass a scratch one.
    const app_path = try installer.placeExtracted(extract, fx.p("Applications"), &c);
    defer testing.allocator.free(app_path);

    // Returns the manifest path under Caskroom/<token>/<version>/.
    try testing.expectEqualStrings(fx.p("Caskroom/font-fira-code/6.2/" ++ cask_font.MANIFEST_NAME), app_path);

    // Both fonts placed by basename into <prefix>/Fonts.
    const fira = fx.p("Fonts/FiraCode-Bold.ttf");
    const hack = fx.p("Fonts/HackNerdFont-Regular.ttf");
    try expectFileBody(io, fira, "BOLD");
    try expectFileBody(io, hack, "HACK");

    // Manifest lists every placed absolute path, newline-joined.
    const manifest_body = try std.fmt.allocPrint(testing.allocator, "{s}\n{s}", .{ fira, hack });
    defer testing.allocator.free(manifest_body);
    try expectFileBody(io, app_path, manifest_body);
}

test "placeExtracted prefers the font branch when a cask carries both app and font artifacts" {
    const io = std.Options.debug_io;
    var fx = try Fixture.init("mixed");
    defer fx.deinit();
    const prefix = fx.base;

    const extract = fx.p("extract");
    try putFile(io, fx.p("extract/A.ttf"), "AAA");

    // A non-empty font stanza must win over a sibling app stanza so a font
    // cask never falls into the .app demand below it.
    const cask_json =
        \\{"token":"mixed","name":["Mixed"],"version":"3.0","desc":"","homepage":"",
        \\ "url":"https://example.com/Mixed.zip","sha256":"no_check","auto_updates":false,
        \\ "artifacts":[{"app":["Mixed.app"]},{"font":["A.ttf"]}]}
    ;
    var c = try cask.parseCask(testing.allocator, cask_json);
    defer c.deinit();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = testEnviron() });
    defer threaded.deinit();
    var installer = newInstaller(&threaded, &db, prefix);

    const app_path = try installer.placeExtracted(extract, fx.p("Applications"), &c);
    defer testing.allocator.free(app_path);

    try testing.expectEqualStrings(fx.p("Caskroom/mixed/3.0/" ++ cask_font.MANIFEST_NAME), app_path);
    try expectFileBody(io, fx.p("Fonts/A.ttf"), "AAA");
}

test "placeExtracted drops a traversal entry and manifests only the safe font" {
    const io = std.Options.debug_io;
    var fx = try Fixture.init("evil");
    defer fx.deinit();
    const prefix = fx.base;

    const extract = fx.p("extract");
    try putFile(io, fx.p("extract/Good.ttf"), "GOOD");
    // A file the cask must never be able to reach via a `..` hop.
    try putFile(io, fx.p("secret"), "SECRET");

    const cask_json =
        \\{"token":"evil","name":["Evil"],"version":"1.0","desc":"","homepage":"",
        \\ "url":"https://example.com/Evil.zip","sha256":"no_check","auto_updates":false,
        \\ "artifacts":[{"font":["../secret"]},{"font":["Good.ttf"]}]}
    ;
    var c = try cask.parseCask(testing.allocator, cask_json);
    defer c.deinit();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = testEnviron() });
    defer threaded.deinit();
    var installer = newInstaller(&threaded, &db, prefix);

    const app_path = try installer.placeExtracted(extract, fx.p("Applications"), &c);
    defer testing.allocator.free(app_path);

    // Only the safe font is placed and recorded; the `..` entry is skipped.
    try expectFileBody(io, app_path, fx.p("Fonts/Good.ttf"));
    try expectFileBody(io, fx.p("Fonts/Good.ttf"), "GOOD");
    try testing.expectError(error.FileNotFound, test_io.openFileAbsolute(io, fx.p("Fonts/secret"), .{}));
}

test "placeExtracted on an all-unsafe font cask places nothing and records an empty manifest" {
    const io = std.Options.debug_io;
    var fx = try Fixture.init("allevil");
    defer fx.deinit();
    const prefix = fx.base;

    const extract = fx.p("extract");
    try putFile(io, fx.p("extract/decoy.ttf"), "DECOY");
    try putFile(io, fx.p("secret"), "SECRET");

    // Every stanza is attacker-crafted: a `..` hop and an absolute path. The
    // worst case must be a no-op, never a traversal or a crash.
    const cask_json =
        \\{"token":"allevil","name":["AllEvil"],"version":"9.9","desc":"","homepage":"",
        \\ "url":"https://example.com/AllEvil.zip","sha256":"no_check","auto_updates":false,
        \\ "artifacts":[{"font":["../secret"]},{"font":["/etc/hosts"]}]}
    ;
    var c = try cask.parseCask(testing.allocator, cask_json);
    defer c.deinit();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = testEnviron() });
    defer threaded.deinit();
    var installer = newInstaller(&threaded, &db, prefix);

    const app_path = try installer.placeExtracted(extract, fx.p("Applications"), &c);
    defer testing.allocator.free(app_path);

    // A manifest is still written (the recorded app_path stays valid) but it
    // lists nothing, and no file escaped into the Fonts dir.
    try expectFileBody(io, app_path, "");
    try testing.expectError(error.FileNotFound, test_io.openFileAbsolute(io, fx.p("Fonts/secret"), .{}));
    try testing.expectError(error.FileNotFound, test_io.openFileAbsolute(io, fx.p("Fonts/hosts"), .{}));
}

test "placeExtracted leaves a normal app zip on the .app path and writes no font manifest" {
    const io = std.Options.debug_io;
    var fx = try Fixture.init("app");
    defer fx.deinit();
    const prefix = fx.base;

    const extract = fx.p("extract");
    const app_dir = fx.p("Applications");
    try putFile(io, fx.p("extract/Foo.app/Contents/Info.plist"), "PLIST");
    try test_io.cwd().createDirPath(io, app_dir);

    const cask_json =
        \\{"token":"foo","name":["Foo"],"version":"1.0","desc":"","homepage":"",
        \\ "url":"https://example.com/Foo.zip","sha256":"no_check","auto_updates":false,
        \\ "artifacts":[{"app":["Foo.app"]}]}
    ;
    var c = try cask.parseCask(testing.allocator, cask_json);
    defer c.deinit();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = testEnviron() });
    defer threaded.deinit();
    var installer = newInstaller(&threaded, &db, prefix);

    const app_path = try installer.placeExtracted(extract, app_dir, &c);
    defer testing.allocator.free(app_path);

    // App branch: returns the promoted bundle path, whose contents are now
    // in place under app_dir.
    try testing.expectEqualStrings(fx.p("Applications/Foo.app"), app_path);
    try expectFileBody(io, fx.p("Applications/Foo.app/Contents/Info.plist"), "PLIST");

    // The font dispatch did not fire: no Caskroom manifest was written.
    try testing.expectError(error.FileNotFound, test_io.openDirAbsolute(io, fx.p("Caskroom"), .{}));
}
