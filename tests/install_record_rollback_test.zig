//! Integration tests for undoing a keg whose DB record failed: the prior
//! install a `--force` reinstall was replacing must survive intact.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");
const sqlite = malt.sqlite;
const schema = malt.schema;
const install = malt.install;
const install_record = malt.install_record;
const linker_mod = malt.linker;
const local = malt.install_local;

const io = std.Options.debug_io;

fn makeKeg(prefix: []const u8, version: []const u8) ![]u8 {
    const keg = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/tool/{s}", .{ prefix, version });
    const bin = try std.fmt.allocPrint(testing.allocator, "{s}/bin", .{keg});
    defer testing.allocator.free(bin);
    try test_io.cwd().createDirPath(io, bin);
    const exe = try std.fmt.allocPrint(testing.allocator, "{s}/tool", .{bin});
    defer testing.allocator.free(exe);
    const f = try test_io.createFileAbsolute(io, exe, .{});
    f.close(io);
    return keg;
}

fn recordLinked(db: *sqlite.Database, linker: *linker_mod.Linker, keg: []const u8, version: []const u8) !void {
    const id = try install_record.recordKegFields(db, .{
        .name = "tool",
        .full_name = "tool",
        .version = version,
        .revision = 0,
        .tap = "",
        .store_sha256 = "",
        .cellar_path = keg,
        .install_reason = "direct",
        .bin_isolated = false,
        .dependencies = &.{},
    }, .{});
    try linker.link(keg, "tool", id, false);
}

fn exists(path: []const u8) bool {
    test_io.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Where `<prefix>/opt/tool` points, or "" when the link is gone.
fn optTarget(prefix: []const u8, buf: []u8) []const u8 {
    var p: [512]u8 = undefined;
    const link = std.fmt.bufPrint(&p, "{s}/opt/tool", .{prefix}) catch return "";
    return test_io.readLinkAbsolute(io, link, buf) catch "";
}

/// Where `<prefix>/bin/tool` points, or "" when the link is gone.
fn binTarget(prefix: []const u8, buf: []u8) []const u8 {
    var p: [512]u8 = undefined;
    const link = std.fmt.bufPrint(&p, "{s}/bin/tool", .{prefix}) catch return "";
    return test_io.readLinkAbsolute(io, link, buf) catch "";
}

test "a failed same-version --force record keeps the keg the prior row points at, linked" {
    const prefix = try test_io.uniqueTempPath(testing.allocator, "record_rollback", "same_version");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(io, prefix) catch {};
    const keg = try makeKeg(prefix, "1.0");
    defer testing.allocator.free(keg);

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var linker = linker_mod.Linker.init(io, testing.allocator, &db, prefix);
    try recordLinked(&db, &linker, keg, "1.0");

    // The pre-link sweep a same-version `--force` runs before recording.
    install.unlinkSameVersionKegLinks(&linker, &db, "tool", keg);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("", binTarget(prefix, &buf));

    install.dropUnrecordedKeg(io, &db, prefix, "tool", "1.0", keg);
    install.relinkKegs(&db, &linker, "tool");

    try testing.expect(exists(keg));
    try testing.expect(std.mem.indexOf(u8, binTarget(prefix, &buf), "Cellar/tool/1.0") != null);
}

test "a failed fresh record removes the keg dir no row points at" {
    const prefix = try test_io.uniqueTempPath(testing.allocator, "record_rollback", "fresh");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(io, prefix) catch {};
    const keg = try makeKeg(prefix, "1.0");
    defer testing.allocator.free(keg);

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    install.dropUnrecordedKeg(io, &db, prefix, "tool", "1.0", keg);

    try testing.expect(!exists(keg));
}

test "a failed other-version --force record drops the new keg and relinks the prior one" {
    const prefix = try test_io.uniqueTempPath(testing.allocator, "record_rollback", "other_version");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(io, prefix) catch {};
    const old_keg = try makeKeg(prefix, "1.0");
    defer testing.allocator.free(old_keg);

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var linker = linker_mod.Linker.init(io, testing.allocator, &db, prefix);
    try recordLinked(&db, &linker, old_keg, "1.0");

    const new_keg = try makeKeg(prefix, "1.1");
    defer testing.allocator.free(new_keg);
    install.unlinkStaleKegLinks(&db, &linker, "tool", new_keg);

    install.dropUnrecordedKeg(io, &db, prefix, "tool", "1.1", new_keg);
    install.relinkKegs(&db, &linker, "tool");

    try testing.expect(!exists(new_keg));
    try testing.expect(exists(old_keg));
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, binTarget(prefix, &buf), "Cellar/tool/1.0") != null);
}

/// Replays `materializeRubyFormula`'s transaction for a tap `--force` over
/// an installed 1.0: record + link 1.1, then hand the tail to the real seam.
/// `fail_commit` makes COMMIT itself error via a deferred FK violation.
fn forceReinstall(prefix: []const u8, new_keg: []const u8, db: *sqlite.Database, linker: *linker_mod.Linker, fail_commit: bool) !void {
    try db.beginTransaction();
    install.unlinkStaleKegLinks(db, linker, "tool", new_keg);
    const id = try install_record.recordKegFields(db, .{
        .name = "tool",
        .full_name = "tool",
        .version = "1.1",
        .revision = 0,
        .tap = "",
        .store_sha256 = "",
        .cellar_path = new_keg,
        .install_reason = "direct",
        .bin_isolated = false,
        .dependencies = &.{},
    }, .{ .in_transaction = true });
    try linker.link(new_keg, "tool", id, false);
    if (fail_commit) {
        try db.exec("PRAGMA defer_foreign_keys=ON;");
        try db.exec("INSERT INTO dependencies(keg_id, dep_name) VALUES(999999, 'ghost');");
    }
    local.commitAndSweep(&malt.app_ctx.debug_ctx, testing.allocator, db, prefix, "tool", new_keg, "1.1", null, true) catch |e| {
        // The errdefer unwind in reverse registration order.
        db.rollback();
        install.dropUnrecordedKeg(io, db, prefix, "tool", "1.1", new_keg);
        install.relinkKegs(db, linker, "tool");
        return e;
    };
    // Production order: opt moves only once the commit is durable.
    try linker.linkOpt("tool", "1.1");
}

test "failed commit keeps the other-version keg a tap --force reinstall was replacing" {
    const prefix = try test_io.uniqueTempPath(testing.allocator, "record_rollback", "commit_fail");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(io, prefix) catch {};
    const old_keg = try makeKeg(prefix, "1.0");
    defer testing.allocator.free(old_keg);

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var linker = linker_mod.Linker.init(io, testing.allocator, &db, prefix);
    try recordLinked(&db, &linker, old_keg, "1.0");
    try linker.linkOpt("tool", "1.0");
    const new_keg = try makeKeg(prefix, "1.1");
    defer testing.allocator.free(new_keg);

    try testing.expectError(error.RecordFailed, forceReinstall(prefix, new_keg, &db, &linker, true));

    var stmt = try db.prepare("SELECT COUNT(*) FROM kegs WHERE name='tool' AND version='1.0';");
    defer stmt.finalize();
    _ = try stmt.step();
    try testing.expectEqual(@as(i64, 1), stmt.columnInt(0));
    try testing.expect(exists(old_keg));
    try testing.expect(!exists(new_keg));
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, binTarget(prefix, &buf), "Cellar/tool/1.0") != null);
    try testing.expect(std.mem.indexOf(u8, optTarget(prefix, &buf), "Cellar/tool/1.0") != null);
}

test "committed tap --force reinstall drops the other-version keg and its row" {
    const prefix = try test_io.uniqueTempPath(testing.allocator, "record_rollback", "commit_ok");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(io, prefix) catch {};
    const old_keg = try makeKeg(prefix, "1.0");
    defer testing.allocator.free(old_keg);

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var linker = linker_mod.Linker.init(io, testing.allocator, &db, prefix);
    try recordLinked(&db, &linker, old_keg, "1.0");
    try linker.linkOpt("tool", "1.0");
    const new_keg = try makeKeg(prefix, "1.1");
    defer testing.allocator.free(new_keg);

    try forceReinstall(prefix, new_keg, &db, &linker, false);

    var stmt = try db.prepare("SELECT COUNT(*) FROM kegs WHERE name='tool' AND version='1.0';");
    defer stmt.finalize();
    _ = try stmt.step();
    try testing.expectEqual(@as(i64, 0), stmt.columnInt(0));
    try testing.expect(!exists(old_keg));
    try testing.expect(exists(new_keg));
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, optTarget(prefix, &buf), "Cellar/tool/1.1") != null);
}

test "a committed install without --force keeps other versions and drops the parked keg" {
    const prefix = try test_io.uniqueTempPath(testing.allocator, "record_rollback", "no_force");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(io, prefix) catch {};
    const old_keg = try makeKeg(prefix, "1.0");
    defer testing.allocator.free(old_keg);
    const new_keg = try makeKeg(prefix, "1.1");
    defer testing.allocator.free(new_keg);
    const aside = try std.fmt.allocPrint(testing.allocator, "{s}/tmp/aside", .{prefix});
    defer testing.allocator.free(aside);
    try test_io.cwd().createDirPath(io, aside);

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try db.beginTransaction();

    try local.commitAndSweep(&malt.app_ctx.debug_ctx, testing.allocator, &db, prefix, "tool", new_keg, "1.1", aside, false);

    try testing.expect(exists(old_keg));
    try testing.expect(!exists(aside));
}

test "a failed commit keeps the parked keg so it can be put back" {
    const prefix = try test_io.uniqueTempPath(testing.allocator, "record_rollback", "aside_kept");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(io, prefix) catch {};
    const new_keg = try makeKeg(prefix, "1.1");
    defer testing.allocator.free(new_keg);
    const aside = try std.fmt.allocPrint(testing.allocator, "{s}/tmp/aside", .{prefix});
    defer testing.allocator.free(aside);
    try test_io.cwd().createDirPath(io, aside);

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try db.beginTransaction();
    try db.exec("PRAGMA defer_foreign_keys=ON;");
    try db.exec("INSERT INTO dependencies(keg_id, dep_name) VALUES(999999, 'ghost');");

    try testing.expectError(error.RecordFailed, local.commitAndSweep(&malt.app_ctx.debug_ctx, testing.allocator, &db, prefix, "tool", new_keg, "1.1", aside, true));
    db.rollback();

    try testing.expect(exists(aside));
}
