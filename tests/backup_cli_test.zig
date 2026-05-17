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
// --- --json dispatch -------------------------------------------------
//
// Under `--json` the default path emits to stdout (no default file), so
// CI pipelines that already use `jq` don't have to clean up a stale
// `malt-backup-*.txt` after each call. The plain-text path stays
// unchanged to preserve `mt restore` parity.

fn withJson() bool {
    const prior = output.isJson();
    output.setMode(.json);
    return prior;
}

fn restoreJson(prior: bool) void {
    output.setMode(if (prior) .json else .human);
}

test "execute --json on an empty DB emits `{formulas:[],casks:[]}`" {
    var s = try Scratch.init(testing.allocator, "json_empty");
    defer s.deinit(testing.allocator);

    const prior = withJson();
    defer restoreJson(prior);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer output.endStdoutCapture();

    quiet();
    defer unquiet();
    try backup.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{});

    try testing.expectEqualStrings("{\"formulas\":[],\"casks\":[]}\n", stdout_buf.items);
}

test "execute --json on a populated DB emits direct formulas + casks with tap" {
    var s = try Scratch.init(testing.allocator, "json_populated");
    defer s.deinit(testing.allocator);
    try seedRows(s.path);

    const prior = withJson();
    defer restoreJson(prior);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer output.endStdoutCapture();

    quiet();
    defer unquiet();
    try backup.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{});

    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"name\":\"wget\"") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"name\":\"jq\"") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"name\":\"firefox\"") != null);
    // Dep-only row excluded — `mt restore` pulls deps transitively.
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"name\":\"zlib\"") == null);
    try testing.expect(std.mem.startsWith(u8, stdout_buf.items, "{\"formulas\":["));
    try testing.expect(std.mem.endsWith(u8, stdout_buf.items, "]}\n"));
}

test "execute --json output is a parseable JSON document" {
    var s = try Scratch.init(testing.allocator, "json_valid_parse");
    defer s.deinit(testing.allocator);
    try seedRows(s.path);

    const prior = withJson();
    defer restoreJson(prior);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer output.endStdoutCapture();

    quiet();
    defer unquiet();
    try backup.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{});

    // Hand the captured bytes to the standard JSON parser; anything other
    // than a clean parse means we shipped malformed output.
    const trimmed = std.mem.trim(u8, stdout_buf.items, " \t\r\n");
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, trimmed, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try testing.expect(root.contains("formulas"));
    try testing.expect(root.contains("casks"));
    try testing.expectEqual(@as(usize, 2), root.get("formulas").?.array.items.len);
    try testing.expectEqual(@as(usize, 1), root.get("casks").?.array.items.len);
}

test "execute --json keeps the cask `tap` field separate (no token qualification)" {
    var s = try Scratch.init(testing.allocator, "json_tap");
    defer s.deinit(testing.allocator);
    try seedTapCask(s.path);

    const prior = withJson();
    defer restoreJson(prior);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer output.endStdoutCapture();

    quiet();
    defer unquiet();
    try backup.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{});

    // Bare token + separate `tap` field — consumers re-qualify themselves.
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"name\":\"flux-markdown\"") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"tap\":\"xykong/tap\"") != null);
    // The slash-qualified shape belongs to plain-text only — must not leak in.
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "xykong/tap/flux-markdown") == null);
    // Core-API cask: empty `tap` field.
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"name\":\"firefox\"") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"name\":\"firefox\",\"version\":\"120.0\",\"tap\":\"\"") != null);
}

test "execute --json --versions is a no-op (version is already a field, not a suffix)" {
    var s = try Scratch.init(testing.allocator, "json_versions");
    defer s.deinit(testing.allocator);
    try seedRows(s.path);

    const prior = withJson();
    defer restoreJson(prior);

    var with_buf: std.ArrayList(u8) = .empty;
    defer with_buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &with_buf);
    quiet();
    try backup.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--versions"});
    output.endStdoutCapture();

    var without_buf: std.ArrayList(u8) = .empty;
    defer without_buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &without_buf);
    try backup.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{});
    output.endStdoutCapture();
    unquiet();

    try testing.expectEqualStrings(with_buf.items, without_buf.items);
    // No `name@version` suffix may bleed in from the plain-text writer.
    try testing.expect(std.mem.indexOf(u8, with_buf.items, "wget@") == null);
    try testing.expect(std.mem.indexOf(u8, with_buf.items, "firefox@") == null);
}

test "execute --json --output - emits to stdout instead of a default file" {
    var s = try Scratch.init(testing.allocator, "json_stdout");
    defer s.deinit(testing.allocator);
    try seedRows(s.path);

    const prior = withJson();
    defer restoreJson(prior);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer output.endStdoutCapture();

    quiet();
    defer unquiet();
    try backup.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "--output", "-" });

    try testing.expect(std.mem.startsWith(u8, stdout_buf.items, "{\"formulas\":["));
    try testing.expect(std.mem.endsWith(u8, stdout_buf.items, "]}\n"));
}

// --- --services round-trip -------------------------------------------
//
// `mt bundle export` populates services into the manifest; the JSON
// surface of `mt backup` mirrors the behaviour so dotfiles workflows
// can capture launchd state in one shot. Plain-text backups stay
// untouched — the canonical file format has no `service` line.

fn seedServices(prefix: []const u8) !void {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    try db.exec(
        \\INSERT INTO services (name, keg_name, plist_path, auto_start, last_status)
        \\VALUES ('postgresql@16', 'postgresql@16', '/tmp/p.plist', 1, 'running'),
        \\       ('redis',         'redis',         '/tmp/r.plist', 0, 'stopped');
    );
}

test "execute --json --services emits auto_start services only" {
    var s = try Scratch.init(testing.allocator, "json_services");
    defer s.deinit(testing.allocator);
    try seedServices(s.path);

    const prior = withJson();
    defer restoreJson(prior);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer output.endStdoutCapture();

    quiet();
    defer unquiet();
    try backup.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--services"});

    const trimmed = std.mem.trim(u8, stdout_buf.items, " \t\r\n");
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, trimmed, .{});
    defer parsed.deinit();
    const services = parsed.value.object.get("services") orelse return error.MissingServices;
    try testing.expectEqual(@as(usize, 1), services.array.items.len);
    try testing.expectEqualStrings("postgresql@16", services.array.items[0].object.get("name").?.string);
    try testing.expect(services.array.items[0].object.get("auto_start").?.bool);
}

test "execute --json without --services omits the services array" {
    var s = try Scratch.init(testing.allocator, "json_no_services");
    defer s.deinit(testing.allocator);
    try seedServices(s.path);

    const prior = withJson();
    defer restoreJson(prior);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer output.endStdoutCapture();

    quiet();
    defer unquiet();
    try backup.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{});

    const trimmed = std.mem.trim(u8, stdout_buf.items, " \t\r\n");
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, trimmed, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("services") == null);
}

test "execute --json --services on an empty services table emits `services:[]`" {
    // Pins the explicit-empty contract: when the user asks for
    // services and there are none, the array still appears so a
    // downstream consumer can branch on `services` length, not on
    // its absence.
    var s = try Scratch.init(testing.allocator, "json_services_empty");
    defer s.deinit(testing.allocator);
    // schema init only; no services seeded.
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
    }

    const prior = withJson();
    defer restoreJson(prior);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer output.endStdoutCapture();

    quiet();
    defer unquiet();
    try backup.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--services"});

    try testing.expectEqualStrings(
        "{\"formulas\":[],\"casks\":[],\"services\":[]}\n",
        stdout_buf.items,
    );
}

test "execute --json --services composes with --versions and --output -" {
    // Combined-flag smoke: arg parser is order-independent and the
    // services payload still rides on stdout-mode output.
    var s = try Scratch.init(testing.allocator, "json_services_combined");
    defer s.deinit(testing.allocator);
    try seedServices(s.path);
    try seedRows(s.path);

    const prior = withJson();
    defer restoreJson(prior);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer output.endStdoutCapture();

    quiet();
    defer unquiet();
    try backup.execute(
        &malt.app_ctx.debug_ctx,
        testing.allocator,
        &.{ "--versions", "--services", "--output", "-" },
    );

    const trimmed = std.mem.trim(u8, stdout_buf.items, " \t\r\n");
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, trimmed, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("services") != null);
    try testing.expect(parsed.value.object.get("formulas") != null);
    try testing.expect(parsed.value.object.get("casks") != null);
}

test "execute --services on plain-text backup is a silent no-op (no `service` line)" {
    var s = try Scratch.init(testing.allocator, "text_services_noop");
    defer s.deinit(testing.allocator);
    try seedServices(s.path);

    const out_path = try std.fmt.allocPrint(testing.allocator, "{s}/snap.txt", .{s.path});
    defer testing.allocator.free(out_path);

    quiet();
    defer unquiet();
    try backup.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "--services", "--output", out_path });

    const body = try readAll(testing.allocator, out_path);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "service ") == null);
    try testing.expect(std.mem.indexOf(u8, body, "postgresql@16") == null);
}

test "execute --json with --output <path> writes JSON to the file" {
    var s = try Scratch.init(testing.allocator, "json_to_path");
    defer s.deinit(testing.allocator);
    try seedRows(s.path);

    const out_path = try std.fmt.allocPrint(testing.allocator, "{s}/snap.json", .{s.path});
    defer testing.allocator.free(out_path);

    const prior = withJson();
    defer restoreJson(prior);

    quiet();
    defer unquiet();
    try backup.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "--output", out_path });

    const body = try readAll(testing.allocator, out_path);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.startsWith(u8, body, "{\"formulas\":["));
    try testing.expect(std.mem.endsWith(u8, body, "]}\n"));
    try testing.expect(std.mem.indexOf(u8, body, "\"name\":\"wget\"") != null);
}

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
