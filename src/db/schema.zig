const std = @import("std");
const testing = std.testing;

const sqlite = @import("sqlite.zig");
const tap_slug = @import("../tap_slug.zig");

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

    // 2. kegs. The fresh shape ships both the v5 UNIQUE and the
    //    `bin_isolated` v10 adds by ALTER on upgraded DBs, so the v4→v5
    //    step short-circuits here instead of rebuilding an empty table.
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
        \\    bin_isolated  INTEGER NOT NULL DEFAULT 0,
        \\    UNIQUE(name, version, revision)
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
pub const known_schema_version: i64 = 14;

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
    if (ver < 9) try migrateV8toV9(db);
    if (ver < 10) try migrateV9toV10(db);
    if (ver < 11) try migrateV10toV11(db);
    if (ver < 12) try migrateV11toV12(db);
    if (ver < 13) try migrateV12toV13(db);
    if (ver < 14) try migrateV13toV14(db);
}

fn migrateV1toV2(db: *sqlite.Database) sqlite.SqliteError!void {
    try db.beginTransaction();
    errdefer db.rollback();

    // `schedule` is added by v13's ALTER on upgraded DBs; the fresh shape
    // ships with it so both paths converge. Nullable: a NULL means run-at-load.
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS services (
        \\    name             TEXT PRIMARY KEY,
        \\    keg_name         TEXT NOT NULL,
        \\    plist_path       TEXT NOT NULL,
        \\    auto_start       INTEGER NOT NULL DEFAULT 0,
        \\    last_started_at  INTEGER,
        \\    last_status      TEXT,
        \\    schedule         TEXT
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

/// Restore FK enforcement after the v5 rebuild. Retries once on a
/// transient SQLITE_BUSY, then escalates: a connection that stays
/// FK-off would silently turn `ON DELETE CASCADE` into a no-op for the
/// rest of its lifetime. Use this on the success path so the migration
/// fails loud rather than committing the table rebuild over a dirty
/// connection.
fn ensureForeignKeysOn(db: *sqlite.Database) sqlite.SqliteError!void {
    db.exec("PRAGMA foreign_keys=ON;") catch {
        return db.exec("PRAGMA foreign_keys=ON;");
    };
}

/// Error-unwind variant: `errdefer` can't propagate, so all we can do
/// when the rebuild itself failed is log and move on. The caller is
/// already returning an error to its own caller.
fn bestEffortEnableForeignKeys(db: *sqlite.Database) void {
    ensureForeignKeysOn(db) catch |err| {
        std.log.warn("foreign_keys re-enable failed during error unwind: {s}", .{@errorName(err)});
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
    // Split safety net: best-effort on unwind, hard re-enable on success.
    errdefer bestEffortEnableForeignKeys(db);

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

    // Success path: FK enforcement must come back on or the connection
    // stays dirty for its lifetime — a partial re-enable would silently
    // demote every later ON DELETE CASCADE to a no-op.
    try ensureForeignKeysOn(db);
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

/// v9 — promote the `homebrew-<repo>` prefix decision from inline format
/// strings into structured `(github_owner, github_repo)` columns. The
/// helper at `core/tap.zig` reads from the row; the prefix is no longer
/// synthesised at fetch time. Existing rows backfill from the slug, so
/// pre-v9 prefixed taps keep fetching from the same URLs byte-for-byte.
fn migrateV8toV9(db: *sqlite.Database) sqlite.SqliteError!void {
    try db.beginTransaction();
    errdefer db.rollback();

    // PRAGMA table_info returns zero rows when the table is missing — same
    // partial-shape fixture defensiveness as v7→v8.
    var have_table = false;
    var have_owner = false;
    var have_repo = false;
    {
        var stmt = try db.prepare("PRAGMA table_info(taps);");
        defer stmt.finalize();
        while (try stmt.step()) {
            have_table = true;
            const name = stmt.columnText(1) orelse continue;
            const n = std.mem.sliceTo(name, 0);
            if (std.mem.eql(u8, n, "github_owner")) have_owner = true;
            if (std.mem.eql(u8, n, "github_repo")) have_repo = true;
        }
    }
    if (have_table and !have_owner) {
        // DEFAULT '' so ALTER over a non-empty table doesn't violate
        // NOT NULL; the backfill below replaces every '' with a real value.
        try db.exec("ALTER TABLE taps ADD COLUMN github_owner TEXT NOT NULL DEFAULT '';");
    }
    if (have_table and !have_repo) {
        try db.exec("ALTER TABLE taps ADD COLUMN github_repo TEXT NOT NULL DEFAULT '';");
    }

    // Backfill only rows that still carry the ALTER default. A row whose
    // pair was already populated (re-run, fresh DB, custom `--repo` insert
    // applied before the migration marker rewound) keeps its value.
    //
    // `instr(name, '/')`: SQLite returns 0 when the slash is absent. The
    // CASE branches keep malformed slugs from corrupting the row — the
    // verbatim fallback preserves what's there rather than producing a
    // negative substring length.
    if (have_table) {
        try db.exec(
            \\UPDATE taps SET
            \\    github_owner = CASE WHEN instr(name, '/') > 0
            \\                        THEN substr(name, 1, instr(name, '/') - 1)
            \\                        ELSE name END,
            \\    github_repo  = CASE WHEN instr(name, '/') > 0
            \\                        THEN 'homebrew-' || substr(name, instr(name, '/') + 1)
            \\                        ELSE name END
            \\WHERE github_owner = '' OR github_repo = '';
        );
    }

    try db.exec("INSERT OR IGNORE INTO schema_version (version) VALUES (9);");

    try db.commit();
}

/// v10 — record per-keg "this keg's bin/sbin are deliberately not
/// linked into prefix" so the linker can skip them on install and
/// replay the policy on upgrades without the user re-passing a flag.
/// Default 0 keeps every pre-feature row behaving exactly like today.
fn migrateV9toV10(db: *sqlite.Database) sqlite.SqliteError!void {
    try db.beginTransaction();
    errdefer db.rollback();

    // PRAGMA table_info returns zero rows when the table is missing —
    // same partial-shape fixture defensiveness as v7→v8 / v8→v9 so a
    // forensic DB without a `kegs` table still bumps the marker rather
    // than aborting the whole chain.
    var have_table = false;
    var have_column = false;
    {
        var stmt = try db.prepare("PRAGMA table_info(kegs);");
        defer stmt.finalize();
        while (try stmt.step()) {
            have_table = true;
            const name = stmt.columnText(1) orelse continue;
            if (std.mem.eql(u8, std.mem.sliceTo(name, 0), "bin_isolated")) {
                have_column = true;
                break;
            }
        }
    }
    if (have_table and !have_column) {
        try db.exec(
            "ALTER TABLE kegs ADD COLUMN bin_isolated INTEGER NOT NULL DEFAULT 0;",
        );
    }

    try db.exec("INSERT OR IGNORE INTO schema_version (version) VALUES (10);");

    try db.commit();
}

/// v11 — record which forge hosts each tap so resolution can pick the
/// right provider per row instead of always synthesising GitHub URLs.
/// DEFAULT 'github.com' (the full host, usable directly as the `host`
/// argument to `forge.buildBaseUrls`) keeps every pre-feature row
/// resolving against GitHub byte-for-byte. Same PRAGMA-guarded shape as
/// v7→v8 / v8→v9 / v9→v10 so re-runs against partial fixtures stay
/// idempotent.
fn migrateV10toV11(db: *sqlite.Database) sqlite.SqliteError!void {
    try db.beginTransaction();
    errdefer db.rollback();

    // PRAGMA table_info returns zero rows when the table is missing —
    // same partial-shape fixture defensiveness as v7→v8 onward.
    var have_table = false;
    var have_column = false;
    {
        var stmt = try db.prepare("PRAGMA table_info(taps);");
        defer stmt.finalize();
        while (try stmt.step()) {
            have_table = true;
            const name = stmt.columnText(1) orelse continue;
            if (std.mem.eql(u8, std.mem.sliceTo(name, 0), "host")) {
                have_column = true;
                break;
            }
        }
    }
    if (have_table and !have_column) {
        try db.exec(
            "ALTER TABLE taps ADD COLUMN host TEXT NOT NULL DEFAULT 'github.com';",
        );
    }

    try db.exec("INSERT OR IGNORE INTO schema_version (version) VALUES (11);");

    try db.commit();
}

/// v12 — record an explicit forge per tap so a custom-domain instance
/// (a corporate GitLab at e.g. code.acme.com, whose host can't reveal
/// its provider) resolves correctly. Nullable on purpose: a NULL forge
/// means "classify by host", so every pre-hint row resolves byte-for-byte
/// as before. Same PRAGMA-guarded shape as the column-add migrations
/// above so re-runs against partial fixtures stay idempotent.
fn migrateV11toV12(db: *sqlite.Database) sqlite.SqliteError!void {
    try db.beginTransaction();
    errdefer db.rollback();

    var have_table = false;
    var have_column = false;
    {
        var stmt = try db.prepare("PRAGMA table_info(taps);");
        defer stmt.finalize();
        while (try stmt.step()) {
            have_table = true;
            const name = stmt.columnText(1) orelse continue;
            if (std.mem.eql(u8, std.mem.sliceTo(name, 0), "forge")) {
                have_column = true;
                break;
            }
        }
    }
    if (have_table and !have_column) {
        try db.exec("ALTER TABLE taps ADD COLUMN forge TEXT;");
    }

    try db.exec("INSERT OR IGNORE INTO schema_version (version) VALUES (12);");

    try db.commit();
}

/// v13 — record a service's schedule as a short human label so
/// `mt services list` can show *why* a service exists ("interval 300s",
/// "cron 30 4 * * 6") without re-parsing the on-disk plist. Nullable: a
/// NULL means run-at-load, so every pre-feature row reads back as
/// no-schedule. The plist stays authoritative; this column is a listing
/// cache. Same PRAGMA-guarded shape as the column-adds above so re-runs
/// against partial fixtures stay idempotent.
fn migrateV12toV13(db: *sqlite.Database) sqlite.SqliteError!void {
    try db.beginTransaction();
    errdefer db.rollback();

    var have_table = false;
    var have_column = false;
    {
        var stmt = try db.prepare("PRAGMA table_info(services);");
        defer stmt.finalize();
        while (try stmt.step()) {
            have_table = true;
            const name = stmt.columnText(1) orelse continue;
            if (std.mem.eql(u8, std.mem.sliceTo(name, 0), "schedule")) {
                have_column = true;
                break;
            }
        }
    }
    if (have_table and !have_column) {
        try db.exec("ALTER TABLE services ADD COLUMN schedule TEXT;");
    }

    try db.exec("INSERT OR IGNORE INTO schema_version (version) VALUES (13);");

    try db.commit();
}

/// True iff `pragma` reports every column in `wanted`. Generalises the
/// per-table probes above; the v14 repair spans three tables.
fn columnsPresent(db: *sqlite.Database, comptime pragma: [:0]const u8, wanted: []const []const u8) sqlite.SqliteError!bool {
    var seen: u32 = 0;
    var stmt = try db.prepare(pragma);
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

/// Rows longer than a slug can legally be are left untouched rather
/// than truncated.
const tap_slug_cap = tap_slug.max_slug_len;

/// v14 — one identity per tap. Slugs used to be stored exactly as typed,
/// so `user/homebrew-tap`, `user/tap` and `User/Tap` were three rows for
/// one tap, and the v9 backfill baked a doubled `homebrew-homebrew-<x>`
/// repo into any row registered with the prefix.
///
/// Written in Zig, not SQL, and driven by the same `tap_slug` helper the
/// runtime uses: v9's defect got baked in precisely because the backfill
/// re-implemented the rule in SQL, and sharing the helper is what stops
/// the stored form and the live form drifting apart again.
///
/// `github_repo`/`github_owner`/`url` are repaired only where the stored
/// value provably came from that backfill — an explicit `--repo`/`--url`
/// registration survives byte-for-byte.
///
/// PRAGMA-guarded like the migrations above so forensic and partial
/// fixture DBs bump the marker instead of aborting the chain.
fn migrateV13toV14(db: *sqlite.Database) sqlite.SqliteError!void {
    try db.beginTransaction();
    errdefer db.rollback();

    if (try columnsPresent(db, "PRAGMA table_info(taps);", &.{ "id", "name", "url", "github_owner", "github_repo", "commit_sha", "host" })) {
        try canonicalizeTaps(db);
    }
    if (try columnsPresent(db, "PRAGMA table_info(kegs);", &.{ "id", "tap", "full_name" })) {
        try canonicalizeKegs(db);
    }
    if (try columnsPresent(db, "PRAGMA table_info(casks);", &.{ "token", "tap" })) {
        try canonicalizeCasks(db);
    }

    try db.exec("INSERT OR IGNORE INTO schema_version (version) VALUES (14);");

    try db.commit();
}

/// Stage the canonical form of every tap row in a temp table, then let
/// SQL do the set work. Staging first keeps us from mutating `taps`
/// while stepping a cursor over it.
fn canonicalizeTaps(db: *sqlite.Database) sqlite.SqliteError!void {
    try db.exec("DROP TABLE IF EXISTS temp._tap_v14;");
    try db.exec(
        \\CREATE TEMP TABLE _tap_v14 (
        \\    id     INTEGER PRIMARY KEY,
        \\    canon  TEXT NOT NULL,
        \\    can_fetch INTEGER NOT NULL,
        \\    owner  TEXT,
        \\    repo   TEXT,
        \\    url    TEXT
        \\);
    );

    {
        var read = try db.prepare("SELECT id, name, github_owner, github_repo, url FROM taps;");
        defer read.finalize();
        var write = try db.prepare(
            "INSERT INTO temp._tap_v14 (id, canon, can_fetch, owner, repo, url) VALUES (?1, ?2, ?3, ?4, ?5, ?6);",
        );
        defer write.finalize();

        while (try read.step()) {
            const id = read.columnInt(0);
            const name = std.mem.sliceTo(read.columnText(1) orelse continue, 0);
            const owner = std.mem.sliceTo(read.columnText(2) orelse "", 0);
            const repo = std.mem.sliceTo(read.columnText(3) orelse "", 0);
            const url = std.mem.sliceTo(read.columnText(4) orelse "", 0);

            var canon_buf: [tap_slug_cap]u8 = undefined;
            const canon = tap_slug.canonicalTapSlug(&canon_buf, name) orelse continue;
            const slash = std.mem.indexOfScalar(u8, canon, '/').?;

            // The row that can actually fetch wins a collision.
            var want_buf: [tap_slug_cap]u8 = undefined;
            const want_repo = tap_slug.synthRepo(&want_buf, canon[slash + 1 ..]) orelse continue;
            const can_fetch: i64 = if (std.mem.eql(u8, repo, want_repo)) 1 else 0;

            // Damage test: the stored repo equals what the v9 backfill
            // would have produced from this row's own spelling. Anything
            // else is an explicit registration and stays as it is.
            // Folding only downcases and strips a prefix, so `canon`'s slash
            // sits at the same index as `name`'s.
            var damaged_buf: [tap_slug_cap]u8 = undefined;
            const backfilled = tap_slug.synthRepo(&damaged_buf, name[slash + 1 ..]);
            const damaged = backfilled != null and std.mem.eql(u8, repo, backfilled.?);

            try write.reset();
            try write.bindInt(1, id);
            try write.bindText(2, canon);
            try write.bindInt(3, can_fetch);
            if (damaged) {
                try write.bindText(4, canon[0..slash]);
                try write.bindText(5, want_repo);
                // Rewrite only the trailing `/<owner>/<repo>`: no URL
                // shape is assumed beyond the repo being the last segment.
                var tail_buf: [tap_slug_cap * 2]u8 = undefined;
                const tail = std.fmt.bufPrint(&tail_buf, "/{s}/{s}", .{ owner, repo }) catch "";
                var new_buf: [1024]u8 = undefined;
                if (tail.len != 0 and std.mem.endsWith(u8, url, tail)) {
                    const fixed = std.fmt.bufPrint(&new_buf, "{s}/{s}/{s}", .{
                        url[0 .. url.len - tail.len], canon[0..slash], want_repo,
                    }) catch "";
                    if (fixed.len != 0) try write.bindText(6, fixed) else try write.bindNull(6);
                } else {
                    try write.bindNull(6);
                }
            } else {
                try write.bindNull(4);
                try write.bindNull(5);
                try write.bindNull(6);
            }
            _ = try write.step();
        }
    }

    // Rows that fold together but live on different forges are two real
    // taps, not one spelled twice — `homebrew-` is a GitHub convention and
    // says nothing about a repo of that name elsewhere. Folding would make
    // one of them unrepresentable under UNIQUE(name), so leave the whole
    // group exactly as registered rather than delete a tap the user still
    // uses.
    try db.exec(
        \\DELETE FROM temp._tap_v14 WHERE canon IN (
        \\  SELECT k.canon FROM temp._tap_v14 k JOIN taps t ON t.id = k.id
        \\  GROUP BY k.canon HAVING COUNT(DISTINCT t.host) > 1
        \\);
    );

    // `name` is UNIQUE, so canonicalizing can collide. Keep the row that
    // can fetch, else the one carrying a real pin, else the oldest.
    try db.exec(
        \\DELETE FROM taps WHERE id IN (
        \\  SELECT c.id FROM temp._tap_v14 c
        \\  WHERE c.id <> (
        \\    SELECT k.id FROM temp._tap_v14 k JOIN taps t ON t.id = k.id
        \\    WHERE k.canon = c.canon
        \\    ORDER BY k.can_fetch DESC, (t.commit_sha IS NOT NULL) DESC, k.id ASC
        \\    LIMIT 1)
        \\);
    );
    try db.exec("DELETE FROM temp._tap_v14 WHERE id NOT IN (SELECT id FROM taps);");

    try db.exec(
        \\UPDATE taps SET
        \\  name         = (SELECT c.canon FROM temp._tap_v14 c WHERE c.id = taps.id),
        \\  github_owner = COALESCE((SELECT c.owner FROM temp._tap_v14 c WHERE c.id = taps.id), github_owner),
        \\  github_repo  = COALESCE((SELECT c.repo  FROM temp._tap_v14 c WHERE c.id = taps.id), github_repo),
        \\  url          = COALESCE((SELECT c.url   FROM temp._tap_v14 c WHERE c.id = taps.id), url)
        \\WHERE id IN (SELECT id FROM temp._tap_v14);
    );
    try db.exec("DROP TABLE temp._tap_v14;");
}

/// `kegs.tap` plus the tap half of `kegs.full_name` (`<tap>/<name>`),
/// which `mt info` and uninstall-by-full-name match on. Canonical slugs
/// are never longer than what they replace, so the width budget the
/// migrate path works to can only shrink.
fn canonicalizeKegs(db: *sqlite.Database) sqlite.SqliteError!void {
    try db.exec("DROP TABLE IF EXISTS temp._keg_v14;");
    try db.exec("CREATE TEMP TABLE _keg_v14 (id INTEGER PRIMARY KEY, tap TEXT NOT NULL, full_name TEXT);");
    {
        var read = try db.prepare("SELECT id, tap, full_name FROM kegs WHERE tap IS NOT NULL AND tap <> '';");
        defer read.finalize();
        var stage = try db.prepare("INSERT INTO temp._keg_v14 (id, tap, full_name) VALUES (?1, ?2, ?3);");
        defer stage.finalize();
        while (try read.step()) {
            const id = read.columnInt(0);
            const tap = std.mem.sliceTo(read.columnText(1) orelse continue, 0);
            var canon_buf: [tap_slug_cap]u8 = undefined;
            const canon = tap_slug.canonicalTapSlug(&canon_buf, tap) orelse continue;

            try stage.reset();
            try stage.bindInt(1, id);
            try stage.bindText(2, canon);
            // NULL full_name means "leave it"; the UPDATE coalesces.
            const full = if (read.columnText(2)) |f| std.mem.sliceTo(f, 0) else "";
            var full_buf: [1024]u8 = undefined;
            const rewritable = full.len > tap.len and
                std.mem.startsWith(u8, full, tap) and full[tap.len] == '/';
            const fixed = if (rewritable)
                std.fmt.bufPrint(&full_buf, "{s}{s}", .{ canon, full[tap.len..] }) catch ""
            else
                "";
            if (fixed.len != 0) try stage.bindText(3, fixed) else try stage.bindNull(3);
            _ = try stage.step();
        }
    }
    try db.exec(
        \\UPDATE kegs SET
        \\  tap       = (SELECT k.tap FROM temp._keg_v14 k WHERE k.id = kegs.id),
        \\  full_name = COALESCE((SELECT k.full_name FROM temp._keg_v14 k WHERE k.id = kegs.id), full_name)
        \\WHERE id IN (SELECT id FROM temp._keg_v14);
    );
    try db.exec("DROP TABLE temp._keg_v14;");
}

/// `casks.tap` has no UNIQUE constraint, so every non-empty value folds
/// with no collision handling.
fn canonicalizeCasks(db: *sqlite.Database) sqlite.SqliteError!void {
    try db.exec("DROP TABLE IF EXISTS temp._cask_v14;");
    try db.exec("CREATE TEMP TABLE _cask_v14 (token TEXT PRIMARY KEY, tap TEXT NOT NULL);");
    {
        var read = try db.prepare("SELECT token, tap FROM casks WHERE tap IS NOT NULL AND tap <> '';");
        defer read.finalize();
        var stage = try db.prepare("INSERT OR REPLACE INTO temp._cask_v14 (token, tap) VALUES (?1, ?2);");
        defer stage.finalize();
        while (try read.step()) {
            const token = std.mem.sliceTo(read.columnText(0) orelse continue, 0);
            const tap = std.mem.sliceTo(read.columnText(1) orelse continue, 0);
            var canon_buf: [tap_slug_cap]u8 = undefined;
            const canon = tap_slug.canonicalTapSlug(&canon_buf, tap) orelse continue;
            try stage.reset();
            try stage.bindText(1, token);
            try stage.bindText(2, canon);
            _ = try stage.step();
        }
    }
    try db.exec(
        \\UPDATE casks SET tap = (SELECT c.tap FROM temp._cask_v14 c WHERE c.token = casks.token)
        \\WHERE token IN (SELECT token FROM temp._cask_v14);
    );
    try db.exec("DROP TABLE temp._cask_v14;");
}

/// Return true iff every column in `wanted` is present on the `casks`
/// table. Mirrors the PRAGMA-guarded probes used by v2→v3 / v3→v4 /
/// v5→v6; centralised here because the v6→v7 backfill needs five
/// columns, not one.
fn caskColumnsPresent(db: *sqlite.Database, wanted: []const []const u8) sqlite.SqliteError!bool {
    return columnsPresent(db, "PRAGMA table_info(casks);", wanted);
}

/// Query the current schema version.
pub fn currentVersion(db: *sqlite.Database) sqlite.SqliteError!i64 {
    var stmt = try db.prepare("SELECT MAX(version) FROM schema_version;");
    defer stmt.finalize();

    const has_row = try stmt.step();
    if (!has_row) return 0;

    return stmt.columnInt(0);
}

fn foreignKeysOn(db: *sqlite.Database) !bool {
    var stmt = try db.prepare("PRAGMA foreign_keys;");
    defer stmt.finalize();
    _ = try stmt.step();
    return stmt.columnInt(0) == 1;
}

test "ensureForeignKeysOn turns FKs on against a fresh connection" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();

    try db.exec("PRAGMA foreign_keys=OFF;");
    try testing.expect(!try foreignKeysOn(&db));

    try ensureForeignKeysOn(&db);
    try testing.expect(try foreignKeysOn(&db));
}

test "ensureForeignKeysOn is idempotent when FKs are already on" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();

    try db.exec("PRAGMA foreign_keys=ON;");
    try ensureForeignKeysOn(&db);
    try ensureForeignKeysOn(&db);
    try testing.expect(try foreignKeysOn(&db));
}

/// True iff `name` is a registered index. The v5 rebuild drops `kegs`,
/// taking its indexes with it, so a missing one is a real regression.
fn indexExists(db: *sqlite.Database, name: []const u8) !bool {
    var stmt = try db.prepare("SELECT 1 FROM sqlite_master WHERE type='index' AND name=?;");
    defer stmt.finalize();
    try stmt.bindText(1, name);
    return try stmt.step();
}

/// The statement owns the text, so it has to be copied out before
/// finalize.
fn kegsCreateSql(db: *sqlite.Database, buf: []u8) ![]const u8 {
    var stmt = try db.prepare(
        \\SELECT sql FROM sqlite_master
        \\WHERE type='table' AND name='kegs';
    );
    defer stmt.finalize();
    if (!try stmt.step()) return error.NoKegsTable;
    const sql = std.mem.sliceTo(stmt.columnText(0) orelse return error.NoKegsTable, 0);
    if (sql.len > buf.len) return error.NoSpaceLeft;
    @memcpy(buf[0..sql.len], sql);
    return buf[0..sql.len];
}

// If the fresh CREATE ever drifts off the v5 UNIQUE again, the v4→v5
// probe misses and fresh DBs silently resume rebuilding an empty table
// with FKs off. These two pin the short-circuit from both sides.

test "fresh DB ships kegs at the v5 UNIQUE without a rebuild (v5 shape)" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    var buf: [1024]u8 = undefined;
    const sql = try kegsCreateSql(&db, &buf);

    // Unquoted name: the rebuild's RENAME tail would have quoted it.
    try testing.expect(std.mem.indexOf(u8, sql, "CREATE TABLE kegs") != null);
    const unique = std.mem.indexOf(u8, sql, "UNIQUE(name, version, revision)") orelse
        return error.TestExpectedV5Unique;
    // Inline, i.e. created — not appended by the v9→v10 ALTER.
    const isolated = std.mem.indexOf(u8, sql, "bin_isolated") orelse
        return error.TestExpectedBinIsolated;
    try testing.expect(isolated < unique);

    // The rebuild used to drop and re-create these; nothing does now.
    try testing.expect(try indexExists(&db, "idx_kegs_name"));
    try testing.expect(try indexExists(&db, "idx_kegs_store"));

    // The short-circuit still has to bump the marker and let the rest of
    // the ladder run.
    try testing.expectEqual(known_schema_version, try currentVersion(&db));
}

fn seedV13Taps(db: *sqlite.Database) sqlite.SqliteError!void {
    try db.exec("DELETE FROM schema_version WHERE version >= 14;");
}

fn tapField(db: *sqlite.Database, comptime sql: [:0]const u8, key: []const u8, buf: []u8) sqlite.SqliteError!?[]const u8 {
    var stmt = try db.prepare(sql);
    defer stmt.finalize();
    try stmt.bindText(1, key);
    if (!(try stmt.step())) return null;
    const v = stmt.columnText(0) orelse return null;
    const t = std.mem.sliceTo(v, 0);
    @memcpy(buf[0..t.len], t);
    return buf[0..t.len];
}

test "v13→v14 canonicalizes a prefixed tap row and repairs its synthesised repo" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    try db.exec(
        \\INSERT INTO taps (name, url, github_owner, github_repo)
        \\VALUES ('Indaco/Homebrew-Tap', 'https://github.com/Indaco/homebrew-Homebrew-Tap',
        \\        'Indaco', 'homebrew-Homebrew-Tap');
    );
    try seedV13Taps(&db);
    try migrate(&db);

    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("homebrew-tap", (try tapField(&db, "SELECT github_repo FROM taps WHERE name = ?1;", "indaco/tap", &buf)).?);
    var buf2: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "https://github.com/indaco/homebrew-tap",
        (try tapField(&db, "SELECT url FROM taps WHERE name = ?1;", "indaco/tap", &buf2)).?,
    );
    try testing.expectEqual(known_schema_version, try currentVersion(&db));
}

test "v13→v14 leaves an explicitly registered repo and url byte-for-byte" {
    // An explicit `--repo`/`--url` pair is intent, not v9 damage: only a
    // value equal to the synthesised one may be rewritten.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    try db.exec(
        \\INSERT INTO taps (name, url, github_owner, github_repo)
        \\VALUES ('Grp/Homebrew-Tap', 'https://gitlab.com/grp/exact-name', 'grp', 'exact-name');
    );
    try seedV13Taps(&db);
    try migrate(&db);

    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("exact-name", (try tapField(&db, "SELECT github_repo FROM taps WHERE name = ?1;", "grp/tap", &buf)).?);
    var buf2: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "https://gitlab.com/grp/exact-name",
        (try tapField(&db, "SELECT url FROM taps WHERE name = ?1;", "grp/tap", &buf2)).?,
    );
}

test "v13→v14 collapses colliding spellings onto the row that can actually fetch" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    // The prefixed row carries the doubled repo (never fetched); the bare
    // row is the one whose repo resolves, so it must be the survivor.
    try db.exec(
        \\INSERT INTO taps (name, url, commit_sha, github_owner, github_repo) VALUES
        \\  ('u/homebrew-tap', 'https://github.com/u/homebrew-homebrew-tap', 'a', 'u', 'homebrew-homebrew-tap'),
        \\  ('u/tap',          'https://github.com/u/homebrew-tap',          NULL, 'u', 'homebrew-tap');
    );
    try seedV13Taps(&db);
    try migrate(&db);

    var count = try db.prepare("SELECT COUNT(*) FROM taps;");
    defer count.finalize();
    try testing.expect(try count.step());
    try testing.expectEqual(@as(i64, 1), count.columnInt(0));

    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("homebrew-tap", (try tapField(&db, "SELECT github_repo FROM taps WHERE name = ?1;", "u/tap", &buf)).?);
}

test "v13→v14 keeps the pinned row when neither collision side has a fetchable repo" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    try db.exec(
        \\INSERT INTO taps (name, url, commit_sha, github_owner, github_repo) VALUES
        \\  ('u/homebrew-tap', 'https://x/a', NULL, 'u', 'zzz'),
        \\  ('u/Tap',          'https://x/b', 'deadbeef', 'u', 'yyy');
    );
    try seedV13Taps(&db);
    try migrate(&db);

    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("deadbeef", (try tapField(&db, "SELECT commit_sha FROM taps WHERE name = ?1;", "u/tap", &buf)).?);
}

test "v13→v14 keeps two same-named taps that live on different forges" {
    // `homebrew-` is a GitHub convention; a repo of that name on another
    // forge is a different tap. Folding these together would delete a
    // registration the user still uses.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    try db.exec(
        \\INSERT INTO taps (name, url, commit_sha, github_owner, github_repo, host) VALUES
        \\  ('Acme/Homebrew-Tap', 'https://github.com/Acme/homebrew-Homebrew-Tap', NULL,
        \\   'Acme', 'homebrew-Homebrew-Tap', 'github.com'),
        \\  ('acme/tap', 'https://gitlab.example.com/acme/tap', 'deadbeef', 'acme', 'tap',
        \\   'gitlab.example.com');
    );
    try seedV13Taps(&db);
    try migrate(&db);

    var count = try db.prepare("SELECT COUNT(*) FROM taps;");
    defer count.finalize();
    try testing.expect(try count.step());
    try testing.expectEqual(@as(i64, 2), count.columnInt(0));

    // Both keep the name they were registered under.
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "gitlab.example.com",
        (try tapField(&db, "SELECT host FROM taps WHERE name = ?1;", "acme/tap", &buf)).?,
    );
    var buf2: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "github.com",
        (try tapField(&db, "SELECT host FROM taps WHERE name = ?1;", "Acme/Homebrew-Tap", &buf2)).?,
    );
}

test "v13→v14 carries the surviving row's untouched columns through a collision" {
    // The repair rewrites name/owner/repo/url; everything else on the
    // winning row must come through byte-for-byte.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    try db.exec(
        \\INSERT INTO taps (name, url, commit_sha, head_etag, github_owner, github_repo, host, forge, added_at) VALUES
        \\  ('u/homebrew-tap', 'https://x/a', NULL, NULL, 'u', 'homebrew-homebrew-tap', 'github.com', NULL, '2020-01-01 00:00:00'),
        \\  ('U/Tap', 'https://github.com/u/homebrew-tap', 'sha', 'etag-keep', 'u', 'homebrew-tap', 'github.com', 'github', '2021-02-03 04:05:06');
    );
    try seedV13Taps(&db);
    try migrate(&db);

    var stmt = try db.prepare("SELECT commit_sha, head_etag, host, forge, added_at FROM taps WHERE name='u/tap';");
    defer stmt.finalize();
    try testing.expect(try stmt.step());
    try testing.expectEqualStrings("sha", std.mem.sliceTo(stmt.columnText(0).?, 0));
    try testing.expectEqualStrings("etag-keep", std.mem.sliceTo(stmt.columnText(1).?, 0));
    try testing.expectEqualStrings("github.com", std.mem.sliceTo(stmt.columnText(2).?, 0));
    try testing.expectEqualStrings("github", std.mem.sliceTo(stmt.columnText(3).?, 0));
    try testing.expectEqualStrings("2021-02-03 04:05:06", std.mem.sliceTo(stmt.columnText(4).?, 0));
    try testing.expect(!try stmt.step());
}

test "v13→v14 resolves a three-way collision down to a single row" {
    // Two rows deleted in one statement whose subquery reads the same
    // table it deletes from — the arity the two-row case cannot expose.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    try db.exec(
        \\INSERT INTO taps (name, url, commit_sha, github_owner, github_repo) VALUES
        \\  ('U/Homebrew-Tap',   'https://x/a', NULL, 'U', 'homebrew-Homebrew-Tap'),
        \\  ('u/linuxbrew-tap',  'https://x/b', NULL, 'u', 'homebrew-linuxbrew-tap'),
        \\  ('u/tap',            'https://x/c', 'sha', 'u', 'homebrew-tap');
    );
    try seedV13Taps(&db);
    try migrate(&db);

    var count = try db.prepare("SELECT COUNT(*) FROM taps;");
    defer count.finalize();
    try testing.expect(try count.step());
    try testing.expectEqual(@as(i64, 1), count.columnInt(0));

    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("sha", (try tapField(&db, "SELECT commit_sha FROM taps WHERE name = ?1;", "u/tap", &buf)).?);
}

test "v13→v14 is idempotent when re-run over already-canonical rows" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    try db.exec(
        \\INSERT INTO taps (name, url, github_owner, github_repo)
        \\VALUES ('Indaco/Homebrew-Tap', 'https://github.com/Indaco/homebrew-Homebrew-Tap',
        \\        'Indaco', 'homebrew-Homebrew-Tap');
    );
    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, tap)
        \\VALUES ('a', 'Indaco/Homebrew-Tap/a', '1.0', 'sha-a', '/c/a/1.0', 'Indaco/Homebrew-Tap');
    );
    try seedV13Taps(&db);
    try migrate(&db);
    try seedV13Taps(&db);
    try migrate(&db);

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "https://github.com/indaco/homebrew-tap",
        (try tapField(&db, "SELECT url FROM taps WHERE name = ?1;", "indaco/tap", &buf)).?,
    );
    var buf2: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "indaco/tap/a",
        (try tapField(&db, "SELECT full_name FROM kegs WHERE name = ?1;", "a", &buf2)).?,
    );
}

test "v13→v14 leaves a full_name that does not carry its tap prefix alone" {
    // Pre-full_name rows store the bare leaf; rewriting blindly would
    // corrupt what `mt info` and uninstall-by-full-name match on.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, tap)
        \\VALUES ('a', 'a', '1.0', 'sha-a', '/c/a/1.0', 'U/Homebrew-Tap');
    );
    try seedV13Taps(&db);
    try migrate(&db);

    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("a", (try tapField(&db, "SELECT full_name FROM kegs WHERE name = ?1;", "a", &buf)).?);
    var buf2: [128]u8 = undefined;
    try testing.expectEqualStrings("u/tap", (try tapField(&db, "SELECT tap FROM kegs WHERE name = ?1;", "a", &buf2)).?);
}

test "v13→v14 bumps the marker past a degenerate slug it cannot canonicalize" {
    // Forensic fixtures must not abort the migration chain.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    try db.exec(
        \\INSERT INTO taps (name, url, github_owner, github_repo)
        \\VALUES ('noslash', 'https://x/a', 'noslash', 'noslash');
    );
    try seedV13Taps(&db);
    try migrate(&db);

    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("noslash", (try tapField(&db, "SELECT name FROM taps WHERE name = ?1;", "noslash", &buf)).?);
    try testing.expectEqual(known_schema_version, try currentVersion(&db));
}

test "v13→v14 bumps the marker even when every table is empty" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);
    try seedV13Taps(&db);
    try migrate(&db);
    try testing.expectEqual(known_schema_version, try currentVersion(&db));
}

test "v13→v14 canonicalizes kegs.tap, casks.tap and the tap half of full_name" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, tap)
        \\VALUES ('myx', 'HaseebKhalid1507/homebrew-tap/myx', '0.4.0', 'sha-myx', '/c/myx/0.4.0',
        \\        'HaseebKhalid1507/homebrew-tap');
    );
    try db.exec(
        \\INSERT INTO casks (token, name, version, url, tap)
        \\VALUES ('font-x', 'Font X', '1.0', 'https://x/f.zip', 'U/Homebrew-Fonts');
    );
    try seedV13Taps(&db);
    try migrate(&db);

    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "haseebkhalid1507/tap",
        (try tapField(&db, "SELECT tap FROM kegs WHERE name = ?1;", "myx", &buf)).?,
    );
    var buf2: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "haseebkhalid1507/tap/myx",
        (try tapField(&db, "SELECT full_name FROM kegs WHERE name = ?1;", "myx", &buf2)).?,
    );
    var buf3: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "u/fonts",
        (try tapField(&db, "SELECT tap FROM casks WHERE token = ?1;", "font-x", &buf3)).?,
    );
}

test "v13→v14 leaves a core-tap keg and a NULL tap alone" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, tap)
        \\VALUES ('jq', 'jq', '1.7', 'sha-jq', '/c/jq/1.7', NULL);
    );
    try seedV13Taps(&db);
    try migrate(&db);

    var stmt = try db.prepare("SELECT full_name, tap FROM kegs WHERE name='jq';");
    defer stmt.finalize();
    try testing.expect(try stmt.step());
    try testing.expectEqualStrings("jq", std.mem.sliceTo(stmt.columnText(0).?, 0));
    try testing.expect(stmt.columnText(1) == null);
}

test "v4→v5 migration is idempotent when kegs already carries the v5 UNIQUE" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path)
        \\VALUES ('foo', 'foo', '1.0', 'sha-foo', '/c/foo/1.0');
    );
    // Rewind past v5 twice: the probe must keep choosing the marker-only
    // branch rather than rebuilding a table that is already correct.
    try db.exec("DELETE FROM schema_version WHERE version >= 5;");
    try migrate(&db);
    try db.exec("DELETE FROM schema_version WHERE version >= 5;");
    try migrate(&db);

    var buf: [1024]u8 = undefined;
    const sql = try kegsCreateSql(&db, &buf);
    try testing.expect(std.mem.indexOf(u8, sql, "CREATE TABLE \"kegs\"") == null);

    try testing.expectEqual(known_schema_version, try currentVersion(&db));

    var probe = try db.prepare("SELECT COUNT(*) FROM kegs WHERE name='foo';");
    defer probe.finalize();
    try testing.expect(try probe.step());
    try testing.expectEqual(@as(i64, 1), probe.columnInt(0));
}

// Without the success-path hard re-enable, a SQLITE_BUSY storm during
// the v5 commit window would leave the connection FK-off for the rest
// of its lifetime — every later ON DELETE CASCADE would silently
// no-op. This nails down the happy-path post-condition.
test "migrate leaves PRAGMA foreign_keys ON after a successful v5 rebuild" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();

    // Pre-v5 shape: the two-column UNIQUE is what makes the v5 probe
    // miss and the rebuild run. Do not "modernise" it — the witness
    // assertions below fail loudly if it drifts.
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
    // v5→v6 is the one step with no missing-table guard; without `casks`
    // the ladder aborts before it can prove anything about the rebuild.
    try db.exec(
        \\CREATE TABLE casks (
        \\    id            INTEGER PRIMARY KEY,
        \\    token         TEXT NOT NULL UNIQUE,
        \\    name          TEXT NOT NULL,
        \\    version       TEXT NOT NULL,
        \\    url           TEXT NOT NULL,
        \\    sha256        TEXT
        \\);
    );

    // Real rows, so the copy step and foreign_key_check tail run against
    // data instead of an empty table.
    try db.exec(
        \\INSERT INTO kegs (id, name, full_name, version, revision, store_sha256, cellar_path)
        \\VALUES (7, 'libgit2', 'libgit2', '1.9.2', 0, 'sha-old', '/c/libgit2/1.9.2');
    );
    try db.exec("INSERT INTO dependencies(keg_id, dep_name) VALUES (7, 'pcre2');");
    try db.exec("INSERT INTO schema_version (version) VALUES (4);");

    try migrate(&db);

    try testing.expect(try foreignKeysOn(&db));

    // Rebuild witness: the migration's `ALTER TABLE ... RENAME` tail
    // leaves the table name quoted; a direct CREATE does not.
    var buf: [1024]u8 = undefined;
    const sql = try kegsCreateSql(&db, &buf);
    try testing.expect(std.mem.indexOf(u8, sql, "CREATE TABLE \"kegs\"") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "UNIQUE(name, version, revision)") != null);

    // The seeded row and its FK child survived the copy.
    var stmt = try db.prepare(
        \\SELECT COUNT(*) FROM dependencies d JOIN kegs k ON k.id = d.keg_id
        \\WHERE k.name = 'libgit2' AND d.dep_name = 'pcre2';
    );
    defer stmt.finalize();
    try testing.expect(try stmt.step());
    try testing.expectEqual(@as(i64, 1), stmt.columnInt(0));
}

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

    try testing.expectEqual(known_schema_version, try currentVersion(&db));
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
    try testing.expectEqual(known_schema_version, try currentVersion(&db));
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
    try testing.expectEqual(known_schema_version, try currentVersion(&db));
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

// v8→v9 promotes the prefix decision into structured (github_owner,
// github_repo) columns so the helper has no string synthesis left to
// forget. Fresh DBs ship with the v9 shape; upgraded DBs get
// `(user, "homebrew-" || repo)` backfilled from the existing slug.

test "fresh DB ships with taps.github_owner and taps.github_repo (v9 shape)" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    var stmt = try db.prepare("PRAGMA table_info(taps);");
    defer stmt.finalize();
    var owner_seen = false;
    var repo_seen = false;
    while (try stmt.step()) {
        const name = stmt.columnText(1) orelse continue;
        const n = std.mem.sliceTo(name, 0);
        if (std.mem.eql(u8, n, "github_owner")) owner_seen = true;
        if (std.mem.eql(u8, n, "github_repo")) repo_seen = true;
    }
    try testing.expect(owner_seen);
    try testing.expect(repo_seen);
    try testing.expectEqual(known_schema_version, try currentVersion(&db));
}

test "v8→v9 migration backfills (user, \"homebrew-\" || repo) from existing slugs" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    // Seed three v8-shape tap rows, then rewind the schema marker so the
    // next migrate run re-enters the v8→v9 step.
    try db.exec(
        \\INSERT INTO taps (name, url, commit_sha) VALUES
        \\    ('aeroxy/tap',   'https://github.com/aeroxy/homebrew-tap',   '0123456789abcdef0123456789abcdef01234567'),
        \\    ('user/repo',    'https://github.com/user/homebrew-repo',    NULL),
        \\    ('user-1/some.v2','https://github.com/user-1/homebrew-some.v2', NULL);
    );
    try db.exec("DELETE FROM schema_version WHERE version >= 9;");

    try migrate(&db);

    try testing.expectEqual(known_schema_version, try currentVersion(&db));

    var probe = try db.prepare(
        "SELECT name, github_owner, github_repo FROM taps ORDER BY name;",
    );
    defer probe.finalize();

    try testing.expect(try probe.step());
    const n0 = std.mem.sliceTo(probe.columnText(0) orelse return error.TestUnexpectedResult, 0);
    try testing.expectEqualStrings("aeroxy/tap", n0);
    try testing.expectEqualStrings("aeroxy", std.mem.sliceTo(probe.columnText(1) orelse "", 0));
    try testing.expectEqualStrings("homebrew-tap", std.mem.sliceTo(probe.columnText(2) orelse "", 0));

    try testing.expect(try probe.step());
    const n1 = std.mem.sliceTo(probe.columnText(0) orelse return error.TestUnexpectedResult, 0);
    try testing.expectEqualStrings("user-1/some.v2", n1);
    try testing.expectEqualStrings("user-1", std.mem.sliceTo(probe.columnText(1) orelse "", 0));
    try testing.expectEqualStrings("homebrew-some.v2", std.mem.sliceTo(probe.columnText(2) orelse "", 0));

    try testing.expect(try probe.step());
    const n2 = std.mem.sliceTo(probe.columnText(0) orelse return error.TestUnexpectedResult, 0);
    try testing.expectEqualStrings("user/repo", n2);
    try testing.expectEqualStrings("user", std.mem.sliceTo(probe.columnText(1) orelse "", 0));
    try testing.expectEqualStrings("homebrew-repo", std.mem.sliceTo(probe.columnText(2) orelse "", 0));
}

test "v8→v9 migration is idempotent when columns are already populated" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    // Stamp a custom (owner, repo) pair, rewind, re-run the migration.
    // The PRAGMA guard must skip the ALTER and the backfill must not
    // overwrite a non-default pair.
    try db.exec(
        \\INSERT INTO taps (name, url, commit_sha, github_owner, github_repo) VALUES
        \\    ('aeroxy/ast-outline', 'https://github.com/aeroxy/ast-outline', NULL, 'aeroxy', 'ast-outline');
    );
    try db.exec("DELETE FROM schema_version WHERE version >= 9;");

    try migrate(&db);

    var probe = try db.prepare(
        "SELECT github_owner, github_repo FROM taps WHERE name='aeroxy/ast-outline';",
    );
    defer probe.finalize();
    try testing.expect(try probe.step());
    try testing.expectEqualStrings("aeroxy", std.mem.sliceTo(probe.columnText(0) orelse "", 0));
    try testing.expectEqualStrings("ast-outline", std.mem.sliceTo(probe.columnText(1) orelse "", 0));
}

// Empty `taps` table is the most common pre-v9 shape — the ALTER must
// add the columns, the backfill UPDATE must safely no-op, and the
// version marker still bumps so a re-run skips this path.
test "v8→v9 migration bumps the marker even when taps is empty" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    try db.exec("DELETE FROM schema_version WHERE version >= 9;");
    try migrate(&db);

    try testing.expectEqual(known_schema_version, try currentVersion(&db));
}

// Pre-v3 rows could in theory have escaped slug validation. The CASE
// branches keep `substr(name, 1, -1)` from corrupting the row — a
// malformed slug falls back to writing the verbatim name into both
// columns so the row stays reachable rather than ending up with a
// negative-length substring.
test "v8→v9 migration tolerates a slug starting with a slash (degenerate fixture)" {
    // `instr('/repo', '/') = 1` makes `substr(name, 1, 0) = ''` — the
    // owner would land empty. The backfill WHERE filters by '' so this
    // is benign on first pass, but a re-run could loop. The current
    // schema rejects empty components on read (`getOwnerRepo` returns
    // null) so this row's URLs fall through to the slug fallback.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    try db.exec(
        \\INSERT INTO taps (name, url, commit_sha) VALUES
        \\    ('/repo', 'https://example.invalid/leading-slash', NULL);
    );
    try db.exec("DELETE FROM schema_version WHERE version >= 9;");
    try migrate(&db);

    // We don't pin the specific (owner, repo) values for degenerate
    // input — only that the migration completes and the marker bumps.
    try testing.expectEqual(known_schema_version, try currentVersion(&db));
}

test "v8→v9 migration falls back to verbatim name on a slug missing the slash" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    try db.exec(
        \\INSERT INTO taps (name, url, commit_sha) VALUES
        \\    ('legacy', 'https://example.invalid/legacy', NULL);
    );
    try db.exec("DELETE FROM schema_version WHERE version >= 9;");
    try migrate(&db);

    var probe = try db.prepare(
        "SELECT github_owner, github_repo FROM taps WHERE name='legacy';",
    );
    defer probe.finalize();
    try testing.expect(try probe.step());
    try testing.expectEqualStrings("legacy", std.mem.sliceTo(probe.columnText(0) orelse "", 0));
    try testing.expectEqualStrings("legacy", std.mem.sliceTo(probe.columnText(1) orelse "", 0));
}

// v9→v10 adds kegs.bin_isolated so the install pipeline can record
// "this dep's bin/sbin are deliberately not symlinked into prefix/bin"
// per-keg. Default 0 keeps every pre-feature install behaving exactly
// like today.

test "fresh DB ships with kegs.bin_isolated (v10 shape)" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    var stmt = try db.prepare("PRAGMA table_info(kegs);");
    defer stmt.finalize();
    var found = false;
    while (try stmt.step()) {
        const name = stmt.columnText(1) orelse continue;
        if (std.mem.eql(u8, std.mem.sliceTo(name, 0), "bin_isolated")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
    try testing.expectEqual(known_schema_version, try currentVersion(&db));
}

test "v9→v10 migration adds bin_isolated and defaults existing rows to 0" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    // Seed kegs on the current shape and rewind the marker so the
    // migration step runs over rows that pre-date the column.
    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, install_reason)
        \\VALUES ('foo', 'foo', '1.0', 'sha-foo', '/c/foo/1.0', 'direct'),
        \\       ('bar', 'bar', '2.0', 'sha-bar', '/c/bar/2.0', 'dependency');
    );
    try db.exec("DELETE FROM schema_version WHERE version >= 10;");

    try migrate(&db);

    try testing.expectEqual(known_schema_version, try currentVersion(&db));

    var probe = try db.prepare("SELECT name, bin_isolated FROM kegs ORDER BY name;");
    defer probe.finalize();
    try testing.expect(try probe.step());
    try testing.expectEqualStrings(
        "bar",
        std.mem.sliceTo(probe.columnText(0) orelse "", 0),
    );
    try testing.expectEqual(@as(i64, 0), probe.columnInt(1));
    try testing.expect(try probe.step());
    try testing.expectEqualStrings(
        "foo",
        std.mem.sliceTo(probe.columnText(0) orelse "", 0),
    );
    try testing.expectEqual(@as(i64, 0), probe.columnInt(1));
}

test "v9→v10 migration is idempotent and preserves bin_isolated=1" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    // Seed a keg whose bin_isolated is already true, rewind the marker,
    // and re-run migrate twice. The PRAGMA guard must skip the ALTER
    // and the row must keep its explicit value.
    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, install_reason, bin_isolated)
        \\VALUES ('foo', 'foo', '1.0', 'sha-foo', '/c/foo/1.0', 'dependency', 1);
    );
    try db.exec("DELETE FROM schema_version WHERE version >= 10;");
    try migrate(&db);
    try db.exec("DELETE FROM schema_version WHERE version >= 10;");
    try migrate(&db);

    var probe = try db.prepare("SELECT bin_isolated FROM kegs WHERE name='foo';");
    defer probe.finalize();
    try testing.expect(try probe.step());
    try testing.expectEqual(@as(i64, 1), probe.columnInt(0));
}

// v10→v11 adds taps.host so a tap row remembers which forge hosts it
// (github.com today; GitLab/Codeberg arrive as forge arms later). The
// DEFAULT keeps every pre-feature row resolving against GitHub exactly
// as before. Fresh and upgraded DBs must converge on the same shape.

test "fresh DB ships with taps.host defaulting to github.com (v11 shape)" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    var stmt = try db.prepare("PRAGMA table_info(taps);");
    defer stmt.finalize();
    var found = false;
    while (try stmt.step()) {
        const name = stmt.columnText(1) orelse continue;
        if (std.mem.eql(u8, std.mem.sliceTo(name, 0), "host")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);

    // A row inserted without naming `host` takes the column DEFAULT —
    // this is the path `tap.add` relies on to stamp github.com.
    try db.exec(
        \\INSERT INTO taps (name, url, commit_sha, github_owner, github_repo)
        \\VALUES ('user/repo', 'https://github.com/user/homebrew-repo', NULL, 'user', 'homebrew-repo');
    );
    var probe = try db.prepare("SELECT host FROM taps WHERE name='user/repo';");
    defer probe.finalize();
    try testing.expect(try probe.step());
    try testing.expectEqualStrings("github.com", std.mem.sliceTo(probe.columnText(0) orelse "", 0));

    try testing.expectEqual(known_schema_version, try currentVersion(&db));
}

test "v10→v11 migration backfills host=github.com on existing tap rows" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    // Seed a tap on the current shape, then rewind the marker so migrate
    // re-enters the v10→v11 step against a row that pre-dates the column.
    try db.exec(
        \\INSERT INTO taps (name, url, commit_sha, github_owner, github_repo)
        \\VALUES ('aeroxy/tap', 'https://github.com/aeroxy/homebrew-tap', NULL, 'aeroxy', 'homebrew-tap');
    );
    try db.exec("DELETE FROM schema_version WHERE version >= 11;");

    try migrate(&db);

    try testing.expectEqual(known_schema_version, try currentVersion(&db));

    var probe = try db.prepare("SELECT host FROM taps WHERE name='aeroxy/tap';");
    defer probe.finalize();
    try testing.expect(try probe.step());
    try testing.expectEqualStrings("github.com", std.mem.sliceTo(probe.columnText(0) orelse "", 0));
}

// A row already carrying a non-default host must survive a re-run — the
// PRAGMA guard skips the ALTER so the explicit value is never clobbered
// back to github.com.
test "v10→v11 migration is idempotent and preserves a non-default host" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    try db.exec(
        \\INSERT INTO taps (name, url, commit_sha, github_owner, github_repo, host)
        \\VALUES ('grp/tap', 'https://gitlab.com/grp/tap', NULL, 'grp', 'tap', 'gitlab.com');
    );
    try db.exec("DELETE FROM schema_version WHERE version >= 11;");
    try migrate(&db);
    try db.exec("DELETE FROM schema_version WHERE version >= 11;");
    try migrate(&db);

    var probe = try db.prepare("SELECT host FROM taps WHERE name='grp/tap';");
    defer probe.finalize();
    try testing.expect(try probe.step());
    try testing.expectEqualStrings("gitlab.com", std.mem.sliceTo(probe.columnText(0) orelse "", 0));
}

// The empty-taps case is the most common upgrade shape: the ALTER must
// add the column and the marker must still bump so a re-run skips it.
test "v10→v11 migration bumps the marker even when taps is empty" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    try db.exec("DELETE FROM schema_version WHERE version >= 11;");
    try migrate(&db);

    try testing.expectEqual(known_schema_version, try currentVersion(&db));
}

// v11→v12 adds taps.forge so a tap can name its provider explicitly when
// the host can't reveal it (a custom-domain GitLab like code.acme.com).
// The column is nullable: a NULL forge means "sniff the host" so every
// pre-hint row resolves exactly as before.

test "fresh DB ships with a nullable taps.forge column (v12 shape)" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    var stmt = try db.prepare("PRAGMA table_info(taps);");
    defer stmt.finalize();
    var found = false;
    while (try stmt.step()) {
        const name = stmt.columnText(1) orelse continue;
        if (std.mem.eql(u8, std.mem.sliceTo(name, 0), "forge")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);

    // A row inserted without naming `forge` leaves it NULL — the path
    // `tap.add` / `addWithHost` rely on to defer to host classification.
    try db.exec(
        \\INSERT INTO taps (name, url, commit_sha, github_owner, github_repo, host)
        \\VALUES ('user/repo', 'https://github.com/user/homebrew-repo', NULL, 'user', 'homebrew-repo', 'github.com');
    );
    var probe = try db.prepare("SELECT forge FROM taps WHERE name='user/repo';");
    defer probe.finalize();
    try testing.expect(try probe.step());
    try testing.expect(probe.columnText(0) == null);

    try testing.expectEqual(known_schema_version, try currentVersion(&db));
}

test "v11→v12 migration adds taps.forge as NULL on existing rows" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    try db.exec(
        \\INSERT INTO taps (name, url, commit_sha, github_owner, github_repo, host)
        \\VALUES ('aeroxy/tap', 'https://github.com/aeroxy/homebrew-tap', NULL, 'aeroxy', 'homebrew-tap', 'github.com');
    );
    try db.exec("DELETE FROM schema_version WHERE version >= 12;");

    try migrate(&db);

    try testing.expectEqual(known_schema_version, try currentVersion(&db));

    var probe = try db.prepare("SELECT forge FROM taps WHERE name='aeroxy/tap';");
    defer probe.finalize();
    try testing.expect(try probe.step());
    try testing.expect(probe.columnText(0) == null);
}

test "v11→v12 migration is idempotent and preserves an explicit forge" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    try db.exec(
        \\INSERT INTO taps (name, url, commit_sha, github_owner, github_repo, host, forge)
        \\VALUES ('acme/tap', 'https://code.acme.com/acme/tap', NULL, 'acme', 'tap', 'code.acme.com', 'gitlab');
    );
    try db.exec("DELETE FROM schema_version WHERE version >= 12;");
    try migrate(&db);
    try db.exec("DELETE FROM schema_version WHERE version >= 12;");
    try migrate(&db);

    var probe = try db.prepare("SELECT forge FROM taps WHERE name='acme/tap';");
    defer probe.finalize();
    try testing.expect(try probe.step());
    try testing.expectEqualStrings("gitlab", std.mem.sliceTo(probe.columnText(0) orelse "", 0));
}

// v12→v13 adds services.schedule, a nullable human label cache ("interval
// 300s", "cron 30 4 * * 6", or NULL for run-at-load). The plist stays the
// source of truth; this column is a listing convenience. Nullable so every
// pre-feature row reads back as no-schedule with no migration error.

test "fresh DB ships with a nullable services.schedule column (v13 shape)" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    var stmt = try db.prepare("PRAGMA table_info(services);");
    defer stmt.finalize();
    var found = false;
    while (try stmt.step()) {
        const name = stmt.columnText(1) orelse continue;
        if (std.mem.eql(u8, std.mem.sliceTo(name, 0), "schedule")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);

    // A row inserted without naming `schedule` leaves it NULL — the path a
    // pre-schedule registration relied on.
    try db.exec(
        \\INSERT INTO services (name, keg_name, plist_path)
        \\VALUES ('redis', 'redis', '/dev/null');
    );
    var probe = try db.prepare("SELECT schedule FROM services WHERE name='redis';");
    defer probe.finalize();
    try testing.expect(try probe.step());
    try testing.expect(probe.columnText(0) == null);

    try testing.expectEqual(known_schema_version, try currentVersion(&db));
}

test "v12→v13 migration adds services.schedule as NULL on existing rows" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    // Seed a service on the current shape, then rewind the marker so migrate
    // re-enters the v12→v13 step against a row that pre-dates the column.
    try db.exec(
        \\INSERT INTO services (name, keg_name, plist_path, auto_start, last_status)
        \\VALUES ('redis', 'redis', '/dev/null', 0, 'registered');
    );
    try db.exec("DELETE FROM schema_version WHERE version >= 13;");

    try migrate(&db);

    try testing.expectEqual(known_schema_version, try currentVersion(&db));

    var probe = try db.prepare("SELECT schedule FROM services WHERE name='redis';");
    defer probe.finalize();
    try testing.expect(try probe.step());
    try testing.expect(probe.columnText(0) == null);
}

test "v12→v13 migration is idempotent and preserves an explicit schedule" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try initSchema(&db);

    try db.exec(
        \\INSERT INTO services (name, keg_name, plist_path, schedule)
        \\VALUES ('redis', 'redis', '/dev/null', 'interval 300s');
    );
    try db.exec("DELETE FROM schema_version WHERE version >= 13;");
    try migrate(&db);
    try db.exec("DELETE FROM schema_version WHERE version >= 13;");
    try migrate(&db);

    var probe = try db.prepare("SELECT schedule FROM services WHERE name='redis';");
    defer probe.finalize();
    try testing.expect(try probe.step());
    try testing.expectEqualStrings(
        "interval 300s",
        std.mem.sliceTo(probe.columnText(0) orelse "", 0),
    );
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
