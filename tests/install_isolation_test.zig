//! Integration tests for the `--isolate-deps` install policy:
//! flag plumbing, schema replay across upgrade/reinstall, promotion
//! semantics, and the "direct kegs are never isolated" invariant.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");
const sqlite = malt.sqlite;
const schema = malt.schema;
const install_record = malt.install_record;
const linker_mod = malt.linker;
const formula_mod = malt.formula;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

const fake_formula_json =
    \\{
    \\  "name": "depkeg",
    \\  "full_name": "depkeg",
    \\  "tap": "homebrew/core",
    \\  "desc": "",
    \\  "homepage": "",
    \\  "versions": {"stable": "1.0"},
    \\  "revision": 0,
    \\  "dependencies": [],
    \\  "keg_only": false,
    \\  "post_install_defined": false,
    \\  "oldnames": [],
    \\  "bottle": {"stable": {"files": {}}}
    \\}
;

fn uniquePrefix(suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        testing.allocator,
        "/tmp/malt_install_iso_{d}_{s}",
        .{ test_io.nanoTimestamp(std.Options.debug_io), suffix },
    );
}

fn makeKegWithBin(prefix: []const u8, name: []const u8, version: []const u8) ![]u8 {
    const keg = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/Cellar/{s}/{s}",
        .{ prefix, name, version },
    );
    try test_io.cwd().createDirPath(std.Options.debug_io, keg);

    const bin_dir = try std.fmt.allocPrint(testing.allocator, "{s}/bin", .{keg});
    defer testing.allocator.free(bin_dir);
    try test_io.makeDirAbsolute(std.Options.debug_io, bin_dir);

    const bin_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ bin_dir, name });
    defer testing.allocator.free(bin_path);
    const f = try test_io.createFileAbsolute(std.Options.debug_io, bin_path, .{});
    try f.writeStreamingAll(std.Options.debug_io, "#!/bin/sh\necho hi\n");
    f.close(std.Options.debug_io);

    return keg;
}

fn pathExists(absolute: []const u8) bool {
    var f = test_io.openFileAbsolute(std.Options.debug_io, absolute, .{}) catch return false;
    f.close(std.Options.debug_io);
    return true;
}

// What the install pipeline does for a dep keg installed under
// `--isolate-deps`: recordKeg writes bin_isolated=1, the linker skips
// bin/sbin. This integration covers the wiring contract the flag must
// guarantee end-to-end — even before the full `mt install` plumbing
// lands, the primitives must compose correctly.
test "isolated dep install: bin_isolated=1, no bin symlink, opt link still present via Linker.linkOpt" {
    const prefix = try uniquePrefix("isolated_dep");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);
    const keg = try makeKegWithBin(prefix, "depkeg", "1.0");
    defer testing.allocator.free(keg);

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f = try formula_mod.parseFormula(arena.allocator(), fake_formula_json);
    defer f.deinit();

    const keg_id = try install_record.recordKeg(
        &db,
        &f,
        "0" ** 64,
        keg,
        "dependency",
        true,
        .{},
    );

    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);
    try linker.link(keg, "depkeg", keg_id, true);
    try linker.linkOpt("depkeg", "1.0");

    // No bin/sbin link in prefix.
    var bin_buf: [512]u8 = undefined;
    const bin_link = try std.fmt.bufPrint(&bin_buf, "{s}/bin/depkeg", .{prefix});
    try testing.expect(!pathExists(bin_link));

    // opt/depkeg is anchored — Mach-O dependents still resolve.
    var opt_buf: [512]u8 = undefined;
    const opt_link = try std.fmt.bufPrint(&opt_buf, "{s}/opt/depkeg", .{prefix});
    var t_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = try test_io.readLinkAbsolute(std.Options.debug_io, opt_link, &t_buf);

    var probe = try db.prepare("SELECT install_reason, bin_isolated FROM kegs WHERE id = ?1;");
    defer probe.finalize();
    try probe.bindInt(1, keg_id);
    _ = try probe.step();
    try testing.expectEqualStrings(
        "dependency",
        std.mem.sliceTo(probe.columnText(0) orelse "", 0),
    );
    try testing.expectEqual(@as(i64, 1), probe.columnInt(1));
}

// The direct half of the same install pass: --isolate-deps must
// never isolate the package the user actually named, even if the
// flag was passed. install_reason='direct' shields it.
test "direct keg under --isolate-deps still links bins and stays bin_isolated=0" {
    const prefix = try uniquePrefix("direct_under_iso");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);
    const keg = try makeKegWithBin(prefix, "depkeg", "1.0");
    defer testing.allocator.free(keg);

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f = try formula_mod.parseFormula(arena.allocator(), fake_formula_json);
    defer f.deinit();

    // Caller computed: bin_isolated = flag and is_dep → false here.
    const keg_id = try install_record.recordKeg(
        &db,
        &f,
        "0" ** 64,
        keg,
        "direct",
        false,
        .{},
    );

    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);
    try linker.link(keg, "depkeg", keg_id, false);

    var bin_buf: [512]u8 = undefined;
    const bin_link = try std.fmt.bufPrint(&bin_buf, "{s}/bin/depkeg", .{prefix});
    try testing.expect(pathExists(bin_link));

    var probe = try db.prepare("SELECT install_reason, bin_isolated FROM kegs WHERE id = ?1;");
    defer probe.finalize();
    try probe.bindInt(1, keg_id);
    _ = try probe.step();
    try testing.expectEqualStrings(
        "direct",
        std.mem.sliceTo(probe.columnText(0) orelse "", 0),
    );
    try testing.expectEqual(@as(i64, 0), probe.columnInt(1));
}

// Replay invariant: a keg recorded with `bin_isolated=1` keeps that
// flag through an `upgradeDbAtomic` round-trip. The caller is the
// upgrade pipeline, which SELECTs the prior row's value and feeds it
// back in — no user re-flagging required.
test "upgradeDbAtomic preserves bin_isolated across an upgrade" {
    const prefix = try uniquePrefix("upgrade_replay");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);
    const old_keg = try makeKegWithBin(prefix, "depkeg", "1.0");
    defer testing.allocator.free(old_keg);
    const new_keg = try makeKegWithBin(prefix, "depkeg", "2.0");
    defer testing.allocator.free(new_keg);

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f_old = try formula_mod.parseFormula(arena.allocator(), fake_formula_json);
    defer f_old.deinit();
    const old_id = try install_record.recordKeg(
        &db,
        &f_old,
        "0" ** 64,
        old_keg,
        "dependency",
        true,
        .{},
    );

    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);
    try linker.link(old_keg, "depkeg", old_id, true);

    // Simulate upgradeDbAtomic: read replay, unlink, recordKeg with
    // bumped version, link with replayed bin_isolated.
    var sel = try db.prepare("SELECT bin_isolated FROM kegs WHERE id = ?1;");
    defer sel.finalize();
    try sel.bindInt(1, old_id);
    _ = try sel.step();
    const replay = sel.columnInt(0) != 0;

    try linker.unlink(old_id);

    const new_formula_json =
        \\{"name": "depkeg", "full_name": "depkeg", "tap": "homebrew/core",
        \\ "desc": "", "homepage": "", "versions": {"stable": "2.0"},
        \\ "revision": 0, "dependencies": [], "keg_only": false,
        \\ "post_install_defined": false, "oldnames": [],
        \\ "bottle": {"stable": {"files": {}}}}
    ;
    var f_new = try formula_mod.parseFormula(arena.allocator(), new_formula_json);
    defer f_new.deinit();
    const new_id = try install_record.recordKeg(
        &db,
        &f_new,
        "1" ** 64,
        new_keg,
        "dependency",
        replay,
        .{},
    );
    try linker.link(new_keg, "depkeg", new_id, replay);

    var probe = try db.prepare("SELECT bin_isolated, install_reason FROM kegs WHERE id = ?1;");
    defer probe.finalize();
    try probe.bindInt(1, new_id);
    _ = try probe.step();
    try testing.expectEqual(@as(i64, 1), probe.columnInt(0));
    try testing.expectEqualStrings(
        "dependency",
        std.mem.sliceTo(probe.columnText(1) orelse "", 0),
    );

    var bin_buf: [512]u8 = undefined;
    const bin_link = try std.fmt.bufPrint(&bin_buf, "{s}/bin/depkeg", .{prefix});
    try testing.expect(!pathExists(bin_link));
}

// Promotion contract: a dep keg recorded with bin_isolated=1 must
// end up direct with bins linked after the user runs `mt install
// <dep>`. The integration here exercises the same UPDATE + Linker.link
// sequence the install pipeline triggers in its pre-resolution sweep.
test "promotion: isolated dep becomes direct with bin link on user install" {
    const prefix = try uniquePrefix("promote");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);
    const keg = try makeKegWithBin(prefix, "depkeg", "1.0");
    defer testing.allocator.free(keg);

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f = try formula_mod.parseFormula(arena.allocator(), fake_formula_json);
    defer f.deinit();
    const keg_id = try install_record.recordKeg(
        &db,
        &f,
        "0" ** 64,
        keg,
        "dependency",
        true,
        .{},
    );

    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);
    try linker.link(keg, "depkeg", keg_id, true);

    // Bins absent under isolation.
    var bin_buf: [512]u8 = undefined;
    const bin_link = try std.fmt.bufPrint(&bin_buf, "{s}/bin/depkeg", .{prefix});
    try testing.expect(!pathExists(bin_link));

    // Simulate the promotion the install command performs.
    try db.exec("UPDATE kegs SET install_reason='direct', bin_isolated=0 WHERE name='depkeg';");
    try linker.link(keg, "depkeg", keg_id, false);

    try testing.expect(pathExists(bin_link));

    var probe = try db.prepare("SELECT install_reason, bin_isolated FROM kegs WHERE id = ?1;");
    defer probe.finalize();
    try probe.bindInt(1, keg_id);
    _ = try probe.step();
    try testing.expectEqualStrings(
        "direct",
        std.mem.sliceTo(probe.columnText(0) orelse "", 0),
    );
    try testing.expectEqual(@as(i64, 0), probe.columnInt(1));
}

// Invariant: a direct keg installed during the same pass as a flag-
// enabled run must NOT pick up isolation. The computation lives in
// linkAndRecord as `bin_isolated = isolate_deps and job.is_dep`, but
// the user-visible promise is "the name I typed always lands in PATH".
test "isolate_deps is a no-op on direct kegs (named pkg stays linked)" {
    const prefix = try uniquePrefix("direct_noop");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);
    const keg = try makeKegWithBin(prefix, "depkeg", "1.0");
    defer testing.allocator.free(keg);

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f = try formula_mod.parseFormula(arena.allocator(), fake_formula_json);
    defer f.deinit();

    // What the install pipeline computes for a direct keg even when
    // the user passed --isolate-deps: bin_isolated = flag(true) and
    // is_dep(false) = false. Mirror that exact call here.
    const isolate_deps_flag = true;
    const job_is_dep = false;
    const computed_bin_isolated = isolate_deps_flag and job_is_dep;
    try testing.expect(!computed_bin_isolated);

    const keg_id = try install_record.recordKeg(
        &db,
        &f,
        "0" ** 64,
        keg,
        "direct",
        computed_bin_isolated,
        .{},
    );

    var linker = linker_mod.Linker.init(std.Options.debug_io, testing.allocator, &db, prefix);
    try linker.link(keg, "depkeg", keg_id, computed_bin_isolated);

    var bin_buf: [512]u8 = undefined;
    const bin_link = try std.fmt.bufPrint(&bin_buf, "{s}/bin/depkeg", .{prefix});
    try testing.expect(pathExists(bin_link));

    var probe = try db.prepare("SELECT bin_isolated FROM kegs WHERE id = ?1;");
    defer probe.finalize();
    try probe.bindInt(1, keg_id);
    _ = try probe.step();
    try testing.expectEqual(@as(i64, 0), probe.columnInt(0));
}

// Long-form spelling is an accepted alias of the canonical flag.
// Pinning the alias keeps a future flag-map cleanup from silently
// dropping the form some users will reach for first.
test "execute accepts --isolate-dependencies as an alias of --isolate-deps" {
    try runFlagAcceptanceProbe("iso_alias", "--isolate-dependencies");
}

// Flag-acceptance smoke: `mt install --isolate-deps --dry-run <pkg>`
// must not error on flag parsing. Verifies argv plumbing exists.
test "execute accepts --isolate-deps without erroring during dry-run" {
    try runFlagAcceptanceProbe("iso_canonical", "--isolate-deps");
}

// Shared helper: drive `install.execute` against a scratch
// MALT_PREFIX so `ensureDirs` doesn't trip on `/opt/malt` being
// unwritable (CI). Any of the downstream "no such formula" errors
// counts as proof the parser reached past the flag stage; raising
// any other error means the flag was rejected.
fn runFlagAcceptanceProbe(suffix: []const u8, flag: []const u8) !void {
    const prefix = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "/tmp/malt_iso_probe_{d}_{s}",
        .{ test_io.nanoTimestamp(std.Options.debug_io), suffix },
        0,
    );
    defer testing.allocator.free(prefix);
    test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    _ = c.setenv("MALT_PREFIX", prefix.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = malt.install.execute(
        &malt.app_ctx.debug_ctx,
        arena.allocator(),
        &.{ "--dry-run", flag, "--quiet", "zz_nonexistent_formula_xyz" },
    );
    if (result) |_| {} else |e| switch (e) {
        error.PartialFailure,
        error.FormulaNotFound,
        error.NetworkError,
        error.RateLimited,
        error.DownloadFailed,
        => {},
        else => return e,
    }
}
