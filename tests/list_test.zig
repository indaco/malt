//! malt — cli/list JSON output tests
//! Exercises `buildListJson` via an on-disk sqlite DB seeded with kegs
//! and casks, asserting the exact bytes written for the three block
//! shapes (installed / legacy formulae / legacy casks).

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const sqlite = malt.sqlite;
const schema = malt.schema;
const cli_list = malt.cli_list;

const TempDb = struct {
    dir: []const u8,
    db: sqlite.Database,

    fn init(comptime tag: []const u8) !TempDb {
        const dir = "/tmp/malt_list_test_" ++ tag;
        malt.fs_compat.deleteTreeAbsolute(dir) catch {};
        try malt.fs_compat.makeDirAbsolute(dir);
        var buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&buf, "{s}/test.db", .{dir}, 0);
        var db = try sqlite.Database.open(path);
        errdefer db.close();
        try schema.initSchema(&db);
        return .{ .dir = dir, .db = db };
    }

    fn deinit(self: *TempDb) void {
        self.db.close();
        malt.fs_compat.deleteTreeAbsolute(self.dir) catch {};
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

fn insertCask(db: *sqlite.Database, token: []const u8, version: []const u8) !void {
    var buf: [512]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(
        &buf,
        "INSERT INTO casks (token, name, version, url) VALUES ('{s}', '{s}', '{s}', 'https://example.com');",
        .{ token, token, version },
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
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    // Use a fixed start_ts so the ",\"time_ms\":N" suffix is predictable.
    try cli_list.buildListJson(db, &aw.writer, show_formula, show_cask, show_pinned, malt.fs_compat.milliTimestamp());
    return aw.toOwnedSlice();
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
    const prior_quiet = malt.output.isQuiet();
    malt.output.setQuiet(quiet);
    defer malt.output.setQuiet(prior_quiet);
    // `writeHumanOutput` reads colour state via the global; pin to no-color
    // so assertions below stay independent of the host terminal.
    malt.color.setForTest(false, false);
    defer malt.color.setForTest(null, null);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try cli_list.writeHumanOutput(db, show_formula, show_cask, show_versions, show_pinned, &aw.writer);
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
        "{\"installed\":[],\"formulae\":[],\"casks\":[]",
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
        "{\"installed\":[" ++
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
        "{\"installed\":[" ++
            "{\"name\":\"firefox\",\"version\":\"120.0\",\"type\":\"cask\"}" ++
            "],\"casks\":[" ++
            "{\"token\":\"firefox\",\"version\":\"120.0\"}" ++
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
        "{\"installed\":[" ++
            "{\"name\":\"zsh\",\"version\":\"5.9\",\"type\":\"formula\",\"pinned\":false}," ++
            "{\"name\":\"slack\",\"version\":\"4.0\",\"type\":\"cask\"}" ++
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
        "{\"installed\":[" ++
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
        "{\"installed\":[" ++
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
        "{\"installed\":[" ++
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
        "{\"installed\":[" ++
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
