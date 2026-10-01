//! malt — CLI behaviour against a DB newer than this binary's schema.
//!
//! `schema.migrate` refuses a DB whose `schema_version` exceeds
//! `known_schema_version`. These tests pin that the commands a user
//! reaches for say so — naming both versions — instead of exiting 0 with
//! empty output, printing an opaque failure, or operating on the DB anyway.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const list = malt.cli_list;
const search = malt.cli_search;
const pin = malt.cli_pin;
const install = malt.install;
const install_record = malt.install_record;
const doctor = malt.doctor;
const purge = malt.purge;
const bundle = malt.cli_bundle;
const sqlite = malt.sqlite;
const schema = malt.schema;
const output = malt.output;

const c = test_io.c;

const too_new: i64 = schema.known_schema_version + 1;

/// Scratch prefix whose DB carries one keg row and a `schema_version`
/// marker one past what this binary supports.
const Scratch = struct {
    path: [:0]u8,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !Scratch {
        const base = try test_io.uniqueTempPath(allocator, "schema_too_new", tag);
        defer allocator.free(base);
        const path = try allocator.dupeZ(u8, base);
        test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
        const db_dir = try std.fmt.allocPrint(allocator, "{s}/db", .{path});
        defer allocator.free(db_dir);
        try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);
        _ = c.setenv("MALT_PREFIX", path.ptr, 1);

        var db = try openDb(path);
        defer db.close();
        try schema.initSchema(&db);
        try db.exec(
            \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, pinned)
            \\VALUES ('tree', 'tree', '2.1', 0, '', '/c/tree/2.1', 0);
        );
        var sql_buf: [96]u8 = undefined;
        const bump = try std.fmt.bufPrintSentinel(&sql_buf, "INSERT INTO schema_version(version) VALUES ({d});", .{too_new}, 0);
        try db.exec(bump);
        return .{ .path = path };
    }

    fn deinit(self: *Scratch, allocator: std.mem.Allocator) void {
        _ = c.unsetenv("MALT_PREFIX");
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.path) catch {};
        allocator.free(self.path);
    }

    fn openDb(prefix: []const u8) !sqlite.Database {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
        return sqlite.Database.open(db_path);
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

/// The diagnostic must let the user compare the two numbers, and must
/// never be the old opaque line that hid them.
fn expectNamesBothVersions(captured: []const u8) !void {
    var db_buf: [16]u8 = undefined;
    const db_tag = try std.fmt.bufPrint(&db_buf, "v{d}", .{too_new});
    var max_buf: [16]u8 = undefined;
    const max_tag = try std.fmt.bufPrint(&max_buf, "v{d}", .{schema.known_schema_version});
    try testing.expect(std.mem.indexOf(u8, captured, db_tag) != null);
    try testing.expect(std.mem.indexOf(u8, captured, max_tag) != null);
    try testing.expect(std.mem.indexOf(u8, captured, "Failed to initialize database schema") == null);
}

test "list refuses a too-new DB and names both versions" {
    var s = try Scratch.init(testing.allocator, "list");
    defer s.deinit(testing.allocator);
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();

    const ctx = ctxWithSink();
    try testing.expectError(error.SchemaTooNew, list.execute(&ctx, &.{}));
    try expectNamesBothVersions(captured.items);
}

test "list --json refuses a too-new DB rather than emitting an empty prefix" {
    // The TUI parses `list --json`; a silent rc 0 renders as "nothing installed".
    var s = try Scratch.init(testing.allocator, "list_json");
    defer s.deinit(testing.allocator);
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();

    const ctx = ctxWithSink();
    try testing.expectError(error.SchemaTooNew, list.execute(&ctx, &.{"--json"}));
    try expectNamesBothVersions(captured.items);
}

test "install refuses a too-new DB with the version diagnostic, not the opaque line" {
    var s = try Scratch.init(testing.allocator, "install");
    defer s.deinit(testing.allocator);
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = ctxWithSink();
    try testing.expectError(
        install_record.InstallError.DatabaseError,
        install.execute(&ctx, arena.allocator(), &.{"tree"}),
    );
    try expectNamesBothVersions(captured.items);
}

test "pin refuses a too-new DB instead of operating on it" {
    var s = try Scratch.init(testing.allocator, "pin");
    defer s.deinit(testing.allocator);
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();

    const ctx = ctxWithSink();
    try testing.expectError(error.SchemaTooNew, pin.execute(&ctx, testing.allocator, &.{"tree"}));
    try expectNamesBothVersions(captured.items);

    // The gate exists so an older binary never writes to a newer shape.
    var db = try Scratch.openDb(s.path);
    defer db.close();
    var stmt = try db.prepare("SELECT pinned FROM kegs WHERE name = 'tree';");
    defer stmt.finalize();
    try testing.expect(try stmt.step());
    try testing.expectEqual(@as(i64, 0), stmt.columnInt(0));
}

test "search --installed refuses a too-new DB instead of reporting nothing installed" {
    var s = try Scratch.init(testing.allocator, "search");
    defer s.deinit(testing.allocator);
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();

    const ctx = ctxWithSink();
    try testing.expectError(error.SchemaTooNew, search.execute(&ctx, testing.allocator, &.{ "--installed", "tree" }));
    try expectNamesBothVersions(captured.items);
}

fn schemaCheck() !doctor.Check {
    for (doctor.checks) |ck| if (std.mem.eql(u8, ck.name, "Database schema")) return ck;
    return error.MissingDatabaseSchemaCheck;
}

test "doctor's schema row fails on a too-new DB and passes once the marker is gone" {
    var s = try Scratch.init(testing.allocator, "doctor");
    defer s.deinit(testing.allocator);
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();

    const ck = try schemaCheck();
    const ctx: doctor.CheckCtx = .{
        .allocator = testing.allocator,
        .prefix = s.path,
        .io = std.Options.debug_io,
        .environ = .empty,
    };
    try testing.expectEqual(doctor.CheckStatus.err_status, ck.run(ctx, ck.name));
    try expectNamesBothVersions(captured.items);

    {
        var db = try Scratch.openDb(s.path);
        defer db.close();
        var sql_buf: [96]u8 = undefined;
        const drop = try std.fmt.bufPrintSentinel(&sql_buf, "DELETE FROM schema_version WHERE version = {d};", .{too_new}, 0);
        try db.exec(drop);
    }
    try testing.expectEqual(doctor.CheckStatus.ok, ck.run(ctx, ck.name));
}

test "doctor's schema row has nothing to compare without a database and stays ok" {
    // A db-less prefix is `Directory structure`'s warning to give; a second
    // row for the same cause would double the tally.
    const base = try test_io.uniqueTempPath(testing.allocator, "schema_too_new", "doctor_no_db");
    defer testing.allocator.free(base);
    test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, base);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();

    const ck = try schemaCheck();
    try testing.expectEqual(doctor.CheckStatus.ok, ck.run(.{
        .allocator = testing.allocator,
        .prefix = base,
        .io = std.Options.debug_io,
        .environ = .empty,
    }, ck.name));
}

test "every purge scope that reads the DB refuses a too-new one with exit 4, not a generic failure" {
    // Upgrading malt, not repairing the DB, is the fix; exit 4 says so to
    // scripts the same way every other command does.
    var s = try Scratch.init(testing.allocator, "purge");
    defer s.deinit(testing.allocator);
    const cellar = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar", .{s.path});
    defer testing.allocator.free(cellar);
    try test_io.cwd().createDirPath(std.Options.debug_io, cellar);

    const runs = [_][]const []const u8{
        &.{ "--store-orphans", "--yes" },
        &.{ "--unused-deps", "--yes" },
        &.{ "--stale-casks", "--yes" },
        &.{ "--old-versions", "--yes" },
        &.{ "--housekeeping", "--yes" },
    };
    const ctx = malt.app_ctx.debug_ctx;
    for (runs) |args| {
        var captured: std.ArrayList(u8) = .empty;
        defer captured.deinit(testing.allocator);
        output.beginStderrCapture(testing.allocator, &captured);
        defer output.endStderrCapture();

        try testing.expectError(error.SchemaTooNew, purge.execute(&ctx, testing.allocator, args));
        try expectNamesBothVersions(captured.items);
    }
}

test "purge --json names a too-new DB in error_kind so scripts need not parse stderr" {
    var s = try Scratch.init(testing.allocator, "purge_json");
    defer s.deinit(testing.allocator);

    const prior_json = output.isJson();
    output.setMode(.json);
    defer output.setMode(if (prior_json) .json else .human);
    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer output.endStdoutCapture();

    const ctx = malt.app_ctx.debug_ctx;
    try testing.expectError(error.SchemaTooNew, purge.execute(&ctx, testing.allocator, &.{ "--store-orphans", "--yes" }));

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, std.mem.trim(u8, stdout_buf.items, " \r\n\t"), .{});
    defer parsed.deinit();
    const row = parsed.value.object.get("scopes").?.array.items[0].object;
    try testing.expectEqualStrings("schema_too_new", row.get("error_kind").?.string);
}

test "bundle import --dry-run refuses a too-new DB like the real import" {
    // A preview that passes where the real run fails misleads `--dry-run && run`.
    var s = try Scratch.init(testing.allocator, "bundle_import_dry");
    defer s.deinit(testing.allocator);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/Maltfile.json", .{s.path});
    defer testing.allocator.free(path);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, path, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io,
            \\{"name": "dev", "version": 1, "formulas": []}
        );
    }

    const prior_dry = output.isDryRun();
    output.setDryRun(true);
    defer output.setDryRun(prior_dry);
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();

    const ctx = ctxWithSink();
    try testing.expectError(error.SchemaTooNew, bundle.execute(&ctx, testing.allocator, &.{ "import", path }));
    try expectNamesBothVersions(captured.items);
}
