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
    tap: ?[]const u8 = null,
};

/// Scope filter for `loadFormulaRows`. `--pinned-only` swaps in a
/// pinned-row SQL so the audit path never round-trips the API for kegs
/// that aren't being protected from upgrade.
pub const KegFilter = enum { all, pinned_only };

/// Load installed formula rows, optionally narrowed to pinned-only.
/// Caller frees with `freeKegRows`. Exposed for tests + the audit path
/// in `cli/upgrade`; both want the same SQL choice.
pub fn loadFormulaRows(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    filter: KegFilter,
) ![]KegRow {
    const sql: [:0]const u8 = switch (filter) {
        .all => "SELECT name, version FROM kegs ORDER BY name;",
        .pinned_only => "SELECT name, version FROM kegs WHERE pinned = 1 ORDER BY name;",
    };
    return loadKegRows(allocator, db, sql);
}

/// Cask sibling of `loadFormulaRows`. Same lifetime contract; pinned
/// filter swaps in `WHERE pinned = 1` so `--pinned-only` walks the
/// pinned-cask audit path symmetrically with formulas. The `tap`
/// column comes along for the ride so `upstreamLatest` can pre-route
/// tap casks to the owning tap's `.rb` instead of the core API.
pub fn loadCaskRows(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    filter: KegFilter,
) ![]KegRow {
    const sql: [:0]const u8 = switch (filter) {
        .all => "SELECT token, version, tap FROM casks ORDER BY token;",
        .pinned_only => "SELECT token, version, tap FROM casks WHERE pinned = 1 ORDER BY token;",
    };
    return loadKegRows(allocator, db, sql);
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

/// Reads `name, version` (and optionally `tap` as column 2) into
/// caller-owned `KegRow`s. Tap is left null when the column isn't
/// part of the SELECT (formula loader) or when the row's value is
/// SQL NULL (core-API cask, or a v5-era row not yet backfilled).
fn loadKegRows(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    sql: [:0]const u8,
) ![]KegRow {
    var stmt = db.prepare(sql) catch return &.{};
    defer stmt.finalize();

    var rows: std.ArrayList(KegRow) = .empty;
    errdefer {
        for (rows.items) |r| {
            allocator.free(r.name);
            allocator.free(r.version);
            if (r.tap) |t| allocator.free(t);
        }
        rows.deinit(allocator);
    }
    while (stmt.step() catch false) {
        const name_ptr = stmt.columnText(0) orelse continue;
        const ver_ptr = stmt.columnText(1);
        const name_slice = std.mem.sliceTo(name_ptr, 0);
        const ver_slice = if (ver_ptr) |v| std.mem.sliceTo(v, 0) else "0";
        const name_dup = try allocator.dupe(u8, name_slice);
        errdefer allocator.free(name_dup);
        const ver_dup = try allocator.dupe(u8, ver_slice);
        errdefer allocator.free(ver_dup);
        // Column 2 is the `tap` field for cask loaders; formula
        // loaders don't SELECT it, so `columnText` returns null and
        // the row gets a null tap.
        var tap_dup: ?[]u8 = null;
        if (stmt.columnText(2)) |tap_ptr| {
            const tap_slice = std.mem.sliceTo(tap_ptr, 0);
            tap_dup = try allocator.dupe(u8, tap_slice);
        }
        try rows.append(allocator, .{ .name = name_dup, .version = ver_dup, .tap = tap_dup });
    }
    return rows.toOwnedSlice(allocator);
}

test "KegFilter exposes both audit scopes" {
    // Compile-time guard so adding a third variant has to acknowledge
    // the SQL switches above explicitly.
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(KegFilter).@"enum".fields.len);
    _ = KegFilter.all;
    _ = KegFilter.pinned_only;
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
