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

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

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
