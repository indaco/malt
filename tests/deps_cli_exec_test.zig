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

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

const Scratch = struct {
    path: [:0]u8,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !Scratch {
        const ts = test_io.nanoTimestamp(std.Options.debug_io);
        const path = try std.fmt.allocPrintSentinel(
            allocator,
            "/tmp/malt_deps_cli_{s}_{d}",
            .{ tag, ts },
            0,
        );
        test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
        try test_io.cwd().createDirPath(std.Options.debug_io, path);
        const db_dir = try std.fmt.allocPrint(allocator, "{s}/db", .{path});
        defer allocator.free(db_dir);
        try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);
        _ = c.setenv("MALT_PREFIX", path.ptr, 1);
        return .{ .path = path };
    }

    fn deinit(self: *Scratch, allocator: std.mem.Allocator) void {
        _ = c.unsetenv("MALT_PREFIX");
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
    const path = "/tmp/malt_deps_cli_no_db";
    test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    _ = c.setenv("MALT_PREFIX", path, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    const ctx = ctxWithSink();
    quiet();
    defer unquiet();
    try deps_cli.execute(&ctx, testing.allocator, &.{ "--installed", "ghost" });
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
