//! malt — backup command end-to-end tests.
//!
//! Covers `backup.execute` against a scratch MALT_PREFIX with seeded
//! kegs/casks rows. The pure `parseLine` / `parseBackup` / `writeEntry`
//! helpers are already covered in `tests/backup_test.zig`; this file
//! fills the dispatch + DB-walk + output-routing branches.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const backup = malt.backup;
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
            "/tmp/malt_backup_exec_{s}_{d}",
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

    // Two direct-install formulae + one dep-only (must be omitted from
    // backup since restore pulls deps transitively).
    var ins1 = try db.prepare(
        \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, install_reason)
        \\VALUES ('wget', 'wget', '1.21', 0, '', '/c/wget/1.21', 'direct'),
        \\       ('jq',   'jq',   '1.7',  0, '', '/c/jq/1.7',   'direct'),
        \\       ('zlib', 'zlib', '1.3',  0, '', '/c/zlib/1.3', 'dep');
    );
    defer ins1.finalize();
    _ = try ins1.step();

    var ins2 = try db.prepare(
        \\INSERT INTO casks (token, name, version, url, sha256)
        \\VALUES ('firefox', 'Firefox', '120.0', 'https://example/firefox.dmg', 'aa');
    );
    defer ins2.finalize();
    _ = try ins2.step();
}

fn readAll(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const f = try test_io.cwd().openFile(std.Options.debug_io, path, .{});
    defer f.close(std.Options.debug_io);
    const stat = try f.stat(std.Options.debug_io);
    const buf = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(buf);
    const n = try f.readPositionalAll(std.Options.debug_io, buf, 0);
    if (n != stat.size) return error.ShortRead;
    return buf;
}

// --- early-return + arg parsing ---------------------------------------

test "execute --help short-circuits before opening the database" {
    var s = try Scratch.init(testing.allocator, "help");
    defer s.deinit(testing.allocator);
    quiet();
    defer unquiet();
    try backup.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--help"});
}

test "execute rejects unknown flags" {
    var s = try Scratch.init(testing.allocator, "unknown_flag");
    defer s.deinit(testing.allocator);
    quiet();
    defer unquiet();
    try testing.expectError(
        backup.Error.InvalidArgs,
        backup.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--nope"}),
    );
}

test "execute --output without a value is rejected" {
    var s = try Scratch.init(testing.allocator, "no_output_value");
    defer s.deinit(testing.allocator);
    quiet();
    defer unquiet();
    try testing.expectError(
        backup.Error.InvalidArgs,
        backup.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--output"}),
    );
}

test "execute fails fast when the database is unopenable" {
    // No DB file pre-created and no db/ dir means SQLite cannot create
    // the file (no parent). That's the DatabaseError branch.
    const path = "/tmp/malt_backup_no_db_dir";
    test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    _ = c.setenv("MALT_PREFIX", path, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    quiet();
    defer unquiet();

    try testing.expectError(
        backup.Error.DatabaseError,
        backup.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "--output", "/tmp/discard.txt" }),
    );
}

// --- happy-path output routing ----------------------------------------

test "execute --output <path> writes only direct-install rows + casks" {
    var s = try Scratch.init(testing.allocator, "to_path");
    defer s.deinit(testing.allocator);
    try seedRows(s.path);

    const out_path = try std.fmt.allocPrint(testing.allocator, "{s}/snap.txt", .{s.path});
    defer testing.allocator.free(out_path);

    quiet();
    defer unquiet();

    try backup.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "--output", out_path });

    const body = try readAll(testing.allocator, out_path);
    defer testing.allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "formula wget") != null);
    try testing.expect(std.mem.indexOf(u8, body, "formula jq") != null);
    try testing.expect(std.mem.indexOf(u8, body, "cask firefox") != null);
    // Dep-only row is excluded — install pulls it transitively.
    try testing.expect(std.mem.indexOf(u8, body, "zlib") == null);
}

test "execute -o <path> short alias mirrors --output" {
    var s = try Scratch.init(testing.allocator, "short");
    defer s.deinit(testing.allocator);
    try seedRows(s.path);

    const out_path = try std.fmt.allocPrint(testing.allocator, "{s}/snap2.txt", .{s.path});
    defer testing.allocator.free(out_path);

    quiet();
    defer unquiet();

    try backup.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "-o", out_path });

    const body = try readAll(testing.allocator, out_path);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "formula wget") != null);
}

test "execute --output=<path> joined-form is accepted" {
    var s = try Scratch.init(testing.allocator, "joined");
    defer s.deinit(testing.allocator);
    try seedRows(s.path);

    const out_path = try std.fmt.allocPrint(testing.allocator, "--output={s}/snap3.txt", .{s.path});
    defer testing.allocator.free(out_path);

    quiet();
    defer unquiet();

    try backup.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{out_path});

    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/snap3.txt", .{s.path});
    defer testing.allocator.free(expected);
    const body = try readAll(testing.allocator, expected);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "cask firefox") != null);
}

test "execute --versions appends @<version> to every entry" {
    var s = try Scratch.init(testing.allocator, "versions");
    defer s.deinit(testing.allocator);
    try seedRows(s.path);

    const out_path = try std.fmt.allocPrint(testing.allocator, "{s}/snap.txt", .{s.path});
    defer testing.allocator.free(out_path);

    quiet();
    defer unquiet();

    try backup.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "--versions", "--output", out_path });

    const body = try readAll(testing.allocator, out_path);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "formula wget@1.21") != null);
    try testing.expect(std.mem.indexOf(u8, body, "formula jq@1.7") != null);
    try testing.expect(std.mem.indexOf(u8, body, "cask firefox@120.0") != null);
}

test "execute --output - emits to stdout instead of a file" {
    var s = try Scratch.init(testing.allocator, "stdout");
    defer s.deinit(testing.allocator);
    try seedRows(s.path);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer output.endStdoutCapture();

    quiet();
    defer unquiet();

    try backup.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "--output", "-" });

    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "formula wget") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "cask firefox") != null);
}

test "execute -q sets quiet mode without breaking the write" {
    var s = try Scratch.init(testing.allocator, "quiet");
    defer s.deinit(testing.allocator);
    try seedRows(s.path);

    const out_path = try std.fmt.allocPrint(testing.allocator, "{s}/snap.txt", .{s.path});
    defer testing.allocator.free(out_path);

    defer unquiet();
    try backup.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "-q", "--output", out_path });

    const body = try readAll(testing.allocator, out_path);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "formula wget") != null);
}

// `mt restore` re-feeds the backup file through `mt install`. For tap
// casks, the unqualified token would 404 against the core API, so the
// backup line must carry the `user/repo/token` slug shape that
// `installTapFormula` resolves. The bare-token form is preserved for
// core-API casks so backups produced before schema v6 keep working.
fn seedTapCask(prefix: []const u8) !void {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    try db.exec(
        \\INSERT INTO casks (token, name, version, url, sha256, tap)
        \\VALUES ('flux-markdown', 'flux-markdown', '0.1.0',
        \\        'https://example.invalid/flux.dmg', 'aa', 'xykong/tap');
    );
    try db.exec(
        \\INSERT INTO casks (token, name, version, url, sha256)
        \\VALUES ('firefox', 'Firefox', '120.0', 'https://example/firefox.dmg', 'bb');
    );
}

test "execute writes tap casks as <user>/<repo>/<token> so restore re-routes correctly" {
    var s = try Scratch.init(testing.allocator, "tap_cask_slug");
    defer s.deinit(testing.allocator);
    try seedTapCask(s.path);

    const out_path = try std.fmt.allocPrint(testing.allocator, "{s}/snap.txt", .{s.path});
    defer testing.allocator.free(out_path);

    quiet();
    defer unquiet();
    try backup.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "--output", out_path });

    const body = try readAll(testing.allocator, out_path);
    defer testing.allocator.free(body);

    // Tap cask: fully-qualified slug so restore routes through
    // `installTapFormula`.
    try testing.expect(std.mem.indexOf(u8, body, "cask xykong/tap/flux-markdown") != null);

    // Bare-token form preserved for the core-API cask alongside.
    try testing.expect(std.mem.indexOf(u8, body, "cask firefox\n") != null);

    // Negative: the tap cask must NOT also surface in the unqualified
    // form, otherwise restore would attempt both and the bare-token
    // attempt would 404 against the core API.
    try testing.expect(std.mem.indexOf(u8, body, "cask flux-markdown\n") == null);
}
