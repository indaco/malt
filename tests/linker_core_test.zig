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

fn uniquePrefix(suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        testing.allocator,
        "/tmp/malt_linker_test_{d}_{s}",
        .{ test_io.nanoTimestamp(
            std.Options.debug_io,
        ), suffix },
    );
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
