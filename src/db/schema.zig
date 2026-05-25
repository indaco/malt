const std = @import("std");
const sqlite = @import("sqlite.zig");

/// Initialize the database schema (CREATE TABLE IF NOT EXISTS).
/// Idempotent — safe to call on an existing database.
pub fn initSchema(db: *sqlite.Database) MigrateError!void {
    try db.beginTransaction();
    errdefer db.rollback();

    // 1. schema_version
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS schema_version (
        \\    version   INTEGER PRIMARY KEY,
        \\    applied   TEXT NOT NULL DEFAULT (datetime('now'))
        \\);
    );

    // 2. kegs
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS kegs (
        \\    id            INTEGER PRIMARY KEY,
        \\    name          TEXT NOT NULL,
        \\    full_name     TEXT NOT NULL,
        \\    version       TEXT NOT NULL,
        \\    revision      INTEGER NOT NULL DEFAULT 0,
        \\    tap           TEXT,
        \\    store_sha256  TEXT NOT NULL,
        \\    cellar_path   TEXT NOT NULL,
        \\    installed_at  TEXT NOT NULL DEFAULT (datetime('now')),
        \\    pinned        INTEGER NOT NULL DEFAULT 0,
        \\    install_reason TEXT NOT NULL DEFAULT 'direct',
        \\    UNIQUE(name, version)
        \\);
    );
    try db.exec("CREATE INDEX IF NOT EXISTS idx_kegs_name ON kegs(name);");
    try db.exec("CREATE INDEX IF NOT EXISTS idx_kegs_store ON kegs(store_sha256);");

    // 3. casks. `pinned` is added by v4, `tap` by v6 — both ALTERs are
    //    PRAGMA-guarded so fresh and upgraded DBs converge.
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS casks (
        \\    id            INTEGER PRIMARY KEY,
        \\    token         TEXT NOT NULL UNIQUE,
        \\    name          TEXT NOT NULL,
        \\    version       TEXT NOT NULL,
        \\    url           TEXT NOT NULL,
        \\    sha256        TEXT,
        \\    app_path      TEXT,
        \\    installed_at  TEXT NOT NULL DEFAULT (datetime('now')),
        \\    auto_updates  INTEGER NOT NULL DEFAULT 0
        \\);
    );

    // 3b. cask_versions — append-only history added by v7 so rollback
    //     has a per-version (url, sha256, cache_path, artifact_type)
    //     trail to reinstall from. CREATE IF NOT EXISTS here so fresh
    //     DBs ship with the v7 shape; the v6→v7 migration also creates
    //     and backfills it for upgraded DBs.
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS cask_versions (
        \\    id              INTEGER PRIMARY KEY,
        \\    token           TEXT NOT NULL,
        \\    version         TEXT NOT NULL,
        \\    url             TEXT NOT NULL,
        \\    sha256          TEXT,
        \\    artifact_type   TEXT,
        \\    cache_path      TEXT,
        \\    installed_at    TEXT NOT NULL DEFAULT (datetime('now')),
        \\    UNIQUE(token, version)
        \\);
    );
    try db.exec("CREATE INDEX IF NOT EXISTS idx_cask_versions_token ON cask_versions(token);");

    // 4. dependencies
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS dependencies (
        \\    keg_id     INTEGER NOT NULL REFERENCES kegs(id) ON DELETE CASCADE,
        \\    dep_name   TEXT NOT NULL,
        \\    dep_type   TEXT NOT NULL DEFAULT 'runtime',
        \\    PRIMARY KEY (keg_id, dep_name)
        \\);
    );

    // 5. links
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS links (
        \\    id         INTEGER PRIMARY KEY,
        \\    keg_id     INTEGER NOT NULL REFERENCES kegs(id) ON DELETE CASCADE,
        \\    link_path  TEXT NOT NULL UNIQUE,
        \\    target     TEXT NOT NULL
        \\);
    );
    try db.exec("CREATE INDEX IF NOT EXISTS idx_links_keg ON links(keg_id);");

    // 6. store_refs
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS store_refs (
        \\    store_sha256  TEXT PRIMARY KEY,
        \\    refcount      INTEGER NOT NULL DEFAULT 1
        \\);
    );

    // 7. taps. `commit_sha` is added by the v2→v3 migration below so
    //    fresh and upgraded DBs converge on the same final shape.
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS taps (
        \\    id         INTEGER PRIMARY KEY,
        \\    name       TEXT NOT NULL UNIQUE,
        \\    url        TEXT NOT NULL,
        \\    added_at   TEXT NOT NULL DEFAULT (datetime('now'))
        \\);
    );

    // Seed schema version
    try db.exec("INSERT OR IGNORE INTO schema_version (version) VALUES (1);");

    try db.commit();

    try migrate(db);
}

/// Highest schema version this binary knows how to operate on. Bump in
/// lockstep with the last `migrateVNtoVN+1` step so a future binary's
/// DB doesn't get silently used against older SQL.
pub const known_schema_version: i64 = 8;

pub const MigrateError = sqlite.SqliteError || error{SchemaTooNew};

/// Run any pending schema migrations. Refuses to operate on a DB whose
/// schema version exceeds `known_schema_version` — running an older
/// binary against a newer DB (e.g. multi-host shared `$MALT_PREFIX/db`)
/// would otherwise execute current SQL against a future shape.
pub fn migrate(db: *sqlite.Database) MigrateError!void {
    const ver = try currentVersion(db);
    if (ver > known_schema_version) return error.SchemaTooNew;
    if (ver < 2) try migrateV1toV2(db);
    if (ver < 3) try migrateV2toV3(db);
    if (ver < 4) try migrateV3toV4(db);
    if (ver < 5) try migrateV4toV5(db);
    if (ver < 6) try migrateV5toV6(db);
    if (ver < 7) try migrateV6toV7(db);
    if (ver < 8) try migrateV7toV8(db);
}

fn migrateV1toV2(db: *sqlite.Database) sqlite.SqliteError!void {
    try db.beginTransaction();
    errdefer db.rollback();

    try db.exec(
        \\CREATE TABLE IF NOT EXISTS services (
        \\    name             TEXT PRIMARY KEY,
        \\    keg_name         TEXT NOT NULL,
        \\    plist_path       TEXT NOT NULL,
        \\    auto_start       INTEGER NOT NULL DEFAULT 0,
        \\    last_started_at  INTEGER,
        \\    last_status      TEXT
        \\);
    );

    try db.exec(
        \\CREATE TABLE IF NOT EXISTS bundles (
        \\    name           TEXT PRIMARY KEY,
        \\    manifest_path  TEXT,
        \\    created_at     INTEGER NOT NULL,
        \\    version        INTEGER NOT NULL
        \\);
    );

    try db.exec(
        \\CREATE TABLE IF NOT EXISTS bundle_members (
        \\    bundle_name  TEXT NOT NULL REFERENCES bundles(name) ON DELETE CASCADE,
        \\    kind         TEXT NOT NULL,
        \\    ref          TEXT NOT NULL,
        \\    spec         TEXT,
        \\    PRIMARY KEY (bundle_name, kind, ref)
        \\);
    );

    try db.exec("INSERT OR IGNORE INTO schema_version (version) VALUES (2);");

    try db.commit();
}

/// v3 — pin third-party taps to a specific commit SHA so a hostile
/// HEAD can't silently swap a formula's URL/SHA256 out from under us.
fn migrateV2toV3(db: *sqlite.Database) sqlite.SqliteError!void {
    try db.beginTransaction();
    errdefer db.rollback();

    // ALTER guarded by PRAGMA so the migration is truly idempotent on
    // any DB that already carries the column (e.g. rerun against a
    // test fixture mid-development).
    var have_column = false;
    {
        var stmt = try db.prepare("PRAGMA table_info(taps);");
        defer stmt.finalize();
        while (try stmt.step()) {
            const name = stmt.columnText(1) orelse continue;
            if (std.mem.eql(u8, std.mem.sliceTo(name, 0), "commit_sha")) {
                have_column = true;
                break;
            }
        }
    }
    if (!have_column) {
        try db.exec("ALTER TABLE taps ADD COLUMN commit_sha TEXT;");
    }

    try db.exec("INSERT OR IGNORE INTO schema_version (version) VALUES (3);");

    try db.commit();
}

/// v4 — extend `pinned` to casks so `mt pin <cask>` and the
/// `--pinned-only` / `--pinned` audit surface are symmetric across
/// formulas and casks.
fn migrateV3toV4(db: *sqlite.Database) sqlite.SqliteError!void {
    try db.beginTransaction();
    errdefer db.rollback();

    // PRAGMA-guarded ALTER so the migration is idempotent on a DB that
    // already carries the column (re-runs against fresh fixtures).
    var have_column = false;
    {
        var stmt = try db.prepare("PRAGMA table_info(casks);");
        defer stmt.finalize();
        while (try stmt.step()) {
            const name = stmt.columnText(1) orelse continue;
            if (std.mem.eql(u8, std.mem.sliceTo(name, 0), "pinned")) {
                have_column = true;
                break;
            }
        }
    }
    if (!have_column) {
        try db.exec("ALTER TABLE casks ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;");
    }

    try db.exec("INSERT OR IGNORE INTO schema_version (version) VALUES (4);");

    try db.commit();
}

/// Best-effort restore of FK enforcement after the v5 rebuild window.
/// `defer` cannot return an error, so a silent `catch {}` would leave
/// the connection running without FKs for the rest of its lifetime if
/// the re-enable hit a transient SQLITE_BUSY. One retry covers that
/// case; surfacing remaining failures via `std.log.warn` is the only
/// recourse left.
fn reenableForeignKeys(db: *sqlite.Database) void {
    db.exec("PRAGMA foreign_keys=ON;") catch {
        db.exec("PRAGMA foreign_keys=ON;") catch |err| {
            std.log.warn("foreign_keys re-enable failed: {s}", .{@errorName(err)});
        };
    };
}

/// v5 — broaden the kegs UNIQUE from `(name, version)` to
/// `(name, version, revision)` so a Homebrew revision-bump upgrade
/// (`1.9.2` → `1.9.2_2`) can transiently coexist with the old row
/// during `recordKeg`'s "INSERT new, then DELETE old" sequence.
/// SQLite has no `ALTER TABLE DROP CONSTRAINT`, so the table is
/// rebuilt per the official recipe.
fn migrateV4toV5(db: *sqlite.Database) sqlite.SqliteError!void {
    // Substring-probe the stored CREATE statement: cheaper than a
    // structural scan, and unique to v5 since this migration is the
    // only writer of the new UNIQUE shape.
    var already_migrated = false;
    {
        var stmt = try db.prepare(
            \\SELECT sql FROM sqlite_master
            \\WHERE type='table' AND name='kegs';
        );
        defer stmt.finalize();
        if (try stmt.step()) {
            const sql_ptr = stmt.columnText(0) orelse "";
            const sql = std.mem.sliceTo(sql_ptr, 0);
            if (std.mem.indexOf(u8, sql, "UNIQUE(name, version, revision)") != null) {
                already_migrated = true;
            }
        }
    }

    if (already_migrated) {
        // Schema is current; just bump the version marker for fixtures
        // that pre-applied the table then reset schema_version.
        try db.exec("INSERT OR IGNORE INTO schema_version (version) VALUES (5);");
        return;
    }

    // FK toggle must live outside any transaction. Disabling lets us
    // DROP `kegs` without tripping `dependencies.keg_id` / `links.keg_id`;
    // the RENAME then rewrites those references at the new table.
    try db.exec("PRAGMA foreign_keys=OFF;");
    defer reenableForeignKeys(db);

    try db.beginTransaction();
    errdefer db.rollback();

    try db.exec(
        \\CREATE TABLE kegs_new (
        \\    id            INTEGER PRIMARY KEY,
        \\    name          TEXT NOT NULL,
        \\    full_name     TEXT NOT NULL,
        \\    version       TEXT NOT NULL,
        \\    revision      INTEGER NOT NULL DEFAULT 0,
        \\    tap           TEXT,
        \\    store_sha256  TEXT NOT NULL,
        \\    cellar_path   TEXT NOT NULL,
        \\    installed_at  TEXT NOT NULL DEFAULT (datetime('now')),
        \\    pinned        INTEGER NOT NULL DEFAULT 0,
        \\    install_reason TEXT NOT NULL DEFAULT 'direct',
        \\    UNIQUE(name, version, revision)
        \\);
    );
    try db.exec(
        \\INSERT INTO kegs_new
        \\    (id, name, full_name, version, revision, tap, store_sha256,
        \\     cellar_path, installed_at, pinned, install_reason)
        \\SELECT id, name, full_name, version, revision, tap, store_sha256,
        \\       cellar_path, installed_at, pinned, install_reason
        \\FROM kegs;
    );
    try db.exec("DROP TABLE kegs;");
    try db.exec("ALTER TABLE kegs_new RENAME TO kegs;");
    try db.exec("CREATE INDEX IF NOT EXISTS idx_kegs_name ON kegs(name);");
    try db.exec("CREATE INDEX IF NOT EXISTS idx_kegs_store ON kegs(store_sha256);");

    try db.exec("INSERT OR IGNORE INTO schema_version (version) VALUES (5);");

    // SQLite recipe step 7: with FKs disabled around the rebuild, a
    // dangling child row would silently survive the commit. The pragma
    // emits one row per violation; presence of any row aborts.
    {
        var stmt = try db.prepare("PRAGMA foreign_key_check;");
        defer stmt.finalize();
        if (try stmt.step()) return sqlite.SqliteError.ConstraintViolation;
    }

    try db.commit();
}

/// v6 — record the originating tap on every cask row so `mt upgrade`
/// can pre-route directly to the owning tap instead of probing every
/// registered tap on each invocation. Legacy rows stay NULL until the
/// next upgrade fills them in via the fallback probe.
fn migrateV5toV6(db: *sqlite.Database) sqlite.SqliteError!void {
    try db.beginTransaction();
    errdefer db.rollback();

    var have_column = false;
    {
        var stmt = try db.prepare("PRAGMA table_info(casks);");
        defer stmt.finalize();
        while (try stmt.step()) {
            const name = stmt.columnText(1) orelse continue;
            if (std.mem.eql(u8, std.mem.sliceTo(name, 0), "tap")) {
                have_column = true;
                break;
            }
        }
    }
    if (!have_column) {
        try db.exec("ALTER TABLE casks ADD COLUMN tap TEXT;");
    }

    try db.exec("INSERT OR IGNORE INTO schema_version (version) VALUES (6);");

    try db.commit();
}

/// v7 — introduce cask_versions, an append-only per-version history so
/// `mt rollback <cask> --list / --to` has a URL + SHA + cache hint per
/// retained version. Backfills existing casks rows so users who upgrade
/// without a fresh install still see their currently-installed cask in
/// the listing.
fn migrateV6toV7(db: *sqlite.Database) sqlite.SqliteError!void {
    try db.beginTransaction();
    errdefer db.rollback();

    try db.exec(
        \\CREATE TABLE IF NOT EXISTS cask_versions (
        \\    id              INTEGER PRIMARY KEY,
        \\    token           TEXT NOT NULL,
        \\    version         TEXT NOT NULL,
        \\    url             TEXT NOT NULL,
        \\    sha256          TEXT,
        \\    artifact_type   TEXT,
        \\    cache_path      TEXT,
        \\    installed_at    TEXT NOT NULL DEFAULT (datetime('now')),
        \\    UNIQUE(token, version)
        \\);
    );
    try db.exec("CREATE INDEX IF NOT EXISTS idx_cask_versions_token ON cask_versions(token);");

    // Backfill only when the canonical casks columns are present. Tests
    // and forensic fixtures sometimes pre-seed a partial `casks` table
    // shape; aborting the migration on that ground would surface as a
    // hard "schema_init" failure later instead of the precise error the
    // affected scope reports.
    if (try caskColumnsPresent(db, &.{ "token", "version", "url", "sha256", "installed_at" })) {
        // INSERT OR IGNORE so a partial backfill on a prior run (or a
        // fresh DB that already shipped with cask_versions populated)
        // stays a no-op rather than tripping UNIQUE(token, version).
        try db.exec(
            \\INSERT OR IGNORE INTO cask_versions
            \\    (token, version, url, sha256, installed_at)
            \\SELECT token, version, url, sha256, installed_at FROM casks;
        );
    }

    try db.exec("INSERT OR IGNORE INTO schema_version (version) VALUES (7);");

    try db.commit();
}

/// v8 — persist the GitHub ETag for `/commits/HEAD` alongside the
/// commit SHA so subsequent resolves can send `If-None-Match` and let
/// 304 responses short-circuit the GitHub rate-limit cost. Same
/// PRAGMA-guarded ALTER shape as v2→v3 / v3→v4 / v5→v6 so re-runs
/// against partially migrated fixtures stay idempotent.
fn migrateV7toV8(db: *sqlite.Database) sqlite.SqliteError!void {
    try db.beginTransaction();
    errdefer db.rollback();

    // PRAGMA table_info returns zero rows when the table is missing — the
    // forensic/partial-shape fixtures exercised by the v6→v7 migration
    // tests sometimes ship without a `taps` table, and aborting the
    // chain there would surface as a hard "schema_init" failure later.
    var have_table = false;
    var have_column = false;
    {
        var stmt = try db.prepare("PRAGMA table_info(taps);");
        defer stmt.finalize();
        while (try stmt.step()) {
            have_table = true;
            const name = stmt.columnText(1) orelse continue;
            if (std.mem.eql(u8, std.mem.sliceTo(name, 0), "head_etag")) {
                have_column = true;
                break;
            }
        }
    }
    if (have_table and !have_column) {
        try db.exec("ALTER TABLE taps ADD COLUMN head_etag TEXT;");
    }

    try db.exec("INSERT OR IGNORE INTO schema_version (version) VALUES (8);");

    try db.commit();
}

/// Return true iff every column in `wanted` is present on the `casks`
/// table. Mirrors the PRAGMA-guarded probes used by v2→v3 / v3→v4 /
/// v5→v6; centralised here because the v6→v7 backfill needs five
/// columns, not one.
fn caskColumnsPresent(db: *sqlite.Database, wanted: []const []const u8) sqlite.SqliteError!bool {
    var seen: u32 = 0;
    var stmt = try db.prepare("PRAGMA table_info(casks);");
    defer stmt.finalize();
    while (try stmt.step()) {
        const name_ptr = stmt.columnText(1) orelse continue;
        const name = std.mem.sliceTo(name_ptr, 0);
        for (wanted, 0..) |w, i| {
            if (std.mem.eql(u8, name, w)) seen |= (@as(u32, 1) << @intCast(i));
        }
    }
    const all: u32 = (@as(u32, 1) << @intCast(wanted.len)) - 1;
    return seen == all;
}

/// Query the current schema version.
pub fn currentVersion(db: *sqlite.Database) sqlite.SqliteError!i64 {
    var stmt = try db.prepare("SELECT MAX(version) FROM schema_version;");
    defer stmt.finalize();

    const has_row = try stmt.step();
    if (!has_row) return 0;

    return stmt.columnInt(0);
}

const testing = std.testing;

// Regression: a Homebrew revision-bump upgrade ("1.9.2" → "1.9.2_2")
// transiently coexists with the old row inside upgradeFormula's
// "INSERT new, DELETE old" sequence. The kegs UNIQUE shape must
// permit that pair; only an exact (name, version, revision) duplicate
// should violate.
test "kegs UNIQUE permits same name+version across revisions" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
        \\VALUES ('libgit2', 'libgit2', '1.9.2', 0, 'sha-old', '/c/libgit2/1.9.2');
    );

    // Same upstream version, bumped revision: must succeed.
    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
        \\VALUES ('libgit2', 'libgit2', '1.9.2', 2, 'sha-new', '/c/libgit2/1.9.2_2');
    );

    // Exact (name, version, revision) duplicate: still rejected.
    const dup = db.exec(
        \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
        \\VALUES ('libgit2', 'libgit2', '1.9.2', 2, 'sha-dup', '/c/libgit2/dup');
    );
    try testing.expectError(sqlite.SqliteError.ConstraintViolation, dup);
}

// The v4→v5 rebuild runs with foreign_keys=OFF so the DROP can succeed,
// which means an orphaned child row would silently survive the commit
// without the SQLite recipe's foreign_key_check safety net.
test "v4→v5 migration aborts when foreign_key_check finds a violation" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();

    // Build the v4-shape subset directly: substring probe must miss
    // (forces the rebuild path) and the FK target name must resolve.
    try db.exec(
        \\CREATE TABLE schema_version (
        \\    version INTEGER PRIMARY KEY,
        \\    applied TEXT NOT NULL DEFAULT (datetime('now'))
        \\);
    );
    try db.exec(
        \\CREATE TABLE kegs (
        \\    id            INTEGER PRIMARY KEY,
        \\    name          TEXT NOT NULL,
        \\    full_name     TEXT NOT NULL,
        \\    version       TEXT NOT NULL,
        \\    revision      INTEGER NOT NULL DEFAULT 0,
        \\    tap           TEXT,
        \\    store_sha256  TEXT NOT NULL,
        \\    cellar_path   TEXT NOT NULL,
        \\    installed_at  TEXT NOT NULL DEFAULT (datetime('now')),
        \\    pinned        INTEGER NOT NULL DEFAULT 0,
        \\    install_reason TEXT NOT NULL DEFAULT 'direct',
        \\    UNIQUE(name, version)
        \\);
    );
    try db.exec(
        \\CREATE TABLE dependencies (
        \\    keg_id     INTEGER NOT NULL REFERENCES kegs(id) ON DELETE CASCADE,
        \\    dep_name   TEXT NOT NULL,
        \\    dep_type   TEXT NOT NULL DEFAULT 'runtime',
        \\    PRIMARY KEY (keg_id, dep_name)
        \\);
    );

    // Seed an orphan dependency with FKs disabled. The migration's
    // ID-preserving rebuild keeps it dangling until the FK check runs.
    try db.exec("PRAGMA foreign_keys=OFF;");
    try db.exec("INSERT INTO dependencies(keg_id, dep_name) VALUES (42, 'orphan');");
    try db.exec("PRAGMA foreign_keys=ON;");

    try db.exec("INSERT INTO schema_version (version) VALUES (4);");

    try testing.expectError(sqlite.SqliteError.ConstraintViolation, migrate(&db));

    // Rollback must leave the schema at v4 so a future run can retry.
    try testing.expectEqual(@as(i64, 4), try currentVersion(&db));
}

// v6→v7 backfills the new cask_versions table from existing casks rows
// so upgrade-then-rollback on a cask that was installed before the
// migration ran still has a history entry to roll back to.
test "v6→v7 migration backfills cask_versions from existing casks rows" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    // Seed two casks rows on the now-current schema so the next
    // initSchema call (post-bump) treats them as legacy state.
    try db.exec(
        \\INSERT INTO casks (token, name, version, url, sha256)
        \\VALUES ('flux-markdown', 'flux-markdown', '1.32.427',
        \\        'https://example.invalid/flux.dmg', 'aa'),
        \\       ('firefox', 'Firefox', '120.0',
        \\        'https://example.invalid/firefox.dmg', 'bb');
    );

    // Force the schema marker back to v6 so the migrate call re-runs the
    // v6→v7 step against the seeded rows — the same path a user upgrading
    // an existing install hits on first launch of the new binary.
    try db.exec("DELETE FROM schema_version WHERE version >= 7;");

    try migrate(&db);

    var stmt = try db.prepare(
        "SELECT token, version, url FROM cask_versions ORDER BY token;",
    );
    defer stmt.finalize();

    try testing.expect(try stmt.step());
    const token0 = stmt.columnText(0) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("firefox", std.mem.sliceTo(token0, 0));
    const ver0 = stmt.columnText(1) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("120.0", std.mem.sliceTo(ver0, 0));

    try testing.expect(try stmt.step());
    const token1 = stmt.columnText(0) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("flux-markdown", std.mem.sliceTo(token1, 0));

    try testing.expectEqual(@as(i64, 8), try currentVersion(&db));
}

test "v6→v7 migration is idempotent when cask_versions already carries the rows" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    try db.exec(
        \\INSERT INTO casks (token, name, version, url, sha256)
        \\VALUES ('flux-markdown', 'flux-markdown', '1.32.427',
        \\        'https://example.invalid/flux.dmg', 'aa');
    );

    // First run: backfills.
    try db.exec("DELETE FROM schema_version WHERE version >= 7;");
    try migrate(&db);

    // Second run: same DB, the backfill must not double-insert.
    try db.exec("DELETE FROM schema_version WHERE version >= 7;");
    try migrate(&db);

    var cnt = try db.prepare("SELECT COUNT(*) FROM cask_versions WHERE token = 'flux-markdown';");
    defer cnt.finalize();
    _ = try cnt.step();
    try testing.expectEqual(@as(i64, 1), cnt.columnInt(0));
}

// v7→v8 adds taps.head_etag so resolveHeadCommit can send
// `If-None-Match` and let GitHub answer 304 without spending a
// rate-limit token. Fresh and upgraded DBs must converge on the same
// shape; the migration is PRAGMA-guarded so re-runs against partially
// migrated fixtures stay idempotent.
test "fresh DB ships with taps.head_etag (v8 shape)" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    var stmt = try db.prepare("PRAGMA table_info(taps);");
    defer stmt.finalize();
    var found = false;
    while (try stmt.step()) {
        const name = stmt.columnText(1) orelse continue;
        if (std.mem.eql(u8, std.mem.sliceTo(name, 0), "head_etag")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
    try testing.expectEqual(@as(i64, 8), try currentVersion(&db));
}

test "v7→v8 migration adds head_etag and preserves existing tap rows" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    // Seed a tap row on the current shape, then rewind the version marker
    // to v7 so `migrate` re-enters the v7→v8 step against the seeded row.
    try db.exec(
        \\INSERT INTO taps (name, url, commit_sha)
        \\VALUES ('aeroxy/tap', 'https://github.com/aeroxy/homebrew-tap',
        \\        '0123456789abcdef0123456789abcdef01234567');
    );
    try db.exec("DELETE FROM schema_version WHERE version >= 8;");

    try migrate(&db);

    var probe = try db.prepare(
        "SELECT commit_sha, head_etag FROM taps WHERE name='aeroxy/tap';",
    );
    defer probe.finalize();
    try testing.expect(try probe.step());
    const sha = probe.columnText(0) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef01234567",
        std.mem.sliceTo(sha, 0),
    );
    // Pre-v8 rows must carry NULL until a conditional GET populates it.
    try testing.expect(probe.columnText(1) == null);
    try testing.expectEqual(@as(i64, 8), try currentVersion(&db));
}

test "v7→v8 migration is idempotent when head_etag is already present" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    // Stamp the column with a value, rewind, re-run the migration. The
    // PRAGMA guard must skip the ALTER and leave the value untouched.
    try db.exec(
        \\INSERT INTO taps (name, url, commit_sha, head_etag)
        \\VALUES ('aeroxy/tap', 'https://github.com/aeroxy/homebrew-tap',
        \\        '0123456789abcdef0123456789abcdef01234567',
        \\        'W/"deadbeef"');
    );
    try db.exec("DELETE FROM schema_version WHERE version >= 8;");

    try migrate(&db);

    var probe = try db.prepare("SELECT head_etag FROM taps WHERE name='aeroxy/tap';");
    defer probe.finalize();
    try testing.expect(try probe.step());
    const et = probe.columnText(0) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("W/\"deadbeef\"", std.mem.sliceTo(et, 0));
}

test "migrate refuses a DB whose schema_version exceeds the known max" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();

    // Minimal v1 shape — a `schema_version` table with one future row is
    // enough to reach the version probe in `migrate`.
    try db.exec(
        \\CREATE TABLE schema_version (
        \\    version INTEGER PRIMARY KEY,
        \\    applied TEXT NOT NULL DEFAULT (datetime('now'))
        \\);
    );
    try db.exec("INSERT INTO schema_version (version) VALUES (999);");

    try testing.expectError(error.SchemaTooNew, migrate(&db));
    // Untouched: refusal must not silently bump the version.
    try testing.expectEqual(@as(i64, 999), try currentVersion(&db));
}
