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

/// Ruby block keywords the arch scanner acts on. Matched against the whole
/// trimmed line, so a modifier (`url "x" if cond`) can never trip them.
const BlockKeyword = enum { else_branch, block_end };

const block_keywords = std.StaticStringMap(BlockKeyword).initComptime(.{
    .{ "else", .else_branch },
    .{ "end", .block_end },
});

/// The only directives a two-arch branch carries. Anything else - a nested
/// block, a `def`, a heredoc - can own an `else` or `end` of its own, and the
/// scanner tracks no depth to tell whose it is.
const arch_branch_directives = [_][]const u8{
    "url ",
    "sha256 ",
    "mirror ",
    "version ",
    "revision ",
};

/// Whether `line` keeps an arch branch straight-line, so a following `else`
/// is unambiguously the branch's own. Callers pass a trimmed, non-empty line.
fn isArchBranchBody(line: []const u8) bool {
    // A heredoc opener hides arbitrary text, including lines reading `else`.
    if (std.mem.indexOf(u8, line, "<<") != null) return false;
    if (line[0] == '#') return true;
    for (arch_branch_directives) |directive| {
        if (std.mem.startsWith(u8, line, directive)) return true;
    }
    return false;
}

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
    // An arch `if`/`elsif` is open, so a bare `else` completes it. Not armed by
    // `on_arm do` / `on_intel do`: a Ruby block has no `else` branch.
    var arch_if_open = false;

    var it = std.mem.splitScalar(u8, rb_content, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        // Uniform skip; the sha256 kwarg continuation below thus tolerates a blank
        // line between its arm:/intel: halves rather than treating it as a reset.
        if (line.len == 0) continue;

        // Extract version (global)
        if (version == null) {
            if (extractQuoted(line, "version \"")) |v| {
                version = v;
            }
        }

        // Extract `revision N` (global, unquoted integer). Names the keg's
        // `<version>_N` leaf and lets the outdated audit spot revision bumps.
        // Layout-blind and formula-oriented: it matches at any indentation, in
        // any block, so the cask caller discards what it finds.
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
            arch_if_open = std.mem.startsWith(u8, line, "if ") or
                std.mem.startsWith(u8, line, "elsif ");
        } else if (block_keywords.get(line)) |kw| switch (kw) {
            // The unmarked half of an arch conditional is ours exactly when
            // the marked half was not.
            .else_branch => if (arch_if_open) {
                in_correct_section = !in_correct_section;
                arch_if_open = false;
            },
            .block_end => arch_if_open = false,
        } else if (!isArchBranchBody(line)) {
            // Anything unrecognised forfeits the flip. Giving up costs a parse
            // refusal; guessing wrong installs the other arch's binary behind
            // a checksum that matches it.
            arch_if_open = false;
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

    // Global url/sha256 fallback. Skip when an arch-segmented formula yielded
    // NEITHER field for our arch — else it grabs the whole other-arch pair.
    // A partial block (our url + a shared global sha256) still completes.
    if ((url == null or sha256 == null) and !(saw_arch_marker and url == null and sha256 == null)) {
        var fallback_it = std.mem.splitScalar(u8, rb_content, '\n');
        while (fallback_it.next()) |raw| {
            const ln = std.mem.trim(u8, raw, " \t\r");
            if (ln.len == 0) continue;

            if (url == null) {
                if (extractQuoted(ln, "url \"")) |u| url = u;
            }
            if (sha256 == null) {
                if (extractQuoted(ln, "sha256 \"")) |s| sha256 = s;
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
/// override to land a working symlink. A `#{staged_path}/` prefix is
/// dropped: the API renders that source relative, and so does malt.
/// Returns null for formulas or casks that omit the directive.
pub fn parseCaskBinary(rb_content: []const u8) ?[]const u8 {
    const line = caskBinaryLine(rb_content) orelse return null;
    const source = extractQuoted(line, "binary \"") orelse return null;
    const staged = "#{staged_path}/";
    return if (std.mem.startsWith(u8, source, staged)) source[staged.len..] else source;
}

/// The `target: "<name>"` sibling on the `binary` line, or null.
pub fn parseCaskBinaryTarget(rb_content: []const u8) ?[]const u8 {
    const line = caskBinaryLine(rb_content) orelse return null;
    return extractQuoted(line, "target: \"");
}

/// Anchored to the trimmed line start so a stray mention in a comment
/// or `desc` string does not match.
fn caskBinaryLine(rb_content: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, rb_content, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "binary \"")) return line;
    }
    return null;
}

/// Pull the first argument of a cask `app "<X>.app"` directive. The
/// cask installer promotes that bundle into the chosen Applications
/// directory; absence flips a `.zip` URL away from the cask path so a
/// formula bottle is still extracted into the Cellar.
pub fn parseCaskApp(rb_content: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, rb_content, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
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
        .tar_gz, .tar_xz, .unknown => null,
    };
}

/// Cap on `run` argv tokens a Ruby service block may carry. Sized well below
/// `plist.max_program_args` so the caller-owned buffer stays small.
pub const max_service_args = 16;

/// A formula's `service do ... end` block, lifted textually. Every string is
/// the raw Ruby spelling (`opt_bin/"svcd"`, `"--foreground"`, `var/"log"`);
/// translating those into launchd paths is the caller's job.
pub const RubyServiceBlock = struct {
    run: []const []const u8,
    working_dir: ?[]const u8 = null,
    log_path: ?[]const u8 = null,
    error_log_path: ?[]const u8 = null,
    keep_alive: bool = true,
    run_type: RunType = .immediate,
    interval: ?u32 = null,
    cron: ?[]const u8 = null,

    pub const RunType = enum { immediate, interval, cron };
};

const ServiceDirective = enum { run, name, keep_alive, working_dir, log_path, error_log_path, run_type, interval, cron };

const service_directives = std.StaticStringMap(ServiceDirective).initComptime(.{
    .{ "run", .run },
    .{ "name", .name },
    .{ "keep_alive", .keep_alive },
    .{ "working_dir", .working_dir },
    .{ "log_path", .log_path },
    .{ "error_log_path", .error_log_path },
    .{ "run_type", .run_type },
    .{ "interval", .interval },
    .{ "cron", .cron },
});

pub const ServiceParseError = error{ Unsupported, ShipsOwnPlist };

/// Lift the `service do ... end` block. Null when the formula has none, or
/// when its `run` carries only a `linux:` argv (no service on macOS);
/// `Unsupported` when it has one but `run` did not lift (absent, empty, over
/// `max_service_args`, or a shape this scanner cannot follow), so the caller
/// can warn instead of reading it as "declares no service". A run-less block
/// that only `name`s a label is `ShipsOwnPlist`: the formula installs the
/// plist itself, which malt deliberately does not adopt. Directives are
/// read only at the block's own body indentation, so a nested `on_macos do`
/// / `if` is skipped without tracking depth; the block closes at the first
/// `end` back at the opener's indentation. Anything not in
/// `service_directives` (`sudo`, `environment_variables`, ...) is ignored.
pub fn parseServiceBlock(buf: *[max_service_args][]const u8, rb_content: []const u8) ServiceParseError!?RubyServiceBlock {
    var block: RubyServiceBlock = .{ .run = &.{} };
    var saw_name = false;
    var saw_run = false;
    var linux_only = false;
    var block_indent: ?usize = null;
    var body_indent: ?usize = null;
    var pos: usize = 0;
    while (pos < rb_content.len) {
        const nl = std.mem.indexOfScalarPos(u8, rb_content, pos, '\n') orelse rb_content.len;
        const raw = rb_content[pos..nl];
        pos = nl + 1;
        // A top-level `#` can only open a comment: `#{` lives inside strings.
        const code = raw[0 .. indexOfTopLevel(raw, '#') orelse raw.len];
        const line = std.mem.trim(u8, code, " \t\r");
        if (line.len == 0) continue;
        const indent = std.mem.indexOfNone(u8, raw, " \t") orelse raw.len;

        const opener = block_indent orelse {
            if (std.mem.eql(u8, line, "service do")) block_indent = indent;
            continue;
        };
        if (indent == opener and std.mem.eql(u8, line, "end")) break;
        // Counted before the indent skip: a `run` nested under `on_macos do`
        // or spelled `run(...)` is one the scanner cannot follow, not a
        // formula that ships its own plist.
        if (isRunDirective(line)) saw_run = true;
        const body = body_indent orelse blk: {
            body_indent = indent;
            break :blk indent;
        };
        if (indent != body) continue;

        // The fallback stays a slice of `line` so `arg.ptr` is always inside
        // `rb_content` for the offset arithmetic below.
        const word, const rest = std.mem.cut(u8, line, " ") orelse .{ line, line[line.len..] };
        const arg = std.mem.trim(u8, rest, " \t");
        switch (service_directives.get(word) orelse continue) {
            .run => {
                // A bracketed argv may continue past this line; consume it
                // from the body and resume after its closing `]`.
                const start = @intFromPtr(arg.ptr) - @intFromPtr(rb_content.ptr);
                const argv = try macosArgv(rb_content[start..]);
                pos = @max(pos, start + argv.consumed);
                // Homebrew leaves `@run` untouched on macOS for a Linux-only
                // call, so a plain `run` elsewhere in the block still wins.
                if (argv.src) |src| block.run = splitArgv(buf, src) orelse return error.Unsupported else linux_only = true;
            },
            // The label is irrelevant: malt keeps its own `com.malt.<name>`.
            .name => saw_name = true,
            .keep_alive => block.keep_alive = !std.mem.eql(u8, arg, "false"),
            .working_dir => block.working_dir = arg,
            .log_path => block.log_path = arg,
            .error_log_path => block.error_log_path = arg,
            .run_type => block.run_type = if (std.mem.eql(u8, arg, ":interval"))
                .interval
            else if (std.mem.eql(u8, arg, ":cron"))
                .cron
            else
                .immediate,
            .interval => block.interval = std.fmt.parseInt(u32, arg, 10) catch null,
            .cron => block.cron = extractQuoted(line, "cron \""),
        }
    }
    if (block_indent == null) return null;
    if (block.run.len == 0) {
        // No service on macOS at all; Homebrew prints nothing for it either.
        if (linux_only) return null;
        return if (saw_name and !saw_run) error.ShipsOwnPlist else error.Unsupported;
    }
    return block;
}

fn isRunDirective(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "run")) return false;
    // Not `run_type`.
    return line.len == 3 or switch (line[3]) {
        ' ', '(', '[' => true,
        else => false,
    };
}

/// The reason suffix of the install warning, kept here so both Ruby-DSL
/// call sites print the same words for the same refusal.
pub fn serviceRefusalReason(err: ServiceParseError) []const u8 {
    return switch (err) {
        error.Unsupported => "unsupported service block",
        error.ShipsOwnPlist => "formula ships its own plist, which malt does not adopt",
    };
}

/// The macOS argv source of a `run` directive: the bracket body of `run [...]`
/// or `run macos: [...]`, or the bare single token of `run opt_bin/"x"`.
/// `consumed` is how many bytes of `src` the directive spans, so a
/// multi-line array is stepped over whole. `src` is null when only a
/// `linux:` argv is given: no service on macOS, not a shape this scanner
/// cannot read. Brackets are matched on the raw buffer, so a `]` inside a
/// comment or a single-quoted string can end an array early.
const MacosArgv = struct { src: ?[]const u8, consumed: usize };

fn macosArgv(src: []const u8) error{Unsupported}!MacosArgv {
    var s = src;
    if (std.mem.startsWith(u8, s, "linux:")) {
        // Step over the Linux argv: a `macos:` sibling may still follow it.
        s = std.mem.trimStart(u8, s["linux:".len..], " \t");
        const end = if (s.len > 0 and s[0] == '[')
            (indexOfTopLevel(s[1..], ']') orelse return error.Unsupported) + 2
        else
            bareTokenEnd(s);
        const linux: MacosArgv = .{ .src = null, .consumed = src.len - s.len + end };
        s = std.mem.trimStart(u8, s[end..], " \t");
        if (s.len == 0 or s[0] != ',') return linux;
        // The raw buffer is read here, so comment lines are still in it.
        s = skipBlankAndComments(s[1..]);
        if (!std.mem.startsWith(u8, s, "macos:")) return linux;
    }
    if (std.mem.startsWith(u8, s, "macos:")) s = std.mem.trimStart(u8, s["macos:".len..], " \t");
    const skipped = src.len - s.len;
    if (s.len > 0 and s[0] == '[') {
        const close = indexOfTopLevel(s[1..], ']') orelse return error.Unsupported;
        return .{ .src = s[1 .. 1 + close], .consumed = skipped + close + 2 };
    }
    const end = bareTokenEnd(s);
    return .{ .src = s[0..end], .consumed = skipped + end };
}

/// Bare form: one token, ending at the line, a comment, or an OS-keyed sibling.
fn bareTokenEnd(s: []const u8) usize {
    const eol = std.mem.indexOfScalar(u8, s, '\n') orelse s.len;
    const end = indexOfTopLevel(s[0..eol], '#') orelse eol;
    return indexOfTopLevel(s[0..end], ',') orelse end;
}

/// A `\\` is Ruby's line continuation; between a comma and `macos:` it
/// is only ever whitespace.
fn skipBlankAndComments(src: []const u8) []const u8 {
    var s = src;
    while (true) {
        s = std.mem.trimStart(u8, s, " \t\r\n\\");
        if (s.len == 0 or s[0] != '#') return s;
        s = s[std.mem.indexOfScalar(u8, s, '\n') orelse s.len ..];
    }
}

/// Split an argv body on top-level commas, keeping `"..."` contents intact.
/// Null when it is empty or exceeds `buf`.
fn splitArgv(buf: *[max_service_args][]const u8, body: []const u8) ?[]const []const u8 {
    var n: usize = 0;
    var rest = body;
    while (true) {
        const cut = indexOfTopLevel(rest, ',') orelse rest.len;
        const tok = std.mem.trim(u8, rest[0..cut], " \t\r\n");
        if (tok.len > 0) {
            if (n == buf.len) return null;
            buf[n] = tok;
            n += 1;
        }
        if (cut == rest.len) break;
        rest = rest[cut + 1 ..];
    }
    return if (n == 0) null else buf[0..n];
}

/// First `needle` outside a `"..."` string and outside nested `[...]`, so
/// `Formula["x"]` inside an argv array neither closes it nor splits it.
fn indexOfTopLevel(s: []const u8, needle: u8) ?usize {
    var in_str = false;
    var depth: usize = 0;
    for (s, 0..) |c, i| {
        if (c == '"') in_str = !in_str;
        if (in_str) continue;
        if (depth == 0 and c == needle) return i;
        switch (c) {
            '[' => depth += 1,
            ']' => depth -|= 1,
            else => {},
        }
    }
    return null;
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

test "parseCaskBinary: a staged_path source is returned relative, the API form" {
    const rb =
        \\cask "textadept" do
        \\  app "Textadept.app"
        \\  binary "#{staged_path}/ta"
        \\end
    ;
    try std.testing.expectEqualStrings("ta", parseCaskBinary(rb).?);
}

test "parseCaskBinary: an appdir source is returned as spelled, for the serializer to translate" {
    const rb =
        \\cask "zed" do
        \\  app "Zed.app"
        \\  binary "#{appdir}/Zed.app/Contents/MacOS/cli", target: "zed"
        \\end
    ;
    try std.testing.expectEqualStrings("#{appdir}/Zed.app/Contents/MacOS/cli", parseCaskBinary(rb).?);
}

test "parseCaskBinaryTarget: reads the target sibling off the binary line" {
    const rb =
        \\cask "zed" do
        \\  binary "#{appdir}/Zed.app/Contents/MacOS/cli", target: "zed"
        \\end
    ;
    try std.testing.expectEqualStrings("zed", parseCaskBinaryTarget(rb).?);
}

test "parseCaskBinaryTarget: null when the directive names no target" {
    const rb =
        \\cask "demo" do
        \\  binary "longbridge"
        \\  # target: "not this line"
        \\end
    ;
    try std.testing.expect(parseCaskBinaryTarget(rb) == null);
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

test "parseRubyFormula: an arch if/else resolves the branch holding our arch, either side" {
    // A bare `else` carries no arch marker, so the branch it opens is only
    // reachable if the scanner flips the section on it.
    const is_arm = @import("../../macho/codesign.zig").isArm64();
    const ours = "https://example.com/foo-ours.tar.gz";
    const theirs = "https://example.com/foo-theirs.tar.gz";

    // Gate names the other arch: `else` holds our pair.
    const in_else = if (is_arm)
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  if Hardware::CPU.intel?
        \\    url "https://example.com/foo-theirs.tar.gz"
        \\    sha256 "bbbbbbbb"
        \\  else
        \\    url "https://example.com/foo-ours.tar.gz"
        \\    sha256 "aaaaaaaa"
        \\  end
        \\end
    else
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  if Hardware::CPU.arm?
        \\    url "https://example.com/foo-theirs.tar.gz"
        \\    sha256 "bbbbbbbb"
        \\  else
        \\    url "https://example.com/foo-ours.tar.gz"
        \\    sha256 "aaaaaaaa"
        \\  end
        \\end
    ;
    const from_else = parseRubyFormula(in_else) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings(ours, from_else.url);
    try std.testing.expectEqualStrings("aaaaaaaa", from_else.sha256);

    // Mirror: gate names our arch, so the `if` branch wins and the flip
    // must not invert.
    const in_if = if (is_arm)
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  if Hardware::CPU.arm?
        \\    url "https://example.com/foo-ours.tar.gz"
        \\    sha256 "aaaaaaaa"
        \\  else
        \\    url "https://example.com/foo-theirs.tar.gz"
        \\    sha256 "bbbbbbbb"
        \\  end
        \\end
    else
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  if Hardware::CPU.intel?
        \\    url "https://example.com/foo-ours.tar.gz"
        \\    sha256 "aaaaaaaa"
        \\  else
        \\    url "https://example.com/foo-theirs.tar.gz"
        \\    sha256 "bbbbbbbb"
        \\  end
        \\end
    ;
    const from_if = parseRubyFormula(in_if) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings(ours, from_if.url);
    try std.testing.expectEqualStrings("aaaaaaaa", from_if.sha256);
    try std.testing.expect(!std.mem.eql(u8, theirs, from_if.url));
}

test "parseRubyFormula: an elsif chain closed by else keeps the matching branch" {
    // Each `elsif` carries its own marker; the trailing `else` must turn the
    // section off after a branch already matched, not hand it the leftovers.
    const is_arm = @import("../../macho/codesign.zig").isArm64();
    const src = if (is_arm)
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  if Hardware::CPU.arm?
        \\    url "https://example.com/foo-ours.tar.gz"
        \\    sha256 "aaaaaaaa"
        \\  elsif Hardware::CPU.intel?
        \\    url "https://example.com/foo-theirs.tar.gz"
        \\    sha256 "bbbbbbbb"
        \\  else
        \\    url "https://example.com/foo-generic.tar.gz"
        \\    sha256 "cccccccc"
        \\  end
        \\end
    else
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  if Hardware::CPU.intel?
        \\    url "https://example.com/foo-ours.tar.gz"
        \\    sha256 "aaaaaaaa"
        \\  elsif Hardware::CPU.arm?
        \\    url "https://example.com/foo-theirs.tar.gz"
        \\    sha256 "bbbbbbbb"
        \\  else
        \\    url "https://example.com/foo-generic.tar.gz"
        \\    sha256 "cccccccc"
        \\  end
        \\end
    ;
    const got = parseRubyFormula(src) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("https://example.com/foo-ours.tar.gz", got.url);
    try std.testing.expectEqualStrings("aaaaaaaa", got.sha256);
}

test "parseRubyFormula: an else with no arch if before it flips nothing" {
    // Only an arch `if`/`elsif` arms the flip, so an unrelated conditional
    // cannot smuggle a non-matching block into our section.
    const src =
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  if build.head?
        \\    url "https://example.com/foo-head.tar.gz"
        \\  else
        \\    url "https://example.com/foo-1.2.3.tar.gz"
        \\  end
        \\  sha256 "deadbeef"
        \\end
    ;
    const got = parseRubyFormula(src) orelse return error.TestUnexpectedNull;
    // Nothing matched a section, so the arch-blind fallback still applies.
    try std.testing.expectEqualStrings("https://example.com/foo-head.tar.gz", got.url);
    try std.testing.expectEqualStrings("deadbeef", got.sha256);
}

test "parseRubyFormula: an else after an arch block opener does not flip the section" {
    // `on_arm do ... end` is a block, not a conditional — Ruby has no `else`
    // to pair with it, so a stray one must leave the wrong-arch refusal alone.
    const is_arm = @import("../../macho/codesign.zig").isArm64();
    const wrong = if (is_arm)
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  on_intel do
        \\    url "https://example.com/foo-theirs.tar.gz"
        \\    sha256 "bbbbbbbb"
        \\  end
        \\  else
        \\  url "https://example.com/foo-stray.tar.gz"
        \\  sha256 "cccccccc"
        \\end
    else
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  on_arm do
        \\    url "https://example.com/foo-theirs.tar.gz"
        \\    sha256 "bbbbbbbb"
        \\  end
        \\  else
        \\  url "https://example.com/foo-stray.tar.gz"
        \\  sha256 "cccccccc"
        \\end
    ;
    try std.testing.expect(parseRubyFormula(wrong) == null);
}

test "parseRubyFormula: a nested conditional inside an arch branch cancels the flip" {
    // The inner `else` belongs to the inner `if`. Claiming it would resolve the
    // other arch's url with the sha256 that matches it - a checksum-clean
    // wrong-arch install. Refusing is the safe answer.
    const is_arm = @import("../../macho/codesign.zig").isArm64();
    const src = if (is_arm)
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  if Hardware::CPU.intel?
        \\    if build.head?
        \\      url "https://example.com/foo-theirs-head.tar.gz"
        \\    else
        \\      url "https://example.com/foo-theirs.tar.gz"
        \\      sha256 "bbbbbbbb"
        \\    end
        \\  else
        \\    url "https://example.com/foo-ours.tar.gz"
        \\    sha256 "aaaaaaaa"
        \\  end
        \\end
    else
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  if Hardware::CPU.arm?
        \\    if build.head?
        \\      url "https://example.com/foo-theirs-head.tar.gz"
        \\    else
        \\      url "https://example.com/foo-theirs.tar.gz"
        \\      sha256 "bbbbbbbb"
        \\    end
        \\  else
        \\    url "https://example.com/foo-ours.tar.gz"
        \\    sha256 "aaaaaaaa"
        \\  end
        \\end
    ;
    try std.testing.expect(parseRubyFormula(src) == null);
}

test "parseRubyFormula: a heredoc inside an arch branch cannot forge the else" {
    // Heredoc bodies hold arbitrary text. A line reading `else` in one is
    // indistinguishable from real Ruby to a scanner with no depth tracking,
    // and believing it would resolve the other arch's matching url+sha256.
    const is_arm = @import("../../macho/codesign.zig").isArm64();
    const src = if (is_arm)
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  if Hardware::CPU.intel?
        \\    caveats <<~EOS
        \\      else
        \\    EOS
        \\    url "https://example.com/foo-theirs.tar.gz"
        \\    sha256 "bbbbbbbb"
        \\  else
        \\    url "https://example.com/foo-ours.tar.gz"
        \\    sha256 "aaaaaaaa"
        \\  end
        \\end
    else
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  if Hardware::CPU.arm?
        \\    caveats <<~EOS
        \\      else
        \\    EOS
        \\    url "https://example.com/foo-theirs.tar.gz"
        \\    sha256 "bbbbbbbb"
        \\  else
        \\    url "https://example.com/foo-ours.tar.gz"
        \\    sha256 "aaaaaaaa"
        \\  end
        \\end
    ;
    const got = parseRubyFormula(src);
    // Never the other arch. Refusing is the acceptable outcome here.
    if (got) |info| {
        try std.testing.expectEqualStrings("https://example.com/foo-ours.tar.gz", info.url);
    }
}

test "parseRubyFormula: comments and a mirror keep an arch branch straight-line" {
    // The branch body a real two-arch formula carries must still flip, or the
    // straight-line rule would be too tight to be useful.
    const is_arm = @import("../../macho/codesign.zig").isArm64();
    const src = if (is_arm)
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  if Hardware::CPU.intel?
        \\    # the intel build
        \\    url "https://example.com/foo-theirs.tar.gz"
        \\    mirror "https://mirror.example.com/foo-theirs.tar.gz"
        \\    sha256 "bbbbbbbb"
        \\  else
        \\    url "https://example.com/foo-ours.tar.gz"
        \\    sha256 "aaaaaaaa"
        \\  end
        \\end
    else
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  if Hardware::CPU.arm?
        \\    # the arm build
        \\    url "https://example.com/foo-theirs.tar.gz"
        \\    mirror "https://mirror.example.com/foo-theirs.tar.gz"
        \\    sha256 "bbbbbbbb"
        \\  else
        \\    url "https://example.com/foo-ours.tar.gz"
        \\    sha256 "aaaaaaaa"
        \\  end
        \\end
    ;
    const got = parseRubyFormula(src) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("https://example.com/foo-ours.tar.gz", got.url);
    try std.testing.expectEqualStrings("aaaaaaaa", got.sha256);
}

test "parseRubyFormula: a do block inside an arch branch cancels the flip" {
    // Same reasoning as a nested conditional: the scanner tracks no depth, so
    // anything that opens a scope makes the next `else` unattributable.
    const is_arm = @import("../../macho/codesign.zig").isArm64();
    const src = if (is_arm)
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  if Hardware::CPU.intel?
        \\    resource "extra" do
        \\      url "https://example.com/extra.tar.gz"
        \\    end
        \\  else
        \\    url "https://example.com/foo-ours.tar.gz"
        \\    sha256 "aaaaaaaa"
        \\  end
        \\end
    else
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  if Hardware::CPU.arm?
        \\    resource "extra" do
        \\      url "https://example.com/extra.tar.gz"
        \\    end
        \\  else
        \\    url "https://example.com/foo-ours.tar.gz"
        \\    sha256 "aaaaaaaa"
        \\  end
        \\end
    ;
    try std.testing.expect(parseRubyFormula(src) == null);
}

test "parseRubyFormula: a closed arch if disarms the flip for a later else" {
    // The flip is spent at the matching `end`; a later `else` belongs to some
    // other conditional and must not reopen the arch section.
    const is_arm = @import("../../macho/codesign.zig").isArm64();
    const src = if (is_arm)
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  if Hardware::CPU.intel?
        \\    url "https://example.com/foo-theirs.tar.gz"
        \\    sha256 "bbbbbbbb"
        \\  end
        \\  if build.head?
        \\    depends_on "git"
        \\  else
        \\    url "https://example.com/foo-stray.tar.gz"
        \\    sha256 "cccccccc"
        \\  end
        \\end
    else
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  if Hardware::CPU.arm?
        \\    url "https://example.com/foo-theirs.tar.gz"
        \\    sha256 "bbbbbbbb"
        \\  end
        \\  if build.head?
        \\    depends_on "git"
        \\  else
        \\    url "https://example.com/foo-stray.tar.gz"
        \\    sha256 "cccccccc"
        \\  end
        \\end
    ;
    try std.testing.expect(parseRubyFormula(src) == null);
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

// Trailing-newline characterization. `splitScalar` (the upcoming line-iteration
// idiom) yields one extra empty segment when a body ends in `\n`; these pin that
// the empty segment stays inert across every split site so the refactor is a
// diff a reviewer checks against "bodies untouched", not a re-derivation.

test "parseRubyFormula: trailing newline parses identically to no trailing newline" {
    const body =
        \\class Foo < Formula
        \\  url "https://example.com/foo-1.2.3.tar.gz"
        \\  sha256 "deadbeef"
        \\  version "1.2.3"
        \\end
    ;
    const base = parseRubyFormula(body) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("1.2.3", base.version);
    try std.testing.expectEqualDeep(parseRubyFormula(body), parseRubyFormula(body ++ "\n"));
}

test "parseRubyFormula: url/sha256 fallback tolerates a trailing newline" {
    // url resolves inside on_macos; the global sha256 is completed by the second
    // (fallback) split site — the case the trailing-newline segment could perturb.
    const body =
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  sha256 "deadbeef"
        \\  on_macos do
        \\    url "https://example.com/foo-1.2.3.tar.gz"
        \\  end
        \\end
    ;
    const base = parseRubyFormula(body) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("https://example.com/foo-1.2.3.tar.gz", base.url);
    try std.testing.expectEqualStrings("deadbeef", base.sha256);
    try std.testing.expectEqualDeep(parseRubyFormula(body), parseRubyFormula(body ++ "\n"));
}

test "parseRubyFormula: arch-segmented body with a trailing newline resolves the arch" {
    // The state machine (in_macos / in_correct_section) is the part most at risk
    // if an empty segment were ever non-inert, so cover it explicitly.
    const is_arm = @import("../../macho/codesign.zig").isArm64();
    const arm =
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  on_arm do
        \\    url "https://example.com/foo-1.2.3-arm.tar.gz"
        \\    sha256 "aaaaaaaa"
        \\  end
        \\end
    ;
    const intel =
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  on_intel do
        \\    url "https://example.com/foo-1.2.3-intel.tar.gz"
        \\    sha256 "bbbbbbbb"
        \\  end
        \\end
    ;
    const body = if (is_arm) arm else intel;
    const body_nl = if (is_arm) arm ++ "\n" else intel ++ "\n";
    const base = parseRubyFormula(body) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings(if (is_arm) "aaaaaaaa" else "bbbbbbbb", base.sha256);
    try std.testing.expectEqualDeep(parseRubyFormula(body), parseRubyFormula(body_nl));
}

test "parseCaskBinary: trailing newline parses the binary directive identically" {
    const body =
        \\cask "demo" do
        \\  binary "longbridge"
        \\end
    ;
    try std.testing.expectEqualStrings("longbridge", parseCaskBinary(body).?);
    try std.testing.expectEqualDeep(parseCaskBinary(body), parseCaskBinary(body ++ "\n"));
}

test "parseCaskApp: trailing newline parses the .app bundle name identically" {
    const body =
        \\cask "deck" do
        \\  url "https://example.com/deck.dmg"
        \\  app "Deck.app"
        \\end
    ;
    try std.testing.expectEqualStrings("Deck.app", parseCaskApp(body).?);
    try std.testing.expectEqualDeep(parseCaskApp(body), parseCaskApp(body ++ "\n"));
}

test "parseRubyFormula: a blank line inside a split sha256 kwarg is skipped, not a terminator" {
    // The uniform empty-line guard skips a blank line, so a `sha256 <arch>:` whose
    // running-arch value sits on the line after a blank still resolves. Real casks
    // never split a kwarg across a blank line; this pins the tolerant behaviour.
    const is_arm = @import("../../macho/codesign.zig").isArm64();
    const body = if (is_arm)
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  on_macos do
        \\    url "https://example.com/foo.tar.gz"
        \\    sha256 intel: "iiiiiiii",
        \\
        \\           arm: "aaaaaaaa"
        \\  end
        \\end
    else
        \\class Foo < Formula
        \\  version "1.2.3"
        \\  on_macos do
        \\    url "https://example.com/foo.tar.gz"
        \\    sha256 arm: "aaaaaaaa",
        \\
        \\           intel: "iiiiiiii"
        \\  end
        \\end
    ;
    const got = parseRubyFormula(body) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings(if (is_arm) "aaaaaaaa" else "iiiiiiii", got.sha256);
}

test "rb_parse entry points return null on empty input" {
    try std.testing.expect(parseRubyFormula("") == null);
    try std.testing.expect(parseCaskBinary("") == null);
    try std.testing.expect(parseCaskApp("") == null);
}

test "parseServiceBlock: lifts run argv and the path/keep_alive directives" {
    const rb =
        \\class Svcd < Formula
        \\  url "https://example.com/svcd-1.0.tar.gz"
        \\  version "1.0"
        \\  sha256 "deadbeef"
        \\  service do
        \\    run [opt_bin/"svcd", "--foreground", var/"y"]
        \\    keep_alive true
        \\    working_dir var
        \\    log_path var/"log/svcd.log"
        \\    error_log_path var/"log/svcd.err"
        \\  end
        \\end
    ;
    var buf: [max_service_args][]const u8 = undefined;
    const got = (try parseServiceBlock(&buf, rb)) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(usize, 3), got.run.len);
    try std.testing.expectEqualStrings("opt_bin/\"svcd\"", got.run[0]);
    try std.testing.expectEqualStrings("\"--foreground\"", got.run[1]);
    try std.testing.expectEqualStrings("var/\"y\"", got.run[2]);
    try std.testing.expect(got.keep_alive);
    try std.testing.expectEqualStrings("var", got.working_dir.?);
    try std.testing.expectEqualStrings("var/\"log/svcd.log\"", got.log_path.?);
    try std.testing.expectEqualStrings("var/\"log/svcd.err\"", got.error_log_path.?);
    try std.testing.expect(got.run_type == .immediate);
}

test "parseServiceBlock: a bare run token and keep_alive false" {
    const rb =
        \\  service do
        \\    run opt_bin/"x"
        \\    keep_alive false
        \\  end
    ;
    var buf: [max_service_args][]const u8 = undefined;
    const got = (try parseServiceBlock(&buf, rb)) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(usize, 1), got.run.len);
    try std.testing.expectEqualStrings("opt_bin/\"x\"", got.run[0]);
    try std.testing.expect(!got.keep_alive);
}

test "parseServiceBlock: keep_alive hash form reads as true" {
    const rb =
        \\  service do
        \\    run [opt_bin/"x"]
        \\    keep_alive { always: true }
        \\  end
    ;
    var buf: [max_service_args][]const u8 = undefined;
    const got = (try parseServiceBlock(&buf, rb)) orelse return error.TestUnexpectedNull;
    try std.testing.expect(got.keep_alive);
}

test "parseServiceBlock: run macos: takes the macOS argv and ignores linux:" {
    const rb =
        \\  service do
        \\    run macos: [opt_bin/"x", "--mac"], linux: [opt_bin/"x", "--linux"]
        \\  end
    ;
    var buf: [max_service_args][]const u8 = undefined;
    const got = (try parseServiceBlock(&buf, rb)) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(usize, 2), got.run.len);
    try std.testing.expectEqualStrings("\"--mac\"", got.run[1]);
}

test "parseServiceBlock: run linux: alone is no service on macOS" {
    // Homebrew refuses to start such a service on macOS and says nothing
    // at install time; a refusal here would blame a parser gap instead.
    var buf: [max_service_args][]const u8 = undefined;
    const one_line =
        \\  service do
        \\    run linux: [opt_bin/"x"]
        \\    working_dir HOMEBREW_PREFIX
        \\  end
    ;
    try std.testing.expect((try parseServiceBlock(&buf, one_line)) == null);

    const multi_line =
        \\  service do
        \\    run linux: [
        \\      opt_bin/"x",
        \\      "--linux",
        \\    ]
        \\  end
    ;
    try std.testing.expect((try parseServiceBlock(&buf, multi_line)) == null);
}

test "parseServiceBlock: run linux: before macos: still lifts the macOS argv" {
    // The linux-only outcome is silent, so it must never swallow a
    // macOS argv that merely comes second.
    const rb =
        \\  service do
        \\    run linux: [opt_bin/"x", "--linux"], macos: [opt_bin/"x", "--mac"]
        \\  end
    ;
    var buf: [max_service_args][]const u8 = undefined;
    const got = (try parseServiceBlock(&buf, rb)) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(usize, 2), got.run.len);
    try std.testing.expectEqualStrings("\"--mac\"", got.run[1]);
}

test "parseServiceBlock: a comment between the linux: array and macos: does not hide the argv" {
    // The argv is read from the raw buffer, so comments sit between the
    // comma and `macos:`; they must not turn into a silent drop.
    var buf: [max_service_args][]const u8 = undefined;
    for ([_][]const u8{
        \\  service do
        \\    run linux: [opt_bin/"x", "--linux"], # linux first
        \\        macos: [opt_bin/"x", "--mac"]
        \\  end
        ,
        \\  service do
        \\    run linux: [opt_bin/"x", "--linux"],
        \\        # linux first
        \\        macos: [opt_bin/"x", "--mac"]
        \\  end
        ,
    }) |rb| {
        const got = (try parseServiceBlock(&buf, rb)) orelse return error.TestUnexpectedNull;
        try std.testing.expectEqual(@as(usize, 2), got.run.len);
        try std.testing.expectEqualStrings("\"--mac\"", got.run[1]);
    }
}

test "parseServiceBlock: a bare linux: token reads like a bracketed one" {
    // The JSON twin is silent on `{"run":{"linux":"/x"}}`; the Ruby side
    // must not warn for the same formula.
    var buf: [max_service_args][]const u8 = undefined;
    const bare =
        \\  service do
        \\    run linux: opt_bin/"x" # linux only
        \\  end
    ;
    try std.testing.expect((try parseServiceBlock(&buf, bare)) == null);

    const bare_then_macos =
        \\  service do
        \\    run linux: opt_bin/"x", macos: opt_bin/"y"
        \\  end
    ;
    const got = (try parseServiceBlock(&buf, bare_then_macos)) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(usize, 1), got.run.len);
    try std.testing.expectEqualStrings("opt_bin/\"y\"", got.run[0]);
}

test "parseServiceBlock: a plain run beside run linux: still wins" {
    // Homebrew's `run linux:` leaves `@run` untouched on macOS, so the
    // plain call is the service whichever line comes first.
    var buf: [max_service_args][]const u8 = undefined;
    for ([_][]const u8{
        \\  service do
        \\    run [opt_bin/"z"]
        \\    run linux: [opt_bin/"x"]
        \\  end
        ,
        \\  service do
        \\    run linux: [opt_bin/"x"]
        \\    run [opt_bin/"z"]
        \\  end
        ,
    }) |rb| {
        const got = (try parseServiceBlock(&buf, rb)) orelse return error.TestUnexpectedNull;
        try std.testing.expectEqual(@as(usize, 1), got.run.len);
        try std.testing.expectEqualStrings("opt_bin/\"z\"", got.run[0]);
    }
}

test "parseServiceBlock: a backslash continuation before macos: does not hide the argv" {
    const rb =
        \\  service do
        \\    run linux: [opt_bin/"x"], \\
        \\        macos: [opt_bin/"x", "--mac"]
        \\  end
    ;
    var buf: [max_service_args][]const u8 = undefined;
    const got = (try parseServiceBlock(&buf, rb)) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("\"--mac\"", got.run[1]);
}

test "parseServiceBlock: an unclosed run linux: array is still Unsupported" {
    const rb =
        \\  service do
        \\    run linux: [opt_bin/"x"
        \\  end
    ;
    var buf: [max_service_args][]const u8 = undefined;
    try std.testing.expectError(error.Unsupported, parseServiceBlock(&buf, rb));
}

test "parseServiceBlock: a quoted comma stays inside its token" {
    const rb =
        \\  service do
        \\    run [opt_bin/"x", "--opt=a,b"]
        \\  end
    ;
    var buf: [max_service_args][]const u8 = undefined;
    const got = (try parseServiceBlock(&buf, rb)) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(usize, 2), got.run.len);
    try std.testing.expectEqualStrings("\"--opt=a,b\"", got.run[1]);
}

test "parseServiceBlock: interval and cron schedules" {
    const iv =
        \\  service do
        \\    run [opt_bin/"x"]
        \\    run_type :interval
        \\    interval 300
        \\  end
    ;
    var buf: [max_service_args][]const u8 = undefined;
    const got = (try parseServiceBlock(&buf, iv)) orelse return error.TestUnexpectedNull;
    try std.testing.expect(got.run_type == .interval);
    try std.testing.expectEqual(@as(?u32, 300), got.interval);

    const cr =
        \\  service do
        \\    run [opt_bin/"x"]
        \\    run_type :cron
        \\    cron "0 * * * *"
        \\  end
    ;
    const got_cr = (try parseServiceBlock(&buf, cr)) orelse return error.TestUnexpectedNull;
    try std.testing.expect(got_cr.run_type == .cron);
    try std.testing.expectEqualStrings("0 * * * *", got_cr.cron.?);
}

test "parseServiceBlock: no block yields null, a block without a usable run is Unsupported" {
    var buf: [max_service_args][]const u8 = undefined;
    const none =
        \\class Foo < Formula
        \\  url "https://example.com/foo-1.0.tar.gz"
        \\end
    ;
    try std.testing.expect((try parseServiceBlock(&buf, none)) == null);

    // Each of these opened a block the caller should warn about, not
    // mistake for "declares no service".
    const no_run =
        \\  service do
        \\    keep_alive true
        \\  end
    ;
    try std.testing.expectError(error.Unsupported, parseServiceBlock(&buf, no_run));

    const bare_run =
        \\  service do
        \\    run
        \\    keep_alive false
        \\  end
    ;
    try std.testing.expectError(error.Unsupported, parseServiceBlock(&buf, bare_run));

    const empty_run =
        \\  service do
        \\    run []
        \\  end
    ;
    try std.testing.expectError(error.Unsupported, parseServiceBlock(&buf, empty_run));

    const too_many =
        \\  service do
        \\    run [opt_bin/"x", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "16"]
        \\  end
    ;
    try std.testing.expectError(error.Unsupported, parseServiceBlock(&buf, too_many));
}

test "parseServiceBlock: a run-less block that names a shipped plist is refused for that reason" {
    // Homebrew's second service shape: the formula installs
    // `<keg>/<label>.plist` itself and only names it. Malt does not adopt
    // shipped plists, but that refusal must not read as a parser gap.
    var buf: [max_service_args][]const u8 = undefined;
    const ships_plist =
        \\  service do
        \\    name macos: "#{plist_name}"
        \\  end
    ;
    try std.testing.expectError(error.ShipsOwnPlist, parseServiceBlock(&buf, ships_plist));

    // `name` may also just rename the label next to a real `run`; that
    // block lifts exactly as before.
    const renamed =
        \\  service do
        \\    name macos: "x"
        \\    run [opt_bin/"x"]
        \\  end
    ;
    const got = (try parseServiceBlock(&buf, renamed)) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(usize, 1), got.run.len);
    try std.testing.expectEqualStrings("opt_bin/\"x\"", got.run[0]);

    // A `name` beside a `run` the scanner cannot follow is still a
    // parser limitation, not a shipped plist.
    const name_with_bad_run =
        \\  service do
        \\    name macos: "x"
        \\    run
        \\  end
    ;
    try std.testing.expectError(error.Unsupported, parseServiceBlock(&buf, name_with_bad_run));

    // A `run` the scanner skips - nested under `on_macos do`, or spelled
    // with parens - is still a run the formula declares, so the block is
    // a scanner limitation, not a shipped plist.
    const name_with_nested_run =
        \\  service do
        \\    name macos: "x"
        \\    on_macos do
        \\      run [opt_bin/"x"]
        \\    end
        \\  end
    ;
    try std.testing.expectError(error.Unsupported, parseServiceBlock(&buf, name_with_nested_run));
    const name_with_paren_run =
        \\  service do
        \\    name macos: "x"
        \\    run([opt_bin/"x"])
        \\  end
    ;
    try std.testing.expectError(error.Unsupported, parseServiceBlock(&buf, name_with_paren_run));
}

test "serviceRefusalReason names each refusal for the install warning" {
    try std.testing.expectEqualStrings("unsupported service block", serviceRefusalReason(error.Unsupported));
    try std.testing.expectEqualStrings("formula ships its own plist, which malt does not adopt", serviceRefusalReason(error.ShipsOwnPlist));
}

test "parseServiceBlock: a trailing Ruby comment does not reach the directive value" {
    // homebrew-core spells `interval 86400 # 24 hours` and `run_type :interval # ...`.
    const rb =
        \\  service do
        \\    run opt_bin/"asimov" # scan
        \\    run_type :interval # every day
        \\    interval 86400 # 24 hours = 60 * 60 * 24
        \\    log_path var/"log/a.log" # "quoted # inside" stays
        \\  end
    ;
    var buf: [max_service_args][]const u8 = undefined;
    const got = (try parseServiceBlock(&buf, rb)) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("opt_bin/\"asimov\"", got.run[0]);
    try std.testing.expect(got.run_type == .interval);
    try std.testing.expectEqual(@as(?u32, 86400), got.interval);
    try std.testing.expectEqualStrings("var/\"log/a.log\"", got.log_path.?);
}

test "parseServiceBlock: unknown directives are skipped, not a parse failure" {
    const rb =
        \\  service do
        \\    run [opt_bin/"x"]
        \\    sudo true
        \\    environment_variables PATH: std_service_path_env
        \\    process_type :background
        \\    restart_delay 5
        \\  end
    ;
    var buf: [max_service_args][]const u8 = undefined;
    const got = (try parseServiceBlock(&buf, rb)) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(usize, 1), got.run.len);
}

test "parseServiceBlock: a desc string mentioning service do does not open a block" {
    const rb =
        \\class Foo < Formula
        \\  desc "runs as a service do not confuse"
        \\  url "https://example.com/foo-1.0.tar.gz"
        \\end
    ;
    var buf: [max_service_args][]const u8 = undefined;
    try std.testing.expect((try parseServiceBlock(&buf, rb)) == null);
}

test "parseServiceBlock: a deeper-indented end does not close the block" {
    const rb =
        \\  service do
        \\    on_macos do
        \\      run [opt_bin/"x", "--nested"]
        \\    end
        \\    run [opt_bin/"x", "--top"]
        \\    keep_alive false
        \\  end
        \\  def post_install
        \\    keep_alive true
        \\  end
    ;
    var buf: [max_service_args][]const u8 = undefined;
    const got = (try parseServiceBlock(&buf, rb)) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("\"--top\"", got.run[1]);
    try std.testing.expect(!got.keep_alive);
}

test "parseServiceBlock: a bracketed dependency reference does not close the argv array" {
    const rb =
        \\  service do
        \\    run [Formula["bash"].opt_bin/"bash", "--login"]
        \\  end
    ;
    var buf: [max_service_args][]const u8 = undefined;
    const got = (try parseServiceBlock(&buf, rb)) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(usize, 2), got.run.len);
    try std.testing.expectEqualStrings("Formula[\"bash\"].opt_bin/\"bash\"", got.run[0]);
    try std.testing.expectEqualStrings("\"--login\"", got.run[1]);
}

test "parseServiceBlock: comments on the opener and the closer still delimit the block" {
    const rb =
        \\  service do # launchd
        \\    run [opt_bin/"svcd"]
        \\  end # service
        \\  def install
        \\    run [opt_bin/"svcd", "--from-def-install"]
        \\  end
    ;
    var buf: [max_service_args][]const u8 = undefined;
    const got = (try parseServiceBlock(&buf, rb)) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(usize, 1), got.run.len);
}
