//! Smoke tests for `malt migrate` — drives `migrate.execute` end-to-end
//! against a fake Homebrew Cellar (via HOMEBREW_PREFIX) and a scratch
//! MALT_PREFIX, so the whole command pipeline is exercised without
//! touching the user's real Homebrew or malt installs, and without
//! network access. Dry-run is the primary vehicle: it reaches every
//! input-validation and cellar-scan path, then returns before any
//! bottle download would happen.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const migrate = malt.cli_migrate;
const output = malt.output;
const io_mod = malt.output;
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
        .{ test_io.nanoTimestamp(
            std.Options.debug_io,
        ), suffix },
        0,
    );
    test_io.deleteTreeAbsolute(std.Options.debug_io, p) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, p);
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
    try test_io.cwd().createDirPath(std.Options.debug_io, cellar);
    for (kegs) |name| {
        const keg_dir = try std.fmt.allocPrint(testing.allocator, "{s}/{s}/1.0", .{ cellar, name });
        defer testing.allocator.free(keg_dir);
        try test_io.cwd().createDirPath(std.Options.debug_io, keg_dir);
    }
}

fn pathExists(path: []const u8) bool {
    test_io.accessAbsolute(std.Options.debug_io, path, .{}) catch return false;
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
    try migrate.execute(&malt.app_ctx.debug_ctx, arena.allocator(), &.{"--help"});
    try migrate.execute(&malt.app_ctx.debug_ctx, arena.allocator(), &.{"-h"});
}

test "bare --use-system-ruby is refused (would widen trust boundary to every keg)" {
    resetOutput();
    _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.unsetenv("MALT_PREFIX");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(
        error.Aborted,
        migrate.execute(&malt.app_ctx.debug_ctx, arena.allocator(), &.{"--use-system-ruby"}),
    );
    // The rejection fires before brew detection, so --dry-run can't rescue it.
    try testing.expectError(
        error.Aborted,
        migrate.execute(&malt.app_ctx.debug_ctx, arena.allocator(), &.{ "--dry-run", "--use-system-ruby" }),
    );
}

// ── detectBrewPrefix env override ───────────────────────────────────────

test "detectBrewPrefix honors HOMEBREW_PREFIX when set" {
    _ = c.setenv("HOMEBREW_PREFIX", "/tmp/brew_fake_prefix", 1);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    const ctx: malt.app_ctx.AppCtx = .{ .io = std.Options.debug_io, .environ = malt.app_ctx.processEnviron() };
    try testing.expectEqualStrings("/tmp/brew_fake_prefix", migrate.detectBrewPrefix(&ctx));
}

test "detectBrewPrefix falls back to arch default when unset" {
    _ = c.unsetenv("HOMEBREW_PREFIX");
    const ctx: malt.app_ctx.AppCtx = .{ .io = std.Options.debug_io, .environ = malt.app_ctx.processEnviron() };
    const got = migrate.detectBrewPrefix(&ctx);
    // Either /opt/homebrew (arm64) or /usr/local (x86) — never empty,
    // always absolute. Exact value depends on the host arch.
    try testing.expect(got.len > 0);
    try testing.expectEqual(@as(u8, '/'), got[0]);
}

test "empty HOMEBREW_PREFIX falls through to arch default" {
    _ = c.setenv("HOMEBREW_PREFIX", "", 1);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    const ctx: malt.app_ctx.AppCtx = .{ .io = std.Options.debug_io, .environ = malt.app_ctx.processEnviron() };
    const got = migrate.detectBrewPrefix(&ctx);
    try testing.expect(got.len > 0);
    try testing.expectEqual(@as(u8, '/'), got[0]);
}

// ── Cellar discovery ────────────────────────────────────────────────────

test "missing Homebrew installation yields error.Aborted" {
    resetOutput();
    const bogus = "/tmp/mt_mig_no_such_brew_dir_12345";
    test_io.deleteTreeAbsolute(std.Options.debug_io, bogus) catch {};
    _ = c.setenv("HOMEBREW_PREFIX", bogus, 1);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try testing.expectError(
        error.Aborted,
        migrate.execute(&ctx, arena.allocator(), &.{"--dry-run"}),
    );
}

test "empty Cellar exits cleanly with no malt state created" {
    resetOutput();
    const brew = try scratchDir("brew_empty");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }
    const mt = try scratchDir("mt_empty");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, mt) catch {};
        testing.allocator.free(mt);
    }
    try seedFakeBrew(brew, &.{});

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{});

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
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }
    const mt = try scratchDir("mt_dry");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, mt) catch {};
        testing.allocator.free(mt);
    }
    try seedFakeBrew(brew, &.{ "tree", "wget", "jq" });

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{ "--dry-run", "--quiet" });

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
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }
    const mt = try scratchDir("mt_idem");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, mt) catch {};
        testing.allocator.free(mt);
    }
    try seedFakeBrew(brew, &.{ "openssl", "ca-certificates" });

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{ "--dry-run", "--quiet" });
    try migrate.execute(&ctx, arena.allocator(), &.{ "--dry-run", "--quiet" });

    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{mt});
    defer testing.allocator.free(db_dir);
    try testing.expect(!pathExists(db_dir));
}

test "dry-run with scoped --use-system-ruby=foo,bar is accepted (scope parsed, no trust-boundary error)" {
    resetOutput();
    const brew = try scratchDir("brew_scope");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }
    const mt = try scratchDir("mt_scope");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, mt) catch {};
        testing.allocator.free(mt);
    }
    try seedFakeBrew(brew, &.{"foo"});

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    // Scoped form is the *only* way to opt in for migrate; empty names in the
    // list (e.g. "foo,,bar") must be tolerated, and dry-run must still win.
    try migrate.execute(&ctx, arena.allocator(), &.{ "--dry-run", "--quiet", "--use-system-ruby=foo,,bar" });
}

// ── Quiet flag ──────────────────────────────────────────────────────────

test "--quiet alone (no dry-run) with empty Cellar still returns cleanly" {
    resetOutput();
    const brew = try scratchDir("brew_quiet");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }
    const mt = try scratchDir("mt_quiet");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, mt) catch {};
        testing.allocator.free(mt);
    }
    try seedFakeBrew(brew, &.{});

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{"-q"});
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
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }

    // MALT_PREFIX must be ≤13 bytes (Mach-O path-patching budget). Using a
    // short prefix keeps us safely under the cap even though migrate's
    // skip-installed path doesn't actually patch any binaries.
    const mt_z: [:0]const u8 = "/tmp/mt_mi";
    test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, mt_z);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};

    try seedFakeBrew(brew, &.{"seeded"});

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    // Pre-seed the malt DB with a keg named "seeded" so migrate's
    // `isInstalled` returns true and the API call is bypassed.
    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{mt_z});
    defer testing.allocator.free(db_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);
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
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{"--quiet"});
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
        &.{"untouched"},
        &.{},
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
    try testing.expectEqual(@as(usize, 1), root.get("cancelled").?.array.items.len);
    try testing.expectEqualStrings("untouched", root.get("cancelled").?.array.items[0].string);

    const counts = root.get("counts").?.object;
    try testing.expectEqual(@as(i64, 2), counts.get("migrated").?.integer);
    try testing.expectEqual(@as(i64, 1), counts.get("skipped_installed").?.integer);
    try testing.expectEqual(@as(i64, 1), counts.get("skipped_post_install").?.integer);
    try testing.expectEqual(@as(i64, 0), counts.get("skipped_no_bottle").?.integer);
    try testing.expectEqual(@as(i64, 1), counts.get("failed").?.integer);
    try testing.expectEqual(@as(i64, 1), counts.get("cancelled").?.integer);
}

// Under `--json`, post_install events land inside the summary doc
// (not as standalone JSONL entries); buffered entries are embedded
// verbatim, preserving the raw JSON bytes the per-keg path captured.
test "buildSummaryJson embeds post_install_events when buffer has entries" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const events = [_][]const u8{
        "{\"name\":\"ca-certificates\",\"status\":\"completed\",\"entries\":[]}",
        "{\"name\":\"openssl@3\",\"status\":\"partially_skipped\",\"entries\":[{\"reason\":\"unknown_method\"}]}",
    };

    try migrate.buildSummaryJson(
        &aw.writer,
        "/opt/homebrew",
        &.{ "ca-certificates", "openssl@3" },
        &.{},
        &.{},
        &.{},
        &.{},
        &.{},
        &events,
        0,
    );

    const parsed = try parseAndCheck(aw.written());
    defer parsed.deinit();
    const root = parsed.value.object;
    const arr = root.get("post_install_events").?.array;
    try testing.expectEqual(@as(usize, 2), arr.items.len);
    try testing.expectEqualStrings("ca-certificates", arr.items[0].object.get("name").?.string);
    try testing.expectEqualStrings("completed", arr.items[0].object.get("status").?.string);
    try testing.expectEqualStrings("openssl@3", arr.items[1].object.get("name").?.string);
    try testing.expectEqualStrings("partially_skipped", arr.items[1].object.get("status").?.string);
}

// Reverse contract: when no post_install events were buffered (every
// migrated keg had `post_install_defined == false`), the summary must
// still expose the array - empty - so consumers can rely on its
// presence under any non-dry-run `--json` invocation.
test "buildSummaryJson emits an empty post_install_events array when buffer is empty" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try migrate.buildSummaryJson(
        &aw.writer,
        "/opt/homebrew",
        &.{},
        &.{},
        &.{},
        &.{},
        &.{},
        &.{},
        &.{},
        0,
    );

    const parsed = try parseAndCheck(aw.written());
    defer parsed.deinit();
    const arr = parsed.value.object.get("post_install_events").?.array;
    try testing.expectEqual(@as(usize, 0), arr.items.len);
}

test "buildSummaryJson escapes adversarial keg names per RFC 8259" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const names = [_][]const u8{"weird\"\\keg"};
    try migrate.buildSummaryJson(&aw.writer, "/opt/homebrew", &names, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, 0);

    const parsed = try parseAndCheck(aw.written());
    defer parsed.deinit();
    try testing.expectEqualStrings("weird\"\\keg", parsed.value.object.get("migrated").?.array.items[0].string);
}

// ── End-to-end: capture stdout under --json, parse the payload ──────────

test "dry-run with --json emits a parseable document on stdout" {
    resetOutput();
    const brew = try scratchDir("brew_json_dry");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }
    const mt = try scratchDir("mt_json_dry");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, mt) catch {};
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
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{"--dry-run"});

    const parsed = try parseAndCheck(buf.items);
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expect(root.get("dry_run").?.bool);
    try testing.expectEqual(@as(i64, 2), root.get("count").?.integer);
    try testing.expectEqual(@as(usize, 2), root.get("kegs").?.array.items.len);
}

// An empty Cellar under `--json` (no `--dry-run`) used to emit the
// dry-run document shape (`.kegs` + `.count`), so consumers had to
// branch on whether their `--json` invocation hit zero kegs. The
// post-migration shape is the contract: counts present, all zero.
test "--json with empty Cellar emits the summary shape with zero counts" {
    resetOutput();
    const brew = try scratchDir("brew_json_empty");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }
    const mt = try scratchDir("mt_json_empty");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, mt) catch {};
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
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{});

    const parsed = try parseAndCheck(buf.items);
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expect(!root.get("dry_run").?.bool);
    try testing.expectEqual(@as(usize, 0), root.get("migrated").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), root.get("skipped_installed").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), root.get("skipped_post_install").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), root.get("skipped_no_bottle").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), root.get("failed").?.array.items.len);
    const counts = root.get("counts").?.object;
    try testing.expectEqual(@as(i64, 0), counts.get("migrated").?.integer);
    try testing.expectEqual(@as(i64, 0), counts.get("failed").?.integer);
    // Stable contract: the dry-run shape's `kegs` / `count` keys must NOT
    // leak into the summary path. Consumers should see one shape only.
    try testing.expect(root.get("kegs") == null);
    try testing.expect(root.get("count") == null);
}

// `--dry-run` keeps the dry-run document shape regardless of count. An
// empty Cellar under `--dry-run --json` therefore preserves the
// `.kegs` + `.count` keys; the summary shape is for non-dry-run only.
test "--dry-run --json with empty Cellar keeps the dry-run shape" {
    resetOutput();
    const brew = try scratchDir("brew_dryjson_empty");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }
    const mt = try scratchDir("mt_dryjson_empty");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, mt) catch {};
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
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{"--dry-run"});

    const parsed = try parseAndCheck(buf.items);
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expect(root.get("dry_run").?.bool);
    try testing.expectEqual(@as(i64, 0), root.get("count").?.integer);
    try testing.expectEqual(@as(usize, 0), root.get("kegs").?.array.items.len);
    try testing.expect(root.get("counts") == null);
}

test "--json on an already-installed keg records it under skipped_installed" {
    resetOutput();
    const brew = try scratchDir("brew_json_inst");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }

    // ≤13-byte MALT_PREFIX — same Mach-O cap rationale as the sister test above.
    const mt_z: [:0]const u8 = "/tmp/mt_mj";
    test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, mt_z);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};

    try seedFakeBrew(brew, &.{"seeded"});

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{mt_z});
    defer testing.allocator.free(db_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);
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
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{});

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
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }
    const mt = try scratchDir("mt_stderr_dry");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, mt) catch {};
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
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{"--dry-run"});

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
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }
    const mt_z: [:0]const u8 = "/tmp/mt_si";
    test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, mt_z);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};

    try seedFakeBrew(brew, &.{"willbeskipped"});

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    // Pre-set the flag so the pre-loop check fires before any API hit.
    malt.signals.setInterruptedForTest(true);
    defer malt.signals.setInterruptedForTest(false);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    io_mod.beginStderrCapture(testing.allocator, &buf);
    defer io_mod.endStderrCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{});

    try testing.expect(containsLine(buf.items, "Interrupted before migration"));
    // Early-return must skip both per-keg success and final summary block.
    try testing.expect(!containsLine(buf.items, "willbeskipped migrated"));
    try testing.expect(!containsLine(buf.items, "Migration completed."));
}

// ── Cellar-entry filter ─────────────────────────────────────────────────

test "cellar scan ignores stray files and symlinks alongside keg directories" {
    resetOutput();
    const brew = try scratchDir("brew_filter");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }
    const mt = try scratchDir("mt_filter");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, mt) catch {};
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

    const f = try test_io.cwd().createFile(std.Options.debug_io, stray_file, .{});
    f.close(std.Options.debug_io);
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
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{"--dry-run"});

    const parsed = try parseAndCheck(buf.items);
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(@as(i64, 1), root.get("count").?.integer);
    const kegs = root.get("kegs").?.array;
    try testing.expectEqual(@as(usize, 1), kegs.items.len);
    try testing.expectEqualStrings("tree", kegs.items[0].string);
}

// ── Symlinked keg directories — picked up end-to-end ───────────────
//
// On-disk version of the unit-level symlink test: the Cellar contains
// one regular keg dir plus a symlink whose target is another keg dir
// living elsewhere on disk. Both must surface in `migrate --dry-run`.
test "cellar scan picks up a symlink whose target is a real keg directory" {
    resetOutput();
    const brew = try scratchDir("brew_symlink_keg");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }
    const mt = try scratchDir("mt_symlink_keg");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, mt) catch {};
        testing.allocator.free(mt);
    }
    const target_root = try scratchDir("brew_symlink_target");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, target_root) catch {};
        testing.allocator.free(target_root);
    }

    // One real keg in the Cellar plus a real keg dir outside it.
    try seedFakeBrew(brew, &.{"tree"});
    const linked_target = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/jq/1.0",
        .{target_root},
        0,
    );
    defer testing.allocator.free(linked_target);
    try test_io.cwd().createDirPath(std.Options.debug_io, linked_target);

    // Plant `Cellar/jq -> <target_root>/jq` (a symlink-to-directory).
    const cellar = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar", .{brew});
    defer testing.allocator.free(cellar);
    const link_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/jq", .{cellar}, 0);
    defer testing.allocator.free(link_path);
    const link_target = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/jq", .{target_root}, 0);
    defer testing.allocator.free(link_target);
    try testing.expectEqual(@as(c_int, 0), std.c.symlink(link_target.ptr, link_path.ptr));

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
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{"--dry-run"});

    const parsed = try parseAndCheck(buf.items);
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(@as(i64, 2), root.get("count").?.integer);
    const kegs = root.get("kegs").?.array;
    try testing.expectEqual(@as(usize, 2), kegs.items.len);
    // Iteration order is filesystem-defined; sort the surfaced names
    // for a stable comparison.
    var seen = [_][]const u8{ kegs.items[0].string, kegs.items[1].string };
    std.mem.sort([]const u8, &seen, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    try testing.expectEqualStrings("jq", seen[0]);
    try testing.expectEqualStrings("tree", seen[1]);
}

// ── Multi-keg mixed outcomes (skipped_installed + failed_api, offline) ──

test "mixed outcomes: installed keg is skipped and unknown keg fails at API (404-cached)" {
    resetOutput();
    const brew = try scratchDir("brew_mixed");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }

    const mt_z: [:0]const u8 = "/tmp/mt_mx";
    test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, mt_z);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};

    try seedFakeBrew(brew, &.{ "seeded", "unknownpkg" });

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    // Seed malt DB: one keg already "installed" to exercise the skip path.
    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{mt_z});
    defer testing.allocator.free(db_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);
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
    try test_io.cwd().createDirPath(std.Options.debug_io, cache_api);
    const marker = try std.fmt.allocPrint(testing.allocator, "{s}/formula_unknownpkg.404", .{cache_api});
    defer testing.allocator.free(marker);
    const mf = try test_io.cwd().createFile(std.Options.debug_io, marker, .{});
    mf.close(std.Options.debug_io);

    output.setMode(.json);
    defer resetOutput();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    io_mod.beginStdoutCapture(testing.allocator, &buf);
    defer io_mod.endStdoutCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{});

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
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }

    const mt_z: [:0]const u8 = "/tmp/mt_lk";
    test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, mt_z);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};

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
    try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);
    const lock_path = try std.fmt.allocPrint(testing.allocator, "{s}/malt.lock", .{db_dir});
    defer testing.allocator.free(lock_path);
    var holder = try malt.lock.LockFile.acquire(std.Options.debug_io, lock_path, 1000);
    defer holder.release(std.Options.debug_io);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try testing.expectError(
        error.Aborted,
        migrate.execute(&ctx, arena.allocator(), &.{}),
    );
}

test "already-installed stderr pins the 'Migration completed.' + 'Skipped (installed): 1' lines" {
    resetOutput();
    color.setForTest(false, false);
    defer color.setForTest(null, null);

    const brew = try scratchDir("brew_stderr_inst");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }

    const mt_z: [:0]const u8 = "/tmp/mt_ms";
    test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, mt_z);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};

    try seedFakeBrew(brew, &.{"seeded"});

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{mt_z});
    defer testing.allocator.free(db_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);
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
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{});

    try testing.expect(containsLine(buf.items, "Migration completed."));
    try testing.expect(containsLine(buf.items, "Migrated: 0"));
    try testing.expect(containsLine(buf.items, "Skipped (installed): 1"));
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
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }

    // ≤13-byte MALT_PREFIX — same Mach-O budget rationale as sister tests.
    const mt_z: [:0]const u8 = "/tmp/mt_nb";
    test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, mt_z);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};

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
    try test_io.cwd().createDirPath(std.Options.debug_io, cache_api);
    const cache_path = try std.fmt.allocPrint(testing.allocator, "{s}/formula_noplatform.json", .{cache_api});
    defer testing.allocator.free(cache_path);
    const cache_file = try test_io.cwd().createFile(std.Options.debug_io, cache_path, .{});
    defer cache_file.close(std.Options.debug_io);
    try cache_file.writeStreamingAll(std.Options.debug_io,
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
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{});

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

    pub fn next(self: *MockIter, io: std.Io) !?MockDirEntry {
        _ = io;
        if (self.fail_after) |n| if (self.idx == n) {
            self.idx += 1;
            return error.AccessDenied;
        };
        if (self.idx >= self.entries.len) return null;
        defer self.idx += 1;
        return self.entries[self.idx];
    }
};

// Fake `Dir` for unit tests of `scanCellarKegs`'s symlink-target stat.
// `scanCellarKegs` only reads `.kind` off the returned struct, so a
// minimal stand-in suffices and keeps the tests free of full `Stat`
// boilerplate. Names absent from `targets` resolve as `FileNotFound`,
// mirroring the dangling-symlink case.
const FakeStat = struct { kind: std.Io.File.Kind };

const MockDir = struct {
    targets: []const struct { name: []const u8, kind: std.Io.File.Kind } = &.{},

    pub fn statFile(
        self: MockDir,
        io: std.Io,
        name: []const u8,
        opts: anytype,
    ) !FakeStat {
        _ = io;
        _ = opts;
        for (self.targets) |t| {
            if (std.mem.eql(u8, t.name, name)) return .{ .kind = t.kind };
        }
        return error.FileNotFound;
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

    // Iterator yields only `.directory` entries here, so the fake dir's
    // `statFile` is never called - an empty `MockDir{}` is sufficient.
    try migrate.scanCellarKegs(std.Options.debug_io, arena.allocator(), &mock, MockDir{}, &names);

    try testing.expectEqual(@as(usize, 2), names.items.len);
    try testing.expectEqualStrings("tree", names.items[0]);
    try testing.expectEqualStrings("wget", names.items[1]);
    try testing.expect(containsLine(buf.items, "Cellar scan error"));
    try testing.expect(containsLine(buf.items, "AccessDenied"));
}

test "scanCellarKegs continues past a mid-scan iterator error" {
    resetOutput();
    color.setForTest(false, false);
    defer color.setForTest(null, null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var names: std.ArrayList([]const u8) = .empty;
    // Bad entry sits between two good ones; the loop must skip the bad
    // index and still surface the trailing keg instead of truncating.
    var mock = MockIter{
        .entries = &.{
            .{ .name = "tree", .kind = .directory },
            .{ .name = "wget", .kind = .directory },
            .{ .name = "ffmpeg", .kind = .directory },
        },
        .fail_after = 1,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    io_mod.beginStderrCapture(testing.allocator, &buf);
    defer io_mod.endStderrCapture();

    try migrate.scanCellarKegs(std.Options.debug_io, arena.allocator(), &mock, MockDir{}, &names);

    // tree precedes the error; ffmpeg follows it. The middle index that
    // returned `error.AccessDenied` is the only one missing.
    try testing.expectEqual(@as(usize, 2), names.items.len);
    try testing.expectEqualStrings("tree", names.items[0]);
    try testing.expectEqualStrings("ffmpeg", names.items[1]);
    try testing.expect(containsLine(buf.items, "Cellar scan error"));
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
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }

    const mt_z: [:0]const u8 = "/tmp/mt_rs";
    test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, mt_z);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};

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
    try test_io.cwd().createDirPath(std.Options.debug_io, cache_api);
    const marker = try std.fmt.allocPrint(testing.allocator, "{s}/formula_unknownpkg.404", .{cache_api});
    defer testing.allocator.free(marker);
    const mf = try test_io.cwd().createFile(std.Options.debug_io, marker, .{});
    mf.close(std.Options.debug_io);

    // Pre-seed a 404 for "alreadydone" too — if the manifest filter ever
    // breaks, the test still terminates offline (failed_api) instead of
    // hitting the network. The assertion still pins resume because we
    // expect skipped_installed, not failed_api.
    const marker2 = try std.fmt.allocPrint(testing.allocator, "{s}/formula_alreadydone.404", .{cache_api});
    defer testing.allocator.free(marker2);
    const mf2 = try test_io.cwd().createFile(std.Options.debug_io, marker2, .{});
    mf2.close(std.Options.debug_io);

    // Pre-seed the resume manifest with "alreadydone" *and* a matching
    // DB row — the resume short-circuit requires both to agree so a
    // stale manifest after `mt uninstall` doesn't silently skip a keg.
    const cache_dir = try std.fmt.allocPrint(testing.allocator, "{s}/cache", .{mt_z});
    defer testing.allocator.free(cache_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, cache_dir);
    var manifest = malt.cli_migrate_manifest.Manifest.init(testing.allocator);
    defer manifest.deinit();
    try manifest.add("alreadydone");
    const manifest_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/migrate.progress.json",
        .{cache_dir},
    );
    defer testing.allocator.free(manifest_path);
    try manifest.writeAtomic(std.Options.debug_io, testing.allocator, manifest_path);

    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{mt_z});
    defer testing.allocator.free(db_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);
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
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{});

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

// ── --parallel flag ────────────────────────────────────────────────
//
// `--parallel` activates the bounded worker pool. The flag must:
//   * never fail to parse (smoke for the new flag plumbing),
//   * not break dry-run (dry-run wins regardless of --parallel),
//   * preserve the resume contract (manifest entries still skipped),
//   * deliver the same outcomes as serial when no real network work
//     is needed (already-installed + manifest-skipped paths).

test "--parallel --dry-run lists kegs and never starts the pool" {
    resetOutput();
    const brew = try scratchDir("brew_par_dry");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }
    const mt = try scratchDir("mt_par_dry");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, mt) catch {};
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
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{ "--parallel", "--dry-run" });

    const parsed = try parseAndCheck(buf.items);
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expect(root.get("dry_run").?.bool);
    try testing.expectEqual(@as(i64, 2), root.get("count").?.integer);
}

test "--parallel sets the dispatch flag before falling through to skip-only paths" {
    resetOutput();
    defer migrate.last_run_parallel = false;

    const brew = try scratchDir("brew_par_dispatch");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }
    const mt_z: [:0]const u8 = "/tmp/mt_pd";
    test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, mt_z);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};

    try seedFakeBrew(brew, &.{"k"});

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    // Seed manifest so the only keg short-circuits, keeping the test offline.
    const cache_dir = try std.fmt.allocPrint(testing.allocator, "{s}/cache", .{mt_z});
    defer testing.allocator.free(cache_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, cache_dir);
    var manifest = malt.cli_migrate_manifest.Manifest.init(testing.allocator);
    defer manifest.deinit();
    try manifest.add("k");
    const manifest_path = try std.fmt.allocPrint(testing.allocator, "{s}/migrate.progress.json", .{cache_dir});
    defer testing.allocator.free(manifest_path);
    try manifest.writeAtomic(std.Options.debug_io, testing.allocator, manifest_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{ "--parallel", "--quiet" });

    try testing.expect(migrate.last_run_parallel);
}

test "without --parallel the dispatch flag stays false" {
    resetOutput();
    migrate.last_run_parallel = false;
    defer migrate.last_run_parallel = false;

    const brew = try scratchDir("brew_par_serial");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }
    const mt = try scratchDir("mt_par_serial");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, mt) catch {};
        testing.allocator.free(mt);
    }
    try seedFakeBrew(brew, &.{});

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{"--quiet"});

    try testing.expect(!migrate.last_run_parallel);
}

test "--parallel honours the resume manifest the same way serial does" {
    resetOutput();

    const brew = try scratchDir("brew_par_resume");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }

    const mt_z: [:0]const u8 = "/tmp/mt_pr";
    test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, mt_z);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};

    try seedFakeBrew(brew, &.{ "k1", "k2", "k3" });

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    // Seed 404 markers for every keg so any reach-the-API behaviour
    // terminates offline as failed_api rather than hanging the test.
    const cache_api = try std.fmt.allocPrint(testing.allocator, "{s}/cache/api", .{mt_z});
    defer testing.allocator.free(cache_api);
    try test_io.cwd().createDirPath(std.Options.debug_io, cache_api);
    inline for (.{ "k1", "k2", "k3" }) |name| {
        const m = try std.fmt.allocPrint(testing.allocator, "{s}/formula_{s}.404", .{ cache_api, name });
        defer testing.allocator.free(m);
        const f = try test_io.cwd().createFile(std.Options.debug_io, m, .{});
        f.close(std.Options.debug_io);
    }

    // Pre-seed all three kegs as completed in the resume manifest *and*
    // in the DB — the skip path requires both to agree (see
    // `cli/migrate.zig` stale-manifest note).
    const cache_dir = try std.fmt.allocPrint(testing.allocator, "{s}/cache", .{mt_z});
    defer testing.allocator.free(cache_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, cache_dir);
    var manifest = malt.cli_migrate_manifest.Manifest.init(testing.allocator);
    defer manifest.deinit();
    try manifest.add("k1");
    try manifest.add("k2");
    try manifest.add("k3");
    const manifest_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/migrate.progress.json",
        .{cache_dir},
    );
    defer testing.allocator.free(manifest_path);
    try manifest.writeAtomic(std.Options.debug_io, testing.allocator, manifest_path);

    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{mt_z});
    defer testing.allocator.free(db_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);
    const db_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/malt.db", .{db_dir}, 0);
    defer testing.allocator.free(db_path);
    var db_seed = try malt.sqlite.Database.open(db_path);
    try malt.schema.initSchema(&db_seed);
    inline for (.{ "k1", "k2", "k3" }) |name| {
        var s = try db_seed.prepare(
            \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path)
            \\VALUES (?, ?, ?, ?, ?);
        );
        try s.bindText(1, name);
        try s.bindText(2, name);
        try s.bindText(3, "1.0");
        try s.bindText(4, "0" ** 64);
        try s.bindText(5, "/tmp/mt_pr/Cellar/" ++ name ++ "/1.0");
        _ = try s.step();
        s.finalize();
    }
    db_seed.close();

    output.setMode(.json);
    defer resetOutput();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    io_mod.beginStdoutCapture(testing.allocator, &buf);
    defer io_mod.endStdoutCapture();

    // Cap workers low so a cold/empty pool still exercises the spawn path.
    _ = c.setenv("MALT_MIGRATE_PARALLEL_WORKERS", "2", 1);
    defer _ = c.unsetenv("MALT_MIGRATE_PARALLEL_WORKERS");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{"--parallel"});

    const parsed = try parseAndCheck(buf.items);
    defer parsed.deinit();
    const root = parsed.value.object;
    // All three kegs are recorded as already-completed via the manifest,
    // so workers never reach the API — failed_names stays empty.
    try testing.expectEqual(@as(usize, 3), root.get("skipped_installed").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), root.get("failed").?.array.items.len);
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
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }
    const mt_z: [:0]const u8 = "/tmp/mt_fn";
    test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, mt_z);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};

    try seedFakeBrew(brew, &.{"failkeg"});

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    const cache_api = try std.fmt.allocPrint(testing.allocator, "{s}/cache/api", .{mt_z});
    defer testing.allocator.free(cache_api);
    try test_io.cwd().createDirPath(std.Options.debug_io, cache_api);
    const marker = try std.fmt.allocPrint(testing.allocator, "{s}/formula_failkeg.404", .{cache_api});
    defer testing.allocator.free(marker);
    const mf = try test_io.cwd().createFile(std.Options.debug_io, marker, .{});
    mf.close(std.Options.debug_io);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{"--quiet"});

    // Manifest must either not exist or contain zero entries — the 404
    // path returned `.failed_api`, never `.migrated`.
    const manifest_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/cache/migrate.progress.json",
        .{mt_z},
    );
    defer testing.allocator.free(manifest_path);
    var loaded = try malt.cli_migrate_manifest.loadFromPath(&malt.app_ctx.debug_ctx, testing.allocator, manifest_path);
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
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }
    const mt_z: [:0]const u8 = "/tmp/mt_pv";
    test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, mt_z);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};

    // The Cellar contains the pre-seeded keg + a new one that 404s.
    try seedFakeBrew(brew, &.{ "old", "newfail" });

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    const cache_api = try std.fmt.allocPrint(testing.allocator, "{s}/cache/api", .{mt_z});
    defer testing.allocator.free(cache_api);
    try test_io.cwd().createDirPath(std.Options.debug_io, cache_api);
    const marker = try std.fmt.allocPrint(testing.allocator, "{s}/formula_newfail.404", .{cache_api});
    defer testing.allocator.free(marker);
    const mf = try test_io.cwd().createFile(std.Options.debug_io, marker, .{});
    mf.close(std.Options.debug_io);

    const cache_dir = try std.fmt.allocPrint(testing.allocator, "{s}/cache", .{mt_z});
    defer testing.allocator.free(cache_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, cache_dir);
    const manifest_path = try std.fmt.allocPrint(testing.allocator, "{s}/migrate.progress.json", .{cache_dir});
    defer testing.allocator.free(manifest_path);

    var seed = malt.cli_migrate_manifest.Manifest.init(testing.allocator);
    defer seed.deinit();
    try seed.add("old");
    try seed.writeAtomic(std.Options.debug_io, testing.allocator, manifest_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{"--quiet"});

    var loaded = try malt.cli_migrate_manifest.loadFromPath(&malt.app_ctx.debug_ctx, testing.allocator, manifest_path);
    defer loaded.deinit();
    try testing.expect(loaded.contains("old"));
    try testing.expect(!loaded.contains("newfail"));
}

// `MALT_MIGRATE_PARALLEL_WORKERS` parses correctly in unit tests, but
// the live-env path goes through `workerCountFromLiveEnv` — wire it
// up here so a future refactor that broke the env name would fail.

// Stale manifest (post-uninstall) must not silently skip a keg the user
// expects to be re-migrated. Pre-seed the manifest with "ghost" but
// leave the DB empty + 404-mark the formula. Pre-PR semantics would
// have skipped silently; the DB cross-check forces a real attempt
// (which 404s offline → `failed`), proving we did NOT short-circuit.

test "stale manifest after uninstall falls through to a real migrate" {
    resetOutput();

    const brew = try scratchDir("brew_stale");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }
    const mt_z: [:0]const u8 = "/tmp/mt_st";
    test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, mt_z);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};

    try seedFakeBrew(brew, &.{"ghost"});

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    const cache_api = try std.fmt.allocPrint(testing.allocator, "{s}/cache/api", .{mt_z});
    defer testing.allocator.free(cache_api);
    try test_io.cwd().createDirPath(std.Options.debug_io, cache_api);
    const marker = try std.fmt.allocPrint(testing.allocator, "{s}/formula_ghost.404", .{cache_api});
    defer testing.allocator.free(marker);
    const mf = try test_io.cwd().createFile(std.Options.debug_io, marker, .{});
    mf.close(std.Options.debug_io);

    // Manifest claims "ghost" was migrated; DB is empty (simulating uninstall).
    const cache_dir = try std.fmt.allocPrint(testing.allocator, "{s}/cache", .{mt_z});
    defer testing.allocator.free(cache_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, cache_dir);
    var stale = malt.cli_migrate_manifest.Manifest.init(testing.allocator);
    defer stale.deinit();
    try stale.add("ghost");
    const manifest_path = try std.fmt.allocPrint(testing.allocator, "{s}/migrate.progress.json", .{cache_dir});
    defer testing.allocator.free(manifest_path);
    try stale.writeAtomic(std.Options.debug_io, testing.allocator, manifest_path);

    output.setMode(.json);
    defer resetOutput();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    io_mod.beginStdoutCapture(testing.allocator, &buf);
    defer io_mod.endStdoutCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{});

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
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }
    const mt_z: [:0]const u8 = "/tmp/mt_hl";
    test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, mt_z);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};

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
    try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);
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
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{"--quiet"});

    // Manifest now exists on disk and contains the keg the DB had —
    // future runs hit the cheap manifest short-circuit instead of the
    // DB lookup. Pin both: file load works, and the entry is there.
    const manifest_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/cache/migrate.progress.json",
        .{mt_z},
    );
    defer testing.allocator.free(manifest_path);
    var loaded = try malt.cli_migrate_manifest.loadFromPath(&malt.app_ctx.debug_ctx, testing.allocator, manifest_path);
    defer loaded.deinit();
    try testing.expect(loaded.contains("recovered"));
}

test "MALT_MIGRATE_PARALLEL_WORKERS env wires through to the live helper" {
    // Rebuild the ctx after each setenv: `std.c.environ` may relocate on
    // mutation, so a snapshot taken once at the top of the test would
    // dereference freed slots.
    _ = c.setenv("MALT_MIGRATE_PARALLEL_WORKERS", "7", 1);
    defer _ = c.unsetenv("MALT_MIGRATE_PARALLEL_WORKERS");
    {
        const ctx: malt.app_ctx.AppCtx = .{ .io = std.Options.debug_io, .environ = malt.app_ctx.processEnviron() };
        try testing.expectEqual(@as(u32, 7), malt.cli_migrate_parallel.workerCountFromLiveEnv(&ctx));
    }

    _ = c.setenv("MALT_MIGRATE_PARALLEL_WORKERS", "9999", 1);
    {
        const ctx: malt.app_ctx.AppCtx = .{ .io = std.Options.debug_io, .environ = malt.app_ctx.processEnviron() };
        try testing.expectEqual(
            malt.cli_migrate_parallel.max_workers,
            malt.cli_migrate_parallel.workerCountFromLiveEnv(&ctx),
        );
    }

    _ = c.unsetenv("MALT_MIGRATE_PARALLEL_WORKERS");
    {
        const ctx: malt.app_ctx.AppCtx = .{ .io = std.Options.debug_io, .environ = malt.app_ctx.processEnviron() };
        try testing.expectEqual(
            malt.cli_migrate_parallel.default_workers,
            malt.cli_migrate_parallel.workerCountFromLiveEnv(&ctx),
        );
    }
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

    // Error swallows the .DS_Store slot (idx 0); the loop must keep
    // going so the trailing keg "tree" still lands in the result.
    try migrate.scanCellarKegs(std.Options.debug_io, arena.allocator(), &mock, MockDir{}, &names);
    try testing.expectEqual(@as(usize, 1), names.items.len);
    try testing.expectEqualStrings("tree", names.items[0]);
    try testing.expect(containsLine(buf.items, "Cellar scan error"));
}

// ── Symlink-to-directory entries are valid kegs ─────────────────────
//
// Real Homebrew Cellars sometimes contain symlinks to keg directories
// (arch transitions, multi-prefix coexistence, scratch fixtures).
// `.sym_link` triggers a target stat and is accepted iff the resolved
// target is itself a directory; everything else falls through.

test "scanCellarKegs accepts a symlink whose target is a directory" {
    resetOutput();
    color.setForTest(false, false);
    defer color.setForTest(null, null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var names: std.ArrayList([]const u8) = .empty;
    var mock = MockIter{ .entries = &.{
        .{ .name = "tree", .kind = .directory },
        .{ .name = "jq-link", .kind = .sym_link },
    } };
    const dir = MockDir{ .targets = &.{
        .{ .name = "jq-link", .kind = .directory },
    } };

    try migrate.scanCellarKegs(std.Options.debug_io, arena.allocator(), &mock, dir, &names);

    try testing.expectEqual(@as(usize, 2), names.items.len);
    try testing.expectEqualStrings("tree", names.items[0]);
    try testing.expectEqualStrings("jq-link", names.items[1]);
}

test "scanCellarKegs skips a symlink whose target is a regular file" {
    resetOutput();
    color.setForTest(false, false);
    defer color.setForTest(null, null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var names: std.ArrayList([]const u8) = .empty;
    var mock = MockIter{ .entries = &.{
        .{ .name = "alias-to-readme", .kind = .sym_link },
    } };
    // Target resolves but is `.file`, so it must not be treated as a keg.
    const dir = MockDir{ .targets = &.{
        .{ .name = "alias-to-readme", .kind = .file },
    } };

    try migrate.scanCellarKegs(std.Options.debug_io, arena.allocator(), &mock, dir, &names);
    try testing.expectEqual(@as(usize, 0), names.items.len);
}

test "scanCellarKegs skips a dangling symlink (statFile fails)" {
    resetOutput();
    color.setForTest(false, false);
    defer color.setForTest(null, null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var names: std.ArrayList([]const u8) = .empty;
    var mock = MockIter{ .entries = &.{
        .{ .name = "dangling", .kind = .sym_link },
        .{ .name = "wget", .kind = .directory },
    } };
    // Empty `targets` so `statFile` returns FileNotFound — same path
    // a real dangling symlink takes. The directory entry after it must
    // still be collected; one bad symlink can't poison the whole scan.
    const dir = MockDir{};

    try migrate.scanCellarKegs(std.Options.debug_io, arena.allocator(), &mock, dir, &names);
    try testing.expectEqual(@as(usize, 1), names.items.len);
    try testing.expectEqualStrings("wget", names.items[0]);
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
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }
    const mt = try scratchDir("mt_noleak");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, mt) catch {};
        testing.allocator.free(mt);
    }
    try seedFakeBrew(brew, &.{ "tree", "wget", "jq", "ffmpeg" });

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, testing.allocator, &.{ "--dry-run", "--quiet" });
}

// ── Tap-fallback post_install execution ─────────────────────────────────
//
// migrateFromLocalCellar runs when the brew API has no record of a keg
// (private/third-party tap). Tap kegs aren't reachable from the bottle
// DSL pipeline's locator, so the fallback resolves the body straight
// off the tap's `<name>.rb` and feeds it to the same DSL +
// FallbackLog → outcome routing the install path uses. A trivially-
// empty body should land on the "completed" branch.

test "tap fallback runs the DSL post_install body and reports completion" {
    resetOutput();
    color.setForTest(false, false);
    defer color.setForTest(null, null);

    const brew = try scratchDir("brew_tap_pi");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }

    // ≤13 bytes — same Mach-O patching budget the sister tests rely on.
    const mt_z: [:0]const u8 = "/tmp/mt_tpi";
    test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, mt_z);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    // Source Cellar keg dir + receipt with non-core tap so the fallback
    // accepts the local copy and source.path so we exercise the receipt
    // branch in findTapFormulaRb. Body is a no-op so the DSL run lands
    // cleanly on the "completed" branch.
    const tap_rb = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/Library/Taps/owner/homebrew-tap/Formula/g/glow.rb",
        .{brew},
    );
    defer testing.allocator.free(tap_rb);
    const tap_dir = std.fs.path.dirname(tap_rb).?;
    try test_io.cwd().createDirPath(std.Options.debug_io, tap_dir);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, tap_rb, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io,
            \\class Glow < Formula
            \\  url "x"
            \\  def post_install
            \\    # no-op; pins the completed-DSL outcome path
            \\  end
            \\end
            \\
        );
    }

    const keg_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/glow/0.2.2", .{brew});
    defer testing.allocator.free(keg_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, keg_dir);
    const receipt_path = try std.fmt.allocPrint(testing.allocator, "{s}/INSTALL_RECEIPT.json", .{keg_dir});
    defer testing.allocator.free(receipt_path);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, receipt_path, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        const body = try std.fmt.allocPrint(
            testing.allocator,
            "{{\"source\":{{\"tap\":\"owner/tap\",\"path\":\"{s}\",\"versions\":{{\"stable\":\"0.2.2\"}}}}}}",
            .{tap_rb},
        );
        defer testing.allocator.free(body);
        try f.writeStreamingAll(std.Options.debug_io, body);
    }

    // 404 marker forces fetchFormula → error.NotFound, routing the keg
    // into the local-Cellar fallback offline.
    const cache_api = try std.fmt.allocPrint(testing.allocator, "{s}/cache/api", .{mt_z});
    defer testing.allocator.free(cache_api);
    try test_io.cwd().createDirPath(std.Options.debug_io, cache_api);
    const marker = try std.fmt.allocPrint(testing.allocator, "{s}/formula_glow.404", .{cache_api});
    defer testing.allocator.free(marker);
    (try test_io.createFileAbsolute(std.Options.debug_io, marker, .{})).close(std.Options.debug_io);

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(testing.allocator);
    io_mod.beginStderrCapture(testing.allocator, &stderr_buf);
    defer io_mod.endStderrCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{});

    try testing.expect(containsLine(stderr_buf.items, "post_install completed for glow"));
    try testing.expect(!containsLine(stderr_buf.items, "post_install partially skipped"));
}

test "tap fallback partial-DSL emits the --use-system-ruby hint same as install" {
    resetOutput();
    color.setForTest(false, false);
    defer color.setForTest(null, null);

    const brew = try scratchDir("brew_tap_partial");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }

    const mt_z: [:0]const u8 = "/tmp/mt_tpp";
    test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, mt_z);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    // Body calls a helper the DSL doesn't speak — FallbackLog records
    // unknown_method, router downgrades to "partially skipped".
    const tap_rb = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/Library/Taps/owner/homebrew-tap/Formula/g/gizmo.rb",
        .{brew},
    );
    defer testing.allocator.free(tap_rb);
    const tap_dir = std.fs.path.dirname(tap_rb).?;
    try test_io.cwd().createDirPath(std.Options.debug_io, tap_dir);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, tap_rb, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io,
            \\class Gizmo < Formula
            \\  url "x"
            \\  def post_install
            \\    not_a_dsl_helper(prefix)
            \\  end
            \\end
            \\
        );
    }

    const keg_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/gizmo/1.0", .{brew});
    defer testing.allocator.free(keg_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, keg_dir);
    const receipt_path = try std.fmt.allocPrint(testing.allocator, "{s}/INSTALL_RECEIPT.json", .{keg_dir});
    defer testing.allocator.free(receipt_path);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, receipt_path, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        const body = try std.fmt.allocPrint(
            testing.allocator,
            "{{\"source\":{{\"tap\":\"owner/tap\",\"path\":\"{s}\",\"versions\":{{\"stable\":\"1.0\"}}}}}}",
            .{tap_rb},
        );
        defer testing.allocator.free(body);
        try f.writeStreamingAll(std.Options.debug_io, body);
    }

    const cache_api = try std.fmt.allocPrint(testing.allocator, "{s}/cache/api", .{mt_z});
    defer testing.allocator.free(cache_api);
    try test_io.cwd().createDirPath(std.Options.debug_io, cache_api);
    const marker = try std.fmt.allocPrint(testing.allocator, "{s}/formula_gizmo.404", .{cache_api});
    defer testing.allocator.free(marker);
    (try test_io.createFileAbsolute(std.Options.debug_io, marker, .{})).close(std.Options.debug_io);

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(testing.allocator);
    io_mod.beginStderrCapture(testing.allocator, &stderr_buf);
    defer io_mod.endStderrCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{});

    try testing.expect(containsLine(stderr_buf.items, "post_install partially skipped"));
    try testing.expect(containsLine(stderr_buf.items, "use --use-system-ruby=gizmo"));
}

test "tap fallback stays silent when the tap formula has no post_install" {
    resetOutput();
    color.setForTest(false, false);
    defer color.setForTest(null, null);

    const brew = try scratchDir("brew_tap_no_pi");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }

    const mt_z: [:0]const u8 = "/tmp/mt_tnp";
    test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, mt_z);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    const tap_rb = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/Library/Taps/owner/homebrew-tap/Formula/q/quiet.rb",
        .{brew},
    );
    defer testing.allocator.free(tap_rb);
    const tap_dir = std.fs.path.dirname(tap_rb).?;
    try test_io.cwd().createDirPath(std.Options.debug_io, tap_dir);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, tap_rb, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io,
            \\class Quiet < Formula
            \\  url "x"
            \\end
            \\
        );
    }

    const keg_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/quiet/1.0", .{brew});
    defer testing.allocator.free(keg_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, keg_dir);
    const receipt_path = try std.fmt.allocPrint(testing.allocator, "{s}/INSTALL_RECEIPT.json", .{keg_dir});
    defer testing.allocator.free(receipt_path);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, receipt_path, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        const body = try std.fmt.allocPrint(
            testing.allocator,
            "{{\"source\":{{\"tap\":\"owner/tap\",\"path\":\"{s}\",\"versions\":{{\"stable\":\"1.0\"}}}}}}",
            .{tap_rb},
        );
        defer testing.allocator.free(body);
        try f.writeStreamingAll(std.Options.debug_io, body);
    }

    const cache_api = try std.fmt.allocPrint(testing.allocator, "{s}/cache/api", .{mt_z});
    defer testing.allocator.free(cache_api);
    try test_io.cwd().createDirPath(std.Options.debug_io, cache_api);
    const marker = try std.fmt.allocPrint(testing.allocator, "{s}/formula_quiet.404", .{cache_api});
    defer testing.allocator.free(marker);
    (try test_io.createFileAbsolute(std.Options.debug_io, marker, .{})).close(std.Options.debug_io);

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(testing.allocator);
    io_mod.beginStderrCapture(testing.allocator, &stderr_buf);
    defer io_mod.endStderrCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{});

    // No body in the .rb means no DSL run and no router output for this
    // keg — the absence of every post_install line is the contract.
    try testing.expect(!containsLine(stderr_buf.items, "post_install"));
}

// ── Renamed/aliased homebrew/core keg migrates from the local copy ──────
//
// A core keg whose name 404s on the brew API (renamed/aliased upstream, e.g.
// `sdl2` → alias of `sdl2-compat`) is still installed locally. A clean 404 is
// not an API outage — outages surface as ApiUnreachable and never reach the
// fallback — so the locally-installed keg is the authoritative artifact and
// must migrate, not be reported as a failure.

test "renamed homebrew/core keg migrates from the local Cellar copy" {
    resetOutput();
    const brew = try scratchDir("brew_core_renamed");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }

    const mt_z: [:0]const u8 = "/tmp/mt_core_renamed";
    test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, mt_z);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    // Core keg present locally with a receipt; no tap .rb (core kegs carry none).
    const keg_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/widget/2.0", .{brew});
    defer testing.allocator.free(keg_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, keg_dir);
    const receipt_path = try std.fmt.allocPrint(testing.allocator, "{s}/INSTALL_RECEIPT.json", .{keg_dir});
    defer testing.allocator.free(receipt_path);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, receipt_path, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io,
            \\{"source":{"tap":"homebrew/core","versions":{"stable":"2.0"}}}
        );
    }

    // 404 marker → fetchFormula returns NotFound offline, routing to the fallback.
    const cache_api = try std.fmt.allocPrint(testing.allocator, "{s}/cache/api", .{mt_z});
    defer testing.allocator.free(cache_api);
    try test_io.cwd().createDirPath(std.Options.debug_io, cache_api);
    const marker = try std.fmt.allocPrint(testing.allocator, "{s}/formula_widget.404", .{cache_api});
    defer testing.allocator.free(marker);
    (try test_io.createFileAbsolute(std.Options.debug_io, marker, .{})).close(std.Options.debug_io);

    output.setMode(.json);
    defer resetOutput();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    io_mod.beginStdoutCapture(testing.allocator, &buf);
    defer io_mod.endStdoutCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{});

    const parsed = try parseAndCheck(buf.items);
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(@as(usize, 1), root.get("migrated").?.array.items.len);
    try testing.expectEqualStrings("widget", root.get("migrated").?.array.items[0].string);
    try testing.expectEqual(@as(usize, 0), root.get("failed").?.array.items.len);
}

test "core keg with a malformed receipt still fails after the core guard is gone" {
    resetOutput();
    const brew = try scratchDir("brew_core_bad_receipt");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }

    const mt_z: [:0]const u8 = "/tmp/mt_core_badrcpt";
    test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, mt_z);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    const keg_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/widget/2.0", .{brew});
    defer testing.allocator.free(keg_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, keg_dir);
    const receipt_path = try std.fmt.allocPrint(testing.allocator, "{s}/INSTALL_RECEIPT.json", .{keg_dir});
    defer testing.allocator.free(receipt_path);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, receipt_path, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "{ not json");
    }

    const cache_api = try std.fmt.allocPrint(testing.allocator, "{s}/cache/api", .{mt_z});
    defer testing.allocator.free(cache_api);
    try test_io.cwd().createDirPath(std.Options.debug_io, cache_api);
    const marker = try std.fmt.allocPrint(testing.allocator, "{s}/formula_widget.404", .{cache_api});
    defer testing.allocator.free(marker);
    (try test_io.createFileAbsolute(std.Options.debug_io, marker, .{})).close(std.Options.debug_io);

    output.setMode(.json);
    defer resetOutput();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    io_mod.beginStdoutCapture(testing.allocator, &buf);
    defer io_mod.endStdoutCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    try migrate.execute(&ctx, arena.allocator(), &.{});

    const parsed = try parseAndCheck(buf.items);
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(@as(usize, 0), root.get("migrated").?.array.items.len);
    try testing.expectEqual(@as(usize, 1), root.get("failed").?.array.items.len);
    try testing.expectEqualStrings("widget", root.get("failed").?.array.items[0].string);
}

// ── post_install drain runs only after every keg's linkOpt ──────────────
//
// Two kegs migrate via the parallel pool; each tap formula's post_install
// drops a marker into its own Cellar prefix only when the OTHER keg's
// `opt/<name>` symlink is already on disk. Both markers can only land if
// drain fires once — after every worker has joined and called `linkOpt`
// — instead of from per-worker scope. This pins the invariant
// `scripts/smokes/smoke_migrate_parallel.sh` exercises against real
// fontconfig+gettext, but inside `zig build test`.
test "post_install drain fires after every keg's linkOpt has run" {
    resetOutput();
    color.setForTest(false, false);
    defer color.setForTest(null, null);

    const brew = try scratchDir("brew_drain");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, brew) catch {};
        testing.allocator.free(brew);
    }

    // Mach-O patching budget: ≤13 bytes for the prefix path.
    const mt_z: [:0]const u8 = "/tmp/mt_drn";
    test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, mt_z);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, mt_z) catch {};

    try setenvZ("HOMEBREW_PREFIX", brew);
    defer _ = c.unsetenv("HOMEBREW_PREFIX");
    _ = c.setenv("MALT_PREFIX", mt_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    const formulas = [_]struct { name: []const u8, peer: []const u8 }{
        .{ .name = "alpha", .peer = "bravo" },
        .{ .name = "bravo", .peer = "alpha" },
    };

    for (formulas) |f| {
        const tap_rb = try std.fmt.allocPrint(
            testing.allocator,
            "{s}/Library/Taps/owner/homebrew-tap/Formula/{c}/{s}.rb",
            .{ brew, f.name[0], f.name },
        );
        defer testing.allocator.free(tap_rb);
        const tap_dir = std.fs.path.dirname(tap_rb).?;
        try test_io.cwd().createDirPath(std.Options.debug_io, tap_dir);
        {
            // Marker lands inside `prefix/` (the keg's own Cellar dir),
            // which sandbox.validatePath always allows. Conditional on
            // the peer's opt/ symlink so its presence proves drain
            // observed both linkOpts before firing the hook.
            const body = try std.fmt.allocPrint(testing.allocator,
                \\class {c}{s} < Formula
                \\  url "x"
                \\  def post_install
                \\    if File.exist?(Formula["{s}"])
                \\      touch prefix/"saw_peer.marker"
                \\    end
                \\  end
                \\end
                \\
            , .{
                std.ascii.toUpper(f.name[0]),
                f.name[1..],
                f.peer,
            });
            defer testing.allocator.free(body);
            const file = try test_io.createFileAbsolute(std.Options.debug_io, tap_rb, .{ .truncate = true });
            defer file.close(std.Options.debug_io);
            try file.writeStreamingAll(std.Options.debug_io, body);
        }

        const keg_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/{s}/1.0", .{ brew, f.name });
        defer testing.allocator.free(keg_dir);
        try test_io.cwd().createDirPath(std.Options.debug_io, keg_dir);
        const receipt_path = try std.fmt.allocPrint(testing.allocator, "{s}/INSTALL_RECEIPT.json", .{keg_dir});
        defer testing.allocator.free(receipt_path);
        {
            const receipt = try std.fmt.allocPrint(
                testing.allocator,
                "{{\"source\":{{\"tap\":\"owner/tap\",\"path\":\"{s}\",\"versions\":{{\"stable\":\"1.0\"}}}}}}",
                .{tap_rb},
            );
            defer testing.allocator.free(receipt);
            const file = try test_io.createFileAbsolute(std.Options.debug_io, receipt_path, .{ .truncate = true });
            defer file.close(std.Options.debug_io);
            try file.writeStreamingAll(std.Options.debug_io, receipt);
        }

        const cache_api = try std.fmt.allocPrint(testing.allocator, "{s}/cache/api", .{mt_z});
        defer testing.allocator.free(cache_api);
        try test_io.cwd().createDirPath(std.Options.debug_io, cache_api);
        const marker = try std.fmt.allocPrint(testing.allocator, "{s}/formula_{s}.404", .{ cache_api, f.name });
        defer testing.allocator.free(marker);
        (try test_io.createFileAbsolute(std.Options.debug_io, marker, .{})).close(std.Options.debug_io);
    }

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(testing.allocator);
    io_mod.beginStderrCapture(testing.allocator, &stderr_buf);
    defer io_mod.endStderrCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    // `--parallel` routes post_install through the shared queue and
    // exercises the drain-after-linkOpt invariant. Sequential mode runs
    // each post_install inline, so the bug case can't even arise there.
    try migrate.execute(&ctx, arena.allocator(), &.{"--parallel"});

    for (formulas) |f| {
        const marker_path = try std.fmt.allocPrint(
            testing.allocator,
            "{s}/Cellar/{s}/1.0/saw_peer.marker",
            .{ mt_z, f.name },
        );
        defer testing.allocator.free(marker_path);
        std.Io.Dir.cwd().access(std.Options.debug_io, marker_path, .{}) catch {
            std.debug.panic("post_install for {s} did not observe peer's opt/ symlink at drain time", .{f.name});
        };
    }
    try testing.expect(containsLine(stderr_buf.items, "post_install completed for alpha"));
    try testing.expect(containsLine(stderr_buf.items, "post_install completed for bravo"));
}
