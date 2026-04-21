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

// ─── hashFileSha256 / verifyFileSha256 ───────────────────────────────
//
// A multi-chunk read bug meant any file larger than the 64 KiB read
// buffer got the first chunk re-hashed in place of later chunks,
// producing a wrong digest. Caught on a live cask install where the
// upstream zip was bit-perfect but malt rejected it. These tests
// exercise the chunk loop at every boundary and prove the hash
// output against independently-computed digests.

const testing = std.testing;
const malt_fs = malt.fs_compat;

/// 64 KiB — the internal SHA256 read buffer size. Every boundary
/// case below is expressed relative to this so the tests stay
/// meaningful if the constant ever changes.
const CHUNK: usize = 64 * 1024;

fn tempFilePath(tag: []const u8, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "/tmp/malt_cask_verify_{s}_{d}", .{ tag, malt_fs.nanoTimestamp() });
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    const f = try malt_fs.createFileAbsolute(path, .{});
    defer f.close();
    try f.writeAll(bytes);
}

/// Independent SHA256 of `bytes` as lowercase hex, computed in one
/// pass via `std.crypto` — used to cross-check the chunked impl.
fn referenceHex(bytes: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}

/// Fill `buf` with a predictable, non-repeating byte pattern so every
/// chunk contributes distinct bytes. The old bug only shows up when
/// later chunks differ from the first.
fn fillPattern(buf: []u8) void {
    for (buf, 0..) |*b, i| b.* = @intCast((i *% 131 +% 7) & 0xFF);
}

fn hashTempFile(alloc: std.mem.Allocator, tag: []const u8, size: usize) !void {
    const payload = try alloc.alloc(u8, size);
    defer alloc.free(payload);
    fillPattern(payload);

    var path_buf: [128]u8 = undefined;
    const p = try tempFilePath(tag, &path_buf);
    try writeFile(p, payload);
    defer malt_fs.cwd().deleteFile(p) catch {};

    const got = try cask.hashFileSha256(p);
    const want = referenceHex(payload);
    try testing.expectEqualSlices(u8, &want, &got);
}

// ── hashFileSha256: exercises the chunk-boundary matrix ──────────────

test "hashFileSha256 matches reference for an empty file" {
    var path_buf: [128]u8 = undefined;
    const p = try tempFilePath("empty", &path_buf);
    try writeFile(p, "");
    defer malt_fs.cwd().deleteFile(p) catch {};

    const got = try cask.hashFileSha256(p);
    // SHA256 of empty input.
    try testing.expectEqualSlices(
        u8,
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &got,
    );
}

test "hashFileSha256 matches reference for sub-chunk inputs" {
    try hashTempFile(testing.allocator, "sub_1", 1);
    try hashTempFile(testing.allocator, "sub_63", 63);
    try hashTempFile(testing.allocator, "sub_1024", 1024);
}

test "hashFileSha256 matches reference at CHUNK-1" {
    try hashTempFile(testing.allocator, "below", CHUNK - 1);
}

test "hashFileSha256 matches reference at exactly CHUNK" {
    // Precise boundary: the loop does one full read then a short-read
    // EOF check. If the loop ever double-read the first chunk this
    // would be the smallest failing size.
    try hashTempFile(testing.allocator, "eq", CHUNK);
}

test "hashFileSha256 matches reference at CHUNK+1 (straddles the boundary)" {
    try hashTempFile(testing.allocator, "above", CHUNK + 1);
}

test "hashFileSha256 matches reference across two full chunks" {
    try hashTempFile(testing.allocator, "two", 2 * CHUNK);
}

test "hashFileSha256 matches reference across 2½ chunks (the repro size)" {
    // 160 KiB — mirrors the failing-in-the-wild case: later chunks
    // carry bytes the old loop never actually hashed.
    try hashTempFile(testing.allocator, "repro", CHUNK * 2 + CHUNK / 2);
}

test "hashFileSha256 matches reference on a 1 MiB payload" {
    try hashTempFile(testing.allocator, "mib", 1024 * 1024);
}

test "hashFileSha256 of 'abc' matches the NIST test vector" {
    var path_buf: [128]u8 = undefined;
    const p = try tempFilePath("nist_abc", &path_buf);
    try writeFile(p, "abc");
    defer malt_fs.cwd().deleteFile(p) catch {};

    const got = try cask.hashFileSha256(p);
    try testing.expectEqualSlices(
        u8,
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &got,
    );
}

test "hashFileSha256 propagates FileNotFound for a missing path" {
    try testing.expectError(
        error.FileNotFound,
        cask.hashFileSha256("/tmp/malt_cask_verify_absent_xyzzy.bin"),
    );
}

// ── verifyFileSha256: the pickier public API ─────────────────────────

test "verifyFileSha256 accepts the correct digest on a tiny file" {
    var path_buf: [128]u8 = undefined;
    const p = try tempFilePath("tiny_ok", &path_buf);
    try writeFile(p, "hello");
    defer malt_fs.cwd().deleteFile(p) catch {};

    // `printf 'hello' | shasum -a 256`
    try cask.verifyFileSha256(p, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824");
}

test "verifyFileSha256 rejects a digest with a single flipped bit" {
    // The strictest form of "is our compare byte-exact?" — the only
    // difference from the correct digest is the trailing character.
    var path_buf: [128]u8 = undefined;
    const p = try tempFilePath("flip", &path_buf);
    try writeFile(p, "hello");
    defer malt_fs.cwd().deleteFile(p) catch {};

    try testing.expectError(
        error.Sha256Mismatch,
        cask.verifyFileSha256(p, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9825"),
    );
}

test "verifyFileSha256 rejects an uppercase digest (strict lower-hex)" {
    // Homebrew always emits lowercase. Reject mixed-case so a sloppy
    // copy-paste can never silently succeed with an attacker-tuned hex.
    var path_buf: [128]u8 = undefined;
    const p = try tempFilePath("upper", &path_buf);
    try writeFile(p, "hello");
    defer malt_fs.cwd().deleteFile(p) catch {};

    try testing.expectError(
        error.Sha256Mismatch,
        cask.verifyFileSha256(p, "2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824"),
    );
}

test "verifyFileSha256 rejects a truncated or over-length digest" {
    var path_buf: [128]u8 = undefined;
    const p = try tempFilePath("length", &path_buf);
    try writeFile(p, "hello");
    defer malt_fs.cwd().deleteFile(p) catch {};

    try testing.expectError(error.Sha256Mismatch, cask.verifyFileSha256(p, "2cf2"));
    try testing.expectError(
        error.Sha256Mismatch,
        cask.verifyFileSha256(p, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b98240"),
    );
}

test "verifyFileSha256 skips verification on null or :no_check" {
    // `sha256 :no_check` is Homebrew's opt-out for self-updating
    // installers. Honouring the skip prevents spurious failures on
    // perfectly valid casks.
    var path_buf: [128]u8 = undefined;
    const p = try tempFilePath("skip", &path_buf);
    try writeFile(p, "anything");
    defer malt_fs.cwd().deleteFile(p) catch {};

    try cask.verifyFileSha256(p, null);
    try cask.verifyFileSha256(p, "no_check");
}

test "verifyFileSha256 accepts a correct digest on a >1 MiB file" {
    // Regression guard for the chunked-read bug: the public API must
    // produce the same digest as `openssl dgst -sha256` on arbitrarily
    // large files. Without the fix, every chunk after the first is
    // re-read from offset 0 and the digest comes out wrong.
    const alloc = testing.allocator;
    const size: usize = 1024 * 1024 + 7; // non-power-of-two on purpose
    const payload = try alloc.alloc(u8, size);
    defer alloc.free(payload);
    fillPattern(payload);

    var path_buf: [128]u8 = undefined;
    const p = try tempFilePath("big_ok", &path_buf);
    try writeFile(p, payload);
    defer malt_fs.cwd().deleteFile(p) catch {};

    const expected = referenceHex(payload);
    try cask.verifyFileSha256(p, &expected);
}

test "verifyFileSha256 propagates FileNotFound rather than Sha256Mismatch" {
    // Distinguish I/O failure from hash failure — users hitting a
    // permission error deserve to know, not "your download is
    // corrupt" when nothing was ever read.
    try testing.expectError(
        error.FileNotFound,
        cask.verifyFileSha256("/tmp/malt_cask_verify_missing_xyzzy.bin", "0" ** 64),
    );
}

// ── findAppInDir: owns the returned name past iterator teardown ─────

fn scratchDir(tag: []const u8, buf: []u8) ![]const u8 {
    const p = try std.fmt.bufPrint(buf, "/tmp/malt_cask_findapp_{s}_{d}", .{ tag, malt_fs.nanoTimestamp() });
    try malt_fs.makeDirAbsolute(p);
    return p;
}

test "findAppInDir returns the .app name copied into the caller buffer" {
    // Pins the fall-through contract: when parseAppName finds no
    // artifacts.app, the scan must hand back a name that outlives
    // the directory iterator. Using a caller buffer makes that
    // guarantee explicit.
    var dir_buf: [128]u8 = undefined;
    const dir_path = try scratchDir("ok", &dir_buf);
    defer malt_fs.deleteTreeAbsolute(dir_path) catch {};

    var app_path_buf: [256]u8 = undefined;
    const app_path = try std.fmt.bufPrint(&app_path_buf, "{s}/Foo.app", .{dir_path});
    try malt_fs.makeDirAbsolute(app_path);

    var out: [128]u8 = undefined;
    const name = cask.findAppInDir(dir_path, &out) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Foo.app", name);
    // The slice must be backed by the caller buffer, not iterator memory.
    try testing.expect(@intFromPtr(name.ptr) == @intFromPtr(&out));
}

test "findAppInDir returns null when no .app bundle is present" {
    var dir_buf: [128]u8 = undefined;
    const dir_path = try scratchDir("none", &dir_buf);
    defer malt_fs.deleteTreeAbsolute(dir_path) catch {};

    var readme_buf: [256]u8 = undefined;
    const readme = try std.fmt.bufPrint(&readme_buf, "{s}/README", .{dir_path});
    const f = try malt_fs.createFileAbsolute(readme, .{});
    f.close();

    var out: [64]u8 = undefined;
    try testing.expect(cask.findAppInDir(dir_path, &out) == null);
}

test "findAppInDir returns null when the .app name exceeds the out-buffer" {
    var dir_buf: [128]u8 = undefined;
    const dir_path = try scratchDir("toolong", &dir_buf);
    defer malt_fs.deleteTreeAbsolute(dir_path) catch {};

    var app_path_buf: [256]u8 = undefined;
    const app_path = try std.fmt.bufPrint(
        &app_path_buf,
        "{s}/AReallyLongApplicationBundleName.app",
        .{dir_path},
    );
    try malt_fs.makeDirAbsolute(app_path);

    var out: [8]u8 = undefined; // too small on purpose
    try testing.expect(cask.findAppInDir(dir_path, &out) == null);
}

test "verifyFileSha256 accepts only the exact-byte payload (collision check)" {
    // Two files that differ by a single byte must produce different
    // hashes — the chunk-boundary bug could otherwise let two files
    // share a hash when the diverging byte lived in a "skipped" chunk.
    const alloc = testing.allocator;
    const a = try alloc.alloc(u8, CHUNK + 128);
    defer alloc.free(a);
    fillPattern(a);

    const b = try alloc.alloc(u8, CHUNK + 128);
    defer alloc.free(b);
    fillPattern(b);
    b[CHUNK + 64] +%= 1; // flip one byte past the first chunk boundary

    var ap_buf: [128]u8 = undefined;
    const ap = try tempFilePath("coll_a", &ap_buf);
    try writeFile(ap, a);
    defer malt_fs.cwd().deleteFile(ap) catch {};

    var bp_buf: [128]u8 = undefined;
    const bp = try tempFilePath("coll_b", &bp_buf);
    try writeFile(bp, b);
    defer malt_fs.cwd().deleteFile(bp) catch {};

    const hex_a = referenceHex(a);
    try cask.verifyFileSha256(ap, &hex_a);
    // `a`'s hash must NOT validate `b` — this is exactly the property
    // the old bug could have broken.
    try testing.expectError(error.Sha256Mismatch, cask.verifyFileSha256(bp, &hex_a));
}

// --- T-006b: applicationsDir is prefix-aware ---

test "isDefaultPrefix: matches /opt/malt and /opt/homebrew exactly" {
    try testing.expect(cask.isDefaultPrefix("/opt/malt"));
    try testing.expect(cask.isDefaultPrefix("/opt/homebrew"));
}

test "isDefaultPrefix: tolerates trailing slash" {
    try testing.expect(cask.isDefaultPrefix("/opt/malt/"));
    try testing.expect(cask.isDefaultPrefix("/opt/homebrew/"));
}

test "isDefaultPrefix: rejects sandboxed and unrelated prefixes" {
    try testing.expect(!cask.isDefaultPrefix("/tmp/mt.abc"));
    try testing.expect(!cask.isDefaultPrefix("/usr/local"));
    try testing.expect(!cask.isDefaultPrefix("/opt/maltx"));
    try testing.expect(!cask.isDefaultPrefix(""));
}

test "resolveAppDir: MALT_APPDIR env override wins regardless of prefix" {
    var buf: [128]u8 = undefined;
    const got = cask.resolveAppDir("/tmp/mt.abc", "/custom/Apps", "/Users/me", true, &buf);
    try testing.expectEqualStrings("/custom/Apps", got);

    const got2 = cask.resolveAppDir("/opt/homebrew", "/elsewhere", "/Users/me", true, &buf);
    try testing.expectEqualStrings("/elsewhere", got2);
}

test "resolveAppDir: non-default prefix routes to <prefix>/Applications" {
    var buf: [128]u8 = undefined;
    const got = cask.resolveAppDir("/tmp/mt.abc", null, "/Users/me", true, &buf);
    try testing.expectEqualStrings("/tmp/mt.abc/Applications", got);
}

test "resolveAppDir: default prefix + writable system → /Applications" {
    var buf: [128]u8 = undefined;
    const got = cask.resolveAppDir("/opt/malt", null, "/Users/me", true, &buf);
    try testing.expectEqualStrings("/Applications", got);
}

test "resolveAppDir: default prefix + not writable → ~/Applications" {
    var buf: [128]u8 = undefined;
    const got = cask.resolveAppDir("/opt/homebrew", null, "/Users/me", false, &buf);
    try testing.expectEqualStrings("/Users/me/Applications", got);
}

test "resolveAppDir: default prefix + not writable + no HOME → /Applications fallback" {
    // Last-resort fallback: if there's nowhere safer to put it, surface
    // the system path so the install fails loudly rather than silently
    // landing somewhere unexpected.
    var buf: [128]u8 = undefined;
    const got = cask.resolveAppDir("/opt/malt", null, null, false, &buf);
    try testing.expectEqualStrings("/Applications", got);
}
