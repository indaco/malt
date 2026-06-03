//! malt — end-to-end integration for the ETag-aware tap HEAD resolve.
//!
//! Inline tests in `src/core/tap.zig` cover `resolveFromConditional` in
//! isolation; the regression script `scripts/regressions/tap_head_etag_304.sh`
//! covers the real-network conditional GET. This file pins the
//! assembled middle layer: schema v8 + `getHeadEtag` + `updateHead`
//! survive a full cold-start → warm-start → cache-bust cycle without
//! drifting the (sha, etag) invariant.

const std = @import("std");
const testing = std.testing;

const malt = @import("malt");
const sqlite = malt.sqlite;
const schema = malt.schema;
const tap = malt.tap;
const client = malt.client;

const fresh_sha = "0123456789abcdef0123456789abcdef01234567";
const moved_sha = "abcdef0123456789abcdef0123456789abcdef01";
const fresh_etag = "W/\"abc123\"";
const moved_etag = "W/\"def456\"";

fn openDb() !sqlite.Database {
    var db = try sqlite.Database.open(":memory:");
    errdefer db.close();
    try schema.initSchema(&db);
    return db;
}

// ── End-to-end DB+helper integration ───────────────────────────────

test "cold start: getHeadEtag returns null before any resolve" {
    var db = try openDb();
    defer db.close();
    try tap.add(&db, "aeroxy/tap", "aeroxy", "homebrew-tap", null);

    const et = try tap.getHeadEtag(testing.allocator, &db, "aeroxy/tap");
    try testing.expectEqual(@as(?[]const u8, null), et);
}

test "warm start: a 200 response persists (sha, etag); next round can short-circuit" {
    var db = try openDb();
    defer db.close();
    try tap.add(&db, "aeroxy/tap", "aeroxy", "homebrew-tap", null);

    // Simulate the cold-start resolve: HeadResolution{sha, etag} →
    // updateHead atomically pairs them in the row.
    try tap.updateHead(&db, "aeroxy/tap", fresh_sha, fresh_etag);

    // The next round reads both back; the caller passes cached_etag to
    // resolveHeadCommit, which sends it as If-None-Match.
    const sha = (try tap.getCommitSha(testing.allocator, &db, "aeroxy/tap")).?;
    defer testing.allocator.free(sha);
    const et = (try tap.getHeadEtag(testing.allocator, &db, "aeroxy/tap")).?;
    defer testing.allocator.free(et);
    try testing.expectEqualStrings(fresh_sha, sha);
    try testing.expectEqualStrings(fresh_etag, et);
}

test "304 response: caller keeps cached sha, no DB write happens" {
    var db = try openDb();
    defer db.close();
    try tap.add(&db, "aeroxy/tap", "aeroxy", "homebrew-tap", null);
    try tap.updateHead(&db, "aeroxy/tap", fresh_sha, fresh_etag);

    // Mimic resolveFromConditional on a 304: HeadResolution.not_modified=true,
    // sha=null. Caller-side logic (install / outdated / upgrade) reads
    // cached_sha and skips updateHead.
    var resp: client.ConditionalResponse = .{
        .status = 304,
        .not_modified = true,
        .body = try testing.allocator.alloc(u8, 0),
        .etag = try testing.allocator.dupe(u8, fresh_etag),
        .allocator = testing.allocator,
    };
    defer resp.deinit();
    var res = try tap.resolveFromConditional(testing.allocator, .github, resp);
    defer res.deinit();
    try testing.expect(res.not_modified);
    try testing.expectEqual(@as(?[]const u8, null), res.sha);

    // DB row is unchanged.
    const sha_after = (try tap.getCommitSha(testing.allocator, &db, "aeroxy/tap")).?;
    defer testing.allocator.free(sha_after);
    const et_after = (try tap.getHeadEtag(testing.allocator, &db, "aeroxy/tap")).?;
    defer testing.allocator.free(et_after);
    try testing.expectEqualStrings(fresh_sha, sha_after);
    try testing.expectEqualStrings(fresh_etag, et_after);
}

test "cache-bust: a clobbered etag triggers a 200 path that updates both fields" {
    var db = try openDb();
    defer db.close();
    try tap.add(&db, "aeroxy/tap", "aeroxy", "homebrew-tap", null);
    try tap.updateHead(&db, "aeroxy/tap", fresh_sha, "W/\"stale\"");

    // The server returns 200 because the stale etag doesn't match.
    var resp: client.ConditionalResponse = .{
        .status = 200,
        .not_modified = false,
        .body = try testing.allocator.dupe(
            u8,
            "{\"sha\":\"" ++ moved_sha ++ "\"}",
        ),
        .etag = try testing.allocator.dupe(u8, moved_etag),
        .allocator = testing.allocator,
    };
    defer resp.deinit();
    var res = try tap.resolveFromConditional(testing.allocator, .github, resp);
    defer res.deinit();
    try testing.expect(!res.not_modified);
    try testing.expectEqualStrings(moved_sha, res.sha.?);
    try testing.expectEqualStrings(moved_etag, res.etag.?);

    // Caller persists — order matters: updateHead writes sha+etag in
    // one statement so a partial-failure window cannot leave the row
    // pointing at the old sha with the new etag.
    try tap.updateHead(&db, "aeroxy/tap", res.sha.?, res.etag);
    const sha_after = (try tap.getCommitSha(testing.allocator, &db, "aeroxy/tap")).?;
    defer testing.allocator.free(sha_after);
    const et_after = (try tap.getHeadEtag(testing.allocator, &db, "aeroxy/tap")).?;
    defer testing.allocator.free(et_after);
    try testing.expectEqualStrings(moved_sha, sha_after);
    try testing.expectEqualStrings(moved_etag, et_after);
}

test "server omits ETag on 200: sha persists, etag column is cleared" {
    // Behind-a-proxy edge case — caller must fall back to unconditional
    // GET on the next round rather than carrying a stale etag forward.
    var db = try openDb();
    defer db.close();
    try tap.add(&db, "aeroxy/tap", "aeroxy", "homebrew-tap", null);
    try tap.updateHead(&db, "aeroxy/tap", fresh_sha, fresh_etag);

    var resp: client.ConditionalResponse = .{
        .status = 200,
        .not_modified = false,
        .body = try testing.allocator.dupe(
            u8,
            "{\"sha\":\"" ++ moved_sha ++ "\"}",
        ),
        .etag = null,
        .allocator = testing.allocator,
    };
    defer resp.deinit();
    var res = try tap.resolveFromConditional(testing.allocator, .github, resp);
    defer res.deinit();
    try tap.updateHead(&db, "aeroxy/tap", res.sha.?, res.etag);

    const et_after = try tap.getHeadEtag(testing.allocator, &db, "aeroxy/tap");
    try testing.expectEqual(@as(?[]const u8, null), et_after);
}

// ── Migration path: pre-v8 DB upgrades cleanly ─────────────────────

test "pre-v8 DB upgrades to v8 and carries existing tap rows forward (etag NULL)" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    try db.exec(
        \\INSERT INTO taps (name, url, commit_sha)
        \\VALUES ('aeroxy/tap', 'https://github.com/aeroxy/homebrew-tap',
        \\        '0123456789abcdef0123456789abcdef01234567');
    );
    try db.exec("DELETE FROM schema_version WHERE version >= 8;");
    try schema.migrate(&db);

    const sha = (try tap.getCommitSha(testing.allocator, &db, "aeroxy/tap")).?;
    defer testing.allocator.free(sha);
    try testing.expectEqualStrings("0123456789abcdef0123456789abcdef01234567", sha);

    const et = try tap.getHeadEtag(testing.allocator, &db, "aeroxy/tap");
    try testing.expectEqual(@as(?[]const u8, null), et);

    // Next resolve hits the unconditional-GET path; on 200 we land
    // here, populating the etag for subsequent rounds.
    try tap.updateHead(&db, "aeroxy/tap", "0123456789abcdef0123456789abcdef01234567", fresh_etag);
    const et2 = (try tap.getHeadEtag(testing.allocator, &db, "aeroxy/tap")).?;
    defer testing.allocator.free(et2);
    try testing.expectEqualStrings(fresh_etag, et2);
}

// ── Concurrent writers: SERIALIZED-mode SQLite tolerates dup writes ─

test "sequential writers of the same (sha, etag) last-writer-wins" {
    // Sanity floor for the concurrent test below: the same row mutated
    // 16x in a row must end at the agreed values.
    var db = try openDb();
    defer db.close();
    try tap.add(&db, "aeroxy/tap", "aeroxy", "homebrew-tap", null);

    for (0..16) |_| {
        try tap.updateHead(&db, "aeroxy/tap", fresh_sha, fresh_etag);
    }

    const sha = (try tap.getCommitSha(testing.allocator, &db, "aeroxy/tap")).?;
    defer testing.allocator.free(sha);
    const et = (try tap.getHeadEtag(testing.allocator, &db, "aeroxy/tap")).?;
    defer testing.allocator.free(et);
    try testing.expectEqualStrings(fresh_sha, sha);
    try testing.expectEqualStrings(fresh_etag, et);
}

// Real-thread concurrency check. The outdated worker pool can have N
// workers hitting `updateHead` / `getHeadEtag` on the shared DB pointer
// at once when several installed casks share a tap. SERIALIZED mode
// (THREADSAFE=1 in build.zig) serialises per-API call inside SQLite —
// this test exercises that empirically rather than trusting the docs.
const ConcurrentCtx = struct {
    db: *sqlite.Database,
    iterations: usize,
    // SqliteError is the only failure modeled; the runner widens to
    // anyerror so a stray OOM from getHeadEtag's allocator surfaces too.
    err: ?anyerror = null,

    fn run(self: *ConcurrentCtx) void {
        var i: usize = 0;
        while (i < self.iterations) : (i += 1) {
            tap.updateHead(self.db, "aeroxy/tap", fresh_sha, fresh_etag) catch |e| {
                self.err = e;
                return;
            };
            // Mix read + write so the serialisation has to cover both
            // sides of the API surface, not just writes.
            const got = tap.getHeadEtag(testing.allocator, self.db, "aeroxy/tap") catch |e| {
                self.err = e;
                return;
            };
            if (got) |g| testing.allocator.free(g);
        }
    }
};

test "concurrent workers (real threads) leave the row consistent under SQLite SERIALIZED" {
    var db = try openDb();
    defer db.close();
    try tap.add(&db, "aeroxy/tap", "aeroxy", "homebrew-tap", null);

    const thread_count: usize = 8;
    const iterations_per_thread: usize = 64;

    var ctxs: [thread_count]ConcurrentCtx = undefined;
    for (&ctxs) |*c| c.* = .{ .db = &db, .iterations = iterations_per_thread };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads, &ctxs) |*t, *c| {
        t.* = try std.Thread.spawn(.{}, ConcurrentCtx.run, .{c});
    }
    for (threads) |t| t.join();

    // No worker tripped on a SQLITE_BUSY / OOM / mapped-error.
    for (ctxs) |c| try testing.expect(c.err == null);

    // Row converged to the agreed value (all writers wrote the same).
    const sha = (try tap.getCommitSha(testing.allocator, &db, "aeroxy/tap")).?;
    defer testing.allocator.free(sha);
    const et = (try tap.getHeadEtag(testing.allocator, &db, "aeroxy/tap")).?;
    defer testing.allocator.free(et);
    try testing.expectEqualStrings(fresh_sha, sha);
    try testing.expectEqualStrings(fresh_etag, et);
}

// ── Edge case: validator rejects bad SHA before any write ──────────

test "updateHead's validator runs before the UPDATE, even with a non-null etag" {
    // A bad sha must not silently store an etag tied to a phantom row;
    // the validator gates both fields together so the (sha, etag)
    // invariant is upheld at every callsite.
    var db = try openDb();
    defer db.close();
    try tap.add(&db, "aeroxy/tap", "aeroxy", "homebrew-tap", null);
    try tap.updateHead(&db, "aeroxy/tap", fresh_sha, fresh_etag);

    try testing.expectError(
        tap.TapError.InvalidSha,
        tap.updateHead(&db, "aeroxy/tap", "00", "W/\"new\""),
    );

    const sha = (try tap.getCommitSha(testing.allocator, &db, "aeroxy/tap")).?;
    defer testing.allocator.free(sha);
    const et = (try tap.getHeadEtag(testing.allocator, &db, "aeroxy/tap")).?;
    defer testing.allocator.free(et);
    try testing.expectEqualStrings(fresh_sha, sha);
    try testing.expectEqualStrings(fresh_etag, et);
}
