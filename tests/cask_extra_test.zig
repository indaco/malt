//! malt — extra cask coverage
//! Covers isAppRunningPub and the CaskInstaller's install/uninstall
//! short-circuit branches that run without network.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const cask = malt.cask;
const sqlite = malt.sqlite;
const schema = malt.schema;

test "isAppRunningPub returns false for a path no pgrep match can cover" {
    // An impossible sentinel path — pgrep will not match, so isAppRunning
    // exits non-zero and the wrapper returns false.
    try testing.expect(!cask.CaskInstaller.isAppRunningPub("/nonexistent/Sentinel-path-never-running.app"));
}

test "CaskInstaller.uninstall on a missing token returns UninstallFailed" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    const prefix: [:0]const u8 = "/tmp/mcask";
    var installer = cask.CaskInstaller.init(testing.allocator, &db, prefix);
    try testing.expectError(cask.CaskError.UninstallFailed, installer.uninstall("nope-nope"));
}

test "CaskInstaller.isOutdated returns false for an unknown token" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    const prefix: [:0]const u8 = "/tmp/mcask2";
    var installer = cask.CaskInstaller.init(testing.allocator, &db, prefix);
    try testing.expect(!installer.isOutdated("nope-nope", "1.0"));
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
    var installer = cask.CaskInstaller.init(testing.allocator, &db, prefix);
    try testing.expectError(cask.CaskError.InstallFailed, installer.install(&c));
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
    const base = "/tmp/malt_cask_uninstall_test";
    std.fs.deleteTreeAbsolute(base) catch {};
    try std.fs.cwd().makePath(base);
    defer std.fs.deleteTreeAbsolute(base) catch {};

    const app_path_z = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/Firefox.app",
        .{base},
        0,
    );
    defer testing.allocator.free(app_path_z);
    try std.fs.makeDirAbsolute(app_path_z);

    try cask.recordInstall(&db, &c, app_path_z);
    try testing.expect(cask.isInstalled(&db, "firefox"));

    const prefix: [:0]const u8 = "/tmp/mc-uninstall";
    std.fs.cwd().makePath(prefix) catch {};
    defer std.fs.deleteTreeAbsolute(prefix) catch {};
    var installer = cask.CaskInstaller.init(testing.allocator, &db, prefix);
    try installer.uninstall("firefox");

    // DB row is gone and the staged "app bundle" has been removed.
    try testing.expect(!cask.isInstalled(&db, "firefox"));
    try testing.expectError(error.FileNotFound, std.fs.openDirAbsolute(app_path_z, .{}));
}
