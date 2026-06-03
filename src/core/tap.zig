const std = @import("std");

const sqlite = @import("../db/sqlite.zig");
const client_mod = @import("../net/client.zig");
const forge = @import("forge.zig");

pub const TapInfo = struct {
    name: []const u8,
    url: []const u8,
    /// 40-char lowercase hex commit SHA the tap was pinned to. Null
    /// for rows carried over from pre-pin schema or for additions that
    /// couldn't resolve a remote commit at tap time.
    commit_sha: ?[]const u8 = null,
    /// Forge host the tap resolves against. Defaults to github.com so
    /// pre-host rows and synthetic test fixtures stay valid.
    host: []const u8 = "github.com",
};

pub const TapError = error{
    /// Catch-all for causes we could not classify (5xx, unknown status, etc.).
    ResolveFailed,
    InvalidSha,
    /// GitHub answered 404 — the resolved `(owner, repo)` does not name
    /// a real repo. Triggers the `--repo` remediation hint in `describeResolveError`.
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

/// Short remediation hint for each `TapError` variant. Keeping the
/// strings here (not at the call site) means `cli/install/local.zig`
/// and `cli/tap.zig` cannot drift out of sync, and unit tests can pin
/// every tag without touching the network or the UI layer.
pub fn describeResolveError(err: TapError) []const u8 {
    return switch (err) {
        error.RateLimited => "GitHub API rate limit reached. Set MALT_GITHUB_TOKEN to an authorized GitHub token to lift the 60/hr anonymous cap.",
        error.NotFound => "GitHub returned 404 for the tap repo. If the repo lives at github.com/<user>/<exact-name> instead of github.com/<user>/homebrew-<repo>, rerun with --repo <user>/<exact-name>.",
        error.NetworkError => "Network failure while reaching api.github.com — check connectivity and retry.",
        error.MalformedJson => "Unexpected response shape from GitHub — rerun with --debug and attach the log when filing an issue.",
        error.InvalidSha => "GitHub returned a commit SHA that failed validation (not 40-char lowercase hex).",
        error.ResolveFailed => "GitHub returned an unexpected status while resolving HEAD — retry, or set MALT_GITHUB_TOKEN if this persists.",
        error.OutOfMemory => "Out of memory while resolving HEAD commit.",
    };
}

/// Materialise `taps.url` from `(host, owner, repo)` into a caller buffer
/// through the forge seam, so the browse-URL shape lives in one place.
/// `buf` must hold ≥160 bytes (19 prefix + 2·64 component cap + 1 slash).
fn writeRepoUrl(buf: []u8, forge_kind: forge.Forge, host: []const u8, owner: []const u8, repo: []const u8) sqlite.SqliteError![]const u8 {
    return forge.repoBrowseUrl(buf, forge_kind, host, owner, repo) catch
        sqlite.SqliteError.ExecFailed;
}

/// GitHub-default `add` — the overwhelming majority of taps. Delegates to
/// `addWithHost` so the 5-arg call sites stay untouched; host is sticky
/// on conflict, so a re-add never clobbers a non-github row's forge.
pub fn add(
    db: *sqlite.Database,
    name: []const u8,
    owner: []const u8,
    repo: []const u8,
    commit_sha: ?[]const u8,
) sqlite.SqliteError!void {
    return addWithHost(db, name, owner, repo, "github.com", commit_sha);
}

/// Register a tap row carrying its forge `host`, letting host
/// classification pick the provider. The `mt tap --host` / `--url`
/// path uses this when the host alone resolves the forge.
pub fn addWithHost(
    db: *sqlite.Database,
    name: []const u8,
    owner: []const u8,
    repo: []const u8,
    host: []const u8,
    commit_sha: ?[]const u8,
) sqlite.SqliteError!void {
    return addWithForge(db, name, owner, repo, host, null, commit_sha);
}

/// Register a tap row, optionally pinning its forge explicitly. A
/// non-null `forge_hint` is the only way to resolve a custom-domain
/// instance whose host can't reveal its provider; null defers to host
/// classification (the common case). The hint is persisted so resolution
/// is stable across runs.
pub fn addWithForge(
    db: *sqlite.Database,
    name: []const u8,
    owner: []const u8,
    repo: []const u8,
    host: []const u8,
    forge_hint: ?forge.Forge,
    commit_sha: ?[]const u8,
) sqlite.SqliteError!void {
    // Owner/repo/host/forge are sticky on conflict — the rebind verb is the
    // only sanctioned mutator. commit_sha is sticky unless a fresh one is
    // passed (refresh goes through `updateCommit`/`updateHead`).
    const forge_kind = forge_hint orelse forge.fromHost(host);
    var url_buf: [256]u8 = undefined;
    const derived_url = try writeRepoUrl(&url_buf, forge_kind, host, owner, repo);

    var stmt = try db.prepare(
        \\INSERT INTO taps (name, url, commit_sha, github_owner, github_repo, host, forge) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        \\ON CONFLICT(name) DO UPDATE SET
        \\    commit_sha = COALESCE(excluded.commit_sha, taps.commit_sha);
    );
    defer stmt.finalize();
    try stmt.bindText(1, name);
    try stmt.bindText(2, derived_url);
    if (commit_sha) |s| {
        try stmt.bindText(3, s);
    } else {
        try stmt.bindNull(3);
    }
    try stmt.bindText(4, owner);
    try stmt.bindText(5, repo);
    try stmt.bindText(6, host);
    // NULL forge means "classify by host" — only an explicit hint persists.
    if (forge_hint) |f| {
        try stmt.bindText(7, @tagName(f));
    } else {
        try stmt.bindNull(7);
    }
    _ = try stmt.step();
}

/// Rebind an existing tap row to a new `(owner, repo)` pair. Clears the
/// commit SHA and ETag because the moved repo has its own HEAD — keeping
/// the old pin would freeze the row at a SHA that doesn't exist on the
/// new repo. The CLI `--force` path is the only sanctioned caller; the
/// default refuse-without-`--force` policy lives at the CLI layer.
pub fn rebind(
    db: *sqlite.Database,
    name: []const u8,
    owner: []const u8,
    repo: []const u8,
) sqlite.SqliteError!void {
    var url_buf: [256]u8 = undefined;
    // Rebind is a GitHub-only verb today (`mt tap --repo`); the row's host
    // is left untouched by the UPDATE below, so deriving the browse URL
    // against github.com matches the row that stays.
    const derived_url = try writeRepoUrl(&url_buf, .github, "github.com", owner, repo);

    var stmt = try db.prepare(
        \\UPDATE taps SET
        \\    github_owner = ?1,
        \\    github_repo  = ?2,
        \\    url          = ?3,
        \\    commit_sha   = NULL,
        \\    head_etag    = NULL
        \\WHERE name = ?4;
    );
    defer stmt.finalize();
    try stmt.bindText(1, owner);
    try stmt.bindText(2, repo);
    try stmt.bindText(3, derived_url);
    try stmt.bindText(4, name);
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

    // Project `url` from (github_owner, github_repo, host) so the listing
    // can't disagree with the actual fetch target.
    var stmt = try db.prepare("SELECT name, github_owner, github_repo, commit_sha, host, forge FROM taps;");
    defer stmt.finalize();

    while (try stmt.step()) {
        const n = stmt.columnText(0) orelse continue;
        const o = stmt.columnText(1) orelse continue;
        const r = stmt.columnText(2) orelse continue;
        // host is NOT NULL DEFAULT 'github.com'; the orelse only guards
        // the impossible NULL so the row still projects.
        const host = std.mem.sliceTo(stmt.columnText(4) orelse "github.com", 0);
        // forge is nullable — NULL means classify by host.
        const forge_stored: ?[]const u8 = if (stmt.columnText(5)) |f| std.mem.sliceTo(f, 0) else null;

        const name_owned = try allocator.dupe(u8, std.mem.sliceTo(n, 0));
        errdefer allocator.free(name_owned);
        const host_owned = try allocator.dupe(u8, host);
        errdefer allocator.free(host_owned);
        const url_owned = try forge.allocRepoBrowseUrl(
            allocator,
            effectiveForge(forge_stored, host),
            host,
            std.mem.sliceTo(o, 0),
            std.mem.sliceTo(r, 0),
        );
        errdefer allocator.free(url_owned);
        const sha_owned: ?[]const u8 = if (stmt.columnText(3)) |s| blk: {
            const trimmed = std.mem.sliceTo(s, 0);
            if (trimmed.len == 0) break :blk null;
            break :blk try allocator.dupe(u8, trimmed);
        } else null;
        errdefer if (sha_owned) |sha| allocator.free(sha);

        try taps.append(allocator, .{
            .name = name_owned,
            .url = url_owned,
            .commit_sha = sha_owned,
            .host = host_owned,
        });
    }

    return taps.toOwnedSlice(allocator);
}

fn freeTapInfoFields(allocator: std.mem.Allocator, info: TapInfo) void {
    allocator.free(info.name);
    allocator.free(info.url);
    if (info.commit_sha) |sha| allocator.free(sha);
    allocator.free(info.host);
}

/// Resolve a tap formula — builds the full tap formula name.
pub fn resolveFormula(allocator: std.mem.Allocator, user: []const u8, repo: []const u8, formula: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ user, repo, formula });
}

/// The URL triple every tap fetch site needs. Re-exported from the
/// forge seam, which owns the host-shaped layout; `tap` keeps the
/// row/SQLite logic that decides the `(owner, repo)` fed into it.
pub const TapBaseUrls = forge.TapBaseUrls;

/// Owner+repo+host read off a tap row. `host` feeds `forge.fromHost`
/// so resolution targets the forge the row was registered on. Caller
/// owns all three slices.
pub const TapPair = struct {
    owner: []const u8,
    repo: []const u8,
    host: []const u8,
    /// The forge a row resolves against. Defaults to `.github` for the
    /// registration-input pairs the CLI builds (they feed the forge in
    /// separately); the row-read paths set the effective forge.
    forge: forge.Forge = .github,

    pub fn deinit(self: TapPair, allocator: std.mem.Allocator) void {
        allocator.free(self.owner);
        allocator.free(self.repo);
        allocator.free(self.host);
    }
};

/// Resolve the forge a tap row should use. An explicit `--forge` hint
/// (the `forge` column) wins — it's the only way to classify a custom
/// domain whose host can't reveal its provider (a corporate GitLab at
/// e.g. code.acme.com). A NULL/empty/unknown value defers to host
/// classification, so every pre-hint row resolves byte-for-byte as before.
pub fn effectiveForge(stored: ?[]const u8, host: []const u8) forge.Forge {
    if (stored) |s| {
        if (std.meta.stringToEnum(forge.Forge, std.mem.sliceTo(s, 0))) |f| return f;
    }
    return forge.fromHost(host);
}

/// Read `(github_owner, github_repo)` for `slug`, or null when the row
/// doesn't exist yet (cold path during `mt tap` registration).
pub fn getOwnerRepo(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    slug: []const u8,
) !?TapPair {
    var stmt = try db.prepare(
        "SELECT github_owner, github_repo, host, forge FROM taps WHERE name = ?1;",
    );
    defer stmt.finalize();
    try stmt.bindText(1, slug);
    if (!(try stmt.step())) return null;
    const owner_raw = stmt.columnText(0) orelse return null;
    const repo_raw = stmt.columnText(1) orelse return null;
    // host is NOT NULL DEFAULT 'github.com'; the orelse only guards the
    // impossible NULL so a forge is never lost on read.
    const host_trim = std.mem.sliceTo(stmt.columnText(2) orelse "github.com", 0);
    // forge is nullable — NULL means classify by host.
    const forge_stored: ?[]const u8 = if (stmt.columnText(3)) |f| std.mem.sliceTo(f, 0) else null;
    const owner_trim = std.mem.sliceTo(owner_raw, 0);
    const repo_trim = std.mem.sliceTo(repo_raw, 0);
    if (owner_trim.len == 0 or repo_trim.len == 0) return null;

    const owner_owned = try allocator.dupe(u8, owner_trim);
    errdefer allocator.free(owner_owned);
    const repo_owned = try allocator.dupe(u8, repo_trim);
    errdefer allocator.free(repo_owned);
    const host_owned = try allocator.dupe(u8, host_trim);
    return .{
        .owner = owner_owned,
        .repo = repo_owned,
        .host = host_owned,
        .forge = effectiveForge(forge_stored, host_trim),
    };
}

/// Single point where the slug-derived default `(user, "homebrew-" || repo)`
/// is synthesised — the cold path during initial `mt tap` registration,
/// before the row is written. Future fetch sites that need a pair MUST
/// route through here so the prefix synthesis can never drift across
/// helpers. `slug` must be a validated `user/repo` form.
pub fn effectiveOwnerRepo(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    slug: []const u8,
    host: []const u8,
) !TapPair {
    if (try getOwnerRepo(allocator, db, slug)) |pair| return pair;
    // Cold path predates any stored row. The `homebrew-<repo>` synthesis is
    // a GitHub-community convention — it does not hold on other forges, so
    // a non-github registration must name its repo explicitly.
    if (!std.mem.eql(u8, host, "github.com")) return error.ExplicitRepoRequired;
    const slash = std.mem.indexOfScalar(u8, slug, '/') orelse unreachable;
    const user = slug[0..slash];
    const repo_part = slug[slash + 1 ..];
    const owner_owned = try allocator.dupe(u8, user);
    errdefer allocator.free(owner_owned);
    const repo_owned = try std.fmt.allocPrint(allocator, "homebrew-{s}", .{repo_part});
    errdefer allocator.free(repo_owned);
    const host_owned = try allocator.dupe(u8, "github.com");
    return .{ .owner = owner_owned, .repo = repo_owned, .host = host_owned };
}

/// Build every URL needed to talk to a tap repo. Reads the row's
/// `(github_owner, github_repo)` when present and falls back to the
/// slug-derived default through `effectiveOwnerRepo` — the single seam
/// where the `homebrew-<repo>` synthesis lives. `slug` must be a
/// validated `user/repo` form.
pub fn resolveTapBaseUrls(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    slug: []const u8,
) !TapBaseUrls {
    // The cold-path hint is github.com: this helper is only reached on the
    // resolve/refresh path, which non-github taps skip until their forge
    // arm lands. When a row exists its persisted host wins anyway.
    const pair = try effectiveOwnerRepo(allocator, db, slug, "github.com");
    defer pair.deinit(allocator);
    // The row's effective forge (an explicit `--forge` hint, else host
    // classification) selects the provider; github.com rows are unchanged.
    return forge.buildBaseUrls(allocator, pair.forge, pair.host, pair.owner, pair.repo);
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

test "resolveFromConditional: routes the body through the row's forge parser" {
    // The forge selects the HEAD parser; a github row reads GitHub's `"sha"`.
    // A future non-github arm reuses this seam — same wiring, different parse.
    var resp = try makeConditional(
        200,
        false,
        "{\"sha\":\"0123456789abcdef0123456789abcdef01234567\"}",
        null,
    );
    defer resp.deinit();
    var res = try resolveFromConditional(std.testing.allocator, .github, resp);
    defer res.deinit();
    try std.testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef01234567",
        res.sha.?,
    );
}

test "resolveFromConditional: 200 with body+etag yields sha and persists etag" {
    var resp = try makeConditional(
        200,
        false,
        "{\"sha\":\"0123456789abcdef0123456789abcdef01234567\",\"commit\":{}}",
        "W/\"deadbeef\"",
    );
    defer resp.deinit();

    var res = try resolveFromConditional(std.testing.allocator, .github, resp);
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

    var res = try resolveFromConditional(std.testing.allocator, .github, resp);
    defer res.deinit();
    try std.testing.expect(!res.not_modified);
    try std.testing.expect(res.sha != null);
    try std.testing.expectEqual(@as(?[]const u8, null), res.etag);
}

test "resolveFromConditional: 304 yields not_modified=true, sha=null, etag preserved" {
    var resp = try makeConditional(304, true, "", "W/\"deadbeef\"");
    defer resp.deinit();

    var res = try resolveFromConditional(std.testing.allocator, .github, resp);
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

    var res = try resolveFromConditional(std.testing.allocator, .github, resp);
    defer res.deinit();
    try std.testing.expect(res.not_modified);
    try std.testing.expectEqual(@as(?[]const u8, null), res.etag);
}

test "resolveFromConditional: 404 classifies as NotFound" {
    var resp = try makeConditional(404, false, "{\"message\":\"Not Found\"}", null);
    defer resp.deinit();
    try std.testing.expectError(
        TapError.NotFound,
        resolveFromConditional(std.testing.allocator, .github, resp),
    );
}

test "resolveFromConditional: 403 classifies as RateLimited" {
    var resp = try makeConditional(403, false, "{\"message\":\"API rate limit exceeded\"}", null);
    defer resp.deinit();
    try std.testing.expectError(
        TapError.RateLimited,
        resolveFromConditional(std.testing.allocator, .github, resp),
    );
}

test "resolveFromConditional: 5xx classifies as ResolveFailed" {
    var resp = try makeConditional(502, false, "<html>bad gateway</html>", null);
    defer resp.deinit();
    try std.testing.expectError(
        TapError.ResolveFailed,
        resolveFromConditional(std.testing.allocator, .github, resp),
    );
}

test "resolveFromConditional: 200 with malformed JSON classifies as MalformedJson" {
    var resp = try makeConditional(200, false, "{\"sha\":\"too-short\"}", null);
    defer resp.deinit();
    try std.testing.expectError(
        TapError.MalformedJson,
        resolveFromConditional(std.testing.allocator, .github, resp),
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
    try add(&db, "user/repo", "user", "homebrew-repo", null);
    const et = try getHeadEtag(std.testing.allocator, &db, "user/repo");
    try std.testing.expectEqual(@as(?[]const u8, null), et);
}

test "updateHead persists sha + etag atomically; getHeadEtag round-trips" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    const schema = @import("../db/schema.zig");
    try schema.initSchema(&db);
    try add(&db, "user/repo", "user", "homebrew-repo", null);

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
    try add(&db, "user/repo", "user", "homebrew-repo", null);

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
    try add(&db, "user/repo", "user", "homebrew-repo", null);
    try updateHead(&db, "user/repo", "0123456789abcdef0123456789abcdef01234567", "W/\"feed\"");

    // Validator runs first — DB stays at the prior value.
    try std.testing.expectError(TapError.InvalidSha, updateHead(&db, "user/repo", "not-a-sha", "W/\"new\""));

    const et = (try getHeadEtag(std.testing.allocator, &db, "user/repo")).?;
    defer std.testing.allocator.free(et);
    try std.testing.expectEqualStrings("W/\"feed\"", et);
}

test "resolveTapBaseUrls falls back to slug-derived defaults when no row exists" {
    // Cold path during initial `mt tap` registration — the row hasn't
    // been written yet, so the helper synthesises the `homebrew-<repo>`
    // default from the slug so the HEAD resolve can find the row's
    // first commit before we persist it.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    const schema = @import("../db/schema.zig");
    try schema.initSchema(&db);

    const urls = try resolveTapBaseUrls(std.testing.allocator, &db, "aeroxy/tap");
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

test "resolveTapBaseUrls reads (owner, repo) from the row when present" {
    // The structural-enforcement claim: once the row exists, the helper
    // reads the stored pair and *never* re-synthesises the `homebrew-`
    // prefix. A custom-repo row produces URLs that hit the user's
    // exact GitHub identifier.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    const schema = @import("../db/schema.zig");
    try schema.initSchema(&db);
    try db.exec(
        \\INSERT INTO taps (name, url, commit_sha, github_owner, github_repo)
        \\VALUES ('aeroxy/ast-outline',
        \\        'https://github.com/aeroxy/ast-outline',
        \\        NULL, 'aeroxy', 'ast-outline');
    );

    const urls = try resolveTapBaseUrls(std.testing.allocator, &db, "aeroxy/ast-outline");
    defer urls.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "https://api.github.com/repos/aeroxy/ast-outline/commits/HEAD",
        urls.api_head_url,
    );
    try std.testing.expectEqualStrings(
        "https://github.com/aeroxy/ast-outline",
        urls.repo_url,
    );
    try std.testing.expectEqualStrings(
        "https://raw.githubusercontent.com/aeroxy/ast-outline",
        urls.raw_base,
    );
}

test "resolveTapBaseUrls reads the stored prefixed pair byte-for-byte" {
    // A default-prefixed row read through the helper produces the same
    // URLs the cold path would have synthesised — the helper must not
    // re-derive the prefix when the row already carries it.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    const schema = @import("../db/schema.zig");
    try schema.initSchema(&db);
    try db.exec(
        \\INSERT INTO taps (name, url, commit_sha, github_owner, github_repo)
        \\VALUES ('user-1/some.v2',
        \\        'https://github.com/user-1/homebrew-some.v2',
        \\        NULL, 'user-1', 'homebrew-some.v2');
    );

    const urls = try resolveTapBaseUrls(std.testing.allocator, &db, "user-1/some.v2");
    defer urls.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "https://api.github.com/repos/user-1/homebrew-some.v2/commits/HEAD",
        urls.api_head_url,
    );
}

test "addWithHost persists the row's forge host" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    const schema = @import("../db/schema.zig");
    try schema.initSchema(&db);
    try addWithHost(&db, "grp/tap", "grp", "tap", "gitlab.com", null);

    const pair = (try getOwnerRepo(std.testing.allocator, &db, "grp/tap")).?;
    defer pair.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("gitlab.com", pair.host);
    try std.testing.expectEqualStrings("grp", pair.owner);
    try std.testing.expectEqualStrings("tap", pair.repo);
}

test "add defaults the host to github.com (delegates to addWithHost)" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    const schema = @import("../db/schema.zig");
    try schema.initSchema(&db);
    try add(&db, "user/repo", "user", "homebrew-repo", null);

    const pair = (try getOwnerRepo(std.testing.allocator, &db, "user/repo")).?;
    defer pair.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("github.com", pair.host);
}

test "list surfaces each row's forge host" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    const schema = @import("../db/schema.zig");
    try schema.initSchema(&db);
    try add(&db, "user/repo", "user", "homebrew-repo", null);
    try addWithHost(&db, "grp/tap", "grp", "tap", "gitlab.com", null);

    const taps = try list(std.testing.allocator, &db);
    defer {
        for (taps) |t| freeTapInfoFields(std.testing.allocator, t);
        std.testing.allocator.free(taps);
    }
    try std.testing.expectEqual(@as(usize, 2), taps.len);
    for (taps) |t| {
        if (std.mem.eql(u8, t.name, "grp/tap")) {
            try std.testing.expectEqualStrings("gitlab.com", t.host);
        } else {
            try std.testing.expectEqualStrings("github.com", t.host);
        }
    }
}

test "getOwnerRepo reads the row's host, defaulting to github.com" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    const schema = @import("../db/schema.zig");
    try schema.initSchema(&db);
    try add(&db, "user/repo", "user", "homebrew-repo", null);

    const pair = (try getOwnerRepo(std.testing.allocator, &db, "user/repo")).?;
    defer pair.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("github.com", pair.host);
}

test "getOwnerRepo reads a non-default host written to the row" {
    // Until the host-registration UX lands, a non-github host can only
    // reach the row via a direct write — exercise the read path now so
    // the persisted host is provably surfaced ahead of the forge arms.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    const schema = @import("../db/schema.zig");
    try schema.initSchema(&db);
    try db.exec(
        \\INSERT INTO taps (name, url, commit_sha, github_owner, github_repo, host)
        \\VALUES ('grp/tap', 'https://gitlab.com/grp/tap', NULL, 'grp', 'tap', 'gitlab.com');
    );

    const pair = (try getOwnerRepo(std.testing.allocator, &db, "grp/tap")).?;
    defer pair.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("gitlab.com", pair.host);
    try std.testing.expectEqualStrings("grp", pair.owner);
    try std.testing.expectEqualStrings("tap", pair.repo);
}

test "effectiveOwnerRepo cold path synthesizes homebrew- for github.com" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    const schema = @import("../db/schema.zig");
    try schema.initSchema(&db);

    const pair = try effectiveOwnerRepo(std.testing.allocator, &db, "aeroxy/tap", "github.com");
    defer pair.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("github.com", pair.host);
    try std.testing.expectEqualStrings("aeroxy", pair.owner);
    try std.testing.expectEqualStrings("homebrew-tap", pair.repo);
}

test "effectiveOwnerRepo refuses to synthesize a repo for non-github hosts" {
    // The `homebrew-<repo>` convention is GitHub-community-specific; on
    // other forges there is no safe default repo to guess, so the cold
    // path must demand an explicit repo rather than mis-resolve.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    const schema = @import("../db/schema.zig");
    try schema.initSchema(&db);

    try std.testing.expectError(
        error.ExplicitRepoRequired,
        effectiveOwnerRepo(std.testing.allocator, &db, "grp/tap", "gitlab.com"),
    );
}

test "effectiveOwnerRepo reads the stored row regardless of the host hint" {
    // Once a row exists its persisted host wins; the hint only governs
    // the cold-path synthesis decision.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    const schema = @import("../db/schema.zig");
    try schema.initSchema(&db);
    try addWithHost(&db, "grp/tap", "grp", "tap", "gitlab.com", null);

    const pair = try effectiveOwnerRepo(std.testing.allocator, &db, "grp/tap", "github.com");
    defer pair.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("gitlab.com", pair.host);
    try std.testing.expectEqualStrings("grp", pair.owner);
    try std.testing.expectEqualStrings("tap", pair.repo);
}

test "resolveTapBaseUrls routes the row's host through the forge seam" {
    // The host is read and handed to `forge.fromHost`: a gitlab.com row
    // resolves to GitLab's v4 commits URL (URL-encoded project path) and
    // the instance-host browse URL. Owner/repo come through verbatim
    // (no `homebrew-` synthesis).
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    const schema = @import("../db/schema.zig");
    try schema.initSchema(&db);
    try db.exec(
        \\INSERT INTO taps (name, url, commit_sha, github_owner, github_repo, host)
        \\VALUES ('grp/tap', 'https://gitlab.com/grp/tap', NULL, 'grp', 'tap', 'gitlab.com');
    );

    const urls = try resolveTapBaseUrls(std.testing.allocator, &db, "grp/tap");
    defer urls.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "https://gitlab.com/api/v4/projects/grp%2Ftap/repository/commits/HEAD",
        urls.api_head_url,
    );
    try std.testing.expectEqualStrings("https://gitlab.com/grp/tap", urls.repo_url);
}

test "effectiveForge: an explicit forge hint overrides host classification" {
    // A corporate GitLab on a custom domain can't be sniffed from its
    // host, so the stored hint is the only signal and must win.
    try std.testing.expectEqual(forge.Forge.gitlab, effectiveForge("gitlab", "code.acme.com"));
}

test "effectiveForge: a null hint falls back to host classification" {
    try std.testing.expectEqual(forge.Forge.gitlab, effectiveForge(null, "gitlab.com"));
    try std.testing.expectEqual(forge.Forge.github, effectiveForge(null, "github.com"));
}

test "effectiveForge: an unrecognised stored value falls back to the host" {
    try std.testing.expectEqual(forge.Forge.github, effectiveForge("bogus", "github.com"));
}

test "addWithForge resolves a custom-domain instance through the hinted forge" {
    // The whole point of `--forge`: code.acme.com isn't named gitlab.*,
    // so only the persisted hint makes it resolve as GitLab.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    const schema = @import("../db/schema.zig");
    try schema.initSchema(&db);

    try addWithForge(&db, "acme/tap", "acme", "tap", "code.acme.com", .gitlab, null);

    const urls = try resolveTapBaseUrls(std.testing.allocator, &db, "acme/tap");
    defer urls.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "https://code.acme.com/api/v4/projects/acme%2Ftap/repository/commits/HEAD",
        urls.api_head_url,
    );
    try std.testing.expectEqualStrings("https://code.acme.com/acme/tap", urls.repo_url);
    try std.testing.expectEqualStrings("https://code.acme.com/acme/tap/-/raw", urls.raw_base);
}

test "addWithForge stamps the browse URL through the hinted forge" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    const schema = @import("../db/schema.zig");
    try schema.initSchema(&db);

    try addWithForge(&db, "acme/tap", "acme", "tap", "code.acme.com", .gitlab, null);

    const taps = try list(std.testing.allocator, &db);
    defer {
        for (taps) |t| freeTapInfoFields(std.testing.allocator, t);
        std.testing.allocator.free(taps);
    }
    try std.testing.expectEqual(@as(usize, 1), taps.len);
    try std.testing.expectEqualStrings("https://code.acme.com/acme/tap", taps[0].url);
}

test "getOwnerRepo carries the row's effective forge" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    const schema = @import("../db/schema.zig");
    try schema.initSchema(&db);
    try addWithForge(&db, "acme/tap", "acme", "tap", "code.acme.com", .gitlab, null);

    const pair = (try getOwnerRepo(std.testing.allocator, &db, "acme/tap")).?;
    defer pair.deinit(std.testing.allocator);
    try std.testing.expectEqual(forge.Forge.gitlab, pair.forge);
}

/// Build the `commits/<sha>` URL sibling of `api_head_url`. Routes
/// through the same `effectiveOwnerRepo` seam the HEAD path uses — a
/// 200 here proves the SHA is reachable against the exact repo
/// subsequent installs will fetch from.
pub fn resolveCommitUrl(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    slug: []const u8,
    sha: []const u8,
) ![]const u8 {
    // `commits/<sha>` is a GitHub-only verb today (`mt tap --pin`).
    const pair = try effectiveOwnerRepo(allocator, db, slug, "github.com");
    defer pair.deinit(allocator);
    return std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repos/{s}/{s}/commits/{s}",
        .{ pair.owner, pair.repo, sha },
    );
}

test "resolveCommitUrl falls back to slug-derived default when no row exists" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    const schema = @import("../db/schema.zig");
    try schema.initSchema(&db);
    const sha = "0123456789abcdef0123456789abcdef01234567";

    const url = try resolveCommitUrl(std.testing.allocator, &db, "user/repo", sha);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://api.github.com/repos/user/homebrew-repo/commits/" ++ sha,
        url,
    );
}

test "resolveCommitUrl reads (owner, repo) from the row when present" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    const schema = @import("../db/schema.zig");
    try schema.initSchema(&db);
    try db.exec(
        \\INSERT INTO taps (name, url, commit_sha, github_owner, github_repo)
        \\VALUES ('aeroxy/ast-outline',
        \\        'https://github.com/aeroxy/ast-outline',
        \\        NULL, 'aeroxy', 'ast-outline');
    );
    const sha = "0123456789abcdef0123456789abcdef01234567";

    const url = try resolveCommitUrl(std.testing.allocator, &db, "aeroxy/ast-outline", sha);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://api.github.com/repos/aeroxy/ast-outline/commits/" ++ sha,
        url,
    );
}

test "resolveTapBaseUrls preserves repo names containing hyphens and digits via the row" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    const schema = @import("../db/schema.zig");
    try schema.initSchema(&db);
    try db.exec(
        \\INSERT INTO taps (name, url, commit_sha, github_owner, github_repo)
        \\VALUES ('user-1/some-tap.v2',
        \\        'https://github.com/user-1/homebrew-some-tap.v2',
        \\        NULL, 'user-1', 'homebrew-some-tap.v2');
    );

    const urls = try resolveTapBaseUrls(std.testing.allocator, &db, "user-1/some-tap.v2");
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

/// Convert a forge's `/commits/HEAD` `ConditionalResponse` into a
/// `HeadResolution`; `forge_kind` selects the body parser. Pure: takes
/// ownership of `resp.etag` only when the
/// status is convertible; otherwise reports the classified `TapError`
/// (`resp.deinit` still frees both body and etag in the error path).
pub fn resolveFromConditional(
    allocator: std.mem.Allocator,
    forge_kind: forge.Forge,
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

    const sha = forge.parseHeadSha(forge_kind, resp.body) orelse return TapError.MalformedJson;
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

/// Ask the forge for the current HEAD commit of a tap's repo, sending
/// `If-None-Match` when `cached_etag` is set so a stable tap costs
/// zero rate-limit tokens. `forge_kind` selects the auth header and HEAD
/// parser. Returns a `HeadResolution` so callers can distinguish
/// "fresh sha" from "304: cached sha is still good".
///
/// `api_head_url` must come from `resolveTapBaseUrls` — that single seam
/// owns the `homebrew-<repo>` synthesis. A bare-args overload that
/// re-synthesised the URL inline is exactly the refresh-regression mode
/// we structurally prevent by routing every fetch site through the helper.
pub fn resolveHeadCommit(
    io: std.Io,
    environ: std.process.Environ,
    allocator: std.mem.Allocator,
    forge_kind: forge.Forge,
    api_head_url: []const u8,
    cached_etag: ?[]const u8,
) TapError!HeadResolution {
    var http = client_mod.HttpClient.init(io, environ, allocator);
    defer http.deinit();

    // The forge's own token (e.g. MALT_GITHUB_TOKEN) is attached per
    // request; falling through to `extra=&.{}` lets net/client's
    // HOMEBREW_GITHUB_API_TOKEN auto-inject still apply for github hosts.
    // 304s don't spend the rate-limit quota either way.
    var auth_buf: [256]u8 = undefined;
    var resp = if (forge.authHeader(forge_kind, environ, &auth_buf)) |header| blk: {
        const headers = [_]std.http.Header{header};
        break :blk http.getConditional(api_head_url, cached_etag, &headers) catch return TapError.NetworkError;
    } else http.getConditional(api_head_url, cached_etag, &.{}) catch return TapError.NetworkError;
    defer resp.deinit();

    return resolveFromConditional(allocator, forge_kind, resp);
}

/// Fetch a tap's raw `.rb`, attaching the forge's raw-auth header when it
/// needs one. Auth rides this explicit per-request path so a private
/// forge whose raw lives on the instance host (e.g. GitLab `PRIVATE-TOKEN`)
/// is reached without leaning on `net/client`'s host-substring auto-inject.
/// GitHub's raw CDN needs none, so its fetch is byte-identical to a plain
/// GET. Caller owns the returned `Response`.
pub fn getRawFile(
    http: *client_mod.HttpClient,
    environ: std.process.Environ,
    forge_kind: forge.Forge,
    rb_url: []const u8,
) !client_mod.Response {
    var auth_buf: [256]u8 = undefined;
    if (forge.rawAuthHeader(forge_kind, environ, &auth_buf)) |header| {
        const headers = [_]std.http.Header{header};
        return http.getWithHeaders(rb_url, &headers, null);
    }
    return http.get(rb_url);
}
