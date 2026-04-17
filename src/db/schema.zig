const std = @import("std");
const sqlite = @import("sqlite.zig");

/// Initialize the database schema (CREATE TABLE IF NOT EXISTS).
/// Idempotent — safe to call on an existing database.
pub fn initSchema(db: *sqlite.Database) sqlite.SqliteError!void {
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

    // 3. casks
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

/// Run any pending schema migrations.
pub fn migrate(db: *sqlite.Database) sqlite.SqliteError!void {
    const ver = try currentVersion(db);
    if (ver < 2) try migrateV1toV2(db);
    if (ver < 3) try migrateV2toV3(db);
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

/// Query the current schema version.
pub fn currentVersion(db: *sqlite.Database) sqlite.SqliteError!i64 {
    var stmt = try db.prepare("SELECT MAX(version) FROM schema_version;");
    defer stmt.finalize();

    const has_row = try stmt.step();
    if (!has_row) return 0;

    return stmt.columnInt(0);
}
