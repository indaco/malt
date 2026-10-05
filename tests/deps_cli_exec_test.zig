//! malt — `mt deps` dispatch tests.
//!
//! Covers the `execute` path against a seeded scratch prefix (matching
//! the pattern in `uses_cli_test.zig`). The pure helpers are unit-tested
//! in `tests/deps_cli_test.zig`; this file pins the CLI seam so the
//! writer/flush/dispatch wiring keeps working end-to-end.

const std = @import("std");
const testing = std.testing;

const malt = @import("malt");
const deps_cli = malt.cli_deps;
const sqlite = malt.sqlite;
const schema = malt.schema;
const output = malt.output;
const test_io = @import("test_io");

const c = test_io.c;

const Scratch = struct {
    path: [:0]u8,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !Scratch {
        const base = try test_io.uniqueTempPath(allocator, "deps_cli", tag);
        defer allocator.free(base);
        const path = try allocator.dupeZ(u8, base);
        test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
        try test_io.cwd().createDirPath(std.Options.debug_io, path);
        const db_dir = try std.fmt.allocPrint(allocator, "{s}/db", .{path});
        defer allocator.free(db_dir);
        try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);
        const api_dir = try std.fmt.allocPrint(allocator, "{s}/cache/api", .{path});
        defer allocator.free(api_dir);
        try test_io.cwd().createDirPath(std.Options.debug_io, api_dir);
        _ = c.setenv("MALT_PREFIX", path.ptr, 1);
        // An inherited MALT_CACHE would miss the seeded records, and a miss
        // aborts just like a refusal does.
        var cache_buf: [512]u8 = undefined;
        const cache = try std.fmt.bufPrintSentinel(&cache_buf, "{s}/cache", .{path}, 0);
        _ = c.setenv("MALT_CACHE", cache.ptr, 1);
        return .{ .path = path };
    }

    fn deinit(self: *Scratch, allocator: std.mem.Allocator) void {
        _ = c.unsetenv("MALT_PREFIX");
        _ = c.unsetenv("MALT_CACHE");
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.path) catch {};
        allocator.free(self.path);
    }
};

fn ctxWithSink() malt.app_ctx.AppCtx {
    return .{
        .io = std.Options.debug_io,
        .environ = .empty,
        .stdout = test_io.testSink(),
        .stderr = test_io.testSink(),
    };
}

fn quiet() void {
    output.setQuiet(true);
}
fn unquiet() void {
    output.setQuiet(false);
}

/// Seed two installed kegs: wget → openssl@3, curl → openssl@3.
fn seedDeps(prefix: []const u8) !void {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    var ins_keg = try db.prepare(
        \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
        \\VALUES ('wget', 'wget', '1.21', 0, '', '/c/wget/1.21'),
        \\       ('openssl@3', 'openssl@3', '3.2', 0, '', '/c/openssl@3/3.2'),
        \\       ('curl', 'curl', '8.0', 0, '', '/c/curl/8.0');
    );
    defer ins_keg.finalize();
    _ = try ins_keg.step();

    var ins_dep = try db.prepare(
        \\INSERT INTO dependencies (keg_id, dep_name)
        \\SELECT id, 'openssl@3' FROM kegs WHERE name = 'wget'
        \\UNION ALL
        \\SELECT id, 'openssl@3' FROM kegs WHERE name = 'curl';
    );
    defer ins_dep.finalize();
    _ = try ins_dep.step();
}

// --- early branches ----------------------------------------------------

test "execute --help short-circuits" {
    var s = try Scratch.init(testing.allocator, "help");
    defer s.deinit(testing.allocator);
    quiet();
    defer unquiet();
    try deps_cli.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--help"});
}

test "execute with no positional formula returns Aborted" {
    var s = try Scratch.init(testing.allocator, "noargs");
    defer s.deinit(testing.allocator);
    quiet();
    defer unquiet();
    try testing.expectError(
        error.Aborted,
        deps_cli.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{}),
    );
}

test "execute on a fresh prefix without --installed still completes" {
    // No db, no api hit either — must degrade cleanly without panic.
    const unique = try test_io.uniqueTempPath(testing.allocator, "deps_cli", "no_db");
    defer testing.allocator.free(unique);
    const path = try testing.allocator.dupeZ(u8, unique);
    defer testing.allocator.free(path);
    test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    _ = c.setenv("MALT_PREFIX", path.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    const ctx = ctxWithSink();
    quiet();
    defer unquiet();
    try deps_cli.execute(&ctx, testing.allocator, &.{ "--installed", "ghost" });
}

// A partial graph must not be rendered as the answer. The error is what
// `main` maps to the interrupt exit code, so it is the user-visible contract.
test "execute surfaces an interrupt instead of printing a partial graph" {
    var s = try Scratch.init(testing.allocator, "interrupted");
    defer s.deinit(testing.allocator);
    try seedDeps(s.path);

    const prior = malt.signals.isInterrupted();
    defer malt.signals.setInterruptedForTest(prior);
    malt.signals.setInterruptedForTest(true);

    const ctx = ctxWithSink();
    quiet();
    defer unquiet();
    try testing.expectError(
        error.UserInterrupted,
        deps_cli.execute(&ctx, testing.allocator, &.{ "--installed", "-r", "wget" }),
    );
}

// --- happy paths ------------------------------------------------------

test "execute --installed reads direct deps from the DB" {
    var s = try Scratch.init(testing.allocator, "direct_installed");
    defer s.deinit(testing.allocator);
    try seedDeps(s.path);

    const ctx = ctxWithSink();
    quiet();
    defer unquiet();
    try deps_cli.execute(&ctx, testing.allocator, &.{ "--installed", "wget" });
}

test "execute --installed -r walks the transitive set" {
    var s = try Scratch.init(testing.allocator, "recursive_installed");
    defer s.deinit(testing.allocator);
    try seedDeps(s.path);

    const ctx = ctxWithSink();
    quiet();
    defer unquiet();
    try deps_cli.execute(&ctx, testing.allocator, &.{ "--installed", "-r", "wget" });
}

test "execute --installed --json emits an array shape" {
    var s = try Scratch.init(testing.allocator, "json_installed");
    defer s.deinit(testing.allocator);
    try seedDeps(s.path);

    const prior_mode: output.OutputMode = if (output.isJson()) .json else .human;
    output.setMode(.json);
    quiet();
    defer {
        output.setMode(prior_mode);
        unquiet();
    }

    const ctx = ctxWithSink();
    try deps_cli.execute(&ctx, testing.allocator, &.{ "--installed", "wget" });
}

// --- API records that could not be read -------------------------------

fn offlineCtx() malt.app_ctx.AppCtx {
    var ctx = ctxWithSink();
    ctx.offline = true;
    return ctx;
}

/// `demo` carries a control byte in a dependency name, so the parser refuses
/// it; `top` reaches it only through a transitive walk.
fn seedApiCache(prefix: []const u8) !void {
    const records = [_]struct { []const u8, []const u8 }{
        .{
            "demo",
            \\{"name":"demo","versions":{"stable":"1.0"},"dependencies":["x\u001b[2J"]}
        },
        .{
            "top",
            \\{"name":"top","versions":{"stable":"1.0"},"dependencies":["demo","leaf"]}
        },
        .{
            "leaf",
            \\{"name":"leaf","versions":{"stable":"1.0"},"dependencies":[]}
        },
    };
    for (records) |r| {
        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/cache/api/formula_{s}.json", .{ prefix, r[0] });
        const f = try test_io.createFileAbsolute(std.Options.debug_io, path, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, r[1]);
    }
}

fn expectDepsAborts(args: []const []const u8) !void {
    const ctx = offlineCtx();
    quiet();
    defer unquiet();
    try testing.expectError(error.Aborted, deps_cli.execute(&ctx, testing.allocator, args));
}

test "execute reports a refused root record instead of not-found" {
    var s = try Scratch.init(testing.allocator, "refused_root");
    defer s.deinit(testing.allocator);
    try seedApiCache(s.path);
    try expectDepsAborts(&.{"demo"});
}

test "execute -r aborts on a refused inner record instead of rendering it missing" {
    // A tree with the branch silently marked "(not installed)" reads as a
    // complete answer.
    var s = try Scratch.init(testing.allocator, "refused_inner");
    defer s.deinit(testing.allocator);
    try seedApiCache(s.path);
    try expectDepsAborts(&.{ "-r", "top" });
}

test "execute reports an offline cache miss instead of not-found" {
    var s = try Scratch.init(testing.allocator, "offline_miss");
    defer s.deinit(testing.allocator);
    try seedApiCache(s.path);
    try expectDepsAborts(&.{"nope"});
}

test "execute reports an interrupt that cut a lookup short, not the lookup failure" {
    // Ctrl-C cancels the in-flight fetch, so the lookup fails too; the
    // user asked to stop and must get the interrupt exit code.
    var s = try Scratch.init(testing.allocator, "interrupted_lookup");
    defer s.deinit(testing.allocator);
    try seedApiCache(s.path);

    const prior = malt.signals.isInterrupted();
    defer malt.signals.setInterruptedForTest(prior);
    malt.signals.setInterruptedForTest(true);

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();

    const ctx = offlineCtx();
    try testing.expectError(error.UserInterrupted, deps_cli.execute(&ctx, testing.allocator, &.{"nope"}));
    try testing.expect(std.mem.indexOf(u8, captured.items, "Interrupted") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "not cached") == null);
}

test "execute still renders clean API records offline" {
    // Guards against a fix that aborts on every API lookup.
    var s = try Scratch.init(testing.allocator, "clean_api");
    defer s.deinit(testing.allocator);
    try seedApiCache(s.path);

    const ctx = offlineCtx();
    quiet();
    defer unquiet();
    try deps_cli.execute(&ctx, testing.allocator, &.{"leaf"});
    // Non-recursive never looks up direct deps, so the refused `demo` is
    // only a name here.
    try deps_cli.execute(&ctx, testing.allocator, &.{"top"});
    try deps_cli.execute(&ctx, testing.allocator, &.{ "-r", "leaf" });
}

test "execute reports an install database it cannot open instead of not-found" {
    // An existing DB that fails to open says nothing about what is
    // installed; with or without --installed it must not read as empty.
    var s = try Scratch.init(testing.allocator, "db_unopenable");
    defer s.deinit(testing.allocator);
    try seedApiCache(s.path);
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrint(&db_path_buf, "{s}/db/malt.db", .{s.path});
    const f = try test_io.createFileAbsolute(std.Options.debug_io, db_path, .{ .truncate = true });
    defer f.close(std.Options.debug_io);
    try f.writeStreamingAll(std.Options.debug_io, "not a sqlite database, just garbage bytes" ** 4);

    try expectDepsAborts(&.{ "--installed", "wget" });
    try expectDepsAborts(&.{"leaf"});
}

test "execute reports a db/ directory it cannot look into instead of not-found" {
    // A probe of the file under a mode-000 db/ fails with EACCES, which
    // must not read as "no database yet".
    if (std.c.geteuid() == 0) return error.SkipZigTest; // root bypasses the perm wall
    var s = try Scratch.init(testing.allocator, "db_walled");
    defer s.deinit(testing.allocator);
    try seedDeps(s.path);
    var dir_buf: [512]u8 = undefined;
    const walled = try test_io.wallDir(std.Options.debug_io, try std.fmt.bufPrint(&dir_buf, "{s}/db", .{s.path}));
    defer test_io.unwallDir(std.Options.debug_io, walled);

    try expectDepsAborts(&.{ "--installed", "wget" });
}

// --- DB adapter contract ------------------------------------------------

test "dbDepLookup returns null for an unknown keg" {
    var s = try Scratch.init(testing.allocator, "db_unknown");
    defer s.deinit(testing.allocator);
    try seedDeps(s.path);

    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();

    const lookup = deps_cli.dbDepLookup(&db);
    const got = try lookup.fetch(testing.allocator, "ghost");
    try testing.expect(got == null);
}

test "dbDepLookup returns owned strings for an installed keg" {
    var s = try Scratch.init(testing.allocator, "db_hit");
    defer s.deinit(testing.allocator);
    try seedDeps(s.path);

    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();

    const lookup = deps_cli.dbDepLookup(&db);
    const got = (try lookup.fetch(testing.allocator, "wget")).?;
    defer {
        for (got) |d| testing.allocator.free(d);
        testing.allocator.free(got);
    }
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("openssl@3", got[0]);
}

// An unreadable DB says nothing about what is installed; reading it as a
// miss renders an installed keg as "(not installed)" or "not found".
test "dbDepLookup reports a database it cannot query instead of a miss" {
    var s = try Scratch.init(testing.allocator, "db_no_kegs");
    defer s.deinit(testing.allocator);

    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();

    quiet();
    defer unquiet();
    try testing.expectError(error.Aborted, deps_cli.dbDepLookup(&db).fetch(testing.allocator, "wget"));
}

test "dbDepLookup reports an unreadable dependency table instead of a leaf" {
    // The keg row resolves, so a swallowed failure here would render wget
    // as having no dependencies.
    var s = try Scratch.init(testing.allocator, "db_no_deps");
    defer s.deinit(testing.allocator);
    try seedDeps(s.path);

    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try db.exec("DROP TABLE dependencies;");

    quiet();
    defer unquiet();
    try testing.expectError(error.Aborted, deps_cli.dbDepLookup(&db).fetch(testing.allocator, "wget"));
}

test "dbDepLookup reports a keg table it cannot read instead of a miss" {
    var s = try Scratch.init(testing.allocator, "db_corrupt_kegs");
    defer s.deinit(testing.allocator);
    try seedDeps(s.path);

    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
    try test_io.corruptTable(db_path, "kegs");
    var db = try sqlite.Database.open(db_path);
    defer db.close();

    quiet();
    defer unquiet();
    try testing.expectError(error.Aborted, deps_cli.dbDepLookup(&db).fetch(testing.allocator, "wget"));
}

test "dbDepLookup reports dependency rows it cannot read instead of a leaf" {
    var s = try Scratch.init(testing.allocator, "db_corrupt_deps");
    defer s.deinit(testing.allocator);
    try seedDeps(s.path);

    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
    try test_io.corruptTable(db_path, "dependencies");
    var db = try sqlite.Database.open(db_path);
    defer db.close();

    quiet();
    defer unquiet();
    try testing.expectError(error.Aborted, deps_cli.dbDepLookup(&db).fetch(testing.allocator, "wget"));
}

test "dbDepLookup returns an empty slice for an installed leaf keg" {
    // openssl@3 is installed but has no rows in dependencies — must
    // come back as an empty slice (not null), so the caller renders it
    // as a leaf in the tree, not as "not installed".
    var s = try Scratch.init(testing.allocator, "db_leaf");
    defer s.deinit(testing.allocator);
    try seedDeps(s.path);

    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();

    const lookup = deps_cli.dbDepLookup(&db);
    const got = (try lookup.fetch(testing.allocator, "openssl@3")).?;
    defer {
        for (got) |d| testing.allocator.free(d);
        testing.allocator.free(got);
    }
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "execute refuses an unknown flag instead of answering without it" {
    // brew's `--tree` used to print the flat list as if it were the tree.
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();
    try testing.expectError(error.Aborted, deps_cli.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "--tree", "wget" }));
    try testing.expect(std.mem.indexOf(u8, captured.items, "Unknown flag: --tree") != null);
}
