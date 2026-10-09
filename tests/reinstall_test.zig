//! malt — reinstall command integration tests.
//!
//! Pins the user-visible contract of `mt reinstall`:
//!   - refuses cleanly when the package isn't installed,
//!   - falls through to the install pipeline (DB opened, lock taken)
//!     when the keg row exists.
//!
//! The happy-path test stops short of asserting the eventual install
//! outcome — the API-bound resolver is unreachable in unit-test land —
//! and only checks that the dispatch arm got past `classify` and into
//! the shared primitive. That's the seam reinstall actually owns; the
//! install pipeline carries its own coverage from `install_*_test.zig`.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const reinstall = malt.cli_reinstall;

const c = test_io.c;

fn pathExists(path: []const u8) bool {
    test_io.accessAbsolute(std.Options.debug_io, path, .{}) catch return false;
    return true;
}

fn setupPrefix(suffix: []const u8) ![:0]u8 {
    const base = try test_io.uniqueTempPath(testing.allocator, "reinstall", suffix);
    defer testing.allocator.free(base);
    const path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}", .{base}, 0);
    test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, path);
    _ = c.setenv("MALT_PREFIX", path.ptr, 1);
    return path;
}

test "execute errors clearly when the package is not installed" {
    const prefix = try setupPrefix("missing");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const prior_quiet = malt.output.isQuiet();
    malt.output.setQuiet(false);
    defer malt.output.setQuiet(prior_quiet);

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    try testing.expectError(error.Aborted, reinstall.execute(&ctx, arena.allocator(), &.{"ghostpkg"}));

    // No `installAll` delegation means no `db/malt.lock` reached the disk:
    // the refusal short-circuited before the install pipeline ran.
    const lock_file = try std.fmt.allocPrint(testing.allocator, "{s}/db/malt.lock", .{prefix});
    defer testing.allocator.free(lock_file);
    try testing.expect(!pathExists(lock_file));

    try testing.expect(std.mem.indexOf(u8, captured.items, "ghostpkg is not installed") != null);
}

test "execute short-circuits on --help without touching the DB" {
    // `mt reinstall --help` is a UX guarantee: it must never spin up
    // the prefix-bound DB plumbing. Asserting "no malt.db on disk"
    // pins that the help fast-path stays ahead of the lookup.
    const prefix = try setupPrefix("help");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    try reinstall.execute(&ctx, arena.allocator(), &.{"--help"});

    const db_file = try std.fmt.allocPrint(testing.allocator, "{s}/db/malt.db", .{prefix});
    defer testing.allocator.free(db_file);
    try testing.expect(!pathExists(db_file));
}

test "execute refuses when no package is named" {
    const prefix = try setupPrefix("noargs");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    try testing.expectError(error.Aborted, reinstall.execute(&ctx, arena.allocator(), &.{}));
}

test "execute reaches the install pipeline when the keg row exists" {
    const prefix = try setupPrefix("present");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }

    // Seed both the on-disk Cellar entry AND the DB keg row so the
    // fast-path classification lands on `.keg` and dispatch hands off
    // to `installAll`. The lock file's appearance proves we crossed
    // the seam reinstall actually owns; the install pipeline itself
    // is covered by `install_*_test.zig`.
    const cellar_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/RESOLVABLE_FIXTURE/1.0", .{prefix});
    defer testing.allocator.free(cellar_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, cellar_dir);

    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{prefix});
    defer testing.allocator.free(db_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);

    const db_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/malt.db", .{db_dir}, 0);
    defer testing.allocator.free(db_path);
    {
        var db = try malt.sqlite.Database.open(db_path);
        defer db.close();
        try malt.schema.initSchema(&db);
        try db.exec(
            \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path)
            \\VALUES ('RESOLVABLE_FIXTURE', 'RESOLVABLE_FIXTURE', '1.0', 'sha-x',
            \\        '/opt/malt/Cellar/RESOLVABLE_FIXTURE/1.0');
        );
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };

    // Eventual failure (API unreachable for a synthetic name) is fine;
    // the assertion is structural — did the dispatch arm hand off?
    reinstall.execute(&ctx, arena.allocator(), &.{ "--quiet", "RESOLVABLE_FIXTURE" }) catch {};

    const lock_file = try std.fmt.allocPrint(testing.allocator, "{s}/db/malt.lock", .{prefix});
    defer testing.allocator.free(lock_file);
    try testing.expect(pathExists(lock_file));
}

test "execute refuses an unknown flag before the forced install starts" {
    // The forwarded `--force` prunes the keg, so a dropped `-n` would be destructive.
    const prefix = try setupPrefix("unknown_flag");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }
    const cellar_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/RESOLVABLE_FIXTURE/1.0", .{prefix});
    defer testing.allocator.free(cellar_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, cellar_dir);
    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{prefix});
    defer testing.allocator.free(db_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);
    const db_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/malt.db", .{db_dir}, 0);
    defer testing.allocator.free(db_path);
    {
        var db = try malt.sqlite.Database.open(db_path);
        defer db.close();
        try malt.schema.initSchema(&db);
        try db.exec(
            \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path)
            \\VALUES ('RESOLVABLE_FIXTURE', 'RESOLVABLE_FIXTURE', '1.0', 'sha-x',
            \\        '/opt/malt/Cellar/RESOLVABLE_FIXTURE/1.0');
        );
    }

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = std.Options.debug_io, .environ = .empty, .offline = true };
    try testing.expectError(error.Aborted, reinstall.execute(&ctx, arena.allocator(), &.{ "-n", "RESOLVABLE_FIXTURE" }));
    try testing.expect(std.mem.indexOf(u8, captured.items, "Unknown flag: -n") != null);

    // No lock taken and the keg untouched: install never began.
    const lock_file = try std.fmt.allocPrint(testing.allocator, "{s}/db/malt.lock", .{prefix});
    defer testing.allocator.free(lock_file);
    try testing.expect(!pathExists(lock_file));
    try testing.expect(pathExists(cellar_dir));
}

test "execute names an unknown flag before looking the package up" {
    // `--bogus ghost` used to report "ghost is not installed", hiding the typo.
    const prefix = try setupPrefix("unknown_flag_missing");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = std.Options.debug_io, .environ = .empty, .offline = true };
    try testing.expectError(error.Aborted, reinstall.execute(&ctx, arena.allocator(), &.{ "--bogus", "ghost" }));
    try testing.expect(std.mem.indexOf(u8, captured.items, "Unknown flag: --bogus") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "not installed") == null);
}

test "execute refuses a formula and a cask in one run before installing anything" {
    // One install run takes one side: `--cask` from the first name would
    // send the formula to the cask resolver.
    const prefix = try setupPrefix("mixed_kinds");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }
    const db_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/db/malt.db", .{prefix}, 0);
    defer testing.allocator.free(db_path);
    try test_io.cwd().createDirPath(std.Options.debug_io, std.fs.path.dirname(db_path).?);
    {
        var db = try malt.sqlite.Database.open(db_path);
        defer db.close();
        try malt.schema.initSchema(&db);
        try db.exec(
            \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path)
            \\  VALUES ('wget', 'wget', '1.24', 'a', '/c/wget');
            \\INSERT INTO casks (token, name, version, url)
            \\  VALUES ('firefox', 'firefox', '120.0', 'https://x.invalid/f.dmg');
        );
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    for ([_][2][]const u8{ .{ "firefox", "wget" }, .{ "wget", "firefox" } }) |names| {
        try testing.expectError(error.Aborted, reinstall.execute(&ctx, arena.allocator(), &names));
    }

    try testing.expect(std.mem.indexOf(u8, captured.items, "Reinstall formulas and casks separately") != null);
    const lock_file = try std.fmt.allocPrint(testing.allocator, "{s}/db/malt.lock", .{prefix});
    defer testing.allocator.free(lock_file);
    try testing.expect(!pathExists(lock_file));
}

test "execute refuses a later name that is not installed before installing anything" {
    // `--force` makes install a fresh install, so a missing later name would
    // be installed instead of refused.
    const prefix = try setupPrefix("later_missing");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }
    const db_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/db/malt.db", .{prefix}, 0);
    defer testing.allocator.free(db_path);
    try test_io.cwd().createDirPath(std.Options.debug_io, std.fs.path.dirname(db_path).?);
    {
        var db = try malt.sqlite.Database.open(db_path);
        defer db.close();
        try malt.schema.initSchema(&db);
        try db.exec(
            \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path)
            \\  VALUES ('wget', 'wget', '1.24', 'a', '/c/wget');
            \\INSERT INTO casks (token, name, version, url)
            \\  VALUES ('firefox', 'firefox', '120.0', 'https://x.invalid/f.dmg');
        );
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    const cases = [_]struct { argv: []const []const u8, want: []const u8 }{
        .{ .argv = &.{ "wget", "htop" }, .want = "htop is not installed" },
        // `--formula` hides the casks table, so the cask is missing here.
        .{ .argv = &.{ "--formula", "wget", "firefox" }, .want = "firefox is not installed" },
        // The first missing name in argv order wins over a later kind split.
        .{ .argv = &.{ "wget", "ghost", "firefox" }, .want = "ghost is not installed" },
        // Plural kind flags scope the lookup like the singular ones.
        .{ .argv = &.{ "--casks", "wget", "ghost" }, .want = "wget is not installed" },
        .{ .argv = &.{ "--formulae", "firefox", "wget" }, .want = "firefox is not installed" },
    };
    for (cases) |case| {
        var captured: std.ArrayList(u8) = .empty;
        defer captured.deinit(testing.allocator);
        malt.output.beginStderrCapture(testing.allocator, &captured);
        defer malt.output.endStderrCapture();
        try testing.expectError(error.Aborted, reinstall.execute(&ctx, arena.allocator(), case.argv));
        try testing.expect(std.mem.indexOf(u8, captured.items, case.want) != null);
    }

    const lock_file = try std.fmt.allocPrint(testing.allocator, "{s}/db/malt.lock", .{prefix});
    defer testing.allocator.free(lock_file);
    try testing.expect(!pathExists(lock_file));
}

test "execute points a core cask at uninstall then install instead of forcing it" {
    // A forced install would delete the live app before placing the new
    // copy, with no way back if that fails; exiting 0 unchanged hid that.
    const prefix = try setupPrefix("core_cask");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }
    const db_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/db/malt.db", .{prefix}, 0);
    defer testing.allocator.free(db_path);
    try test_io.cwd().createDirPath(std.Options.debug_io, std.fs.path.dirname(db_path).?);
    {
        var db = try malt.sqlite.Database.open(db_path);
        defer db.close();
        try malt.schema.initSchema(&db);
        try db.exec(
            \\INSERT INTO casks (token, name, version, url)
            \\  VALUES ('firefox', 'firefox', '120.0', 'https://x.invalid/f.dmg');
        );
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    for ([_][]const u8{ "firefox", "homebrew/cask/firefox" }) |typed| {
        try testing.expectError(error.Aborted, reinstall.execute(&ctx, arena.allocator(), &.{typed}));
    }

    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, captured.items, "`mt uninstall --cask firefox` then `mt install --cask firefox`"));
    const lock_file = try std.fmt.allocPrint(testing.allocator, "{s}/db/malt.lock", .{prefix});
    defer testing.allocator.free(lock_file);
    try testing.expect(!pathExists(lock_file));
}

test "execute names a control-byte local keg without echoing the byte" {
    // A row stored before install screened recipe paths: the scrubber passes
    // a UTF-8 C1, and install refuses the hint's path anyway.
    const prefix = try setupPrefix("local_control");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }
    const db_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/db/malt.db", .{prefix}, 0);
    defer testing.allocator.free(db_path);
    try test_io.cwd().createDirPath(std.Options.debug_io, std.fs.path.dirname(db_path).?);
    {
        var db = try malt.sqlite.Database.open(db_path);
        defer db.close();
        try malt.schema.initSchema(&db);
        try db.exec("INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, tap) " ++
            "VALUES ('lx', '/w/x' || char(155) || '2Jy/lx.rb', '1.0', 'a', '/c/lx', 'local');");
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    try testing.expectError(error.Aborted, reinstall.execute(&ctx, arena.allocator(), &.{"lx"}));

    try testing.expect(std.mem.indexOf(u8, captured.items, "\xc2\x9b") == null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "mt install --local --force '") == null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "lx (/w/x\\xc2\\x9b2Jy/lx.rb) is a local formula whose name or recipe path holds a control character") != null);
}

test "execute reports a table it cannot read instead of retargeting or calling the package missing" {
    // Read as a miss, a damaged kegs table sent a bare name to the same-named
    // cask, and a damaged casks table called an installed cask missing.
    const cases = .{
        .{ "kegs", &[_][]const u8{"box"} },
        .{ "kegs", &[_][]const u8{ "--formula", "box" } },
        .{ "casks", &[_][]const u8{ "--cask", "box" } },
    };
    inline for (cases, 0..) |case, i| {
        const prefix = try setupPrefix("corrupt_" ++ case[0] ++ std.fmt.comptimePrint("{d}", .{i}));
        defer {
            test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
            testing.allocator.free(prefix);
            _ = c.unsetenv("MALT_PREFIX");
        }
        const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{prefix});
        defer testing.allocator.free(db_dir);
        try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);
        const db_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/db/malt.db", .{prefix}, 0);
        defer testing.allocator.free(db_path);
        {
            var db = try malt.sqlite.Database.open(db_path);
            defer db.close();
            try malt.schema.initSchema(&db);
            try db.exec(
                \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path) VALUES ('box', 'box', '1.0', 'a', '/c/box');
                \\INSERT INTO casks (token, name, version, url) VALUES ('box', 'Box', '1.0', 'https://x.invalid/b.dmg');
            );
        }
        try test_io.corruptTable(db_path, case[0]);

        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const prior_quiet = malt.output.isQuiet();
        malt.output.setQuiet(false);
        defer malt.output.setQuiet(prior_quiet);
        var captured: std.ArrayList(u8) = .empty;
        defer captured.deinit(testing.allocator);
        malt.output.beginStderrCapture(testing.allocator, &captured);
        defer malt.output.endStderrCapture();

        const ctx: malt.app_ctx.AppCtx = .{ .io = std.Options.debug_io, .environ = .empty, .offline = true };
        try testing.expectError(error.Aborted, reinstall.execute(&ctx, arena.allocator(), case[1]));
        try testing.expect(std.mem.indexOf(u8, captured.items, "package database") != null);
        try testing.expect(std.mem.indexOf(u8, captured.items, "is a cask") == null);
        try testing.expect(std.mem.indexOf(u8, captured.items, "not installed") == null);
    }
}
