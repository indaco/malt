//! Pure leaf owning every host-shaped tap decision: the URL triple, the
//! raw-`.rb` tail, the HEAD-commit sha parse, and the auth header. A
//! single enum-`switch` per concern means a new forge (GitLab, Codeberg)
//! is a new arm the compiler forces you to handle — never a scattered
//! edit across call sites. Imports neither `cli/*` nor `ui/*` (guarded by
//! `tests/forge_purity_test.zig`); never renders user-facing strings.

const std = @import("std");

/// Source forge hosting a tap repo. Each variant forces an
/// exhaustive-switch compile error until every concern below handles it,
/// so a new forge can never be half-wired.
pub const Forge = enum { github, gitlab, codeberg };

const github_browse_fmt = "https://github.com/{s}/{s}";
// GitLab's browse, repo, and `/-/raw` URLs all share the instance host,
// so the host (not a literal) prefixes each.
const gitlab_browse_fmt = "https://{s}/{s}/{s}";

/// Browse URL for `taps.url`, written into a caller buffer. `host` is
/// plumbed for non-github arms; the github arm's host is fixed.
pub fn repoBrowseUrl(
    buf: []u8,
    forge: Forge,
    host: []const u8,
    owner: []const u8,
    repo: []const u8,
) std.fmt.BufPrintError![]const u8 {
    return switch (forge) {
        .github => std.fmt.bufPrint(buf, github_browse_fmt, .{ owner, repo }),
        // gitlab and codeberg both browse at the instance host.
        .gitlab, .codeberg => std.fmt.bufPrint(buf, gitlab_browse_fmt, .{ host, owner, repo }),
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
    return switch (forge) {
        .github => std.fmt.allocPrint(allocator, github_browse_fmt, .{ owner, repo }),
        .gitlab, .codeberg => std.fmt.allocPrint(allocator, gitlab_browse_fmt, .{ host, owner, repo }),
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
        // Same tail for all: the forge-specific infix already lives in
        // `raw_base` (github: bare; gitlab: `/-/raw`; codeberg: `/raw`).
        .github, .gitlab, .codeberg => std.fmt.bufPrint(buf, "{s}/{s}/{s}/{s}.rb", .{
            raw_base, sha, kind.subdir(), name,
        }),
    };
}

/// Map a host to its forge. Defaults to `.github` — the only variant
/// today; the `host` argument is plumbed now so AP-002 only feeds it,
/// never re-threads signatures.
pub fn fromHost(host: []const u8) Forge {
    // Narrow `gitlab.` prefix (covers gitlab.com and self-hosted
    // gitlab.<org>); a look-alike like notgitlab.com must not match.
    if (std.mem.startsWith(u8, host, "gitlab.")) return .gitlab;
    // codeberg.org is the only name-detectable Gitea host; an exact match
    // keeps a look-alike like notcodeberg.org from auto-classifying.
    // Self-hosted Forgejo uses explicit `--forge codeberg` registration.
    if (std.mem.eql(u8, host, "codeberg.org")) return .codeberg;
    return .github;
}

/// URLs every tap fetch site needs. For raw fetches callers append the
/// `<sha>/Formula/<name>.rb` (or `Casks/`) tail via `rawFileUrl`.
pub const TapBaseUrls = struct {
    /// The forge these URLs were built for. Carried so resolve sites pick
    /// the right HEAD parse and auth header without re-deriving it.
    forge: Forge,
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

const upper_hex = "0123456789ABCDEF";

/// RFC 3986 unreserved set — the bytes `encodeProjectPath` leaves intact.
fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

/// Percent-encode `owner/repo` into `buf` as GitLab's v4 `:id` segment
/// (`owner%2Frepo`). Every byte outside the unreserved set is escaped —
/// the `/` separator included — so a subgroup path or an odd repo name
/// can't break out of the URL segment. Caller sizes `buf`.
fn encodeProjectPath(buf: []u8, owner: []const u8, repo: []const u8) error{NoSpaceLeft}![]const u8 {
    var n: usize = 0;
    for ([_][]const u8{ owner, "/", repo }) |part| {
        for (part) |c| {
            if (isUnreserved(c)) {
                if (n >= buf.len) return error.NoSpaceLeft;
                buf[n] = c;
                n += 1;
            } else {
                if (n + 3 > buf.len) return error.NoSpaceLeft;
                buf[n] = '%';
                buf[n + 1] = upper_hex[c >> 4];
                buf[n + 2] = upper_hex[c & 0x0f];
                n += 3;
            }
        }
    }
    return buf[0..n];
}

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
            // github hosts are fixed; only the gitlab arm consults `host`.
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

            return .{ .forge = forge, .api_head_url = api_head_url, .repo_url = repo_url, .raw_base = raw_base };
        },
        .gitlab => {
            // Worst case every byte escapes to 3 chars; the "/" separator too.
            const enc_cap = (owner.len + 1 + repo.len) * 3;
            const enc = try allocator.alloc(u8, enc_cap);
            defer allocator.free(enc);
            // enc is sized for the worst case, so encoding cannot overflow it.
            const path = encodeProjectPath(enc, owner, repo) catch unreachable;

            const api_head_url = try std.fmt.allocPrint(
                allocator,
                "https://{s}/api/v4/projects/{s}/repository/commits/HEAD",
                .{ host, path },
            );
            errdefer allocator.free(api_head_url);

            const repo_url = try std.fmt.allocPrint(allocator, gitlab_browse_fmt, .{ host, owner, repo });
            errdefer allocator.free(repo_url);

            const raw_base = try std.fmt.allocPrint(allocator, "https://{s}/{s}/{s}/-/raw", .{ host, owner, repo });
            errdefer allocator.free(raw_base);

            return .{ .forge = forge, .api_head_url = api_head_url, .repo_url = repo_url, .raw_base = raw_base };
        },
        .codeberg => {
            // Gitea's v1 API keys by plain owner/repo (no URL-encoding,
            // unlike gitlab); `commits?limit=1` returns a one-element array
            // so HEAD costs one round-trip. Raw has no `/-/` infix. All
            // three URLs ride the row's `host` for self-hosted Forgejo.
            const api_head_url = try std.fmt.allocPrint(
                allocator,
                "https://{s}/api/v1/repos/{s}/{s}/commits?limit=1&stat=false",
                .{ host, owner, repo },
            );
            errdefer allocator.free(api_head_url);

            const repo_url = try std.fmt.allocPrint(allocator, gitlab_browse_fmt, .{ host, owner, repo });
            errdefer allocator.free(repo_url);

            const raw_base = try std.fmt.allocPrint(allocator, "https://{s}/{s}/{s}/raw", .{ host, owner, repo });
            errdefer allocator.free(raw_base);

            return .{ .forge = forge, .api_head_url = api_head_url, .repo_url = repo_url, .raw_base = raw_base };
        },
    }
}

/// Build the `commits/<sha>` URL for a tap repo — the pin-verb sibling of
/// `buildBaseUrls`'s `api_head_url`. `mt tap --pin` hits it to prove a SHA
/// is reachable on the tap's **own** forge, so a non-github tap never
/// routes its check at api.github.com. `host` drives the non-github arms;
/// the github arm's host is fixed. Caller owns the result.
pub fn commitUrl(
    allocator: std.mem.Allocator,
    forge_kind: Forge,
    host: []const u8,
    owner: []const u8,
    repo: []const u8,
    sha: []const u8,
) std.mem.Allocator.Error![]const u8 {
    switch (forge_kind) {
        .github => return std.fmt.allocPrint(
            allocator,
            "https://api.github.com/repos/{s}/{s}/commits/{s}",
            .{ owner, repo, sha },
        ),
        .gitlab => {
            // v4 keys by the URL-encoded project path, like buildBaseUrls;
            // worst case every byte (the "/" separator too) escapes to 3.
            const enc_cap = (owner.len + 1 + repo.len) * 3;
            const enc = try allocator.alloc(u8, enc_cap);
            defer allocator.free(enc);
            // enc is sized for the worst case, so encoding cannot overflow it.
            const path = encodeProjectPath(enc, owner, repo) catch unreachable;
            return std.fmt.allocPrint(
                allocator,
                "https://{s}/api/v4/projects/{s}/repository/commits/{s}",
                .{ host, path, sha },
            );
        },
        // Gitea/Forgejo serve a single commit at `git/commits/<sha>` (the
        // git-data route); the bare `commits/<sha>` verb 404s. Keyed by
        // plain owner/repo (no encoding) on the instance host.
        .codeberg => return std.fmt.allocPrint(
            allocator,
            "https://{s}/api/v1/repos/{s}/{s}/git/commits/{s}",
            .{ host, owner, repo, sha },
        ),
    }
}

/// Auth header for the forge's **API** request (the `commits/HEAD`
/// call), built into `buf` from the forge's token env var, or null when
/// unset/empty. The token contract is one env var per forge, keyed by
/// forge rather than by host, so a self-hosted instance reuses its
/// forge's var:
///   - github:   `MALT_GITHUB_TOKEN`   → `Authorization: Bearer <t>`
///   - gitlab:   `MALT_GITLAB_TOKEN`   → `PRIVATE-TOKEN: <t>`
///   - codeberg: `MALT_CODEBERG_TOKEN` → `Authorization: token <t>`
/// The reach is deliberately narrow — only the tap-resolution callers
/// pass this header — so the token never leaks onto unrelated requests.
pub fn authHeader(forge: Forge, environ: std.process.Environ, buf: []u8) ?std.http.Header {
    switch (forge) {
        .github => {
            const raw = std.process.Environ.getPosix(environ, "MALT_GITHUB_TOKEN") orelse return null;
            if (raw.len == 0) return null;
            const value = std.fmt.bufPrint(buf, "Bearer {s}", .{raw}) catch return null;
            return .{ .name = "Authorization", .value = value };
        },
        .gitlab => return gitlabPrivateToken(environ, buf),
        .codeberg => return codebergToken(environ, buf),
    }
}

/// GitLab's `PRIVATE-TOKEN` header from `MALT_GITLAB_TOKEN`, or null when
/// unset/empty. Shared by the API and the instance-host raw fetch — both
/// authenticate the same way, against the same host.
fn gitlabPrivateToken(environ: std.process.Environ, buf: []u8) ?std.http.Header {
    const raw = std.process.Environ.getPosix(environ, "MALT_GITLAB_TOKEN") orelse return null;
    if (raw.len == 0) return null;
    // Bare PAT — no scheme prefix, unlike github's Bearer.
    const value = std.fmt.bufPrint(buf, "{s}", .{raw}) catch return null;
    return .{ .name = "PRIVATE-TOKEN", .value = value };
}

/// Gitea/Forgejo's `Authorization: token <PAT>` header from
/// `MALT_CODEBERG_TOKEN`, or null when unset/empty. Shared by the API and
/// the instance-host raw fetch — both authenticate the same way, against
/// the same host. The `token` scheme is Gitea's, not github's `Bearer`.
fn codebergToken(environ: std.process.Environ, buf: []u8) ?std.http.Header {
    const raw = std.process.Environ.getPosix(environ, "MALT_CODEBERG_TOKEN") orelse return null;
    if (raw.len == 0) return null;
    const value = std.fmt.bufPrint(buf, "token {s}", .{raw}) catch return null;
    return .{ .name = "Authorization", .value = value };
}

/// Auth header for a **raw `.rb`** fetch, or null when the forge's raw
/// host needs none. GitHub serves raw content from a separate public CDN
/// (`raw.githubusercontent.com`) the API token does not belong to —
/// attaching it there would only widen the token's reach, so the github
/// raw fetch stays unauthenticated, exactly as before. Forges whose raw
/// path lives on the authenticated instance host attach their token here.
pub fn rawAuthHeader(forge: Forge, environ: std.process.Environ, buf: []u8) ?std.http.Header {
    return switch (forge) {
        .github => null,
        .gitlab => gitlabPrivateToken(environ, buf),
        // Gitea serves `/raw` from the authenticated instance host, like gitlab.
        .codeberg => codebergToken(environ, buf),
    };
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

/// First top-level `<marker>` string value, validated as a 40-char hex
/// sha. `marker` carries its own quotes (`"sha"`, `"id"`) so it can't
/// match a longer key (`"short_id"` won't match `"id"`). Untrusted input —
/// malformed/unexpected shapes return null. Result borrows from `body`.
fn firstShaField(body: []const u8, marker: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, body, marker) orelse return null;
    var cur = idx + marker.len;
    while (cur < body.len and (body[cur] == ' ' or body[cur] == ':' or body[cur] == '\t')) : (cur += 1) {}
    if (cur >= body.len or body[cur] != '"') return null;
    cur += 1;
    const end = std.mem.indexOfScalarPos(u8, body, cur, '"') orelse return null;
    const sha = body[cur..end];
    if (!isCommitSha(sha)) return null;
    return sha;
}

/// Pull the HEAD commit sha out of a forge's `commits/HEAD` response, as
/// the caller dupes it. The shape differs only in the leading key:
/// GitHub emits `"sha"` first; GitLab emits `"id"` (not `sha`) first.
/// Codeberg/Gitea wraps the same GitHub-shaped `"sha"` in a one-element
/// array, so the first-field scan finds it without parsing the array — an
/// empty `[]` simply has no `"sha"` and falls through to null.
pub fn parseHeadSha(forge: Forge, body: []const u8) ?[]const u8 {
    return switch (forge) {
        .github, .codeberg => firstShaField(body, "\"sha\""),
        .gitlab => firstShaField(body, "\"id\""),
    };
}

test "fromHost classifies github.com as .github" {
    try std.testing.expectEqual(Forge.github, fromHost("github.com"));
}

test "fromHost defaults non-gitlab hosts to .github" {
    try std.testing.expectEqual(Forge.github, fromHost("example.com"));
}

test "fromHost classifies gitlab.com as .gitlab" {
    try std.testing.expectEqual(Forge.gitlab, fromHost("gitlab.com"));
}

test "fromHost classifies a self-hosted gitlab.* instance as .gitlab" {
    try std.testing.expectEqual(Forge.gitlab, fromHost("gitlab.gnome.org"));
}

test "fromHost leaves a gitlab look-alike host as .github" {
    // The match is a narrow `gitlab.` prefix, not a substring: a name like
    // `notgitlab.com` must not auto-classify. Self-hosted instances that
    // aren't named gitlab.* use explicit registration, not host sniffing.
    try std.testing.expectEqual(Forge.github, fromHost("notgitlab.com"));
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

// ── parseHeadSha (gitlab) ──────────────────────────────────────────
// GitLab's commit object leads with `"id":"<sha>"` (note: id, not sha).
// Same untrusted-input discipline as github: malformed shapes return
// null so resolve reports MalformedJson rather than pinning a bad sha.

test "parseHeadSha gitlab: canonical GitLab commit response" {
    const body =
        \\{"id":"0123456789abcdef0123456789abcdef01234567","short_id":"01234567","title":"x"}
    ;
    const got = parseHeadSha(.gitlab, body) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(valid_sha_fixture, got);
}

test "parseHeadSha gitlab: short_id does not shadow the full id" {
    // The `"id"` marker must not match inside `"short_id"` — a false
    // match there would yield the 8-char short id, not the 40-hex sha.
    const body =
        \\{"id":"0123456789abcdef0123456789abcdef01234567","short_id":"01234567"}
    ;
    const got = parseHeadSha(.gitlab, body) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(valid_sha_fixture, got);
}

test "parseHeadSha gitlab: missing id field yields null" {
    const body =
        \\{"short_id":"01234567","title":"x"}
    ;
    try std.testing.expectEqual(@as(?[]const u8, null), parseHeadSha(.gitlab, body));
}

test "parseHeadSha gitlab: short (malformed) id yields null" {
    const body =
        \\{"id":"0123456","short_id":"0123456"}
    ;
    try std.testing.expectEqual(@as(?[]const u8, null), parseHeadSha(.gitlab, body));
}

test "parseHeadSha gitlab: non-string id value yields null" {
    const body =
        \\{"id": 42}
    ;
    try std.testing.expectEqual(@as(?[]const u8, null), parseHeadSha(.gitlab, body));
}

test "parseHeadSha gitlab: empty body yields null" {
    try std.testing.expectEqual(@as(?[]const u8, null), parseHeadSha(.gitlab, ""));
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

test "rawAuthHeader github: null even when MALT_GITHUB_TOKEN is set" {
    // The API token belongs to api.github.com, not the raw CDN — the raw
    // fetch stays unauthenticated so the token's reach never widens.
    const entries = [_:null]?[*:0]const u8{"MALT_GITHUB_TOKEN=ghp_testtoken"};
    var buf: [256]u8 = undefined;
    try std.testing.expect(rawAuthHeader(.github, envWith(entries), &buf) == null);
    try std.testing.expect(rawAuthHeader(.github, .empty, &buf) == null);
}

// ── authHeader (gitlab) ────────────────────────────────────────────
// GitLab authenticates with a bare PAT under the PRIVATE-TOKEN header —
// no `Bearer` prefix. MALT_GITLAB_TOKEN keys it (one var per forge), so
// a self-hosted instance reuses its forge's var.

test "authHeader gitlab: null when MALT_GITLAB_TOKEN unset" {
    var buf: [256]u8 = undefined;
    try std.testing.expect(authHeader(.gitlab, .empty, &buf) == null);
}

test "authHeader gitlab: PRIVATE-TOKEN header when MALT_GITLAB_TOKEN set" {
    const entries = [_:null]?[*:0]const u8{"MALT_GITLAB_TOKEN=glpat-xyz"};
    var buf: [256]u8 = undefined;
    const h = authHeader(.gitlab, envWith(entries), &buf) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("PRIVATE-TOKEN", h.name);
    try std.testing.expectEqualStrings("glpat-xyz", h.value);
}

test "authHeader gitlab: empty-string token behaves as unset" {
    const entries = [_:null]?[*:0]const u8{"MALT_GITLAB_TOKEN="};
    var buf: [256]u8 = undefined;
    try std.testing.expect(authHeader(.gitlab, envWith(entries), &buf) == null);
}

test "rawAuthHeader gitlab: PRIVATE-TOKEN attached — raw lives on the instance host" {
    // Unlike github's separate public raw CDN, gitlab serves `/-/raw` from
    // the authenticated instance host, so a private tap's raw fetch carries
    // the token. Same var, same header as the API call.
    const entries = [_:null]?[*:0]const u8{"MALT_GITLAB_TOKEN=glpat-xyz"};
    var buf: [256]u8 = undefined;
    const h = rawAuthHeader(.gitlab, envWith(entries), &buf) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("PRIVATE-TOKEN", h.name);
    try std.testing.expectEqualStrings("glpat-xyz", h.value);
}

test "rawAuthHeader gitlab: null when MALT_GITLAB_TOKEN unset" {
    var buf: [256]u8 = undefined;
    try std.testing.expect(rawAuthHeader(.gitlab, .empty, &buf) == null);
}

// ── buildBaseUrls (github) ─────────────────────────────────────────
// The URL triple every tap fetch site needs. Byte shapes are the
// contract — `core/tap.zig`'s resolve path and every install/upgrade
// caller depend on them being identical to today.

test "buildBaseUrls github: records the originating forge on the result" {
    // The row's forge must ride along with the URL triple so resolve sites
    // (auth + body parse) consult it without re-deriving it from the host.
    const urls = try buildBaseUrls(std.testing.allocator, .github, "github.com", "o", "r");
    defer urls.deinit(std.testing.allocator);
    try std.testing.expectEqual(Forge.github, urls.forge);
}

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

// ── browse URL (gitlab) ────────────────────────────────────────────
// Unlike github, the host is not fixed: a self-hosted instance domain
// must drive the URL, so the row's `host` is the source of truth.

test "repoBrowseUrl gitlab: the instance host drives the browse URL" {
    var buf: [256]u8 = undefined;
    const url = try repoBrowseUrl(&buf, .gitlab, "gitlab.gnome.org", "GNOME", "glib");
    try std.testing.expectEqualStrings("https://gitlab.gnome.org/GNOME/glib", url);
}

test "allocRepoBrowseUrl gitlab: allocates the instance-host browse URL" {
    const url = try allocRepoBrowseUrl(std.testing.allocator, .gitlab, "gitlab.com", "grp", "tap");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://gitlab.com/grp/tap", url);
}

// ── buildBaseUrls (gitlab) ─────────────────────────────────────────
// GitLab keys the v4 API by the URL-encoded project path (owner%2Frepo),
// serves raw files under `/-/raw`, and browses at the instance host —
// all three driven by the row's `host`, never a literal, so self-hosted
// instances resolve against their own domain.

test "buildBaseUrls gitlab: builds the encoded v4 / raw / browse triple" {
    const urls = try buildBaseUrls(std.testing.allocator, .gitlab, "gitlab.com", "o", "r");
    defer urls.deinit(std.testing.allocator);
    try std.testing.expectEqual(Forge.gitlab, urls.forge);
    try std.testing.expectEqualStrings(
        "https://gitlab.com/api/v4/projects/o%2Fr/repository/commits/HEAD",
        urls.api_head_url,
    );
    try std.testing.expectEqualStrings("https://gitlab.com/o/r", urls.repo_url);
    try std.testing.expectEqualStrings("https://gitlab.com/o/r/-/raw", urls.raw_base);
}

test "buildBaseUrls gitlab: a self-hosted instance host drives every URL" {
    const urls = try buildBaseUrls(std.testing.allocator, .gitlab, "gitlab.gnome.org", "GNOME", "glib");
    defer urls.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "https://gitlab.gnome.org/api/v4/projects/GNOME%2Fglib/repository/commits/HEAD",
        urls.api_head_url,
    );
    try std.testing.expectEqualStrings("https://gitlab.gnome.org/GNOME/glib", urls.repo_url);
    try std.testing.expectEqualStrings("https://gitlab.gnome.org/GNOME/glib/-/raw", urls.raw_base);
}

test "buildBaseUrls gitlab: percent-encodes reserved bytes in the project path" {
    // Reserved bytes (the `/` separator, a space) must escape so the path
    // stays inside the v4 `:id` segment; unreserved `.` is left intact.
    const urls = try buildBaseUrls(std.testing.allocator, .gitlab, "gitlab.com", "a b", "c.d");
    defer urls.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "https://gitlab.com/api/v4/projects/a%20b%2Fc.d/repository/commits/HEAD",
        urls.api_head_url,
    );
}

fn buildGitlabAndFree(allocator: std.mem.Allocator) !void {
    const urls = try buildBaseUrls(allocator, .gitlab, "gitlab.com", "grp", "tap");
    urls.deinit(allocator);
}

test "buildBaseUrls gitlab: no leak on any allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildGitlabAndFree, .{});
}

test "encodeProjectPath: surfaces NoSpaceLeft for an unreserved byte and an escape" {
    // buildBaseUrls always sizes the buffer for the worst case, so these
    // branches are otherwise unreachable — cover them directly.
    var tiny: [0]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, encodeProjectPath(&tiny, "a", "b"));
    var one: [1]u8 = undefined; // fits 'a' but not the "/" escape (needs 3)
    try std.testing.expectError(error.NoSpaceLeft, encodeProjectPath(&one, "a", "b"));
}

// ── rawFileUrl (gitlab) ────────────────────────────────────────────
// The tail is identical to github; gitlab differs only in raw_base
// (the `/-/raw` infix `buildBaseUrls` already baked in).

const gitlab_raw_base = "https://gitlab.com/grp/tap/-/raw";

test "rawFileUrl gitlab: formula kind builds the /-/raw Formula tail" {
    var buf: [512]u8 = undefined;
    const url = try rawFileUrl(&buf, .gitlab, gitlab_raw_base, raw_sha_fixture, .formula, "glow");
    try std.testing.expectEqualStrings(
        gitlab_raw_base ++ "/" ++ raw_sha_fixture ++ "/Formula/glow.rb",
        url,
    );
}

test "rawFileUrl gitlab: cask kind builds the /-/raw Casks tail" {
    var buf: [512]u8 = undefined;
    const url = try rawFileUrl(&buf, .gitlab, gitlab_raw_base, raw_sha_fixture, .cask, "glow");
    try std.testing.expectEqualStrings(
        gitlab_raw_base ++ "/" ++ raw_sha_fixture ++ "/Casks/glow.rb",
        url,
    );
}

// ── fromHost (codeberg) ────────────────────────────────────────────
// codeberg.org is the only name-detectable Gitea host. Self-hosted
// Forgejo/Gitea instances aren't, so they reach `.codeberg` only via
// explicit `--forge codeberg` registration, never host sniffing.

test "fromHost classifies codeberg.org as .codeberg" {
    try std.testing.expectEqual(Forge.codeberg, fromHost("codeberg.org"));
}

test "fromHost leaves an unnamed Forgejo host as .github" {
    // A self-hosted Gitea like git.example.org isn't name-detectable; it
    // must be registered with `--forge codeberg`, not auto-classified.
    try std.testing.expectEqual(Forge.github, fromHost("git.example.org"));
}

test "fromHost leaves a codeberg look-alike host as .github" {
    // Exact host match, not a substring: `notcodeberg.org` must not match.
    try std.testing.expectEqual(Forge.github, fromHost("notcodeberg.org"));
}

// ── parseHeadSha (codeberg) ────────────────────────────────────────
// Gitea's `commits?limit=1` returns a JSON *array*; the head sha is the
// first element's top-level `"sha"` (GitHub-shaped, unlike gitlab's id).
// Same untrusted-input discipline: empty array / malformed entry → null
// so resolve reports MalformedJson rather than pinning a bad sha.

test "parseHeadSha codeberg: single-element commits array yields the sha" {
    const body =
        \\[{"sha":"0123456789abcdef0123456789abcdef01234567","commit":{"message":"x"}}]
    ;
    const got = parseHeadSha(.codeberg, body) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(valid_sha_fixture, got);
}

test "parseHeadSha codeberg: picks the element's top-level sha, not a nested tree sha" {
    const body =
        \\[{"sha":"0123456789abcdef0123456789abcdef01234567","commit":{"tree":{"sha":"ffffffffffffffffffffffffffffffffffffffff"}}}]
    ;
    const got = parseHeadSha(.codeberg, body) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(valid_sha_fixture, got);
}

test "parseHeadSha codeberg: empty array yields null" {
    try std.testing.expectEqual(@as(?[]const u8, null), parseHeadSha(.codeberg, "[]"));
}

test "parseHeadSha codeberg: malformed sha entry yields null" {
    const body =
        \\[{"sha":"not-a-valid-sha"}]
    ;
    try std.testing.expectEqual(@as(?[]const u8, null), parseHeadSha(.codeberg, body));
}

test "parseHeadSha codeberg: empty body yields null" {
    try std.testing.expectEqual(@as(?[]const u8, null), parseHeadSha(.codeberg, ""));
}

// ── buildBaseUrls (codeberg) ───────────────────────────────────────
// Gitea keys its v1 API by plain `{owner}/{repo}` (no URL-encoding,
// unlike gitlab), serves raw under `/raw` (no `/-/` infix), and browses
// at the instance host — all driven by the row's `host`, so self-hosted
// Forgejo resolves against its own domain.

test "buildBaseUrls codeberg: builds the v1 commits / raw / browse triple" {
    const urls = try buildBaseUrls(std.testing.allocator, .codeberg, "codeberg.org", "o", "r");
    defer urls.deinit(std.testing.allocator);
    try std.testing.expectEqual(Forge.codeberg, urls.forge);
    try std.testing.expectEqualStrings(
        "https://codeberg.org/api/v1/repos/o/r/commits?limit=1&stat=false",
        urls.api_head_url,
    );
    try std.testing.expectEqualStrings("https://codeberg.org/o/r", urls.repo_url);
    try std.testing.expectEqualStrings("https://codeberg.org/o/r/raw", urls.raw_base);
}

test "buildBaseUrls codeberg: a self-hosted Forgejo host drives every URL" {
    const urls = try buildBaseUrls(std.testing.allocator, .codeberg, "git.example.org", "team", "tap");
    defer urls.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "https://git.example.org/api/v1/repos/team/tap/commits?limit=1&stat=false",
        urls.api_head_url,
    );
    try std.testing.expectEqualStrings("https://git.example.org/team/tap", urls.repo_url);
    try std.testing.expectEqualStrings("https://git.example.org/team/tap/raw", urls.raw_base);
}

fn buildCodebergAndFree(allocator: std.mem.Allocator) !void {
    const urls = try buildBaseUrls(allocator, .codeberg, "codeberg.org", "grp", "tap");
    urls.deinit(allocator);
}

test "buildBaseUrls codeberg: no leak on any allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildCodebergAndFree, .{});
}

// ── browse URL (codeberg) ──────────────────────────────────────────
// Like gitlab, the instance host (not a literal) drives the browse URL.

test "repoBrowseUrl codeberg: the instance host drives the browse URL" {
    var buf: [256]u8 = undefined;
    const url = try repoBrowseUrl(&buf, .codeberg, "codeberg.org", "grp", "tap");
    try std.testing.expectEqualStrings("https://codeberg.org/grp/tap", url);
}

test "allocRepoBrowseUrl codeberg: allocates the instance-host browse URL" {
    const url = try allocRepoBrowseUrl(std.testing.allocator, .codeberg, "git.example.org", "team", "tap");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://git.example.org/team/tap", url);
}

// ── rawFileUrl (codeberg) ──────────────────────────────────────────
// Gitea's raw route has no `/-/` infix; raw_base already ends in `/raw`,
// so the shared tail appends `<sha>/Formula/<name>.rb`.

const codeberg_raw_base = "https://codeberg.org/grp/tap/raw";

test "rawFileUrl codeberg: formula kind builds the /raw Formula tail" {
    var buf: [512]u8 = undefined;
    const url = try rawFileUrl(&buf, .codeberg, codeberg_raw_base, raw_sha_fixture, .formula, "glow");
    try std.testing.expectEqualStrings(
        codeberg_raw_base ++ "/" ++ raw_sha_fixture ++ "/Formula/glow.rb",
        url,
    );
}

test "rawFileUrl codeberg: cask kind builds the /raw Casks tail" {
    var buf: [512]u8 = undefined;
    const url = try rawFileUrl(&buf, .codeberg, codeberg_raw_base, raw_sha_fixture, .cask, "glow");
    try std.testing.expectEqualStrings(
        codeberg_raw_base ++ "/" ++ raw_sha_fixture ++ "/Casks/glow.rb",
        url,
    );
}

// ── authHeader (codeberg) ──────────────────────────────────────────
// Gitea/Forgejo authenticate with `Authorization: token <PAT>` — the
// `token` scheme, not github's `Bearer`. MALT_CODEBERG_TOKEN keys it.

test "authHeader codeberg: null when MALT_CODEBERG_TOKEN unset" {
    var buf: [256]u8 = undefined;
    try std.testing.expect(authHeader(.codeberg, .empty, &buf) == null);
}

test "authHeader codeberg: token header when MALT_CODEBERG_TOKEN set" {
    const entries = [_:null]?[*:0]const u8{"MALT_CODEBERG_TOKEN=cb_testtoken"};
    var buf: [256]u8 = undefined;
    const h = authHeader(.codeberg, envWith(entries), &buf) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("Authorization", h.name);
    try std.testing.expectEqualStrings("token cb_testtoken", h.value);
}

test "authHeader codeberg: empty-string token behaves as unset" {
    const entries = [_:null]?[*:0]const u8{"MALT_CODEBERG_TOKEN="};
    var buf: [256]u8 = undefined;
    try std.testing.expect(authHeader(.codeberg, envWith(entries), &buf) == null);
}

test "rawAuthHeader codeberg: token attached — raw lives on the instance host" {
    // Gitea serves `/raw` from the authenticated instance host (like gitlab,
    // unlike github's public CDN), so a private tap's raw fetch carries it.
    const entries = [_:null]?[*:0]const u8{"MALT_CODEBERG_TOKEN=cb_testtoken"};
    var buf: [256]u8 = undefined;
    const h = rawAuthHeader(.codeberg, envWith(entries), &buf) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("Authorization", h.name);
    try std.testing.expectEqualStrings("token cb_testtoken", h.value);
}

test "rawAuthHeader codeberg: null when MALT_CODEBERG_TOKEN unset" {
    var buf: [256]u8 = undefined;
    try std.testing.expect(rawAuthHeader(.codeberg, .empty, &buf) == null);
}

// ── commitUrl ──────────────────────────────────────────────────────
// The `commits/<sha>` sibling of `api_head_url` that `mt tap --pin` hits
// to prove a SHA is reachable on the tap's own forge. Byte shapes are the
// contract: a non-github tap must pin against its own endpoint, never
// api.github.com. github stays byte-identical to the pre-seam literal.

const commit_sha_fixture = "0123456789abcdef0123456789abcdef01234567";

test "commitUrl github: byte-identical to the pre-seam api.github.com literal" {
    const url = try commitUrl(std.testing.allocator, .github, "github.com", "aeroxy", "ast-outline", commit_sha_fixture);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://api.github.com/repos/aeroxy/ast-outline/commits/" ++ commit_sha_fixture,
        url,
    );
}

test "commitUrl gitlab: encoded v4 project path on the instance host" {
    const url = try commitUrl(std.testing.allocator, .gitlab, "gitlab.com", "grp", "tap", commit_sha_fixture);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://gitlab.com/api/v4/projects/grp%2Ftap/repository/commits/" ++ commit_sha_fixture,
        url,
    );
}

test "commitUrl gitlab: a self-hosted instance host drives the URL" {
    const url = try commitUrl(std.testing.allocator, .gitlab, "gitlab.gnome.org", "GNOME", "glib", commit_sha_fixture);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://gitlab.gnome.org/api/v4/projects/GNOME%2Fglib/repository/commits/" ++ commit_sha_fixture,
        url,
    );
}

test "commitUrl codeberg: plain owner/repo on the v1 git/commits endpoint" {
    // Gitea/Forgejo serve a single commit at `git/commits/<sha>`; the bare
    // `commits/<sha>` (gitlab/github's verb) 404s here.
    const url = try commitUrl(std.testing.allocator, .codeberg, "codeberg.org", "grp", "tap", commit_sha_fixture);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://codeberg.org/api/v1/repos/grp/tap/git/commits/" ++ commit_sha_fixture,
        url,
    );
}

test "commitUrl codeberg: a self-hosted Forgejo host drives the URL" {
    const url = try commitUrl(std.testing.allocator, .codeberg, "git.example.org", "team", "tap", commit_sha_fixture);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://git.example.org/api/v1/repos/team/tap/git/commits/" ++ commit_sha_fixture,
        url,
    );
}

fn commitUrlAndFree(allocator: std.mem.Allocator) !void {
    // gitlab is the allocating-twice arm (encode buffer + allocPrint).
    const url = try commitUrl(allocator, .gitlab, "gitlab.com", "grp", "tap", commit_sha_fixture);
    allocator.free(url);
}

test "commitUrl gitlab: no leak on any allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, commitUrlAndFree, .{});
}

// Codeberg's `commits/<sha>` returns a single object (`{"sha":…}`), not
// the `?limit=1` array its HEAD path uses. The shared scan finds the
// first top-level `"sha"` either way, so the pin path reuses the parser.

test "parseHeadSha codeberg: single commit object (commits/<sha>) yields the sha" {
    const body =
        \\{"sha":"0123456789abcdef0123456789abcdef01234567","commit":{"message":"x"}}
    ;
    const got = parseHeadSha(.codeberg, body) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(valid_sha_fixture, got);
}

test "parseHeadSha codeberg: commit object picks the top-level sha, not a nested tree sha" {
    // The pin response nests a `commit.tree.sha`; the scan must lock onto
    // the object's own top-level sha, exactly as the HEAD array path does.
    const body =
        \\{"sha":"0123456789abcdef0123456789abcdef01234567","commit":{"tree":{"sha":"ffffffffffffffffffffffffffffffffffffffff"}}}
    ;
    const got = parseHeadSha(.codeberg, body) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(valid_sha_fixture, got);
}
