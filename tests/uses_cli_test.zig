//! malt — `mt uses` dispatch tests.
//!
//! Existing uses_test.zig covers the pure helpers (`collectDependents`,
//! `encodeJson`). This file pins `execute` against a scratch
//! MALT_PREFIX so the dispatch + writer + flush paths land on the
//! coverage map.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const uses = malt.cli_uses;
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
            "/tmp/malt_uses_cli_{s}_{d}",
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

fn seedDeps(prefix: []const u8) !void {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    // wget depends on openssl.
    var ins_keg = try db.prepare(
        \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
        \\VALUES ('wget', 'wget', '1.21', 0, '', '/c/wget/1.21'),
        \\       ('curl', 'curl', '8.0',  0, '', '/c/curl/8.0');
    );
    defer ins_keg.finalize();
    _ = try ins_keg.step();

    var ins_dep = try db.prepare(
        \\INSERT INTO dependencies (keg_id, dep_name)
        \\SELECT id, 'openssl' FROM kegs WHERE name = 'wget'
        \\UNION ALL
        \\SELECT id, 'openssl' FROM kegs WHERE name = 'curl';
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
    try uses.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--help"});
}

test "execute with no positional formula returns Aborted" {
    var s = try Scratch.init(testing.allocator, "noargs");
    defer s.deinit(testing.allocator);
    quiet();
    defer unquiet();
    try testing.expectError(
        error.Aborted,
        uses.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{}),
    );
}

test "execute on a fresh prefix with no db emits an empty result" {
    const path = "/tmp/malt_uses_cli_no_db";
    test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    _ = c.setenv("MALT_PREFIX", path, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    const ctx = ctxWithSink();
    quiet();
    defer unquiet();
    try uses.execute(&ctx, testing.allocator, &.{"openssl"});
}

// --- happy paths ------------------------------------------------------

test "execute lists direct dependents in human mode" {
    var s = try Scratch.init(testing.allocator, "direct");
    defer s.deinit(testing.allocator);
    try seedDeps(s.path);

    const ctx = ctxWithSink();
    quiet();
    defer unquiet();
    try uses.execute(&ctx, testing.allocator, &.{"openssl"});
}

test "execute --recursive walks the transitive closure" {
    var s = try Scratch.init(testing.allocator, "recursive");
    defer s.deinit(testing.allocator);
    try seedDeps(s.path);

    const ctx = ctxWithSink();
    quiet();
    defer unquiet();
    try uses.execute(&ctx, testing.allocator, &.{ "openssl", "--recursive" });
}

test "execute -r is the short alias for --recursive" {
    var s = try Scratch.init(testing.allocator, "rshort");
    defer s.deinit(testing.allocator);
    try seedDeps(s.path);

    const ctx = ctxWithSink();
    quiet();
    defer unquiet();
    try uses.execute(&ctx, testing.allocator, &.{ "-r", "openssl" });
}

test "execute --json on no-result emits an empty uses array" {
    var s = try Scratch.init(testing.allocator, "json_empty");
    defer s.deinit(testing.allocator);
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
    }

    const prior_mode: output.OutputMode = if (output.isJson()) .json else .human;
    output.setMode(.json);
    quiet();
    defer {
        output.setMode(prior_mode);
        unquiet();
    }

    const ctx = ctxWithSink();
    try uses.execute(&ctx, testing.allocator, &.{"ghost"});
}

test "execute --json with seeded deps emits the dependents in the array" {
    var s = try Scratch.init(testing.allocator, "json_full");
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
    try uses.execute(&ctx, testing.allocator, &.{"openssl"});
}
