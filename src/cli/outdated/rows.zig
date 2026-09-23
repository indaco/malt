//! malt — outdated DB row loaders
//!
//! Read the installed-package list out of the malt DB into caller-owned
//! `KegRow`s. The pinned-only filter swaps in a `WHERE pinned = 1` SQL
//! so `--pinned-only` walks the pinned-row audit path symmetrically for
//! formulas and casks. Integration tests with a seeded DB live in
//! `tests/outdated_test.zig`; the inline tests here cover lifetime and
//! enum shape only.

const std = @import("std");

const sqlite = @import("../../db/sqlite.zig");

/// One row of the installed-package list fed to the worker pool.
/// `tap` is the third-party tap label for tap-installed casks (drives
/// outdated's pre-routing the same way `upgradeCask` uses
/// `lookupInstalled.tap()`); null for kegs and for casks installed
/// from the core Homebrew API. Owned by the same allocator as `name`
/// and `version`; freed by `freeKegRows`.
pub const KegRow = struct {
    name: []const u8,
    version: []const u8,
    /// Homebrew revision of the installed keg (`kegs.revision`); 0 for
    /// casks, which have no revision. Paired with `version` via
    /// `formula.pkgVersion` to compare against upstream revision bumps.
    revision: i64 = 0,
    tap: ?[]const u8 = null,
    /// True for `mt pin`-held rows. Surfaced so `mt outdated --json` can
    /// keep a pinned-but-outdated package visible with `pinned:true`.
    pinned: bool = false,
    /// Tap keg installed from `Casks/`; its `.rb` is re-read from there.
    rb_from_casks: bool = false,
};

/// Scope filter for `loadFormulaRows` / `loadCaskRows`. Variants:
/// - `all`: walk every installed row.
/// - `pinned_only`: `WHERE pinned = 1` — `--pinned-only` audits.
/// - `by_tap`: `WHERE tap = ?1` — single-tap filter for `--tap`.
///   Strict equality means NULL-tap rows (legacy v5-era casks) never
///   match; the user-facing workaround lives in the `--help` text.
pub const KegFilter = union(enum) {
    all,
    pinned_only,
    by_tap: []const u8,
};

/// Load installed formula rows, optionally narrowed by scope.
/// Caller frees with `freeKegRows`. Exposed for tests + the audit path
/// in `cli/upgrade`; both want the same SQL choice.
pub fn loadFormulaRows(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    filter: KegFilter,
) ![]KegRow {
    const sql: [:0]const u8 = switch (filter) {
        .all => "SELECT name, version, revision, tap, pinned, tap_rb_subtree = 'cask' FROM kegs ORDER BY name;",
        .pinned_only => "SELECT name, version, revision, tap, pinned, tap_rb_subtree = 'cask' FROM kegs WHERE pinned = 1 ORDER BY name;",
        // NOCASE: redundant now both sides are canonical, kept for
        // hand-edited or un-migrated DBs. See `tapExists`.
        .by_tap => "SELECT name, version, revision, tap, pinned, tap_rb_subtree = 'cask' FROM kegs WHERE tap = ?1 COLLATE NOCASE ORDER BY name;",
    };
    const bind: ?[]const u8 = switch (filter) {
        .by_tap => |label| label,
        .all, .pinned_only => null,
    };
    return loadKegRows(allocator, db, sql, bind);
}

/// Cask sibling of `loadFormulaRows`. Same lifetime contract. The
/// `tap` column comes along for the ride so `upstreamLatest` can
/// pre-route tap casks to the owning tap's `.rb` instead of the core
/// API.
pub fn loadCaskRows(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    filter: KegFilter,
) ![]KegRow {
    // Casks have no revision; `0 AS revision` keeps the column layout
    // uniform with the formula query so `loadKegRows` reads one shape.
    const sql: [:0]const u8 = switch (filter) {
        .all => "SELECT token, version, 0 AS revision, tap, pinned, 0 FROM casks ORDER BY token;",
        .pinned_only => "SELECT token, version, 0 AS revision, tap, pinned, 0 FROM casks WHERE pinned = 1 ORDER BY token;",
        // NOCASE: redundant now both sides are canonical, kept for
        // hand-edited or un-migrated DBs. See `tapExists`.
        .by_tap => "SELECT token, version, 0 AS revision, tap, pinned, 0 FROM casks WHERE tap = ?1 COLLATE NOCASE ORDER BY token;",
    };
    const bind: ?[]const u8 = switch (filter) {
        .by_tap => |label| label,
        .all, .pinned_only => null,
    };
    return loadKegRows(allocator, db, sql, bind);
}

/// True iff the given `<user/repo>` label is known anywhere the
/// `--tap` audit can act on: the local `taps` registry, or any
/// installed row's `tap` column. Used by `outdated`'s `--tap` flag
/// to fail clearly on typos without rejecting taps the user has
/// `untap`ped while keeping their installs.
pub fn tapExists(db: *sqlite.Database, label: []const u8) !bool {
    // Three sources, single round-trip: `?1` is reused across the
    // UNION ALL legs; `LIMIT 1` short-circuits after the first match.
    // `COLLATE NOCASE` predates canonicalization and is now redundant —
    // kept so hand-edited or un-migrated DBs still match. Caller
    // propagates `error.PrepareFailed` so a broken schema is diagnosed
    // distinctly from a typo.
    var stmt = try db.prepare(
        \\SELECT 1 FROM taps  WHERE name = ?1 COLLATE NOCASE
        \\UNION ALL
        \\SELECT 1 FROM kegs  WHERE tap  = ?1 COLLATE NOCASE
        \\UNION ALL
        \\SELECT 1 FROM casks WHERE tap  = ?1 COLLATE NOCASE
        \\LIMIT 1;
    );
    defer stmt.finalize();
    try stmt.bindText(1, label);
    return try stmt.step();
}

/// Caller-side free for any rows returned by `loadFormulaRows` /
/// `loadCaskRows`. Pairs with the allocator passed in.
pub fn freeKegRows(allocator: std.mem.Allocator, rows: []KegRow) void {
    for (rows) |r| {
        allocator.free(r.name);
        allocator.free(r.version);
        if (r.tap) |t| allocator.free(t);
    }
    allocator.free(rows);
}

/// Reads `name, version, tap, pinned` into caller-owned `KegRow`s.
/// Tap is left null when the row's value is SQL NULL (core-API cask,
/// or a v5-era row not yet backfilled). A prepare/step failure
/// propagates: zero rows would read as an all-clear downstream, so a
/// drifted table must never look like an empty prefix.
fn loadKegRows(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    sql: [:0]const u8,
    bind1: ?[]const u8,
) ![]KegRow {
    var stmt = try db.prepare(sql);
    defer stmt.finalize();
    if (bind1) |b| try stmt.bindText(1, b);

    var rows: std.ArrayList(KegRow) = .empty;
    errdefer {
        for (rows.items) |r| {
            allocator.free(r.name);
            allocator.free(r.version);
            if (r.tap) |t| allocator.free(t);
        }
        rows.deinit(allocator);
    }
    while (try stmt.step()) {
        const name_ptr = stmt.columnText(0) orelse continue;
        const ver_ptr = stmt.columnText(1);
        const name_slice = std.mem.sliceTo(name_ptr, 0);
        const ver_slice = if (ver_ptr) |v| std.mem.sliceTo(v, 0) else "0";
        const name_dup = try allocator.dupe(u8, name_slice);
        errdefer allocator.free(name_dup);
        const ver_dup = try allocator.dupe(u8, ver_slice);
        errdefer allocator.free(ver_dup);
        // Column layout (uniform across formula/cask): 0 name, 1 version,
        // 2 revision, 3 tap (null for core-API rows / v5-era casks),
        // 4 pinned, 5 installed from a tap's Casks/ (always 0 for casks).
        var tap_dup: ?[]u8 = null;
        if (stmt.columnText(3)) |tap_ptr| {
            const tap_slice = std.mem.sliceTo(tap_ptr, 0);
            tap_dup = try allocator.dupe(u8, tap_slice);
        }
        errdefer if (tap_dup) |t| allocator.free(t);
        try rows.append(allocator, .{
            .name = name_dup,
            .version = ver_dup,
            .revision = stmt.columnInt(2),
            .tap = tap_dup,
            .pinned = stmt.columnBool(4),
            .rb_from_casks = stmt.columnBool(5),
        });
    }
    return rows.toOwnedSlice(allocator);
}

test "KegFilter exposes every audit scope" {
    // Compile-time guard so adding another variant has to acknowledge
    // the SQL switches above explicitly.
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(KegFilter).@"union".fields.len);
    _ = KegFilter.all;
    _ = KegFilter.pinned_only;
    _ = KegFilter{ .by_tap = "user/repo" };
}

test "freeKegRows is a no-op on an empty slice" {
    const empty: []KegRow = try std.testing.allocator.alloc(KegRow, 0);
    freeKegRows(std.testing.allocator, empty);
}

test "freeKegRows releases name, version, and optional tap" {
    // One row with a tap (cask path) plus one without (formula path)
    // exercises both arms of the `if (r.tap) |t|` branch in the
    // free routine.
    var rows = try std.testing.allocator.alloc(KegRow, 2);
    rows[0] = .{
        .name = try std.testing.allocator.dupe(u8, "alpha"),
        .version = try std.testing.allocator.dupe(u8, "1.0"),
        .tap = null,
    };
    rows[1] = .{
        .name = try std.testing.allocator.dupe(u8, "beta"),
        .version = try std.testing.allocator.dupe(u8, "2.0"),
        .tap = try std.testing.allocator.dupe(u8, "foo/bar"),
    };
    freeKegRows(std.testing.allocator, rows);
}

test "loadFormulaRows flags a keg installed from its tap's Casks/" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE kegs (name TEXT, version TEXT, revision INTEGER, tap TEXT, pinned INTEGER, tap_rb_subtree TEXT);");
    try db.exec(
        \\INSERT INTO kegs (name, version, revision, tap, pinned, tap_rb_subtree) VALUES
        \\  ('fromcask', '1.0', 0, 'a/b', 0, 'cask'),
        \\  ('fromformula', '1.0', 0, 'a/b', 0, 'formula'),
        \\  ('legacy', '1.0', 0, 'a/b', 0, NULL);
    );
    const rows = try loadFormulaRows(std.testing.allocator, &db, .all);
    defer freeKegRows(std.testing.allocator, rows);
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expect(rows[0].rb_from_casks);
    try std.testing.expect(!rows[1].rb_from_casks);
    try std.testing.expect(!rows[2].rb_from_casks);
}

test "loadFormulaRows refuses to read a drifted kegs table as zero rows" {
    // A table that passed `initSchema` but lost a SELECTed column is
    // indistinguishable from an empty prefix downstream; the leaf must
    // surface the failure, not hand back an all-clear.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE kegs (name TEXT, version TEXT, revision INTEGER, tap TEXT);");
    try db.exec("INSERT INTO kegs (name, version, revision, tap) VALUES ('alpha', '1.0', 0, NULL);");
    try std.testing.expectError(error.PrepareFailed, loadFormulaRows(std.testing.allocator, &db, .all));
}

test "loadCaskRows refuses to read a drifted casks table as zero rows" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE casks (token TEXT, version TEXT, tap TEXT);");
    try db.exec("INSERT INTO casks (token, version, tap) VALUES ('alpha', '1.0', NULL);");
    try std.testing.expectError(error.PrepareFailed, loadCaskRows(std.testing.allocator, &db, .all));
}
