//! malt — core/linker Linker struct tests
//! Covers link(), unlink(), linkOpt() and checkConflicts() against a real
//! keg layout inside a temporary prefix.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const sqlite = malt.sqlite;
const schema = malt.schema;
const linker_mod = malt.linker;

fn uniquePrefix(suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        testing.allocator,
        "/tmp/malt_linker_test_{d}_{s}",
        .{ malt.fs_compat.nanoTimestamp(), suffix },
    );
}

fn makeKegWithBinary(prefix: []const u8, name: []const u8, version: []const u8, bin_name: []const u8) ![]u8 {
    const keg = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/Cellar/{s}/{s}",
        .{ prefix, name, version },
    );
    try malt.fs_compat.cwd().makePath(keg);

    const bin_dir = try std.fmt.allocPrint(testing.allocator, "{s}/bin", .{keg});
    defer testing.allocator.free(bin_dir);
    try malt.fs_compat.makeDirAbsolute(bin_dir);

    const bin_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ bin_dir, bin_name });
    defer testing.allocator.free(bin_path);
    const f = try malt.fs_compat.createFileAbsolute(bin_path, .{});
    try f.writeAll("#!/bin/sh\necho hi\n");
    f.close();

    return keg;
}

test "link creates symlinks for every file in a keg and records them in the DB" {
    const prefix = try uniquePrefix("link_basic");
    defer testing.allocator.free(prefix);
    defer malt.fs_compat.deleteTreeAbsolute(prefix) catch {};

    try malt.fs_compat.cwd().makePath(prefix);
    const keg = try makeKegWithBinary(prefix, "foo", "1.0", "foo-tool");
    defer testing.allocator.free(keg);

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    // Insert a row into `kegs` so the linker's FK (if any) is satisfied,
    // and we have a keg_id to record against.
    var insert = try db.prepare(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path)
        \\VALUES (?1, ?2, ?3, ?4, ?5);
    );
    try insert.bindText(1, "foo");
    try insert.bindText(2, "foo");
    try insert.bindText(3, "1.0");
    try insert.bindText(4, "0" ** 64);
    try insert.bindText(5, keg);
    _ = try insert.step();
    insert.finalize();
    const keg_id: i64 = 1;

    var linker = linker_mod.Linker.init(testing.allocator, &db, prefix);
    try linker.link(keg, "foo", keg_id);

    // Symlink should exist at {prefix}/bin/foo-tool -> {keg}/bin/foo-tool
    var link_path_buf: [512]u8 = undefined;
    const link_path = try std.fmt.bufPrint(&link_path_buf, "{s}/bin/foo-tool", .{prefix});
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = try malt.fs_compat.readLinkAbsolute(link_path, &target_buf);
    try testing.expect(std.mem.indexOf(u8, target, "/Cellar/foo/1.0/bin/foo-tool") != null);

    // Row in links table
    var count = try db.prepare("SELECT COUNT(*) FROM links WHERE keg_id = ?1;");
    defer count.finalize();
    try count.bindInt(1, keg_id);
    _ = try count.step();
    try testing.expectEqual(@as(i64, 1), count.columnInt(0));

    // unlink removes both the symlink and the DB row.
    try linker.unlink(keg_id);
    try testing.expectError(error.FileNotFound, malt.fs_compat.openFileAbsolute(link_path, .{}));
}

test "linkOpt creates opt/{name} -> Cellar/{name}/{version}" {
    const prefix = try uniquePrefix("link_opt");
    defer testing.allocator.free(prefix);
    defer malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
    try malt.fs_compat.cwd().makePath(prefix);
    const cellar = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/bar/2.0", .{prefix});
    defer testing.allocator.free(cellar);
    try malt.fs_compat.cwd().makePath(cellar);

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    var linker = linker_mod.Linker.init(testing.allocator, &db, prefix);
    try linker.linkOpt("bar", "2.0");

    var opt_buf: [512]u8 = undefined;
    const opt_path = try std.fmt.bufPrint(&opt_buf, "{s}/opt/bar", .{prefix});
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = try malt.fs_compat.readLinkAbsolute(opt_path, &target_buf);
    try testing.expect(std.mem.endsWith(u8, target, "/Cellar/bar/2.0"));

    // Re-running linkOpt must replace the existing symlink atomically.
    try linker.linkOpt("bar", "2.0");
    const target2 = try malt.fs_compat.readLinkAbsolute(opt_path, &target_buf);
    try testing.expect(std.mem.endsWith(u8, target2, "/Cellar/bar/2.0"));
}

test "checkConflicts flags a symlink that points into a different keg" {
    const prefix = try uniquePrefix("link_conflict");
    defer testing.allocator.free(prefix);
    defer malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
    try malt.fs_compat.cwd().makePath(prefix);

    // Two kegs that both ship a `bin/tool` binary.
    const keg_a = try makeKegWithBinary(prefix, "alpha", "1.0", "tool");
    defer testing.allocator.free(keg_a);
    const keg_b = try makeKegWithBinary(prefix, "beta", "1.0", "tool");
    defer testing.allocator.free(keg_b);

    // Link alpha first.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var linker = linker_mod.Linker.init(testing.allocator, &db, prefix);
    try linker.link(keg_a, "alpha", 1);

    // Now the `bin/tool` symlink points into alpha. Check beta's conflicts.
    const conflicts = try linker.checkConflicts(keg_b);
    defer {
        for (conflicts) |c| {
            testing.allocator.free(c.link_path);
            testing.allocator.free(c.existing_keg);
        }
        testing.allocator.free(conflicts);
    }
    try testing.expect(conflicts.len >= 1);
    var matched = false;
    for (conflicts) |c| {
        if (std.mem.endsWith(u8, c.link_path, "/bin/tool")) {
            matched = true;
            try testing.expect(std.mem.indexOf(u8, c.existing_keg, "alpha") != null);
        }
    }
    try testing.expect(matched);
}

test "checkConflicts is empty when nothing is linked yet" {
    const prefix = try uniquePrefix("link_no_conflict");
    defer testing.allocator.free(prefix);
    defer malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
    try malt.fs_compat.cwd().makePath(prefix);
    const keg = try makeKegWithBinary(prefix, "gamma", "1.0", "tool");
    defer testing.allocator.free(keg);

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var linker = linker_mod.Linker.init(testing.allocator, &db, prefix);

    const conflicts = try linker.checkConflicts(keg);
    defer testing.allocator.free(conflicts);
    try testing.expectEqual(@as(usize, 0), conflicts.len);
}
