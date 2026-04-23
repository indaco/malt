//! Pure argv + path helpers used by `cli/install.zig`. Every function
//! here is allocation-free and filesystem-free so tests can call them
//! without fixtures.

const std = @import("std");
const fs_compat = @import("../../fs/compat.zig");

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

/// Check if a package name is a tap formula (user/repo/formula format).
pub fn isTapFormula(name: []const u8) bool {
    var slash_count: u32 = 0;
    for (name) |ch| {
        if (ch == '/') slash_count += 1;
    }
    return slash_count == 2;
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

/// Expand a leading `~/` to `$HOME/...`. Returns the input unchanged
/// when no tilde prefix is present. Returns null when `$HOME` is
/// needed but unset.
pub fn expandTildePath(buf: []u8, arg: []const u8) ?[]const u8 {
    if (arg.len < 2 or arg[0] != '~' or arg[1] != '/') return arg;
    const home = fs_compat.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ home, arg[1..] }) catch null;
}
