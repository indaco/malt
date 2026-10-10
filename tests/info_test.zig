//! malt — info command integration tests
//!
//! Integration coverage that needs real side effects: the `openDb`
//! filesystem behaviour (a prefix with/without a `db/` dir) and the
//! DB-backed dependency read. The pure encoder unit tests live inline in
//! `src/cli/info.zig`.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");
const info = malt.cli_info;
const sqlite = malt.sqlite;
const schema = malt.schema;
const output = malt.output;
const color = malt.color;

const c = test_io.c;

/// Scratch tree under a process-unique base, so overlapping test runs cannot
/// wipe each other's fixtures.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    base: [:0]const u8,

    fn init(tag: []const u8) !Fixture {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const base = try test_io.uniqueTempPath(arena.allocator(), "info", tag);
        const base_z = try arena.allocator().dupeZ(u8, base);
        test_io.deleteTreeAbsolute(std.Options.debug_io, base_z) catch {};
        try test_io.cwd().createDirPath(std.Options.debug_io, base_z);
        return .{ .arena = arena, .base = base_z };
    }

    /// Absolute path to `sub` inside the fixture; valid until `deinit`.
    fn p(self: *Fixture, sub: []const u8) [:0]const u8 {
        return std.fmt.allocPrintSentinel(
            self.arena.allocator(),
            "{s}/{s}",
            .{ self.base, sub },
            0,
        ) catch @panic("OOM");
    }

    fn deinit(self: *Fixture) void {
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.base) catch {};
        self.arena.deinit();
    }
};

test "openDb returns null when the prefix has no db/ directory" {
    // Fresh prefix with no db/ subdir at all — SQLite's OPEN_CREATE
    // cannot create intermediate dirs, so the open must fail and
    // the helper must turn that into a null instead of an error.
    var fx = try Fixture.init("missing_db");
    defer fx.deinit();

    try testing.expect(info.openDb(std.Options.debug_io, fx.base, false) == null);
}

test "openDb succeeds and returns a usable handle when db/ exists" {
    var fx = try Fixture.init("ok_db");
    defer fx.deinit();
    try test_io.makeDirAbsolute(std.Options.debug_io, fx.p("db"));

    var db = info.openDb(std.Options.debug_io, fx.base, false) orelse return error.ExpectedDatabase;
    defer db.close();
}

test "openDb returns null when the prefix itself does not exist" {
    // A completely absent prefix path — typical when MALT_PREFIX is
    // pointed at a freshly-minted directory that hasn't been
    // populated by any malt command yet.
    const prefix = try test_io.uniqueTempPath(testing.allocator, "info", "no_prefix_at_all");
    defer testing.allocator.free(prefix);
    try testing.expect(info.openDb(std.Options.debug_io, prefix, false) == null);
}

// --- openInstallDb: only a missing db/ is a fresh prefix ----------------

fn expectRefused(prefix: []const u8) !void {
    var err_buf: std.ArrayList(u8) = .empty;
    defer err_buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &err_buf);
    defer output.endStderrCapture();
    try testing.expectError(error.Aborted, info.openInstallDb(std.Options.debug_io, prefix));
    try testing.expect(std.mem.indexOf(u8, err_buf.items, "could not open the install database") != null);
}

test "openInstallDb reads a prefix with no db/ directory as empty" {
    var fx = try Fixture.init("install_db_absent");
    defer fx.deinit();
    try testing.expect(try info.openInstallDb(std.Options.debug_io, fx.base) == null);
}

test "openInstallDb creates the database when db/ exists but the file does not" {
    var fx = try Fixture.init("install_db_dir_only");
    defer fx.deinit();
    try test_io.makeDirAbsolute(std.Options.debug_io, fx.p("db"));
    var db = (try info.openInstallDb(std.Options.debug_io, fx.base)) orelse return error.ExpectedDatabase;
    db.close();
}

test "openInstallDb refuses a file that exists but is not a database" {
    var fx = try Fixture.init("install_db_garbage");
    defer fx.deinit();
    try test_io.makeDirAbsolute(std.Options.debug_io, fx.p("db"));
    const f = try test_io.createFileAbsolute(std.Options.debug_io, fx.p("db/malt.db"), .{ .truncate = true });
    defer f.close(std.Options.debug_io);
    try f.writeStreamingAll(std.Options.debug_io, "not a sqlite database, just garbage bytes" ** 4);
    try expectRefused(fx.base);
}

test "openInstallDb refuses a db that is a file where the directory should be" {
    // ENOTDIR reads as "not found" to a probe of the file path itself.
    var fx = try Fixture.init("install_db_notdir");
    defer fx.deinit();
    const f = try test_io.createFileAbsolute(std.Options.debug_io, fx.p("db"), .{});
    f.close(std.Options.debug_io);
    try expectRefused(fx.base);
}

test "openInstallDb refuses a db/ directory it cannot look into" {
    if (std.c.geteuid() == 0) return error.SkipZigTest; // root bypasses the perm wall
    var fx = try Fixture.init("install_db_walled");
    defer fx.deinit();
    try test_io.makeDirAbsolute(std.Options.debug_io, fx.p("db"));
    const walled = try test_io.wallDir(std.Options.debug_io, fx.p("db"));
    defer test_io.unwallDir(std.Options.debug_io, walled);
    try expectRefused(fx.base);
}

test "openInstallDb refuses a db/ symlink whose target is gone" {
    // e.g. db/ on a volume that is not mounted: not a fresh prefix.
    var fx = try Fixture.init("install_db_dangling");
    defer fx.deinit();
    try test_io.symLinkAbsolute(std.Options.debug_io, "/nonexistent/malt-db", fx.p("db"), .{});
    try expectRefused(fx.base);
}

test "openInstallDb refuses a prefix that is a file" {
    var fx = try Fixture.init("install_db_prefix_file");
    defer fx.deinit();
    const f = try test_io.createFileAbsolute(std.Options.debug_io, fx.p("prefix"), .{});
    f.close(std.Options.debug_io);
    try expectRefused(fx.p("prefix"));
}

test "openInstallDb refuses a prefix too long to hold the database path" {
    // Silently reading an unbuildable path as "no db/" would hide every
    // install under it.
    const long_prefix = "/" ++ "p" ** malt.prefix_path.path_buf_len;
    var err_buf: std.ArrayList(u8) = .empty;
    defer err_buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &err_buf);
    defer output.endStderrCapture();
    try testing.expectError(error.Aborted, info.openInstallDb(std.Options.debug_io, long_prefix));
    try testing.expect(std.mem.indexOf(u8, err_buf.items, "install database") != null);
}

// --- collectInstalledDeps: DB-backed dependency read --------------------
//
// The detail pane must read an installed keg's deps from the recorded
// `dependencies` table — offline, no network re-resolve. These tests
// build a tiny kegs+dependencies fixture and pin the caller-observable
// list, including the empty-deps and not-installed edges.

/// The db lives inside `fx` so `fx.deinit()` takes the `-wal`/`-shm`
/// siblings with it. Close the returned db before the fixture goes.
fn makeDepsDb(fx: *Fixture) !sqlite.Database {
    var db = try sqlite.Database.open(fx.p("deps.db"));
    try schema.initSchema(&db);
    return db;
}

fn insertKegRow(db: *sqlite.Database, name: []const u8) !i64 {
    var stmt = try db.prepare(
        "INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path)" ++
            " VALUES (?1, ?1, '1.0', ?1, '/tmp/cellar') RETURNING id;",
    );
    defer stmt.finalize();
    try stmt.bindText(1, name);
    _ = try stmt.step();
    return stmt.columnInt(0);
}

fn addDepRow(db: *sqlite.Database, keg_id: i64, dep_name: []const u8) !void {
    var stmt = try db.prepare(
        "INSERT INTO dependencies (keg_id, dep_name) VALUES (?1, ?2);",
    );
    defer stmt.finalize();
    try stmt.bindInt(1, keg_id);
    try stmt.bindText(2, dep_name);
    _ = try stmt.step();
}

fn freeDepsSlice(deps: []const []const u8) void {
    for (deps) |d| testing.allocator.free(d);
    testing.allocator.free(deps);
}

test "collectInstalledDeps reads a fixture keg's recorded deps, alphabetised" {
    var fx = try Fixture.init("deps_populated");
    defer fx.deinit(); // runs after db.close(): LIFO
    var db = try makeDepsDb(&fx);
    defer db.close();

    // Insert deps out of order to prove the reader sorts rather than
    // leaking insertion order to consumers.
    const wget_id = try insertKegRow(&db, "wget");
    try addDepRow(&db, wget_id, "openssl@3");
    try addDepRow(&db, wget_id, "libidn2");

    const deps = try info.collectInstalledDeps(testing.allocator, &db, "wget");
    defer freeDepsSlice(deps);

    try testing.expectEqual(@as(usize, 2), deps.len);
    try testing.expectEqualStrings("libidn2", deps[0]);
    try testing.expectEqualStrings("openssl@3", deps[1]);
}

test "collectInstalledDeps returns an empty slice for an installed leaf" {
    var fx = try Fixture.init("deps_leaf");
    defer fx.deinit(); // runs after db.close(): LIFO
    var db = try makeDepsDb(&fx);
    defer db.close();

    _ = try insertKegRow(&db, "tree");

    const deps = try info.collectInstalledDeps(testing.allocator, &db, "tree");
    defer freeDepsSlice(deps);

    try testing.expectEqual(@as(usize, 0), deps.len);
}

test "collectInstalledDeps returns an empty slice when the keg is not installed" {
    var fx = try Fixture.init("deps_absent");
    defer fx.deinit(); // runs after db.close(): LIFO
    var db = try makeDepsDb(&fx);
    defer db.close();

    const deps = try info.collectInstalledDeps(testing.allocator, &db, "ghost");
    defer freeDepsSlice(deps);

    try testing.expectEqual(@as(usize, 0), deps.len);
}

test "collectInstalledDeps reports dependency rows it cannot read instead of a leaf" {
    // An empty list would render an installed keg as having no dependencies.
    var fx = try Fixture.init("deps_corrupt");
    defer fx.deinit();
    {
        var db = try makeDepsDb(&fx);
        defer db.close();
        const wget_id = try insertKegRow(&db, "wget");
        try addDepRow(&db, wget_id, "openssl@3");
    }
    try test_io.corruptTable(fx.p("deps.db"), "dependencies");
    var db = try sqlite.Database.open(fx.p("deps.db"));
    defer db.close();

    output.setQuiet(true);
    defer output.setQuiet(false);
    try testing.expectError(error.Aborted, info.collectInstalledDeps(testing.allocator, &db, "wget"));
}

test "collectInstalledDeps reports a keg table it cannot query instead of a leaf" {
    var fx = try Fixture.init("deps_no_kegs");
    defer fx.deinit();
    var db = try makeDepsDb(&fx);
    defer db.close();
    try db.exec("DROP TABLE dependencies; DROP TABLE kegs;");

    output.setQuiet(true);
    defer output.setQuiet(false);
    try testing.expectError(error.Aborted, info.collectInstalledDeps(testing.allocator, &db, "wget"));
}

fn collectAndFree(allocator: std.mem.Allocator, db: *sqlite.Database, name: []const u8) !void {
    const deps = try info.collectInstalledDeps(allocator, db, name);
    for (deps) |d| allocator.free(d);
    allocator.free(deps);
}

test "collectInstalledDeps frees every name when an allocation fails part-way" {
    var fx = try Fixture.init("deps_alloc_failures");
    defer fx.deinit();
    var db = try makeDepsDb(&fx);
    defer db.close();
    const wget_id = try insertKegRow(&db, "wget");
    try addDepRow(&db, wget_id, "openssl@3");
    try addDepRow(&db, wget_id, "libidn2");

    try testing.checkAllAllocationFailures(testing.allocator, collectAndFree, .{ &db, "wget" });
}

// --- both kind-flags dispatch: --cask --formula must not hide an install -
//
// `--cask`/`--formula` are inclusive selectors (mirroring `search`):
// passing both reads the same as passing neither. These tests drive the
// full `execute` dispatch against a seeded prefix so the flag plumbing —
// not just the encoders — is pinned. Offline so the installed lookup is
// the only thing under test.

const Prefix = struct {
    path: [:0]u8,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !Prefix {
        const base = try test_io.uniqueTempPath(allocator, "info_dispatch", tag);
        defer allocator.free(base);
        const path = try allocator.dupeZ(u8, base);
        test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
        const db_dir = try std.fmt.allocPrint(allocator, "{s}/db", .{path});
        defer allocator.free(db_dir);
        try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);
        _ = c.setenv("MALT_PREFIX", path.ptr, 1);
        return .{ .path = path };
    }

    fn deinit(self: *Prefix, allocator: std.mem.Allocator) void {
        _ = c.unsetenv("MALT_PREFIX");
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.path) catch {};
        allocator.free(self.path);
    }

    // Record that the API already answered 404 for this name as both kinds,
    // so an offline run reaches "not installed" through a real miss rather
    // than an unanswered question.
    fn seedNotFound(self: *Prefix, name: []const u8) !void {
        const io = std.Options.debug_io;
        var dir_buf: [512]u8 = undefined;
        const dir = try std.fmt.bufPrint(&dir_buf, "{s}/cache/api", .{self.path});
        try test_io.cwd().createDirPath(io, dir);
        for ([_][]const u8{ "formula_", "cask_" }) |kind| {
            var path_buf: [512]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}{s}.404", .{ dir, kind, name });
            const f = try test_io.createFileAbsolute(io, path, .{ .truncate = true });
            f.close(io);
        }
    }

    // Seed one installed formula keg so the local lookup has a real row.
    fn seedFormula(self: *Prefix, name: []const u8) !void {
        var db = try self.openSeedDb();
        defer db.close();
        var stmt = try db.prepare(
            "INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path)" ++
                " VALUES (?1, ?1, '1.24.5', ?1, '/c/wget/1.24.5');",
        );
        defer stmt.finalize();
        try stmt.bindText(1, name);
        _ = try stmt.step();
    }

    // Seed one installed cask row.
    fn seedCask(self: *Prefix, token: []const u8) !void {
        var db = try self.openSeedDb();
        defer db.close();
        var stmt = try db.prepare(
            "INSERT INTO casks (token, name, version, url, sha256)" ++
                " VALUES (?1, ?1, '120.0', 'https://example.invalid/x.dmg', 'aa');",
        );
        defer stmt.finalize();
        try stmt.bindText(1, token);
        _ = try stmt.step();
    }

    fn openSeedDb(self: *Prefix) !sqlite.Database {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{self.path}, 0);
        var db = try sqlite.Database.open(db_path);
        errdefer db.close();
        try schema.initSchema(&db);
        return db;
    }
};

// Drive `info.execute` with stdout backed by a real fd so the encoder
// writes survive for byte assertions; offline so no network is attempted.
fn captureInfo(allocator: std.mem.Allocator, args: []const []const u8, tag: []const u8) ![]u8 {
    // Colour is decided by whether stderr is a TTY, not by where the text
    // goes, so an interactive run writes escapes into this capture file and
    // the byte-level assertions below fail. Pin it off.
    color.setForTest(false, null);

    const cap_base = try test_io.uniqueTempPath(allocator, "info_cap", tag);
    defer allocator.free(cap_base);
    const cap_path = try allocator.dupeZ(u8, cap_base);
    defer allocator.free(cap_path);
    defer test_io.deleteFileAbsolute(std.Options.debug_io, cap_path) catch {};

    var file = try test_io.createFileAbsolute(std.Options.debug_io, cap_path, .{ .truncate = true });
    errdefer file.close(std.Options.debug_io);

    const ctx: malt.app_ctx.AppCtx = .{
        .io = std.Options.debug_io,
        .environ = .empty,
        .offline = true,
        .stdout = file,
        .stderr = test_io.testSink(),
    };

    try info.execute(&ctx, allocator, args);
    file.close(std.Options.debug_io);

    return try test_io.readFileAbsoluteAlloc(std.Options.debug_io, allocator, cap_path, 64 * 1024);
}

const OutputState = struct {
    prior_mode: output.OutputMode,
    prior_quiet: bool,

    fn save() OutputState {
        return .{
            .prior_mode = if (output.isJson()) .json else .human,
            .prior_quiet = output.isQuiet(),
        };
    }
    fn restore(self: OutputState) void {
        output.setMode(self.prior_mode);
        output.setQuiet(self.prior_quiet);
    }
};

test "info --cask --formula shows the installed formula, not 'not installed'" {
    var p = try Prefix.init(testing.allocator, "both_human");
    defer p.deinit(testing.allocator);
    try p.seedFormula("wget");

    const prior = OutputState.save();
    defer prior.restore();
    output.setQuiet(true);

    const out = try captureInfo(testing.allocator, &.{ "--cask", "--formula", "wget" }, "both_human");
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "not installed") == null);
    try testing.expectStringStartsWith(out, "wget: ");
}

test "info --cask --formula --json pins installed:true for an installed package" {
    var p = try Prefix.init(testing.allocator, "both_json");
    defer p.deinit(testing.allocator);
    try p.seedFormula("wget");

    const prior = OutputState.save();
    defer prior.restore();
    output.setMode(.json);
    output.setQuiet(true);

    const out = try captureInfo(testing.allocator, &.{ "--cask", "--formula", "wget" }, "both_json");
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"installed\":true") != null);
}

test "info --formula still narrows to the installed formula" {
    var p = try Prefix.init(testing.allocator, "formula_only");
    defer p.deinit(testing.allocator);
    try p.seedFormula("wget");

    const prior = OutputState.save();
    defer prior.restore();
    output.setQuiet(true);

    const out = try captureInfo(testing.allocator, &.{ "--formula", "wget" }, "formula_only");
    defer testing.allocator.free(out);

    try testing.expectStringStartsWith(out, "wget: ");
}

test "info --cask --formula resolves an installed cask (formula misses, cask runs)" {
    // The symmetric half of the bug: with both flags set the formula
    // lookup misses for a cask token, so the cask branch must still run
    // rather than being suppressed alongside it.
    var p = try Prefix.init(testing.allocator, "both_cask");
    defer p.deinit(testing.allocator);
    try p.seedCask("firefox");

    const prior = OutputState.save();
    defer prior.restore();
    output.setQuiet(true);

    const out = try captureInfo(testing.allocator, &.{ "--cask", "--formula", "firefox" }, "both_cask");
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "not installed") == null);
    try testing.expectStringStartsWith(out, "firefox: ");
    try testing.expect(std.mem.indexOf(u8, out, "(cask)") != null);
}

test "info --cask still skips the formula branch for an installed formula" {
    // Single-flag narrowing must be unchanged: `--cask` on a formula
    // token must NOT surface the formula — it falls through to not-found.
    var p = try Prefix.init(testing.allocator, "cask_only_excludes_formula");
    defer p.deinit(testing.allocator);
    try p.seedFormula("wget");
    try p.seedNotFound("wget");

    const prior = OutputState.save();
    defer prior.restore();
    output.setQuiet(true);

    const out = try captureInfo(testing.allocator, &.{ "--cask", "wget" }, "cask_only_excludes_formula");
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "not installed") != null);
}

test "info --cask --formula on an absent token still reaches not-found" {
    // The fix widens which lookups run; it must not suppress the
    // not-found terminal for a token that is neither formula nor cask.
    var p = try Prefix.init(testing.allocator, "both_absent");
    defer p.deinit(testing.allocator);
    try p.seedFormula("wget");
    try p.seedNotFound("ghost-pkg-xyz");

    const prior = OutputState.save();
    defer prior.restore();
    output.setQuiet(true);

    const out = try captureInfo(testing.allocator, &.{ "--cask", "--formula", "ghost-pkg-xyz" }, "both_absent");
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "not installed") != null);
}

test "info --json on an absent token reports the kind the caller selected" {
    // A `--cask` consumer must not get back the one kind it excluded.
    var p = try Prefix.init(testing.allocator, "absent_json_kind");
    defer p.deinit(testing.allocator);
    try p.seedNotFound("ghost-pkg-xyz");

    const prior = OutputState.save();
    defer prior.restore();
    output.setQuiet(true);
    output.setMode(.json);

    const cask_out = try captureInfo(testing.allocator, &.{ "--cask", "ghost-pkg-xyz" }, "absent_json_cask");
    defer testing.allocator.free(cask_out);
    try testing.expect(std.mem.indexOf(u8, cask_out, "\"type\":\"cask\",\"installed\":false}") != null);

    const formula_out = try captureInfo(testing.allocator, &.{ "--formula", "ghost-pkg-xyz" }, "absent_json_formula");
    defer testing.allocator.free(formula_out);
    try testing.expect(std.mem.indexOf(u8, formula_out, "\"type\":\"formula\",\"installed\":false}") != null);
}

test "info --cask and --formula each return their own side of a name installed as both" {
    // The TUI detail pane passes the row's kind; this is the contract it relies on.
    var p = try Prefix.init(testing.allocator, "shared_name_kinds");
    defer p.deinit(testing.allocator);
    try p.seedFormula("box");
    try p.seedCask("box");

    const prior = OutputState.save();
    defer prior.restore();
    output.setQuiet(true);
    output.setMode(.json);

    const cask_out = try captureInfo(testing.allocator, &.{ "--cask", "box" }, "shared_name_cask");
    defer testing.allocator.free(cask_out);
    try testing.expect(std.mem.indexOf(u8, cask_out, "\"type\":\"cask\",\"installed\":true,\"version\":\"120.0\"") != null);

    const formula_out = try captureInfo(testing.allocator, &.{ "--formula", "box" }, "shared_name_formula");
    defer testing.allocator.free(formula_out);
    try testing.expect(std.mem.indexOf(u8, formula_out, "\"type\":\"formula\",\"installed\":true,\"version\":\"1.24.5\"") != null);
}
