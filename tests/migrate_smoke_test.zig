//! Smoke tests for `malt migrate` — drives `migrate.execute` end-to-end
//! against a fake Homebrew Cellar (via HOMEBREW_PREFIX) and a scratch
//! MALT_PREFIX, so the whole command pipeline is exercised without
//! touching the user's real Homebrew or malt installs, and without
//! network access. Dry-run is the primary vehicle: it reaches every
//! input-validation and cellar-scan path, then returns before any
//! bottle download would happen.

const std = @import("std");
const malt = @import("malt");
const testing = std.testing;
const migrate = malt.cli_migrate;
const output = malt.output;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

// Reset the global output flags that prior tests may have flipped — migrate
// reads `output.isDryRun()` to seed its local `dry_run` and calls
// `output.setQuiet` when it sees `-q`/`--quiet`.
fn resetOutput() void {
    output.setQuiet(false);
    output.setDryRun(false);
}

fn scratchDir(suffix: []const u8) ![:0]u8 {
    const p = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "/tmp/mt_mig_{d}_{s}",
        .{ malt.fs_compat.nanoTimestamp(), suffix },
        0,
    );
    malt.fs_compat.deleteTreeAbsolute(p) catch {};
    try malt.fs_compat.cwd().makePath(p);
    return p;
}

fn setenvZ(key: [*:0]const u8, value: []const u8) !void {
    const sz = try testing.allocator.dupeZ(u8, value);
    defer testing.allocator.free(sz);
    _ = c.setenv(key, sz.ptr, 1);
}

// Seed `prefix/Cellar/<name>/1.0` for each keg name. Empty directories are
// enough — migrate's cellar iterator only looks at `entry.kind == .directory`.
fn seedFakeBrew(prefix: []const u8, kegs: []const []const u8) !void {
    const cellar = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar", .{prefix});
    defer testing.allocator.free(cellar);
    try malt.fs_compat.cwd().makePath(cellar);
    for (kegs) |name| {
        const keg_dir = try std.fmt.allocPrint(testing.allocator, "{s}/{s}/1.0", .{ cellar, name });
        defer testing.allocator.free(keg_dir);
        try malt.fs_compat.cwd().makePath(keg_dir);
    }
}

fn pathExists(path: []const u8) bool {
    malt.fs_compat.accessAbsolute(path, .{}) catch return false;
    return true;
}

// ── Flag parsing / input validation ─────────────────────────────────────

test "migrate --help short-circuits before touching the filesystem" {
    resetOutput();
    // No HOMEBREW_PREFIX set, no MALT_PREFIX set — help must not care.
    _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.unsetenv("MALT_PREFIX");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try migrate.execute(arena.allocator(), &.{"--help"});
    try migrate.execute(arena.allocator(), &.{"-h"});
}

test "bare --use-system-ruby is refused (would widen trust boundary to every keg)" {
    resetOutput();
    _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.unsetenv("MALT_PREFIX");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(
        error.Aborted,
        migrate.execute(arena.allocator(), &.{"--use-system-ruby"}),
    );
    // The rejection fires before brew detection, so --dry-run can't rescue it.
    try testing.expectError(
        error.Aborted,
        migrate.execute(arena.allocator(), &.{ "--dry-run", "--use-system-ruby" }),
    );
}

// ── detectBrewPrefix env override ───────────────────────────────────────

test "detectBrewPrefix honors HOMEBREW_PREFIX when set" {
    _ = c.setenv("HOMEBREW_PREFIX", "/tmp/brew_fake_prefix", 1);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    try testing.expectEqualStrings("/tmp/brew_fake_prefix", migrate.detectBrewPrefix());
}

test "detectBrewPrefix falls back to arch default when unset" {
    _ = c.unsetenv("HOMEBREW_PREFIX");
    const got = migrate.detectBrewPrefix();
    // Either /opt/homebrew (arm64) or /usr/local (x86) — never empty,
    // always absolute. Exact value depends on the host arch.
    try testing.expect(got.len > 0);
    try testing.expectEqual(@as(u8, '/'), got[0]);
}

test "empty HOMEBREW_PREFIX falls through to arch default" {
    _ = c.setenv("HOMEBREW_PREFIX", "", 1);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    const got = migrate.detectBrewPrefix();
    try testing.expect(got.len > 0);
    try testing.expectEqual(@as(u8, '/'), got[0]);
}

// ── Cellar discovery ────────────────────────────────────────────────────

test "missing Homebrew installation yields error.Aborted" {
    resetOutput();
    const bogus = "/tmp/mt_mig_no_such_brew_dir_12345";
    malt.fs_compat.deleteTreeAbsolute(bogus) catch {};
    _ = c.setenv("HOMEBREW_PREFIX", bogus, 1);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(
        error.Aborted,
        migrate.execute(arena.allocator(), &.{"--dry-run"}),
    );
}

test "empty Cellar exits cleanly with no malt state created" {
    resetOutput();
    const brew = try scratchDir("brew_empty");
    defer {
        malt.fs_compat.deleteTreeAbsolute(brew) catch {};
        testing.allocator.free(brew);
    }
    const mt = try scratchDir("mt_empty");
    defer {
        malt.fs_compat.deleteTreeAbsolute(mt) catch {};
        testing.allocator.free(mt);
    }
    try seedFakeBrew(brew, &.{});

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try migrate.execute(arena.allocator(), &.{});

    // Empty-Cellar branch returns before ensureDirs runs, so the malt
    // prefix must not have been seeded with store/db/Cellar subtrees.
    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{mt});
    defer testing.allocator.free(db_dir);
    try testing.expect(!pathExists(db_dir));
}

// ── Dry-run happy paths ─────────────────────────────────────────────────

test "dry-run with kegs lists them and never initializes malt state" {
    resetOutput();
    const brew = try scratchDir("brew_dry");
    defer {
        malt.fs_compat.deleteTreeAbsolute(brew) catch {};
        testing.allocator.free(brew);
    }
    const mt = try scratchDir("mt_dry");
    defer {
        malt.fs_compat.deleteTreeAbsolute(mt) catch {};
        testing.allocator.free(mt);
    }
    try seedFakeBrew(brew, &.{ "tree", "wget", "jq" });

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try migrate.execute(arena.allocator(), &.{ "--dry-run", "--quiet" });

    // Dry-run returns before ensureDirs — no DB, no lock, no Cellar
    // in the malt prefix.
    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{mt});
    defer testing.allocator.free(db_dir);
    try testing.expect(!pathExists(db_dir));
}

test "dry-run is idempotent: back-to-back runs both succeed with no state change" {
    resetOutput();
    const brew = try scratchDir("brew_idem");
    defer {
        malt.fs_compat.deleteTreeAbsolute(brew) catch {};
        testing.allocator.free(brew);
    }
    const mt = try scratchDir("mt_idem");
    defer {
        malt.fs_compat.deleteTreeAbsolute(mt) catch {};
        testing.allocator.free(mt);
    }
    try seedFakeBrew(brew, &.{ "openssl", "ca-certificates" });

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try migrate.execute(arena.allocator(), &.{ "--dry-run", "--quiet" });
    try migrate.execute(arena.allocator(), &.{ "--dry-run", "--quiet" });

    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{mt});
    defer testing.allocator.free(db_dir);
    try testing.expect(!pathExists(db_dir));
}

test "dry-run with scoped --use-system-ruby=foo,bar is accepted (scope parsed, no trust-boundary error)" {
    resetOutput();
    const brew = try scratchDir("brew_scope");
    defer {
        malt.fs_compat.deleteTreeAbsolute(brew) catch {};
        testing.allocator.free(brew);
    }
    const mt = try scratchDir("mt_scope");
    defer {
        malt.fs_compat.deleteTreeAbsolute(mt) catch {};
        testing.allocator.free(mt);
    }
    try seedFakeBrew(brew, &.{"foo"});

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Scoped form is the *only* way to opt in for migrate; empty names in the
    // list (e.g. "foo,,bar") must be tolerated, and dry-run must still win.
    try migrate.execute(arena.allocator(), &.{ "--dry-run", "--quiet", "--use-system-ruby=foo,,bar" });
}

// ── Quiet flag ──────────────────────────────────────────────────────────

test "--quiet alone (no dry-run) with empty Cellar still returns cleanly" {
    resetOutput();
    const brew = try scratchDir("brew_quiet");
    defer {
        malt.fs_compat.deleteTreeAbsolute(brew) catch {};
        testing.allocator.free(brew);
    }
    const mt = try scratchDir("mt_quiet");
    defer {
        malt.fs_compat.deleteTreeAbsolute(mt) catch {};
        testing.allocator.free(mt);
    }
    try seedFakeBrew(brew, &.{});

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try migrate.execute(arena.allocator(), &.{"-q"});
    // Reset so downstream tests don't inherit quiet=true from this one.
    resetOutput();
}

// ── Already-installed skip path ─────────────────────────────────────────
//
// This test exercises the full non-dry-run pipeline up to the per-keg
// dispatch: ensureDirs creates the malt tree, the SQLite DB is opened,
// schema initialised, lock acquired, and then migrateKeg's `isInstalled`
// check short-circuits the API call because the keg is already recorded.
// No network hit, no bottle download, no Cellar materialization.

test "already-installed kegs are skipped without touching the network" {
    resetOutput();
    const brew = try scratchDir("brew_inst");
    defer {
        malt.fs_compat.deleteTreeAbsolute(brew) catch {};
        testing.allocator.free(brew);
    }

    // MALT_PREFIX must be ≤13 bytes (Mach-O path-patching budget). Using a
    // short prefix keeps us safely under the cap even though migrate's
    // skip-installed path doesn't actually patch any binaries.
    const mt_z: [:0]const u8 = "/tmp/mt_mi";
    malt.fs_compat.deleteTreeAbsolute(mt_z) catch {};
    try malt.fs_compat.cwd().makePath(mt_z);
    defer malt.fs_compat.deleteTreeAbsolute(mt_z) catch {};

    try seedFakeBrew(brew, &.{"seeded"});

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    // Pre-seed the malt DB with a keg named "seeded" so migrate's
    // `isInstalled` returns true and the API call is bypassed.
    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{mt_z});
    defer testing.allocator.free(db_dir);
    try malt.fs_compat.cwd().makePath(db_dir);
    const db_path = try std.fmt.allocPrint(testing.allocator, "{s}/malt.db", .{db_dir});
    defer testing.allocator.free(db_path);

    var db = try malt.sqlite.Database.open(db_path);
    try malt.schema.initSchema(&db);
    var stmt = try db.prepare(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path)
        \\VALUES (?, ?, ?, ?, ?);
    );
    try stmt.bindText(1, "seeded");
    try stmt.bindText(2, "seeded");
    try stmt.bindText(3, "1.0");
    try stmt.bindText(4, "0" ** 64);
    try stmt.bindText(5, "/tmp/mt_mi/Cellar/seeded/1.0");
    _ = try stmt.step();
    stmt.finalize();
    db.close();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try migrate.execute(arena.allocator(), &.{"--quiet"});
    resetOutput();

    // Verify the skip branch did not insert a duplicate or clobber the seed.
    var db2 = try malt.sqlite.Database.open(db_path);
    defer db2.close();
    var count_stmt = try db2.prepare("SELECT COUNT(*) FROM kegs WHERE name = 'seeded';");
    defer count_stmt.finalize();
    try testing.expect(try count_stmt.step());
    try testing.expectEqual(@as(i64, 1), count_stmt.columnInt(0));
}
