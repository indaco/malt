//! Pure argv + path helpers used by `cli/install.zig`. Every function
//! here is allocation-free and filesystem-free so tests can call them
//! without fixtures.

const std = @import("std");
const AppCtx = @import("../../app_ctx.zig").AppCtx;

/// Upper bound on MALT_PREFIX byte length. This is a sanity cap, not a
/// correctness gate: the Mach-O relocation pipeline (see
/// `src/core/patch.zig`) grows overflowing load-command slots via
/// `install_name_tool`, so realistic prefixes of any practical length
/// work without preflight rejection. The cap just keeps pathological
/// values from reaching the subprocess.
pub const max_prefix_sane_len: usize = 256;

pub const PrefixError = error{PrefixAbsurd};

/// Reject MALT_PREFIX values past the sanity cap. Exposed so `mt doctor`
/// can reuse the same rule.
pub fn checkPrefixSane(prefix: []const u8) PrefixError!void {
    if (prefix.len > max_prefix_sane_len) return error.PrefixAbsurd;
}

/// True when `arg` resolves to malt itself in any dispatcher-accepted
/// shape: `malt`/`mt`, `<user>/<repo>/malt`, or `*/malt.rb`. The last
/// path segment (with optional `.rb` stripped) is matched against the
/// binary names. `mt update` is the supported upgrade channel.
pub fn isSelfInstall(arg: []const u8) bool {
    const tail = if (std.mem.lastIndexOfScalar(u8, arg, '/')) |i| arg[i + 1 ..] else arg;
    const stem = if (std.mem.endsWith(u8, tail, ".rb")) tail[0 .. tail.len - 3] else tail;
    return std.mem.eql(u8, stem, "malt") or std.mem.eql(u8, stem, "mt");
}

/// Check if a package name is a tap formula (user/repo/formula format).
pub fn isTapFormula(name: []const u8) bool {
    var slash_count: u32 = 0;
    for (name) |ch| {
        if (ch == '/') slash_count += 1;
    }
    return slash_count == 2;
}

/// True when `tap_label` represents one of Homebrew's core taps. Empty
/// or NULL labels also count as core so legacy keg rows that predate
/// the tap-tracking column don't get mis-routed through the tap path.
pub fn isCoreTap(tap_label: []const u8) bool {
    if (tap_label.len == 0) return true;
    if (std.mem.eql(u8, tap_label, "homebrew/core")) return true;
    if (std.mem.eql(u8, tap_label, "homebrew/cask")) return true;
    return false;
}

/// Shape-based detection for a local `.rb` path argument (e.g.
/// `./wget.rb`, `/tmp/wget.rb`, `~/f/wget.rb`, `a/b/c/d.rb`). Pure:
/// no filesystem access, no allocation.
///
/// Tie-break with tap-form: the `.rb` suffix always wins. A bare tap
/// slug `user/repo/formula` has no suffix; `user/repo/formula.rb` is
/// treated as a path so the user does not get a confusing 404 from the
/// tap resolver.
pub fn isLocalFormulaPath(arg: []const u8) bool {
    if (!std.mem.endsWith(u8, arg, ".rb")) return false;
    if (arg.len == 0) return false;
    if (arg[0] == '/' or arg[0] == '~' or arg[0] == '.') return true;
    // Any embedded separator also flags it as a path (e.g. "a/b/c.rb").
    for (arg) |ch| if (ch == '/' or ch == '\\') return true;
    // Bare `wget.rb` with no separator is NOT auto-detected; require
    // `--local` to avoid shadowing a same-named formula on the API.
    return false;
}

/// Parse a tap formula name into user, repo, formula components.
pub fn parseTapName(name: []const u8) ?struct { user: []const u8, repo: []const u8, formula: []const u8 } {
    const first_slash = std.mem.findScalar(u8, name, '/') orelse return null;
    const rest = name[first_slash + 1 ..];
    const second_slash = std.mem.findScalar(u8, rest, '/') orelse return null;
    return .{
        .user = name[0..first_slash],
        .repo = rest[0..second_slash],
        .formula = rest[second_slash + 1 ..],
    };
}

/// True only when `url` is a well-formed `https://` URL with a host
/// component. The local-install path uses this to reject scheme
/// smuggling (file://, ftp://, data:) and downgrade attempts (http://)
/// before we ever hand the URL to the HTTP client. Strict lower-case
/// match keeps the allowlist tamper-resistant; real tap formulas never
/// use mixed-case schemes.
pub fn isAllowedArchiveUrl(url: []const u8) bool {
    const prefix = "https://";
    if (!std.mem.startsWith(u8, url, prefix)) return false;
    const host_and_path = url[prefix.len..];
    // Reject `https://` with nothing after, or a leading slash that
    // would collapse the authority component.
    if (host_and_path.len == 0) return false;
    if (host_and_path[0] == '/') return false;
    return true;
}

/// Interpolate `#{version}` inside a URL. Falls back to the raw URL if
/// the buffer is too small (bufPrint error) — the caller's SHA check
/// will then fail fast if the server serves a different asset.
pub fn interpolateVersion(buf: []u8, url: []const u8, version: []const u8) []const u8 {
    const version_needle = "#" ++ "{version}";
    if (std.mem.indexOf(u8, url, version_needle)) |pos| {
        const before = url[0..pos];
        const after = url[pos + version_needle.len ..];
        return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ before, version, after }) catch url;
    }
    return url;
}

/// Interpolate both `#{version}` and `#{arch}` inside a URL. The arch
/// substitution is what cask DSL multi-arch downloads need — without
/// it, the SHA-verified fetch would 404 because the server never sees
/// a real per-arch suffix. Empty `arch_token` is valid (intel rows in
/// real casks routinely set `intel: ""`); the needle is replaced with
/// nothing rather than skipped. Falls back to the raw URL on any
/// bufPrint overflow so the caller's SHA check fails fast on truncation.
pub fn interpolateUrl(
    buf: []u8,
    url: []const u8,
    version: []const u8,
    arch_token: []const u8,
) []const u8 {
    const version_needle = "#" ++ "{version}";
    const arch_needle = "#" ++ "{arch}";
    const has_version = std.mem.indexOf(u8, url, version_needle) != null;
    const has_arch = std.mem.indexOf(u8, url, arch_needle) != null;
    if (!has_version and !has_arch) return url;

    // Walk the URL once and copy verbatim, expanding either needle at
    // its position. A single pass keeps the API allocation-free and
    // immune to nested substitutions (e.g. an arch token that happens
    // to contain `#{version}` literally is left alone).
    var written: usize = 0;
    var i: usize = 0;
    while (i < url.len) {
        if (has_version and std.mem.startsWith(u8, url[i..], version_needle)) {
            if (written + version.len > buf.len) return url;
            @memcpy(buf[written..][0..version.len], version);
            written += version.len;
            i += version_needle.len;
            continue;
        }
        if (has_arch and std.mem.startsWith(u8, url[i..], arch_needle)) {
            if (written + arch_token.len > buf.len) return url;
            @memcpy(buf[written..][0..arch_token.len], arch_token);
            written += arch_token.len;
            i += arch_needle.len;
            continue;
        }
        if (written + 1 > buf.len) return url;
        buf[written] = url[i];
        written += 1;
        i += 1;
    }
    return buf[0..written];
}

/// Expand a leading `~/` to `$HOME/...`. Returns the input unchanged
/// when no tilde prefix is present. Returns null when `$HOME` is
/// needed but unset.
pub fn expandTildePath(ctx: *const AppCtx, buf: []u8, arg: []const u8) ?[]const u8 {
    if (arg.len < 2 or arg[0] != '~' or arg[1] != '/') return arg;
    const home = std.process.Environ.getPosix(ctx.environ, "HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ home, arg[1..] }) catch null;
}

test "isCoreTap recognises homebrew/core and homebrew/cask" {
    try std.testing.expect(isCoreTap("homebrew/core"));
    try std.testing.expect(isCoreTap("homebrew/cask"));
}

test "isCoreTap treats empty string as core (legacy rows)" {
    // Pre-tap-tracking kegs have NULL/empty `tap`; they must keep
    // routing through the core API path.
    try std.testing.expect(isCoreTap(""));
}

test "isCoreTap rejects third-party tap labels" {
    try std.testing.expect(!isCoreTap("user/repo"));
    try std.testing.expect(!isCoreTap("acme/tools"));
    try std.testing.expect(!isCoreTap("homebrew/services"));
}

test "isCoreTap is exact-match (not prefix)" {
    // `homebrew/core-staging` is a hypothetical fork; treat it as third-party.
    try std.testing.expect(!isCoreTap("homebrew/core-staging"));
    try std.testing.expect(!isCoreTap("homebrew/cask-fonts"));
}
