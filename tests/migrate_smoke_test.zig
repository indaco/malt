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
const io_mod = malt.io_mod;
const color = malt.color;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

// Reset globals other tests may have flipped. `setMode(.human)` matters for the
// --json assertions below — JSON mode is sticky across tests otherwise.
fn resetOutput() void {
    output.setQuiet(false);
    output.setDryRun(false);
    output.setMode(.human);
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
    const db_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/malt.db", .{db_dir}, 0);
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

// ── JSON builders: pure unit tests (no globals, no filesystem) ──────────

fn parseAndCheck(bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return try std.json.parseFromSlice(std.json.Value, testing.allocator, bytes, .{});
}

test "buildDryRunJson emits a well-formed document with kegs + count" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const kegs = [_][]const u8{ "tree", "wget", "jq" };
    try migrate.buildDryRunJson(&aw.writer, "/opt/homebrew", &kegs, true, 0);

    const bytes = aw.written();
    try testing.expect(std.mem.endsWith(u8, bytes, "}\n"));

    const parsed = try parseAndCheck(bytes);
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expect(root.get("dry_run").?.bool);
    try testing.expectEqualStrings("/opt/homebrew", root.get("brew_prefix").?.string);
    try testing.expectEqual(@as(i64, 3), root.get("count").?.integer);
    const arr = root.get("kegs").?.array;
    try testing.expectEqual(@as(usize, 3), arr.items.len);
    try testing.expectEqualStrings("tree", arr.items[0].string);
    try testing.expectEqualStrings("wget", arr.items[1].string);
    try testing.expectEqualStrings("jq", arr.items[2].string);
    try testing.expect(root.get("time_ms") != null);
}

test "buildDryRunJson emits empty-kegs shape for an empty Cellar" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try migrate.buildDryRunJson(&aw.writer, "/usr/local", &.{}, false, 0);

    const parsed = try parseAndCheck(aw.written());
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expect(!root.get("dry_run").?.bool);
    try testing.expectEqualStrings("/usr/local", root.get("brew_prefix").?.string);
    try testing.expectEqual(@as(i64, 0), root.get("count").?.integer);
    try testing.expectEqual(@as(usize, 0), root.get("kegs").?.array.items.len);
}

test "buildSummaryJson emits per-category arrays + counts object" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try migrate.buildSummaryJson(
        &aw.writer,
        "/opt/homebrew",
        &.{ "tree", "wget" },
        &.{"seeded"},
        &.{"fancy-keg"},
        &.{},
        &.{"brokenpkg"},
        0,
    );

    const parsed = try parseAndCheck(aw.written());
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expect(!root.get("dry_run").?.bool);
    try testing.expectEqual(@as(usize, 2), root.get("migrated").?.array.items.len);
    try testing.expectEqualStrings("tree", root.get("migrated").?.array.items[0].string);
    try testing.expectEqual(@as(usize, 1), root.get("skipped_installed").?.array.items.len);
    try testing.expectEqualStrings("seeded", root.get("skipped_installed").?.array.items[0].string);
    try testing.expectEqual(@as(usize, 1), root.get("skipped_post_install").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), root.get("skipped_no_bottle").?.array.items.len);
    try testing.expectEqual(@as(usize, 1), root.get("failed").?.array.items.len);
    try testing.expectEqualStrings("brokenpkg", root.get("failed").?.array.items[0].string);

    const counts = root.get("counts").?.object;
    try testing.expectEqual(@as(i64, 2), counts.get("migrated").?.integer);
    try testing.expectEqual(@as(i64, 1), counts.get("skipped_installed").?.integer);
    try testing.expectEqual(@as(i64, 1), counts.get("skipped_post_install").?.integer);
    try testing.expectEqual(@as(i64, 0), counts.get("skipped_no_bottle").?.integer);
    try testing.expectEqual(@as(i64, 1), counts.get("failed").?.integer);
}

test "buildSummaryJson escapes adversarial keg names per RFC 8259" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const names = [_][]const u8{"weird\"\\keg"};
    try migrate.buildSummaryJson(&aw.writer, "/opt/homebrew", &names, &.{}, &.{}, &.{}, &.{}, 0);

    const parsed = try parseAndCheck(aw.written());
    defer parsed.deinit();
    try testing.expectEqualStrings("weird\"\\keg", parsed.value.object.get("migrated").?.array.items[0].string);
}

// ── End-to-end: capture stdout under --json, parse the payload ──────────

test "dry-run with --json emits a parseable document on stdout" {
    resetOutput();
    const brew = try scratchDir("brew_json_dry");
    defer {
        malt.fs_compat.deleteTreeAbsolute(brew) catch {};
        testing.allocator.free(brew);
    }
    const mt = try scratchDir("mt_json_dry");
    defer {
        malt.fs_compat.deleteTreeAbsolute(mt) catch {};
        testing.allocator.free(mt);
    }
    try seedFakeBrew(brew, &.{ "tree", "wget" });

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    output.setMode(.json);
    defer resetOutput();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    io_mod.beginStdoutCapture(testing.allocator, &buf);
    defer io_mod.endStdoutCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try migrate.execute(arena.allocator(), &.{"--dry-run"});

    const parsed = try parseAndCheck(buf.items);
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expect(root.get("dry_run").?.bool);
    try testing.expectEqual(@as(i64, 2), root.get("count").?.integer);
    try testing.expectEqual(@as(usize, 2), root.get("kegs").?.array.items.len);
}

test "--json with empty Cellar emits an empty-kegs document (no human 'No kegs' line)" {
    resetOutput();
    const brew = try scratchDir("brew_json_empty");
    defer {
        malt.fs_compat.deleteTreeAbsolute(brew) catch {};
        testing.allocator.free(brew);
    }
    const mt = try scratchDir("mt_json_empty");
    defer {
        malt.fs_compat.deleteTreeAbsolute(mt) catch {};
        testing.allocator.free(mt);
    }
    try seedFakeBrew(brew, &.{});

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    output.setMode(.json);
    defer resetOutput();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    io_mod.beginStdoutCapture(testing.allocator, &buf);
    defer io_mod.endStdoutCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try migrate.execute(arena.allocator(), &.{});

    const parsed = try parseAndCheck(buf.items);
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 0), parsed.value.object.get("count").?.integer);
}

test "--json on an already-installed keg records it under skipped_installed" {
    resetOutput();
    const brew = try scratchDir("brew_json_inst");
    defer {
        malt.fs_compat.deleteTreeAbsolute(brew) catch {};
        testing.allocator.free(brew);
    }

    // ≤13-byte MALT_PREFIX — same Mach-O cap rationale as the sister test above.
    const mt_z: [:0]const u8 = "/tmp/mt_mj";
    malt.fs_compat.deleteTreeAbsolute(mt_z) catch {};
    try malt.fs_compat.cwd().makePath(mt_z);
    defer malt.fs_compat.deleteTreeAbsolute(mt_z) catch {};

    try seedFakeBrew(brew, &.{"seeded"});

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{mt_z});
    defer testing.allocator.free(db_dir);
    try malt.fs_compat.cwd().makePath(db_dir);
    const db_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/malt.db", .{db_dir}, 0);
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
    try stmt.bindText(5, "/tmp/mt_mj/Cellar/seeded/1.0");
    _ = try stmt.step();
    stmt.finalize();
    db.close();

    output.setMode(.json);
    defer resetOutput();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    io_mod.beginStdoutCapture(testing.allocator, &buf);
    defer io_mod.endStdoutCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try migrate.execute(arena.allocator(), &.{});

    const parsed = try parseAndCheck(buf.items);
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(@as(usize, 0), root.get("migrated").?.array.items.len);
    try testing.expectEqual(@as(usize, 1), root.get("skipped_installed").?.array.items.len);
    try testing.expectEqualStrings("seeded", root.get("skipped_installed").?.array.items[0].string);
    try testing.expectEqual(@as(i64, 1), root.get("counts").?.object.get("skipped_installed").?.integer);
}

// ── Human summary: stderr capture pins specific lines ───────────────────

fn containsLine(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "dry-run stderr pins the 'Found N packages' and 'Would migrate N' lines" {
    resetOutput();
    color.setForTest(false, false);
    defer color.setForTest(null, null);

    const brew = try scratchDir("brew_stderr_dry");
    defer {
        malt.fs_compat.deleteTreeAbsolute(brew) catch {};
        testing.allocator.free(brew);
    }
    const mt = try scratchDir("mt_stderr_dry");
    defer {
        malt.fs_compat.deleteTreeAbsolute(mt) catch {};
        testing.allocator.free(mt);
    }
    try seedFakeBrew(brew, &.{ "tree", "wget", "jq" });

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    io_mod.beginStderrCapture(testing.allocator, &buf);
    defer io_mod.endStderrCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try migrate.execute(arena.allocator(), &.{"--dry-run"});

    try testing.expect(containsLine(buf.items, "Found 3 package(s) in Homebrew Cellar"));
    try testing.expect(containsLine(buf.items, "Would migrate: tree"));
    try testing.expect(containsLine(buf.items, "Would migrate: wget"));
    try testing.expect(containsLine(buf.items, "Would migrate: jq"));
    try testing.expect(containsLine(buf.items, "Would migrate 3 packages from Homebrew"));
}

// ── SIGINT handling ─────────────────────────────────────────────────────

test "pre-set SIGINT flag short-circuits the per-keg loop before any API call" {
    resetOutput();
    color.setForTest(false, false);
    defer color.setForTest(null, null);

    const brew = try scratchDir("brew_sigint");
    defer {
        malt.fs_compat.deleteTreeAbsolute(brew) catch {};
        testing.allocator.free(brew);
    }
    const mt_z: [:0]const u8 = "/tmp/mt_si";
    malt.fs_compat.deleteTreeAbsolute(mt_z) catch {};
    try malt.fs_compat.cwd().makePath(mt_z);
    defer malt.fs_compat.deleteTreeAbsolute(mt_z) catch {};

    try seedFakeBrew(brew, &.{"willbeskipped"});

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    // Pre-set the flag so the pre-loop check fires before any API hit.
    malt.main_mod.setInterruptedForTest(true);
    defer malt.main_mod.setInterruptedForTest(false);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    io_mod.beginStderrCapture(testing.allocator, &buf);
    defer io_mod.endStderrCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try migrate.execute(arena.allocator(), &.{});

    try testing.expect(containsLine(buf.items, "Interrupted before migration"));
    // Early-return must skip both per-keg success and final summary block.
    try testing.expect(!containsLine(buf.items, "willbeskipped migrated"));
    try testing.expect(!containsLine(buf.items, "Migration complete:"));
}

// ── Cellar-entry filter ─────────────────────────────────────────────────

test "cellar scan ignores stray files and symlinks alongside keg directories" {
    resetOutput();
    const brew = try scratchDir("brew_filter");
    defer {
        malt.fs_compat.deleteTreeAbsolute(brew) catch {};
        testing.allocator.free(brew);
    }
    const mt = try scratchDir("mt_filter");
    defer {
        malt.fs_compat.deleteTreeAbsolute(mt) catch {};
        testing.allocator.free(mt);
    }
    try seedFakeBrew(brew, &.{"tree"});

    // Plant a stray regular file + a dangling symlink in the Cellar root.
    const cellar = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar", .{brew});
    defer testing.allocator.free(cellar);
    const stray_file = try std.fmt.allocPrint(testing.allocator, "{s}/.DS_Store", .{cellar});
    defer testing.allocator.free(stray_file);
    const stray_link = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/dangling", .{cellar}, 0);
    defer testing.allocator.free(stray_link);

    const f = try malt.fs_compat.cwd().createFile(stray_file, .{});
    f.close();
    _ = std.c.symlink("/tmp/nonexistent_migrate_smoke_target", stray_link.ptr);

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    output.setMode(.json);
    defer resetOutput();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    io_mod.beginStdoutCapture(testing.allocator, &buf);
    defer io_mod.endStdoutCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try migrate.execute(arena.allocator(), &.{"--dry-run"});

    const parsed = try parseAndCheck(buf.items);
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(@as(i64, 1), root.get("count").?.integer);
    const kegs = root.get("kegs").?.array;
    try testing.expectEqual(@as(usize, 1), kegs.items.len);
    try testing.expectEqualStrings("tree", kegs.items[0].string);
}

// ── Multi-keg mixed outcomes (skipped_installed + failed_api, offline) ──

test "mixed outcomes: installed keg is skipped and unknown keg fails at API (404-cached)" {
    resetOutput();
    const brew = try scratchDir("brew_mixed");
    defer {
        malt.fs_compat.deleteTreeAbsolute(brew) catch {};
        testing.allocator.free(brew);
    }

    const mt_z: [:0]const u8 = "/tmp/mt_mx";
    malt.fs_compat.deleteTreeAbsolute(mt_z) catch {};
    try malt.fs_compat.cwd().makePath(mt_z);
    defer malt.fs_compat.deleteTreeAbsolute(mt_z) catch {};

    try seedFakeBrew(brew, &.{ "seeded", "unknownpkg" });

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    // Seed malt DB: one keg already "installed" to exercise the skip path.
    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{mt_z});
    defer testing.allocator.free(db_dir);
    try malt.fs_compat.cwd().makePath(db_dir);
    const db_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/malt.db", .{db_dir}, 0);
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
    try stmt.bindText(5, "/tmp/mt_mx/Cellar/seeded/1.0");
    _ = try stmt.step();
    stmt.finalize();
    db.close();

    // Pre-seed a 404 marker so fetchFormula fails offline (audit-documented pattern).
    const cache_api = try std.fmt.allocPrint(testing.allocator, "{s}/cache/api", .{mt_z});
    defer testing.allocator.free(cache_api);
    try malt.fs_compat.cwd().makePath(cache_api);
    const marker = try std.fmt.allocPrint(testing.allocator, "{s}/formula_unknownpkg.404", .{cache_api});
    defer testing.allocator.free(marker);
    const mf = try malt.fs_compat.cwd().createFile(marker, .{});
    mf.close();

    output.setMode(.json);
    defer resetOutput();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    io_mod.beginStdoutCapture(testing.allocator, &buf);
    defer io_mod.endStdoutCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try migrate.execute(arena.allocator(), &.{});

    const parsed = try parseAndCheck(buf.items);
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(@as(usize, 0), root.get("migrated").?.array.items.len);
    try testing.expectEqual(@as(usize, 1), root.get("skipped_installed").?.array.items.len);
    try testing.expectEqualStrings("seeded", root.get("skipped_installed").?.array.items[0].string);
    try testing.expectEqual(@as(usize, 1), root.get("failed").?.array.items.len);
    try testing.expectEqualStrings("unknownpkg", root.get("failed").?.array.items[0].string);

    const counts = root.get("counts").?.object;
    try testing.expectEqual(@as(i64, 0), counts.get("migrated").?.integer);
    try testing.expectEqual(@as(i64, 1), counts.get("skipped_installed").?.integer);
    try testing.expectEqual(@as(i64, 1), counts.get("failed").?.integer);
}

// ── Lock contention ─────────────────────────────────────────────────────

test "lock contention returns error.Aborted when db/malt.lock is already held" {
    resetOutput();
    const brew = try scratchDir("brew_lock");
    defer {
        malt.fs_compat.deleteTreeAbsolute(brew) catch {};
        testing.allocator.free(brew);
    }

    const mt_z: [:0]const u8 = "/tmp/mt_lk";
    malt.fs_compat.deleteTreeAbsolute(mt_z) catch {};
    try malt.fs_compat.cwd().makePath(mt_z);
    defer malt.fs_compat.deleteTreeAbsolute(mt_z) catch {};

    try seedFakeBrew(brew, &.{"willnotreach"});

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");
    // Short timeout so contention fails fast instead of the 30 s default.
    _ = c.setenv("MALT_LOCK_TIMEOUT_MS", "50", 1);
    defer _ = c.unsetenv("MALT_LOCK_TIMEOUT_MS");

    // Pre-acquire the lock externally so migrate's acquire hits timeout.
    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{mt_z});
    defer testing.allocator.free(db_dir);
    try malt.fs_compat.cwd().makePath(db_dir);
    const lock_path = try std.fmt.allocPrint(testing.allocator, "{s}/malt.lock", .{db_dir});
    defer testing.allocator.free(lock_path);
    var holder = try malt.lock.LockFile.acquire(lock_path, 1000);
    defer holder.release();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(
        error.Aborted,
        migrate.execute(arena.allocator(), &.{}),
    );
}

test "already-installed stderr pins the 'Migration complete' + 'Skipped (installed): 1' lines" {
    resetOutput();
    color.setForTest(false, false);
    defer color.setForTest(null, null);

    const brew = try scratchDir("brew_stderr_inst");
    defer {
        malt.fs_compat.deleteTreeAbsolute(brew) catch {};
        testing.allocator.free(brew);
    }

    const mt_z: [:0]const u8 = "/tmp/mt_ms";
    malt.fs_compat.deleteTreeAbsolute(mt_z) catch {};
    try malt.fs_compat.cwd().makePath(mt_z);
    defer malt.fs_compat.deleteTreeAbsolute(mt_z) catch {};

    try seedFakeBrew(brew, &.{"seeded"});

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{mt_z});
    defer testing.allocator.free(db_dir);
    try malt.fs_compat.cwd().makePath(db_dir);
    const db_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/malt.db", .{db_dir}, 0);
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
    try stmt.bindText(5, "/tmp/mt_ms/Cellar/seeded/1.0");
    _ = try stmt.step();
    stmt.finalize();
    db.close();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    io_mod.beginStderrCapture(testing.allocator, &buf);
    defer io_mod.endStderrCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try migrate.execute(arena.allocator(), &.{});

    try testing.expect(containsLine(buf.items, "Migration complete:"));
    try testing.expect(containsLine(buf.items, "Migrated:              0"));
    try testing.expect(containsLine(buf.items, "Skipped (installed):   1"));
}

// ── Parsed-formula lifecycle pinning ────────────────────────────────────
//
// Drive `migrateKeg` through the `.skipped_no_bottle` branch (formula JSON
// has no bottle for this platform). The defer/errdefer pair must free
// exactly once on this path — a double free of `_parsed` would crash the
// sqlite/arena owner in the next run.

test "skipped_no_bottle: cached formula with no platform bottle is categorized correctly" {
    resetOutput();

    const brew = try scratchDir("brew_nobottle");
    defer {
        malt.fs_compat.deleteTreeAbsolute(brew) catch {};
        testing.allocator.free(brew);
    }

    // ≤13-byte MALT_PREFIX — same Mach-O budget rationale as sister tests.
    const mt_z: [:0]const u8 = "/tmp/mt_nb";
    malt.fs_compat.deleteTreeAbsolute(mt_z) catch {};
    try malt.fs_compat.cwd().makePath(mt_z);
    defer malt.fs_compat.deleteTreeAbsolute(mt_z) catch {};

    try seedFakeBrew(brew, &.{"noplatform"});

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    // Seed a formula-cache hit with an intentionally minimal payload — no
    // bottle_files, no dependencies, no oldnames. `resolveBottle` returns
    // NoBottleAvailable immediately and the branch's cleanup path runs.
    const cache_api = try std.fmt.allocPrint(testing.allocator, "{s}/cache/api", .{mt_z});
    defer testing.allocator.free(cache_api);
    try malt.fs_compat.cwd().makePath(cache_api);
    const cache_path = try std.fmt.allocPrint(testing.allocator, "{s}/formula_noplatform.json", .{cache_api});
    defer testing.allocator.free(cache_path);
    const cache_file = try malt.fs_compat.cwd().createFile(cache_path, .{});
    defer cache_file.close();
    try cache_file.writeAll(
        \\{"name":"noplatform","full_name":"noplatform","tap":"homebrew/core","versions":{"stable":"1.0"}}
    );

    output.setMode(.json);
    defer resetOutput();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    io_mod.beginStdoutCapture(testing.allocator, &buf);
    defer io_mod.endStdoutCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try migrate.execute(arena.allocator(), &.{});

    const parsed = try parseAndCheck(buf.items);
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(@as(usize, 1), root.get("skipped_no_bottle").?.array.items.len);
    try testing.expectEqualStrings("noplatform", root.get("skipped_no_bottle").?.array.items[0].string);
    try testing.expectEqual(@as(usize, 0), root.get("migrated").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), root.get("failed").?.array.items.len);
    try testing.expectEqual(@as(i64, 1), root.get("counts").?.object.get("skipped_no_bottle").?.integer);
}

// ── Iterator-error surface: scanCellarKegs logs + preserves prior ──────
//
// `iter.next() catch null` silently collapsed the scan on any permission,
// I/O, or stale-handle error — hiding every later keg behind a single bad
// entry. A mock iterator that yields two kegs then `error.AccessDenied`
// pins the replacement contract: prior entries survive, the failure is
// logged, and the loop terminates without propagating the error.

const MockDirEntry = struct {
    name: []const u8,
    kind: std.Io.File.Kind,
};

const MockIter = struct {
    entries: []const MockDirEntry,
    idx: usize = 0,
    fail_after: ?usize = null,

    pub fn next(self: *MockIter) !?MockDirEntry {
        if (self.fail_after) |n| if (self.idx == n) {
            self.idx += 1;
            return error.AccessDenied;
        };
        if (self.idx >= self.entries.len) return null;
        defer self.idx += 1;
        return self.entries[self.idx];
    }
};

test "scanCellarKegs warns and preserves prior names when iterator errors" {
    resetOutput();
    color.setForTest(false, false);
    defer color.setForTest(null, null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var names: std.ArrayList([]const u8) = .empty;
    var mock = MockIter{
        .entries = &.{
            .{ .name = "tree", .kind = .directory },
            .{ .name = "wget", .kind = .directory },
        },
        .fail_after = 2,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    io_mod.beginStderrCapture(testing.allocator, &buf);
    defer io_mod.endStderrCapture();

    try migrate.scanCellarKegs(arena.allocator(), &mock, &names);

    try testing.expectEqual(@as(usize, 2), names.items.len);
    try testing.expectEqualStrings("tree", names.items[0]);
    try testing.expectEqualStrings("wget", names.items[1]);
    try testing.expect(containsLine(buf.items, "Cellar scan error"));
    try testing.expect(containsLine(buf.items, "AccessDenied"));
}

// ── Resume manifest ────────────────────────────────────────────────
//
// Pre-seed `{cache}/migrate.progress.json` with one keg name. Run migrate
// over a fake Cellar that contains that same keg and one unknown keg. The
// pre-seeded keg must be skipped *before* any API hit (no 404 marker, so
// reaching the API would leak as a `failed_api` outcome) — this pins the
// resume contract end-to-end.

test "resume manifest: pre-seeded keg is skipped before any API call" {
    resetOutput();

    const brew = try scratchDir("brew_resume");
    defer {
        malt.fs_compat.deleteTreeAbsolute(brew) catch {};
        testing.allocator.free(brew);
    }

    const mt_z: [:0]const u8 = "/tmp/mt_rs";
    malt.fs_compat.deleteTreeAbsolute(mt_z) catch {};
    try malt.fs_compat.cwd().makePath(mt_z);
    defer malt.fs_compat.deleteTreeAbsolute(mt_z) catch {};

    try seedFakeBrew(brew, &.{ "alreadydone", "unknownpkg" });

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    // Pre-seed a 404 marker for the *other* keg so it fails offline. If the
    // manifest filter ever regresses, "alreadydone" would also try the API
    // and fail differently (FormulaNotFound → failed_api), pinning the bug.
    const cache_api = try std.fmt.allocPrint(testing.allocator, "{s}/cache/api", .{mt_z});
    defer testing.allocator.free(cache_api);
    try malt.fs_compat.cwd().makePath(cache_api);
    const marker = try std.fmt.allocPrint(testing.allocator, "{s}/formula_unknownpkg.404", .{cache_api});
    defer testing.allocator.free(marker);
    const mf = try malt.fs_compat.cwd().createFile(marker, .{});
    mf.close();

    // Pre-seed a 404 for "alreadydone" too — if the manifest filter ever
    // breaks, the test still terminates offline (failed_api) instead of
    // hitting the network. The assertion still pins resume because we
    // expect skipped_installed, not failed_api.
    const marker2 = try std.fmt.allocPrint(testing.allocator, "{s}/formula_alreadydone.404", .{cache_api});
    defer testing.allocator.free(marker2);
    const mf2 = try malt.fs_compat.cwd().createFile(marker2, .{});
    mf2.close();

    // Pre-seed the resume manifest with "alreadydone" *and* a matching
    // DB row — the resume short-circuit requires both to agree so a
    // stale manifest after `mt uninstall` doesn't silently skip a keg.
    const cache_dir = try std.fmt.allocPrint(testing.allocator, "{s}/cache", .{mt_z});
    defer testing.allocator.free(cache_dir);
    try malt.fs_compat.cwd().makePath(cache_dir);
    var manifest = malt.cli_migrate_manifest.Manifest.init(testing.allocator);
    defer manifest.deinit();
    try manifest.add("alreadydone");
    const manifest_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/migrate.progress.json",
        .{cache_dir},
    );
    defer testing.allocator.free(manifest_path);
    try manifest.writeAtomic(testing.allocator, manifest_path);

    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{mt_z});
    defer testing.allocator.free(db_dir);
    try malt.fs_compat.cwd().makePath(db_dir);
    const db_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/malt.db", .{db_dir}, 0);
    defer testing.allocator.free(db_path);
    var db_seed = try malt.sqlite.Database.open(db_path);
    try malt.schema.initSchema(&db_seed);
    var seed_stmt = try db_seed.prepare(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path)
        \\VALUES (?, ?, ?, ?, ?);
    );
    try seed_stmt.bindText(1, "alreadydone");
    try seed_stmt.bindText(2, "alreadydone");
    try seed_stmt.bindText(3, "1.0");
    try seed_stmt.bindText(4, "0" ** 64);
    try seed_stmt.bindText(5, "/tmp/mt_rs/Cellar/alreadydone/1.0");
    _ = try seed_stmt.step();
    seed_stmt.finalize();
    db_seed.close();

    output.setMode(.json);
    defer resetOutput();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    io_mod.beginStdoutCapture(testing.allocator, &buf);
    defer io_mod.endStdoutCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try migrate.execute(arena.allocator(), &.{});

    const parsed = try parseAndCheck(buf.items);
    defer parsed.deinit();
    const root = parsed.value.object;
    // Pre-seeded keg is reported skipped (resume contract).
    const skipped = root.get("skipped_installed").?.array;
    var found_alreadydone = false;
    for (skipped.items) |v| {
        if (std.mem.eql(u8, v.string, "alreadydone")) found_alreadydone = true;
    }
    try testing.expect(found_alreadydone);
    // The other keg still went through the API (and 404'd) — pinning that
    // the manifest filter is *selective*, not a blanket short-circuit.
    const failed = root.get("failed").?.array;
    try testing.expectEqual(@as(usize, 1), failed.items.len);
    try testing.expectEqualStrings("unknownpkg", failed.items[0].string);
}

// ── Manifest contract on failure ───────────────────────────────────
//
// A failed keg must never end up in `migrate.progress.json`; otherwise
// every future run would silently skip a keg the user actually wants
// installed. Drive a 404-failing keg through the serial path and assert
// the on-disk manifest stays empty.

test "failed migrate does not write the keg into the resume manifest" {
    resetOutput();

    const brew = try scratchDir("brew_failnomanifest");
    defer {
        malt.fs_compat.deleteTreeAbsolute(brew) catch {};
        testing.allocator.free(brew);
    }
    const mt_z: [:0]const u8 = "/tmp/mt_fn";
    malt.fs_compat.deleteTreeAbsolute(mt_z) catch {};
    try malt.fs_compat.cwd().makePath(mt_z);
    defer malt.fs_compat.deleteTreeAbsolute(mt_z) catch {};

    try seedFakeBrew(brew, &.{"failkeg"});

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    const cache_api = try std.fmt.allocPrint(testing.allocator, "{s}/cache/api", .{mt_z});
    defer testing.allocator.free(cache_api);
    try malt.fs_compat.cwd().makePath(cache_api);
    const marker = try std.fmt.allocPrint(testing.allocator, "{s}/formula_failkeg.404", .{cache_api});
    defer testing.allocator.free(marker);
    const mf = try malt.fs_compat.cwd().createFile(marker, .{});
    mf.close();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try migrate.execute(arena.allocator(), &.{"--quiet"});

    // Manifest must either not exist or contain zero entries — the 404
    // path returned `.failed_api`, never `.migrated`.
    const manifest_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/cache/migrate.progress.json",
        .{mt_z},
    );
    defer testing.allocator.free(manifest_path);
    var loaded = try malt.cli_migrate_manifest.loadFromPath(testing.allocator, manifest_path);
    defer loaded.deinit();
    try testing.expect(!loaded.contains("failkeg"));
    try testing.expectEqual(@as(usize, 0), loaded.entries.items.len);
}

// Pre-seeded successes must survive a later re-run that fails on
// other kegs. `writeAtomic` rewrites the whole file each tick, so a
// regression in the load-then-rewrite contract would silently drop
// previously-completed entries.

test "manifest preserves pre-existing entries across a run with new failures" {
    resetOutput();

    const brew = try scratchDir("brew_preserve");
    defer {
        malt.fs_compat.deleteTreeAbsolute(brew) catch {};
        testing.allocator.free(brew);
    }
    const mt_z: [:0]const u8 = "/tmp/mt_pv";
    malt.fs_compat.deleteTreeAbsolute(mt_z) catch {};
    try malt.fs_compat.cwd().makePath(mt_z);
    defer malt.fs_compat.deleteTreeAbsolute(mt_z) catch {};

    // The Cellar contains the pre-seeded keg + a new one that 404s.
    try seedFakeBrew(brew, &.{ "old", "newfail" });

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    const cache_api = try std.fmt.allocPrint(testing.allocator, "{s}/cache/api", .{mt_z});
    defer testing.allocator.free(cache_api);
    try malt.fs_compat.cwd().makePath(cache_api);
    const marker = try std.fmt.allocPrint(testing.allocator, "{s}/formula_newfail.404", .{cache_api});
    defer testing.allocator.free(marker);
    const mf = try malt.fs_compat.cwd().createFile(marker, .{});
    mf.close();

    const cache_dir = try std.fmt.allocPrint(testing.allocator, "{s}/cache", .{mt_z});
    defer testing.allocator.free(cache_dir);
    try malt.fs_compat.cwd().makePath(cache_dir);
    const manifest_path = try std.fmt.allocPrint(testing.allocator, "{s}/migrate.progress.json", .{cache_dir});
    defer testing.allocator.free(manifest_path);

    var seed = malt.cli_migrate_manifest.Manifest.init(testing.allocator);
    defer seed.deinit();
    try seed.add("old");
    try seed.writeAtomic(testing.allocator, manifest_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try migrate.execute(arena.allocator(), &.{"--quiet"});

    var loaded = try malt.cli_migrate_manifest.loadFromPath(testing.allocator, manifest_path);
    defer loaded.deinit();
    try testing.expect(loaded.contains("old"));
    try testing.expect(!loaded.contains("newfail"));
}

// Stale manifest (post-uninstall) must not silently skip a keg the user
// expects to be re-migrated. Pre-seed the manifest with "ghost" but
// leave the DB empty + 404-mark the formula. Pre-PR semantics would
// have skipped silently; the DB cross-check forces a real attempt
// (which 404s offline → `failed`), proving we did NOT short-circuit.

test "stale manifest after uninstall falls through to a real migrate" {
    resetOutput();

    const brew = try scratchDir("brew_stale");
    defer {
        malt.fs_compat.deleteTreeAbsolute(brew) catch {};
        testing.allocator.free(brew);
    }
    const mt_z: [:0]const u8 = "/tmp/mt_st";
    malt.fs_compat.deleteTreeAbsolute(mt_z) catch {};
    try malt.fs_compat.cwd().makePath(mt_z);
    defer malt.fs_compat.deleteTreeAbsolute(mt_z) catch {};

    try seedFakeBrew(brew, &.{"ghost"});

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    const cache_api = try std.fmt.allocPrint(testing.allocator, "{s}/cache/api", .{mt_z});
    defer testing.allocator.free(cache_api);
    try malt.fs_compat.cwd().makePath(cache_api);
    const marker = try std.fmt.allocPrint(testing.allocator, "{s}/formula_ghost.404", .{cache_api});
    defer testing.allocator.free(marker);
    const mf = try malt.fs_compat.cwd().createFile(marker, .{});
    mf.close();

    // Manifest claims "ghost" was migrated; DB is empty (simulating uninstall).
    const cache_dir = try std.fmt.allocPrint(testing.allocator, "{s}/cache", .{mt_z});
    defer testing.allocator.free(cache_dir);
    try malt.fs_compat.cwd().makePath(cache_dir);
    var stale = malt.cli_migrate_manifest.Manifest.init(testing.allocator);
    defer stale.deinit();
    try stale.add("ghost");
    const manifest_path = try std.fmt.allocPrint(testing.allocator, "{s}/migrate.progress.json", .{cache_dir});
    defer testing.allocator.free(manifest_path);
    try stale.writeAtomic(testing.allocator, manifest_path);

    output.setMode(.json);
    defer resetOutput();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    io_mod.beginStdoutCapture(testing.allocator, &buf);
    defer io_mod.endStdoutCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try migrate.execute(arena.allocator(), &.{});

    const parsed = try parseAndCheck(buf.items);
    defer parsed.deinit();
    const root = parsed.value.object;
    // Real attempt happened — keg ended up in `failed` (API 404), not
    // `skipped_installed`. A regression to manifest-only-skip would
    // place it in `skipped_installed` with zero failures.
    try testing.expectEqual(@as(usize, 0), root.get("skipped_installed").?.array.items.len);
    try testing.expectEqual(@as(usize, 1), root.get("failed").?.array.items.len);
    try testing.expectEqualStrings("ghost", root.get("failed").?.array.items[0].string);
}

// Self-heal contract: the SIGKILL window between "DB row committed"
// and "manifest writeAtomic flushed" leaves DB ahead of manifest. The
// recovery run must repopulate the manifest from the DB-confirmed skip
// so subsequent runs don't keep paying the DB-lookup penalty for the
// same keg forever.

test "manifest self-heals from DB-confirmed skips after a crash recovery" {
    resetOutput();

    const brew = try scratchDir("brew_heal");
    defer {
        malt.fs_compat.deleteTreeAbsolute(brew) catch {};
        testing.allocator.free(brew);
    }
    const mt_z: [:0]const u8 = "/tmp/mt_hl";
    malt.fs_compat.deleteTreeAbsolute(mt_z) catch {};
    try malt.fs_compat.cwd().makePath(mt_z);
    defer malt.fs_compat.deleteTreeAbsolute(mt_z) catch {};

    try seedFakeBrew(brew, &.{"recovered"});

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    // Simulate the post-crash state: DB has the keg (previous run
    // committed it) but the manifest file does not exist (previous
    // run died before writeAtomic).
    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{mt_z});
    defer testing.allocator.free(db_dir);
    try malt.fs_compat.cwd().makePath(db_dir);
    const db_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/malt.db", .{db_dir}, 0);
    defer testing.allocator.free(db_path);
    var db = try malt.sqlite.Database.open(db_path);
    try malt.schema.initSchema(&db);
    var stmt = try db.prepare(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path)
        \\VALUES (?, ?, ?, ?, ?);
    );
    try stmt.bindText(1, "recovered");
    try stmt.bindText(2, "recovered");
    try stmt.bindText(3, "1.0");
    try stmt.bindText(4, "0" ** 64);
    try stmt.bindText(5, "/tmp/mt_hl/Cellar/recovered/1.0");
    _ = try stmt.step();
    stmt.finalize();
    db.close();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try migrate.execute(arena.allocator(), &.{"--quiet"});

    // Manifest now exists on disk and contains the keg the DB had —
    // future runs hit the cheap manifest short-circuit instead of the
    // DB lookup. Pin both: file load works, and the entry is there.
    const manifest_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/cache/migrate.progress.json",
        .{mt_z},
    );
    defer testing.allocator.free(manifest_path);
    var loaded = try malt.cli_migrate_manifest.loadFromPath(testing.allocator, manifest_path);
    defer loaded.deinit();
    try testing.expect(loaded.contains("recovered"));
}

test "scanCellarKegs skips non-directory entries and survives fail-first iterator" {
    resetOutput();
    color.setForTest(false, false);
    defer color.setForTest(null, null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var names: std.ArrayList([]const u8) = .empty;
    var mock = MockIter{
        .entries = &.{
            .{ .name = ".DS_Store", .kind = .file },
            .{ .name = "tree", .kind = .directory },
        },
        .fail_after = 0, // error on the very first call
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    io_mod.beginStderrCapture(testing.allocator, &buf);
    defer io_mod.endStderrCapture();

    try migrate.scanCellarKegs(arena.allocator(), &mock, &names);
    try testing.expectEqual(@as(usize, 0), names.items.len);
    try testing.expect(containsLine(buf.items, "Cellar scan error"));
}

// ── Leak discipline: execute must not leak under testing.allocator ──────
//
// A plain `ArrayList([]const u8)` whose `deinit` only frees the backing
// array would leak every per-entry `allocator.dupe`. Dropping the arena
// here turns any such leak into a test failure and guards the arena-scoped
// scan going forward.

test "dry-run with 4 kegs under testing.allocator shows zero leaks" {
    resetOutput();
    const brew = try scratchDir("brew_noleak");
    defer {
        malt.fs_compat.deleteTreeAbsolute(brew) catch {};
        testing.allocator.free(brew);
    }
    const mt = try scratchDir("mt_noleak");
    defer {
        malt.fs_compat.deleteTreeAbsolute(mt) catch {};
        testing.allocator.free(mt);
    }
    try seedFakeBrew(brew, &.{ "tree", "wget", "jq", "ffmpeg" });

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    try migrate.execute(testing.allocator, &.{ "--dry-run", "--quiet" });
}
