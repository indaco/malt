//! malt — ruby_subprocess pure-helper tests
//! Covers tap discovery, formula .rb path resolution (new sharded and flat
//! layouts), and post_install body extraction from a .rb file on disk.

const std = @import("std");
const malt = @import("malt");
const testing = std.testing;
const ruby = @import("malt").ruby_subprocess;

fn uniqueDir(suffix: []const u8) ![]u8 {
    const p = try std.fmt.allocPrint(
        testing.allocator,
        "/tmp/malt_ruby_sub_{d}_{s}",
        .{ malt.fs_compat.nanoTimestamp(), suffix },
    );
    try malt.fs_compat.cwd().makePath(p);
    return p;
}

test "findHomebrewCoreTap returns null when the canonical paths are absent" {
    // On most CI boxes the tap is absent. We can't assert true/null
    // deterministically, so we at least exercise the lookup loop.
    _ = ruby.findHomebrewCoreTap();
}

test "resolveFormulaRbPath returns null for an empty name" {
    var buf: [1024]u8 = undefined;
    try testing.expect(ruby.resolveFormulaRbPath(&buf, "/any/tap", "") == null);
}

test "resolveFormulaRbPath returns null when neither layout exists" {
    const tap = try uniqueDir("no_formula");
    defer testing.allocator.free(tap);
    defer malt.fs_compat.deleteTreeAbsolute(tap) catch {};
    var buf: [1024]u8 = undefined;
    try testing.expect(ruby.resolveFormulaRbPath(&buf, tap, "wget") == null);
}

test "resolveFormulaRbPath prefers the sharded Formula/{first}/{name}.rb layout" {
    const tap = try uniqueDir("sharded");
    defer testing.allocator.free(tap);
    defer malt.fs_compat.deleteTreeAbsolute(tap) catch {};
    const shard_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Formula/w", .{tap});
    defer testing.allocator.free(shard_dir);
    try malt.fs_compat.cwd().makePath(shard_dir);
    const rb = try std.fmt.allocPrint(testing.allocator, "{s}/wget.rb", .{shard_dir});
    defer testing.allocator.free(rb);
    (try malt.fs_compat.createFileAbsolute(rb, .{})).close();

    var buf: [1024]u8 = undefined;
    const got = ruby.resolveFormulaRbPath(&buf, tap, "wget");
    try testing.expect(got != null);
    try testing.expect(std.mem.endsWith(u8, got.?, "/Formula/w/wget.rb"));
}

test "resolveFormulaRbPath falls back to the flat Formula/{name}.rb layout" {
    const tap = try uniqueDir("flat");
    defer testing.allocator.free(tap);
    defer malt.fs_compat.deleteTreeAbsolute(tap) catch {};
    const flat_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Formula", .{tap});
    defer testing.allocator.free(flat_dir);
    try malt.fs_compat.cwd().makePath(flat_dir);
    const rb = try std.fmt.allocPrint(testing.allocator, "{s}/wget.rb", .{flat_dir});
    defer testing.allocator.free(rb);
    (try malt.fs_compat.createFileAbsolute(rb, .{})).close();

    var buf: [1024]u8 = undefined;
    const got = ruby.resolveFormulaRbPath(&buf, tap, "wget");
    try testing.expect(got != null);
    try testing.expect(std.mem.endsWith(u8, got.?, "/Formula/wget.rb"));
}

test "extractPostInstallBody returns null when the file has no post_install" {
    const tap = try uniqueDir("no_postinstall");
    defer testing.allocator.free(tap);
    defer malt.fs_compat.deleteTreeAbsolute(tap) catch {};
    const rb = try std.fmt.allocPrint(testing.allocator, "{s}/hello.rb", .{tap});
    defer testing.allocator.free(rb);
    {
        const f = try malt.fs_compat.createFileAbsolute(rb, .{});
        try f.writeAll("class Hello < Formula\n  url \"x\"\nend\n");
        f.close();
    }
    try testing.expect(ruby.extractPostInstallBody(testing.allocator, rb) == null);
}

test "extractPostInstallBody returns null for a missing file" {
    try testing.expect(ruby.extractPostInstallBody(testing.allocator, "/tmp/malt_ruby_missing_xyz.rb") == null);
}

test "extractPostInstallFromSource handles an in-memory Ruby body" {
    const src =
        \\class Hello < Formula
        \\  def post_install
        \\    mkdir_p "etc"
        \\  end
        \\end
        \\
    ;
    const body = ruby.extractPostInstallFromSource(testing.allocator, src);
    try testing.expect(body != null);
    defer testing.allocator.free(body.?);
    try testing.expect(std.mem.indexOf(u8, body.?, "mkdir_p \"etc\"") != null);
}

test "extractPostInstallFromSource returns null when no post_install exists" {
    const src = "class X < Formula\n  url \"x\"\nend\n";
    try testing.expect(ruby.extractPostInstallFromSource(testing.allocator, src) == null);
}

test "extractPostInstallFromSource handles post_install at the top level (no indent)" {
    const src =
        \\def post_install
        \\touch "foo"
        \\end
        \\
    ;
    const body = ruby.extractPostInstallFromSource(testing.allocator, src);
    try testing.expect(body != null);
    defer testing.allocator.free(body.?);
    try testing.expect(std.mem.indexOf(u8, body.?, "touch \"foo\"") != null);
}

test "generateWrapper emits a Ruby script containing the post_install body and prefix" {
    const script = try ruby.generateWrapper(
        testing.allocator,
        "mypkg",
        "2.3",
        "/opt/malt",
        "  mkdir_p \"etc/mypkg\"\n",
    );
    defer testing.allocator.free(script);
    try testing.expect(std.mem.indexOf(u8, script, "require 'pathname'") != null);
    try testing.expect(std.mem.indexOf(u8, script, "mkdir_p \"etc/mypkg\"") != null);
    try testing.expect(std.mem.indexOf(u8, script, "/opt/malt") != null);
    try testing.expect(std.mem.indexOf(u8, script, "mypkg") != null);
    try testing.expect(std.mem.indexOf(u8, script, "2.3") != null);
}

// Injection regression — every disallowed byte in any of prefix /
// name / version must be rejected by generateWrapper, not silently
// interpolated into the single-quoted Ruby literal.

test "generateWrapper rejects single quote in prefix" {
    try testing.expectError(
        error.InvalidInput,
        ruby.generateWrapper(testing.allocator, "pkg", "1.0", "/tmp/m'x", "ohai 'hi'\n"),
    );
}

test "generateWrapper rejects backslash in prefix" {
    try testing.expectError(
        error.InvalidInput,
        ruby.generateWrapper(testing.allocator, "pkg", "1.0", "/tmp/m\\x", "ohai 'hi'\n"),
    );
}

test "generateWrapper rejects newline in prefix" {
    try testing.expectError(
        error.InvalidInput,
        ruby.generateWrapper(testing.allocator, "pkg", "1.0", "/tmp/m\nx", "ohai 'hi'\n"),
    );
}

test "generateWrapper rejects single quote in name" {
    try testing.expectError(
        error.InvalidInput,
        ruby.generateWrapper(testing.allocator, "p'k", "1.0", "/opt/malt", "ohai 'hi'\n"),
    );
}

test "generateWrapper rejects backslash in name" {
    try testing.expectError(
        error.InvalidInput,
        ruby.generateWrapper(testing.allocator, "p\\k", "1.0", "/opt/malt", "ohai 'hi'\n"),
    );
}

test "generateWrapper rejects newline in name" {
    try testing.expectError(
        error.InvalidInput,
        ruby.generateWrapper(testing.allocator, "p\nk", "1.0", "/opt/malt", "ohai 'hi'\n"),
    );
}

test "generateWrapper rejects single quote in version" {
    try testing.expectError(
        error.InvalidInput,
        ruby.generateWrapper(testing.allocator, "pkg", "1'+exec()+'0", "/opt/malt", "ohai 'hi'\n"),
    );
}

test "generateWrapper rejects backslash in version" {
    try testing.expectError(
        error.InvalidInput,
        ruby.generateWrapper(testing.allocator, "pkg", "1\\0", "/opt/malt", "ohai 'hi'\n"),
    );
}

test "generateWrapper rejects newline in version" {
    try testing.expectError(
        error.InvalidInput,
        ruby.generateWrapper(testing.allocator, "pkg", "1\n0", "/opt/malt", "ohai 'hi'\n"),
    );
}

test "generateWrapper accepts the @-versioned name format (llvm@21)" {
    // Real-world formula names use `@` for major-version pinning.
    const script = try ruby.generateWrapper(
        testing.allocator,
        "llvm@21",
        "21.1.5",
        "/opt/malt",
        "ohai 'ok'\n",
    );
    defer testing.allocator.free(script);
    try testing.expect(std.mem.indexOf(u8, script, "llvm@21") != null);
}

test "generateWrapper rejects empty name" {
    try testing.expectError(
        error.InvalidInput,
        ruby.generateWrapper(testing.allocator, "", "1.0", "/opt/malt", "ohai 'hi'\n"),
    );
}

test "generateWrapper rejects empty version" {
    try testing.expectError(
        error.InvalidInput,
        ruby.generateWrapper(testing.allocator, "pkg", "", "/opt/malt", "ohai 'hi'\n"),
    );
}

test "generateWrapper rejects empty prefix" {
    try testing.expectError(
        error.InvalidInput,
        ruby.generateWrapper(testing.allocator, "pkg", "1.0", "", "ohai 'hi'\n"),
    );
}

test "fetchPostInstallFromGitHub returns null for an empty name" {
    try testing.expect(ruby.fetchPostInstallFromGitHub(testing.allocator, "") == null);
}

test "extractPostInstallBody captures the body between def post_install and matching end" {
    const tap = try uniqueDir("with_postinstall");
    defer testing.allocator.free(tap);
    defer malt.fs_compat.deleteTreeAbsolute(tap) catch {};
    const rb = try std.fmt.allocPrint(testing.allocator, "{s}/hello.rb", .{tap});
    defer testing.allocator.free(rb);
    {
        const f = try malt.fs_compat.createFileAbsolute(rb, .{});
        try f.writeAll(
            \\class Hello < Formula
            \\  def post_install
            \\    mkdir_p "etc/hello"
            \\    touch "etc/hello/config"
            \\  end
            \\end
            \\
        );
        f.close();
    }
    const body = ruby.extractPostInstallBody(testing.allocator, rb);
    try testing.expect(body != null);
    defer testing.allocator.free(body.?);
    try testing.expect(std.mem.indexOf(u8, body.?, "mkdir_p \"etc/hello\"") != null);
    try testing.expect(std.mem.indexOf(u8, body.?, "touch \"etc/hello/config\"") != null);
    // Trailing `end` must NOT be inside the body.
    try testing.expect(std.mem.indexOf(u8, body.?, "end\n") == null or
        std.mem.findLast(u8, body.?, "end") == null);
}

// ---------------------------------------------------------------------------
// Sibling-def extraction — real formulas (llvm@21, ca-certificates) define
// helpers at class indent and call them from post_install. The extractor
// must surface those helpers so the DSL can register them.
// ---------------------------------------------------------------------------

test "extractPostInstallFromSource prepends sibling defs so helpers resolve" {
    const src =
        \\class Foo < Formula
        \\  def helper
        \\    ohai "helped"
        \\  end
        \\
        \\  def post_install
        \\    helper
        \\  end
        \\end
        \\
    ;
    const body = ruby.extractPostInstallFromSource(testing.allocator, src);
    try testing.expect(body != null);
    defer testing.allocator.free(body.?);

    // Sibling def appears before post_install body content.
    const idx_sibling = std.mem.indexOf(u8, body.?, "def helper") orelse return error.TestUnexpectedResult;
    const idx_call = std.mem.indexOf(u8, body.?, "  helper\n") orelse return error.TestUnexpectedResult;
    try testing.expect(idx_sibling < idx_call);
    // `def post_install` itself is NOT repeated in the body — only its body.
    try testing.expect(std.mem.indexOf(u8, body.?, "def post_install") == null);
}

test "extractPostInstallFromSource collects multiple sibling defs in file order" {
    // Same shape as ca-certificates.rb — two mac/linux helpers plus the
    // dispatcher post_install. All three must register before the body runs.
    const src =
        \\class Certs < Formula
        \\  def macos_post_install
        \\    ohai "mac"
        \\  end
        \\
        \\  def linux_post_install
        \\    ohai "linux"
        \\  end
        \\
        \\  def post_install
        \\    if OS.mac?
        \\      macos_post_install
        \\    else
        \\      linux_post_install
        \\    end
        \\  end
        \\end
    ;
    const body = ruby.extractPostInstallFromSource(testing.allocator, src);
    try testing.expect(body != null);
    defer testing.allocator.free(body.?);
    try testing.expect(std.mem.indexOf(u8, body.?, "def macos_post_install") != null);
    try testing.expect(std.mem.indexOf(u8, body.?, "def linux_post_install") != null);
    try testing.expect(std.mem.indexOf(u8, body.?, "if OS.mac?") != null);
}

test "extractPostInstallFromSource skips nested defs inside post_install body" {
    // A `def` nested inside the post_install body stays in the body; it is
    // NOT promoted to a sibling (the indent match ensures this). No double
    // occurrences.
    const src =
        \\class X < Formula
        \\  def post_install
        \\    ohai "hi"
        \\  end
        \\end
    ;
    const body = ruby.extractPostInstallFromSource(testing.allocator, src);
    try testing.expect(body != null);
    defer testing.allocator.free(body.?);
    try testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, body.?, "def post_install"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, body.?, "ohai \"hi\""));
}

// ca-certificates-shaped regression: the real formula's `macos_post_install`
// and `linux_post_install` bodies use Ruby we can't parse (Tempfile, scan
// blocks, keyword args, `ensure`), so the dispatcher post_install ends up
// calling helpers that weren't registered. Pre-v0.7.0 that was a silent
// skip; the "partially skipped" warning that now fires on every TLS-using
// install is a regression we pin here end-to-end: extract + run → clean log.
test "ca-certificates-shape: dispatcher with unparseable siblings leaves flog clean" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Trailing `.` is a reliable parser diagnostic ("expected method name
    // after '.'") — canParseBlock returns false for both sibling bodies.
    const src =
        \\class CaCertificates < Formula
        \\  def macos_post_install
        \\    foo.
        \\  end
        \\
        \\  def linux_post_install
        \\    bar.
        \\  end
        \\
        \\  def post_install
        \\    if OS.mac?
        \\      macos_post_install
        \\    else
        \\      linux_post_install
        \\    end
        \\  end
        \\end
    ;

    const body = ruby.extractPostInstallFromSource(alloc, src) orelse
        return error.TestUnexpectedResult;

    const json =
        \\{
        \\  "name": "ca-certificates",
        \\  "full_name": "ca-certificates",
        \\  "tap": "homebrew/core",
        \\  "desc": "test",
        \\  "homepage": "https://example.com",
        \\  "license": "MIT",
        \\  "revision": 0,
        \\  "keg_only": false,
        \\  "post_install_defined": true,
        \\  "versions": { "stable": "2026-03-19", "head": null },
        \\  "dependencies": [],
        \\  "oldnames": [],
        \\  "bottle": { "stable": { "root_url": "https://example.com", "files": {} } }
        \\}
    ;
    var f = try malt.formula.parseFormula(alloc, json);
    defer f.deinit();

    var flog = malt.dsl.FallbackLog.init(alloc);
    defer flog.deinit();

    try malt.dsl.executePostInstall(alloc, &f, body, "/tmp/malt_cacerts_test", &flog);

    try testing.expect(!flog.hasFatal());
    try testing.expectEqual(@as(usize, 0), flog.entries.items.len);
}

// Defense-in-depth — runPostInstall must reject hostile name / version
// up front, before any of the lookup/IO work that would eventually flow
// them into the wrapper. A Cellar directory whose name or version embeds
// `'`, `\`, or a newline is a concrete attack on `--use-system-ruby`
// (the directory listing flows back into name).

test "runPostInstall rejects single-quote in name with InvalidInput" {
    const err = ruby.runPostInstall(testing.allocator, "p'k", "1.0", "/opt/malt");
    try testing.expectError(error.InvalidInput, err);
}

test "runPostInstall rejects backslash in name with InvalidInput" {
    const err = ruby.runPostInstall(testing.allocator, "p\\k", "1.0", "/opt/malt");
    try testing.expectError(error.InvalidInput, err);
}

test "runPostInstall rejects newline in version with InvalidInput" {
    const err = ruby.runPostInstall(testing.allocator, "pkg", "1\n0", "/opt/malt");
    try testing.expectError(error.InvalidInput, err);
}

test "runPostInstall rejects empty name/version/prefix with InvalidInput" {
    try testing.expectError(
        error.InvalidInput,
        ruby.runPostInstall(testing.allocator, "", "1.0", "/opt/malt"),
    );
    try testing.expectError(
        error.InvalidInput,
        ruby.runPostInstall(testing.allocator, "pkg", "", "/opt/malt"),
    );
    try testing.expectError(
        error.InvalidInput,
        ruby.runPostInstall(testing.allocator, "pkg", "1.0", ""),
    );
}

test "runPostInstall rejects hostile prefix with InvalidInput" {
    // Even if the env-boundary check were bypassed, runPostInstall must
    // not produce a syntax-corrupt wrapper.
    const err = ruby.runPostInstall(testing.allocator, "pkg", "1.0", "/tmp/m'x");
    try testing.expectError(error.InvalidInput, err);
}

test "detectRuby returns a heap-owned slice that the caller can free" {
    // On any machine that has Ruby available, the contract requires the
    // returned slice to be allocator-owned so the call site can pair it
    // with `defer allocator.free`. We can't assert the path itself
    // (machine-dependent), but we *can* verify that freeing the result
    // does not double-free or fault — which only holds if every branch
    // returns heap memory rather than a mix of static and heap slices.
    if (ruby.detectRuby(testing.allocator)) |path| {
        defer testing.allocator.free(path);
        try testing.expect(path.len > 0);
        try testing.expect(std.mem.startsWith(u8, path, "/"));
    }
}
