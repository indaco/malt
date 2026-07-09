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
    /// Homebrew `revision N` (0 when absent). Lets the outdated audit detect a
    /// revision-only bump on a tap formula, matching the core path.
    revision: i64 = 0,
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
    var revision: i64 = 0;
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
    // Formula is arch-segmented — disarms the arch-blind global fallback so it
    // can't resolve the other arch's self-consistent (checksum-passing) pair.
    var saw_arch_marker = false;

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

            // Extract `revision N` (global, unquoted integer). Ignored by the
            // install path; the outdated audit uses it to spot revision bumps.
            if (revision == 0 and std.mem.startsWith(u8, line, "revision ")) {
                const rest = std.mem.trim(u8, line["revision ".len..], " \t");
                revision = std.fmt.parseInt(i64, rest, 10) catch 0;
            }

            // Track on_macos block. The cask DSL uses this as the only
            // platform gate, so being inside it is enough to consume
            // url + arch + multi-arch sha256 directives.
            if (std.mem.indexOf(u8, line, "on_macos") != null) {
                in_macos = true;
                in_correct_section = true;
            }

            // CPU section (Hardware::CPU / on_arm / on_intel). Not gated on
            // `on_macos`: these markers also appear at top level, and missing
            // them there is what let a wrong-arch pair reach the fallback.
            // `on_*` is anchored to the line start (block opener) so the token
            // in a `desc`/comment string never mis-flags a flat formula.
            const has_arm = std.mem.startsWith(u8, line, "on_arm") or
                std.mem.indexOf(u8, line, "Hardware::CPU.arm?") != null;
            const has_intel = std.mem.startsWith(u8, line, "on_intel") or
                std.mem.indexOf(u8, line, "Hardware::CPU.intel?") != null;
            // Each arch marker re-scopes the section to whether the block is
            // ours. Without `end` tracking the flag is otherwise sticky, so a
            // non-matching block (or the first block under `on_macos` on the
            // other arch) would leak its url/sha256 across the boundary.
            if (has_arm or has_intel) {
                saw_arch_marker = true;
                in_correct_section = (is_arm and has_arm) or (!is_arm and has_intel);
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

    // Global url/sha256 fallback. Skip when an arch-segmented formula yielded
    // NEITHER field for our arch — else it grabs the whole other-arch pair.
    // A partial block (our url + a shared global sha256) still completes.
    if ((url == null or sha256 == null) and !(saw_arch_marker and url == null and sha256 == null)) {
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
            .revision = revision,
            .url = url.?,
            .sha256 = sha256.?,
            .arch_token = arch_token,
        };
    }
    return null;
}

/// Pull a version token out of a forge URL when the formula omits
/// `version "..."`. Covers the shapes GitHub, GitLab, and Gitea/Forgejo
/// encode the tag in:
///   * `…/releases/download/<X>/…`              — GitHub release asset
///   * `…/-/archive/<X>/<file>`                 — GitLab archive
///   * `…/-/releases/<X>/downloads/…`           — GitLab release asset
///   * `…/archive/refs/tags/<X>.<archive-ext>`  — GitHub git tag tarball
///   * `…/archive/<X>.<archive-ext>`            — short-form tag tarball (Gitea)
/// Returns null when no pattern matches or the captured token does not
/// look like a version (must start with a digit, optionally after a
/// single `v`/`V`). The strict check stops malt from inventing a
/// version like `latest` or `nightly` for a floating-tag URL.
fn deriveVersionFromUrl(url: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, url, "/releases/download/")) |pos| {
        return firstPathSegmentVersion(url[pos + "/releases/download/".len ..]);
    }

    // GitLab archive: `/-/archive/<ref>/<name>-<ref>.<ext>`. The ref is
    // the first path segment; the filename repeats it, so read up to the
    // next slash rather than suffix-stripping the filename. Must precede
    // the generic `/archive/` branch, whose nested-slash guard would
    // otherwise reject this shape (it contains `/archive/` as a substring).
    if (std.mem.indexOf(u8, url, "/-/archive/")) |pos| {
        return firstPathSegmentVersion(url[pos + "/-/archive/".len ..]);
    }

    // GitLab release asset: `/-/releases/<tag>/downloads/<asset>`.
    if (std.mem.indexOf(u8, url, "/-/releases/")) |pos| {
        return firstPathSegmentVersion(url[pos + "/-/releases/".len ..]);
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

    // No path marker carried the tag: fall back to the bare filename.
    return versionFromFilename(url);
}

/// Last-resort derivation for a self-hosted release whose version lives only
/// in the filename (`…/tool-1.2.3.tar.gz`, `…/tool_1.2.3_amd64.zip`) with no
/// `/archive/` or `/releases/` marker. Strip a known archive suffix, split
/// the stem on `-`/`_`, and accept a version only when EXACTLY one token is
/// an unambiguous dotted version. Zero or several such tokens → null, so a
/// digit-led name (`7zip`) or a multi-version filename never mis-derives —
/// a wrong version is worse than none (it fakes an "outdated").
fn versionFromFilename(url: []const u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, url, '/') orelse return null;
    const filename = url[slash + 1 ..];

    const stem = for (tap_archive_suffixes) |suffix| {
        if (std.mem.endsWith(u8, filename, suffix))
            break filename[0 .. filename.len - suffix.len];
    } else return null;

    var found: ?[]const u8 = null;
    var it = std.mem.tokenizeAny(u8, stem, "-_");
    while (it.next()) |tok| {
        const ver = strictVersionToken(tok) orelse continue;
        if (found != null) return null; // >1 version-like token → ambiguous
        found = ver;
    }
    return found;
}

/// Stricter than `validateVersionToken`: the *whole* token must read as a
/// dotted version (`v?` then only digits and dots). Used when guessing a
/// version out of a bare filename, where the loose first-byte check would
/// misread a name segment like `7zip` as a version. Returns the v-stripped
/// token or null.
fn strictVersionToken(s: []const u8) ?[]const u8 {
    var body = s;
    if (body.len > 0 and (body[0] == 'v' or body[0] == 'V')) body = body[1..];
    if (body.len == 0 or !std.ascii.isDigit(body[0])) return null;
    for (body) |c| {
        if (!std.ascii.isDigit(c) and c != '.') return null;
    }
    return body;
}

/// Validate the path segment up to the next `/` as a version token.
/// Shared by the URL shapes that carry the tag as a bare segment
/// (`/releases/download/<X>/`, `/-/archive/<X>/`, `/-/releases/<X>/`)
/// rather than as a suffixed filename. Returns null when the segment
/// is the whole tail (no trailing slash) or fails the version gate.
fn firstPathSegmentVersion(after: []const u8) ?[]const u8 {
    const slash = std.mem.indexOfScalar(u8, after, '/') orelse return null;
    return validateVersionToken(after[0..slash]);
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

test "parseRubyFormula: extracts the revision and defaults it to 0" {
    const with_rev =
        \\class Foo < Formula
        \\  url "https://example.com/foo-1.2.3.tar.gz"
        \\  sha256 "deadbeef"
        \\  version "1.2.3"
        \\  revision 2
        \\end
    ;
    const got = parseRubyFormula(with_rev) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(i64, 2), got.revision);

    const no_rev =
        \\class Foo < Formula
        \\  url "https://example.com/foo-1.2.3.tar.gz"
        \\  sha256 "deadbeef"
        \\  version "1.2.3"
        \\end
    ;
    const got0 = parseRubyFormula(no_rev) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(i64, 0), got0.revision);
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

test "parseRubyFormula: derives version from a GitLab /-/archive/ URL" {
    const src =
        \\class Foo < Formula
        \\  url "https://gitlab.com/foo/bar/-/archive/v1.2.3/bar-v1.2.3.tar.gz"
        \\  sha256 "deadbeef"
        \\end
    ;
    const got = parseRubyFormula(src) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("1.2.3", got.version);
}

test "deriveVersionFromUrl: GitLab archive uses the ref segment, not the filename" {
    const got = deriveVersionFromUrl(
        "https://gitlab.com/foo/bar/-/archive/v1.2.3/bar-v1.2.3.tar.gz",
    ) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("1.2.3", got);
}

test "deriveVersionFromUrl: GitLab release downloads path yields the tag" {
    const got = deriveVersionFromUrl(
        "https://gitlab.com/foo/bar/-/releases/v1.2.3/downloads/bar.tar.gz",
    ) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("1.2.3", got);
}

test "deriveVersionFromUrl: Gitea short-form /archive/<ref>.tar.gz" {
    const got = deriveVersionFromUrl(
        "https://gitea.example.com/foo/bar/archive/v1.2.3.tar.gz",
    ) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("1.2.3", got);
}

test "deriveVersionFromUrl: GitLab floating ref is rejected" {
    try std.testing.expect(deriveVersionFromUrl(
        "https://gitlab.com/foo/bar/-/archive/main/bar-main.tar.gz",
    ) == null);
}

test "deriveVersionFromUrl: GitLab floating release tag is rejected" {
    try std.testing.expect(deriveVersionFromUrl(
        "https://gitlab.com/foo/bar/-/releases/latest/downloads/bar.tar.gz",
    ) == null);
}

test "deriveVersionFromUrl: derives from a bare versioned filename, null when ambiguous" {
    const cases = [_]struct { url: []const u8, want: ?[]const u8 }{
        // The headline shape: a self-hosted release with the version only
        // in the filename, no `/archive/` or `/releases/` path marker.
        .{ .url = "https://host.example.com/dl/tool-1.2.3.tar.gz", .want = "1.2.3" },
        // Underscore-delimited, version in the middle (`_<version>_`).
        .{ .url = "https://host.example.com/dl/tool_1.2.3_amd64.zip", .want = "1.2.3" },
        // A leading `v` is stripped just like the path-marker shapes.
        .{ .url = "https://host.example.com/dl/tool-v2.4.0.tgz", .want = "2.4.0" },
        // A name with leading digits must not be mistaken for the version.
        .{ .url = "https://host.example.com/dl/7zip-22.01.tar.xz", .want = "22.01" },
        // No version-like token → graceful skip, never a guess.
        .{ .url = "https://host.example.com/dl/tool.tar.gz", .want = null },
        // Two version-like tokens are ambiguous → null, not a wrong pick.
        .{ .url = "https://host.example.com/dl/tool-1.2-3.4.tar.gz", .want = null },
        // Unrecognised archive suffix → no stem to read → null.
        .{ .url = "https://host.example.com/dl/tool-1.2.3.bin", .want = null },
    };
    for (cases) |c| {
        const got = deriveVersionFromUrl(c.url);
        if (c.want) |w| {
            try std.testing.expectEqualStrings(w, got orelse return error.TestUnexpectedNull);
        } else {
            try std.testing.expect(got == null);
        }
    }
}

test "parseRubyFormula: derives version from a bare versioned filename" {
    const src =
        \\class Foo < Formula
        \\  url "https://downloads.example.com/foo-1.2.3.tar.gz"
        \\  sha256 "deadbeef"
        \\end
    ;
    const got = parseRubyFormula(src) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("1.2.3", got.version);
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

test "parseRubyFormula: top-level arch-segmented formula with no matching arch is refused" {
    // Only the arch we are NOT running on is present. The arch-blind fallback
    // must not resolve the other arch's self-consistent url+sha256 pair.
    const is_arm = @import("../../macho/codesign.zig").isArm64();
    const wrong = if (is_arm)
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  on_intel do
        \\    url "https://example.com/foo-1.2.3-intel.tar.gz"
        \\    sha256 "bbbbbbbb"
        \\  end
        \\end
    else
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  on_arm do
        \\    url "https://example.com/foo-1.2.3-arm.tar.gz"
        \\    sha256 "aaaaaaaa"
        \\  end
        \\end
    ;
    try std.testing.expect(parseRubyFormula(wrong) == null);
}

test "parseRubyFormula: top-level arch block for the running arch resolves its own url+sha256" {
    const is_arm = @import("../../macho/codesign.zig").isArm64();
    const src =
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  on_arm do
        \\    url "https://example.com/foo-1.2.3-arm.tar.gz"
        \\    sha256 "aaaaaaaa"
        \\  end
        \\  on_intel do
        \\    url "https://example.com/foo-1.2.3-intel.tar.gz"
        \\    sha256 "bbbbbbbb"
        \\  end
        \\end
    ;
    const got = parseRubyFormula(src) orelse return error.TestUnexpectedNull;
    if (is_arm) {
        try std.testing.expectEqualStrings("https://example.com/foo-1.2.3-arm.tar.gz", got.url);
        try std.testing.expectEqualStrings("aaaaaaaa", got.sha256);
    } else {
        try std.testing.expectEqualStrings("https://example.com/foo-1.2.3-intel.tar.gz", got.url);
        try std.testing.expectEqualStrings("bbbbbbbb", got.sha256);
    }
}

test "parseRubyFormula: a flat formula mentioning on_arm in prose still resolves via fallback" {
    // The `on_*` marker is anchored to the line start, so an `on_arm` token in
    // a desc string must not disarm the global fallback for a flat formula.
    const src =
        \\class Foo < Formula
        \\  desc "runs great on_arm boards"
        \\  version "1.2.3"
        \\  url "https://example.com/foo-1.2.3.tar.gz"
        \\  sha256 "deadbeef"
        \\end
    ;
    const got = parseRubyFormula(src) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("https://example.com/foo-1.2.3.tar.gz", got.url);
    try std.testing.expectEqualStrings("deadbeef", got.sha256);
}

test "parseRubyFormula: top-level Hardware::CPU block for the wrong arch is refused" {
    // Same defect surface as on_arm/on_intel, expressed in the classic
    // `Hardware::CPU.<arch>?` form with no on_macos wrapper.
    const is_arm = @import("../../macho/codesign.zig").isArm64();
    const wrong = if (is_arm)
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  if Hardware::CPU.intel?
        \\    url "https://example.com/foo-1.2.3-intel.tar.gz"
        \\    sha256 "bbbbbbbb"
        \\  end
        \\end
    else
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  if Hardware::CPU.arm?
        \\    url "https://example.com/foo-1.2.3-arm.tar.gz"
        \\    sha256 "aaaaaaaa"
        \\  end
        \\end
    ;
    try std.testing.expect(parseRubyFormula(wrong) == null);
}

test "parseRubyFormula: resolves the running arch even when the other arch block is first" {
    // The section resets at each arch marker. Otherwise `on_macos` leaves it
    // stuck true and the leading, wrong-arch block wins — a self-consistent
    // wrong-arch pair that would sail through the checksum gate.
    const is_arm = @import("../../macho/codesign.zig").isArm64();
    const src = if (is_arm)
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  on_macos do
        \\    on_intel do
        \\      url "https://example.com/foo-intel.tar.gz"
        \\      sha256 "bbbbbbbb"
        \\    end
        \\    on_arm do
        \\      url "https://example.com/foo-arm.tar.gz"
        \\      sha256 "aaaaaaaa"
        \\    end
        \\  end
        \\end
    else
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  on_macos do
        \\    on_arm do
        \\      url "https://example.com/foo-arm.tar.gz"
        \\      sha256 "aaaaaaaa"
        \\    end
        \\    on_intel do
        \\      url "https://example.com/foo-intel.tar.gz"
        \\      sha256 "bbbbbbbb"
        \\    end
        \\  end
        \\end
    ;
    const got = parseRubyFormula(src) orelse return error.TestUnexpectedNull;
    if (is_arm) {
        try std.testing.expectEqualStrings("https://example.com/foo-arm.tar.gz", got.url);
        try std.testing.expectEqualStrings("aaaaaaaa", got.sha256);
    } else {
        try std.testing.expectEqualStrings("https://example.com/foo-intel.tar.gz", got.url);
        try std.testing.expectEqualStrings("bbbbbbbb", got.sha256);
    }
}

test "parseRubyFormula: a formula carrying a def install block still parses" {
    // A `def install` block is no refusal signal — a prebuilt formula
    // also carries one (`bin.install "<file-in-archive>"`). The parser
    // must surface version/url/sha256 regardless; whether the archive
    // yields a binary is decided downstream on the extracted result.
    const rb =
        \\class Sketchybar < Formula
        \\  url "https://example.com/sketchybar-2.24.0.tar.gz"
        \\  sha256 "deadbeef"
        \\  version "2.24.0"
        \\  def install
        \\    system "make"
        \\  end
        \\end
    ;
    const got = parseRubyFormula(rb) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("2.24.0", got.version);
    try std.testing.expectEqualStrings("deadbeef", got.sha256);
}
