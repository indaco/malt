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

const c = test_io.c;

const Scratch = struct {
    path: [:0]u8,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !Scratch {
        const base = try test_io.uniqueTempPath(allocator, "list_cli", tag);
        defer allocator.free(base);
        const path = try allocator.dupeZ(u8, base);
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
    const base = try test_io.uniqueTempPath(testing.allocator, "list_cli", "no_db");
    defer testing.allocator.free(base);
    const path = try testing.allocator.dupeZ(u8, base);
    defer testing.allocator.free(path);
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

// --- layout dispatch --------------------------------------------------

/// Run `execute` with stdout on a scratch file: a non-terminal stdout, the
/// shape of `mt list > out.txt` or a pipe.
fn executeToFile(s: *const Scratch, args: []const []const u8, verbose: bool) ![]u8 {
    const io = std.Options.debug_io;
    const out_path = try std.fmt.allocPrint(testing.allocator, "{s}/stdout.txt", .{s.path});
    defer testing.allocator.free(out_path);
    const f = try std.Io.Dir.createFileAbsolute(io, out_path, .{});
    output.setVerbose(verbose);
    defer output.setVerbose(false);
    malt.color.setForTest(false, false);
    defer malt.color.setForTest(null, null);
    var ctx = ctxWithSink();
    ctx.stdout = f;
    list.execute(&ctx, args) catch |e| {
        f.close(io);
        return e;
    };
    f.close(io);
    return test_io.cwd().readFileAlloc(io, out_path, testing.allocator, .limited(1 << 16));
}

test "execute off a terminal prints bare names so pipes and redirects stay grep -x friendly" {
    var s = try Scratch.init(testing.allocator, "dispatch_piped");
    defer s.deinit(testing.allocator);
    try seedRows(s.path);

    const out = try executeToFile(&s, &.{}, false);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("jq\nwget\nfirefox\n", out);
}

test "execute -v keeps the bulleted row layout with the [pinned] tag" {
    var s = try Scratch.init(testing.allocator, "dispatch_verbose");
    defer s.deinit(testing.allocator);
    try seedRows(s.path);

    const out = try executeToFile(&s, &.{}, true);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("  ▸ jq [pinned]\n  ▸ wget\n  ▸ firefox\n", out);
}

// --- unreadable install database ---------------------------------------
//
// An empty list reads as "nothing installed"; only a prefix with no db/
// may say that without reading anything.

/// Runs `list` in both output modes; each must abort and name the DB.
fn expectListRefusesDb() !void {
    const prior_mode: output.OutputMode = if (output.isJson()) .json else .human;
    defer output.setMode(prior_mode);
    var err_buf: std.ArrayList(u8) = .empty;
    defer err_buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &err_buf);
    defer output.endStderrCapture();
    for ([_]output.OutputMode{ .human, .json }) |mode| {
        output.setMode(mode);
        err_buf.clearRetainingCapacity();
        try testing.expectError(error.Aborted, list.execute(&ctxWithSink(), &.{}));
        try testing.expect(std.mem.indexOf(u8, err_buf.items, "install database") != null);
    }
}

test "execute reports a malt.db that is not a database instead of an empty list" {
    var s = try Scratch.init(testing.allocator, "garbage_db");
    defer s.deinit(testing.allocator);
    var path_buf: [512]u8 = undefined;
    const f = try test_io.createFileAbsolute(std.Options.debug_io, try std.fmt.bufPrint(&path_buf, "{s}/db/malt.db", .{s.path}), .{ .truncate = true });
    defer f.close(std.Options.debug_io);
    try f.writeStreamingAll(std.Options.debug_io, "not a sqlite database, just garbage bytes" ** 4);
    try expectListRefusesDb();
}

test "execute reports a db/ directory it cannot look into instead of an empty list" {
    if (std.c.geteuid() == 0) return error.SkipZigTest; // root bypasses the perm wall
    var s = try Scratch.init(testing.allocator, "walled_db");
    defer s.deinit(testing.allocator);
    try seedRows(s.path);
    var dir_buf: [512]u8 = undefined;
    const walled = try test_io.wallDir(std.Options.debug_io, try std.fmt.bufPrint(&dir_buf, "{s}/db", .{s.path}));
    defer test_io.unwallDir(std.Options.debug_io, walled);
    try expectListRefusesDb();
}
