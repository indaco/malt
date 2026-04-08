//! malt — cask module tests
//! Tests for cask JSON parsing, artifact type detection, and DB operations.

const std = @import("std");
const malt = @import("malt");
const cask = malt.cask;
const sqlite = malt.sqlite;
const schema = malt.schema;

// --- artifactTypeFromUrl ---

test "artifactTypeFromUrl detects .dmg" {
    try std.testing.expectEqual(cask.ArtifactType.dmg, cask.artifactTypeFromUrl("https://example.com/App.dmg"));
}

test "artifactTypeFromUrl detects .zip" {
    try std.testing.expectEqual(cask.ArtifactType.zip, cask.artifactTypeFromUrl("https://example.com/App.zip"));
}

test "artifactTypeFromUrl detects .pkg" {
    try std.testing.expectEqual(cask.ArtifactType.pkg, cask.artifactTypeFromUrl("https://example.com/App.pkg"));
}

test "artifactTypeFromUrl handles query params after .dmg" {
    try std.testing.expectEqual(cask.ArtifactType.dmg, cask.artifactTypeFromUrl("https://cdn.example.com/App.dmg?dl=1"));
}

test "artifactTypeFromUrl handles query params after .zip" {
    try std.testing.expectEqual(cask.ArtifactType.zip, cask.artifactTypeFromUrl("https://cdn.example.com/App.zip?dl=1"));
}

test "artifactTypeFromUrl returns unknown for unsupported" {
    try std.testing.expectEqual(cask.ArtifactType.unknown, cask.artifactTypeFromUrl("https://example.com/App.tar.gz"));
}

// --- parseCask ---

const test_cask_json =
    \\{
    \\  "token": "firefox",
    \\  "name": ["Firefox"],
    \\  "version": "123.0",
    \\  "desc": "Web browser",
    \\  "homepage": "https://www.mozilla.org/firefox/",
    \\  "url": "https://download.mozilla.org/firefox-123.0.dmg",
    \\  "sha256": "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
    \\  "auto_updates": true,
    \\  "artifacts": [{"app": ["Firefox.app"]}]
    \\}
;

test "parseCask extracts token and version" {
    var c = try cask.parseCask(std.testing.allocator, test_cask_json);
    defer c.deinit();

    try std.testing.expectEqualStrings("firefox", c.token);
    try std.testing.expectEqualStrings("123.0", c.version);
    try std.testing.expectEqualStrings("Firefox", c.name);
    try std.testing.expect(c.auto_updates);
}

test "parseCask extracts url and sha256" {
    var c = try cask.parseCask(std.testing.allocator, test_cask_json);
    defer c.deinit();

    try std.testing.expect(std.mem.endsWith(u8, c.url, ".dmg"));
    try std.testing.expect(c.sha256 != null);
    try std.testing.expectEqual(@as(usize, 64), c.sha256.?.len);
}

test "parseCask rejects invalid JSON" {
    const result = cask.parseCask(std.testing.allocator, "not json");
    try std.testing.expectError(cask.CaskError.ParseFailed, result);
}

test "parseCask rejects missing token" {
    const bad_json =
        \\{"name": ["Foo"], "version": "1.0", "url": "https://x.com/a.dmg"}
    ;
    const result = cask.parseCask(std.testing.allocator, bad_json);
    try std.testing.expectError(cask.CaskError.ParseFailed, result);
}

// --- parseAppName ---

test "parseAppName extracts app from artifacts" {
    var c = try cask.parseCask(std.testing.allocator, test_cask_json);
    defer c.deinit();

    const app_name = cask.parseAppName(c.parsed.value.object);
    try std.testing.expect(app_name != null);
    try std.testing.expectEqualStrings("Firefox.app", app_name.?);
}

test "parseAppName returns null for no artifacts" {
    const json =
        \\{"token": "test", "name": ["T"], "version": "1.0", "url": "https://x.com/a.dmg"}
    ;
    var c = try cask.parseCask(std.testing.allocator, json);
    defer c.deinit();

    const app_name = cask.parseAppName(c.parsed.value.object);
    try std.testing.expect(app_name == null);
}

// --- DB operations ---

fn openTestDb() !sqlite.Database {
    return sqlite.Database.open(":memory:");
}

test "recordInstall and lookupInstalled round-trip" {
    var db = try openTestDb();
    defer db.close();
    try schema.initSchema(&db);

    var c = try cask.parseCask(std.testing.allocator, test_cask_json);
    defer c.deinit();

    try cask.recordInstall(&db, &c, "/Applications/Firefox.app");

    const info = cask.lookupInstalled(&db, "firefox");
    try std.testing.expect(info != null);
    try std.testing.expectEqualStrings("123.0", info.?.version());
    try std.testing.expectEqualStrings("/Applications/Firefox.app", info.?.appPath().?);
}

test "isInstalled returns true after recordInstall" {
    var db = try openTestDb();
    defer db.close();
    try schema.initSchema(&db);

    var c = try cask.parseCask(std.testing.allocator, test_cask_json);
    defer c.deinit();

    try std.testing.expect(!cask.isInstalled(&db, "firefox"));
    try cask.recordInstall(&db, &c, "/Applications/Firefox.app");
    try std.testing.expect(cask.isInstalled(&db, "firefox"));
}

test "removeRecord removes cask from DB" {
    var db = try openTestDb();
    defer db.close();
    try schema.initSchema(&db);

    var c = try cask.parseCask(std.testing.allocator, test_cask_json);
    defer c.deinit();

    try cask.recordInstall(&db, &c, "/Applications/Firefox.app");
    try std.testing.expect(cask.isInstalled(&db, "firefox"));

    try cask.removeRecord(&db, "firefox");
    try std.testing.expect(!cask.isInstalled(&db, "firefox"));
}

// --- CaskInstaller.isOutdated ---

test "isOutdated detects version mismatch" {
    var db = try openTestDb();
    defer db.close();
    try schema.initSchema(&db);

    var c = try cask.parseCask(std.testing.allocator, test_cask_json);
    defer c.deinit();

    try cask.recordInstall(&db, &c, "/Applications/Firefox.app");

    const prefix: [:0]const u8 = "/tmp/malt_test";
    var installer = cask.CaskInstaller.init(std.testing.allocator, &db, prefix);

    try std.testing.expect(installer.isOutdated("firefox", "124.0"));
    try std.testing.expect(!installer.isOutdated("firefox", "123.0"));
}
