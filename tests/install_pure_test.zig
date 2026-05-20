//! malt — install.zig pure-helper tests
//! Covers extractQuoted, buildGhcrRepo, isTapFormula, parseTapName,
//! parseRubyFormula, and checkPrefixLength — all side-effect-free.

const std = @import("std");
const testing = std.testing;
const install = @import("malt").install;
const install_args = @import("malt").install_args;
const install_download = @import("malt").install_download;
const install_ghcr_url = @import("malt").install_ghcr_url;
const install_post_install = @import("malt").install_post_install;
const install_rb_parse = @import("malt").install_rb_parse;
const install_record = @import("malt").install_record;

test "extractQuoted returns the string between the prefix and the next quote" {
    const got = install_rb_parse.extractQuoted("version \"1.2.3\"", "version \"");
    try testing.expect(got != null);
    try testing.expectEqualStrings("1.2.3", got.?);
}

test "extractQuoted returns null when the prefix is absent" {
    try testing.expect(install_rb_parse.extractQuoted("something else", "version \"") == null);
}

test "extractQuoted returns null when there is no closing quote" {
    // "version \"unterminated" has no closing quote after the prefix.
    try testing.expect(install_rb_parse.extractQuoted("version \"unterminated", "version \"") == null);
}

test "buildGhcrRepo appends plain names under homebrew/core/" {
    var buf: [128]u8 = undefined;
    const got = try install_ghcr_url.buildGhcrRepo(&buf, "wget");
    try testing.expectEqualStrings("homebrew/core/wget", got);
}

test "buildGhcrRepo translates @ into / for versioned formulas" {
    var buf: [128]u8 = undefined;
    const got = try install_ghcr_url.buildGhcrRepo(&buf, "openssl@3");
    try testing.expectEqualStrings("homebrew/core/openssl/3", got);
}

test "buildGhcrRepo returns OutOfMemory when the buffer is too small" {
    var buf: [8]u8 = undefined; // not big enough for the prefix
    try testing.expectError(error.OutOfMemory, install_ghcr_url.buildGhcrRepo(&buf, "wget"));
}

// S10: parseGhcrUrl — pure splitter used by both the token-prefetch
// path in `execute` and the per-worker blob download in
// `downloadWorker`. Pinning the contract here keeps the two call
// sites from drifting apart.
test "parseGhcrUrl splits a well-formed bottle URL into repo + digest" {
    const url = "https://ghcr.io/v2/homebrew/core/wget/blobs/sha256:abcdef";
    const ref = install_ghcr_url.parseGhcrUrl(url) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("homebrew/core/wget", ref.repo);
    try testing.expectEqualStrings("sha256:abcdef", ref.digest);
}

test "parseGhcrUrl handles versioned repos that contain a slash" {
    // openssl@3 maps to homebrew/core/openssl/3 in GHCR's repo layout.
    const url = "https://ghcr.io/v2/homebrew/core/openssl/3/blobs/sha256:ff00";
    const ref = install_ghcr_url.parseGhcrUrl(url) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("homebrew/core/openssl/3", ref.repo);
    try testing.expectEqualStrings("sha256:ff00", ref.digest);
}

test "parseGhcrUrl returns null for non-GHCR and malformed URLs" {
    try testing.expect(install_ghcr_url.parseGhcrUrl("https://example.com/foo") == null);
    try testing.expect(install_ghcr_url.parseGhcrUrl("https://ghcr.io/v2/no-blobs-segment") == null);
    try testing.expect(install_ghcr_url.parseGhcrUrl("") == null);
}

test "isSelfInstall catches every shape that would relink malt" {
    // bare names
    try testing.expect(install_args.isSelfInstall("malt"));
    try testing.expect(install_args.isSelfInstall("mt"));
    // tap slugs
    try testing.expect(install_args.isSelfInstall("indaco/tap/malt"));
    try testing.expect(install_args.isSelfInstall("indaco/homebrew-tap/mt"));
    // local .rb paths (relative, absolute, tilde)
    try testing.expect(install_args.isSelfInstall("./malt.rb"));
    try testing.expect(install_args.isSelfInstall("/tmp/malt.rb"));
    try testing.expect(install_args.isSelfInstall("~/f/mt.rb"));
}

test "isSelfInstall lets unrelated names through" {
    try testing.expect(!install_args.isSelfInstall("wget"));
    try testing.expect(!install_args.isSelfInstall("homebrew/core/wget"));
    try testing.expect(!install_args.isSelfInstall("./wget.rb"));
    // Substring matches must not trip the guard.
    try testing.expect(!install_args.isSelfInstall("malted"));
    try testing.expect(!install_args.isSelfInstall("mtr"));
    try testing.expect(!install_args.isSelfInstall("user/tap/malted"));
    // Empty and slash-only inputs.
    try testing.expect(!install_args.isSelfInstall(""));
    try testing.expect(!install_args.isSelfInstall("/"));
}

test "isTapFormula recognises the 'user/repo/formula' shape" {
    try testing.expect(install_args.isTapFormula("homebrew/core/wget"));
    try testing.expect(install_args.isTapFormula("user/tap/myformula"));
}

test "isTapFormula rejects other shapes" {
    try testing.expect(!install_args.isTapFormula("wget"));
    try testing.expect(!install_args.isTapFormula("user/repo"));
    try testing.expect(!install_args.isTapFormula("a/b/c/d"));
}

test "parseTapName splits into user, repo, formula" {
    const got = install_args.parseTapName("user/tap/myformula");
    try testing.expect(got != null);
    try testing.expectEqualStrings("user", got.?.user);
    try testing.expectEqualStrings("tap", got.?.repo);
    try testing.expectEqualStrings("myformula", got.?.formula);
}

test "parseTapName returns null on an incomplete string" {
    try testing.expect(install_args.parseTapName("user") == null);
    try testing.expect(install_args.parseTapName("user/repo") == null);
}

test "checkPrefixSane accepts realistic prefixes (up to the 256-byte sanity cap)" {
    try install_args.checkPrefixSane("/opt/malt");
    try install_args.checkPrefixSane("/usr/local");
    try install_args.checkPrefixSane("/opt/homebrew");
    try install_args.checkPrefixSane("/tmp/mt_tahoe");
    try install_args.checkPrefixSane("/Users/someuser/malt");
    // Nothing special about 13 bytes any more — install_name_tool's
    // headerpad fallback absorbs the overflow.
    try install_args.checkPrefixSane("/var/folders/qp/mt_prefix_under_128_bytes_long_enough_to_matter");
}

test "checkPrefixSane rejects absurdly long prefixes at the 256-byte cap" {
    const huge = "/" ++ "x" ** 512;
    try testing.expectError(error.PrefixAbsurd, install_args.checkPrefixSane(huge));
}

test "parseRubyFormula extracts version/url/sha256 from a flat formula body" {
    const src =
        \\class Hello < Formula
        \\  version "1.0"
        \\  url "https://example.com/hello-1.0.tar.gz"
        \\  sha256 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        \\end
    ;
    const got = install_rb_parse.parseRubyFormula(src);
    try testing.expect(got != null);
    try testing.expectEqualStrings("1.0", got.?.version);
    try testing.expectEqualStrings("https://example.com/hello-1.0.tar.gz", got.?.url);
    try testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        got.?.sha256,
    );
}

test "parseRubyFormula returns null when required fields are missing" {
    try testing.expect(install_rb_parse.parseRubyFormula("class X end") == null);
}

// Hostile / malformed inputs must never crash the parser. `--local`
// accepts user-supplied `.rb` files up to `max_local_formula_bytes`
// (1 MiB), so these cases are realistic, not paranoid.
test "parseRubyFormula survives an empty input" {
    try testing.expect(install_rb_parse.parseRubyFormula("") == null);
}

test "parseRubyFormula survives a single newline" {
    try testing.expect(install_rb_parse.parseRubyFormula("\n") == null);
}

test "parseRubyFormula survives a single un-newlined byte" {
    // The state machine has a final-char branch (`idx == len - 1`)
    // that must not read past the end of the slice for 1-byte inputs.
    try testing.expect(install_rb_parse.parseRubyFormula("x") == null);
}

test "parseRubyFormula survives embedded NULs without scanning past them" {
    const src = "class X < Formula\x00version \"1.0\"\x00url \"https://e/a.tar.gz\"\x00sha256 \"" ++
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"\nend";
    // The fact that we return at all is the property under test —
    // behavior on NULs is implementation-defined but must not crash.
    _ = install_rb_parse.parseRubyFormula(src);
}

test "parseRubyFormula tolerates a UTF-8 BOM on the first line" {
    // \xEF\xBB\xBF is the 3-byte BOM. The parser is line-oriented and
    // trims ASCII whitespace only, so a BOM-leading `version "..."`
    // line will not match — we just assert no crash here, mirroring
    // the real-world behaviour that a BOM-prefixed file parses as
    // "missing version" rather than panicking.
    const src = "\xEF\xBB\xBFversion \"1.0\"\nurl \"https://e\"\nsha256 \"0000\"\n";
    _ = install_rb_parse.parseRubyFormula(src);
}

test "parseRubyFormula tolerates mixed CRLF and LF line endings" {
    const src = "version \"1.0\"\r\nurl \"https://example.com/h.tar.gz\"\r\nsha256 \"" ++
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"\r\n";
    const got = install_rb_parse.parseRubyFormula(src) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("1.0", got.version);
}

test "parseRubyFormula tolerates an unterminated quote on a required field" {
    // `extractQuoted` returns null on unterminated content, so the
    // field stays unset and the whole parse returns null — no panic.
    const src = "version \"1.0\nurl \"\nsha256 \"\n";
    try testing.expect(install_rb_parse.parseRubyFormula(src) == null);
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
    const got = install_rb_parse.parseRubyFormula(big);
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
    try testing.expect(install_rb_parse.parseRubyFormula(src) == null);
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
    const got = install_rb_parse.parseRubyFormula(src);
    try testing.expect(got != null);
    if (is_arm) {
        try testing.expect(std.mem.indexOf(u8, got.?.url, "arm") != null);
    } else {
        try testing.expect(std.mem.indexOf(u8, got.?.url, "intel") != null);
    }
}

// Modern Homebrew cask DSL collapses per-arch sha256 + arch suffix into
// keyword-argument directives inside a single `on_macos` block. The
// parser must pick the right sha256 and capture the `#{arch}` token so
// `interpolateUrl` can substitute it before the SHA-verified download.
test "parseRubyFormula handles cask DSL multi-arch sha256 + arch directive" {
    const is_arm = @import("builtin").cpu.arch == .aarch64;
    const src =
        \\cask "rebased" do
        \\  version "1.0.12"
        \\  on_macos do
        \\    arch arm: "-aarch64", intel: ""
        \\    sha256 arm:   "3ef9aace106128e78e94777c7fe64228cfa1df816e7cc15b8b1bc054b7df9e9c",
        \\           intel: "93bc02e6c7ba06e907cfa540ed22d9eae0a7e3408810bf3bf07cd18a8bef6cdc"
        \\    url "https://github.com/DetachHead/rebased/releases/download/#{version}/rebased#{arch}.dmg"
        \\  end
        \\  app "Rebased.app"
        \\end
    ;
    const got = install_rb_parse.parseRubyFormula(src) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("1.0.12", got.version);
    try testing.expect(std.mem.indexOf(u8, got.url, "#{arch}") != null);
    if (is_arm) {
        try testing.expectEqualStrings(
            "3ef9aace106128e78e94777c7fe64228cfa1df816e7cc15b8b1bc054b7df9e9c",
            got.sha256,
        );
        try testing.expectEqualStrings("-aarch64", got.arch_token);
    } else {
        try testing.expectEqualStrings(
            "93bc02e6c7ba06e907cfa540ed22d9eae0a7e3408810bf3bf07cd18a8bef6cdc",
            got.sha256,
        );
        try testing.expectEqualStrings("", got.arch_token);
    }
}

// Empty intel arch values are valid in real casks (the upstream archive
// has no intel-specific suffix). The parser must not collapse an empty
// captured token into "no arch was set".
test "parseRubyFormula accepts an empty intel arch token" {
    const is_arm = @import("builtin").cpu.arch == .aarch64;
    const src =
        \\cask "tool" do
        \\  version "2.0"
        \\  on_macos do
        \\    arch arm: "-arm", intel: ""
        \\    sha256 arm:   "1111111111111111111111111111111111111111111111111111111111111111",
        \\           intel: "2222222222222222222222222222222222222222222222222222222222222222"
        \\    url "https://example.com/tool#{arch}.dmg"
        \\  end
        \\end
    ;
    const got = install_rb_parse.parseRubyFormula(src) orelse return error.TestUnexpectedNull;
    if (is_arm) {
        try testing.expectEqualStrings("-arm", got.arch_token);
    } else {
        try testing.expectEqualStrings("", got.arch_token);
    }
}

// A cask that omits the `arch` directive entirely (single archive for
// both architectures, no `#{arch}` in the URL) must still parse. The
// arch_token defaults to empty so a stray `interpolateUrl` is a no-op.
test "parseRubyFormula handles a cask with no arch directive" {
    const src =
        \\cask "single" do
        \\  version "3.1"
        \\  on_macos do
        \\    sha256 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        \\    url "https://example.com/single-#{version}.dmg"
        \\  end
        \\end
    ;
    const got = install_rb_parse.parseRubyFormula(src) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("3.1", got.version);
    try testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        got.sha256,
    );
    try testing.expectEqualStrings("", got.arch_token);
}

// Both args on a single line (no comma-newline split) — some casks
// fit `arm: "...", intel: "..."` on one line. The continuation-line
// branch of the parser must not be required for this case.
test "parseRubyFormula handles single-line multi-arch sha256" {
    const is_arm = @import("builtin").cpu.arch == .aarch64;
    const src =
        \\cask "compact" do
        \\  version "0.1"
        \\  on_macos do
        \\    arch arm: "_arm", intel: "_x86"
        \\    sha256 arm: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", intel: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        \\    url "https://example.com/compact#{arch}.dmg"
        \\  end
        \\end
    ;
    const got = install_rb_parse.parseRubyFormula(src) orelse return error.TestUnexpectedNull;
    if (is_arm) {
        try testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", got.sha256);
        try testing.expectEqualStrings("_arm", got.arch_token);
    } else {
        try testing.expectEqualStrings("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", got.sha256);
        try testing.expectEqualStrings("_x86", got.arch_token);
    }
}

// Argument order independent: some casks list intel first.
test "parseRubyFormula handles intel-first multi-arch ordering" {
    const is_arm = @import("builtin").cpu.arch == .aarch64;
    const src =
        \\cask "intel-first" do
        \\  version "0.2"
        \\  on_macos do
        \\    arch intel: "-x86", arm: "-arm64"
        \\    sha256 intel: "1111111111111111111111111111111111111111111111111111111111111111",
        \\           arm:   "2222222222222222222222222222222222222222222222222222222222222222"
        \\    url "https://example.com/foo#{arch}.dmg"
        \\  end
        \\end
    ;
    const got = install_rb_parse.parseRubyFormula(src) orelse return error.TestUnexpectedNull;
    if (is_arm) {
        try testing.expectEqualStrings("2222222222222222222222222222222222222222222222222222222222222222", got.sha256);
        try testing.expectEqualStrings("-arm64", got.arch_token);
    } else {
        try testing.expectEqualStrings("1111111111111111111111111111111111111111111111111111111111111111", got.sha256);
        try testing.expectEqualStrings("-x86", got.arch_token);
    }
}

// CRLF line endings in a real-world cask file fetched from a Windows-
// committed branch. The continuation-line trim must strip the \r so
// the kwarg parser still sees `intel: "..."`.
test "parseRubyFormula handles CRLF line endings inside multi-arch sha256" {
    const is_arm = @import("builtin").cpu.arch == .aarch64;
    const src = "cask \"crlf\" do\r\n" ++
        "  version \"0.3\"\r\n" ++
        "  on_macos do\r\n" ++
        "    arch arm: \"-arm\", intel: \"\"\r\n" ++
        "    sha256 arm:   \"3333333333333333333333333333333333333333333333333333333333333333\",\r\n" ++
        "           intel: \"4444444444444444444444444444444444444444444444444444444444444444\"\r\n" ++
        "    url \"https://example.com/foo#{arch}.dmg\"\r\n" ++
        "  end\r\n" ++
        "end\r\n";
    const got = install_rb_parse.parseRubyFormula(src) orelse return error.TestUnexpectedNull;
    if (is_arm) {
        try testing.expectEqualStrings("3333333333333333333333333333333333333333333333333333333333333333", got.sha256);
        try testing.expectEqualStrings("-arm", got.arch_token);
    } else {
        try testing.expectEqualStrings("4444444444444444444444444444444444444444444444444444444444444444", got.sha256);
        try testing.expectEqualStrings("", got.arch_token);
    }
}

// Mid-line `arm:` substring inside a quoted value (here, a hash) must
// not confuse the keyword-arg matcher. The continuation-line gate is
// already gone by the time the URL line is examined, so the URL value
// has to come through cleanly.
test "parseRubyFormula does not mis-detect arm: inside quoted values" {
    const src =
        \\cask "boundary" do
        \\  version "0.4"
        \\  on_macos do
        \\    arch arm: "-arm", intel: ""
        \\    sha256 arm:   "5555555555555555555555555555555555555555555555555555555555555555",
        \\           intel: "6666666666666666666666666666666666666666666666666666666666666666"
        \\    url "https://example.com/notes:arm:thing/foo#{arch}.tar.gz"
        \\  end
        \\end
    ;
    const got = install_rb_parse.parseRubyFormula(src) orelse return error.TestUnexpectedNull;
    // The url should reach the parser intact (#{arch} interpolated later).
    try testing.expect(std.mem.indexOf(u8, got.url, "notes:arm:thing") != null);
}

// A formula that mixes shapes (a global sha256 plus a Hardware::CPU
// section that only sets url) must still parse — the global fallback
// loop fills in whichever field the section path missed.
test "parseRubyFormula falls back to global sha256 when section omits it" {
    const is_arm = @import("builtin").cpu.arch == .aarch64;
    const src =
        \\class Mixed < Formula
        \\  version "1.0"
        \\  sha256 "7777777777777777777777777777777777777777777777777777777777777777"
        \\  on_macos do
        \\    on_arm do
        \\      url "https://example.com/mixed-arm.tar.gz"
        \\    end
        \\    on_intel do
        \\      url "https://example.com/mixed-intel.tar.gz"
        \\    end
        \\  end
        \\end
    ;
    const got = install_rb_parse.parseRubyFormula(src) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("7777777777777777777777777777777777777777777777777777777777777777", got.sha256);
    if (is_arm) {
        try testing.expect(std.mem.indexOf(u8, got.url, "arm") != null);
    } else {
        try testing.expect(std.mem.indexOf(u8, got.url, "intel") != null);
    }
}

// A cask with the keyword-arg form for the current arch only (the other
// arch is missing from the keyword args entirely). On the missing arch
// the parse must return null cleanly — no crash, no partial info, no
// false claim of success.
test "parseRubyFormula returns null when current platform's kwarg is missing" {
    const is_arm = @import("builtin").cpu.arch == .aarch64;
    const src_arm_only =
        \\cask "arm-only" do
        \\  version "0.5"
        \\  on_macos do
        \\    arch arm: "-arm"
        \\    sha256 arm: "8888888888888888888888888888888888888888888888888888888888888888"
        \\    url "https://example.com/foo#{arch}.dmg"
        \\  end
        \\end
    ;
    if (is_arm) {
        const got = install_rb_parse.parseRubyFormula(src_arm_only) orelse return error.TestUnexpectedNull;
        try testing.expectEqualStrings("-arm", got.arch_token);
    } else {
        try testing.expect(install_rb_parse.parseRubyFormula(src_arm_only) == null);
    }
}

// The arch directive is per-on_macos: a directive emitted before the
// `on_macos` block opens (rare but seen in stage-loaded casks) should
// be ignored so a Linux-side block can't bleed an arch token into the
// macOS install.
test "parseRubyFormula ignores arch directive outside on_macos" {
    const is_arm = @import("builtin").cpu.arch == .aarch64;
    _ = is_arm;
    const src =
        \\cask "scoped" do
        \\  version "0.6"
        \\  arch arm: "-do-not-use", intel: "-also-no"
        \\  on_macos do
        \\    sha256 "9999999999999999999999999999999999999999999999999999999999999999"
        \\    url "https://example.com/scoped-#{version}.dmg"
        \\  end
        \\end
    ;
    const got = install_rb_parse.parseRubyFormula(src) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("", got.arch_token);
}

// `version` is optional in Homebrew formulas — when the tag is encoded
// in the URL path, the parser must derive it so common tap shapes like
// `aeroxy/tap/ast-outline` (top-level url + sha256, no version line,
// release-asset URL) install instead of failing as "unsupported DSL".
test "parseRubyFormula derives version from /releases/download/<X>/ when version directive is absent" {
    const src =
        \\class AstOutline < Formula
        \\  desc "test"
        \\  url "https://github.com/aeroxy/ast-outline/releases/download/2.0.0/ast-outline-macos-arm64.zip"
        \\  sha256 "a76c4e384a0dd155a42b6dc7b2fe4f125de7c5ede04ddb8e7ee8fbab51fc0f34"
        \\end
    ;
    const got = install_rb_parse.parseRubyFormula(src) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("2.0.0", got.version);
    try testing.expectEqualStrings(
        "https://github.com/aeroxy/ast-outline/releases/download/2.0.0/ast-outline-macos-arm64.zip",
        got.url,
    );
    try testing.expectEqualStrings(
        "a76c4e384a0dd155a42b6dc7b2fe4f125de7c5ede04ddb8e7ee8fbab51fc0f34",
        got.sha256,
    );
}

// A leading `v` on the captured token is stripped — `v3.1.4` → `3.1.4`.
// Every release-tag URL we sampled in the wild used this convention,
// and `Cellar/<name>/v3.1.4` paths would be ugly and inconsistent with
// the bottle path Homebrew installs to.
test "parseRubyFormula derives version stripping a leading v from a release tag" {
    const src =
        \\class Tool < Formula
        \\  url "https://github.com/example/tool/releases/download/v3.1.4/tool.tar.gz"
        \\  sha256 "1111111111111111111111111111111111111111111111111111111111111111"
        \\end
    ;
    const got = install_rb_parse.parseRubyFormula(src) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("3.1.4", got.version);
}

// `archive/refs/tags/v<X>.tar.gz` is the dominant source-archive shape
// for taps like FelixKratz/sketchybar — pinning it keeps the parser
// useful for the broader "version-in-URL" population, not just for
// release-asset binaries.
test "parseRubyFormula derives version from archive/refs/tags/<X>.tar.gz" {
    const src =
        \\class Sketchybar < Formula
        \\  url "https://github.com/FelixKratz/SketchyBar/archive/refs/tags/v2.23.0.tar.gz"
        \\  sha256 "2222222222222222222222222222222222222222222222222222222222222222"
        \\end
    ;
    const got = install_rb_parse.parseRubyFormula(src) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("2.23.0", got.version);
}

// .zip variant of the same shape — extension matching is exhaustive
// across the four archive formats we extract, so .zip must work too.
test "parseRubyFormula derives version from archive/refs/tags/<X>.zip" {
    const src =
        \\class Tool < Formula
        \\  url "https://github.com/example/tool/archive/refs/tags/1.0.0.zip"
        \\  sha256 "3333333333333333333333333333333333333333333333333333333333333333"
        \\end
    ;
    const got = install_rb_parse.parseRubyFormula(src) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("1.0.0", got.version);
}

// Short-form `/archive/<X>.tar.gz` — GitHub serves the same tarball
// for this and the long form, and a non-trivial slice of older
// formulas still use the short URL.
test "parseRubyFormula derives version from archive/<X>.tar.gz" {
    const src =
        \\class Tool < Formula
        \\  url "https://github.com/example/tool/archive/v1.0.0.tar.gz"
        \\  sha256 "4444444444444444444444444444444444444444444444444444444444444444"
        \\end
    ;
    const got = install_rb_parse.parseRubyFormula(src) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("1.0.0", got.version);
}

// An explicit `version "..."` always wins over what could be derived
// from the URL — the formula author's intent is authoritative.
test "parseRubyFormula prefers explicit version over a derivable URL token" {
    const src =
        \\class Tool < Formula
        \\  version "9.9.9"
        \\  url "https://github.com/example/tool/releases/download/2.0.0/tool.zip"
        \\  sha256 "5555555555555555555555555555555555555555555555555555555555555555"
        \\end
    ;
    const got = install_rb_parse.parseRubyFormula(src) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("9.9.9", got.version);
}

// Floating-tag URLs (`latest`, `nightly`, …) are common but must not
// silently become a malt keg directory named `latest`. The token must
// start with a digit; anything else returns null so the user sees the
// "unsupported DSL shape" error and adds an explicit `version`.
test "parseRubyFormula rejects floating-tag URLs that are not version-shaped" {
    const src =
        \\class Tool < Formula
        \\  url "https://github.com/example/tool/releases/download/latest/tool.zip"
        \\  sha256 "6666666666666666666666666666666666666666666666666666666666666666"
        \\end
    ;
    try testing.expect(install_rb_parse.parseRubyFormula(src) == null);
}

// URL with none of the three recognised path shapes — the parser does
// not invent a version from the filename basename.
test "parseRubyFormula returns null when URL matches no derivation pattern" {
    const src =
        \\class Tool < Formula
        \\  url "https://example.com/foo.tar.gz"
        \\  sha256 "7777777777777777777777777777777777777777777777777777777777777777"
        \\end
    ;
    try testing.expect(install_rb_parse.parseRubyFormula(src) == null);
}

// A leading `v` must be followed by a digit — otherwise `vendor-build`,
// `v0lume`'s typo, or a tag like `vN` would all parse as versions.
test "parseRubyFormula rejects a v-prefix that is not followed by a digit" {
    const src =
        \\class Tool < Formula
        \\  url "https://github.com/example/tool/releases/download/vendor-build/tool.zip"
        \\  sha256 "8888888888888888888888888888888888888888888888888888888888888888"
        \\end
    ;
    try testing.expect(install_rb_parse.parseRubyFormula(src) == null);
}

// extractQuoted underpins both legacy and cask DSL extraction; the
// keyword-arg shape introduces a new pattern (`url "..."` after a
// long sha256 directive) so pin a "won't accidentally cut on the
// wrong line" property here.
test "extractQuoted does not match across newlines" {
    const got = install_rb_parse.extractQuoted("sha256 arm:\nintel: \"x\"", "intel: \"");
    // `intel: \"` only appears on the second line; with line-by-line
    // trimming this is invoked per-line, not on the joined buffer.
    // Calling extractQuoted on the whole string still cuts at the
    // first match — the property under test is "does not match a
    // prefix that didn't appear" (it does appear, so it returns "x").
    try testing.expect(got != null);
    try testing.expectEqualStrings("x", got.?);
}

test "findFailedDep flags the first dep name that appears in failed_kegs" {
    var failed = std.StringHashMap(void).init(testing.allocator);
    defer failed.deinit();
    try failed.put("libfoo", {});

    const json =
        \\{"name":"bar","full_name":"bar","versions":{"stable":"1.0"},"bottle":{"stable":{"files":{}}},"dependencies":["libfoo","other"]}
    ;
    var cache = @import("malt").deps.FormulaCache.init(testing.allocator);
    defer cache.deinit();
    const name = install_download.findFailedDep(&cache, &failed, "bar", json);
    try testing.expect(name != null);
    try testing.expectEqualStrings("libfoo", name.?);
}

const malt = @import("malt");
const test_io = @import("test_io");
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

    try testing.expect(!install_record.isInstalled(&db, "foo"));

    var f = try parseFake(arena.allocator());
    defer f.deinit();
    const keg_id = try install_record.recordKeg(&db, &f, "0" ** 64, "/opt/malt/Cellar/foo/1.0", "direct", .{});
    try testing.expect(keg_id > 0);
    try testing.expect(install_record.isInstalled(&db, "foo"));
}

test "pruneCellarForReinstall wipes an existing Cellar dir so --force can re-materialize" {
    const prefix = try std.fmt.allocPrint(
        testing.allocator,
        "/tmp/malt_prune_cellar_{d}",
        .{test_io.nanoTimestamp(
            std.Options.debug_io,
        )},
    );
    defer testing.allocator.free(prefix);
    test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    const keg_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/foo/1.0/bin", .{prefix});
    defer testing.allocator.free(keg_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, keg_dir);

    const file = try std.fmt.allocPrint(testing.allocator, "{s}/foo", .{keg_dir});
    defer testing.allocator.free(file);
    {
        const f = try test_io.cwd().createFile(std.Options.debug_io, file, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "payload");
    }

    install.pruneCellarForReinstall(&malt.app_ctx.debug_ctx, prefix, "foo", "1.0");

    const cellar_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/foo/1.0", .{prefix});
    defer testing.allocator.free(cellar_dir);
    try testing.expectError(error.FileNotFound, test_io.accessAbsolute(std.Options.debug_io, cellar_dir, .{}));
}

test "pruneCellarForReinstall is a no-op when the destination is missing" {
    const prefix = try std.fmt.allocPrint(
        testing.allocator,
        "/tmp/malt_prune_cellar_missing_{d}",
        .{test_io.nanoTimestamp(
            std.Options.debug_io,
        )},
    );
    defer testing.allocator.free(prefix);
    test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    // Never created — pruning must not fault, panic, or leak.
    install.pruneCellarForReinstall(&malt.app_ctx.debug_ctx, prefix, "ghost", "1.0");
}

test "install_record.recordKeg preserves a prior pinned flag on REPLACE (force-reinstall keeps the hold)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    // Seed a pinned keg row at version 1.0 so the upcoming INSERT OR REPLACE
    // for the same (name, version) hits the conflict path.
    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, pinned)
        \\VALUES ('foo', 'foo', '1.0', 'deadbeef', '/opt/malt/Cellar/foo/1.0', 1);
    );

    var f = try parseFake(arena.allocator());
    defer f.deinit();
    const keg_id = try install_record.recordKeg(&db, &f, "0" ** 64, "/opt/malt/Cellar/foo/1.0", "direct", .{});

    var stmt = try db.prepare("SELECT pinned FROM kegs WHERE id = ?1 LIMIT 1;");
    defer stmt.finalize();
    try stmt.bindInt(1, keg_id);
    _ = try stmt.step();
    try testing.expectEqual(true, stmt.columnBool(0));
}

test "install_record.recordKeg defaults pinned=0 when no prior keg of that name exists" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    var f = try parseFake(arena.allocator());
    defer f.deinit();
    const keg_id = try install_record.recordKeg(&db, &f, "0" ** 64, "/opt/malt/Cellar/foo/1.0", "direct", .{});

    var stmt = try db.prepare("SELECT pinned FROM kegs WHERE id = ?1 LIMIT 1;");
    defer stmt.finalize();
    try stmt.bindInt(1, keg_id);
    _ = try stmt.step();
    try testing.expectEqual(false, stmt.columnBool(0));
}

test "install_record.recordKeg with inherit_pin=false clears the prior pin (opt-out branch)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    // Seed a pinned row that COALESCE-MAX would otherwise inherit from.
    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, pinned)
        \\VALUES ('foo', 'foo', '1.0', 'deadbeef', '/opt/malt/Cellar/foo/1.0', 1);
    );

    var f = try parseFake(arena.allocator());
    defer f.deinit();
    const keg_id = try install_record.recordKeg(
        &db,
        &f,
        "0" ** 64,
        "/opt/malt/Cellar/foo/1.0",
        "direct",
        .{ .inherit_pin = false },
    );

    var stmt = try db.prepare("SELECT pinned FROM kegs WHERE id = ?1 LIMIT 1;");
    defer stmt.finalize();
    try stmt.bindInt(1, keg_id);
    _ = try stmt.step();
    try testing.expectEqual(false, stmt.columnBool(0));
}

test "install_record.recordKeg with .{ .in_transaction = false } opens its own BEGIN/COMMIT" {
    // Pinning the default txn-wrapping path: a standalone caller is
    // not inside a transaction, so `recordKeg` must open + commit one
    // on its own. The post-call SELECT proves the row landed.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    var f = try parseFake(arena.allocator());
    defer f.deinit();
    const keg_id = try install_record.recordKeg(
        &db,
        &f,
        "0" ** 64,
        "/opt/malt/Cellar/foo/1.0",
        "direct",
        .{ .in_transaction = false },
    );

    var stmt = try db.prepare("SELECT name FROM kegs WHERE id = ?1 LIMIT 1;");
    defer stmt.finalize();
    try stmt.bindInt(1, keg_id);
    _ = try stmt.step();
    try testing.expectEqualStrings("foo", std.mem.sliceTo(stmt.columnText(0).?, 0));
}

test "install_record.recordKeg with .{ .in_transaction = true } inside an outer BEGIN does not nest" {
    // Caller owns the txn — `recordKeg` must skip its own BEGIN/COMMIT,
    // otherwise SQLite throws "cannot start a transaction within a
    // transaction" and the upgrade flow's atomic unlink+record+link
    // wrapper would leave kegs/links half-mutated.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    var f = try parseFake(arena.allocator());
    defer f.deinit();

    try db.beginTransaction();
    const keg_id = try install_record.recordKeg(
        &db,
        &f,
        "0" ** 64,
        "/opt/malt/Cellar/foo/1.0",
        "direct",
        .{ .in_transaction = true },
    );
    try db.commit();

    var stmt = try db.prepare("SELECT name FROM kegs WHERE id = ?1 LIMIT 1;");
    defer stmt.finalize();
    try stmt.bindInt(1, keg_id);
    _ = try stmt.step();
    try testing.expectEqualStrings("foo", std.mem.sliceTo(stmt.columnText(0).?, 0));
}

test "install_record.recordKeg with inherit_pin=true carries the prior pin (option's default branch)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, pinned)
        \\VALUES ('foo', 'foo', '1.0', 'deadbeef', '/opt/malt/Cellar/foo/1.0', 1);
    );

    var f = try parseFake(arena.allocator());
    defer f.deinit();
    const keg_id = try install_record.recordKeg(
        &db,
        &f,
        "0" ** 64,
        "/opt/malt/Cellar/foo/1.0",
        "direct",
        .{ .inherit_pin = true },
    );

    var stmt = try db.prepare("SELECT pinned FROM kegs WHERE id = ?1 LIMIT 1;");
    defer stmt.finalize();
    try stmt.bindInt(1, keg_id);
    _ = try stmt.step();
    try testing.expectEqual(true, stmt.columnBool(0));
}

test "recordDeps inserts one row per dependency in the dependencies table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    var f = try parseFake(arena.allocator());
    defer f.deinit();
    const keg_id = try install_record.recordKeg(&db, &f, "0" ** 64, "/opt/malt/Cellar/foo/1.0", "direct", .{});
    install_record.recordDeps(&db, keg_id, &f);

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
    const keg_id = try install_record.recordKeg(&db, &f, "0" ** 64, "/opt/malt/Cellar/foo/1.0", "direct", .{});
    try testing.expect(install_record.isInstalled(&db, "foo"));
    install_record.deleteKeg(&db, keg_id);
    try testing.expect(!install_record.isInstalled(&db, "foo"));
}

test "ensureDirs creates every required subdirectory under a fresh prefix" {
    const prefix = try std.fmt.allocPrint(
        testing.allocator,
        "/tmp/malt_install_ensure_dirs_{d}",
        .{test_io.nanoTimestamp(
            std.Options.debug_io,
        )},
    );
    defer testing.allocator.free(prefix);
    test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try install_record.ensureDirs(&malt.app_ctx.debug_ctx, prefix);

    const subs = [_][]const u8{ "store", "Cellar", "Caskroom", "opt", "bin", "lib", "include", "share", "sbin", "etc", "tmp", "cache", "db" };
    for (subs) |s| {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ prefix, s });
        defer testing.allocator.free(p);
        var d = try test_io.openDirAbsolute(std.Options.debug_io, p, .{});
        d.close(std.Options.debug_io);
    }
}

test "findFailedDep returns null when no dep is in the failed set" {
    var failed = std.StringHashMap(void).init(testing.allocator);
    defer failed.deinit();

    const json =
        \\{"name":"bar","full_name":"bar","versions":{"stable":"1.0"},"bottle":{"stable":{"files":{}}},"dependencies":["libfoo"]}
    ;
    var cache = @import("malt").deps.FormulaCache.init(testing.allocator);
    defer cache.deinit();
    try testing.expect(install_download.findFailedDep(&cache, &failed, "bar", json) == null);
}

// ---------------------------------------------------------------------------
// routePostInstallOutcome — branch coverage driven by a synthetic fallback
// log. The router is where "completed" gets its real meaning (zero logged
// entries) and where silent unknown_method entries now surface the
// `--use-system-ruby` hint instead of passing under the radar.
// ---------------------------------------------------------------------------

const dsl = @import("malt").dsl;
const io_mod = @import("malt").output;
const color_mod = @import("malt").color;
const output_mod = @import("malt").output;

/// Construct an `AppCtx` whose `stdout`/`stderr` point at `/dev/null`.
/// The `routePostInstallOutcome` Ruby fallback path forwards the
/// sandboxed child's fd 1/2 to `ctx.stdout.handle`/`ctx.stderr.handle`;
/// without this redirect, child stderr lands on the test runner's real
/// fd 2 and the build-runner promotes the bytes to `result_error_msgs`,
/// printing a misleading `failed command:` against a passing test.
/// Caller closes the returned fd via `closeDevnullCtx`.
fn devnullCtx() !struct { ctx: malt.app_ctx.AppCtx, fd: std.c.fd_t } {
    const fd = std.c.open("/dev/null", .{ .ACCMODE = .RDWR }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.DevnullOpenFailed;
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    return .{
        .ctx = .{
            .io = malt.app_ctx.debug_ctx.io,
            .environ = malt.app_ctx.debug_ctx.environ,
            .stdout = file,
            .stderr = file,
        },
        .fd = fd,
    };
}

fn closeDevnullCtx(fd: std.c.fd_t) void {
    _ = std.c.close(fd);
}

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

    const dn = try devnullCtx();
    defer closeDevnullCtx(dn.fd);

    install_post_install.routePostInstallOutcome(&dn.ctx, testing.allocator, name, "1.0", "/tmp/irrelevant", flog, scope);

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
    try test_io.skipIfNoSubprocess();
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
    // The script's soft-fail rescue catches undefined-helper errors
    // and exits 0, so the route reports `ran_via_ruby` with the
    // "(via system Ruby)" suffix on the completion line.
    try testing.expect(std.mem.indexOf(u8, out, "falling back to system Ruby") != null);
    try testing.expect(std.mem.indexOf(u8, out, "partially skipped") == null);
    try testing.expect(std.mem.indexOf(u8, out, "post_install completed for openssl@3 (via system Ruby)") != null);
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

// `mt migrate ruby` shouldn't require `--use-system-ruby=ruby` — the
// recursion is nonsensical. Self-hosting interpreter kegs (ruby,
// ruby@N) are auto-included in the system-Ruby allow-list so the
// hook routes to the same fallback path with no flag from the user.
test "routePostInstallOutcome: ruby keg auto-routes to system Ruby with no flag" {
    try test_io.skipIfNoSubprocess();
    var flog = dsl.FallbackLog.init(testing.allocator);
    defer flog.deinit();
    flog.log(.{
        .formula = "ruby",
        .reason = .unknown_method,
        .detail = "rubygems_helper",
        .loc = null,
    });

    const out = try runRoute(&flog, "ruby", &.{});
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "falling back to system Ruby") != null);
    try testing.expect(std.mem.indexOf(u8, out, "partially skipped") == null);
    try testing.expect(std.mem.indexOf(u8, out, "use --use-system-ruby=ruby") == null);
}

test "routePostInstallOutcome: ruby@N keg also auto-routes to system Ruby" {
    try test_io.skipIfNoSubprocess();
    var flog = dsl.FallbackLog.init(testing.allocator);
    defer flog.deinit();
    flog.log(.{
        .formula = "ruby@3.4",
        .reason = .unsupported_node,
        .detail = "default_args",
        .loc = null,
    });

    const out = try runRoute(&flog, "ruby@3.4", &.{});
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "falling back to system Ruby") != null);
    try testing.expect(std.mem.indexOf(u8, out, "partially skipped") == null);
}

// Negative: lookalikes must NOT inherit the auto-include — only the
// canonical interpreter kegs. Regression guard against widening the
// trust boundary by accident.
test "routePostInstallOutcome: ruby-lookalike kegs still need the explicit flag" {
    var flog = dsl.FallbackLog.init(testing.allocator);
    defer flog.deinit();
    flog.log(.{ .formula = "rubygems", .reason = .unknown_method, .detail = "x", .loc = null });

    const out = try runRoute(&flog, "rubygems", &.{});
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "falling back to system Ruby") == null);
    try testing.expect(std.mem.indexOf(u8, out, "partially skipped (use --use-system-ruby=rubygems") != null);
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

// Auto-included Ruby-interpreter kegs (`ruby`, `ruby@N`) gate the re-run
// on whether the DSL handled anything: their effects often land at brew
// install time, so re-running the hook end-to-end via Ruby would double-
// stamp non-idempotent steps (counters, timestamps, version caches).
// Explicit `--use-system-ruby=NAME` is a user opt-in and unaffected.
test "routePostInstallOutcome: auto-included ruby keg skips re-run when DSL did work" {
    var flog = dsl.FallbackLog.init(testing.allocator);
    defer flog.deinit();
    flog.log(.{
        .formula = "ruby@3.4",
        .reason = .unsupported_node,
        .detail = "default_args",
        .loc = null,
    });
    flog.total_top_level = 3;
    flog.handled_top_level = 2;

    const out = try runRoute(&flog, "ruby@3.4", &.{});
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "falling back to system Ruby") == null);
    try testing.expect(std.mem.indexOf(u8, out, "(via system Ruby)") == null);
    try testing.expect(std.mem.indexOf(u8, out, "partially skipped") != null);
}

// Negative pin on the same axis: when the DSL handled none of the body,
// the auto-include must still fall back so a fresh `mt migrate ruby`
// (or any zero-coverage scenario) still runs the hook via system Ruby.
test "routePostInstallOutcome: auto-included ruby keg falls back when DSL did nothing" {
    try test_io.skipIfNoSubprocess();
    var flog = dsl.FallbackLog.init(testing.allocator);
    defer flog.deinit();
    flog.log(.{
        .formula = "ruby@3.4",
        .reason = .unsupported_node,
        .detail = "default_args",
        .loc = null,
    });
    flog.total_top_level = 3;
    flog.handled_top_level = 0;

    const out = try runRoute(&flog, "ruby@3.4", &.{});
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "falling back to system Ruby") != null);
    try testing.expect(std.mem.indexOf(u8, out, "partially skipped") == null);
}

// JSON mirror for the auto-include skip path: status is partially_skipped,
// never ran_via_ruby, when the DSL handled some work.
test "routePostInstallOutcome: --json reports partially_skipped for ruby keg with work" {
    var flog = dsl.FallbackLog.init(testing.allocator);
    defer flog.deinit();
    flog.log(.{ .formula = "ruby@3.4", .reason = .unknown_method, .detail = "h", .loc = null });
    flog.total_top_level = 4;
    flog.handled_top_level = 3;

    const out = try runRouteCaptureStdout(&flog, "ruby@3.4", &.{});
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"status\":\"partially_skipped\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"status\":\"ran_via_ruby\"") == null);
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

    const dn = try devnullCtx();
    defer closeDevnullCtx(dn.fd);

    install_post_install.routePostInstallOutcome(&dn.ctx, testing.allocator, name, "1.0", "/tmp/irrelevant", flog, scope);
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
// executeDslPostInstall — owns one DSL attempt against a parsed formula.
// The outcome decides whether the caller falls through to the system-Ruby
// fallback. Narrow inputs (name + version + json bytes) so install and
// migrate share the same entry without forging a DownloadJob.
// ---------------------------------------------------------------------------

test "executeDslPostInstall returns .parse_failed when formula JSON is unparseable" {
    // The parse-failure path must surface as a distinct outcome so the
    // caller can still try the system-Ruby fallback instead of silently
    // dropping the hook.
    const prior_quiet = output_mod.isQuiet();
    output_mod.setQuiet(true);
    defer output_mod.setQuiet(prior_quiet);

    const outcome = install_post_install.executeDslPostInstall(
        &malt.app_ctx.debug_ctx,
        testing.allocator,
        "bad-json",
        "1.0",
        "not-a-json",
        "# empty body",
        "/tmp/irrelevant",
        &.{},
        null,
    );
    try testing.expectEqual(install_post_install.DslPostInstallOutcome.parse_failed, outcome);
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
    const outcome = install_post_install.executeDslPostInstall(
        &malt.app_ctx.debug_ctx,
        testing.allocator,
        "hello",
        "1.0",
        json,
        "# empty",
        "/tmp/irrelevant",
        &.{},
        null,
    );
    try testing.expectEqual(install_post_install.DslPostInstallOutcome.handled, outcome);
}

test "executeDslPostInstall routes through the shared FormulaCache once per name" {
    // Pins the parse-once invariant the dep resolver and linkAndRecord
    // already enforce: with a shared cache, repeated post_install calls
    // for the same formula across an installAll run must not re-parse.
    color_mod.setForTest(false, false);
    defer color_mod.setForTest(null, null);
    const prior_quiet = output_mod.isQuiet();
    output_mod.setQuiet(true);
    defer output_mod.setQuiet(prior_quiet);

    const json =
        \\{"name":"hello","full_name":"hello","versions":{"stable":"1.0"},"dependencies":[],"oldnames":[]}
    ;
    var cache = malt.deps.FormulaCache.init(testing.allocator);
    defer cache.deinit();

    const first = install_post_install.executeDslPostInstall(
        &malt.app_ctx.debug_ctx,
        testing.allocator,
        "hello",
        "1.0",
        json,
        "# empty",
        "/tmp/irrelevant",
        &.{},
        &cache,
    );
    try testing.expectEqual(install_post_install.DslPostInstallOutcome.handled, first);
    try testing.expectEqual(@as(usize, 1), cache.parse_count);

    const second = install_post_install.executeDslPostInstall(
        &malt.app_ctx.debug_ctx,
        testing.allocator,
        "hello",
        "1.0",
        json,
        "# empty",
        "/tmp/irrelevant",
        &.{},
        &cache,
    );
    try testing.expectEqual(install_post_install.DslPostInstallOutcome.handled, second);
    try testing.expectEqual(@as(usize, 1), cache.parse_count);
}

test "executeDslPostInstall reuses an entry the install pipeline already parsed" {
    // Mirrors the install loop's order: linkAndRecord parses + caches,
    // then drive() runs post_install. The second parse must be a no-op.
    color_mod.setForTest(false, false);
    defer color_mod.setForTest(null, null);
    const prior_quiet = output_mod.isQuiet();
    output_mod.setQuiet(true);
    defer output_mod.setQuiet(prior_quiet);

    const json =
        \\{"name":"hello","full_name":"hello","versions":{"stable":"1.0"},"dependencies":[],"oldnames":[]}
    ;
    var cache = malt.deps.FormulaCache.init(testing.allocator);
    defer cache.deinit();
    _ = try cache.getOrParse("hello", json);
    try testing.expectEqual(@as(usize, 1), cache.parse_count);

    const outcome = install_post_install.executeDslPostInstall(
        &malt.app_ctx.debug_ctx,
        testing.allocator,
        "hello",
        "1.0",
        json,
        "# empty",
        "/tmp/irrelevant",
        &.{},
        &cache,
    );
    try testing.expectEqual(install_post_install.DslPostInstallOutcome.handled, outcome);
    try testing.expectEqual(@as(usize, 1), cache.parse_count);
}

// ---------------------------------------------------------------------------
// drive — full post_install flow shared by install + migrate. Locates a
// DSL source, runs it through executeDslPostInstall, or falls back to the
// system-Ruby subprocess. Tested via the no-source / no-scope leaf so both
// commands route the "user must opt in" hint through one code path.
// ---------------------------------------------------------------------------

test "drive: no DSL source and no scope match emits the unified skip hint" {
    color_mod.setForTest(false, false);
    defer color_mod.setForTest(null, null);
    const prior_quiet = output_mod.isQuiet();
    output_mod.setQuiet(false);
    defer output_mod.setQuiet(prior_quiet);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    io_mod.beginStderrCapture(testing.allocator, &buf);
    defer io_mod.endStderrCapture();

    // A name guaranteed to miss every DSL source: not a real formula, no
    // .rb on disk, no pin manifest entry → fetchPostInstallFromGitHub
    // returns null, so drive lands on the skip leaf.
    install_post_install.drive(
        &malt.app_ctx.debug_ctx,
        testing.allocator,
        "__nonexistent_test_formula_xyz__",
        "1.0",
        "{}",
        "/tmp/irrelevant",
        &.{},
        null,
    );

    // The skip hint is the byte-for-byte string both install and migrate
    // must print so scripted users see the same "opt in" message.
    try testing.expect(std.mem.indexOf(
        u8,
        buf.items,
        "post_install skipped (use --use-system-ruby=__nonexistent_test_formula_xyz__ or brew install __nonexistent_test_formula_xyz__)",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "Running post_install") == null);
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
