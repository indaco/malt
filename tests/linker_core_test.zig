//! malt — core/linker Linker struct tests
//! Covers link(), unlink(), linkOpt() and checkConflicts() against a real
//! keg layout inside a temporary prefix.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");
const sqlite = malt.sqlite;
const schema = malt.schema;
const linker_mod = malt.linker;

fn uniquePrefix(suffix: []const u8) ![]const u8 {
    return test_io.uniqueTempPath(testing.allocator, "linker_test", suffix);
}

fn makeKegWithBinary(prefix: []const u8, name: []const u8, version: []const u8, bin_name: []const u8) ![]u8 {
    const keg = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/Cellar/{s}/{s}",
        .{ prefix, name, version },
    );
    try test_io.cwd().createDirPath(std.Options.debug_io, keg);

    const bin_dir = try std.fmt.allocPrint(testing.allocator, "{s}/bin", .{keg});
    defer testing.allocator.free(bin_dir);
    try test_io.makeDirAbsolute(std.Options.debug_io, bin_dir);

    const bin_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ bin_dir, bin_name });
    defer testing.allocator.free(bin_path);
    const f = try test_io.createFileAbsolute(std.Options.debug_io, bin_path, .{});
    try f.writeStreamingAll(std.Options.debug_io, "#!/bin/sh\necho hi\n");
    f.close(std.Options.debug_io);

    return keg;
}

test "link creates symlinks for every file in a keg and records them in the DB" {
    const prefix = try uniquePrefix("link_basic");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);
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

    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);
    try linker.link(keg, "foo", keg_id, false);

    // Symlink should exist at {prefix}/bin/foo-tool -> {keg}/bin/foo-tool
    var link_path_buf: [512]u8 = undefined;
    const link_path = try std.fmt.bufPrint(&link_path_buf, "{s}/bin/foo-tool", .{prefix});
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = try test_io.readLinkAbsolute(std.Options.debug_io, link_path, &target_buf);
    try testing.expect(std.mem.indexOf(u8, target, "/Cellar/foo/1.0/bin/foo-tool") != null);

    // Row in links table
    var count = try db.prepare("SELECT COUNT(*) FROM links WHERE keg_id = ?1;");
    defer count.finalize();
    try count.bindInt(1, keg_id);
    _ = try count.step();
    try testing.expectEqual(@as(i64, 1), count.columnInt(0));

    // unlink removes both the symlink and the DB row.
    try linker.unlink(keg_id);
    try testing.expectError(error.FileNotFound, test_io.openFileAbsolute(std.Options.debug_io, link_path, .{}));
}

fn insertKeg(db: *sqlite.Database, id: i64, name: []const u8, cellar_path: []const u8) !void {
    var s = try db.prepare(
        \\INSERT INTO kegs (id, name, full_name, version, store_sha256, cellar_path)
        \\VALUES (?1, ?2, ?2, '1.0', 'aa', ?3);
    );
    defer s.finalize();
    try s.bindInt(1, id);
    try s.bindText(2, name);
    try s.bindText(3, cellar_path);
    _ = try s.step();
}

fn writeFile(path: []const u8, body: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try test_io.cwd().createDirPath(std.Options.debug_io, parent);
    }
    const f = try test_io.createFileAbsolute(std.Options.debug_io, path, .{});
    defer f.close(std.Options.debug_io);
    try f.writeStreamingAll(std.Options.debug_io, body);
}

test "link mirrors nested keg subdirectories and records each nested leaf" {
    const prefix = try uniquePrefix("link_nested");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);

    const keg = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/nest/1.0", .{prefix});
    defer testing.allocator.free(keg);

    // Depth-1 leaf, a nested chain four levels deep, and two sibling subdirs
    // under one linkable dir (share/locale + share/man) — the sibling case
    // must not stop after the first leaf.
    const bin = try std.fmt.allocPrint(testing.allocator, "{s}/bin/tool", .{keg});
    defer testing.allocator.free(bin);
    const pc = try std.fmt.allocPrint(testing.allocator, "{s}/lib/pkgconfig/nest.pc", .{keg});
    defer testing.allocator.free(pc);
    const mo = try std.fmt.allocPrint(testing.allocator, "{s}/share/locale/en_US/LC_MESSAGES/nest.mo", .{keg});
    defer testing.allocator.free(mo);
    const man = try std.fmt.allocPrint(testing.allocator, "{s}/share/man/man1/tool.1", .{keg});
    defer testing.allocator.free(man);
    try writeFile(bin, "#!/bin/sh\n");
    try writeFile(pc, "Name: nest\n");
    try writeFile(mo, "mo\n");
    try writeFile(man, ".TH TOOL 1\n");

    // A keg-shipped symlink leaf (Homebrew ships e.g. lib/libfoo.dylib ->
    // libfoo.1.dylib) must be linked like a file, not descended into. The
    // link's own target is irrelevant here — the linker links to the keg's
    // symlink file, never dereferencing it — so any absolute target works.
    const dylib = try std.fmt.allocPrint(testing.allocator, "{s}/lib/libnest.dylib", .{keg});
    defer testing.allocator.free(dylib);
    const dylib_target = try std.fmt.allocPrint(testing.allocator, "{s}/lib/libnest.1.dylib", .{keg});
    defer testing.allocator.free(dylib_target);
    try test_io.symLinkAbsolute(std.Options.debug_io, dylib_target, dylib, .{});

    // An empty nested dir must contribute no leaf and no prefix dir.
    const empty = try std.fmt.allocPrint(testing.allocator, "{s}/share/empty", .{keg});
    defer testing.allocator.free(empty);
    try test_io.cwd().createDirPath(std.Options.debug_io, empty);

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    // A kegs row so the links FK is satisfied and the rows actually record.
    var ins = try db.prepare(
        \\INSERT INTO kegs (id, name, full_name, version, store_sha256, cellar_path)
        \\VALUES (1, 'nest', 'nest', '1.0', 'aa', ?1);
    );
    try ins.bindText(1, keg);
    _ = try ins.step();
    ins.finalize();

    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);
    try linker.link(keg, "nest", 1, false);

    // Every leaf — nested, sibling, and the keg symlink — must resolve.
    const leaves = [_][]const u8{
        "bin/tool",
        "lib/pkgconfig/nest.pc",
        "lib/libnest.dylib",
        "share/locale/en_US/LC_MESSAGES/nest.mo",
        "share/man/man1/tool.1",
    };
    for (leaves) |leaf| {
        var lp_buf: [512]u8 = undefined;
        const lp = try std.fmt.bufPrint(&lp_buf, "{s}/{s}", .{ prefix, leaf });
        var tgt_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tgt = try test_io.readLinkAbsolute(std.Options.debug_io, lp, &tgt_buf);
        try testing.expect(std.mem.endsWith(u8, tgt, leaf));
    }

    // The empty keg dir is skipped: no prefix dir is created for it.
    var empty_lp_buf: [512]u8 = undefined;
    const empty_lp = try std.fmt.bufPrint(&empty_lp_buf, "{s}/share/empty", .{prefix});
    try testing.expectError(error.FileNotFound, std.Io.Dir.openDirAbsolute(std.Options.debug_io, empty_lp, .{}));

    // One links row per leaf, each keyed on its full nested path so unlink
    // removes it.
    var count = try db.prepare("SELECT COUNT(*) FROM links WHERE keg_id = 1;");
    defer count.finalize();
    _ = try count.step();
    try testing.expectEqual(@as(i64, leaves.len), count.columnInt(0));

    // unlink clears the nested symlinks too.
    try linker.unlink(1);
    var data_lp_buf: [512]u8 = undefined;
    const data_lp = try std.fmt.bufPrint(&data_lp_buf, "{s}/share/man/man1/tool.1", .{prefix});
    try testing.expectError(error.FileNotFound, test_io.openFileAbsolute(std.Options.debug_io, data_lp, .{}));
}

test "checkConflicts detects a nested cross-keg collision" {
    const prefix = try uniquePrefix("link_nested_conflict");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);

    // Two kegs that both ship the same nested man page.
    const keg_a = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/alpha/1.0", .{prefix});
    defer testing.allocator.free(keg_a);
    const keg_b = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/beta/1.0", .{prefix});
    defer testing.allocator.free(keg_b);
    const man_a = try std.fmt.allocPrint(testing.allocator, "{s}/share/man/man1/tool.1", .{keg_a});
    defer testing.allocator.free(man_a);
    const man_b = try std.fmt.allocPrint(testing.allocator, "{s}/share/man/man1/tool.1", .{keg_b});
    defer testing.allocator.free(man_b);
    try writeFile(man_a, ".TH TOOL 1\n");
    try writeFile(man_b, ".TH TOOL 1\n");

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try insertKeg(&db, 1, "alpha", keg_a);
    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);
    try linker.link(keg_a, "alpha", 1, false);

    const conflicts = try linker.checkConflicts(keg_b, false);
    defer {
        for (conflicts) |c| {
            testing.allocator.free(c.link_path);
            testing.allocator.free(c.existing_keg);
        }
        testing.allocator.free(conflicts);
    }
    var matched = false;
    for (conflicts) |c| {
        if (std.mem.endsWith(u8, c.link_path, "/share/man/man1/tool.1")) {
            matched = true;
            try testing.expect(std.mem.indexOf(u8, c.existing_keg, "alpha") != null);
        }
    }
    try testing.expect(matched);
}

test "unlink prunes emptied nested dirs but keeps dirs another keg still links" {
    const prefix = try uniquePrefix("unlink_prune");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);

    // Two kegs share share/man/man1; each ships its own page there.
    const keg_a = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/alpha/1.0", .{prefix});
    defer testing.allocator.free(keg_a);
    const keg_b = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/beta/1.0", .{prefix});
    defer testing.allocator.free(keg_b);
    const man_a = try std.fmt.allocPrint(testing.allocator, "{s}/share/man/man1/a.1", .{keg_a});
    defer testing.allocator.free(man_a);
    const man_b = try std.fmt.allocPrint(testing.allocator, "{s}/share/man/man1/b.1", .{keg_b});
    defer testing.allocator.free(man_b);
    try writeFile(man_a, ".TH A 1\n");
    try writeFile(man_b, ".TH B 1\n");

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var ins = try db.prepare(
        \\INSERT INTO kegs (id, name, full_name, version, store_sha256, cellar_path)
        \\VALUES (1, 'alpha', 'alpha', '1.0', 'aa', ?1), (2, 'beta', 'beta', '1.0', 'bb', ?2);
    );
    try ins.bindText(1, keg_a);
    try ins.bindText(2, keg_b);
    _ = try ins.step();
    ins.finalize();

    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);
    try linker.link(keg_a, "alpha", 1, false);
    try linker.link(keg_b, "beta", 2, false);

    // Unlink alpha: its page goes, but beta's b.1 keeps share/man/man1 alive.
    try linker.unlink(1);
    var man1_buf: [512]u8 = undefined;
    const man1 = try std.fmt.bufPrint(&man1_buf, "{s}/share/man/man1", .{prefix});
    var d = try std.Io.Dir.openDirAbsolute(std.Options.debug_io, man1, .{});
    d.close(std.Options.debug_io);

    // Unlink beta: now share/man/man1, share/man and share are all empty and
    // must be pruned — no lingering nested dirs — while the prefix survives.
    try linker.unlink(2);
    for ([_][]const u8{ "share/man/man1", "share/man", "share" }) |sub| {
        var buf: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ prefix, sub });
        try testing.expectError(error.FileNotFound, std.Io.Dir.openDirAbsolute(std.Options.debug_io, p, .{}));
    }
    var pd = try std.Io.Dir.openDirAbsolute(std.Options.debug_io, prefix, .{});
    pd.close(std.Options.debug_io);
}

test "unlink still prunes emptied nested dirs when the link file is already gone" {
    // unlink treats the DB rows as the source of truth: even if a symlink
    // was removed out-of-band, the emptied nested dirs must still be pruned.
    const prefix = try uniquePrefix("unlink_prune_gone");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);

    const keg = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/nest/1.0", .{prefix});
    defer testing.allocator.free(keg);
    const man = try std.fmt.allocPrint(testing.allocator, "{s}/share/man/man1/tool.1", .{keg});
    defer testing.allocator.free(man);
    try writeFile(man, ".TH TOOL 1\n");

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var ins = try db.prepare(
        \\INSERT INTO kegs (id, name, full_name, version, store_sha256, cellar_path)
        \\VALUES (1, 'nest', 'nest', '1.0', 'aa', ?1);
    );
    try ins.bindText(1, keg);
    _ = try ins.step();
    ins.finalize();

    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);
    try linker.link(keg, "nest", 1, false);

    // Remove the symlink out-of-band; the DB row still points at it.
    var lp_buf: [512]u8 = undefined;
    const lp = try std.fmt.bufPrint(&lp_buf, "{s}/share/man/man1/tool.1", .{prefix});
    try test_io.cwd().deleteFile(std.Options.debug_io, lp);

    try linker.unlink(1);
    var man1_buf: [512]u8 = undefined;
    const man1 = try std.fmt.bufPrint(&man1_buf, "{s}/share/man/man1", .{prefix});
    try testing.expectError(error.FileNotFound, std.Io.Dir.openDirAbsolute(std.Options.debug_io, man1, .{}));
}

test "checkConflicts under bin_isolated skips bin but still catches nested lib conflicts" {
    const prefix = try uniquePrefix("conflict_isolated");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);

    // Both kegs ship the same bin and the same nested lib/pkgconfig file.
    const keg_a = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/alpha/1.0", .{prefix});
    defer testing.allocator.free(keg_a);
    const keg_b = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/beta/1.0", .{prefix});
    defer testing.allocator.free(keg_b);
    for ([_][]const u8{ keg_a, keg_b }) |k| {
        const bin = try std.fmt.allocPrint(testing.allocator, "{s}/bin/tool", .{k});
        defer testing.allocator.free(bin);
        const pc = try std.fmt.allocPrint(testing.allocator, "{s}/lib/pkgconfig/lib.pc", .{k});
        defer testing.allocator.free(pc);
        try writeFile(bin, "#!/bin/sh\n");
        try writeFile(pc, "Name: lib\n");
    }

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var ins = try db.prepare(
        \\INSERT INTO kegs (id, name, full_name, version, store_sha256, cellar_path)
        \\VALUES (1, 'alpha', 'alpha', '1.0', 'aa', ?1);
    );
    try ins.bindText(1, keg_a);
    _ = try ins.step();
    ins.finalize();

    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);
    try linker.link(keg_a, "alpha", 1, false);

    // Isolated probe: bin is not linked for an isolated dep, so a bin
    // collision must be suppressed, but the nested lib one must still fire.
    const conflicts = try linker.checkConflicts(keg_b, true);
    defer {
        for (conflicts) |c| {
            testing.allocator.free(c.link_path);
            testing.allocator.free(c.existing_keg);
        }
        testing.allocator.free(conflicts);
    }
    var lib_hit = false;
    for (conflicts) |c| {
        try testing.expect(!std.mem.endsWith(u8, c.link_path, "/bin/tool"));
        if (std.mem.endsWith(u8, c.link_path, "/lib/pkgconfig/lib.pc")) lib_hit = true;
    }
    try testing.expect(lib_hit);
}

test "re-linking a nested keg is idempotent: no error, no duplicate rows" {
    const prefix = try uniquePrefix("relink_nested");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);

    const keg = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/nest/1.0", .{prefix});
    defer testing.allocator.free(keg);
    const pc = try std.fmt.allocPrint(testing.allocator, "{s}/lib/pkgconfig/nest.pc", .{keg});
    defer testing.allocator.free(pc);
    const man = try std.fmt.allocPrint(testing.allocator, "{s}/share/man/man1/tool.1", .{keg});
    defer testing.allocator.free(man);
    try writeFile(pc, "Name: nest\n");
    try writeFile(man, ".TH TOOL 1\n");

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var ins = try db.prepare(
        \\INSERT INTO kegs (id, name, full_name, version, store_sha256, cellar_path)
        \\VALUES (1, 'nest', 'nest', '1.0', 'aa', ?1);
    );
    try ins.bindText(1, keg);
    _ = try ins.step();
    ins.finalize();

    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);
    // The nested tmp-symlink-then-rename path must survive a second run: the
    // rename lands atop the existing link, INSERT OR REPLACE dedups the row.
    try linker.link(keg, "nest", 1, false);
    try linker.link(keg, "nest", 1, false);

    var count = try db.prepare("SELECT COUNT(*) FROM links WHERE keg_id = 1;");
    defer count.finalize();
    _ = try count.step();
    try testing.expectEqual(@as(i64, 2), count.columnInt(0));

    var lp_buf: [512]u8 = undefined;
    const lp = try std.fmt.bufPrint(&lp_buf, "{s}/share/man/man1/tool.1", .{prefix});
    var tgt_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tgt = try test_io.readLinkAbsolute(std.Options.debug_io, lp, &tgt_buf);
    try testing.expect(std.mem.endsWith(u8, tgt, "share/man/man1/tool.1"));
}

test "link propagates a DB write failure and backs out the orphaned symlink" {
    // No kegs row -> the links FK insert fails. link() must surface the error
    // (so install can roll back) and leave no symlink the DB can't track.
    const prefix = try uniquePrefix("link_db_fail");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);

    const keg = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/nest/1.0", .{prefix});
    defer testing.allocator.free(keg);
    const bin = try std.fmt.allocPrint(testing.allocator, "{s}/bin/tool", .{keg});
    defer testing.allocator.free(bin);
    try writeFile(bin, "#!/bin/sh\n");

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);

    // FK violation propagates instead of being swallowed.
    try testing.expectError(sqlite.SqliteError.ConstraintViolation, linker.link(keg, "nest", 1, false));

    // The symlink created just before the failed insert was backed out.
    var lp_buf: [512]u8 = undefined;
    const lp = try std.fmt.bufPrint(&lp_buf, "{s}/bin/tool", .{prefix});
    try testing.expectError(error.FileNotFound, test_io.openFileAbsolute(std.Options.debug_io, lp, .{}));
}

test "link joins a transaction the caller already holds instead of nesting one" {
    // `rollback` and `upgrade` wrap their DB work — including the link call —
    // in one transaction. SQLite has no nested BEGIN, so batching the link
    // rows must piggyback on the open transaction rather than open its own.
    const prefix = try uniquePrefix("link_in_caller_txn");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);

    const keg = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/nest/1.0", .{prefix});
    defer testing.allocator.free(keg);
    const bin = try std.fmt.allocPrint(testing.allocator, "{s}/bin/tool", .{keg});
    defer testing.allocator.free(bin);
    const man = try std.fmt.allocPrint(testing.allocator, "{s}/share/man/man1/tool.1", .{keg});
    defer testing.allocator.free(man);
    try writeFile(bin, "#!/bin/sh\n");
    try writeFile(man, ".TH TOOL 1\n");

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try insertKeg(&db, 1, "nest", keg);

    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);
    try db.beginTransaction();
    try linker.link(keg, "nest", 1, false);
    try db.commit();

    var count = try db.prepare("SELECT COUNT(*) FROM links WHERE keg_id = 1;");
    defer count.finalize();
    _ = try count.step();
    try testing.expectEqual(@as(i64, 2), count.columnInt(0));
}

test "a failed link leaves no transaction open and keeps the rows it did write" {
    // The batched rows are a ledger of symlinks already on disk: after a
    // mid-run failure the caller's `unlink(keg_id)` is what sweeps them, so
    // the rows must survive — and the connection must be back in autocommit
    // so the next writer isn't locked out.
    const prefix = try uniquePrefix("link_fail_txn_state");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);

    const keg = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/nest/1.0", .{prefix});
    defer testing.allocator.free(keg);
    const bin = try std.fmt.allocPrint(testing.allocator, "{s}/bin/tool", .{keg});
    defer testing.allocator.free(bin);
    try writeFile(bin, "#!/bin/sh\n");

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    // No kegs row: every links insert violates the FK.
    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);
    try testing.expectError(sqlite.SqliteError.ConstraintViolation, linker.link(keg, "nest", 1, false));

    // A leaked open transaction would make this BEGIN fail.
    try db.beginTransaction();
    try db.commit();
}

test "a leaf failing mid-run keeps the rows already written so unlink can sweep them" {
    // The batched rows are a ledger of symlinks already on disk. `link` runs
    // subdirs in `linkable_dirs` order, so bin/tool is recorded before
    // lib/boom.so aborts — and the bin row must survive the failure, or
    // install's `unlink(keg_id)` rollback leaves that symlink stranded.
    const prefix = try uniquePrefix("link_partial_ledger");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);

    const keg = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/nest/1.0", .{prefix});
    defer testing.allocator.free(keg);
    const bin = try std.fmt.allocPrint(testing.allocator, "{s}/bin/tool", .{keg});
    defer testing.allocator.free(bin);
    const boom = try std.fmt.allocPrint(testing.allocator, "{s}/lib/boom.so", .{keg});
    defer testing.allocator.free(boom);
    try writeFile(bin, "#!/bin/sh\n");
    try writeFile(boom, "x\n");

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try insertKeg(&db, 1, "nest", keg);
    // Fail exactly one leaf, deterministically, after a good one has landed.
    try db.exec(
        \\CREATE TRIGGER boom_guard BEFORE INSERT ON links
        \\WHEN NEW.link_path LIKE '%boom.so'
        \\BEGIN SELECT RAISE(ABORT, 'boom'); END;
    );

    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);
    try testing.expectError(sqlite.SqliteError.ConstraintViolation, linker.link(keg, "nest", 1, false));

    // The bin row committed despite the later abort...
    var count = try db.prepare("SELECT COUNT(*) FROM links WHERE keg_id = 1 AND link_path LIKE '%bin/tool';");
    defer count.finalize();
    _ = try count.step();
    try testing.expectEqual(@as(i64, 1), count.columnInt(0));

    // ...and it describes a symlink that really is on disk, so unlink sweeps it.
    var lp_buf: [512]u8 = undefined;
    const lp = try std.fmt.bufPrint(&lp_buf, "{s}/bin/tool", .{prefix});
    var tgt_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = try test_io.readLinkAbsolute(std.Options.debug_io, lp, &tgt_buf);

    try linker.unlink(1);
    try testing.expectError(error.FileNotFound, test_io.openFileAbsolute(std.Options.debug_io, lp, .{}));
}

test "link replaces a leaf already occupied by another keg's symlink" {
    // Linking straight to the leaf name hits EEXIST when a prior keg owns the
    // slot; the replacement must land, not be skipped, and must not leave the
    // temp name behind.
    const prefix = try uniquePrefix("link_replace_existing");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);

    const keg_a = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/alpha/1.0", .{prefix});
    defer testing.allocator.free(keg_a);
    const keg_b = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/beta/1.0", .{prefix});
    defer testing.allocator.free(keg_b);
    // A nested leaf and a depth-1 one: the temp name is built differently when
    // `rel` has no parent component, so both branches need to replace cleanly.
    for ([_][]const u8{ keg_a, keg_b }) |k| {
        const man = try std.fmt.allocPrint(testing.allocator, "{s}/share/man/man1/tool.1", .{k});
        defer testing.allocator.free(man);
        const bin = try std.fmt.allocPrint(testing.allocator, "{s}/bin/tool", .{k});
        defer testing.allocator.free(bin);
        try writeFile(man, ".TH TOOL 1\n");
        try writeFile(bin, "#!/bin/sh\n");
    }

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try insertKeg(&db, 1, "alpha", keg_a);
    try insertKeg(&db, 2, "beta", keg_b);

    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);
    try linker.link(keg_a, "alpha", 1, false);
    try linker.link(keg_b, "beta", 2, false);

    for ([_][]const u8{ "share/man/man1/tool.1", "bin/tool" }) |leaf| {
        var lp_buf: [512]u8 = undefined;
        const lp = try std.fmt.bufPrint(&lp_buf, "{s}/{s}", .{ prefix, leaf });
        var tgt_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tgt = try test_io.readLinkAbsolute(std.Options.debug_io, lp, &tgt_buf);
        try testing.expect(std.mem.indexOf(u8, tgt, "/Cellar/beta/1.0/") != null);
    }

    // No `.malt_tmp_*` residue in either destination directory.
    for ([_][]const u8{ "share/man/man1", "bin" }) |sub| {
        var dir_buf: [512]u8 = undefined;
        const dp = try std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ prefix, sub });
        var d = try std.Io.Dir.openDirAbsolute(std.Options.debug_io, dp, .{ .iterate = true });
        defer d.close(std.Options.debug_io);
        var it = d.iterate();
        while (try it.next(std.Options.debug_io)) |entry| {
            try testing.expect(!std.mem.startsWith(u8, entry.name, ".malt_tmp_"));
        }
    }
}

test "a keg with nothing linkable succeeds and records no rows" {
    // Batching opens a transaction up front, so the no-leaf case now runs an
    // empty BEGIN/COMMIT that has to close cleanly.
    const prefix = try uniquePrefix("link_nothing");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);

    // Only a non-linkable dir, so no subdir in linkable_dirs yields a leaf.
    const keg = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/bare/1.0", .{prefix});
    defer testing.allocator.free(keg);
    const doc = try std.fmt.allocPrint(testing.allocator, "{s}/doc/README", .{keg});
    defer testing.allocator.free(doc);
    try writeFile(doc, "nothing to link\n");

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try insertKeg(&db, 1, "bare", keg);

    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);
    try linker.link(keg, "bare", 1, false);

    var count = try db.prepare("SELECT COUNT(*) FROM links WHERE keg_id = 1;");
    defer count.finalize();
    _ = try count.step();
    try testing.expectEqual(@as(i64, 0), count.columnInt(0));

    // The connection is back in autocommit: the empty transaction closed.
    try db.beginTransaction();
    try db.commit();
}

test "a leaf slot held by a directory is skipped, not forced" {
    // alpha puts a real directory at share/data; beta ships a file there.
    // Linking beta cannot win that slot, and must skip the leaf without
    // erroring or disturbing what alpha already linked.
    const prefix = try uniquePrefix("link_leaf_is_dir");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);

    const keg_a = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/alpha/1.0", .{prefix});
    defer testing.allocator.free(keg_a);
    const keg_b = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/beta/1.0", .{prefix});
    defer testing.allocator.free(keg_b);
    const inner = try std.fmt.allocPrint(testing.allocator, "{s}/share/data/inner", .{keg_a});
    defer testing.allocator.free(inner);
    const file_b = try std.fmt.allocPrint(testing.allocator, "{s}/share/data", .{keg_b});
    defer testing.allocator.free(file_b);
    try writeFile(inner, "inner\n");
    try writeFile(file_b, "payload\n");

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try insertKeg(&db, 1, "alpha", keg_a);
    try insertKeg(&db, 2, "beta", keg_b);

    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);
    try linker.link(keg_a, "alpha", 1, false);
    // Must not error even though beta's only leaf cannot be placed.
    try linker.link(keg_b, "beta", 2, false);

    // alpha's nested link survives, and beta recorded no row for the lost leaf.
    var lp_buf: [512]u8 = undefined;
    const lp = try std.fmt.bufPrint(&lp_buf, "{s}/share/data/inner", .{prefix});
    var tgt_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = try test_io.readLinkAbsolute(std.Options.debug_io, lp, &tgt_buf);

    var count = try db.prepare("SELECT COUNT(*) FROM links WHERE keg_id = 2;");
    defer count.finalize();
    _ = try count.step();
    try testing.expectEqual(@as(i64, 0), count.columnInt(0));
}

test "checkConflicts flags a file-vs-directory collision the symlink probe misses" {
    const prefix = try uniquePrefix("conflict_filedir");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);

    // alpha ships a FILE at share/data; beta ships share/data/inner (so beta
    // needs `data` to be a directory). Linking beta would fail — the
    // pre-check must not report a clean bill of health.
    const keg_a = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/alpha/1.0", .{prefix});
    defer testing.allocator.free(keg_a);
    const keg_b = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/beta/1.0", .{prefix});
    defer testing.allocator.free(keg_b);
    const file_a = try std.fmt.allocPrint(testing.allocator, "{s}/share/data", .{keg_a});
    defer testing.allocator.free(file_a);
    const file_b = try std.fmt.allocPrint(testing.allocator, "{s}/share/data/inner", .{keg_b});
    defer testing.allocator.free(file_b);
    try writeFile(file_a, "payload\n");
    try writeFile(file_b, "inner\n");

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try insertKeg(&db, 1, "alpha", keg_a);
    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);
    try linker.link(keg_a, "alpha", 1, false);

    const conflicts = try linker.checkConflicts(keg_b, false);
    defer {
        for (conflicts) |c| {
            testing.allocator.free(c.link_path);
            testing.allocator.free(c.existing_keg);
        }
        testing.allocator.free(conflicts);
    }
    var hit = false;
    for (conflicts) |c| {
        if (std.mem.endsWith(u8, c.link_path, "/share/data")) hit = true;
    }
    try testing.expect(hit);
}

test "link handles a nested path longer than 512 bytes without dropping it" {
    // Two ~250-char component dirs push the composed path past the old 512-byte
    // buffers; the leaf must still be linked (no silent truncation drop).
    const prefix = try uniquePrefix("link_deep");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);

    const seg = "d" ** 250;
    const rel = try std.fmt.allocPrint(testing.allocator, "share/{s}/{s}/leaf.txt", .{ seg, seg });
    defer testing.allocator.free(rel);
    const keg = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/nest/1.0", .{prefix});
    defer testing.allocator.free(keg);
    const leaf = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ keg, rel });
    defer testing.allocator.free(leaf);
    try writeFile(leaf, "deep\n");

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try insertKeg(&db, 1, "nest", keg);
    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);
    try linker.link(keg, "nest", 1, false);

    var lp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const lp = try std.fmt.bufPrint(&lp_buf, "{s}/{s}", .{ prefix, rel });
    var tgt_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tgt = try test_io.readLinkAbsolute(std.Options.debug_io, lp, &tgt_buf);
    try testing.expect(std.mem.endsWith(u8, tgt, "leaf.txt"));
}

test "linkOpt creates opt/{name} -> Cellar/{name}/{version}" {
    const prefix = try uniquePrefix("link_opt");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);
    const cellar = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/bar/2.0", .{prefix});
    defer testing.allocator.free(cellar);
    try test_io.cwd().createDirPath(std.Options.debug_io, cellar);

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);
    try linker.linkOpt("bar", "2.0");

    var opt_buf: [512]u8 = undefined;
    const opt_path = try std.fmt.bufPrint(&opt_buf, "{s}/opt/bar", .{prefix});
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = try test_io.readLinkAbsolute(std.Options.debug_io, opt_path, &target_buf);
    try testing.expect(std.mem.endsWith(u8, target, "/Cellar/bar/2.0"));

    // Re-running linkOpt must replace the existing symlink atomically.
    try linker.linkOpt("bar", "2.0");
    const target2 = try test_io.readLinkAbsolute(std.Options.debug_io, opt_path, &target_buf);
    try testing.expect(std.mem.endsWith(u8, target2, "/Cellar/bar/2.0"));
}

test "linkOpt replaces a stale regular file at opt/{name}" {
    // `deleteFile` clears regular files (and stale symlinks), so the
    // symLink call must still succeed — only a true obstruction (a
    // non-removable directory) should surface as an error.
    const prefix = try uniquePrefix("link_opt_regular_file");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);

    const opt_parent = try std.fmt.allocPrint(testing.allocator, "{s}/opt", .{prefix});
    defer testing.allocator.free(opt_parent);
    try test_io.cwd().createDirPath(std.Options.debug_io, opt_parent);
    const stale = try std.fmt.allocPrint(testing.allocator, "{s}/wget", .{opt_parent});
    defer testing.allocator.free(stale);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, stale, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "stale\n");
    }

    const cellar = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/wget/1.0", .{prefix});
    defer testing.allocator.free(cellar);
    try test_io.cwd().createDirPath(std.Options.debug_io, cellar);

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);
    try linker.linkOpt("wget", "1.0");

    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = try test_io.readLinkAbsolute(std.Options.debug_io, stale, &target_buf);
    try testing.expect(std.mem.endsWith(u8, target, "/Cellar/wget/1.0"));
}

test "linkOpt surfaces a typed error when opt/{name} is an obstructing directory" {
    const prefix = try uniquePrefix("link_opt_obstructed");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);

    // Pre-create `<prefix>/opt/blocked/` as a non-empty directory.
    // `deleteFile` can't remove it, so the symLink call must fail —
    // and the failure must propagate, not get silently swallowed.
    const opt_blocked = try std.fmt.allocPrint(testing.allocator, "{s}/opt/blocked", .{prefix});
    defer testing.allocator.free(opt_blocked);
    try test_io.cwd().createDirPath(std.Options.debug_io, opt_blocked);
    const sentinel = try std.fmt.allocPrint(testing.allocator, "{s}/sentinel", .{opt_blocked});
    defer testing.allocator.free(sentinel);
    const f = try test_io.createFileAbsolute(std.Options.debug_io, sentinel, .{});
    f.close(std.Options.debug_io);

    const cellar = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/blocked/9.9", .{prefix});
    defer testing.allocator.free(cellar);
    try test_io.cwd().createDirPath(std.Options.debug_io, cellar);

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);
    try testing.expectError(error.PathAlreadyExists, linker.linkOpt("blocked", "9.9"));
}

test "checkConflicts flags a symlink that points into a different keg" {
    const prefix = try uniquePrefix("link_conflict");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);

    // Two kegs that both ship a `bin/tool` binary.
    const keg_a = try makeKegWithBinary(prefix, "alpha", "1.0", "tool");
    defer testing.allocator.free(keg_a);
    const keg_b = try makeKegWithBinary(prefix, "beta", "1.0", "tool");
    defer testing.allocator.free(keg_b);

    // Link alpha first.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try insertKeg(&db, 1, "alpha", keg_a);
    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);
    try linker.link(keg_a, "alpha", 1, false);

    // Now the `bin/tool` symlink points into alpha. Check beta's conflicts.
    const conflicts = try linker.checkConflicts(keg_b, false);
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
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);
    const keg = try makeKegWithBinary(prefix, "gamma", "1.0", "tool");
    defer testing.allocator.free(keg);

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);

    const conflicts = try linker.checkConflicts(keg, false);
    defer testing.allocator.free(conflicts);
    try testing.expectEqual(@as(usize, 0), conflicts.len);
}

// Without the `links` table, unlink's prepare fails. The rc used to
// turn into a silent `return`, hiding "schema missing" from the caller.
test "unlink surfaces SqliteError when links table is missing" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    // Intentionally no schema.initSchema — `links` does not exist.

    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, "/tmp/malt_unused");
    try testing.expectError(sqlite.SqliteError.PrepareFailed, linker.unlink(1));
}
