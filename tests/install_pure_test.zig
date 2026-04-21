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

// ---------------------------------------------------------------------------
// routePostInstallOutcome — branch coverage driven by a synthetic fallback
// log. The router is where "completed" gets its real meaning (zero logged
// entries) and where silent unknown_method entries now surface the
// `--use-system-ruby` hint instead of passing under the radar.
// ---------------------------------------------------------------------------

const dsl = @import("malt").dsl;
const io_mod = @import("malt").io_mod;
const color_mod = @import("malt").color;
const output_mod = @import("malt").output;

/// Capture stderr output from a single router call and return the raw
/// bytes. Caller owns the buffer. Deterministic state (no color / no
/// emoji / not quiet) so the assertions pin plain ASCII prefixes.
fn runRoute(
    flog: *const dsl.FallbackLog,
    name: []const u8,
    scope: []const []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(testing.allocator);

    color_mod.setForTest(false, false);
    defer color_mod.setForTest(null, null);
    const prior_quiet = output_mod.isQuiet();
    output_mod.setQuiet(false);
    defer output_mod.setQuiet(prior_quiet);

    io_mod.beginStderrCapture(testing.allocator, &buf);
    defer io_mod.endStderrCapture();

    install.routePostInstallOutcome(testing.allocator, name, "1.0", "/tmp/irrelevant", flog, scope);

    return buf.toOwnedSlice(testing.allocator);
}

test "routePostInstallOutcome: clean flog prints a 'completed' info line" {
    var flog = dsl.FallbackLog.init(testing.allocator);
    defer flog.deinit();

    const out = try runRoute(&flog, "wget", &.{});
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "post_install completed for wget") != null);
    // Never suggest the Ruby fallback on clean runs.
    try testing.expect(std.mem.indexOf(u8, out, "--use-system-ruby") == null);
    try testing.expect(std.mem.indexOf(u8, out, "fatal") == null);
}

test "routePostInstallOutcome: non-fatal entry surfaces the --use-system-ruby hint" {
    var flog = dsl.FallbackLog.init(testing.allocator);
    defer flog.deinit();
    flog.log(.{
        .formula = "wget",
        .reason = .unknown_method,
        .detail = "some_helper",
        .loc = .{ .line = 2, .col = 3 },
    });

    const out = try runRoute(&flog, "wget", &.{});
    defer testing.allocator.free(out);

    // Downgrade: "completed" must NOT appear — silent skip ≠ success.
    try testing.expect(std.mem.indexOf(u8, out, "post_install completed") == null);
    try testing.expect(std.mem.indexOf(u8, out, "partially skipped") != null);
    try testing.expect(std.mem.indexOf(u8, out, "--use-system-ruby=wget") != null);
}

test "routePostInstallOutcome: --use-system-ruby=NAME in scope triggers the Ruby fallback banner" {
    var flog = dsl.FallbackLog.init(testing.allocator);
    defer flog.deinit();
    flog.log(.{
        .formula = "openssl@3",
        .reason = .unsupported_node,
        .detail = "keyword_args",
        .loc = null,
    });

    const scope = [_][]const u8{"openssl@3"};
    const out = try runRoute(&flog, "openssl@3", scope[0..]);
    defer testing.allocator.free(out);

    // The fallback banner leads the warning so users know the Ruby
    // subprocess is about to run — not the "partially skipped" hint.
    try testing.expect(std.mem.indexOf(u8, out, "falling back to system Ruby") != null);
    try testing.expect(std.mem.indexOf(u8, out, "partially skipped") == null);
    try testing.expect(std.mem.indexOf(u8, out, "post_install completed") == null);
}

test "routePostInstallOutcome: fatal entry wins over hasErrors heuristic" {
    var flog = dsl.FallbackLog.init(testing.allocator);
    defer flog.deinit();
    flog.log(.{
        .formula = "evil",
        .reason = .sandbox_violation,
        .detail = "/etc/passwd",
        .loc = .{ .line = 1, .col = 1 },
    });
    // A fatal entry must short-circuit even if --use-system-ruby is in
    // scope — sandbox violations are never delegated to Ruby.
    const scope = [_][]const u8{"evil"};
    const out = try runRoute(&flog, "evil", scope[0..]);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "post_install DSL failed for evil (fatal)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "falling back to system Ruby") == null);
    try testing.expect(std.mem.indexOf(u8, out, "post_install completed") == null);
}

test "routePostInstallOutcome: scope with unrelated names is ignored" {
    var flog = dsl.FallbackLog.init(testing.allocator);
    defer flog.deinit();
    flog.log(.{ .formula = "foo", .reason = .unknown_method, .detail = "x", .loc = null });

    // `--use-system-ruby=other` shouldn't catch "foo".
    const scope = [_][]const u8{"other"};
    const out = try runRoute(&flog, "foo", scope[0..]);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "falling back to system Ruby") == null);
    try testing.expect(std.mem.indexOf(u8, out, "partially skipped (use --use-system-ruby=foo") != null);
}

// ---------------------------------------------------------------------------
// routePostInstallOutcome under --verbose / --debug — the diagnostic dump
// is what lets users (and bug reports) see WHICH helpers the DSL skipped.
// ---------------------------------------------------------------------------

test "routePostInstallOutcome: --verbose dumps unknown_method entries after the hint" {
    var flog = dsl.FallbackLog.init(testing.allocator);
    defer flog.deinit();
    flog.log(.{ .formula = "foo", .reason = .unknown_method, .detail = "quiet_system", .loc = .{ .line = 4, .col = 6 } });
    flog.log(.{ .formula = "foo", .reason = .unsupported_node, .detail = "default_args", .loc = null });

    const prior = output_mod.isVerbose();
    output_mod.setVerbose(true);
    defer output_mod.setVerbose(prior);

    const out = try runRoute(&flog, "foo", &.{});
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "partially skipped") != null);
    // Both reasons surface, with/without source location.
    try testing.expect(std.mem.indexOf(u8, out, "foo:4:6: [unknown_method] quiet_system") != null);
    try testing.expect(std.mem.indexOf(u8, out, "foo: [unsupported_node] default_args") != null);
}

test "routePostInstallOutcome: --debug surfaces fatal entries alongside the hint" {
    var flog = dsl.FallbackLog.init(testing.allocator);
    defer flog.deinit();
    // Non-fatal unknown + a parse_error diagnostic — debug prints both.
    flog.log(.{ .formula = "foo", .reason = .unknown_method, .detail = "helper", .loc = null });
    flog.log(.{ .formula = "foo", .reason = .parse_error, .detail = "unexpected token", .loc = .{ .line = 1, .col = 1 } });

    const prior_v = output_mod.isVerbose();
    const prior_d = output_mod.isDebug();
    output_mod.setDebug(true);
    defer {
        output_mod.setVerbose(prior_v);
        // No setter to un-debug a flag — reset via setDebug(false).
        output_mod.setDebug(prior_d);
    }

    const out = try runRoute(&flog, "foo", &.{});
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "partially skipped") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[unknown_method] helper") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[parse_error] unexpected token") != null);
}

test "routePostInstallOutcome: fatal + --debug also prints non-fatal context" {
    var flog = dsl.FallbackLog.init(testing.allocator);
    defer flog.deinit();
    flog.log(.{ .formula = "z", .reason = .sandbox_violation, .detail = "/etc/passwd", .loc = null });
    flog.log(.{ .formula = "z", .reason = .unknown_method, .detail = "tangential_helper", .loc = null });

    const prior_d = output_mod.isDebug();
    output_mod.setDebug(true);
    defer output_mod.setDebug(prior_d);

    const out = try runRoute(&flog, "z", &.{});
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "DSL failed for z (fatal)") != null);
    // Sandbox violation surfaces via printFatal; tangential helper via printUnknown.
    try testing.expect(std.mem.indexOf(u8, out, "[sandbox_violation] /etc/passwd") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[unknown_method] tangential_helper") != null);
}

// ---------------------------------------------------------------------------
// routePostInstallOutcome under --json — one structured line per package
// so scripted pipelines can tell completed / partial / fatal apart.
// ---------------------------------------------------------------------------

fn runRouteCaptureStdout(
    flog: *const dsl.FallbackLog,
    name: []const u8,
    scope: []const []const u8,
) ![]u8 {
    var stdout_buf: std.ArrayList(u8) = .empty;
    errdefer stdout_buf.deinit(testing.allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(testing.allocator);

    color_mod.setForTest(false, false);
    defer color_mod.setForTest(null, null);

    const prior_mode_is_json = output_mod.isJson();
    output_mod.setMode(.json);
    defer output_mod.setMode(if (prior_mode_is_json) .json else .human);

    io_mod.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer io_mod.endStdoutCapture();
    io_mod.beginStderrCapture(testing.allocator, &stderr_buf);
    defer io_mod.endStderrCapture();

    install.routePostInstallOutcome(testing.allocator, name, "1.0", "/tmp/irrelevant", flog, scope);
    return stdout_buf.toOwnedSlice(testing.allocator);
}

test "routePostInstallOutcome: --json emits one status line with escaped name" {
    var flog = dsl.FallbackLog.init(testing.allocator);
    defer flog.deinit();
    flog.log(.{ .formula = "llvm@21", .reason = .unknown_method, .detail = "write_config_files", .loc = .{ .line = 8, .col = 3 } });

    const out = try runRouteCaptureStdout(&flog, "llvm@21", &.{});
    defer testing.allocator.free(out);

    // Shape: `{"event":"post_install","name":"llvm@21","status":"partially_skipped","entries":[...]}\n`
    try testing.expect(std.mem.endsWith(u8, out, "\n"));
    try testing.expect(std.mem.indexOf(u8, out, "\"event\":\"post_install\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"name\":\"llvm@21\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"status\":\"partially_skipped\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"reason\":\"unknown_method\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"detail\":\"write_config_files\"") != null);

    // Round-trip through std.json to confirm the line is parser-clean.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("llvm@21", parsed.value.object.get("name").?.string);
    try testing.expectEqualStrings("partially_skipped", parsed.value.object.get("status").?.string);
}

test "routePostInstallOutcome: --json status=completed for clean flog" {
    var flog = dsl.FallbackLog.init(testing.allocator);
    defer flog.deinit();
    const out = try runRouteCaptureStdout(&flog, "wget", &.{});
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"status\":\"completed\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"entries\":[]") != null);
}

test "routePostInstallOutcome: --json status=fatal on sandbox violation" {
    var flog = dsl.FallbackLog.init(testing.allocator);
    defer flog.deinit();
    flog.log(.{ .formula = "bad", .reason = .sandbox_violation, .detail = "/etc/passwd", .loc = null });
    const out = try runRouteCaptureStdout(&flog, "bad", &.{});
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"status\":\"fatal\"") != null);
}

// ---------------------------------------------------------------------------
// executeDslPostInstall — owns one DSL attempt against a job. The outcome
// decides whether the caller falls through to the system-Ruby fallback.
// ---------------------------------------------------------------------------

fn stubJob(name: []const u8, formula_json: []const u8) install.DownloadJob {
    return .{
        .name = name,
        .version_str = "1.0",
        .sha256 = "aa",
        .bottle_url = "",
        .is_dep = false,
        .keg_only = false,
        .post_install_defined = true,
        .formula_json = formula_json,
        .cellar_type = ":any",
        .label_width = 0,
        .line_index = 0,
        .multi = null,
        .bar = null,
        .store_sha256 = "",
        .succeeded = true,
    };
}

test "executeDslPostInstall returns .parse_failed when formula JSON is unparseable" {
    // The parse-failure path must surface as a distinct outcome so the
    // caller can still try the system-Ruby fallback instead of silently
    // dropping the hook.
    const prior_quiet = output_mod.isQuiet();
    output_mod.setQuiet(true);
    defer output_mod.setQuiet(prior_quiet);

    const job = stubJob("bad-json", "not-a-json");
    const outcome = install.executeDslPostInstall(
        testing.allocator,
        &job,
        "# empty body",
        "/tmp/irrelevant",
        &.{},
    );
    try testing.expectEqual(install.DslPostInstallOutcome.parse_failed, outcome);
}

test "executeDslPostInstall returns .handled when DSL executes against a valid formula" {
    color_mod.setForTest(false, false);
    defer color_mod.setForTest(null, null);
    const prior_quiet = output_mod.isQuiet();
    output_mod.setQuiet(true);
    defer output_mod.setQuiet(prior_quiet);

    // Minimal valid JSON: parseFormula only requires `name`; an empty Ruby
    // body compiles to zero nodes so the interpreter runs to completion.
    const json =
        \\{"name":"hello","full_name":"hello","versions":{"stable":"1.0"},"dependencies":[],"oldnames":[]}
    ;
    const job = stubJob("hello", json);
    const outcome = install.executeDslPostInstall(
        testing.allocator,
        &job,
        "# empty",
        "/tmp/irrelevant",
        &.{},
    );
    try testing.expectEqual(install.DslPostInstallOutcome.handled, outcome);
}

// ---------------------------------------------------------------------------
// Invariants — pinned as tests so future refactors can't drift them silently:
//   - per-formula FallbackLog isolation
//   - deferred cleanup fires on labelled break
//   - multiple non-fatal entries emit a single partial-skip warning
//   - unknown scope names can't pass as `--use-system-ruby` matches
// ---------------------------------------------------------------------------

test "invariant: two FallbackLogs stay isolated (per-formula scope)" {
    var a = dsl.FallbackLog.init(testing.allocator);
    defer a.deinit();
    var b = dsl.FallbackLog.init(testing.allocator);
    defer b.deinit();

    a.log(.{ .formula = "a", .reason = .unknown_method, .detail = "a_helper", .loc = null });
    try testing.expect(a.hasErrors());
    try testing.expect(!b.hasErrors());
    try testing.expectEqual(@as(usize, 1), a.entries.items.len);
    try testing.expectEqual(@as(usize, 0), b.entries.items.len);
}

test "invariant: router emits exactly one partially-skipped warn regardless of entry count" {
    var flog = dsl.FallbackLog.init(testing.allocator);
    defer flog.deinit();
    // 10 entries shouldn't yield 10 warnings — the hint is per-package.
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        flog.log(.{ .formula = "f", .reason = .unknown_method, .detail = "x", .loc = null });
    }
    const out = try runRoute(&flog, "f", &.{});
    defer testing.allocator.free(out);

    // One "partially skipped" line with the package name — count occurrences.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "partially skipped"));
}

test "invariant: defer fires on labelled break (FallbackLog no-leak)" {
    // Smokes the control-flow that the install loop uses every iteration.
    var leaked = false;
    outer: {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(testing.allocator);
        list.append(testing.allocator, 'x') catch {
            leaked = true;
            break :outer;
        };
        // Labelled break — the Zig runtime MUST still run the defer above.
        break :outer;
    }
    try testing.expect(!leaked);
}
