//! malt — `mt pin` / `mt unpin` behaviour tests
//! Locks in the pin/unpin contract: setting the column on an installed
//! keg, idempotent re-pin, error handling for missing-name and
//! not-installed cases. Uses a scratch MALT_PREFIX so no real DB is hit.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const cli_pin = malt.cli_pin;
const sqlite = malt.sqlite;
const schema = malt.schema;

const c = test_io.c;

fn setupPrefix(suffix: []const u8) ![:0]u8 {
    const base = try test_io.uniqueTempPath(testing.allocator, "pin", suffix);
    defer testing.allocator.free(base);
    const path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}", .{base}, 0);
    test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, path);
    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{path});
    defer testing.allocator.free(db_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);
    _ = c.setenv("MALT_PREFIX", path.ptr, 1);
    return path;
}

fn openDb(prefix: [:0]const u8) !sqlite.Database {
    var buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    errdefer db.close();
    try schema.initSchema(&db);
    return db;
}

fn insertKeg(db: *sqlite.Database, name: []const u8, pinned: bool) !void {
    var buf: [512]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(
        &buf,
        "INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, pinned) VALUES ('{s}', '{s}', '1.0', 'deadbeef', '/cellar/{s}/1.0', {d});",
        .{ name, name, name, @intFromBool(pinned) },
    );
    try db.exec(sql);
}

fn readPinned(db: *sqlite.Database, name: []const u8) !bool {
    var stmt = try db.prepare("SELECT pinned FROM kegs WHERE name = ?1 LIMIT 1;");
    defer stmt.finalize();
    try stmt.bindText(1, name);
    const has = try stmt.step();
    if (!has) return error.NotFound;
    return stmt.columnBool(0);
}

test "mt pin <name> sets pinned=1 on installed keg" {
    const path = try setupPrefix("pin_set");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openDb(path);
        defer db.close();
        try insertKeg(&db, "alpha", false);
    }

    try cli_pin.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"alpha"});

    var db = try openDb(path);
    defer db.close();
    try testing.expectEqual(true, try readPinned(&db, "alpha"));
}

test "mt unpin <name> clears pinned" {
    const path = try setupPrefix("unpin_clear");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openDb(path);
        defer db.close();
        try insertKeg(&db, "bravo", true);
    }

    try cli_pin.executeUnpin(&malt.app_ctx.debug_ctx, testing.allocator, &.{"bravo"});

    var db = try openDb(path);
    defer db.close();
    try testing.expectEqual(false, try readPinned(&db, "bravo"));
}

test "mt pin with no args returns Aborted (usage)" {
    const path = try setupPrefix("pin_noargs");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    try testing.expectError(error.Aborted, cli_pin.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{}));
}

test "mt unpin with no args returns Aborted (usage)" {
    const path = try setupPrefix("unpin_noargs");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    try testing.expectError(error.Aborted, cli_pin.executeUnpin(&malt.app_ctx.debug_ctx, testing.allocator, &.{}));
}

test "mt pin <not-installed> returns Aborted" {
    const path = try setupPrefix("pin_notinst");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openDb(path);
        defer db.close();
    }

    try testing.expectError(
        error.Aborted,
        cli_pin.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"definitely-not-installed"}),
    );
}

test "mt unpin <not-installed> returns Aborted" {
    const path = try setupPrefix("unpin_notinst");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openDb(path);
        defer db.close();
    }

    try testing.expectError(
        error.Aborted,
        cli_pin.executeUnpin(&malt.app_ctx.debug_ctx, testing.allocator, &.{"definitely-not-installed"}),
    );
}

test "isPinned reflects DB column" {
    const path = try setupPrefix("ispinned");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openDb(path);
    defer db.close();
    try insertKeg(&db, "uno", false);
    try insertKeg(&db, "due", true);

    try testing.expect(!cli_pin.isPinned(&db, .formula, "uno"));
    try testing.expect(cli_pin.isPinned(&db, .formula, "due"));
    try testing.expect(!cli_pin.isPinned(&db, .formula, "missing"));
}

fn insertCask(db: *sqlite.Database, token: []const u8, pinned: bool) !void {
    var buf: [512]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(
        &buf,
        "INSERT INTO casks (token, name, version, url, pinned) VALUES ('{s}', '{s}', '120.0', 'https://example.invalid', {d});",
        .{ token, token, @intFromBool(pinned) },
    );
    try db.exec(sql);
}

fn readCaskPinned(db: *sqlite.Database, token: []const u8) !bool {
    var stmt = try db.prepare("SELECT pinned FROM casks WHERE token = ?1 LIMIT 1;");
    defer stmt.finalize();
    try stmt.bindText(1, token);
    const has = try stmt.step();
    if (!has) return error.NotFound;
    return stmt.columnBool(0);
}

test "mt pin <cask-token> falls through kegs and sets casks.pinned" {
    const path = try setupPrefix("pin_cask_set");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openDb(path);
        defer db.close();
        try insertCask(&db, "firefox", false);
    }

    try cli_pin.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"firefox"});

    var db = try openDb(path);
    defer db.close();
    try testing.expectEqual(true, try readCaskPinned(&db, "firefox"));
}

test "mt unpin <cask-token> clears casks.pinned" {
    const path = try setupPrefix("unpin_cask_clear");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openDb(path);
        defer db.close();
        try insertCask(&db, "slack", true);
    }

    try cli_pin.executeUnpin(&malt.app_ctx.debug_ctx, testing.allocator, &.{"slack"});

    var db = try openDb(path);
    defer db.close();
    try testing.expectEqual(false, try readCaskPinned(&db, "slack"));
}

test "mt pin <cask> is idempotent — re-pinning a cask still succeeds" {
    const path = try setupPrefix("pin_cask_idempotent");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openDb(path);
        defer db.close();
        try insertCask(&db, "obsidian", true);
    }

    try cli_pin.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"obsidian"});

    var db = try openDb(path);
    defer db.close();
    try testing.expectEqual(true, try readCaskPinned(&db, "obsidian"));
}

test "isPinned(.cask) reflects casks.pinned" {
    const path = try setupPrefix("ispinned_cask");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var db = try openDb(path);
    defer db.close();
    try insertCask(&db, "loose-cask", false);
    try insertCask(&db, "held-cask", true);

    try testing.expect(!cli_pin.isPinned(&db, .cask, "loose-cask"));
    try testing.expect(cli_pin.isPinned(&db, .cask, "held-cask"));
}

test "mt pin is idempotent — re-pinning is a no-op success" {
    const path = try setupPrefix("pin_idempotent");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    {
        var db = try openDb(path);
        defer db.close();
        try insertKeg(&db, "tre", true);
    }

    try cli_pin.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"tre"});

    var db = try openDb(path);
    defer db.close();
    try testing.expectEqual(true, try readPinned(&db, "tre"));
}

// --- a name installed as both a formula and a cask ----------------------

fn seedSharedName(prefix: [:0]const u8, keg_pinned: bool, cask_pinned: bool) !void {
    var db = try openDb(prefix);
    defer db.close();
    try insertKeg(&db, "box", keg_pinned);
    try insertCask(&db, "box", cask_pinned);
}

/// Runs pin/unpin with stderr captured into `buf`. Returns the command's
/// error so callers can assert refusals alongside the message.
fn runCaptured(
    comptime unpin: bool,
    args: []const []const u8,
    buf: *std.ArrayList(u8),
) !void {
    const prior_quiet = malt.output.isQuiet();
    defer malt.output.setQuiet(prior_quiet);
    malt.output.setQuiet(false);
    malt.output.beginStderrCapture(testing.allocator, buf);
    defer malt.output.endStderrCapture();
    const run = if (unpin) cli_pin.executeUnpin else cli_pin.execute;
    return run(&malt.app_ctx.debug_ctx, testing.allocator, args);
}

fn expectPins(prefix: [:0]const u8, keg: bool, cask: bool) !void {
    var db = try openDb(prefix);
    defer db.close();
    try testing.expectEqual(keg, try readPinned(&db, "box"));
    try testing.expectEqual(cask, try readCaskPinned(&db, "box"));
}

const notice = "Treating box as a formula";

test "mt pin --cask on a name shared with a formula pins only the cask" {
    const path = try setupPrefix("pin_shared_cask");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");
    try seedSharedName(path, false, false);

    var err_buf: std.ArrayList(u8) = .empty;
    defer err_buf.deinit(testing.allocator);
    try runCaptured(false, &.{ "--cask", "box" }, &err_buf);

    try expectPins(path, false, true);
    try testing.expect(std.mem.indexOf(u8, err_buf.items, notice) == null);
}

test "mt unpin --casks on a name shared with a formula clears only the cask" {
    const path = try setupPrefix("unpin_shared_cask");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");
    try seedSharedName(path, true, true);

    var err_buf: std.ArrayList(u8) = .empty;
    defer err_buf.deinit(testing.allocator);
    try runCaptured(true, &.{ "box", "--casks" }, &err_buf);

    try expectPins(path, true, false);
}

test "a bare mt pin on a shared name pins the formula and says so" {
    const path = try setupPrefix("pin_shared_bare");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");
    try seedSharedName(path, false, false);

    var err_buf: std.ArrayList(u8) = .empty;
    defer err_buf.deinit(testing.allocator);
    try runCaptured(false, &.{"box"}, &err_buf);

    try expectPins(path, true, false);
    try testing.expect(std.mem.indexOf(u8, err_buf.items, notice) != null);
}

test "a bare mt unpin on a shared name leaves a pinned cask held and says so" {
    const path = try setupPrefix("unpin_shared_bare");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");
    try seedSharedName(path, true, true);

    var err_buf: std.ArrayList(u8) = .empty;
    defer err_buf.deinit(testing.allocator);
    try runCaptured(true, &.{"box"}, &err_buf);

    // The user is told the formula was chosen, so the cask's hold is not a surprise.
    try expectPins(path, false, true);
    try testing.expect(std.mem.indexOf(u8, err_buf.items, notice) != null);
}

test "mt pin --formula and -q on a shared name pin the formula without the notice" {
    const path = try setupPrefix("pin_shared_silenced");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");
    try seedSharedName(path, false, false);

    var err_buf: std.ArrayList(u8) = .empty;
    defer err_buf.deinit(testing.allocator);
    try runCaptured(false, &.{ "--formulae", "box" }, &err_buf);
    try expectPins(path, true, false);
    try runCaptured(true, &.{ "-q", "box" }, &err_buf);
    try expectPins(path, false, false);

    try testing.expect(std.mem.indexOf(u8, err_buf.items, notice) == null);
}

test "a bare mt pin on a cask-only name still pins the cask, without a notice" {
    const path = try setupPrefix("pin_cask_only_bare");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");
    {
        var db = try openDb(path);
        defer db.close();
        try insertCask(&db, "box", false);
    }

    var err_buf: std.ArrayList(u8) = .empty;
    defer err_buf.deinit(testing.allocator);
    try runCaptured(false, &.{"box"}, &err_buf);

    var db = try openDb(path);
    defer db.close();
    try testing.expect(try readCaskPinned(&db, "box"));
    try testing.expect(std.mem.indexOf(u8, err_buf.items, notice) == null);
}

test "mt pin --formula on a cask-only name is not installed and touches nothing" {
    const path = try setupPrefix("pin_formula_on_cask");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");
    {
        var db = try openDb(path);
        defer db.close();
        try insertCask(&db, "box", false);
    }

    var err_buf: std.ArrayList(u8) = .empty;
    defer err_buf.deinit(testing.allocator);
    try testing.expectError(error.Aborted, runCaptured(false, &.{ "--formula", "box" }, &err_buf));

    try testing.expect(std.mem.indexOf(u8, err_buf.items, "box is not installed as a formula") != null);
    var db = try openDb(path);
    defer db.close();
    try testing.expect(!try readCaskPinned(&db, "box"));
}

test "mt pin --cask on a formula-only name is not installed and touches nothing" {
    const path = try setupPrefix("pin_cask_on_formula");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");
    {
        var db = try openDb(path);
        defer db.close();
        try insertKeg(&db, "box", false);
    }

    var err_buf: std.ArrayList(u8) = .empty;
    defer err_buf.deinit(testing.allocator);
    try testing.expectError(error.Aborted, runCaptured(false, &.{ "--cask", "box" }, &err_buf));

    try testing.expect(std.mem.indexOf(u8, err_buf.items, "box is not installed as a cask") != null);
    var db = try openDb(path);
    defer db.close();
    try testing.expect(!try readPinned(&db, "box"));
}

test "mt pin refuses --cask with --formula ahead of the usage check, as brew does" {
    const path = try setupPrefix("pin_both_kinds");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");
    try seedSharedName(path, false, false);

    var err_buf: std.ArrayList(u8) = .empty;
    defer err_buf.deinit(testing.allocator);
    try testing.expectError(error.Aborted, runCaptured(false, &.{ "--cask", "--formula", "box" }, &err_buf));
    // No name at all: the conflict still wins over the usage line.
    try testing.expectError(error.Aborted, runCaptured(true, &.{ "--formula", "--cask" }, &err_buf));

    try testing.expect(std.mem.indexOf(u8, err_buf.items, "Options --formula and --cask are mutually exclusive") != null);
    try testing.expect(std.mem.indexOf(u8, err_buf.items, "Usage") == null);
    try expectPins(path, false, false);
}

test "mt pin refuses an unknown flag instead of reading it as the name" {
    const path = try setupPrefix("pin_unknown_flag");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");
    try seedSharedName(path, false, false);

    var err_buf: std.ArrayList(u8) = .empty;
    defer err_buf.deinit(testing.allocator);
    try testing.expectError(error.Aborted, runCaptured(false, &.{ "--bogus", "box" }, &err_buf));

    try testing.expect(std.mem.indexOf(u8, err_buf.items, "Unknown flag: --bogus") != null);
    try expectPins(path, false, false);
}

test "mt pin with only a kind flag prints the usage line" {
    const path = try setupPrefix("pin_flag_no_name");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    var err_buf: std.ArrayList(u8) = .empty;
    defer err_buf.deinit(testing.allocator);
    try testing.expectError(error.Aborted, runCaptured(false, &.{"--cask"}, &err_buf));

    try testing.expect(std.mem.indexOf(u8, err_buf.items, "Usage: mt pin <name> [--cask | --formula]") != null);
}

test "a bare mt pin still pins the formula when the casks table cannot be read" {
    const path = try setupPrefix("pin_casks_unreadable");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");
    try seedSharedName(path, false, false);
    var db_path_buf: [512]u8 = undefined;
    try test_io.corruptTable(try std.fmt.bufPrintZ(&db_path_buf, "{s}/db/malt.db", .{path}), "casks");

    var err_buf: std.ArrayList(u8) = .empty;
    defer err_buf.deinit(testing.allocator);
    // The notice is advisory; a broken casks table must not cost the formula its pin.
    try runCaptured(false, &.{"box"}, &err_buf);

    var db = try openDb(path);
    defer db.close();
    try testing.expect(try readPinned(&db, "box"));
}

test "mt pin refuses a second name instead of silently pinning only the first" {
    const path = try setupPrefix("pin_two_names");
    defer testing.allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");
    {
        var db = try openDb(path);
        defer db.close();
        try insertKeg(&db, "wget", false);
        try insertKeg(&db, "curl", false);
    }

    var err_buf: std.ArrayList(u8) = .empty;
    defer err_buf.deinit(testing.allocator);
    try testing.expectError(error.Aborted, runCaptured(false, &.{ "wget", "curl" }, &err_buf));

    try testing.expect(std.mem.indexOf(u8, err_buf.items, "Usage: mt pin <name>") != null);
    var db = try openDb(path);
    defer db.close();
    try testing.expect(!try readPinned(&db, "wget"));
}
