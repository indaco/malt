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

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

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

    try testing.expect(info.openDb(fx.base) == null);
}

test "openDb succeeds and returns a usable handle when db/ exists" {
    var fx = try Fixture.init("ok_db");
    defer fx.deinit();
    try test_io.makeDirAbsolute(std.Options.debug_io, fx.p("db"));

    var db = info.openDb(fx.base) orelse return error.ExpectedDatabase;
    defer db.close();
}

test "openDb returns null when the prefix itself does not exist" {
    // A completely absent prefix path — typical when MALT_PREFIX is
    // pointed at a freshly-minted directory that hasn't been
    // populated by any malt command yet.
    const prefix = try test_io.uniqueTempPath(testing.allocator, "info", "no_prefix_at_all");
    defer testing.allocator.free(prefix);
    try testing.expect(info.openDb(prefix) == null);
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

    const deps = info.collectInstalledDeps(testing.allocator, &db, "wget");
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

    const deps = info.collectInstalledDeps(testing.allocator, &db, "tree");
    defer freeDepsSlice(deps);

    try testing.expectEqual(@as(usize, 0), deps.len);
}

test "collectInstalledDeps returns an empty slice when the keg is not installed" {
    var fx = try Fixture.init("deps_absent");
    defer fx.deinit(); // runs after db.close(): LIFO
    var db = try makeDepsDb(&fx);
    defer db.close();

    const deps = info.collectInstalledDeps(testing.allocator, &db, "ghost");
    defer freeDepsSlice(deps);

    try testing.expectEqual(@as(usize, 0), deps.len);
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
    try testing.expect(std.mem.startsWith(u8, out, "wget: "));
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

    try testing.expect(std.mem.startsWith(u8, out, "wget: "));
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
    try testing.expect(std.mem.startsWith(u8, out, "firefox: "));
    try testing.expect(std.mem.indexOf(u8, out, "(cask)") != null);
}

test "info --cask still skips the formula branch for an installed formula" {
    // Single-flag narrowing must be unchanged: `--cask` on a formula
    // token must NOT surface the formula — it falls through to not-found.
    var p = try Prefix.init(testing.allocator, "cask_only_excludes_formula");
    defer p.deinit(testing.allocator);
    try p.seedFormula("wget");

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

    const prior = OutputState.save();
    defer prior.restore();
    output.setQuiet(true);

    const out = try captureInfo(testing.allocator, &.{ "--cask", "--formula", "ghost-pkg-xyz" }, "both_absent");
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "not installed") != null);
}
