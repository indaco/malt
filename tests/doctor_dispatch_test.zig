//! malt — `mt doctor` dispatch + walker integration tests.
//!
//! Drives `doctor.runChecks` with the production check table against a
//! scratch MALT_PREFIX so each individual `checkX` body lands on the
//! coverage map. `doctor.execute`'s exit-on-warn/err branches call
//! `std.process.exit` and cannot be exercised here, so the coverage
//! goal is the body of every check, not the dispatch tally.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const doctor = malt.doctor;
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
            "/tmp/malt_doctor_disp_{s}_{d}",
            .{ tag, ts },
            0,
        );
        test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
        try test_io.cwd().createDirPath(std.Options.debug_io, path);
        const subs = [_][]const u8{ "store", "Cellar", "Caskroom", "opt", "bin", "lib", "tmp", "cache", "db" };
        for (subs) |sd| {
            const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, sd });
            defer allocator.free(dir);
            try test_io.cwd().createDirPath(std.Options.debug_io, dir);
        }
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

// --- runChecks against the production table ----------------------------

test "runChecks walks the production check table on a clean prefix" {
    // The walker visits every check fn — the goal is coverage on each
    // body. Tally values aren't asserted: API-reachable depends on the
    // host network state and isn't deterministic in a test bench.
    var s = try Scratch.init(testing.allocator, "clean");
    defer s.deinit(testing.allocator);

    // Pre-init the DB so checkSqliteIntegrity hits the happy path.
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
    }

    quiet();
    defer unquiet();

    const tally = doctor.runChecks(.{
        .allocator = testing.allocator,
        .prefix = s.path,
        .io = std.Options.debug_io,
        .environ = .empty,
    }, &doctor.checks);

    // The walker must always produce a tally — the values themselves are
    // host-dependent (network, APFS, install_name_tool on PATH).
    _ = tally;
}

test "runChecks surfaces a warning when a directory is missing" {
    // Carve away one of the structure dirs so checkDirectoryStructure
    // takes the warn branch.
    var s = try Scratch.init(testing.allocator, "missing_dir");
    defer s.deinit(testing.allocator);

    const opt_path = try std.fmt.allocPrint(testing.allocator, "{s}/opt", .{s.path});
    defer testing.allocator.free(opt_path);
    test_io.deleteTreeAbsolute(std.Options.debug_io, opt_path) catch {};

    quiet();
    defer unquiet();

    const tally = doctor.runChecks(.{
        .allocator = testing.allocator,
        .prefix = s.path,
        .io = std.Options.debug_io,
        .environ = .empty,
    }, &doctor.checks);

    // Walker bumped at least one warning (the missing-dir).
    try testing.expect(tally.warnings >= 1);
}

test "runChecks surfaces an error when a keg row points at a missing Cellar dir" {
    var s = try Scratch.init(testing.allocator, "missing_keg");
    defer s.deinit(testing.allocator);

    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);

        // Cellar path that intentionally does not exist on disk.
        var stmt = try db.prepare(
            \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
            \\VALUES ('phantom', 'phantom', '9.9', 0, '', '/tmp/malt_phantom_does_not_exist');
        );
        defer stmt.finalize();
        _ = try stmt.step();
    }

    quiet();
    defer unquiet();

    const tally = doctor.runChecks(.{
        .allocator = testing.allocator,
        .prefix = s.path,
        .io = std.Options.debug_io,
        .environ = .empty,
    }, &doctor.checks);

    try testing.expect(tally.errors >= 1);
}

// --- execute pre-loop branches -----------------------------------------

test "execute --help short-circuits before opening anything" {
    var s = try Scratch.init(testing.allocator, "help");
    defer s.deinit(testing.allocator);
    quiet();
    defer unquiet();
    try doctor.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--help"});
}

test "execute --post-install-status returns without invoking the walker" {
    // No kegs → the loop body is skipped, but every line of the helper
    // up to the loop is exercised (db open, query prep, http init).
    var s = try Scratch.init(testing.allocator, "pi_status");
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

    try doctor.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--post-install-status"});
}

// --- pure helpers ------------------------------------------------------

test "externalToolAvailable returns false when PATH does not contain the tool" {
    quiet();
    defer unquiet();
    try testing.expect(!doctor.externalToolAvailable(
        std.Options.debug_io,
        .empty,
        "tool-name-that-cannot-possibly-exist-on-any-machine-xyz123",
    ));
}

test "countMissingLocalSources tallies missing source paths against tap='local' rows" {
    var s = try Scratch.init(testing.allocator, "local_sources");
    defer s.deinit(testing.allocator);

    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    // Two `local` kegs: one with a present source path, one with a
    // ghost path. Only the ghost should bump `stale`.
    const present = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/here.rb", .{s.path});
    defer testing.allocator.free(present);
    const f = try test_io.createFileAbsolute(std.Options.debug_io, present, .{ .truncate = true });
    f.close(std.Options.debug_io);

    {
        var stmt = try db.prepare(
            \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, tap)
            \\VALUES ('here', ?1, '1.0', 0, '', '/here', 'local');
        );
        defer stmt.finalize();
        try stmt.bindText(1, present);
        _ = try stmt.step();
    }
    {
        var stmt = try db.prepare(
            \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, tap)
            \\VALUES ('gone', '/tmp/malt_doctor_disp_ghost.rb', '1.0', 0, '', '/gone', 'local');
        );
        defer stmt.finalize();
        _ = try stmt.step();
    }

    const census = doctor.countMissingLocalSources(std.Options.debug_io, testing.allocator, &db);
    try testing.expectEqual(@as(u32, 2), census.total);
    try testing.expectEqual(@as(u32, 1), census.stale);
}
