//! malt — cli/list JSON output tests
//! Exercises `buildListJson` via an on-disk sqlite DB seeded with kegs
//! and casks, asserting the exact bytes written for the three block
//! shapes (installed / legacy formulae / legacy casks).

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");
const sqlite = malt.sqlite;
const schema = malt.schema;
const cli_list = malt.cli_list;

/// Scratch DB under a process-unique base, so overlapping test runs cannot
/// wipe each other's fixtures.
const TempDb = struct {
    arena: std.heap.ArenaAllocator,
    dir: [:0]const u8,
    db: sqlite.Database,

    fn init(tag: []const u8) !TempDb {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const base = try test_io.uniqueTempPath(arena.allocator(), "list", tag);
        const dir = try arena.allocator().dupeZ(u8, base);
        test_io.deleteTreeAbsolute(std.Options.debug_io, dir) catch {};
        try test_io.makeDirAbsolute(std.Options.debug_io, dir);
        var buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&buf, "{s}/test.db", .{dir}, 0);
        var db = try sqlite.Database.open(path);
        errdefer db.close();
        try schema.initSchema(&db);
        return .{ .arena = arena, .dir = dir, .db = db };
    }

    fn deinit(self: *TempDb) void {
        self.db.close();
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.dir) catch {};
        self.arena.deinit();
    }
};

fn insertKeg(db: *sqlite.Database, name: []const u8, version: []const u8, pinned: bool) !void {
    var buf: [512]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(
        &buf,
        "INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, pinned) VALUES ('{s}', '{s}', '{s}', 'deadbeef', '/opt/malt/Cellar/{s}/{s}', {d});",
        .{ name, name, version, name, version, @intFromBool(pinned) },
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

fn runBuild(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    show_formula: bool,
    show_cask: bool,
    show_pinned: bool,
) ![]u8 {
    return runBuildTap(allocator, db, show_formula, show_cask, show_pinned, null);
}

fn runBuildTap(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    show_formula: bool,
    show_cask: bool,
    show_pinned: bool,
    tap_filter: ?[]const u8,
) ![]u8 {
    return runBuildFull(allocator, db, show_formula, show_cask, show_pinned, false, false, tap_filter, "");
}

/// Full encoder entry point: lets size/linked tests opt into the new
/// `--size`/`--linked` enrichment and supply the prefix used to resolve
/// cask `Caskroom/<token>` paths.
fn runBuildFull(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    show_formula: bool,
    show_cask: bool,
    show_pinned: bool,
    show_size: bool,
    show_linked: bool,
    tap_filter: ?[]const u8,
    prefix: []const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    // Use a fixed start_ts so the ",\"time_ms\":N" suffix is predictable.
    try cli_list.buildListJson(
        db,
        &aw.writer,
        std.Options.debug_io,
        prefix,
        show_formula,
        show_cask,
        show_pinned,
        show_size,
        show_linked,
        tap_filter,
        test_io.milliTimestamp(std.Options.debug_io),
    );
    return aw.toOwnedSlice();
}

/// Write `body` to `parent/rel`, creating intermediate dirs. Mirrors the
/// keg-dir fixtures other suites build for on-disk walks.
fn writeTreeFile(parent: []const u8, rel: []const u8, body: []const u8) !void {
    const io = std.Options.debug_io;
    var buf: [512]u8 = undefined;
    const abs = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ parent, rel });
    if (std.fs.path.dirname(abs)) |d| std.Io.Dir.cwd().createDirPath(io, d) catch {};
    const f = try std.Io.Dir.createFileAbsolute(io, abs, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, body);
}

// Strip the non-deterministic ",\"time_ms\":N}\n" suffix so assertions can
// compare the structural body.
fn trimTimeSuffix(out: []const u8) []const u8 {
    const needle = ",\"time_ms\":";
    if (std.mem.findLast(u8, out, needle)) |pos| return out[0..pos];
    return out;
}

/// Emit `writeHumanOutput` into a freshly allocated buffer with `quiet`
/// honoured around the call so the global state mutation never leaks
/// to neighbouring tests.
fn runHuman(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    show_formula: bool,
    show_cask: bool,
    show_versions: bool,
    show_pinned: bool,
    quiet: bool,
) ![]u8 {
    return runHumanTap(allocator, db, show_formula, show_cask, show_versions, show_pinned, quiet, null);
}

fn runHumanTap(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    show_formula: bool,
    show_cask: bool,
    show_versions: bool,
    show_pinned: bool,
    quiet: bool,
    tap_filter: ?[]const u8,
) ![]u8 {
    const prior_quiet = malt.output.isQuiet();
    malt.output.setQuiet(quiet);
    defer malt.output.setQuiet(prior_quiet);
    // `writeHumanOutput` reads colour state via the global; pin to no-color
    // so assertions below stay independent of the host terminal.
    malt.color.setForTest(false, false);
    defer malt.color.setForTest(null, null);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try cli_list.writeHumanOutput(db, show_formula, show_cask, show_versions, show_pinned, tap_filter, &aw.writer);
    return aw.toOwnedSlice();
}

test "writeHumanOutput honours --quiet: names only, no bullet, no decorations" {
    // The help text advertises `--quiet, -q  Names only, one per line`,
    // which makes the output script-parseable. Decorations (bullet, version
    // suffix, [pinned] tag) must all be suppressed under quiet mode.
    var t = try TempDb.init("human_quiet");
    defer t.deinit();
    try insertKeg(&t.db, "alpha", "1.0", false);
    try insertKeg(&t.db, "bravo", "2.1", true);
    try insertCask(&t.db, "charlie", "3.0");

    const out = try runHuman(testing.allocator, &t.db, true, true, true, false, true);
    defer testing.allocator.free(out);

    try testing.expectEqualStrings("alpha\nbravo\ncharlie\n", out);
}

test "writeHumanOutput non-quiet keeps the bullet prefix and decorations" {
    // Regression guard: the quiet fix must not strip decorations from the
    // default human output that interactive users expect.
    var t = try TempDb.init("human_decorated");
    defer t.deinit();
    try insertKeg(&t.db, "alpha", "1.0", true);

    const out = try runHuman(testing.allocator, &t.db, true, false, true, false, false);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "  ▸ alpha") != null);
    try testing.expect(std.mem.indexOf(u8, out, " (1.0)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[pinned]") != null);
}

test "buildListJson: empty DB, both flags" {
    var t = try TempDb.init("empty");
    defer t.deinit();

    const out = try runBuild(testing.allocator, &t.db, true, true, false);
    defer testing.allocator.free(out);

    const body = trimTimeSuffix(out);
    try testing.expectEqualStrings(
        "{\"schema_version\":1,\"installed\":[],\"formulae\":[],\"casks\":[]",
        body,
    );
    // Suffix structure intact.
    try testing.expect(std.mem.endsWith(u8, out, "}\n"));
    try testing.expect(std.mem.indexOf(u8, out, ",\"time_ms\":") != null);
}

test "buildListJson: formula-only, two kegs, pinned flag preserved" {
    var t = try TempDb.init("formula_only");
    defer t.deinit();

    try insertKeg(&t.db, "alpha", "1.0", false);
    try insertKeg(&t.db, "bravo", "2.1", true);

    const out = try runBuild(testing.allocator, &t.db, true, false, false);
    defer testing.allocator.free(out);

    const body = trimTimeSuffix(out);
    try testing.expectEqualStrings(
        "{\"schema_version\":1,\"installed\":[" ++
            "{\"name\":\"alpha\",\"version\":\"1.0\",\"type\":\"formula\",\"pinned\":false}," ++
            "{\"name\":\"bravo\",\"version\":\"2.1\",\"type\":\"formula\",\"pinned\":true}" ++
            "],\"formulae\":[" ++
            "{\"name\":\"alpha\",\"version\":\"1.0\",\"pinned\":false}," ++
            "{\"name\":\"bravo\",\"version\":\"2.1\",\"pinned\":true}" ++
            "]",
        body,
    );
}

test "buildListJson: cask-only, one cask" {
    var t = try TempDb.init("cask_only");
    defer t.deinit();

    try insertCask(&t.db, "firefox", "120.0");

    const out = try runBuild(testing.allocator, &t.db, false, true, false);
    defer testing.allocator.free(out);

    const body = trimTimeSuffix(out);
    try testing.expectEqualStrings(
        "{\"schema_version\":1,\"installed\":[" ++
            "{\"name\":\"firefox\",\"version\":\"120.0\",\"type\":\"cask\",\"pinned\":false}" ++
            "],\"casks\":[" ++
            "{\"token\":\"firefox\",\"version\":\"120.0\"}" ++
            "]",
        body,
    );
}

test "buildListJson: cask .installed row carries pinned, matching formulae" {
    // Symmetry with formula rows: a pinned cask must surface `pinned:true`
    // in the installed array so the dashboard can show held casks too.
    var t = try TempDb.init("cask_pinned");
    defer t.deinit();

    try insertCask(&t.db, "loose", "1.0"); // unpinned
    try t.db.exec(
        \\INSERT INTO casks (token, name, version, url, pinned)
        \\VALUES ('held', 'held', '2.0', 'https://example.invalid', 1);
    );

    const out = try runBuild(testing.allocator, &t.db, false, true, false);
    defer testing.allocator.free(out);

    const body = trimTimeSuffix(out);
    try testing.expectEqualStrings(
        "{\"schema_version\":1,\"installed\":[" ++
            "{\"name\":\"held\",\"version\":\"2.0\",\"type\":\"cask\",\"pinned\":true}," ++
            "{\"name\":\"loose\",\"version\":\"1.0\",\"type\":\"cask\",\"pinned\":false}" ++
            "],\"casks\":[" ++
            "{\"token\":\"held\",\"version\":\"2.0\"}," ++
            "{\"token\":\"loose\",\"version\":\"1.0\"}" ++
            "]",
        body,
    );
}

test "buildListJson: mixed kegs and casks, comma between types in installed" {
    var t = try TempDb.init("mixed");
    defer t.deinit();

    try insertKeg(&t.db, "zsh", "5.9", false);
    try insertCask(&t.db, "slack", "4.0");

    const out = try runBuild(testing.allocator, &t.db, true, true, false);
    defer testing.allocator.free(out);

    const body = trimTimeSuffix(out);
    try testing.expectEqualStrings(
        "{\"schema_version\":1,\"installed\":[" ++
            "{\"name\":\"zsh\",\"version\":\"5.9\",\"type\":\"formula\",\"pinned\":false}," ++
            "{\"name\":\"slack\",\"version\":\"4.0\",\"type\":\"cask\",\"pinned\":false}" ++
            "],\"formulae\":[" ++
            "{\"name\":\"zsh\",\"version\":\"5.9\",\"pinned\":false}" ++
            "],\"casks\":[" ++
            "{\"token\":\"slack\",\"version\":\"4.0\"}" ++
            "]",
        body,
    );
}

test "buildListJson: --pinned filters formulae to pinned only" {
    var t = try TempDb.init("pinned");
    defer t.deinit();

    try insertKeg(&t.db, "one", "1.0", false);
    try insertKeg(&t.db, "two", "2.0", true);

    const out = try runBuild(testing.allocator, &t.db, true, false, true);
    defer testing.allocator.free(out);

    const body = trimTimeSuffix(out);
    try testing.expectEqualStrings(
        "{\"schema_version\":1,\"installed\":[" ++
            "{\"name\":\"two\",\"version\":\"2.0\",\"type\":\"formula\",\"pinned\":true}" ++
            "],\"formulae\":[" ++
            "{\"name\":\"two\",\"version\":\"2.0\",\"pinned\":true}" ++
            "]",
        body,
    );
}

test "buildListJson: --pinned UNIONs pinned formulas and casks sorted by name" {
    var t = try TempDb.init("pinned_mixed");
    defer t.deinit();

    // 'zsh' is the only pinned formula; 'firefox' is the only pinned cask.
    // 'loose' (formula) and 'slack' (cask) must be excluded by the pinned filter.
    try insertKeg(&t.db, "loose", "1.0", false);
    try insertKeg(&t.db, "zsh", "5.9", true);
    try insertCask(&t.db, "slack", "4.0");
    try t.db.exec(
        \\INSERT INTO casks (token, name, version, url, pinned)
        \\VALUES ('firefox', 'firefox', '120.0', 'https://example.invalid', 1);
    );

    const out = try runBuild(testing.allocator, &t.db, true, true, true);
    defer testing.allocator.free(out);

    const body = trimTimeSuffix(out);
    try testing.expectEqualStrings(
        "{\"schema_version\":1,\"installed\":[" ++
            "{\"name\":\"firefox\",\"version\":\"120.0\",\"type\":\"cask\",\"pinned\":true}," ++
            "{\"name\":\"zsh\",\"version\":\"5.9\",\"type\":\"formula\",\"pinned\":true}" ++
            "],\"formulae\":[" ++
            "{\"name\":\"zsh\",\"version\":\"5.9\",\"pinned\":true}" ++
            "],\"casks\":[" ++
            "{\"token\":\"firefox\",\"version\":\"120.0\"}" ++
            "]",
        body,
    );
}

test "buildListJson: --pinned installed array interleaves formulas and casks by name" {
    var t = try TempDb.init("pinned_interleave");
    defer t.deinit();

    // Names chosen so any en-bloc emit (formulas-then-casks or vice versa)
    // would visibly mis-sort against the cross-kind name order.
    try insertKeg(&t.db, "alpha", "1.0", true);
    try insertKeg(&t.db, "charlie", "3.0", true);
    try t.db.exec(
        \\INSERT INTO casks (token, name, version, url, pinned)
        \\VALUES ('bravo', 'bravo', '2.0', 'https://example.invalid', 1),
        \\       ('delta', 'delta', '4.0', 'https://example.invalid', 1);
    );

    const out = try runBuild(testing.allocator, &t.db, true, true, true);
    defer testing.allocator.free(out);

    const body = trimTimeSuffix(out);
    try testing.expectEqualStrings(
        "{\"schema_version\":1,\"installed\":[" ++
            "{\"name\":\"alpha\",\"version\":\"1.0\",\"type\":\"formula\",\"pinned\":true}," ++
            "{\"name\":\"bravo\",\"version\":\"2.0\",\"type\":\"cask\",\"pinned\":true}," ++
            "{\"name\":\"charlie\",\"version\":\"3.0\",\"type\":\"formula\",\"pinned\":true}," ++
            "{\"name\":\"delta\",\"version\":\"4.0\",\"type\":\"cask\",\"pinned\":true}" ++
            "],\"formulae\":[" ++
            "{\"name\":\"alpha\",\"version\":\"1.0\",\"pinned\":true}," ++
            "{\"name\":\"charlie\",\"version\":\"3.0\",\"pinned\":true}" ++
            "],\"casks\":[" ++
            "{\"token\":\"bravo\",\"version\":\"2.0\"}," ++
            "{\"token\":\"delta\",\"version\":\"4.0\"}" ++
            "]",
        body,
    );
}

test "buildListJson: --pinned legacy casks array excludes unpinned casks" {
    var t = try TempDb.init("pinned_casks_legacy");
    defer t.deinit();

    try insertCask(&t.db, "loose-cask", "1.0"); // unpinned: must NOT appear
    try t.db.exec(
        \\INSERT INTO casks (token, name, version, url, pinned)
        \\VALUES ('held-cask', 'held-cask', '2.0', 'https://example.invalid', 1);
    );

    const out = try runBuild(testing.allocator, &t.db, false, true, true);
    defer testing.allocator.free(out);

    const body = trimTimeSuffix(out);
    try testing.expectEqualStrings(
        "{\"schema_version\":1,\"installed\":[" ++
            "{\"name\":\"held-cask\",\"version\":\"2.0\",\"type\":\"cask\",\"pinned\":true}" ++
            "],\"casks\":[" ++
            "{\"token\":\"held-cask\",\"version\":\"2.0\"}" ++
            "]",
        body,
    );
}

test "writeHumanOutput --pinned drops the [pinned] tag (every row is pinned by definition)" {
    var t = try TempDb.init("human_pinned_no_tag");
    defer t.deinit();
    try insertKeg(&t.db, "alpha", "1.0", true);
    try t.db.exec(
        \\INSERT INTO casks (token, name, version, url, pinned)
        \\VALUES ('bravo', 'bravo', '2.0', 'https://example.invalid', 1);
    );

    const out = try runHuman(testing.allocator, &t.db, true, true, false, true, false);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "[pinned]") == null);
    try testing.expect(std.mem.indexOf(u8, out, "alpha") != null);
    try testing.expect(std.mem.indexOf(u8, out, "bravo") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[cask]") != null);
}

test "writeHumanOutput --pinned merges pinned formulas + casks in one sorted list" {
    var t = try TempDb.init("human_pinned_mixed");
    defer t.deinit();

    try insertKeg(&t.db, "loose", "1.0", false);
    try insertKeg(&t.db, "zsh", "5.9", true);
    try t.db.exec(
        \\INSERT INTO casks (token, name, version, url, pinned)
        \\VALUES ('firefox', 'firefox', '120.0', 'https://example.invalid', 1);
    );
    try insertCask(&t.db, "slack", "4.0"); // unpinned, must not appear

    const out = try runHuman(testing.allocator, &t.db, true, true, false, true, false);
    defer testing.allocator.free(out);

    // Single sorted output: firefox (cask) then zsh (formula). 'loose' and
    // 'slack' excluded by the pinned filter.
    try testing.expect(std.mem.indexOf(u8, out, "  ▸ firefox") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  ▸ zsh") != null);
    try testing.expect(std.mem.indexOf(u8, out, "loose") == null);
    try testing.expect(std.mem.indexOf(u8, out, "slack") == null);
    try testing.expect(std.mem.indexOf(u8, out, "[cask]") != null);
    const firefox_pos = std.mem.indexOf(u8, out, "firefox").?;
    const zsh_pos = std.mem.indexOf(u8, out, "zsh").?;
    try testing.expect(firefox_pos < zsh_pos);
}

// --- --tap filter ------------------------------------------------------

test "writeHumanOutput --tap scopes formulas and casks to a single tap" {
    var t = try TempDb.init("human_tap");
    defer t.deinit();

    try insertKegTap(&t.db, "tap-formula", "1.0", "user/repo");
    try insertKeg(&t.db, "core-formula", "2.0", false);
    try insertCaskTap(&t.db, "tap-cask", "3.0", "user/repo");
    try insertCask(&t.db, "core-cask", "4.0");

    const out = try runHumanTap(testing.allocator, &t.db, true, true, false, false, true, "user/repo");
    defer testing.allocator.free(out);

    try testing.expectEqualStrings("tap-formula\ntap-cask\n", out);
}

test "writeHumanOutput --tap nonexistent yields empty output (typo guard)" {
    var t = try TempDb.init("human_tap_typo");
    defer t.deinit();

    try insertKegTap(&t.db, "alpha", "1.0", "user/repo");
    try insertCaskTap(&t.db, "bravo", "2.0", "user/repo");

    const out = try runHumanTap(testing.allocator, &t.db, true, true, false, false, true, "user/nope");
    defer testing.allocator.free(out);

    try testing.expectEqualStrings("", out);
}

test "writeHumanOutput --tap combined with --formula scopes to that tap's formulas only" {
    var t = try TempDb.init("human_tap_formula_only");
    defer t.deinit();

    try insertKegTap(&t.db, "alpha", "1.0", "user/repo");
    try insertCaskTap(&t.db, "bravo", "2.0", "user/repo");

    const out = try runHumanTap(testing.allocator, &t.db, true, false, false, false, true, "user/repo");
    defer testing.allocator.free(out);

    try testing.expectEqualStrings("alpha\n", out);
}

test "writeHumanOutput --tap excludes NULL-tap casks (legacy rows treated as unattributed)" {
    // v5-era casks have tap = NULL until upgrade backfills them. The
    // --tap filter is strict equality: NULL never matches, even when
    // the requested label is `homebrew/cask`. The workaround documented
    // in `--help` is `mt upgrade <token>` to trigger attribution.
    var t = try TempDb.init("human_tap_null_excluded");
    defer t.deinit();

    try insertCask(&t.db, "legacy-cask", "1.0"); // tap = NULL

    const out = try runHumanTap(testing.allocator, &t.db, false, true, false, false, true, "homebrew/cask");
    defer testing.allocator.free(out);

    try testing.expectEqualStrings("", out);
}

test "writeHumanOutput --tap combined with --pinned scopes to pinned rows from that tap" {
    var t = try TempDb.init("human_tap_pinned");
    defer t.deinit();

    try t.db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, tap, pinned)
        \\VALUES ('pinned-alpha', 'pinned-alpha', '1.0', 'aa', '/c/pinned-alpha/1.0', 'user/repo', 1),
        \\       ('loose-bravo',  'loose-bravo',  '2.0', 'aa', '/c/loose-bravo/2.0',  'user/repo', 0);
    );

    const out = try runHumanTap(testing.allocator, &t.db, true, true, false, true, true, "user/repo");
    defer testing.allocator.free(out);

    try testing.expectEqualStrings("pinned-alpha\n", out);
}

test "buildListJson --tap filters both installed and legacy arrays" {
    var t = try TempDb.init("json_tap");
    defer t.deinit();

    try insertKegTap(&t.db, "tap-formula", "1.0", "user/repo");
    try insertKeg(&t.db, "core-formula", "2.0", false);
    try insertCaskTap(&t.db, "tap-cask", "3.0", "user/repo");

    const out = try runBuildTap(testing.allocator, &t.db, true, true, false, "user/repo");
    defer testing.allocator.free(out);

    const body = trimTimeSuffix(out);
    try testing.expectEqualStrings(
        "{\"schema_version\":1,\"installed\":[" ++
            "{\"name\":\"tap-formula\",\"version\":\"1.0\",\"type\":\"formula\",\"pinned\":false}," ++
            "{\"name\":\"tap-cask\",\"version\":\"3.0\",\"type\":\"cask\",\"pinned\":false}" ++
            "],\"formulae\":[" ++
            "{\"name\":\"tap-formula\",\"version\":\"1.0\",\"pinned\":false}" ++
            "],\"casks\":[" ++
            "{\"token\":\"tap-cask\",\"version\":\"3.0\"}" ++
            "]",
        body,
    );
}

test "buildListJson --tap with no matches produces empty arrays" {
    var t = try TempDb.init("json_tap_empty");
    defer t.deinit();

    try insertKegTap(&t.db, "alpha", "1.0", "user/repo");

    const out = try runBuildTap(testing.allocator, &t.db, true, true, false, "other/tap");
    defer testing.allocator.free(out);

    const body = trimTimeSuffix(out);
    try testing.expectEqualStrings(
        "{\"schema_version\":1,\"installed\":[],\"formulae\":[],\"casks\":[]",
        body,
    );
}

test "buildListJson --tap with --pinned cross-filters" {
    var t = try TempDb.init("json_tap_pinned");
    defer t.deinit();

    try t.db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, tap, pinned)
        \\VALUES ('held', 'held', '1.0', 'aa', '/c/held/1.0', 'user/repo', 1),
        \\       ('loose', 'loose', '2.0', 'aa', '/c/loose/2.0', 'user/repo', 0);
    );

    const out = try runBuildTap(testing.allocator, &t.db, true, false, true, "user/repo");
    defer testing.allocator.free(out);

    const body = trimTimeSuffix(out);
    try testing.expectEqualStrings(
        "{\"schema_version\":1,\"installed\":[" ++
            "{\"name\":\"held\",\"version\":\"1.0\",\"type\":\"formula\",\"pinned\":true}" ++
            "],\"formulae\":[" ++
            "{\"name\":\"held\",\"version\":\"1.0\",\"pinned\":true}" ++
            "]",
        body,
    );
}

test "buildListJson: output parses as valid JSON" {
    var t = try TempDb.init("valid_json");
    defer t.deinit();

    try insertKeg(&t.db, "tree", "2.1", false);
    try insertCask(&t.db, "obs", "30.0");

    const out = try runBuild(testing.allocator, &t.db, true, true, false);
    defer testing.allocator.free(out);

    // The CLI writes a trailing newline; parseFromSlice tolerates it.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try testing.expect(root.get("installed") != null);
    try testing.expect(root.get("formulae") != null);
    try testing.expect(root.get("casks") != null);
    try testing.expect(root.get("time_ms") != null);
}

test "buildListJson --size --linked output parses as valid JSON with both fields" {
    var t = try TempDb.init("valid_json_extras");
    defer t.deinit();
    try insertKeg(&t.db, "tree", "2.1", false);
    try insertCask(&t.db, "obs", "30.0");

    const out = try runBuildFull(testing.allocator, &t.db, true, true, false, true, true, null, t.dir);
    defer testing.allocator.free(out);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();

    const installed = parsed.value.object.get("installed").?.array;
    try testing.expectEqual(@as(usize, 2), installed.items.len);
    for (installed.items) |row| {
        try testing.expect(row.object.get("size_bytes").? == .integer);
        try testing.expect(row.object.get("linked").? == .bool);
    }
    // Legacy arrays must stay lean — no enrichment leaked into them.
    const legacy_formulae = parsed.value.object.get("formulae").?.array;
    try testing.expect(legacy_formulae.items[0].object.get("size_bytes") == null);
    try testing.expect(legacy_formulae.items[0].object.get("linked") == null);
}

// --- --size ------------------------------------------------------------

test "buildListJson --size sums size_bytes from the keg cellar dir" {
    var t = try TempDb.init("size_formula");
    defer t.deinit();

    var cb: [256]u8 = undefined;
    const cellar = try std.fmt.bufPrint(&cb, "{s}/Cellar/treesize/1.0", .{t.dir});
    try writeTreeFile(cellar, "bin/a", "12345"); // 5 bytes
    try writeTreeFile(cellar, "lib/b", "678"); // 3 bytes

    var sb: [600]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(
        &sb,
        "INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path) VALUES ('treesize','treesize','1.0','deadbeef','{s}');",
        .{cellar},
    );
    try t.db.exec(sql);

    const out = try runBuildFull(testing.allocator, &t.db, true, false, false, true, false, null, t.dir);
    defer testing.allocator.free(out);

    const body = trimTimeSuffix(out);
    try testing.expectEqualStrings(
        "{\"schema_version\":1,\"installed\":[" ++
            "{\"name\":\"treesize\",\"version\":\"1.0\",\"type\":\"formula\",\"pinned\":false,\"size_bytes\":8}" ++
            "],\"formulae\":[" ++
            "{\"name\":\"treesize\",\"version\":\"1.0\",\"pinned\":false}" ++
            "]",
        body,
    );
}

test "buildListJson --size emits size_bytes:0 when the keg cellar dir is missing" {
    // A partial/absent keg dir must not crash the writer — it reads as 0.
    var t = try TempDb.init("size_missing");
    defer t.deinit();
    try insertKeg(&t.db, "ghost", "1.0", false); // cellar_path points nowhere real

    const out = try runBuildFull(testing.allocator, &t.db, true, false, false, true, false, null, t.dir);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"size_bytes\":0") != null);
}

test "buildListJson --size emits size_bytes:0 for an empty cellar dir" {
    var t = try TempDb.init("size_empty");
    defer t.deinit();

    var cb: [256]u8 = undefined;
    const cellar = try std.fmt.bufPrint(&cb, "{s}/Cellar/empty/1.0", .{t.dir});
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, cellar);

    var sb: [600]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(
        &sb,
        "INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path) VALUES ('empty','empty','1.0','deadbeef','{s}');",
        .{cellar},
    );
    try t.db.exec(sql);

    const out = try runBuildFull(testing.allocator, &t.db, true, false, false, true, false, null, t.dir);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"size_bytes\":0") != null);
}

test "buildListJson --size sums a cask's Caskroom dir and app_path bundle" {
    var t = try TempDb.init("size_cask");
    defer t.deinit();

    var crb: [256]u8 = undefined;
    const caskroom = try std.fmt.bufPrint(&crb, "{s}/Caskroom/widget", .{t.dir});
    try writeTreeFile(caskroom, "1.0/data", "abcd"); // 4 bytes in-prefix bookkeeping

    var ab: [256]u8 = undefined;
    const app = try std.fmt.bufPrint(&ab, "{s}/Applications/Widget.app", .{t.dir});
    try writeTreeFile(app, "Contents/MacOS/widget", "binary"); // 6 bytes app payload

    var sb: [700]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(
        &sb,
        "INSERT INTO casks (token, name, version, url, app_path) VALUES ('widget','Widget','1.0','https://example.invalid','{s}');",
        .{app},
    );
    try t.db.exec(sql);

    const out = try runBuildFull(testing.allocator, &t.db, false, true, false, true, false, null, t.dir);
    defer testing.allocator.free(out);

    const body = trimTimeSuffix(out);
    try testing.expectEqualStrings(
        "{\"schema_version\":1,\"installed\":[" ++
            "{\"name\":\"widget\",\"version\":\"1.0\",\"type\":\"cask\",\"pinned\":false,\"size_bytes\":10}" ++
            "],\"casks\":[" ++
            "{\"token\":\"widget\",\"version\":\"1.0\"}" ++
            "]",
        body,
    );
}

test "buildListJson --size on a cask with no app_path counts only the Caskroom dir" {
    // A cask row may carry a NULL app_path; size must fall back to the
    // in-prefix Caskroom dir without crashing the writer.
    var t = try TempDb.init("size_cask_no_app");
    defer t.deinit();

    var crb: [256]u8 = undefined;
    const caskroom = try std.fmt.bufPrint(&crb, "{s}/Caskroom/barecask", .{t.dir});
    try writeTreeFile(caskroom, "1.0/payload", "abcdef"); // 6 bytes
    try insertCask(&t.db, "barecask", "1.0"); // app_path stays NULL

    const out = try runBuildFull(testing.allocator, &t.db, false, true, false, true, false, null, t.dir);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"size_bytes\":6") != null);
}

test "buildListJson --size does not double-count a cask app_path symlinked into Caskroom" {
    // Binary casks symlink their installed name back into the payload that
    // already lives under Caskroom. The symlink-safe walk must count the
    // 7-byte payload once (via Caskroom) and ignore the app_path symlink.
    var t = try TempDb.init("size_cask_symlink");
    defer t.deinit();
    const io = std.Options.debug_io;

    var crb: [256]u8 = undefined;
    const caskroom = try std.fmt.bufPrint(&crb, "{s}/Caskroom/tool", .{t.dir});
    try writeTreeFile(caskroom, "2.0/tool", "1234567"); // 7 bytes

    var binb: [256]u8 = undefined;
    const bindir = try std.fmt.bufPrint(&binb, "{s}/bin", .{t.dir});
    std.Io.Dir.cwd().createDirPath(io, bindir) catch {};
    var tgtb: [320]u8 = undefined;
    const target = try std.fmt.bufPrint(&tgtb, "{s}/2.0/tool", .{caskroom});
    var bd = try std.Io.Dir.openDirAbsolute(io, bindir, .{});
    defer bd.close(io);
    bd.symLink(io, target, "tool", .{}) catch {};

    var appb: [256]u8 = undefined;
    const app = try std.fmt.bufPrint(&appb, "{s}/tool", .{bindir});
    var sb: [700]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(
        &sb,
        "INSERT INTO casks (token, name, version, url, app_path) VALUES ('tool','tool','2.0','https://example.invalid','{s}');",
        .{app},
    );
    try t.db.exec(sql);

    const out = try runBuildFull(testing.allocator, &t.db, false, true, false, true, false, null, t.dir);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"size_bytes\":7") != null);
}

// --- --linked ----------------------------------------------------------

test "buildListJson --linked reports keg link status from the links table" {
    var t = try TempDb.init("linked_formula");
    defer t.deinit();

    try t.db.exec(
        \\INSERT INTO kegs (id, name, full_name, version, store_sha256, cellar_path)
        \\VALUES (1,'active','active','1.0','aa','/c/active/1.0'),
        \\       (2,'dormant','dormant','2.0','bb','/c/dormant/2.0');
    );
    // Only the first keg has a recorded symlink.
    try t.db.exec(
        \\INSERT INTO links (keg_id, link_path, target)
        \\VALUES (1,'/opt/malt/bin/active','/c/active/1.0/bin/active');
    );

    const out = try runBuildFull(testing.allocator, &t.db, true, false, false, false, true, null, t.dir);
    defer testing.allocator.free(out);

    const body = trimTimeSuffix(out);
    try testing.expectEqualStrings(
        "{\"schema_version\":1,\"installed\":[" ++
            "{\"name\":\"active\",\"version\":\"1.0\",\"type\":\"formula\",\"pinned\":false,\"linked\":true}," ++
            "{\"name\":\"dormant\",\"version\":\"2.0\",\"type\":\"formula\",\"pinned\":false,\"linked\":false}" ++
            "],\"formulae\":[" ++
            "{\"name\":\"active\",\"version\":\"1.0\",\"pinned\":false}," ++
            "{\"name\":\"dormant\",\"version\":\"2.0\",\"pinned\":false}" ++
            "]",
        body,
    );
}

test "buildListJson --linked reports casks as always linked" {
    // Casks have no prefix-link concept; an installed cask is active.
    var t = try TempDb.init("linked_cask");
    defer t.deinit();
    try insertCask(&t.db, "firefox", "120.0");

    const out = try runBuildFull(testing.allocator, &t.db, false, true, false, false, true, null, t.dir);
    defer testing.allocator.free(out);

    const body = trimTimeSuffix(out);
    try testing.expectEqualStrings(
        "{\"schema_version\":1,\"installed\":[" ++
            "{\"name\":\"firefox\",\"version\":\"120.0\",\"type\":\"cask\",\"pinned\":false,\"linked\":true}" ++
            "],\"casks\":[" ++
            "{\"token\":\"firefox\",\"version\":\"120.0\"}" ++
            "]",
        body,
    );
}

test "buildListJson --size --linked emits size_bytes before linked" {
    // Pins the field order so consumers and the schema doc agree.
    var t = try TempDb.init("size_linked_order");
    defer t.deinit();

    var cb: [256]u8 = undefined;
    const cellar = try std.fmt.bufPrint(&cb, "{s}/Cellar/combo/1.0", .{t.dir});
    try writeTreeFile(cellar, "bin/x", "ab"); // 2 bytes

    var sb: [600]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(
        &sb,
        "INSERT INTO kegs (id, name, full_name, version, store_sha256, cellar_path) VALUES (1,'combo','combo','1.0','aa','{s}');",
        .{cellar},
    );
    try t.db.exec(sql);
    try t.db.exec(
        \\INSERT INTO links (keg_id, link_path, target) VALUES (1,'/opt/malt/bin/combo','/x');
    );

    const out = try runBuildFull(testing.allocator, &t.db, true, false, false, true, true, null, t.dir);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "\"pinned\":false,\"size_bytes\":2,\"linked\":true}",
    ) != null);
}

test "buildListJson --tap --size --linked keeps column alignment in the tap SQL" {
    // The tap SELECT variant carries the same trailing id/cellar_path/
    // app_path columns; this guards their index alignment under a filter.
    var t = try TempDb.init("tap_extras");
    defer t.deinit();

    var cb: [256]u8 = undefined;
    const cellar = try std.fmt.bufPrint(&cb, "{s}/Cellar/tapped/1.0", .{t.dir});
    try writeTreeFile(cellar, "bin/y", "abc"); // 3 bytes

    var sb: [600]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(
        &sb,
        "INSERT INTO kegs (id, name, full_name, version, store_sha256, cellar_path, tap) VALUES (1,'tapped','tapped','1.0','aa','{s}','user/repo');",
        .{cellar},
    );
    try t.db.exec(sql);
    try t.db.exec(
        \\INSERT INTO links (keg_id, link_path, target) VALUES (1,'/opt/malt/bin/tapped','/x');
    );
    // A second keg in a different tap must be excluded by the filter.
    try insertKegTap(&t.db, "other", "9.0", "other/repo");

    const out = try runBuildFull(testing.allocator, &t.db, true, false, false, true, true, "user/repo", t.dir);
    defer testing.allocator.free(out);

    const body = trimTimeSuffix(out);
    try testing.expectEqualStrings(
        "{\"schema_version\":1,\"installed\":[" ++
            "{\"name\":\"tapped\",\"version\":\"1.0\",\"type\":\"formula\",\"pinned\":false,\"size_bytes\":3,\"linked\":true}" ++
            "],\"formulae\":[" ++
            "{\"name\":\"tapped\",\"version\":\"1.0\",\"pinned\":false}" ++
            "]",
        body,
    );
}

// --- --pinned parity ---------------------------------------------------

test "buildListJson --pinned --size --linked enriches the pinned installed rows" {
    var t = try TempDb.init("pinned_extras");
    defer t.deinit();

    var cb: [256]u8 = undefined;
    const cellar = try std.fmt.bufPrint(&cb, "{s}/Cellar/held/1.0", .{t.dir});
    try writeTreeFile(cellar, "bin/h", "abcd"); // 4 bytes

    var sb: [600]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(
        &sb,
        "INSERT INTO kegs (id, name, full_name, version, store_sha256, cellar_path, pinned) VALUES (1,'held','held','1.0','aa','{s}',1);",
        .{cellar},
    );
    try t.db.exec(sql);
    try t.db.exec(
        \\INSERT INTO links (keg_id, link_path, target) VALUES (1,'/opt/malt/bin/held','/x');
    );

    const out = try runBuildFull(testing.allocator, &t.db, true, false, true, true, true, null, t.dir);
    defer testing.allocator.free(out);

    const body = trimTimeSuffix(out);
    try testing.expectEqualStrings(
        "{\"schema_version\":1,\"installed\":[" ++
            "{\"name\":\"held\",\"version\":\"1.0\",\"type\":\"formula\",\"pinned\":true,\"size_bytes\":4,\"linked\":true}" ++
            "],\"formulae\":[" ++
            "{\"name\":\"held\",\"version\":\"1.0\",\"pinned\":true}" ++
            "]",
        body,
    );
}

test "buildListJson --pinned --linked marks pinned casks linked" {
    var t = try TempDb.init("pinned_cask_linked");
    defer t.deinit();
    try t.db.exec(
        \\INSERT INTO casks (token, name, version, url, pinned)
        \\VALUES ('held','held','2.0','https://example.invalid',1);
    );

    const out = try runBuildFull(testing.allocator, &t.db, false, true, true, false, true, null, t.dir);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "\"type\":\"cask\",\"pinned\":true,\"linked\":true",
    ) != null);
}
