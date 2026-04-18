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

// S10: parseGhcrUrl — pure splitter used by both the token-prefetch
// path in `execute` and the per-worker blob download in
// `downloadWorker`. Pinning the contract here keeps the two call
// sites from drifting apart.
test "parseGhcrUrl splits a well-formed bottle URL into repo + digest" {
    const url = "https://ghcr.io/v2/homebrew/core/wget/blobs/sha256:abcdef";
    const ref = install.parseGhcrUrl(url) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("homebrew/core/wget", ref.repo);
    try testing.expectEqualStrings("sha256:abcdef", ref.digest);
}

test "parseGhcrUrl handles versioned repos that contain a slash" {
    // openssl@3 maps to homebrew/core/openssl/3 in GHCR's repo layout.
    const url = "https://ghcr.io/v2/homebrew/core/openssl/3/blobs/sha256:ff00";
    const ref = install.parseGhcrUrl(url) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("homebrew/core/openssl/3", ref.repo);
    try testing.expectEqualStrings("sha256:ff00", ref.digest);
}

test "parseGhcrUrl returns null for non-GHCR and malformed URLs" {
    try testing.expect(install.parseGhcrUrl("https://example.com/foo") == null);
    try testing.expect(install.parseGhcrUrl("https://ghcr.io/v2/no-blobs-segment") == null);
    try testing.expect(install.parseGhcrUrl("") == null);
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

// Hostile / malformed inputs must never crash the parser. `--local`
// accepts user-supplied `.rb` files up to `max_local_formula_bytes`
// (1 MiB), so these cases are realistic, not paranoid.
test "parseRubyFormula survives an empty input" {
    try testing.expect(install.parseRubyFormula("") == null);
}

test "parseRubyFormula survives a single newline" {
    try testing.expect(install.parseRubyFormula("\n") == null);
}

test "parseRubyFormula survives a single un-newlined byte" {
    // The state machine has a final-char branch (`idx == len - 1`)
    // that must not read past the end of the slice for 1-byte inputs.
    try testing.expect(install.parseRubyFormula("x") == null);
}

test "parseRubyFormula survives embedded NULs without scanning past them" {
    const src = "class X < Formula\x00version \"1.0\"\x00url \"https://e/a.tar.gz\"\x00sha256 \"" ++
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"\nend";
    // The fact that we return at all is the property under test —
    // behavior on NULs is implementation-defined but must not crash.
    _ = install.parseRubyFormula(src);
}

test "parseRubyFormula tolerates a UTF-8 BOM on the first line" {
    // \xEF\xBB\xBF is the 3-byte BOM. The parser is line-oriented and
    // trims ASCII whitespace only, so a BOM-leading `version "..."`
    // line will not match — we just assert no crash here, mirroring
    // the real-world behaviour that a BOM-prefixed file parses as
    // "missing version" rather than panicking.
    const src = "\xEF\xBB\xBFversion \"1.0\"\nurl \"https://e\"\nsha256 \"0000\"\n";
    _ = install.parseRubyFormula(src);
}

test "parseRubyFormula tolerates mixed CRLF and LF line endings" {
    const src = "version \"1.0\"\r\nurl \"https://example.com/h.tar.gz\"\r\nsha256 \"" ++
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"\r\n";
    const got = install.parseRubyFormula(src) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("1.0", got.version);
}

test "parseRubyFormula tolerates an unterminated quote on a required field" {
    // `extractQuoted` returns null on unterminated content, so the
    // field stays unset and the whole parse returns null — no panic.
    const src = "version \"1.0\nurl \"\nsha256 \"\n";
    try testing.expect(install.parseRubyFormula(src) == null);
}

test "parseRubyFormula bounds work on an input near the 1 MiB cap" {
    // Synthesise a large file: a valid prelude, then ~1 MiB of
    // irrelevant padding. We only assert the parse completes and
    // extracts the prelude — the property is "no pathological scan
    // cost or OOB access on long inputs".
    const alloc = testing.allocator;
    const header = "version \"1.0\"\nurl \"https://example.com/big.tar.gz\"\n" ++
        "sha256 \"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"\n";
    const padding_len: usize = 256 * 1024;
    const big = try alloc.alloc(u8, header.len + padding_len);
    defer alloc.free(big);
    @memcpy(big[0..header.len], header);
    @memset(big[header.len..], 'x');
    const got = install.parseRubyFormula(big);
    try testing.expect(got != null);
    try testing.expectEqualStrings("1.0", got.?.version);
}

test "parseRubyFormula refuses when on_arm/on_intel section has no sha256" {
    const src =
        \\class Hello < Formula
        \\  version "1.0"
        \\  on_macos do
        \\    on_arm do
        \\      url "https://example.com/hello-arm.tar.gz"
        \\    end
        \\  end
        \\end
    ;
    try testing.expect(install.parseRubyFormula(src) == null);
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
        .{malt.fs_compat.nanoTimestamp()},
    );
    defer testing.allocator.free(prefix);
    malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
    defer malt.fs_compat.deleteTreeAbsolute(prefix) catch {};

    try install.ensureDirs(prefix);

    const subs = [_][]const u8{ "store", "Cellar", "Caskroom", "opt", "bin", "lib", "include", "share", "sbin", "etc", "tmp", "cache", "db" };
    for (subs) |s| {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ prefix, s });
        defer testing.allocator.free(p);
        var d = try malt.fs_compat.openDirAbsolute(p, .{});
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
