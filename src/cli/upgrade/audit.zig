//! Phase 1 of `mt upgrade`: decide which installed rows may be skipped,
//! without upgrading anything. A row is excluded only when the bulk version
//! index positively proved it current — anything unproven costs a redundant
//! upgrade attempt, while the reverse silently skips one the user asked for.

const std = @import("std");
const outdated = @import("../outdated.zig");
const api_mod = @import("../../net/api.zig");
const sqlite = @import("../../db/sqlite.zig");

pub const Kind = api_mod.BrewApi.Kind;

/// Narrowings that make an audit cover less than the whole installed set.
/// `--tap` is absent: the bulk path never narrows by tap.
pub const Scope = struct {
    cask_only: bool = false,
    formula_only: bool = false,
    pinned_only: bool = false,
};

/// Rows and their verdicts, aligned 1:1 — `dispositions[i]` answers for
/// `rows[i]`. Phase 2 walks the pair; no row is ever dropped here.
pub const Plan = struct {
    rows: []outdated.KegRow,
    dispositions: []outdated.Disposition,
    /// True only when this audit belongs to an unnarrowed walk of the
    /// whole installed set. `--cask` clears it even for the cask audit:
    /// a caller persisting that result would under-report the formulae
    /// it never looked at.
    full_keg: bool,

    /// Nothing audited, nothing provable. The fallback when a kind is
    /// narrowed out or its audit could not read a row: `full_keg` is false,
    /// so it can never license a snapshot write. Freeing a zero-length
    /// slice is a no-op, so `deinit` is safe on it.
    pub const empty: Plan = .{
        .rows = @constCast(&[_]outdated.KegRow{}),
        .dispositions = @constCast(&[_]outdated.Disposition{}),
        .full_keg = false,
    };

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        outdated.freeKegRows(allocator, self.rows);
        outdated.freeDispositions(allocator, self.dispositions);
    }
};

/// The exclusion policy, entire. Default arm is "do not skip", so a new
/// `Disposition` arm cannot silently become skippable.
///
/// `--force` disables exclusion wholesale. It deliberately preserves
/// today's inconsistency where the per-package core compare ignores
/// force; reconciling the two is separate work.
pub fn skips(d: outdated.Disposition, force: bool) bool {
    return !force and d == .proven_current;
}

fn fullKeg(scope: Scope) bool {
    return !scope.cask_only and !scope.formula_only and !scope.pinned_only;
}

fn filterFor(scope: Scope) outdated.KegFilter {
    return if (scope.pinned_only) .pinned_only else .all;
}

/// Load every row of `kind` and resolve it against the bulk version index.
/// The index is consulted once; a tap row, a miss or a down index all stay
/// `unknown` for phase 2, and no per-keg HEAD is fetched here.
///
/// Offline skips the resolve entirely: the index serves a cached dump at any
/// age when offline, and a stale dump can "prove" a genuinely outdated row
/// current — the one way this hides work instead of saving it.
pub fn audit(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    api: *api_mod.BrewApi,
    kind: Kind,
    scope: Scope,
) !Plan {
    const filter = filterFor(scope);
    const rows = switch (kind) {
        .formula => try outdated.loadFormulaRows(allocator, db, filter),
        .cask => try outdated.loadCaskRows(allocator, db, filter),
    };
    errdefer outdated.freeKegRows(allocator, rows);

    const dispositions = if (api.offline) blk: {
        const ds = try allocator.alloc(outdated.Disposition, rows.len);
        @memset(ds, .unknown);
        break :blk ds;
    } else switch (kind) {
        .formula => try outdated.collectIndexDispositionsFormulas(allocator, api, rows),
        .cask => try outdated.collectIndexDispositionsCasks(allocator, api, rows),
    };

    return .{ .rows = rows, .dispositions = dispositions, .full_keg = fullKeg(scope) };
}

// ── tests ───────────────────────────────────────────────────────────

const testing = std.testing;
const schema = @import("../../db/schema.zig");
const client_mod = @import("../../net/client.zig");

test "skips excludes a proven-current row" {
    try testing.expect(skips(.proven_current, false));
}

test "skips honours --force so a forced run upgrades even a proven-current row" {
    try testing.expect(!skips(.proven_current, true));
}

test "skips never excludes an unproven row, forced or not" {
    // The default arm. `unknown` is the verdict every unresolved row
    // carries, so treating it as skippable would silently drop upgrades.
    var latest = [_]u8{ '9', '.', '9' };
    for ([_]bool{ false, true }) |force| {
        try testing.expect(!skips(.unknown, force));
        try testing.expect(!skips(.{ .needs_upgrade = &latest }, force));
    }
}

test "full_keg is true only for an unnarrowed audit" {
    try testing.expect(fullKeg(.{}));
    try testing.expect(!fullKeg(.{ .pinned_only = true }));
    try testing.expect(!fullKeg(.{ .cask_only = true }));
    try testing.expect(!fullKeg(.{ .formula_only = true }));
    try testing.expect(!fullKeg(.{ .cask_only = true, .pinned_only = true }));
}

test "--pinned selects the pinned-only keg filter" {
    try testing.expect(filterFor(.{ .pinned_only = true }) == .pinned_only);
    try testing.expect(filterFor(.{}) == .all);
    try testing.expect(filterFor(.{ .cask_only = true }) == .all);
}

/// Tmp tree + schema-initialised db, doubling as the api cache dir so a
/// planted side-car is the only version truth these tests can reach.
const TempDb = struct {
    tmp: std.testing.TmpDir,
    dir_buf: [std.fs.max_path_bytes]u8 = undefined,
    dir_len: usize = 0,
    db: sqlite.Database = undefined,

    fn init() !TempDb {
        var self: TempDb = .{ .tmp = std.testing.tmpDir(.{}) };
        errdefer self.tmp.cleanup();
        self.dir_len = try std.Io.Dir.realPath(self.tmp.dir, std.Options.debug_io, &self.dir_buf);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&buf, "{s}/test.db", .{self.dir()}, 0);
        self.db = try sqlite.Database.open(path);
        errdefer self.db.close();
        try schema.initSchema(&self.db);
        return self;
    }

    /// Computed, not stored: a stored slice would dangle the moment the
    /// struct is returned by value.
    fn dir(self: *const TempDb) []const u8 {
        return self.dir_buf[0..self.dir_len];
    }

    fn deinit(self: *TempDb) void {
        self.db.close();
        self.tmp.cleanup();
    }
};

fn insertKeg(db: *sqlite.Database, name: []const u8, version: []const u8) !void {
    var buf: [512]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(
        &buf,
        "INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, pinned) VALUES ('{s}', '{s}', '{s}', 'deadbeef', '/opt/malt/Cellar/{s}/{s}', 0);",
        .{ name, name, version, name, version },
    );
    try db.exec(sql);
}

fn insertPinnedKeg(db: *sqlite.Database, name: []const u8, version: []const u8) !void {
    var buf: [512]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(
        &buf,
        "INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, pinned) VALUES ('{s}', '{s}', '{s}', 'deadbeef', '/opt/malt/Cellar/{s}/{s}', 1);",
        .{ name, name, version, name, version },
    );
    try db.exec(sql);
}

fn insertKegTap(db: *sqlite.Database, name: []const u8, version: []const u8, tap: []const u8) !void {
    var buf: [512]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(
        &buf,
        "INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, tap) VALUES ('{s}', '{s}', '{s}', 'deadbeef', '/opt/malt/Cellar/{s}/{s}', '{s}');",
        .{ name, name, version, name, version, tap },
    );
    try db.exec(sql);
}

/// Legacy shape: no tap. `isCorePathRow` reads a NULL tap as core, so
/// these still resolve from the bulk dump.
fn insertCask(db: *sqlite.Database, token: []const u8, version: []const u8) !void {
    var buf: [512]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(
        &buf,
        "INSERT INTO casks (token, name, version, url) VALUES ('{s}', '{s}', '{s}', 'https://example.com');",
        .{ token, token, version },
    );
    try db.exec(sql);
}

fn insertCaskTap(db: *sqlite.Database, token: []const u8, version: []const u8, tap: []const u8) !void {
    var buf: [512]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(
        &buf,
        "INSERT INTO casks (token, name, version, url, tap) VALUES ('{s}', '{s}', '{s}', 'https://example.com', '{s}');",
        .{ token, token, version, tap },
    );
    try db.exec(sql);
}

/// Plant the `<name>\t<stable>\t<revision>` side-car the bulk path reads.
fn writeVersionsIndex(cache_dir: []const u8, kind: Kind, body: []const u8) !void {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}/api", .{cache_dir});
    std.Io.Dir.createDirAbsolute(std.Options.debug_io, dir, .default_dir) catch {};
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = try std.fmt.bufPrint(&path_buf, "{s}/api/versions_{s}.txt", .{
        cache_dir,
        @tagName(kind),
    });
    const f = try std.Io.Dir.cwd().createFile(std.Options.debug_io, p, .{});
    defer f.close(std.Options.debug_io);
    try f.writeStreamingAll(std.Options.debug_io, body);
}

/// Api wired to the fixture's tmp tree. Every version answer therefore
/// comes from a planted side-car; nothing here can reach the network.
fn testApi(http: *client_mod.HttpClient, t: *const TempDb) api_mod.BrewApi {
    return api_mod.BrewApi.init(std.Options.debug_io, testing.allocator, http, t.dir());
}

test "offline leaves every row unknown even when a cached dump would prove one current" {
    // The fixture is the hazard: a dump saying alpha is already at the
    // installed version. Online that is `proven_current`. Offline the dump
    // may be arbitrarily stale, so trusting it could prove a genuinely
    // outdated row current — the one way this pre-filter hides work.
    var t = try TempDb.init();
    defer t.deinit();
    try insertKeg(&t.db, "alpha", "1.0");
    try writeVersionsIndex(t.dir(), .formula, "alpha\t1.0\t0\n");

    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    http.offline = true;
    var api = testApi(&http, &t);
    api.offline = true;

    var plan = try audit(testing.allocator, &t.db, &api, .formula, .{});
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), plan.dispositions.len);
    try testing.expect(plan.dispositions[0] == .unknown);
}

test "audit returns one disposition per row, in row order, dropping none" {
    // Mixed provability: a row the dump proves current, a row it says is
    // behind, and a row it never mentions. All three must survive — phase 2
    // needs every row, and a dropped one is an upgrade that never happens.
    var t = try TempDb.init();
    defer t.deinit();
    try insertKeg(&t.db, "alpha", "1.0");
    try insertKeg(&t.db, "beta", "1.0");
    try insertKeg(&t.db, "gamma", "1.0");
    try writeVersionsIndex(t.dir(), .formula, "alpha\t1.0\t0\nbeta\t2.0\t0\n");

    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var api = testApi(&http, &t);

    var plan = try audit(testing.allocator, &t.db, &api, .formula, .{});
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), plan.dispositions.len);
    try testing.expectEqualStrings("alpha", plan.rows[0].name);
    try testing.expect(plan.dispositions[0] == .proven_current);
    try testing.expectEqualStrings("beta", plan.rows[1].name);
    try testing.expectEqualStrings("2.0", plan.dispositions[1].needs_upgrade);
    // Absent from the dump: unproven, so unknown — never skippable.
    try testing.expectEqualStrings("gamma", plan.rows[2].name);
    try testing.expect(plan.dispositions[2] == .unknown);
    try testing.expect(plan.full_keg);
}

test "a cask audit reads the cask table against the cask index" {
    // Casks are a separate table, column and side-car. Without this, a
    // swapped switch arm would resolve casks against formula versions and
    // still pass every other test here.
    var t = try TempDb.init();
    defer t.deinit();
    try insertCask(&t.db, "shared", "1.0");
    try insertKeg(&t.db, "shared", "1.0");
    // Same name in both dumps, different answers: only the cask side-car
    // can produce `proven_current` for the cask row.
    try writeVersionsIndex(t.dir(), .cask, "shared\t1.0\t0\n");
    try writeVersionsIndex(t.dir(), .formula, "shared\t9.9\t0\n");

    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var api = testApi(&http, &t);

    var plan = try audit(testing.allocator, &t.db, &api, .cask, .{});
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), plan.dispositions.len);
    try testing.expectEqualStrings("shared", plan.rows[0].name);
    try testing.expect(plan.dispositions[0] == .proven_current);
}

test "a legacy NULL-tap cask resolves against the dump like any core row" {
    // The shape v5-era rows still carry. A NULL tap reads as core, so this
    // is the one cask arrangement the bulk dump can prove current — and the
    // one most likely to be mistaken for unattributed and skipped.
    var t = try TempDb.init();
    defer t.deinit();
    try insertCask(&t.db, "current", "1.0");
    try insertCask(&t.db, "behind", "1.0");
    try insertCask(&t.db, "absent", "1.0");
    try writeVersionsIndex(t.dir(), .cask, "current\t1.0\t0\nbehind\t2.0\t0\n");

    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var api = testApi(&http, &t);

    var plan = try audit(testing.allocator, &t.db, &api, .cask, .{});
    defer plan.deinit(testing.allocator);

    // Rows come back ordered by token: absent, behind, current.
    try testing.expectEqual(@as(usize, 3), plan.rows.len);
    try testing.expectEqualStrings("absent", plan.rows[0].name);
    try testing.expect(plan.dispositions[0] == .unknown);
    try testing.expectEqualStrings("behind", plan.rows[1].name);
    try testing.expectEqualStrings("2.0", plan.dispositions[1].needs_upgrade);
    try testing.expectEqualStrings("current", plan.rows[2].name);
    try testing.expect(plan.dispositions[2] == .proven_current);
}

test "a homebrew/cask-tapped cask is core and resolves against the dump" {
    // The backfilled counterpart of the NULL-tap row above: attribution to
    // the core cask tap must not change the verdict.
    var t = try TempDb.init();
    defer t.deinit();
    try insertCaskTap(&t.db, "labelled", "1.0", "homebrew/cask");
    try writeVersionsIndex(t.dir(), .cask, "labelled\t1.0\t0\n");

    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var api = testApi(&http, &t);

    var plan = try audit(testing.allocator, &t.db, &api, .cask, .{});
    defer plan.deinit(testing.allocator);

    try testing.expect(plan.dispositions[0] == .proven_current);
}

test "a revision-bearing dump line cannot prove a cask current" {
    // Casks carry no revision — the row is always revision 0. So a dump
    // line claiming one qualifies to `1.0_1`, which is not the installed
    // `1.0`. Unproven, and the upgrade attempt is the safe answer.
    var t = try TempDb.init();
    defer t.deinit();
    try insertCask(&t.db, "tok", "1.0");
    try writeVersionsIndex(t.dir(), .cask, "tok\t1.0\t1\n");

    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var api = testApi(&http, &t);

    var plan = try audit(testing.allocator, &t.db, &api, .cask, .{});
    defer plan.deinit(testing.allocator);

    try testing.expect(plan.dispositions[0] != .proven_current);
    try testing.expectEqualStrings("1.0_1", plan.dispositions[0].needs_upgrade);
    try testing.expect(!skips(plan.dispositions[0], false));
}

test "an empty cask table yields an empty plan" {
    var t = try TempDb.init();
    defer t.deinit();
    try insertKeg(&t.db, "alpha", "1.0");

    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var api = testApi(&http, &t);

    // A populated keg table must not leak into a cask audit.
    var plan = try audit(testing.allocator, &t.db, &api, .cask, .{});
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), plan.rows.len);
    try testing.expectEqual(@as(usize, 0), plan.dispositions.len);
}

test "--pinned narrows a cask audit to pinned tokens" {
    var t = try TempDb.init();
    defer t.deinit();
    try insertCask(&t.db, "loose", "1.0");
    try t.db.exec("INSERT INTO casks (token, name, version, url, pinned) VALUES ('held', 'held', '1.0', 'https://example.com', 1);");
    try writeVersionsIndex(t.dir(), .cask, "held\t1.0\t0\nloose\t1.0\t0\n");

    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var api = testApi(&http, &t);

    var plan = try audit(testing.allocator, &t.db, &api, .cask, .{ .pinned_only = true });
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), plan.rows.len);
    try testing.expectEqualStrings("held", plan.rows[0].name);
    try testing.expect(!plan.full_keg);
}

test "offline leaves a cask row unknown even when the cask dump would prove it current" {
    var t = try TempDb.init();
    defer t.deinit();
    try insertCask(&t.db, "tok", "1.0");
    try writeVersionsIndex(t.dir(), .cask, "tok\t1.0\t0\n");

    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    http.offline = true;
    var api = testApi(&http, &t);
    api.offline = true;

    var plan = try audit(testing.allocator, &t.db, &api, .cask, .{});
    defer plan.deinit(testing.allocator);

    try testing.expect(plan.dispositions[0] == .unknown);
}

test "--pinned audits only pinned rows and marks the plan narrowed" {
    var t = try TempDb.init();
    defer t.deinit();
    try insertKeg(&t.db, "loose", "1.0");
    try insertPinnedKeg(&t.db, "held", "1.0");
    try writeVersionsIndex(t.dir(), .formula, "held\t1.0\t0\nloose\t1.0\t0\n");

    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var api = testApi(&http, &t);

    var plan = try audit(testing.allocator, &t.db, &api, .formula, .{ .pinned_only = true });
    defer plan.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), plan.rows.len);
    try testing.expectEqualStrings("held", plan.rows[0].name);
    try testing.expect(!plan.full_keg);
}

test "an empty keg table yields an empty plan rather than an error" {
    var t = try TempDb.init();
    defer t.deinit();

    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var api = testApi(&http, &t);

    // Both arms: the offline short-circuit allocates its own slice, so it
    // has its own zero-row path to get wrong.
    for ([_]bool{ false, true }) |offline| {
        api.offline = offline;
        var plan = try audit(testing.allocator, &t.db, &api, .formula, .{});
        defer plan.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), plan.rows.len);
        try testing.expectEqual(@as(usize, 0), plan.dispositions.len);
    }
}

test "a third-party-tap row stays unknown even when the index lists it as outdated" {
    // The audit resolves against the version index only, and the index cannot
    // speak for a tap row: those answer to sha-truth (a HEAD move with an
    // unchanged version constant) the index never sees. If the audit let the
    // index prove this row current — or even mark it needs_upgrade — phase 2
    // would lose the sha-only move. It must come back unknown and fall through.
    var t = try TempDb.init();
    defer t.deinit();
    try insertKegTap(&t.db, "tapped", "1.0", "third/party");
    // The index even disagrees with the installed version — still ignored.
    try writeVersionsIndex(t.dir(), .formula, "tapped\t2.0\t0\n");

    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var api = testApi(&http, &t);

    var plan = try audit(testing.allocator, &t.db, &api, .formula, .{});
    defer plan.deinit(testing.allocator);

    try testing.expect(plan.dispositions[0] == .unknown);
}

test "an unparseable upstream version reaches the plan as unknown" {
    // The disposition layer's guarantee, re-asserted here so the two cannot
    // drift apart: a version too long to qualify is unproven, never current.
    var t = try TempDb.init();
    defer t.deinit();
    try insertKeg(&t.db, "alpha", "1.0");

    var body_buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "alpha\t1.{s}\t0\n", .{"9" ** 300});
    try writeVersionsIndex(t.dir(), .formula, body);

    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    var api = testApi(&http, &t);

    var plan = try audit(testing.allocator, &t.db, &api, .formula, .{});
    defer plan.deinit(testing.allocator);

    try testing.expect(plan.dispositions[0] == .unknown);
    try testing.expect(!skips(plan.dispositions[0], false));
}
