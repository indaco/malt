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
        const path = try std.fmt.bufPrint(&buf, "{s}/test.db", .{dir});
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
