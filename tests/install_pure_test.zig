//! malt — install.zig pure-helper tests
//! Covers extractQuoted, buildGhcrRepo, isTapFormula, parseTapName,
//! parseRubyFormula, and checkPrefixLength — all side-effect-free.

const std = @import("std");
const testing = std.testing;
const install = @import("malt").install;

test "extractQuoted returns the string between the prefix and the next quote" {
    const got = install.extractQuoted("version \"1.2.3\"", "version \"");
    try testing.expect(got != null);
    try testing.expectEqualStrings("1.2.3", got.?);
}

test "extractQuoted returns null when the prefix is absent" {
    try testing.expect(install.extractQuoted("something else", "version \"") == null);
}

test "extractQuoted returns null when there is no closing quote" {
    // "version \"unterminated" has no closing quote after the prefix.
    try testing.expect(install.extractQuoted("version \"unterminated", "version \"") == null);
}

test "buildGhcrRepo appends plain names under homebrew/core/" {
    var buf: [128]u8 = undefined;
    const got = try install.buildGhcrRepo(&buf, "wget");
    try testing.expectEqualStrings("homebrew/core/wget", got);
}

test "buildGhcrRepo translates @ into / for versioned formulas" {
    var buf: [128]u8 = undefined;
    const got = try install.buildGhcrRepo(&buf, "openssl@3");
    try testing.expectEqualStrings("homebrew/core/openssl/3", got);
}

test "buildGhcrRepo returns OutOfMemory when the buffer is too small" {
    var buf: [8]u8 = undefined; // not big enough for the prefix
    try testing.expectError(error.OutOfMemory, install.buildGhcrRepo(&buf, "wget"));
}

test "isTapFormula recognises the 'user/repo/formula' shape" {
    try testing.expect(install.isTapFormula("homebrew/core/wget"));
    try testing.expect(install.isTapFormula("user/tap/myformula"));
}

test "isTapFormula rejects other shapes" {
    try testing.expect(!install.isTapFormula("wget"));
    try testing.expect(!install.isTapFormula("user/repo"));
    try testing.expect(!install.isTapFormula("a/b/c/d"));
}

test "parseTapName splits into user, repo, formula" {
    const got = install.parseTapName("user/tap/myformula");
    try testing.expect(got != null);
    try testing.expectEqualStrings("user", got.?.user);
    try testing.expectEqualStrings("tap", got.?.repo);
    try testing.expectEqualStrings("myformula", got.?.formula);
}

test "parseTapName returns null on an incomplete string" {
    try testing.expect(install.parseTapName("user") == null);
    try testing.expect(install.parseTapName("user/repo") == null);
}

test "checkPrefixLength rejects a prefix longer than the Mach-O budget" {
    const too_long = "/" ++ "x" ** 64;
    try testing.expectError(error.PrefixTooLong, install.checkPrefixLength(too_long));
}

test "checkPrefixLength accepts prefixes up to the Mach-O budget" {
    try install.checkPrefixLength("/opt/malt");
    try install.checkPrefixLength("/usr/local");
    try install.checkPrefixLength("/opt/homebrew");
}

test "parseRubyFormula extracts version/url/sha256 from a flat formula body" {
    const src =
        \\class Hello < Formula
        \\  version "1.0"
        \\  url "https://example.com/hello-1.0.tar.gz"
        \\  sha256 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        \\end
    ;
    const got = install.parseRubyFormula(src);
    try testing.expect(got != null);
    try testing.expectEqualStrings("1.0", got.?.version);
    try testing.expectEqualStrings("https://example.com/hello-1.0.tar.gz", got.?.url);
    try testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        got.?.sha256,
    );
}

test "parseRubyFormula returns null when required fields are missing" {
    try testing.expect(install.parseRubyFormula("class X end") == null);
}

test "parseRubyFormula prefers the platform-specific section when on_arm/on_intel are present" {
    const is_arm = @import("builtin").cpu.arch == .aarch64;
    // Two sections: on_arm picks the arm binary, on_intel picks the x86 binary.
    const src =
        \\class Hello < Formula
        \\  version "1.0"
        \\  on_macos do
        \\    on_arm do
        \\      url "https://example.com/hello-arm.tar.gz"
        \\      sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\    end
        \\    on_intel do
        \\      url "https://example.com/hello-intel.tar.gz"
        \\      sha256 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        \\    end
        \\  end
        \\end
    ;
    const got = install.parseRubyFormula(src);
    try testing.expect(got != null);
    if (is_arm) {
        try testing.expect(std.mem.indexOf(u8, got.?.url, "arm") != null);
    } else {
        try testing.expect(std.mem.indexOf(u8, got.?.url, "intel") != null);
    }
}

test "findFailedDep flags the first dep name that appears in failed_kegs" {
    var failed = std.StringHashMap(void).init(testing.allocator);
    defer failed.deinit();
    try failed.put("libfoo", {});

    const json =
        \\{"name":"bar","full_name":"bar","versions":{"stable":"1.0"},"bottle":{"stable":{"files":{}}},"dependencies":["libfoo","other"]}
    ;
    const name = install.findFailedDep(&failed, json);
    try testing.expect(name != null);
    try testing.expectEqualStrings("libfoo", name.?);
}

const malt = @import("malt");
const sqlite = malt.sqlite;
const schema = malt.schema;
const formula_mod = malt.formula;

fn openDb() !sqlite.Database {
    return sqlite.Database.open(":memory:");
}

const fake_formula_json =
    \\{
    \\  "name": "foo",
    \\  "full_name": "foo",
    \\  "tap": "homebrew/core",
    \\  "desc": "",
    \\  "homepage": "",
    \\  "versions": {"stable": "1.0"},
    \\  "revision": 0,
    \\  "dependencies": ["libbar", "libbaz"],
    \\  "keg_only": false,
    \\  "post_install_defined": false,
    \\  "oldnames": [],
    \\  "bottle": {"stable": {"files": {}}}
    \\}
;

fn parseFake(alloc: std.mem.Allocator) !formula_mod.Formula {
    return formula_mod.parseFormula(alloc, fake_formula_json);
}

test "isInstalled is false before recordKeg, true after" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try testing.expect(!install.isInstalled(&db, "foo"));

    var f = try parseFake(arena.allocator());
    defer f.deinit();
    const keg_id = try install.recordKeg(&db, &f, "0" ** 64, "/opt/malt/Cellar/foo/1.0", "direct");
    try testing.expect(keg_id > 0);
    try testing.expect(install.isInstalled(&db, "foo"));
}

test "recordDeps inserts one row per dependency in the dependencies table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    var f = try parseFake(arena.allocator());
    defer f.deinit();
    const keg_id = try install.recordKeg(&db, &f, "0" ** 64, "/opt/malt/Cellar/foo/1.0", "direct");
    install.recordDeps(&db, keg_id, &f);

    var stmt = try db.prepare("SELECT COUNT(*) FROM dependencies WHERE keg_id = ?1;");
    defer stmt.finalize();
    try stmt.bindInt(1, keg_id);
    _ = try stmt.step();
    try testing.expectEqual(@as(i64, 2), stmt.columnInt(0));
}

test "deleteKeg removes the row and isInstalled reports false again" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    var f = try parseFake(arena.allocator());
    defer f.deinit();
    const keg_id = try install.recordKeg(&db, &f, "0" ** 64, "/opt/malt/Cellar/foo/1.0", "direct");
    try testing.expect(install.isInstalled(&db, "foo"));
    install.deleteKeg(&db, keg_id);
    try testing.expect(!install.isInstalled(&db, "foo"));
}

test "ensureDirs creates every required subdirectory under a fresh prefix" {
    const prefix = try std.fmt.allocPrint(
        testing.allocator,
        "/tmp/malt_install_ensure_dirs_{d}",
        .{std.time.nanoTimestamp()},
    );
    defer testing.allocator.free(prefix);
    std.fs.deleteTreeAbsolute(prefix) catch {};
    defer std.fs.deleteTreeAbsolute(prefix) catch {};

    try install.ensureDirs(prefix);

    const subs = [_][]const u8{ "store", "Cellar", "Caskroom", "opt", "bin", "lib", "include", "share", "sbin", "etc", "tmp", "cache", "db" };
    for (subs) |s| {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ prefix, s });
        defer testing.allocator.free(p);
        var d = try std.fs.openDirAbsolute(p, .{});
        d.close();
    }
}

test "findFailedDep returns null when no dep is in the failed set" {
    var failed = std.StringHashMap(void).init(testing.allocator);
    defer failed.deinit();

    const json =
        \\{"name":"bar","full_name":"bar","versions":{"stable":"1.0"},"bottle":{"stable":{"files":{}}},"dependencies":["libfoo"]}
    ;
    try testing.expect(install.findFailedDep(&failed, json) == null);
}
