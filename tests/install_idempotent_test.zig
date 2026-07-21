//! malt — idempotent-install fast-path integration tests.
//!
//! When every named package already has a populated Cellar entry and no
//! upgrade-forcing flag is in play, `install.execute` must short-circuit
//! before opening SQLite, acquiring the install lock, or initialising
//! the HTTP pool. Asserting "no DB file created" is the cheapest way to
//! pin that the fast path actually skipped the heavy setup.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const install = malt.install;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

fn pathExists(path: []const u8) bool {
    test_io.accessAbsolute(std.Options.debug_io, path, .{}) catch return false;
    return true;
}

fn seedCellarKeg(prefix: []const u8, name: []const u8, version: []const u8) !void {
    const dir = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/{s}/{s}", .{ prefix, name, version });
    defer testing.allocator.free(dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, dir);
}

fn setupPrefix(suffix: []const u8) ![:0]u8 {
    const base = try test_io.uniqueTempPath(testing.allocator, "install_idem", suffix);
    defer testing.allocator.free(base);
    const path = try testing.allocator.dupeZ(u8, base);
    test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, path);
    _ = c.setenv("MALT_PREFIX", path.ptr, 1);
    return path;
}

test "execute short-circuits without opening the DB when the keg already exists" {
    const prefix = try setupPrefix("hit");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }

    try seedCellarKeg(prefix, "seedpkg", "1.0");

    const db_file = try std.fmt.allocPrint(testing.allocator, "{s}/db/malt.db", .{prefix});
    defer testing.allocator.free(db_file);
    const lock_file = try std.fmt.allocPrint(testing.allocator, "{s}/db/malt.lock", .{prefix});
    defer testing.allocator.free(lock_file);

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
    try install.execute(&ctx, arena.allocator(), &.{"seedpkg"});

    // No SQLite open ⇒ no malt.db file. No lock acquire ⇒ no malt.lock.
    try testing.expect(!pathExists(db_file));
    try testing.expect(!pathExists(lock_file));
    try testing.expect(std.mem.indexOf(u8, captured.items, "seedpkg is already installed") != null);
}

test "execute --force falls through to the existing path even when the keg exists" {
    const prefix = try setupPrefix("force");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }

    try seedCellarKeg(prefix, "seedpkg", "1.0");

    const db_file = try std.fmt.allocPrint(testing.allocator, "{s}/db/malt.db", .{prefix});
    defer testing.allocator.free(db_file);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    // `--force` drives the full pipeline; we don't care about the eventual
    // outcome for an unresolvable name, only that the DB was opened.
    install.execute(&ctx, arena.allocator(), &.{ "--force", "--quiet", "seedpkg" }) catch {};

    try testing.expect(pathExists(db_file));
}

test "execute falls through when one of several args is missing from the Cellar" {
    const prefix = try setupPrefix("partial");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }

    // Uppercase names fail api.validateName synchronously — keeps the
    // fall-through pipeline off the network. "alpha" is a real Homebrew
    // cask, so the prior fixture downloaded Alpha.app and crashed.
    try seedCellarKeg(prefix, "ALPHA_FIXTURE", "1.0");

    const db_file = try std.fmt.allocPrint(testing.allocator, "{s}/db/malt.db", .{prefix});
    defer testing.allocator.free(db_file);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    install.execute(&ctx, arena.allocator(), &.{ "--quiet", "ALPHA_FIXTURE", "MISSING_FIXTURE" }) catch {};

    try testing.expect(pathExists(db_file));
}

test "execute --dry-run skips the fast path so the plan still reaches the user" {
    const prefix = try setupPrefix("dryrun");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }

    try seedCellarKeg(prefix, "seedpkg", "1.0");

    const db_file = try std.fmt.allocPrint(testing.allocator, "{s}/db/malt.db", .{prefix});
    defer testing.allocator.free(db_file);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    install.execute(&ctx, arena.allocator(), &.{ "--dry-run", "--quiet", "seedpkg" }) catch {};

    try testing.expect(pathExists(db_file));
}
