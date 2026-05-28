//! Linker bin/sbin-isolation matrix tests.
//!
//! Exercises the `bin_isolated` parameter on `Linker.link` and
//! `Linker.checkConflicts` against a temp-prefix-rooted keg layout.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");
const sqlite = malt.sqlite;
const schema = malt.schema;
const linker_mod = malt.linker;

fn uniquePrefix(suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        testing.allocator,
        "/tmp/malt_linker_iso_{d}_{s}",
        .{ test_io.nanoTimestamp(std.Options.debug_io), suffix },
    );
}

// Build a keg with one file under each named subdir so both
// `bin`/`sbin` and `lib` get exercised in the same fixture.
fn makeKegWithFiles(
    prefix: []const u8,
    name: []const u8,
    version: []const u8,
    subdirs: []const []const u8,
    file_name: []const u8,
) ![]u8 {
    const keg = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/Cellar/{s}/{s}",
        .{ prefix, name, version },
    );
    try test_io.cwd().createDirPath(std.Options.debug_io, keg);

    for (subdirs) |subdir| {
        const sub = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ keg, subdir });
        defer testing.allocator.free(sub);
        try test_io.makeDirAbsolute(std.Options.debug_io, sub);

        const file = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ sub, file_name });
        defer testing.allocator.free(file);
        const f = try test_io.createFileAbsolute(std.Options.debug_io, file, .{});
        try f.writeStreamingAll(std.Options.debug_io, "x\n");
        f.close(std.Options.debug_io);
    }
    return keg;
}

fn seedKegRow(db: *sqlite.Database, name: []const u8, version: []const u8, cellar_path: []const u8) !i64 {
    var insert = try db.prepare(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path)
        \\VALUES (?1, ?2, ?3, ?4, ?5);
    );
    defer insert.finalize();
    try insert.bindText(1, name);
    try insert.bindText(2, name);
    try insert.bindText(3, version);
    try insert.bindText(4, "0" ** 64);
    try insert.bindText(5, cellar_path);
    _ = try insert.step();

    var id_stmt = try db.prepare("SELECT last_insert_rowid();");
    defer id_stmt.finalize();
    _ = try id_stmt.step();
    return id_stmt.columnInt(0);
}

fn pathExists(absolute: []const u8) bool {
    var f = test_io.openFileAbsolute(std.Options.debug_io, absolute, .{}) catch return false;
    f.close(std.Options.debug_io);
    return true;
}

// link(bin_isolated=true) keeps lib/include/share/etc linked but skips
// bin and sbin. The DB row count for the keg must reflect what landed
// on disk — the conflict probe must agree with the materialised state.
test "link with bin_isolated=true skips bin and sbin but links lib" {
    const prefix = try uniquePrefix("iso_true");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);
    const keg = try makeKegWithFiles(prefix, "depkeg", "1.0", &.{ "bin", "sbin", "lib" }, "tool");
    defer testing.allocator.free(keg);

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    const keg_id = try seedKegRow(&db, "depkeg", "1.0", keg);

    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);
    try linker.link(keg, "depkeg", keg_id, true);

    var bin_buf: [512]u8 = undefined;
    const bin_link = try std.fmt.bufPrint(&bin_buf, "{s}/bin/tool", .{prefix});
    try testing.expect(!pathExists(bin_link));

    var sbin_buf: [512]u8 = undefined;
    const sbin_link = try std.fmt.bufPrint(&sbin_buf, "{s}/sbin/tool", .{prefix});
    try testing.expect(!pathExists(sbin_link));

    var lib_buf: [512]u8 = undefined;
    const lib_link = try std.fmt.bufPrint(&lib_buf, "{s}/lib/tool", .{prefix});
    try testing.expect(pathExists(lib_link));

    var count = try db.prepare("SELECT COUNT(*) FROM links WHERE keg_id = ?1;");
    defer count.finalize();
    try count.bindInt(1, keg_id);
    _ = try count.step();
    try testing.expectEqual(@as(i64, 1), count.columnInt(0));
}

// link(bin_isolated=false) behaves exactly like the pre-feature path.
// Pinning this prevents a future refactor from silently flipping the
// default and breaking every existing install.
test "link with bin_isolated=false links bin and sbin (default behaviour)" {
    const prefix = try uniquePrefix("iso_false");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);
    const keg = try makeKegWithFiles(prefix, "directkeg", "1.0", &.{ "bin", "sbin", "lib" }, "tool");
    defer testing.allocator.free(keg);

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    const keg_id = try seedKegRow(&db, "directkeg", "1.0", keg);

    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);
    try linker.link(keg, "directkeg", keg_id, false);

    var bin_buf: [512]u8 = undefined;
    const bin_link = try std.fmt.bufPrint(&bin_buf, "{s}/bin/tool", .{prefix});
    try testing.expect(pathExists(bin_link));

    var sbin_buf: [512]u8 = undefined;
    const sbin_link = try std.fmt.bufPrint(&sbin_buf, "{s}/sbin/tool", .{prefix});
    try testing.expect(pathExists(sbin_link));

    var lib_buf: [512]u8 = undefined;
    const lib_link = try std.fmt.bufPrint(&lib_buf, "{s}/lib/tool", .{prefix});
    try testing.expect(pathExists(lib_link));

    var count = try db.prepare("SELECT COUNT(*) FROM links WHERE keg_id = ?1;");
    defer count.finalize();
    try count.bindInt(1, keg_id);
    _ = try count.step();
    try testing.expectEqual(@as(i64, 3), count.columnInt(0));
}

// Two isolated deps that ship the same bin name must not produce a
// spurious conflict — neither one will materialise the link, so
// `checkConflicts` should probe-skip bin/sbin before opening them.
test "checkConflicts with bin_isolated=true skips bin and sbin probes" {
    const prefix = try uniquePrefix("iso_conflict_skip");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);

    const keg_a = try makeKegWithFiles(prefix, "depa", "1.0", &.{"bin"}, "tool");
    defer testing.allocator.free(keg_a);
    const keg_b = try makeKegWithFiles(prefix, "depb", "1.0", &.{"bin"}, "tool");
    defer testing.allocator.free(keg_b);

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    const a_id = try seedKegRow(&db, "depa", "1.0", keg_a);

    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);
    try linker.link(keg_a, "depa", a_id, false);

    // Now depb wants to install under isolation: even though depa owns
    // <prefix>/bin/tool, the probe must skip bin and report zero.
    const conflicts = try linker.checkConflicts(keg_b, true);
    defer {
        for (conflicts) |c| {
            testing.allocator.free(c.link_path);
            testing.allocator.free(c.existing_keg);
        }
        testing.allocator.free(conflicts);
    }
    try testing.expectEqual(@as(usize, 0), conflicts.len);
}

// And the same pair without isolation must still surface the conflict
// — the bin_isolated=false branch keeps today's contract.
test "checkConflicts with bin_isolated=false still flags bin collisions" {
    const prefix = try uniquePrefix("iso_conflict_keep");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);

    const keg_a = try makeKegWithFiles(prefix, "alpha", "1.0", &.{"bin"}, "tool");
    defer testing.allocator.free(keg_a);
    const keg_b = try makeKegWithFiles(prefix, "beta", "1.0", &.{"bin"}, "tool");
    defer testing.allocator.free(keg_b);

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    const a_id = try seedKegRow(&db, "alpha", "1.0", keg_a);

    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);
    try linker.link(keg_a, "alpha", a_id, false);

    const conflicts = try linker.checkConflicts(keg_b, false);
    defer {
        for (conflicts) |c| {
            testing.allocator.free(c.link_path);
            testing.allocator.free(c.existing_keg);
        }
        testing.allocator.free(conflicts);
    }
    try testing.expect(conflicts.len >= 1);
}
