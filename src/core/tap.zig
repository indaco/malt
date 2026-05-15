const std = @import("std");
const sqlite = @import("../db/sqlite.zig");
const client_mod = @import("../net/client.zig");

pub const TapInfo = struct {
    name: []const u8,
    url: []const u8,
    /// 40-char lowercase hex commit SHA the tap was pinned to. Null
    /// for rows carried over from pre-pin schema or for additions that
    /// couldn't resolve a remote commit at tap time.
    commit_sha: ?[]const u8 = null,
};

pub const TapError = error{
    /// Catch-all for causes we could not classify (5xx, unknown status, etc.).
    ResolveFailed,
    InvalidSha,
    /// GitHub answered 404 — the tap repo is not at `homebrew-<repo>`.
    NotFound,
    /// GitHub answered 403 — public cap is 60/hr per IP.
    RateLimited,
    /// `/commits/HEAD` returned 200 but the body did not contain a valid SHA.
    MalformedJson,
    /// Network layer failure before a status could be read.
    NetworkError,
    OutOfMemory,
};

/// Map a non-200 GitHub response status onto the narrowest `TapError` tag
/// we can name. Callers use the tag to pick the user-facing message —
/// see `src/cli/install/local.zig` and `src/cli/tap.zig`.
pub fn classifyResolveStatus(status: u16) TapError {
    return switch (status) {
        403 => TapError.RateLimited,
        404 => TapError.NotFound,
        else => TapError.ResolveFailed,
    };
}

/// Build a `Authorization: Bearer <token>` header into `buf` from
/// `MALT_GITHUB_TOKEN`, or return null when the env var is unset or
/// empty. Exclusive to `resolveHeadCommit` — no other codepath picks up
/// this env var, so users who set it only affect tap-resolution calls.
pub fn githubAuthHeader(environ: std.process.Environ, buf: []u8) ?std.http.Header {
    const raw = std.process.Environ.getPosix(environ, "MALT_GITHUB_TOKEN") orelse return null;
    if (raw.len == 0) return null;
    const value = std.fmt.bufPrint(buf, "Bearer {s}", .{raw}) catch return null;
    return .{ .name = "Authorization", .value = value };
}

/// Short remediation hint for each `TapError` variant. Keeping the
/// strings here (not at the call site) means `cli/install/local.zig`
/// and `cli/tap.zig` cannot drift out of sync, and unit tests can pin
/// every tag without touching the network or the UI layer.
pub fn describeResolveError(err: TapError) []const u8 {
    return switch (err) {
        error.RateLimited => "GitHub API rate limit reached. Set MALT_GITHUB_TOKEN to an authorized GitHub token to lift the 60/hr anonymous cap.",
        error.NotFound => "GitHub returned 404 for the tap repo. Third-party taps must live at github.com/<user>/homebrew-<repo>; taps that drop the 'homebrew-' prefix are not yet supported.",
        error.NetworkError => "Network failure while reaching api.github.com — check connectivity and retry.",
        error.MalformedJson => "Unexpected response shape from GitHub — rerun with --debug and attach the log when filing an issue.",
        error.InvalidSha => "GitHub returned a commit SHA that failed validation (not 40-char lowercase hex).",
        error.ResolveFailed => "GitHub returned an unexpected status while resolving HEAD — retry, or set MALT_GITHUB_TOKEN if this persists.",
        error.OutOfMemory => "Out of memory while resolving HEAD commit.",
    };
}

pub fn add(
    db: *sqlite.Database,
    name: []const u8,
    url: []const u8,
    commit_sha: ?[]const u8,
) sqlite.SqliteError!void {
    // URL is sticky on conflict (URL doesn't change once registered);
    // commit_sha is sticky unless the caller passes a new one. Refresh
    // goes through `updateCommit` which forces a replacement.
    var stmt = try db.prepare(
        \\INSERT INTO taps (name, url, commit_sha) VALUES (?1, ?2, ?3)
        \\ON CONFLICT(name) DO UPDATE SET
        \\    commit_sha = COALESCE(excluded.commit_sha, taps.commit_sha);
    );
    defer stmt.finalize();
    try stmt.bindText(1, name);
    try stmt.bindText(2, url);
    if (commit_sha) |s| {
        try stmt.bindText(3, s);
    } else {
        try stmt.bindNull(3);
    }
    _ = try stmt.step();
}

pub fn remove(db: *sqlite.Database, name: []const u8) sqlite.SqliteError!void {
    var stmt = try db.prepare("DELETE FROM taps WHERE name = ?1;");
    defer stmt.finalize();
    try stmt.bindText(1, name);
    _ = try stmt.step();
}

/// Replace the stored commit SHA for an existing tap. Called by
/// `malt tap --refresh`; fails if the tap isn't already registered.
pub fn updateCommit(db: *sqlite.Database, name: []const u8, commit_sha: []const u8) !void {
    try validateCommitSha(commit_sha);
    var stmt = try db.prepare(
        "UPDATE taps SET commit_sha = ?1 WHERE name = ?2;",
    );
    defer stmt.finalize();
    try stmt.bindText(1, commit_sha);
    try stmt.bindText(2, name);
    _ = try stmt.step();
}

pub fn getCommitSha(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    name: []const u8,
) !?[]const u8 {
    var stmt = try db.prepare("SELECT commit_sha FROM taps WHERE name = ?1;");
    defer stmt.finalize();
    try stmt.bindText(1, name);
    if (!(try stmt.step())) return null;
    const raw = stmt.columnText(0) orelse return null;
    const trimmed = std.mem.sliceTo(raw, 0);
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

pub fn list(allocator: std.mem.Allocator, db: *sqlite.Database) ![]TapInfo {
    var taps: std.ArrayList(TapInfo) = .empty;
    // ArrayList.deinit doesn't reach row sub-allocations; walk them too.
    errdefer {
        for (taps.items) |t| freeTapInfoFields(allocator, t);
        taps.deinit(allocator);
    }

    var stmt = try db.prepare("SELECT name, url, commit_sha FROM taps;");
    defer stmt.finalize();

    while (try stmt.step()) {
        const n = stmt.columnText(0) orelse continue;
        const u = stmt.columnText(1) orelse continue;

        // Build the row in locals so a later dupe failure can't strand an earlier one.
        const name_owned = try allocator.dupe(u8, std.mem.sliceTo(n, 0));
        errdefer allocator.free(name_owned);
        const url_owned = try allocator.dupe(u8, std.mem.sliceTo(u, 0));
        errdefer allocator.free(url_owned);
        const sha_owned: ?[]const u8 = if (stmt.columnText(2)) |s| blk: {
            const trimmed = std.mem.sliceTo(s, 0);
            if (trimmed.len == 0) break :blk null;
            break :blk try allocator.dupe(u8, trimmed);
        } else null;
        errdefer if (sha_owned) |sha| allocator.free(sha);

        try taps.append(allocator, .{
            .name = name_owned,
            .url = url_owned,
            .commit_sha = sha_owned,
        });
    }

    return taps.toOwnedSlice(allocator);
}

fn freeTapInfoFields(allocator: std.mem.Allocator, info: TapInfo) void {
    allocator.free(info.name);
    allocator.free(info.url);
    if (info.commit_sha) |sha| allocator.free(sha);
}

/// Resolve a tap formula — builds the full tap formula name.
pub fn resolveFormula(allocator: std.mem.Allocator, user: []const u8, repo: []const u8, formula: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ user, repo, formula });
}

/// URLs every tap fetch site needs, derived from one slug parse so the
/// `homebrew-<repo>` synthesis lives in exactly one place. For raw
/// fetches callers append `/<sha>/Formula/<name>.rb` (or `Casks/`) to
/// `raw_base` — keeping the sha out of the helper means the API URL
/// (queried before any sha exists) shares the same synthesis path.
pub const TapBaseUrls = struct {
    /// `https://api.github.com/repos/<user>/homebrew-<repo>/commits/HEAD`
    api_head_url: []const u8,
    /// `https://github.com/<user>/homebrew-<repo>` — the URL that actually
    /// resolves; written to `taps.url`.
    repo_url: []const u8,
    /// `https://raw.githubusercontent.com/<user>/homebrew-<repo>` — caller
    /// appends `/<sha>/Formula/<name>.rb` or `/<sha>/Casks/<name>.rb`.
    raw_base: []const u8,

    pub fn deinit(self: TapBaseUrls, allocator: std.mem.Allocator) void {
        allocator.free(self.api_head_url);
        allocator.free(self.repo_url);
        allocator.free(self.raw_base);
    }
};

/// Build every URL needed to talk to a tap repo from its `user/repo` slug.
/// Single seam for `homebrew-<repo>` prefix synthesis — a future change
/// to the URL shape (prefixless taps, non-GitHub hosts) lands in one
/// file. `slug` must be a validated `user/repo` form (see
/// `cli/tap.zig:validateTapName`); a missing `/` trips `unreachable`.
pub fn resolveTapBaseUrls(
    allocator: std.mem.Allocator,
    slug: []const u8,
) std.mem.Allocator.Error!TapBaseUrls {
    const slash = std.mem.indexOfScalar(u8, slug, '/') orelse unreachable;
    const user = slug[0..slash];
    const repo = slug[slash + 1 ..];

    const api_head_url = try std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repos/{s}/homebrew-{s}/commits/HEAD",
        .{ user, repo },
    );
    errdefer allocator.free(api_head_url);

    const repo_url = try std.fmt.allocPrint(
        allocator,
        "https://github.com/{s}/homebrew-{s}",
        .{ user, repo },
    );
    errdefer allocator.free(repo_url);

    const raw_base = try std.fmt.allocPrint(
        allocator,
        "https://raw.githubusercontent.com/{s}/homebrew-{s}",
        .{ user, repo },
    );
    errdefer allocator.free(raw_base);

    return .{
        .api_head_url = api_head_url,
        .repo_url = repo_url,
        .raw_base = raw_base,
    };
}

test "resolveTapBaseUrls synthesises homebrew- prefix once per field" {
    const urls = try resolveTapBaseUrls(std.testing.allocator, "aeroxy/tap");
    defer urls.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "https://api.github.com/repos/aeroxy/homebrew-tap/commits/HEAD",
        urls.api_head_url,
    );
    try std.testing.expectEqualStrings(
        "https://github.com/aeroxy/homebrew-tap",
        urls.repo_url,
    );
    try std.testing.expectEqualStrings(
        "https://raw.githubusercontent.com/aeroxy/homebrew-tap",
        urls.raw_base,
    );
}

/// Build the `commits/<sha>` URL siblings of `api_head_url`. Routed
/// through the same `homebrew-<repo>` synthesis so `mt tap --pin` and the
/// HEAD path can't drift apart — a 200 here means the SHA is reachable
/// against the exact repo subsequent installs will fetch from.
pub fn resolveCommitUrl(
    allocator: std.mem.Allocator,
    slug: []const u8,
    sha: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const slash = std.mem.indexOfScalar(u8, slug, '/') orelse unreachable;
    const user = slug[0..slash];
    const repo = slug[slash + 1 ..];
    return std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repos/{s}/homebrew-{s}/commits/{s}",
        .{ user, repo, sha },
    );
}

test "resolveCommitUrl builds the homebrew- prefixed commits/<sha> URL" {
    const sha = "0123456789abcdef0123456789abcdef01234567";
    const url = try resolveCommitUrl(std.testing.allocator, "user/repo", sha);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://api.github.com/repos/user/homebrew-repo/commits/" ++ sha,
        url,
    );
}

test "resolveCommitUrl preserves hyphens and digits in repo names" {
    const sha = "0123456789abcdef0123456789abcdef01234567";
    const url = try resolveCommitUrl(std.testing.allocator, "user-1/some-tap.v2", sha);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://api.github.com/repos/user-1/homebrew-some-tap.v2/commits/" ++ sha,
        url,
    );
}

test "resolveTapBaseUrls preserves repo names containing hyphens and digits" {
    const urls = try resolveTapBaseUrls(std.testing.allocator, "user-1/some-tap.v2");
    defer urls.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "https://api.github.com/repos/user-1/homebrew-some-tap.v2/commits/HEAD",
        urls.api_head_url,
    );
    try std.testing.expectEqualStrings(
        "https://github.com/user-1/homebrew-some-tap.v2",
        urls.repo_url,
    );
    try std.testing.expectEqualStrings(
        "https://raw.githubusercontent.com/user-1/homebrew-some-tap.v2",
        urls.raw_base,
    );
}

/// A 40-char lowercase hex commit SHA — matches git's printable form.
pub fn validateCommitSha(sha: []const u8) TapError!void {
    if (sha.len != 40) return TapError.InvalidSha;
    for (sha) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return TapError.InvalidSha,
    };
}

/// Pull the first top-level `"sha"` field out of a GitHub commits/HEAD
/// response. Exposed for unit tests; production code reaches it via
/// `resolveHeadCommit`.
///
/// Takes only the first match because GitHub's response always has
/// the commit SHA before the nested tree/parent objects. The result
/// is validated as a 40-char lowercase hex string — malformed or
/// unexpected shapes return null rather than misleading SHAs.
pub fn parseCommitShaFromJson(body: []const u8) ?[]const u8 {
    const marker = "\"sha\"";
    const idx = std.mem.indexOf(u8, body, marker) orelse return null;
    var cur = idx + marker.len;
    while (cur < body.len and (body[cur] == ' ' or body[cur] == ':' or body[cur] == '\t')) : (cur += 1) {}
    if (cur >= body.len or body[cur] != '"') return null;
    cur += 1;
    const end = std.mem.indexOfScalarPos(u8, body, cur, '"') orelse return null;
    const sha = body[cur..end];
    validateCommitSha(sha) catch return null;
    return sha;
}

/// Ask GitHub for the current HEAD commit of a tap's repo. Returns
/// the 40-char lowercase hex SHA or a classified `TapError` so callers
/// can surface the actual cause (rate limit, 404, network, JSON). Caller
/// owns the returned slice.
///
/// `api_head_url` must come from `resolveTapBaseUrls` — that single seam
/// owns the `homebrew-<repo>` synthesis. A bare-args overload that
/// re-synthesised the URL inline is exactly the refresh-regression mode
/// we structurally prevent by routing every fetch site through the helper.
pub fn resolveHeadCommit(
    io: std.Io,
    environ: std.process.Environ,
    allocator: std.mem.Allocator,
    api_head_url: []const u8,
) TapError![]const u8 {
    var http = client_mod.HttpClient.init(io, environ, allocator);
    defer http.deinit();

    // MALT_GITHUB_TOKEN takes precedence; otherwise `http.get` falls
    // back to the HOMEBREW_GITHUB_API_TOKEN auto-inject in net/client.
    var auth_buf: [256]u8 = undefined;
    var resp = if (githubAuthHeader(environ, &auth_buf)) |header| blk: {
        const headers = [_]std.http.Header{header};
        break :blk http.getWithHeaders(api_head_url, &headers, null) catch return TapError.NetworkError;
    } else http.get(api_head_url) catch return TapError.NetworkError;
    defer resp.deinit();

    if (resp.status != 200) return classifyResolveStatus(resp.status);

    const sha = parseCommitShaFromJson(resp.body) orelse return TapError.MalformedJson;
    return allocator.dupe(u8, sha) catch TapError.OutOfMemory;
}
