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

const c = test_io.c;

fn pathExists(path: []const u8) bool {
    test_io.accessAbsolute(std.Options.debug_io, path, .{}) catch return false;
    return true;
}

fn seedCellarKeg(prefix: []const u8, name: []const u8, version: []const u8) !void {
    const dir = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/{s}/{s}", .{ prefix, name, version });
    defer testing.allocator.free(dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, dir);
}

/// Create `<prefix>/db/malt.db` with the real schema and run `sql` against
/// it. The cask and tap-form probes read that DB, so their fixtures need a
/// genuine one rather than a hand-rolled table.
fn seedDb(prefix: []const u8, sql: [:0]const u8) !void {
    const dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{prefix});
    defer testing.allocator.free(dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, dir);

    const path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/db/malt.db", .{prefix}, 0);
    defer testing.allocator.free(path);
    var db = try malt.sqlite.Database.open(path);
    defer db.close();
    try malt.schema.initSchema(&db);
    try db.exec(sql);
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

test "execute never claims a dot-entry name is already installed" {
    const prefix = try setupPrefix("dotentry");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }

    // `Cellar/.` and `Cellar/..` always resolve, so an unguarded probe
    // reports success for a name that can never have been installed.
    const cellar = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar", .{prefix});
    defer testing.allocator.free(cellar);
    try test_io.cwd().createDirPath(std.Options.debug_io, cellar);

    const prior_quiet = malt.output.isQuiet();
    malt.output.setQuiet(false);
    defer malt.output.setQuiet(prior_quiet);

    for ([_][]const u8{ ".", "..", "./x" }) |name| {
        var captured: std.ArrayList(u8) = .empty;
        defer captured.deinit(testing.allocator);
        malt.output.beginStderrCapture(testing.allocator, &captured);
        defer malt.output.endStderrCapture();

        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var threaded: std.Io.Threaded = .init(testing.allocator, .{});
        defer threaded.deinit();
        const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
        install.execute(&ctx, arena.allocator(), &.{name}) catch {};

        try testing.expect(std.mem.indexOf(u8, captured.items, "is already installed") == null);
    }
}

test "execute --cask short-circuits when the cask is recorded in the DB" {
    const prefix = try setupPrefix("cask");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }

    try seedDb(prefix,
        \\INSERT INTO casks(token,name,version,url,sha256,app_path)
        \\  VALUES('seedcask','SeedCask','1.0','https://example.invalid/a.dmg','x','/Applications/Seed.app');
    );

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
    try install.execute(&ctx, arena.allocator(), &.{ "--cask", "seedcask" });

    // The DB file is part of the fixture, so the lock is what pins that the
    // heavy setup never ran.
    try testing.expect(!pathExists(lock_file));
    try testing.expect(std.mem.indexOf(u8, captured.items, "seedcask is already installed") != null);
}

test "execute --cask falls through when no cask row backs the token" {
    const prefix = try setupPrefix("caskmiss");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }

    // A Cellar entry must not stand in for a cask row: the two live in
    // different layouts and only the row survives a partial install.
    try seedCellarKeg(prefix, "SEEDCASK_FIXTURE", "1.0");
    try seedDb(prefix, "SELECT 1;");

    const lock_file = try std.fmt.allocPrint(testing.allocator, "{s}/db/malt.lock", .{prefix});
    defer testing.allocator.free(lock_file);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    install.execute(&ctx, arena.allocator(), &.{ "--cask", "--quiet", "SEEDCASK_FIXTURE" }) catch {};

    try testing.expect(pathExists(lock_file));
}

test "execute short-circuits on the tap form when the keg is recorded against that tap" {
    const prefix = try setupPrefix("tap");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }

    // A tap keg lands in the Cellar under its leaf name, so the probe needs
    // both the directory and the row that names the owning tap.
    try seedCellarKeg(prefix, "tapleaf", "1.0");
    try seedDb(prefix,
        \\INSERT INTO kegs(name,full_name,version,tap,store_sha256,cellar_path)
        \\  VALUES('tapleaf','owner/repo/tapleaf','1.0','owner/repo','x','/Cellar/tapleaf/1.0');
    );

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
    try install.execute(&ctx, arena.allocator(), &.{"owner/repo/tapleaf"});

    try testing.expect(!pathExists(lock_file));
    try testing.expect(std.mem.indexOf(u8, captured.items, "owner/repo/tapleaf is already installed") != null);
}

test "execute falls through when the tap form names a keg owned by another tap" {
    const prefix = try setupPrefix("tapmismatch");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }

    // Without the tap match, `owner/repo/tapleaf` would claim the
    // homebrew/core keg of the same leaf name is what the user asked for.
    try seedCellarKeg(prefix, "tapleaf", "1.0");
    try seedDb(prefix,
        \\INSERT INTO kegs(name,full_name,version,tap,store_sha256,cellar_path)
        \\  VALUES('tapleaf','tapleaf','1.0','homebrew/core','x','/Cellar/tapleaf/1.0');
    );

    const lock_file = try std.fmt.allocPrint(testing.allocator, "{s}/db/malt.lock", .{prefix});
    defer testing.allocator.free(lock_file);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    // No `taps` row for owner/repo, so the fall-through fails at URL
    // resolution and never reaches the network.
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    install.execute(&ctx, arena.allocator(), &.{ "--quiet", "owner/repo/tapleaf" }) catch {};

    try testing.expect(pathExists(lock_file));
}

test "execute short-circuits on the tap form when a cask row backs the token" {
    const prefix = try setupPrefix("tapcask");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }

    // No Cellar and no Caskroom dir: `recordCaskroom` is best-effort, so the
    // row is the only marker a tap cask is guaranteed to leave.
    try seedDb(prefix,
        \\INSERT INTO casks(token,name,version,url,sha256,app_path,tap)
        \\  VALUES('deckclip','Deck','1.4.5','https://example.invalid/d.dmg','x','/Applications/Deck.app','owner/repo');
    );

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
    try install.execute(&ctx, arena.allocator(), &.{"owner/repo/deckclip"});

    try testing.expect(!pathExists(lock_file));
    try testing.expect(std.mem.indexOf(u8, captured.items, "owner/repo/deckclip is already installed") != null);
}

test "execute falls through when the tap form names a cask owned by another tap" {
    const prefix = try setupPrefix("tapcaskmismatch");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }

    try seedDb(prefix,
        \\INSERT INTO casks(token,name,version,url,sha256,app_path,tap)
        \\  VALUES('deckclip','Deck','1.4.5','https://example.invalid/d.dmg','x','/Applications/Deck.app','homebrew/cask');
    );

    const lock_file = try std.fmt.allocPrint(testing.allocator, "{s}/db/malt.lock", .{prefix});
    defer testing.allocator.free(lock_file);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    install.execute(&ctx, arena.allocator(), &.{ "--quiet", "owner/repo/deckclip" }) catch {};

    try testing.expect(pathExists(lock_file));
}

test "execute --download-only still warms the store for an installed formula" {
    const prefix = try setupPrefix("dlonlyformula");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }

    // The keg row says nothing about whether the *current* version's bottle
    // is in the store, so warming it is never a no-op worth skipping.
    try seedCellarKeg(prefix, "ALPHA_FIXTURE", "1.0");

    const db_file = try std.fmt.allocPrint(testing.allocator, "{s}/db/malt.db", .{prefix});
    defer testing.allocator.free(db_file);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = malt.app_ctx.processEnviron() };
    install.execute(&ctx, arena.allocator(), &.{ "--download-only", "--quiet", "ALPHA_FIXTURE" }) catch {};

    try testing.expect(pathExists(db_file));
}

test "execute --download-only on the tap form still refreshes the cached artefact" {
    const prefix = try setupPrefix("tapdlonly");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }

    try seedCellarKeg(prefix, "tapleaf", "1.0");
    try seedDb(prefix,
        \\INSERT INTO kegs(name,full_name,version,tap,store_sha256,cellar_path)
        \\  VALUES('tapleaf','owner/repo/tapleaf','1.0','owner/repo','x','/Cellar/tapleaf/1.0');
    );

    const lock_file = try std.fmt.allocPrint(testing.allocator, "{s}/db/malt.lock", .{prefix});
    defer testing.allocator.free(lock_file);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    install.execute(&ctx, arena.allocator(), &.{ "--download-only", "--quiet", "owner/repo/tapleaf" }) catch {};

    // The prefetch `mt upgrade` relies on must not be swallowed by the gate.
    try testing.expect(pathExists(lock_file));
}

test "installTapFormula returns before any fetch when the keg is recorded against that tap" {
    // Direct entry point: callers that legitimately bypass the fast path
    // must not pay a `.rb` round trip either. No `taps` row is seeded, so a
    // regression that drops the short-circuit fails at URL resolution
    // rather than silently passing.
    const prefix = try setupPrefix("tapdirect");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }

    try seedDb(prefix,
        \\INSERT INTO kegs(name,full_name,version,tap,store_sha256,cellar_path)
        \\  VALUES('tapleaf','owner/repo/tapleaf','1.0','owner/repo','x','/Cellar/tapleaf/1.0');
    );

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    const db_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/db/malt.db", .{prefix}, 0);
    defer testing.allocator.free(db_path);
    var db = try malt.sqlite.Database.open(db_path);
    defer db.close();
    var linker = malt.linker.Linker.init(ctx.io, allocator, &db, prefix);

    const prior_quiet = malt.output.isQuiet();
    malt.output.setQuiet(false);
    defer malt.output.setQuiet(prior_quiet);

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();

    try malt.install_local.installTapFormula(
        &ctx,
        allocator,
        "owner/repo/tapleaf",
        &db,
        &linker,
        prefix,
        false, // dry_run
        false, // force
        false, // download_only
        malt.install_sink.terminal,
    );

    try testing.expect(std.mem.indexOf(u8, captured.items, "tapleaf is already installed") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "Resolving tap") == null);
}

test "execute --dry-run skips the fast path so the plan still reaches the user" {
    const prefix = try setupPrefix("dryrun");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }

    try seedCellarKeg(prefix, "seedpkg", "1.0");

    const prior_quiet = malt.output.isQuiet();
    malt.output.setQuiet(false);
    defer malt.output.setQuiet(prior_quiet);
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty, .offline = true };
    install.execute(&ctx, arena.allocator(), &.{ "--dry-run", "seedpkg" }) catch {};

    // Offline, the slow path reports the uncached formula; the fast path
    // would have answered "already installed" without planning anything.
    try testing.expect(std.mem.indexOf(u8, captured.items, "not cached") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "already installed") == null);
}

test "execute --dry-run on a prefix that does not exist yet creates nothing" {
    const parent = try setupPrefix("dryrun_fresh");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, parent) catch {};
        testing.allocator.free(parent);
        _ = c.unsetenv("MALT_PREFIX");
    }
    const prefix = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/p", .{parent}, 0);
    defer testing.allocator.free(prefix);
    _ = c.setenv("MALT_PREFIX", prefix.ptr, 1);

    const prior_quiet = malt.output.isQuiet();
    malt.output.setQuiet(false);
    defer malt.output.setQuiet(prior_quiet);
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty, .offline = true };
    const prior_ndjson = malt.output.isNdjson();
    malt.output.setNdjson(true);
    defer malt.output.setNdjson(prior_ndjson);
    var events: std.ArrayList(u8) = .empty;
    defer events.deinit(testing.allocator);
    malt.output.beginStdoutCapture(testing.allocator, &events);
    defer malt.output.endStdoutCapture();

    install.execute(&ctx, arena.allocator(), &.{ "--dry-run", "freshpkg" }) catch {};

    // The preview still plans against the empty install a real run would start from.
    try testing.expect(std.mem.indexOf(u8, captured.items, "not cached") != null);
    try testing.expect(!pathExists(prefix));
    // No lock was taken, so neither half of the lock bracket may appear alone.
    const opened = std.mem.indexOf(u8, events.items, "\"event\":\"lock_acquired\"") != null;
    const closed = std.mem.indexOf(u8, events.items, "\"event\":\"install_complete\"") != null;
    try testing.expectEqual(opened, closed);
}

test "execute --cask refuses an unreadable casks table before fetching the cask" {
    const prefix = try setupPrefix("caskcorrupt");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }
    try seedDb(prefix,
        \\INSERT INTO casks(token,name,version,url) VALUES('seedcask','SeedCask','1.0','https://example.invalid/a.dmg');
    );
    const db_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/db/malt.db", .{prefix}, 0);
    defer testing.allocator.free(db_path);
    try test_io.corruptTable(db_path, "casks");

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
    // Offline with no cached record: reaching the fetch would fail
    // OfflineRequired, so a database error proves the guard ran first.
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty, .offline = true };
    // A per-package failure; the message is what tells the DB apart from the fetch.
    try testing.expectError(error.PartialFailure, install.execute(&ctx, arena.allocator(), &.{ "--cask", "seedcask" }));
    try testing.expect(std.mem.indexOf(u8, captured.items, "package database") != null);
}

test "execute --cask --download-only never consults an unreadable casks table" {
    const prefix = try setupPrefix("caskcorruptdl");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }
    try seedDb(prefix,
        \\INSERT INTO casks(token,name,version,url) VALUES('seedcask','SeedCask','1.0','https://example.invalid/a.dmg');
    );
    const db_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/db/malt.db", .{prefix}, 0);
    defer testing.allocator.free(db_path);
    try test_io.corruptTable(db_path, "casks");

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
    // Refreshing the cache must not depend on the install record: offline
    // with nothing cached, it stops at the fetch, not at the table.
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty, .offline = true };
    if (install.execute(&ctx, arena.allocator(), &.{ "--cask", "--download-only", "seedcask" })) |_| return error.TestUnexpectedResult else |_| {}
    try testing.expect(std.mem.indexOf(u8, captured.items, "package database") == null);
}

test "execute --dry-run reads the database only once it holds the lock" {
    // A preview that copied first would plan from what a concurrent writer
    // was about to replace; here the writer moves the schema past this malt.
    const prefix = try setupPrefix("dryrun_lock");
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
        _ = c.unsetenv("MALT_PREFIX");
    }
    try seedDb(prefix, "SELECT 1;");

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const lock_path = try std.fmt.allocPrint(testing.allocator, "{s}/db/malt.lock", .{prefix});
    defer testing.allocator.free(lock_path);
    const db_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/db/malt.db", .{prefix}, 0);
    defer testing.allocator.free(db_path);

    const Writer = struct {
        fn run(wio: std.Io, holder: *malt.lock.LockFile, path: [:0]const u8) void {
            std.Io.sleep(wio, .fromMilliseconds(300), .awake) catch {};
            if (malt.sqlite.Database.open(path)) |db| {
                var w = db;
                w.exec("INSERT INTO schema_version (version) VALUES (999);") catch {};
                w.close();
            } else |_| {}
            holder.release(wio);
        }
    };
    var holder = try malt.lock.LockFile.acquire(io, lock_path, 1000);
    const writer = try std.Thread.spawn(.{}, Writer.run, .{ io, &holder, db_path });

    const prior_quiet = malt.output.isQuiet();
    malt.output.setQuiet(false);
    defer malt.output.setQuiet(prior_quiet);
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.output.beginStderrCapture(testing.allocator, &captured);
    defer malt.output.endStderrCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = io, .environ = .empty, .offline = true };
    install.execute(&ctx, arena.allocator(), &.{ "--dry-run", "foo" }) catch {};
    writer.join();

    try testing.expect(std.mem.indexOf(u8, captured.items, "schema v999") != null);
}
