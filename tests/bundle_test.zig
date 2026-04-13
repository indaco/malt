//! malt — bundle runner / CLI smoke tests
//!
//! `dry_run = true` lets us exercise the orchestration logic without forking
//! `malt install` for every member.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const sqlite = malt.sqlite;
const schema = malt.schema;
const manifest_mod = malt.bundle_manifest;
const runner = malt.bundle_runner;

const TempDb = struct {
    dir: []const u8,
    db: sqlite.Database,

    fn init(comptime tag: []const u8) !TempDb {
        const dir = "/tmp/malt_bundle_test_" ++ tag;
        std.fs.deleteTreeAbsolute(dir) catch {};
        try std.fs.makeDirAbsolute(dir);
        var db_path_buf: [256]u8 = undefined;
        const db_path = try std.fmt.bufPrint(&db_path_buf, "{s}/test.db", .{dir});
        var db = try sqlite.Database.open(db_path);
        errdefer db.close();
        try schema.initSchema(&db);
        return .{ .dir = dir, .db = db };
    }

    fn deinit(self: *TempDb) void {
        self.db.close();
        std.fs.deleteTreeAbsolute(self.dir) catch {};
    }
};

fn buildManifest(parent: std.mem.Allocator) !manifest_mod.Manifest {
    var m = manifest_mod.Manifest.init(parent);
    const a = m.allocator();
    m.name = try a.dupe(u8, "devtools");
    m.version = manifest_mod.SCHEMA_VERSION;

    const taps = try a.alloc([]const u8, 1);
    taps[0] = try a.dupe(u8, "homebrew/cask-fonts");
    m.taps = taps;

    const formulas = try a.alloc(manifest_mod.FormulaEntry, 2);
    formulas[0] = .{ .name = try a.dupe(u8, "wget") };
    formulas[1] = .{ .name = try a.dupe(u8, "jq"), .version = try a.dupe(u8, "1.7") };
    m.formulas = formulas;

    const casks = try a.alloc(manifest_mod.CaskEntry, 1);
    casks[0] = .{ .name = try a.dupe(u8, "ghostty") };
    m.casks = casks;

    return m;
}

test "dry-run runner does not fork and skips DB write" {
    var t = try TempDb.init("dry_run");
    defer t.deinit();

    var m = try buildManifest(testing.allocator);
    defer m.deinit();

    try runner.run(testing.allocator, &t.db, m, .{ .dry_run = true });

    var stmt = try t.db.prepare("SELECT COUNT(*) FROM bundles;");
    defer stmt.finalize();
    _ = try stmt.step();
    try testing.expectEqual(@as(i64, 0), stmt.columnInt(0));
}

test "non-dry runner with mocked malt_bin records bundle even on member failure" {
    var t = try TempDb.init("record");
    defer t.deinit();

    var m = try buildManifest(testing.allocator);
    defer m.deinit();

    // Use /usr/bin/false: spawns succeed but each call exits non-zero.
    // The runner should still record the bundle row before returning the
    // aggregate MemberFailed error.
    const result = runner.run(testing.allocator, &t.db, m, .{
        .dry_run = false,
        .malt_bin = "/usr/bin/false",
    });
    try testing.expectError(runner.RunnerError.MemberFailed, result);

    var stmt = try t.db.prepare("SELECT COUNT(*) FROM bundles WHERE name='devtools';");
    defer stmt.finalize();
    _ = try stmt.step();
    try testing.expectEqual(@as(i64, 1), stmt.columnInt(0));

    var ms = try t.db.prepare("SELECT COUNT(*) FROM bundle_members WHERE bundle_name='devtools';");
    defer ms.finalize();
    _ = try ms.step();
    // 1 tap + 2 formulas + 1 cask = 4 members
    try testing.expectEqual(@as(i64, 4), ms.columnInt(0));
}

test "round-trip: parse Brewfile fixture, run dry, no panic" {
    var t = try TempDb.init("smoke");
    defer t.deinit();

    const fixture =
        \\tap "homebrew/cask-fonts"
        \\brew "wget"
        \\brew "jq", version: "1.7"
        \\cask "ghostty"
        \\# real-world dotfiles often have these:
        \\whalebrew "foo/bar"
    ;
    var m = try malt.bundle_brewfile.parse(testing.allocator, fixture);
    defer m.deinit();

    try runner.run(testing.allocator, &t.db, m, .{ .dry_run = true });
}
