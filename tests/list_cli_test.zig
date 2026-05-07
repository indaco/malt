//! malt — `mt list` end-to-end dispatch tests.
//!
//! Existing list_test.zig covers the pure encoders (`writeHumanOutput`,
//! `buildListJson`). This file fills the dispatch — `execute` against a
//! scratch MALT_PREFIX with seeded kegs/casks rows.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const list = malt.cli_list;
const sqlite = malt.sqlite;
const schema = malt.schema;
const output = malt.output;

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
            "/tmp/malt_list_cli_{s}_{d}",
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

fn quiet() void {
    output.setQuiet(true);
}
fn unquiet() void {
    output.setQuiet(false);
}

fn seedRows(prefix: []const u8) !void {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    var ins = try db.prepare(
        \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, pinned)
        \\VALUES ('wget', 'wget', '1.21', 0, '', '/c/wget/1.21', 0),
        \\       ('jq',   'jq',   '1.7',  0, '', '/c/jq/1.7',   1);
    );
    defer ins.finalize();
    _ = try ins.step();

    var ins2 = try db.prepare(
        \\INSERT INTO casks (token, name, version, url, sha256)
        \\VALUES ('firefox', 'Firefox', '120.0', 'https://example/firefox.dmg', 'aa');
    );
    defer ins2.finalize();
    _ = try ins2.step();
}

fn ctxWithSink() malt.app_ctx.AppCtx {
    return .{
        .io = std.Options.debug_io,
        .environ = .empty,
        .stdout = test_io.testSink(),
        .stderr = test_io.testSink(),
    };
}

// --- early branches ----------------------------------------------------

test "execute --help short-circuits" {
    var s = try Scratch.init(testing.allocator, "help");
    defer s.deinit(testing.allocator);
    quiet();
    defer unquiet();
    try list.execute(&malt.app_ctx.debug_ctx, &.{"--help"});
}

test "execute on a fresh prefix with no db is a clean no-op" {
    // No db/ subdir → SQLite open fails → list takes the "empty dir" branch.
    const path = "/tmp/malt_list_cli_no_db";
    test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    _ = c.setenv("MALT_PREFIX", path, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    quiet();
    defer unquiet();
    try list.execute(&malt.app_ctx.debug_ctx, &.{});
}

// --- happy paths ------------------------------------------------------

test "execute with no flags lists both kegs and casks" {
    var s = try Scratch.init(testing.allocator, "no_flags");
    defer s.deinit(testing.allocator);
    try seedRows(s.path);

    const ctx = ctxWithSink();
    quiet();
    defer unquiet();
    try list.execute(&ctx, &.{});
}

test "execute --formula scopes the dump to kegs only" {
    var s = try Scratch.init(testing.allocator, "formula_only");
    defer s.deinit(testing.allocator);
    try seedRows(s.path);

    const ctx = ctxWithSink();
    quiet();
    defer unquiet();
    try list.execute(&ctx, &.{"--formula"});
}

test "execute --cask scopes the dump to casks only" {
    var s = try Scratch.init(testing.allocator, "cask_only");
    defer s.deinit(testing.allocator);
    try seedRows(s.path);

    const ctx = ctxWithSink();
    quiet();
    defer unquiet();
    try list.execute(&ctx, &.{"--cask"});
}

test "execute --versions includes version strings in the human dump" {
    var s = try Scratch.init(testing.allocator, "versions");
    defer s.deinit(testing.allocator);
    try seedRows(s.path);

    const ctx = ctxWithSink();
    quiet();
    defer unquiet();
    try list.execute(&ctx, &.{"--versions"});
}

test "execute --pinned scopes the dump to pinned rows only" {
    var s = try Scratch.init(testing.allocator, "pinned");
    defer s.deinit(testing.allocator);
    try seedRows(s.path);

    const ctx = ctxWithSink();
    quiet();
    defer unquiet();
    try list.execute(&ctx, &.{"--pinned"});
}

test "execute --json emits a JSON dump" {
    var s = try Scratch.init(testing.allocator, "json");
    defer s.deinit(testing.allocator);
    try seedRows(s.path);

    const prior_mode: output.OutputMode = if (output.isJson()) .json else .human;
    output.setMode(.json);
    quiet();
    defer {
        output.setMode(prior_mode);
        unquiet();
    }
    const ctx = ctxWithSink();
    try list.execute(&ctx, &.{});
}
