//! Pure leaf owning every host-shaped tap decision: the URL triple, the
//! raw-`.rb` tail, the HEAD-commit sha parse, and the auth header. A
//! single enum-`switch` per concern means a new forge (GitLab, Codeberg)
//! is a new arm the compiler forces you to handle — never a scattered
//! edit across call sites. Imports neither `cli/*` nor `ui/*` (guarded by
//! `tests/forge_purity_test.zig`); never renders user-facing strings.

const std = @import("std");

/// Source forge hosting a tap repo. GitHub is the only variant today;
/// GitLab/Codeberg arrive as new arms, each forcing an exhaustive-switch
/// compile error until every concern below handles it.
pub const Forge = enum { github };

const github_browse_fmt = "https://github.com/{s}/{s}";

/// Browse URL for `taps.url`, written into a caller buffer. `host` is
/// plumbed for non-github arms; the github arm's host is fixed.
pub fn repoBrowseUrl(
    buf: []u8,
    forge: Forge,
    host: []const u8,
    owner: []const u8,
    repo: []const u8,
) std.fmt.BufPrintError![]const u8 {
    _ = host;
    return switch (forge) {
        .github => std.fmt.bufPrint(buf, github_browse_fmt, .{ owner, repo }),
    };
}

/// Allocating sibling of `repoBrowseUrl` for the read-time projection in
/// `list`, where each row owns its slice. Same bytes as the buffered form.
pub fn allocRepoBrowseUrl(
    allocator: std.mem.Allocator,
    forge: Forge,
    host: []const u8,
    owner: []const u8,
    repo: []const u8,
) std.mem.Allocator.Error![]const u8 {
    _ = host;
    return switch (forge) {
        .github => std.fmt.allocPrint(allocator, github_browse_fmt, .{ owner, repo }),
    };
}

/// Which tap subtree a raw `.rb` lives under. The `Formula/` vs
/// `Casks/` split callers used to inline as a string literal.
pub const RawKind = enum {
    formula,
    cask,

    fn subdir(self: RawKind) []const u8 {
        return switch (self) {
            .formula => "Formula",
            .cask => "Casks",
        };
    }
};

/// Build a raw `.rb` URL into `buf` by appending the
/// `<sha>/<subdir>/<name>.rb` tail to a forge's `raw_base`. GitHub's
/// raw layout puts the sha right after the base; other forges differ
/// only in `raw_base` (the infix), so the tail is uniform here today.
pub fn rawFileUrl(
    buf: []u8,
    forge: Forge,
    raw_base: []const u8,
    sha: []const u8,
    kind: RawKind,
    name: []const u8,
) std.fmt.BufPrintError![]const u8 {
    return switch (forge) {
        .github => std.fmt.bufPrint(buf, "{s}/{s}/{s}/{s}.rb", .{
            raw_base, sha, kind.subdir(), name,
        }),
    };
}

/// Map a host to its forge. Defaults to `.github` — the only variant
/// today; the `host` argument is plumbed now so AP-002 only feeds it,
/// never re-threads signatures.
pub fn fromHost(host: []const u8) Forge {
    _ = host;
    return .github;
}

/// URLs every tap fetch site needs. For raw fetches callers append the
/// `<sha>/Formula/<name>.rb` (or `Casks/`) tail via `rawFileUrl`.
pub const TapBaseUrls = struct {
    /// `https://api.github.com/repos/<owner>/<repo>/commits/HEAD`
    api_head_url: []const u8,
    /// `https://github.com/<owner>/<repo>` — the URL that actually
    /// resolves; mirrored into `taps.url` at INSERT/rebind time.
    repo_url: []const u8,
    /// `https://raw.githubusercontent.com/<owner>/<repo>` — `rawFileUrl`
    /// appends the `<sha>/Formula/<name>.rb` or `Casks/` tail.
    raw_base: []const u8,

    pub fn deinit(self: TapBaseUrls, allocator: std.mem.Allocator) void {
        allocator.free(self.api_head_url);
        allocator.free(self.repo_url);
        allocator.free(self.raw_base);
    }
};

/// Build the URL triple for a tap repo. `host` is plumbed for the
/// non-GitHub arms (AP-002 feeds it from the row); the github arm's
/// hosts are fixed, so it ignores `host` today.
pub fn buildBaseUrls(
    allocator: std.mem.Allocator,
    forge: Forge,
    host: []const u8,
    owner: []const u8,
    repo: []const u8,
) std.mem.Allocator.Error!TapBaseUrls {
    switch (forge) {
        .github => {
            _ = host; // github hosts are fixed; host drives only non-github arms
            const api_head_url = try std.fmt.allocPrint(
                allocator,
                "https://api.github.com/repos/{s}/{s}/commits/HEAD",
                .{ owner, repo },
            );
            errdefer allocator.free(api_head_url);

            const repo_url = try std.fmt.allocPrint(
                allocator,
                "https://github.com/{s}/{s}",
                .{ owner, repo },
            );
            errdefer allocator.free(repo_url);

            const raw_base = try std.fmt.allocPrint(
                allocator,
                "https://raw.githubusercontent.com/{s}/{s}",
                .{ owner, repo },
            );
            errdefer allocator.free(raw_base);

            return .{ .api_head_url = api_head_url, .repo_url = repo_url, .raw_base = raw_base };
        },
    }
}

/// Build the per-forge auth header into `buf` from the forge's token
/// env var, or null when unset/empty. GitHub: `Authorization: Bearer
/// <MALT_GITHUB_TOKEN>`. The reach is deliberately narrow — only the
/// tap-resolution caller passes this header — so the token never leaks
/// onto unrelated requests.
pub fn authHeader(forge: Forge, environ: std.process.Environ, buf: []u8) ?std.http.Header {
    switch (forge) {
        .github => {
            const raw = std.process.Environ.getPosix(environ, "MALT_GITHUB_TOKEN") orelse return null;
            if (raw.len == 0) return null;
            const value = std.fmt.bufPrint(buf, "Bearer {s}", .{raw}) catch return null;
            return .{ .name = "Authorization", .value = value };
        },
    }
}

/// A 40-char lowercase hex commit SHA — git's printable form. Kept
/// leaf-local so `forge` never reaches into `tap`'s `validateCommitSha`
/// (which carries `TapError` + row semantics this module must not pull in).
fn isCommitSha(sha: []const u8) bool {
    if (sha.len != 40) return false;
    for (sha) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// Pull the HEAD commit sha out of a forge's `commits/HEAD` response.
/// GitHub: the first top-level `"sha"` string, validated as 40-char
/// lowercase hex. Untrusted input — malformed or unexpected shapes
/// return null rather than a misleading sha. The result borrows from
/// `body`; the caller dupes it.
pub fn parseHeadSha(forge: Forge, body: []const u8) ?[]const u8 {
    switch (forge) {
        .github => {
            // First top-level `"sha"` takes the value — GitHub always emits
            // the commit SHA before the nested tree/parent objects.
            const marker = "\"sha\"";
            const idx = std.mem.indexOf(u8, body, marker) orelse return null;
            var cur = idx + marker.len;
            while (cur < body.len and (body[cur] == ' ' or body[cur] == ':' or body[cur] == '\t')) : (cur += 1) {}
            if (cur >= body.len or body[cur] != '"') return null;
            cur += 1;
            const end = std.mem.indexOfScalarPos(u8, body, cur, '"') orelse return null;
            const sha = body[cur..end];
            if (!isCommitSha(sha)) return null;
            return sha;
        },
    }
}

test "fromHost classifies github.com as .github" {
    try std.testing.expectEqual(Forge.github, fromHost("github.com"));
}

test "fromHost defaults unknown hosts to .github (only variant today)" {
    try std.testing.expectEqual(Forge.github, fromHost("example.com"));
}

// ── parseHeadSha (github) ──────────────────────────────────────────
// Security-sensitive: picking up the wrong "sha" field would pin malt
// to an attacker-influenced commit instead of the real HEAD. Exhaustive
// coverage of shapes a real GitHub `commits/HEAD` response can take.

const valid_sha_fixture = "0123456789abcdef0123456789abcdef01234567";

test "parseHeadSha github: canonical GitHub response" {
    const body =
        \\{"sha":"0123456789abcdef0123456789abcdef01234567","node_id":"X","commit":{"author":{"name":"x"}}}
    ;
    const got = parseHeadSha(.github, body) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(valid_sha_fixture, got);
}

test "parseHeadSha github: tolerates whitespace around ':' and value" {
    const body =
        \\{  "sha"  :  "0123456789abcdef0123456789abcdef01234567" , "other": 1 }
    ;
    const got = parseHeadSha(.github, body) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(valid_sha_fixture, got);
}

test "parseHeadSha github: returns first top-level sha even when nested sha exists" {
    const body =
        \\{"sha":"0123456789abcdef0123456789abcdef01234567","commit":{"tree":{"sha":"ffffffffffffffffffffffffffffffffffffffff"}}}
    ;
    const got = parseHeadSha(.github, body) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(valid_sha_fixture, got);
}

test "parseHeadSha github: missing sha field yields null" {
    const body =
        \\{"node_id":"X","commit":{"author":{"name":"x"}}}
    ;
    try std.testing.expectEqual(@as(?[]const u8, null), parseHeadSha(.github, body));
}

test "parseHeadSha github: non-string value yields null" {
    const body =
        \\{"sha": 42}
    ;
    try std.testing.expectEqual(@as(?[]const u8, null), parseHeadSha(.github, body));
}

test "parseHeadSha github: truncated value yields null" {
    const body =
        \\{"sha":"deadbeef
    ;
    try std.testing.expectEqual(@as(?[]const u8, null), parseHeadSha(.github, body));
}

test "parseHeadSha github: malformed SHA value yields null" {
    const body =
        \\{"sha":"not-a-valid-sha"}
    ;
    try std.testing.expectEqual(@as(?[]const u8, null), parseHeadSha(.github, body));
}

test "parseHeadSha github: empty body yields null" {
    try std.testing.expectEqual(@as(?[]const u8, null), parseHeadSha(.github, ""));
}

test "parseHeadSha github: uppercase hex in value is rejected" {
    const body =
        \\{"sha":"0123456789ABCDEF0123456789ABCDEF01234567"}
    ;
    try std.testing.expectEqual(@as(?[]const u8, null), parseHeadSha(.github, body));
}

// ── authHeader (github) ────────────────────────────────────────────
// Only the `/commits/HEAD` call picks up MALT_GITHUB_TOKEN. The Bearer
// format must match GitHub's contract. Environs are constructed inline
// so the test never mutates real process state.

fn envWith(comptime entries: anytype) std.process.Environ {
    const slice = entries;
    return .{ .block = .{ .slice = slice[0..slice.len :null] } };
}

test "authHeader github: null when MALT_GITHUB_TOKEN unset" {
    var buf: [256]u8 = undefined;
    try std.testing.expect(authHeader(.github, .empty, &buf) == null);
}

test "authHeader github: Bearer header when MALT_GITHUB_TOKEN set" {
    const entries = [_:null]?[*:0]const u8{"MALT_GITHUB_TOKEN=ghp_testtoken"};
    var buf: [256]u8 = undefined;
    const h = authHeader(.github, envWith(entries), &buf) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("Authorization", h.name);
    try std.testing.expectEqualStrings("Bearer ghp_testtoken", h.value);
}

test "authHeader github: empty-string token behaves as unset" {
    const entries = [_:null]?[*:0]const u8{"MALT_GITHUB_TOKEN="};
    var buf: [256]u8 = undefined;
    try std.testing.expect(authHeader(.github, envWith(entries), &buf) == null);
}

// ── buildBaseUrls (github) ─────────────────────────────────────────
// The URL triple every tap fetch site needs. Byte shapes are the
// contract — `core/tap.zig`'s resolve path and every install/upgrade
// caller depend on them being identical to today.

test "buildBaseUrls github: builds the api-head / repo / raw triple" {
    const urls = try buildBaseUrls(std.testing.allocator, .github, "github.com", "aeroxy", "ast-outline");
    defer urls.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "https://api.github.com/repos/aeroxy/ast-outline/commits/HEAD",
        urls.api_head_url,
    );
    try std.testing.expectEqualStrings("https://github.com/aeroxy/ast-outline", urls.repo_url);
    try std.testing.expectEqualStrings("https://raw.githubusercontent.com/aeroxy/ast-outline", urls.raw_base);
}

test "buildBaseUrls github: preserves hyphens and dots in the repo component" {
    const urls = try buildBaseUrls(std.testing.allocator, .github, "github.com", "user-1", "homebrew-some-tap.v2");
    defer urls.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "https://api.github.com/repos/user-1/homebrew-some-tap.v2/commits/HEAD",
        urls.api_head_url,
    );
}

fn buildAndFree(allocator: std.mem.Allocator) !void {
    const urls = try buildBaseUrls(allocator, .github, "github.com", "user", "homebrew-repo");
    urls.deinit(allocator);
}

test "buildBaseUrls github: no leak on any allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildAndFree, .{});
}

// ── rawFileUrl (github) ────────────────────────────────────────────
// The `<sha>/Formula/<name>.rb` vs `Casks/` tail tap install/upgrade
// callers used to append inline. Centralised so a forge with a
// different raw layout is one arm, not edits at every fetch site.

const raw_sha_fixture = "0123456789abcdef0123456789abcdef01234567";
const github_raw_base = "https://raw.githubusercontent.com/aeroxy/ast-outline";

test "rawFileUrl github: formula kind builds the Formula/ tail" {
    var buf: [512]u8 = undefined;
    const url = try rawFileUrl(&buf, .github, github_raw_base, raw_sha_fixture, .formula, "glow");
    try std.testing.expectEqualStrings(
        github_raw_base ++ "/" ++ raw_sha_fixture ++ "/Formula/glow.rb",
        url,
    );
}

test "rawFileUrl github: cask kind builds the Casks/ tail" {
    var buf: [512]u8 = undefined;
    const url = try rawFileUrl(&buf, .github, github_raw_base, raw_sha_fixture, .cask, "glow");
    try std.testing.expectEqualStrings(
        github_raw_base ++ "/" ++ raw_sha_fixture ++ "/Casks/glow.rb",
        url,
    );
}

test "rawFileUrl github: overflowing buffer surfaces NoSpaceLeft" {
    var buf: [8]u8 = undefined;
    try std.testing.expectError(
        error.NoSpaceLeft,
        rawFileUrl(&buf, .github, github_raw_base, raw_sha_fixture, .formula, "glow"),
    );
}

// ── browse URL (github) ────────────────────────────────────────────
// The `taps.url` projection: the URL that actually resolves in a
// browser, written at INSERT/rebind and re-derived in `list`. Both
// shapes must agree byte-for-byte, hence one seam.

test "repoBrowseUrl github: writes the github.com browse URL into a buffer" {
    var buf: [256]u8 = undefined;
    const url = try repoBrowseUrl(&buf, .github, "github.com", "user", "homebrew-repo");
    try std.testing.expectEqualStrings("https://github.com/user/homebrew-repo", url);
}

test "allocRepoBrowseUrl github: allocates the same browse URL" {
    const url = try allocRepoBrowseUrl(std.testing.allocator, .github, "github.com", "aeroxy", "ast-outline");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://github.com/aeroxy/ast-outline", url);
}

fn browseAndFree(allocator: std.mem.Allocator) !void {
    const url = try allocRepoBrowseUrl(allocator, .github, "github.com", "user", "homebrew-repo");
    allocator.free(url);
}

test "allocRepoBrowseUrl github: no leak on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, browseAndFree, .{});
}
