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
