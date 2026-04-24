const std = @import("std");
const sqlite = @import("../db/sqlite.zig");
const client_mod = @import("../net/client.zig");
const fs_compat = @import("../fs/compat.zig");

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
pub fn githubAuthHeader(buf: []u8) ?std.http.Header {
    const raw = fs_compat.getenv("MALT_GITHUB_TOKEN") orelse return null;
    const token = std.mem.sliceTo(raw, 0);
    if (token.len == 0) return null;
    const value = std.fmt.bufPrint(buf, "Bearer {s}", .{token}) catch return null;
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
pub fn resolveHeadCommit(
    allocator: std.mem.Allocator,
    user: []const u8,
    repo_bare: []const u8,
) TapError![]const u8 {
    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(
        &url_buf,
        "https://api.github.com/repos/{s}/homebrew-{s}/commits/HEAD",
        .{ user, repo_bare },
    ) catch return TapError.ResolveFailed;

    var http = client_mod.HttpClient.init(allocator);
    defer http.deinit();

    // MALT_GITHUB_TOKEN takes precedence; otherwise `http.get` falls
    // back to the HOMEBREW_GITHUB_API_TOKEN auto-inject in net/client.
    var auth_buf: [256]u8 = undefined;
    var resp = if (githubAuthHeader(&auth_buf)) |header| blk: {
        const headers = [_]std.http.Header{header};
        break :blk http.getWithHeaders(url, &headers, null) catch return TapError.NetworkError;
    } else http.get(url) catch return TapError.NetworkError;
    defer resp.deinit();

    if (resp.status != 200) return classifyResolveStatus(resp.status);

    const sha = parseCommitShaFromJson(resp.body) orelse return TapError.MalformedJson;
    return allocator.dupe(u8, sha) catch TapError.OutOfMemory;
}
