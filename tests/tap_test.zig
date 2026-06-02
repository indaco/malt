//! malt — core/tap module tests
//! Covers add/remove/list round-trip, resolveFormula helper, and the
//! commit-pin lifecycle (tap_mod.add with SHA, updateCommit, validator).

const std = @import("std");
const testing = std.testing;

const malt = @import("malt");
const sqlite = malt.sqlite;
const schema = malt.schema;
const tap = malt.tap;

const valid_sha = "0123456789abcdef0123456789abcdef01234567";
const other_sha = "abcdef0123456789abcdef0123456789abcdef01";

fn openDb() !sqlite.Database {
    return sqlite.Database.open(":memory:");
}

fn freeTaps(taps: []tap.TapInfo) void {
    for (taps) |t| {
        testing.allocator.free(t.name);
        testing.allocator.free(t.url);
        if (t.commit_sha) |sha| testing.allocator.free(sha);
    }
    testing.allocator.free(taps);
}

test "list returns empty slice on a fresh database" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    const taps = try tap.list(testing.allocator, &db);
    defer freeTaps(taps);
    try testing.expectEqual(@as(usize, 0), taps.len);
}

test "add then list round-trips tap name, derived URL, and commit SHA" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "user/repo", "user", "homebrew-repo", valid_sha);

    const taps = try tap.list(testing.allocator, &db);
    defer freeTaps(taps);
    try testing.expectEqual(@as(usize, 1), taps.len);
    try testing.expectEqualStrings("user/repo", taps[0].name);
    // url is projected from (github_owner, github_repo) — not the lie
    // it was in v8 where bare-slug got written verbatim.
    try testing.expectEqualStrings("https://github.com/user/homebrew-repo", taps[0].url);
    try testing.expectEqualStrings(valid_sha, taps[0].commit_sha.?);
}

test "add with null SHA persists as unpinned" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "user/repo", "user", "homebrew-repo", null);

    const taps = try tap.list(testing.allocator, &db);
    defer freeTaps(taps);
    try testing.expectEqual(@as(usize, 1), taps.len);
    try testing.expectEqual(@as(?[]const u8, null), taps[0].commit_sha);
}

test "add preserves (owner, repo) on conflict — rebind requires the explicit verb" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "user/repo", "user", "homebrew-repo", null);
    // Second add with a different repo must NOT mutate the existing
    // pair — the only sanctioned rebind path is `tap.rebind`.
    try tap.add(&db, "user/repo", "user", "homebrew-repo-other", null);

    const taps = try tap.list(testing.allocator, &db);
    defer freeTaps(taps);
    try testing.expectEqual(@as(usize, 1), taps.len);
    try testing.expectEqualStrings("https://github.com/user/homebrew-repo", taps[0].url);
}

test "add preserves existing commit pin when new add passes null" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "user/repo", "user", "homebrew-repo", valid_sha);
    // Second add without a SHA must NOT wipe the pin.
    try tap.add(&db, "user/repo", "user", "homebrew-repo", null);

    const taps = try tap.list(testing.allocator, &db);
    defer freeTaps(taps);
    try testing.expectEqualStrings(valid_sha, taps[0].commit_sha.?);
}

test "add replaces existing pin when new add passes a different non-null SHA" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "user/repo", "user", "homebrew-repo", valid_sha);
    try tap.add(&db, "user/repo", "user", "homebrew-repo", other_sha);

    const taps = try tap.list(testing.allocator, &db);
    defer freeTaps(taps);
    try testing.expectEqualStrings(other_sha, taps[0].commit_sha.?);
}

test "add persists the (github_owner, github_repo) pair passed at INSERT" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "aeroxy/ast-outline", "aeroxy", "ast-outline", null);

    var stmt = try db.prepare(
        "SELECT github_owner, github_repo FROM taps WHERE name = ?1;",
    );
    defer stmt.finalize();
    try stmt.bindText(1, "aeroxy/ast-outline");
    try testing.expect(try stmt.step());
    try testing.expectEqualStrings(
        "aeroxy",
        std.mem.sliceTo(stmt.columnText(0) orelse "", 0),
    );
    try testing.expectEqualStrings(
        "ast-outline",
        std.mem.sliceTo(stmt.columnText(1) orelse "", 0),
    );
}

test "add stamps the default host github.com, read back via getOwnerRepo" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "user/repo", "user", "homebrew-repo", null);

    const pair = (try tap.getOwnerRepo(testing.allocator, &db, "user/repo")).?;
    defer pair.deinit(testing.allocator);
    try testing.expectEqualStrings("github.com", pair.host);
}

test "a non-github host round-trips through getOwnerRepo and list" {
    // Persistence half of multi-forge support: the host is stored and
    // read back. Resolution still produces github-shaped URLs because the
    // non-github forge arms aren't here yet — assert the host is *read*,
    // not that the URL changed.
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try db.exec(
        \\INSERT INTO taps (name, url, commit_sha, github_owner, github_repo, host)
        \\VALUES ('grp/tap', 'https://gitlab.com/grp/tap', NULL, 'grp', 'tap', 'gitlab.com');
    );

    const pair = (try tap.getOwnerRepo(testing.allocator, &db, "grp/tap")).?;
    defer pair.deinit(testing.allocator);
    try testing.expectEqualStrings("gitlab.com", pair.host);

    const taps = try tap.list(testing.allocator, &db);
    defer freeTaps(taps);
    try testing.expectEqual(@as(usize, 1), taps.len);
    try testing.expectEqualStrings("grp/tap", taps[0].name);
    try testing.expectEqualStrings("https://github.com/grp/tap", taps[0].url);
}

test "rebind moves (owner, repo) and clears commit_sha and head_etag" {
    // Rebinding to a new repo invalidates the old pin — the new repo has
    // its own HEAD, and keeping the stale SHA would freeze the row at a
    // commit that doesn't exist on the new target. Force-rebind is the
    // only sanctioned mutator.
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "user/repo", "user", "homebrew-repo", valid_sha);
    try tap.updateHead(&db, "user/repo", valid_sha, "W/\"stale\"");

    try tap.rebind(&db, "user/repo", "user", "other-name");

    var stmt = try db.prepare(
        "SELECT github_owner, github_repo, commit_sha, head_etag FROM taps WHERE name = ?1;",
    );
    defer stmt.finalize();
    try stmt.bindText(1, "user/repo");
    try testing.expect(try stmt.step());
    try testing.expectEqualStrings(
        "user",
        std.mem.sliceTo(stmt.columnText(0) orelse "", 0),
    );
    try testing.expectEqualStrings(
        "other-name",
        std.mem.sliceTo(stmt.columnText(1) orelse "", 0),
    );
    try testing.expect(stmt.columnText(2) == null);
    try testing.expect(stmt.columnText(3) == null);
}

test "rebind also rewrites the derived url column" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "user/repo", "user", "homebrew-repo", null);
    try tap.rebind(&db, "user/repo", "user", "exact-name");

    const taps = try tap.list(testing.allocator, &db);
    defer freeTaps(taps);
    try testing.expectEqualStrings(
        "https://github.com/user/exact-name",
        taps[0].url,
    );
}

test "effectiveOwnerRepo reads from the row when present" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);
    try tap.add(&db, "aeroxy/ast-outline", "aeroxy", "ast-outline", null);

    const pair = try tap.effectiveOwnerRepo(testing.allocator, &db, "aeroxy/ast-outline");
    defer pair.deinit(testing.allocator);
    try testing.expectEqualStrings("aeroxy", pair.owner);
    try testing.expectEqualStrings("ast-outline", pair.repo);
}

test "effectiveOwnerRepo falls back to slug-derived (user, \"homebrew-\" || repo)" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    const pair = try tap.effectiveOwnerRepo(testing.allocator, &db, "aeroxy/tap");
    defer pair.deinit(testing.allocator);
    try testing.expectEqualStrings("aeroxy", pair.owner);
    try testing.expectEqualStrings("homebrew-tap", pair.repo);
}

test "add is idempotent on owner/repo — second add with same pair preserves state" {
    // Mirrors today's `tap.add` ON CONFLICT semantics for the new
    // columns: the (owner, repo) sticks, only commit_sha rotates.
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "user/repo", "user", "homebrew-repo", valid_sha);
    try tap.add(&db, "user/repo", "user", "homebrew-repo", null);

    var stmt = try db.prepare(
        "SELECT github_owner, github_repo, commit_sha FROM taps WHERE name = ?1;",
    );
    defer stmt.finalize();
    try stmt.bindText(1, "user/repo");
    try testing.expect(try stmt.step());
    try testing.expectEqualStrings("user", std.mem.sliceTo(stmt.columnText(0) orelse "", 0));
    try testing.expectEqualStrings("homebrew-repo", std.mem.sliceTo(stmt.columnText(1) orelse "", 0));
    try testing.expectEqualStrings(valid_sha, std.mem.sliceTo(stmt.columnText(2) orelse "", 0));
}

test "rebind is a no-op when the row is missing (mirrors updateCommit)" {
    // SQLite UPDATE on a missing row affects zero rows without raising.
    // Documented so the CLI layer doesn't try to handle a NotFound case
    // that can't happen.
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.rebind(&db, "ghost/tap", "ghost", "other");

    const taps = try tap.list(testing.allocator, &db);
    defer freeTaps(taps);
    try testing.expectEqual(@as(usize, 0), taps.len);
}

test "effectiveOwnerRepo treats half-empty rows as missing (forgiving against corruption)" {
    // If only one column carries an empty default — e.g. a manual DB
    // hack or an interrupted backfill — the helper falls back to the
    // slug-derived default rather than handing back a half-pair that
    // would build an invalid URL.
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);
    try db.exec(
        \\INSERT INTO taps (name, url, github_owner, github_repo)
        \\VALUES ('user/repo', 'https://x', '', 'something');
    );

    const pair = try tap.effectiveOwnerRepo(testing.allocator, &db, "user/repo");
    defer pair.deinit(testing.allocator);
    try testing.expectEqualStrings("user", pair.owner);
    try testing.expectEqualStrings("homebrew-repo", pair.repo);
}

test "list mixes custom-repo and default-prefixed rows without cross-contamination" {
    // Each row projects its own URL from its own (owner, repo) — no
    // shared template state across rows.
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "aeroxy/ast-outline", "aeroxy", "ast-outline", null);
    try tap.add(&db, "user/repo", "user", "homebrew-repo", null);

    const taps = try tap.list(testing.allocator, &db);
    defer freeTaps(taps);
    try testing.expectEqual(@as(usize, 2), taps.len);
    // ORDER BY isn't applied in `list` — sort manually before asserting.
    for (taps) |t| {
        if (std.mem.eql(u8, t.name, "aeroxy/ast-outline")) {
            try testing.expectEqualStrings("https://github.com/aeroxy/ast-outline", t.url);
        } else {
            try testing.expectEqualStrings("https://github.com/user/homebrew-repo", t.url);
        }
    }
}

test "list URL projection follows rebind end-to-end" {
    // Touches the read-time projection: after a force-rebind, the
    // listing must show the new repo, not the cached lie.
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "aeroxy/ast-outline", "aeroxy", "homebrew-ast-outline", null);
    try tap.rebind(&db, "aeroxy/ast-outline", "aeroxy", "ast-outline");

    const taps = try tap.list(testing.allocator, &db);
    defer freeTaps(taps);
    try testing.expectEqualStrings(
        "https://github.com/aeroxy/ast-outline",
        taps[0].url,
    );
    try testing.expectEqual(@as(?[]const u8, null), taps[0].commit_sha);
}

test "describeResolveError(NotFound) names the --repo remediation" {
    const msg = tap.describeResolveError(error.NotFound);
    try testing.expect(std.mem.indexOf(u8, msg, "--repo") != null);
}

test "updateCommit replaces an existing pin" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "user/repo", "user", "homebrew-repo", valid_sha);
    try tap.updateCommit(&db, "user/repo", other_sha);

    const taps = try tap.list(testing.allocator, &db);
    defer freeTaps(taps);
    try testing.expectEqualStrings(other_sha, taps[0].commit_sha.?);
}

test "updateCommit rejects malformed SHA" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "user/repo", "user", "homebrew-repo", valid_sha);
    try testing.expectError(error.InvalidSha, tap.updateCommit(&db, "user/repo", "notasha"));
    try testing.expectError(error.InvalidSha, tap.updateCommit(&db, "user/repo", "XXXX567890abcdef0123456789abcdef01234567"));
}

test "updateCommit on an unknown tap is a no-op (no rows affected, no error)" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.updateCommit(&db, "nobody/never-added", valid_sha);

    const taps = try tap.list(testing.allocator, &db);
    defer freeTaps(taps);
    try testing.expectEqual(@as(usize, 0), taps.len);
}

test "getCommitSha returns the stored pin" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "user/repo", "user", "homebrew-repo", valid_sha);
    const got = (try tap.getCommitSha(testing.allocator, &db, "user/repo")) orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(valid_sha, got);
}

test "getCommitSha returns null for unpinned tap" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "user/repo", "user", "homebrew-repo", null);
    try testing.expectEqual(
        @as(?[]const u8, null),
        try tap.getCommitSha(testing.allocator, &db, "user/repo"),
    );
}

test "getCommitSha returns null for unknown tap" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);
    try testing.expectEqual(
        @as(?[]const u8, null),
        try tap.getCommitSha(testing.allocator, &db, "nobody/unregistered"),
    );
}

test "validateCommitSha accepts 40-char lowercase hex" {
    try tap.validateCommitSha(valid_sha);
}

test "validateCommitSha rejects wrong length" {
    try testing.expectError(error.InvalidSha, tap.validateCommitSha("deadbeef"));
    try testing.expectError(error.InvalidSha, tap.validateCommitSha(valid_sha ++ "00"));
}

test "validateCommitSha rejects uppercase" {
    const upper = "ABCDEF0123456789ABCDEF0123456789ABCDEF01";
    try testing.expectError(error.InvalidSha, tap.validateCommitSha(upper));
}

test "validateCommitSha rejects non-hex chars" {
    const bad = "ggggggggggggggggggggggggggggggggggggggg0";
    try testing.expectError(error.InvalidSha, tap.validateCommitSha(bad));
}

test "remove deletes a tap" {
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "a/b", "a", "homebrew-b", valid_sha);
    try tap.add(&db, "c/d", "c", "homebrew-d", valid_sha);
    try tap.remove(&db, "a/b");

    const taps = try tap.list(testing.allocator, &db);
    defer freeTaps(taps);
    try testing.expectEqual(@as(usize, 1), taps.len);
    try testing.expectEqualStrings("c/d", taps[0].name);
}

// A missing schema previously turned into a silent no-op; now the
// caller sees the underlying sqlite rc and can distinguish it from a
// constraint violation or a bind failure.
test "add surfaces SqliteError when schema is missing" {
    var db = try openDb();
    defer db.close();

    try testing.expectError(
        sqlite.SqliteError.PrepareFailed,
        tap.add(&db, "user/repo", "user", "homebrew-repo", valid_sha),
    );
}

test "remove surfaces SqliteError when schema is missing" {
    var db = try openDb();
    defer db.close();

    try testing.expectError(
        sqlite.SqliteError.PrepareFailed,
        tap.remove(&db, "user/repo"),
    );
}

fn listAndFree(alloc: std.mem.Allocator, db: *sqlite.Database) !void {
    const taps = try tap.list(alloc, db);
    for (taps) |t| {
        alloc.free(t.name);
        alloc.free(t.url);
        if (t.commit_sha) |sha| alloc.free(sha);
    }
    alloc.free(taps);
}

test "list: partial-dupe failure on any allocation leaves zero leaks" {
    // BUG-011 regression guard: per-row dupes used to leak when a later
    // dupe or append failed, and completed rows were never walked.
    // Mix a pinned row with an unpinned one to exercise the optional-SHA branch.
    var db = try openDb();
    defer db.close();
    try schema.initSchema(&db);

    try tap.add(&db, "alpha/one", "alpha", "homebrew-one", valid_sha);
    try tap.add(&db, "beta/two", "beta", "homebrew-two", null);

    try testing.checkAllAllocationFailures(testing.allocator, listAndFree, .{&db});
}

test "resolveFormula joins user/repo/formula with slashes" {
    const s = try tap.resolveFormula(testing.allocator, "u", "r", "f");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("u/r/f", s);
}

// parseHeadSha and githubAuthHeader moved to the forge seam in the
// extraction; their exhaustive coverage now lives as inline tests in
// `src/core/forge.zig` (`parseHeadSha github: …`, `authHeader github: …`).

// ────────────────────────────────────────────────────────────────────
// classifyResolveStatus — callers rely on distinct tags to map each
// GitHub failure mode to a user-facing message. A blanket
// `ResolveFailed` would re-introduce the opaque "floating HEAD" error.
// ────────────────────────────────────────────────────────────────────

test "classifyResolveStatus: 403 is the rate-limit signal" {
    // Unauthenticated `/commits/HEAD` caps at 60/hr per IP. Past the
    // cap, the API answers 403 with a rate-limit body.
    try testing.expectEqual(tap.TapError.RateLimited, tap.classifyResolveStatus(403));
}

test "classifyResolveStatus: 404 maps to NotFound" {
    try testing.expectEqual(tap.TapError.NotFound, tap.classifyResolveStatus(404));
}

test "classifyResolveStatus: unexpected 5xx falls back to ResolveFailed" {
    try testing.expectEqual(tap.TapError.ResolveFailed, tap.classifyResolveStatus(500));
    try testing.expectEqual(tap.TapError.ResolveFailed, tap.classifyResolveStatus(502));
}

test "classifyResolveStatus: 401 (bad auth) is distinct from rate limit" {
    try testing.expectEqual(tap.TapError.ResolveFailed, tap.classifyResolveStatus(401));
}

// ────────────────────────────────────────────────────────────────────
// describeResolveError — load-bearing user-facing change: each tap
// failure mode gets a distinct remediation hint instead of the old
// blanket "floating HEAD" message.
// ────────────────────────────────────────────────────────────────────

test "describeResolveError: RateLimited names MALT_GITHUB_TOKEN" {
    const msg = tap.describeResolveError(tap.TapError.RateLimited);
    try testing.expect(std.mem.indexOf(u8, msg, "MALT_GITHUB_TOKEN") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "rate limit") != null);
}

test "describeResolveError: NotFound explains the homebrew- prefix rule" {
    const msg = tap.describeResolveError(tap.TapError.NotFound);
    try testing.expect(std.mem.indexOf(u8, msg, "homebrew-") != null);
}

test "describeResolveError: NetworkError mentions connectivity" {
    const msg = tap.describeResolveError(tap.TapError.NetworkError);
    try testing.expect(std.mem.indexOf(u8, msg, "etwork") != null or
        std.mem.indexOf(u8, msg, "onnect") != null);
}

test "describeResolveError: MalformedJson is distinct from ResolveFailed" {
    const malformed = tap.describeResolveError(tap.TapError.MalformedJson);
    const generic = tap.describeResolveError(tap.TapError.ResolveFailed);
    try testing.expect(!std.mem.eql(u8, malformed, generic));
}

test "describeResolveError: every TapError variant gets a non-empty hint" {
    inline for (@typeInfo(tap.TapError).error_set.?) |e| {
        const err = @field(tap.TapError, e.name);
        const msg = tap.describeResolveError(err);
        try testing.expect(msg.len > 0);
    }
}
