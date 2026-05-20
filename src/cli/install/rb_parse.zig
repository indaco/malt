//! Pure Ruby-formula / cask-DSL textual parser used by the tap and
//! local install paths. No allocator threading, no I/O — operates on
//! the in-memory `.rb` body and returns slices into the caller's buffer.
//! Split out of `cli/install/local.zig` so importers that only want
//! parsing (outdated, upgrade) no longer pay for orchestration's
//! compile cost.

const std = @import("std");
const cask_mod = @import("../../core/cask.zig");

/// Post-parse payload shared by the tap and local-file install paths.
/// Slices point into the caller-owned `.rb` content and must outlive
/// the caller's use of this struct.
pub const RubyFormulaInfo = struct {
    version: []const u8,
    url: []const u8,
    sha256: []const u8,
    /// Empty by default. Populated only when the cask DSL set `arch`
    /// keyword-argument values for the current platform (typically a
    /// short suffix like `-aarch64` for arm and `""` for intel).
    arch_token: []const u8 = "",
};

/// Suffix strings the parser recognises when deriving a version from a
/// tag-in-URL formula. Kept in sync with orchestration's separate
/// `(suffix, kind)` table in `local.zig`: adding a new archive format
/// requires updating both, but each table represents a different
/// concern (parsing vs extractor dispatch).
const tap_archive_suffixes = [_][]const u8{
    ".tar.gz",
    ".tgz",
    ".tar.xz",
    ".zip",
};

/// Minimal Ruby formula parser for GoReleaser-style formulas plus the
/// modern Homebrew cask DSL. Extracts version, URL, SHA256 — and, for
/// casks that interpolate `#{arch}` into the URL, the per-platform arch
/// suffix captured from the `arch arm: "...", intel: "..."` directive.
pub fn parseRubyFormula(rb_content: []const u8) ?RubyFormulaInfo {
    const is_arm = @import("../../macho/codesign.zig").isArm64();

    var version: ?[]const u8 = null;
    var url: ?[]const u8 = null;
    var sha256: ?[]const u8 = null;
    var arch_token: []const u8 = "";

    // The state machine recognises two layouts:
    //   * Classic: each platform has its own `Hardware::CPU.*` /
    //     `on_arm` / `on_intel` block carrying url + sha256 lines.
    //   * Cask DSL multi-arch: a single `on_macos` block holds
    //     keyword-arg directives — `arch arm: "...", intel: "..."`,
    //     `sha256 arm: "...", intel: "..."`, and a url that
    //     interpolates `#{arch}`.
    var in_correct_section = false;
    var in_macos = false;
    var prev_in_kwarg_sha256 = false;

    var line_start: usize = 0;
    for (rb_content, 0..) |ch, idx| {
        if (ch == '\n' or idx == rb_content.len - 1) {
            const line_end = if (ch == '\n') idx else idx + 1;
            const line = std.mem.trim(u8, rb_content[line_start..line_end], " \t\r");
            line_start = idx + 1;

            // Extract version (global)
            if (version == null) {
                if (extractQuoted(line, "version \"")) |v| {
                    version = v;
                }
            }

            // Track on_macos block. The cask DSL uses this as the only
            // platform gate, so being inside it is enough to consume
            // url + arch + multi-arch sha256 directives.
            if (std.mem.indexOf(u8, line, "on_macos") != null) {
                in_macos = true;
                in_correct_section = true;
            }

            // Track CPU section (Formula style: Hardware::CPU, Cask style: on_arm/on_intel)
            if (in_macos) {
                if (is_arm and (std.mem.indexOf(u8, line, "Hardware::CPU.arm?") != null or
                    std.mem.indexOf(u8, line, "on_arm") != null))
                {
                    in_correct_section = true;
                } else if (!is_arm and (std.mem.indexOf(u8, line, "Hardware::CPU.intel?") != null or
                    std.mem.indexOf(u8, line, "on_intel") != null))
                {
                    in_correct_section = true;
                }
            }

            // arch directive — only meaningful inside on_macos.
            if (in_macos and arch_token.len == 0 and std.mem.startsWith(u8, line, "arch ")) {
                arch_token = pickKwArg(line["arch ".len..], is_arm) orelse arch_token;
            }

            // Multi-arch sha256: the directive may span two lines
            // (`sha256 arm: "...", \n  intel: "..."`). Track whether the
            // previous trimmed line opened a `sha256` directive so the
            // continuation line can still pick the platform value.
            if (in_macos and sha256 == null) {
                if (std.mem.startsWith(u8, line, "sha256 ")) {
                    const body = line["sha256 ".len..];
                    if (lineStartsWithKwArg(body)) {
                        if (pickKwArg(body, is_arm)) |s| sha256 = s;
                        prev_in_kwarg_sha256 = sha256 == null;
                    }
                } else if (prev_in_kwarg_sha256) {
                    if (pickKwArg(line, is_arm)) |s| sha256 = s;
                    // Continuation lines never re-open the directive — a
                    // missed match means the second arg is the one we
                    // didn't want, so stop hunting for more.
                    prev_in_kwarg_sha256 = false;
                } else prev_in_kwarg_sha256 = false;
            } else prev_in_kwarg_sha256 = false;

            // Extract URL and SHA256 within the correct section
            if (in_correct_section) {
                if (url == null) {
                    if (extractQuoted(line, "url \"")) |u| {
                        url = u;
                    }
                }
                if (sha256 == null) {
                    if (extractQuoted(line, "sha256 \"")) |s| {
                        sha256 = s;
                    }
                }
            }

            // If we have both, stop
            if (url != null and sha256 != null) break;
        }
    }

    // Fallback: if no CPU-specific section found, try global url/sha256
    if (url == null or sha256 == null) {
        var ls: usize = 0;
        for (rb_content, 0..) |ch, idx| {
            if (ch == '\n' or idx == rb_content.len - 1) {
                const le = if (ch == '\n') idx else idx + 1;
                const ln = std.mem.trim(u8, rb_content[ls..le], " \t\r");
                ls = idx + 1;

                if (url == null) {
                    if (extractQuoted(ln, "url \"")) |u| url = u;
                }
                if (sha256 == null) {
                    if (extractQuoted(ln, "sha256 \"")) |s| sha256 = s;
                }
            }
        }
    }

    if (url != null and sha256 != null) {
        // Homebrew treats `version` as optional when the tag is encoded
        // in the URL. Mirror that: derive it from the release-asset or
        // archive-tag path so common tap shapes (top-level url+sha256,
        // no `version` line) still install.
        const final_version = version orelse deriveVersionFromUrl(url.?) orelse return null;
        return .{
            .version = final_version,
            .url = url.?,
            .sha256 = sha256.?,
            .arch_token = arch_token,
        };
    }
    return null;
}

/// Pull a version token out of a Homebrew-style URL when the formula
/// omits `version "..."`. Covers the three shapes Homebrew itself
/// derives from:
///   * `…/releases/download/<X>/…`              — release asset
///   * `…/archive/refs/tags/<X>.<archive-ext>`  — git tag tarball
///   * `…/archive/<X>.<archive-ext>`            — short-form tag tarball
/// Returns null when no pattern matches or the captured token does not
/// look like a version (must start with a digit, optionally after a
/// single `v`/`V`). The strict check stops malt from inventing a
/// version like `latest` or `nightly` for a floating-tag URL.
fn deriveVersionFromUrl(url: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, url, "/releases/download/")) |pos| {
        const after = url[pos + "/releases/download/".len ..];
        const slash = std.mem.indexOfScalar(u8, after, '/') orelse return null;
        return validateVersionToken(after[0..slash]);
    }

    if (std.mem.indexOf(u8, url, "/archive/refs/tags/")) |pos| {
        const after = url[pos + "/archive/refs/tags/".len ..];
        return stripArchiveSuffixThenValidate(after);
    }

    if (std.mem.indexOf(u8, url, "/archive/")) |pos| {
        const after = url[pos + "/archive/".len ..];
        // Nested paths belong to the `/archive/refs/tags/` shape, which
        // would already have matched above — anything still containing
        // a slash here is not a version token.
        if (std.mem.indexOfScalar(u8, after, '/') != null) return null;
        return stripArchiveSuffixThenValidate(after);
    }

    return null;
}

/// Strip any accepted tap-archive suffix from `tail` and run the
/// result through `validateVersionToken`. Returns null when no
/// recognised suffix matches — keeps the suffix list in lockstep with
/// `tap_archive_suffixes` so adding a format wires up version
/// derivation automatically.
fn stripArchiveSuffixThenValidate(tail: []const u8) ?[]const u8 {
    for (tap_archive_suffixes) |suffix| {
        if (std.mem.endsWith(u8, tail, suffix)) {
            return validateVersionToken(tail[0 .. tail.len - suffix.len]);
        }
    }
    return null;
}

/// Strip an optional leading `v`/`V` and confirm the next byte is a
/// digit. Reject anything else so a tag like `latest`, `nightly`, or
/// `release-2.0.0` never becomes a malt `Cellar/<name>/<version>`
/// path. Returns the trimmed slice or null on rejection.
fn validateVersionToken(s: []const u8) ?[]const u8 {
    if (s.len == 0) return null;
    if (s[0] == 'v' or s[0] == 'V') {
        if (s.len < 2 or !std.ascii.isDigit(s[1])) return null;
        return s[1..];
    }
    if (!std.ascii.isDigit(s[0])) return null;
    return s;
}

/// True when the trimmed line body starts with a keyword argument the
/// cask DSL uses for per-arch dispatch (`arm:` or `intel:`, possibly
/// with whitespace before the value). The trailing whitespace check
/// avoids matching a key prefix like `armadillo:`.
fn lineStartsWithKwArg(body: []const u8) bool {
    if (std.mem.startsWith(u8, body, "arm:")) return true;
    if (std.mem.startsWith(u8, body, "intel:")) return true;
    return false;
}

/// Pick the per-platform value out of a cask DSL keyword-arg body.
/// Accepts both spellings (`arm:` / `intel:`) on either side of a comma
/// and tolerates the variable run of whitespace casks use to align the
/// values vertically. Returns null when the platform's key is absent.
fn pickKwArg(body: []const u8, is_arm: bool) ?[]const u8 {
    const key = if (is_arm) "arm:" else "intel:";
    var rest = body;
    while (std.mem.indexOf(u8, rest, key)) |pos| {
        // Anchor on a word boundary so `arm:` does not match inside
        // `armadillo:` (hypothetical, but cheap to defend against).
        const before_ok = pos == 0 or rest[pos - 1] == ' ' or rest[pos - 1] == '\t' or rest[pos - 1] == ',';
        if (!before_ok) {
            rest = rest[pos + key.len ..];
            continue;
        }
        var after = rest[pos + key.len ..];
        // Skip the spaces casks insert between key and value for
        // vertical alignment.
        while (after.len > 0 and (after[0] == ' ' or after[0] == '\t')) after = after[1..];
        if (after.len == 0 or after[0] != '"') return null;
        const value, _ = std.mem.cut(u8, after[1..], "\"") orelse return null;
        return value;
    }
    return null;
}

pub fn extractQuoted(line: []const u8, prefix: []const u8) ?[]const u8 {
    _, const after = std.mem.cut(u8, line, prefix) orelse return null;
    const body, _ = std.mem.cut(u8, after, "\"") orelse return null;
    return body;
}

/// Pull the first argument of a cask `binary "<name>"` directive.
/// Homebrew's cask DSL promotes that file to `$PREFIX/bin/<name>`, so
/// tap casks whose archive binary does not match the cask token
/// (e.g. `longbridge-terminal` ships a `longbridge` binary) need this
/// override to land a working symlink. Returns null for formulas or
/// casks that omit the directive. Anchored to the trimmed line start
/// so a stray mention in a comment or `desc` string does not match.
pub fn parseCaskBinary(rb_content: []const u8) ?[]const u8 {
    var line_start: usize = 0;
    for (rb_content, 0..) |ch, idx| {
        if (ch != '\n' and idx != rb_content.len - 1) continue;
        const line_end = if (ch == '\n') idx else idx + 1;
        const line = std.mem.trim(u8, rb_content[line_start..line_end], " \t\r");
        line_start = idx + 1;
        if (!std.mem.startsWith(u8, line, "binary \"")) continue;
        if (extractQuoted(line, "binary \"")) |b| return b;
    }
    return null;
}

/// Pull the first argument of a cask `app "<X>.app"` directive. The
/// cask installer promotes that bundle into the chosen Applications
/// directory; absence flips a `.zip` URL away from the cask path so a
/// formula bottle is still extracted into the Cellar.
pub fn parseCaskApp(rb_content: []const u8) ?[]const u8 {
    var line_start: usize = 0;
    for (rb_content, 0..) |ch, idx| {
        if (ch != '\n' and idx != rb_content.len - 1) continue;
        const line_end = if (ch == '\n') idx else idx + 1;
        const line = std.mem.trim(u8, rb_content[line_start..line_end], " \t\r");
        line_start = idx + 1;
        if (!std.mem.startsWith(u8, line, "app \"")) continue;
        if (extractQuoted(line, "app \"")) |a| return a;
    }
    return null;
}

/// Decide whether a tap-DSL URL should route through the cask installer.
/// `.dmg` and `.pkg` are always cask formats. `.zip` is ambiguous so it
/// only flips when the DSL ships an `app "<X>.app"` directive — otherwise
/// the archive flows down the keg-extract path as before. Reusing
/// `cask.artifactTypeFromUrl` keeps suffix/query parsing in one place
/// and turns this into an exhaustive switch — adding a new ArtifactType
/// variant later is a compile error here until the policy is decided.
pub fn tapCaskArtifactKind(url: []const u8, has_app: bool) ?cask_mod.ArtifactType {
    return switch (cask_mod.artifactTypeFromUrl(url)) {
        .dmg => .dmg,
        .pkg => .pkg,
        .zip => if (has_app) .zip else null,
        .tar_gz, .unknown => null,
    };
}

test "parseRubyFormula: extracts version/url/sha256 from a flat formula" {
    const src =
        \\class Foo < Formula
        \\  url "https://example.com/foo-1.2.3.tar.gz"
        \\  sha256 "deadbeef"
        \\  version "1.2.3"
        \\end
    ;
    const got = parseRubyFormula(src) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("1.2.3", got.version);
    try std.testing.expectEqualStrings("https://example.com/foo-1.2.3.tar.gz", got.url);
    try std.testing.expectEqualStrings("deadbeef", got.sha256);
}

test "parseRubyFormula: returns null when required fields are missing" {
    try std.testing.expect(parseRubyFormula("class X end") == null);
}

test "parseRubyFormula: derives version from /releases/download/ URL" {
    const src =
        \\class Foo < Formula
        \\  url "https://github.com/foo/bar/releases/download/v2.4.0/bar.tar.gz"
        \\  sha256 "deadbeef"
        \\end
    ;
    const got = parseRubyFormula(src) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("2.4.0", got.version);
}

test "extractQuoted: extracts between prefix and the next quote" {
    const got = extractQuoted("version \"1.2.3\"", "version \"") orelse
        return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("1.2.3", got);
}

test "extractQuoted: returns null when the prefix is absent" {
    try std.testing.expect(extractQuoted("something else", "version \"") == null);
}

test "parseCaskBinary: extracts the basic binary directive" {
    const rb =
        \\cask "demo" do
        \\  binary "longbridge"
        \\end
    ;
    try std.testing.expectEqualStrings("longbridge", parseCaskBinary(rb).?);
}

test "parseCaskBinary: returns null on formulas with no binary directive" {
    const rb =
        \\class Foo < Formula
        \\  url "https://example.com/foo.tar.gz"
        \\end
    ;
    try std.testing.expect(parseCaskBinary(rb) == null);
}

test "parseCaskApp: extracts the .app bundle name" {
    const rb =
        \\cask "deck" do
        \\  url "https://example.com/deck.dmg"
        \\  app "Deck.app"
        \\end
    ;
    try std.testing.expectEqualStrings("Deck.app", parseCaskApp(rb).?);
}

test "parseCaskApp: returns null on formulas with no app directive" {
    const rb =
        \\class Foo < Formula
        \\  url "https://example.com/foo.tar.gz"
        \\end
    ;
    try std.testing.expect(parseCaskApp(rb) == null);
}

test "tapCaskArtifactKind: .dmg URLs always route to the cask installer" {
    try std.testing.expectEqual(
        cask_mod.ArtifactType.dmg,
        tapCaskArtifactKind("https://example.com/Tool.dmg", false).?,
    );
}

test "tapCaskArtifactKind: .pkg URLs always route to the cask installer" {
    try std.testing.expectEqual(
        cask_mod.ArtifactType.pkg,
        tapCaskArtifactKind("https://example.com/Tool.pkg", false).?,
    );
}

test "tapCaskArtifactKind: .zip routes only when an app directive is set" {
    try std.testing.expect(tapCaskArtifactKind("https://example.com/tool.zip", false) == null);
    try std.testing.expectEqual(
        cask_mod.ArtifactType.zip,
        tapCaskArtifactKind("https://example.com/Tool.zip", true).?,
    );
}

test "tapCaskArtifactKind: tar.gz formula archives stay on the keg path" {
    try std.testing.expect(tapCaskArtifactKind("https://example.com/tool.tar.gz", false) == null);
    try std.testing.expect(tapCaskArtifactKind("https://example.com/tool.tgz", true) == null);
    try std.testing.expect(tapCaskArtifactKind("https://example.com/tool.tar.xz", false) == null);
}
