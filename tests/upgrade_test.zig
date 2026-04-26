//! malt — upgrade.execute behaviour tests
//! Locks in the exit-code contract: an upgrade that touches a package we
//! cannot upgrade (not installed, or batch item failure) must surface a
//! non-zero exit instead of silently reporting success. Uses a scratch
//! MALT_PREFIX so no real DB or network is hit.

const std = @import("std");
const malt = @import("malt");
const testing = std.testing;
const upgrade = malt.upgrade;
const sqlite = malt.sqlite;
const schema = malt.schema;
const formula_mod = malt.formula;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

fn setupPrefix(suffix: []const u8) ![:0]u8 {
    const path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "/tmp/malt_upgrade_exec_{d}_{s}",
        .{ malt.fs_compat.nanoTimestamp(), suffix },
        0,
    );
    malt.fs_compat.deleteTreeAbsolute(path) catch {};
    try malt.fs_compat.cwd().makePath(path);
    _ = c.setenv("MALT_PREFIX", path.ptr, 1);
    return path;
}

test "mt upgrade <nonexistent> surfaces a non-zero exit" {
    const path = try setupPrefix("nonexistent_pkg");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    // Seed an empty DB so the `db/` dir exists (lock acquire doesn't
    // short-circuit to silent-return) but no packages are installed.
    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{path});
    defer testing.allocator.free(db_dir);
    try malt.fs_compat.cwd().makePath(db_dir);

    try testing.expectError(
        error.Aborted,
        upgrade.execute(testing.allocator, &.{"definitely-not-installed"}),
    );
}

fn openSeededDb(prefix: [:0]const u8) !sqlite.Database {
    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{prefix});
    defer testing.allocator.free(db_dir);
    try malt.fs_compat.cwd().makePath(db_dir);

    var buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    errdefer db.close();
    try schema.initSchema(&db);
    return db;
}

fn insertPinnedKeg(db: *sqlite.Database, name: []const u8) !void {
    var buf: [512]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(
        &buf,
        "INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, pinned) VALUES ('{s}', '{s}', '1.0', 'deadbeef', '/cellar/{s}/1.0', 1);",
        .{ name, name, name },
    );
    try db.exec(sql);
}

test "mt upgrade <pinned> is a quiet no-op (no API call)" {
    const path = try setupPrefix("pinned_skip_named");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openSeededDb(path);
        defer db.close();
        try insertPinnedKeg(&db, "alpha-pinned");
    }

    // Pinned name short-circuits before fetchFormula — must NOT error.
    try upgrade.execute(testing.allocator, &.{"alpha-pinned"});
}

test "mt upgrade (no args) skips pinned kegs without aggregating failures" {
    const path = try setupPrefix("pinned_skip_bulk");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openSeededDb(path);
        defer db.close();
        try insertPinnedKeg(&db, "first-pinned");
        try insertPinnedKeg(&db, "second-pinned");
    }

    // All-pinned bulk run: every keg is skipped, no failures aggregate.
    try upgrade.execute(testing.allocator, &.{});
}

test "mt upgrade --pinned --dry-run with no pinned kegs is a quiet no-op" {
    const path = try setupPrefix("pinned_audit_empty");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openSeededDb(path);
        defer db.close();
        // Unpinned keg — the --pinned filter excludes it, no API call.
        try db.exec("INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path) VALUES ('loose', 'loose', '1.0', 'sha', '/cellar/loose/1.0');");
    }

    try upgrade.execute(testing.allocator, &.{ "--pinned", "--dry-run" });
}

test "mt upgrade --pinned without --dry-run or --force errors with usage" {
    const path = try setupPrefix("pinned_requires_audit");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{path});
    defer testing.allocator.free(db_dir);
    try malt.fs_compat.cwd().makePath(db_dir);

    try testing.expectError(
        error.Aborted,
        upgrade.execute(testing.allocator, &.{"--pinned"}),
    );
}

fn insertPinnedCask(db: *sqlite.Database, token: []const u8, version: []const u8) !void {
    var buf: [512]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(
        &buf,
        "INSERT INTO casks (token, name, version, url, pinned) VALUES ('{s}', '{s}', '{s}', 'https://example.invalid', 1);",
        .{ token, token, version },
    );
    try db.exec(sql);
}

test "mt upgrade <pinned-cask> is a quiet no-op (no API call)" {
    const path = try setupPrefix("pinned_skip_named_cask");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openSeededDb(path);
        defer db.close();
        try insertPinnedCask(&db, "firefox", "120.0");
    }

    // Pinned cask short-circuits in upgradeCask before fetchCask — must NOT error.
    try upgrade.execute(testing.allocator, &.{"firefox"});
}

test "recordKeg inherits pinned=1 from an existing keg of the same name" {
    const path = try setupPrefix("recordkeg_inherit_pin");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try insertPinnedKeg(&db, "alpha");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const formula_json =
        \\{
        \\  "name": "alpha",
        \\  "full_name": "alpha",
        \\  "tap": "homebrew/core",
        \\  "versions": {"stable": "2.0"}
        \\}
    ;
    var formula = try formula_mod.parseFormula(arena.allocator(), formula_json);
    defer formula.deinit();

    const new_keg_id = try upgrade.recordKeg(&db, &formula, "deadbeef2", "/cellar/alpha/2.0");

    var stmt = try db.prepare("SELECT pinned FROM kegs WHERE id = ?1 LIMIT 1;");
    defer stmt.finalize();
    try stmt.bindInt(1, new_keg_id);
    _ = try stmt.step();
    try testing.expectEqual(true, stmt.columnBool(0));
}

test "force-upgrade-cask orchestration: pin survives removeRecord + recordInstall" {
    // Simulates the DB side of upgradeCask under --force: the existing
    // pinned cask row is removed (uninstall.removeRecord), a new row is
    // inserted (recordInstall), and the orchestration must reapply the
    // pin so the user's hold survives.
    const path = try setupPrefix("force_upgrade_cask_pin");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try insertPinnedCask(&db, "firefox", "1.0");

    const was_pinned = malt.cli_pin.isPinned(&db, "firefox");
    try testing.expect(was_pinned);

    // Step 1: uninstall side — DB row removed by removeRecord.
    try malt.cask.removeRecord(&db, "firefox");

    // Step 2: install side — recordInstall on a fresh row defaults pinned=0.
    var c2 = try malt.cask.parseCask(testing.allocator,
        \\{
        \\  "token": "firefox",
        \\  "name": ["Firefox"],
        \\  "version": "200.0",
        \\  "url": "https://example.invalid/firefox.dmg",
        \\  "auto_updates": true,
        \\  "artifacts": [{"app": ["Firefox.app"]}]
        \\}
    );
    defer c2.deinit();
    try malt.cask.recordInstall(&db, &c2, "/Applications/Firefox.app");

    // Step 3: orchestration must reapply the pin.
    if (was_pinned) {
        _ = try malt.cli_pin.setPinned(&db, "firefox", true);
    }

    try testing.expect(malt.cli_pin.isPinned(&db, "firefox"));
}

test "recordKeg defaults pinned=0 when no prior keg of that name exists" {
    const path = try setupPrefix("recordkeg_fresh_pin");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const formula_json =
        \\{
        \\  "name": "fresh",
        \\  "full_name": "fresh",
        \\  "tap": "homebrew/core",
        \\  "versions": {"stable": "1.0"}
        \\}
    ;
    var formula = try formula_mod.parseFormula(arena.allocator(), formula_json);
    defer formula.deinit();

    const new_keg_id = try upgrade.recordKeg(&db, &formula, "deadbeef0", "/cellar/fresh/1.0");

    var stmt = try db.prepare("SELECT pinned FROM kegs WHERE id = ?1 LIMIT 1;");
    defer stmt.finalize();
    try stmt.bindInt(1, new_keg_id);
    _ = try stmt.step();
    try testing.expectEqual(false, stmt.columnBool(0));
}

test "pinSkip honours --force and audit_mode for casks too" {
    const path = try setupPrefix("pinskip_cask");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try insertPinnedCask(&db, "held-cask", "1.0");

    try testing.expect(upgrade.pinSkip(&db, "held-cask", false, false));
    try testing.expect(!upgrade.pinSkip(&db, "held-cask", true, false));
    try testing.expect(!upgrade.pinSkip(&db, "held-cask", false, true));
}

test "mt upgrade --pinned --dry-run reaches the cask path (no formula-only override)" {
    const path = try setupPrefix("pinned_audit_cask");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openSeededDb(path);
        defer db.close();
        try insertPinnedCask(&db, "pinned-cask", "1.0");
    }

    // No cache seeded: if the walker reaches the cask, fetchCask fails and
    // aborts; if the formula-only override is still in place, the cask
    // path is silently skipped and execute() returns OK. The audit must
    // walk the row, so this run aborts.
    try testing.expectError(
        error.Aborted,
        upgrade.execute(testing.allocator, &.{ "--pinned", "--dry-run" }),
    );
}

test "pinSkip honours --force and audit_mode: pinned + override = no skip" {
    const path = try setupPrefix("pinskip_helper");
    defer testing.allocator.free(path);
    defer malt.fs_compat.deleteTreeAbsolute(path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openSeededDb(path);
    defer db.close();
    try insertPinnedKeg(&db, "forced");
    try db.exec("INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path) VALUES ('loose', 'loose', '1.0', 'sha', '/cellar/loose/1.0');");

    // pinned + neither override = skip
    try testing.expect(upgrade.pinSkip(&db, "forced", false, false));
    // pinned + force = no skip (the whole point of --force)
    try testing.expect(!upgrade.pinSkip(&db, "forced", true, false));
    // pinned + audit = no skip (so `--pinned --dry-run` walks the row)
    try testing.expect(!upgrade.pinSkip(&db, "forced", false, true));
    // unpinned: never skipped, force/audit or not
    try testing.expect(!upgrade.pinSkip(&db, "loose", false, false));
    try testing.expect(!upgrade.pinSkip(&db, "loose", true, false));
    // unknown name: not pinned, not skipped
    try testing.expect(!upgrade.pinSkip(&db, "ghost", false, false));
}
