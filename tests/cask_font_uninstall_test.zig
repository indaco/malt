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

test "uninstall unlinks every font listed in the manifest, then drops Caskroom and the DB row" {
    const io = std.Options.debug_io;
    const prefix: [:0]const u8 = "/tmp/malt_font_uninstall_it";
    test_io.deleteTreeAbsolute(io, prefix) catch {};
    defer test_io.deleteTreeAbsolute(io, prefix) catch {};

    // Reconstruct the post-install on-disk state without driving a real
    // install: two placed fonts plus the manifest that records them.
    const fonts = prefix ++ "/Fonts";
    try putFile(io, fonts ++ "/A.ttf", "AAA");
    try putFile(io, fonts ++ "/B.ttf", "BBB");
    const manifest_path = prefix ++ "/Caskroom/font-x/1.0/" ++ cask_font.MANIFEST_NAME;
    try cask_font.writeManifest(io, manifest_path, fonts ++ "/A.ttf\n" ++ fonts ++ "/B.ttf");

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
    try testing.expectError(error.FileNotFound, test_io.openFileAbsolute(io, fonts ++ "/A.ttf", .{}));
    try testing.expectError(error.FileNotFound, test_io.openFileAbsolute(io, fonts ++ "/B.ttf", .{}));
    try testing.expectError(error.FileNotFound, test_io.openDirAbsolute(io, prefix ++ "/Caskroom/font-x", .{}));
    try testing.expect(!cask.isInstalled(&db, "font-x"));
}

test "uninstall survives a missing manifest and still clears the DB row" {
    const io = std.Options.debug_io;
    const prefix: [:0]const u8 = "/tmp/malt_font_uninstall_drift_it";
    test_io.deleteTreeAbsolute(io, prefix) catch {};
    defer test_io.deleteTreeAbsolute(io, prefix) catch {};

    // The Caskroom (and its manifest) was manually nuked: app_path points at a
    // manifest that no longer exists. Uninstall must treat this as "nothing to
    // unlink" and still finish cleaning the DB row.
    const manifest_path = prefix ++ "/Caskroom/font-x/1.0/" ++ cask_font.MANIFEST_NAME;

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
