//! malt — idempotent-install fast-path integration tests.
//!
//! When every named package already has a populated Cellar entry and no
//! upgrade-forcing flag is in play, `install.execute` must short-circuit
//! before opening SQLite, acquiring the install lock, or initialising
//! the HTTP pool. Asserting "no DB file created" is the cheapest way to
//! pin that the fast path actually skipped the heavy setup.

const std = @import("std");
const malt = @import("malt");
const testing = std.testing;
const install = malt.install;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

fn pathExists(path: []const u8) bool {
    malt.fs_compat.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn seedCellarKeg(prefix: []const u8, name: []const u8, version: []const u8) !void {
    const dir = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/{s}/{s}", .{ prefix, name, version });
    defer testing.allocator.free(dir);
    try malt.fs_compat.cwd().makePath(dir);
}

/// Redirect fd 2 to /dev/null and return a saved dup. Subprocess stderr
/// (e.g. `ditto` complaining about a deliberately-broken cask path)
/// bypasses `io_mod.beginStderrCapture` since that only catches Zig
/// writes — silencing fd 2 itself is the only way to keep `just coverage`
/// output tidy.
fn silenceStderr() std.c.fd_t {
    const saved = std.c.dup(2);
    if (saved < 0) return -1;
    const dn = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
    if (dn < 0) {
        _ = std.c.close(saved);
        return -1;
    }
    _ = std.c.dup2(dn, 2);
    _ = std.c.close(dn);
    return saved;
}

fn restoreStderr(saved: std.c.fd_t) void {
    if (saved < 0) return;
    _ = std.c.dup2(saved, 2);
    _ = std.c.close(saved);
}

fn setupPrefix(suffix: []const u8) ![:0]u8 {
    const path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "/tmp/malt_install_idem_{d}_{s}",
        .{ malt.fs_compat.nanoTimestamp(), suffix },
        0,
    );
    malt.fs_compat.deleteTreeAbsolute(path) catch {};
    try malt.fs_compat.cwd().makePath(path);
    _ = c.setenv("MALT_PREFIX", path.ptr, 1);
    return path;
}

test "execute short-circuits without opening the DB when the keg already exists" {
    const prefix = try setupPrefix("hit");
    defer {
        malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
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
    malt.io_mod.beginStderrCapture(testing.allocator, &captured);
    defer malt.io_mod.endStderrCapture();

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
        malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
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
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.fs_compat.processEnviron() };
    // `--force` drives the full pipeline; we don't care about the eventual
    // outcome for an unresolvable name, only that the DB was opened.
    install.execute(&ctx, arena.allocator(), &.{ "--force", "--quiet", "seedpkg" }) catch {};

    try testing.expect(pathExists(db_file));
}

test "execute falls through when one of several args is missing from the Cellar" {
    const prefix = try setupPrefix("partial");
    defer {
        malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }

    try seedCellarKeg(prefix, "alpha", "1.0");

    const db_file = try std.fmt.allocPrint(testing.allocator, "{s}/db/malt.db", .{prefix});
    defer testing.allocator.free(db_file);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // The fall-through pipeline reaches a deliberately-broken cask
    // extract; ditto writes its complaint straight to fd 2 — gate it.
    const saved_stderr = silenceStderr();
    defer restoreStderr(saved_stderr);
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.fs_compat.processEnviron() };
    install.execute(&ctx, arena.allocator(), &.{ "--quiet", "alpha", "missing" }) catch {};

    try testing.expect(pathExists(db_file));
}

test "execute --dry-run skips the fast path so the plan still reaches the user" {
    const prefix = try setupPrefix("dryrun");
    defer {
        malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
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
