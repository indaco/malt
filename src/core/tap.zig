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

/// Read the cached `head_etag` for a tap, or null when never seen or
/// stamped empty. Caller owns the returned slice. Sibling of
/// `getCommitSha`; the two columns travel together at every call site.
pub fn getHeadEtag(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    name: []const u8,
) !?[]const u8 {
    var stmt = try db.prepare("SELECT head_etag FROM taps WHERE name = ?1;");
    defer stmt.finalize();
    try stmt.bindText(1, name);
    if (!(try stmt.step())) return null;
    const raw = stmt.columnText(0) orelse return null;
    const trimmed = std.mem.sliceTo(raw, 0);
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

/// Atomic write of both `commit_sha` and `head_etag` for an existing
/// tap row. Order matters: the etag is paired with the sha that owns
/// it, so a partial failure cannot leave the DB pointing at the old
/// sha with a fresh etag (which would freeze the tap at the stale sha
/// until manual refresh). `etag` may be null when the server omitted
/// the header — the row's etag is then cleared so the next resolve
/// falls back to an unconditional GET.
pub fn updateHead(
    db: *sqlite.Database,
    name: []const u8,
    commit_sha: []const u8,
    etag: ?[]const u8,
) !void {
    try validateCommitSha(commit_sha);
    var stmt = try db.prepare(
        "UPDATE taps SET commit_sha = ?1, head_etag = ?2 WHERE name = ?3;",
    );
    defer stmt.finalize();
    try stmt.bindText(1, commit_sha);
    if (etag) |e| {
        try stmt.bindText(2, e);
    } else {
        try stmt.bindNull(2);
    }
    try stmt.bindText(3, name);
    _ = try stmt.step();
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

// ── resolveFromConditional: response → HeadResolution conversion ────
//
// `resolveHeadCommit` defers all classification to this pure helper so
// every shape GitHub can return (200+etag, 200 no-etag, 304, 404, 403,
// 5xx) is testable without spinning an HTTP transport.

fn makeConditional(
    status: u16,
    not_modified: bool,
    body: []const u8,
    etag: ?[]const u8,
) !client_mod.ConditionalResponse {
    return .{
        .status = status,
        .not_modified = not_modified,
        .body = try std.testing.allocator.dupe(u8, body),
        .etag = if (etag) |e| try std.testing.allocator.dupe(u8, e) else null,
        .allocator = std.testing.allocator,
    };
}

test "resolveFromConditional: 200 with body+etag yields sha and persists etag" {
    var resp = try makeConditional(
        200,
        false,
        "{\"sha\":\"0123456789abcdef0123456789abcdef01234567\",\"commit\":{}}",
        "W/\"deadbeef\"",
    );
    defer resp.deinit();

    var res = try resolveFromConditional(std.testing.allocator, resp);
    defer res.deinit();
    try std.testing.expect(!res.not_modified);
    try std.testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef01234567",
        res.sha.?,
    );
    try std.testing.expectEqualStrings("W/\"deadbeef\"", res.etag.?);
}

test "resolveFromConditional: 200 without etag still yields sha (etag stays null)" {
    var resp = try makeConditional(
        200,
        false,
        "{\"sha\":\"0123456789abcdef0123456789abcdef01234567\"}",
        null,
    );
    defer resp.deinit();

    var res = try resolveFromConditional(std.testing.allocator, resp);
    defer res.deinit();
    try std.testing.expect(!res.not_modified);
    try std.testing.expect(res.sha != null);
    try std.testing.expectEqual(@as(?[]const u8, null), res.etag);
}

test "resolveFromConditional: 304 yields not_modified=true, sha=null, etag preserved" {
    var resp = try makeConditional(304, true, "", "W/\"deadbeef\"");
    defer resp.deinit();

    var res = try resolveFromConditional(std.testing.allocator, resp);
    defer res.deinit();
    try std.testing.expect(res.not_modified);
    try std.testing.expectEqual(@as(?[]const u8, null), res.sha);
    try std.testing.expectEqualStrings("W/\"deadbeef\"", res.etag.?);
}

test "resolveFromConditional: 304 without ETag header — caller falls back to cached" {
    // GitHub always sends ETag on 304, but a stripping reverse proxy in
    // front of `api.github.com` could violate that — degrade gracefully.
    var resp = try makeConditional(304, true, "", null);
    defer resp.deinit();

    var res = try resolveFromConditional(std.testing.allocator, resp);
    defer res.deinit();
    try std.testing.expect(res.not_modified);
    try std.testing.expectEqual(@as(?[]const u8, null), res.etag);
}

test "resolveFromConditional: 404 classifies as NotFound" {
    var resp = try makeConditional(404, false, "{\"message\":\"Not Found\"}", null);
    defer resp.deinit();
    try std.testing.expectError(
        TapError.NotFound,
        resolveFromConditional(std.testing.allocator, resp),
    );
}

test "resolveFromConditional: 403 classifies as RateLimited" {
    var resp = try makeConditional(403, false, "{\"message\":\"API rate limit exceeded\"}", null);
    defer resp.deinit();
    try std.testing.expectError(
        TapError.RateLimited,
        resolveFromConditional(std.testing.allocator, resp),
    );
}

test "resolveFromConditional: 5xx classifies as ResolveFailed" {
    var resp = try makeConditional(502, false, "<html>bad gateway</html>", null);
    defer resp.deinit();
    try std.testing.expectError(
        TapError.ResolveFailed,
        resolveFromConditional(std.testing.allocator, resp),
    );
}

test "resolveFromConditional: 200 with malformed JSON classifies as MalformedJson" {
    var resp = try makeConditional(200, false, "{\"sha\":\"too-short\"}", null);
    defer resp.deinit();
    try std.testing.expectError(
        TapError.MalformedJson,
        resolveFromConditional(std.testing.allocator, resp),
    );
}

test "HeadResolution.deinit: tolerates partial sets (sha-only, etag-only, both null)" {
    var sha_only: HeadResolution = .{
        .sha = try std.testing.allocator.dupe(u8, "abc"),
        .etag = null,
        .not_modified = false,
        .allocator = std.testing.allocator,
    };
    sha_only.deinit();

    var etag_only: HeadResolution = .{
        .sha = null,
        .etag = try std.testing.allocator.dupe(u8, "W/\"x\""),
        .not_modified = true,
        .allocator = std.testing.allocator,
    };
    etag_only.deinit();

    var both_null: HeadResolution = .{
        .sha = null,
        .etag = null,
        .not_modified = true,
        .allocator = std.testing.allocator,
    };
    both_null.deinit();
}

// ── getHeadEtag / updateHead: per-tap etag persistence ─────────────

test "getHeadEtag returns null on a fresh row (no etag stamped yet)" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    const schema = @import("../db/schema.zig");
    try schema.initSchema(&db);
    try add(&db, "user/repo", "https://github.com/user/repo", null);
    const et = try getHeadEtag(std.testing.allocator, &db, "user/repo");
    try std.testing.expectEqual(@as(?[]const u8, null), et);
}

test "updateHead persists sha + etag atomically; getHeadEtag round-trips" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    const schema = @import("../db/schema.zig");
    try schema.initSchema(&db);
    try add(&db, "user/repo", "https://github.com/user/repo", null);

    const sha = "0123456789abcdef0123456789abcdef01234567";
    try updateHead(&db, "user/repo", sha, "W/\"feed\"");

    const stored_sha = (try getCommitSha(std.testing.allocator, &db, "user/repo")).?;
    defer std.testing.allocator.free(stored_sha);
    try std.testing.expectEqualStrings(sha, stored_sha);

    const stored_et = (try getHeadEtag(std.testing.allocator, &db, "user/repo")).?;
    defer std.testing.allocator.free(stored_et);
    try std.testing.expectEqualStrings("W/\"feed\"", stored_et);
}

test "updateHead with null etag clears the column (server omitted ETag)" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    const schema = @import("../db/schema.zig");
    try schema.initSchema(&db);
    try add(&db, "user/repo", "https://github.com/user/repo", null);

    const sha = "0123456789abcdef0123456789abcdef01234567";
    try updateHead(&db, "user/repo", sha, "W/\"feed\"");
    try updateHead(&db, "user/repo", sha, null);

    const et = try getHeadEtag(std.testing.allocator, &db, "user/repo");
    try std.testing.expectEqual(@as(?[]const u8, null), et);
}

test "getHeadEtag returns null for a tap name that was never added" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    const schema = @import("../db/schema.zig");
    try schema.initSchema(&db);
    const et = try getHeadEtag(std.testing.allocator, &db, "ghost/tap");
    try std.testing.expectEqual(@as(?[]const u8, null), et);
}

test "updateHead is a silent no-op on a missing row (mirrors updateCommit)" {
    // SQLite UPDATE against a missing row affects zero rows without
    // raising — same semantics as `updateCommit`. Documented here so
    // callers don't expect a `NotFound`-style error.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    const schema = @import("../db/schema.zig");
    try schema.initSchema(&db);

    try updateHead(&db, "ghost/tap", "0123456789abcdef0123456789abcdef01234567", "W/\"x\"");
    const et = try getHeadEtag(std.testing.allocator, &db, "ghost/tap");
    try std.testing.expectEqual(@as(?[]const u8, null), et);
}

test "updateHead rejects an invalid SHA before touching the row" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    const schema = @import("../db/schema.zig");
    try schema.initSchema(&db);
    try add(&db, "user/repo", "https://github.com/user/repo", null);
    try updateHead(&db, "user/repo", "0123456789abcdef0123456789abcdef01234567", "W/\"feed\"");

    // Validator runs first — DB stays at the prior value.
    try std.testing.expectError(TapError.InvalidSha, updateHead(&db, "user/repo", "not-a-sha", "W/\"new\""));

    const et = (try getHeadEtag(std.testing.allocator, &db, "user/repo")).?;
    defer std.testing.allocator.free(et);
    try std.testing.expectEqualStrings("W/\"feed\"", et);
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

/// HEAD-resolve outcome. `sha` is set on a fresh body (200) and null
/// on 304 — the caller's cached sha is still authoritative in that
/// case. `etag`, when set, is GitHub's current ETag for `/commits/HEAD`;
/// callers persist it via `tap_mod.updateHead` so the next round can
/// short-circuit again. A null `etag` means the server omitted the
/// header (rare but legal); the caller's previously cached etag, if any,
/// stays valid.
pub const HeadResolution = struct {
    sha: ?[]const u8,
    etag: ?[]const u8,
    not_modified: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *HeadResolution) void {
        if (self.sha) |s| self.allocator.free(s);
        if (self.etag) |e| self.allocator.free(e);
    }
};

/// Convert a `ConditionalResponse` from GitHub's `/commits/HEAD` into a
/// `HeadResolution`. Pure: takes ownership of `resp.etag` only when the
/// status is convertible; otherwise reports the classified `TapError`
/// (`resp.deinit` still frees both body and etag in the error path).
pub fn resolveFromConditional(
    allocator: std.mem.Allocator,
    resp: client_mod.ConditionalResponse,
) TapError!HeadResolution {
    if (resp.not_modified) {
        // 304: keep cached SHA, only the ETag may have rotated.
        const etag_owned: ?[]const u8 = if (resp.etag) |e|
            allocator.dupe(u8, e) catch return TapError.OutOfMemory
        else
            null;
        return .{
            .sha = null,
            .etag = etag_owned,
            .not_modified = true,
            .allocator = allocator,
        };
    }

    if (resp.status != 200) return classifyResolveStatus(resp.status);

    const sha = parseCommitShaFromJson(resp.body) orelse return TapError.MalformedJson;
    const sha_owned = allocator.dupe(u8, sha) catch return TapError.OutOfMemory;
    errdefer allocator.free(sha_owned);

    const etag_owned: ?[]const u8 = if (resp.etag) |e|
        allocator.dupe(u8, e) catch return TapError.OutOfMemory
    else
        null;

    return .{
        .sha = sha_owned,
        .etag = etag_owned,
        .not_modified = false,
        .allocator = allocator,
    };
}

/// Ask GitHub for the current HEAD commit of a tap's repo, sending
/// `If-None-Match` when `cached_etag` is set so a stable tap costs
/// zero rate-limit tokens. Returns a `HeadResolution` so callers can
/// distinguish "fresh sha" from "304: cached sha is still good".
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
    cached_etag: ?[]const u8,
) TapError!HeadResolution {
    var http = client_mod.HttpClient.init(io, environ, allocator);
    defer http.deinit();

    // MALT_GITHUB_TOKEN takes precedence; falling through to `extra=&.{}`
    // lets net/client's HOMEBREW_GITHUB_API_TOKEN auto-inject still apply
    // — both authenticate against the same 5000/hr quota that 304s don't
    // touch.
    var auth_buf: [256]u8 = undefined;
    var resp = if (githubAuthHeader(environ, &auth_buf)) |header| blk: {
        const headers = [_]std.http.Header{header};
        break :blk http.getConditional(api_head_url, cached_etag, &headers) catch return TapError.NetworkError;
    } else http.getConditional(api_head_url, cached_etag, &.{}) catch return TapError.NetworkError;
    defer resp.deinit();

    return resolveFromConditional(allocator, resp);
}
