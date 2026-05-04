//! malt — `mt tap` / `mt untap` dispatch tests.
//!
//! Existing tap_test.zig and cli_tap_test.zig cover the core/tap.zig
//! helpers and the executor pure paths. This file fills the cli/tap.zig
//! `execute` and `executeUntap` dispatch — list, untap, validation
//! errors, refresh-on-untap rejection. The `tap.add` path is left out
//! because it shells out to `git ls-remote` for HEAD resolution.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const tap = malt.cli_tap;
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
            "/tmp/malt_tap_cli_{s}_{d}",
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

fn ctxWithSink() malt.app_ctx.AppCtx {
    return .{
        .io = std.Options.debug_io,
        .environ = .empty,
        .stdout = test_io.testSink(),
        .stderr = test_io.testSink(),
    };
}

fn seedTap(prefix: []const u8, name: []const u8, sha: ?[]const u8) !void {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    if (sha) |s| {
        var stmt = try db.prepare(
            \\INSERT INTO taps (name, url, commit_sha) VALUES (?1, ?2, ?3);
        );
        defer stmt.finalize();
        try stmt.bindText(1, name);
        try stmt.bindText(2, "https://example/repo");
        try stmt.bindText(3, s);
        _ = try stmt.step();
    } else {
        var stmt = try db.prepare(
            \\INSERT INTO taps (name, url) VALUES (?1, ?2);
        );
        defer stmt.finalize();
        try stmt.bindText(1, name);
        try stmt.bindText(2, "https://example/repo");
        _ = try stmt.step();
    }
}

// --- validateTapName --------------------------------------------------

test "validateTapName accepts well-formed user/repo" {
    try tap.validateTapName("homebrew/core");
    try tap.validateTapName("user-name/repo.name");
}

test "validateTapName rejects missing slash, double slash, traversal" {
    try testing.expectError(tap.TapNameError.InvalidTapName, tap.validateTapName("noslash"));
    try testing.expectError(tap.TapNameError.InvalidTapName, tap.validateTapName("a/b/c"));
    try testing.expectError(tap.TapNameError.InvalidTapName, tap.validateTapName(".hidden/repo"));
    try testing.expectError(tap.TapNameError.InvalidTapName, tap.validateTapName("user/.hidden"));
    try testing.expectError(tap.TapNameError.InvalidTapName, tap.validateTapName("user!/repo"));
    try testing.expectError(tap.TapNameError.InvalidTapName, tap.validateTapName(""));
    try testing.expectError(tap.TapNameError.InvalidTapName, tap.validateTapName("/repo"));
    try testing.expectError(tap.TapNameError.InvalidTapName, tap.validateTapName("user/"));
}

// --- execute (tap) early branches ------------------------------------

test "execute --help short-circuits without opening the database" {
    var s = try Scratch.init(testing.allocator, "help");
    defer s.deinit(testing.allocator);
    quiet();
    defer unquiet();
    try tap.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--help"});
}

test "execute on a fresh prefix with no db is a clean no-op" {
    const path = "/tmp/malt_tap_cli_no_db";
    test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    _ = c.setenv("MALT_PREFIX", path, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    quiet();
    defer unquiet();
    try tap.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{});
}

test "execute on an empty taps table prints \"No taps registered\"" {
    var s = try Scratch.init(testing.allocator, "list_empty");
    defer s.deinit(testing.allocator);
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
    }
    quiet();
    defer unquiet();
    try tap.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{});
}

test "execute lists pinned + unpinned taps with the right line shape" {
    var s = try Scratch.init(testing.allocator, "list_full");
    defer s.deinit(testing.allocator);
    try seedTap(s.path, "homebrew/core", "0123456789abcdef0123456789abcdef01234567");
    try seedTap(s.path, "user/unpinned", null);

    const ctx = ctxWithSink();
    quiet();
    defer unquiet();
    try tap.execute(&ctx, testing.allocator, &.{});
}

test "execute on an invalid tap name returns Aborted" {
    var s = try Scratch.init(testing.allocator, "invalid");
    defer s.deinit(testing.allocator);
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
    }

    quiet();
    defer unquiet();
    try testing.expectError(
        error.Aborted,
        tap.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"badname-no-slash"}),
    );
}

// --- executeUntap branches -------------------------------------------

test "executeUntap with no args returns Aborted with a usage hint" {
    var s = try Scratch.init(testing.allocator, "untap_noargs");
    defer s.deinit(testing.allocator);
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
    }
    quiet();
    defer unquiet();
    try testing.expectError(
        error.Aborted,
        tap.executeUntap(&malt.app_ctx.debug_ctx, testing.allocator, &.{}),
    );
}

test "executeUntap removes the matching row and is idempotent on rerun" {
    var s = try Scratch.init(testing.allocator, "untap_ok");
    defer s.deinit(testing.allocator);
    try seedTap(s.path, "user/repo", "0123456789abcdef0123456789abcdef01234567");

    quiet();
    defer unquiet();

    try tap.executeUntap(&malt.app_ctx.debug_ctx, testing.allocator, &.{"user/repo"});
    try tap.executeUntap(&malt.app_ctx.debug_ctx, testing.allocator, &.{"user/repo"});
}

test "executeUntap --refresh is rejected (refresh is tap-only)" {
    var s = try Scratch.init(testing.allocator, "untap_refresh");
    defer s.deinit(testing.allocator);
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
    }
    quiet();
    defer unquiet();
    try testing.expectError(
        error.Aborted,
        tap.executeUntap(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "user/repo", "--refresh" }),
    );
}
