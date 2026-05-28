//! `mt doctor` dependency bin/sbin-leak enumeration tests.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");

const doctor = malt.doctor;
const sqlite = malt.sqlite;
const schema = malt.schema;

fn uniquePrefix(suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        testing.allocator,
        "/tmp/malt_doctor_iso_{d}_{s}",
        .{ test_io.nanoTimestamp(std.Options.debug_io), suffix },
    );
}

// Seed: direct keg with bin links, isolated dep with no bin links, and
// a pre-feature dep keg with bin_isolated=0 + a bin link in `links`
// (the offender). The check must flag only the offender.
fn seedFixture(prefix: []const u8) !void {
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);
    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{prefix});
    defer testing.allocator.free(db_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);

    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, install_reason, bin_isolated)
        \\VALUES
        \\  ('direct_keg', 'direct_keg', '1.0', 'sha-d', '/c/direct_keg/1.0', 'direct',     0),
        \\  ('isolated',   'isolated',   '1.0', 'sha-i', '/c/isolated/1.0',   'dependency', 1),
        \\  ('leaker',     'leaker',     '1.0', 'sha-l', '/c/leaker/1.0',     'dependency', 0);
    );

    // direct_keg has bin link (expected, not flagged).
    try db.exec(
        \\INSERT INTO links (keg_id, link_path, target) VALUES
        \\  ((SELECT id FROM kegs WHERE name='direct_keg'),
        \\   '/p/bin/direct_keg', '/c/direct_keg/1.0/bin/direct_keg'),
        \\  ((SELECT id FROM kegs WHERE name='leaker'),
        \\   '/p/bin/leaker', '/c/leaker/1.0/bin/leaker');
    );
}

test "doctor isolation check flags only dep kegs with bin/sbin links and bin_isolated=0" {
    const prefix = try uniquePrefix("leaker");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try seedFixture(prefix);

    const ctx: doctor.CheckCtx = .{
        .allocator = testing.allocator,
        .prefix = prefix,
        .io = std.Options.debug_io,
        .environ = .empty,
        .mirrors = .{},
        .offline = false,
    };

    // Run the check directly so we don't depend on doctor's stdout-printing.
    const result = checkResult(ctx);
    try testing.expectEqual(doctor.CheckResult.warn_status, result);
}

// Clean prefix: no dep kegs leak. Check returns ok.
test "doctor isolation check returns ok when no dep keg leaks bin/sbin" {
    const prefix = try uniquePrefix("clean");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);
    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{prefix});
    defer testing.allocator.free(db_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);

    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, install_reason, bin_isolated)
        \\VALUES
        \\  ('direct_keg', 'direct_keg', '1.0', 'sha-d', '/c/direct_keg/1.0', 'direct',     0),
        \\  ('isolated',   'isolated',   '1.0', 'sha-i', '/c/isolated/1.0',   'dependency', 1);
    );
    try db.exec(
        \\INSERT INTO links (keg_id, link_path, target) VALUES
        \\  ((SELECT id FROM kegs WHERE name='direct_keg'),
        \\   '/p/bin/direct_keg', '/c/direct_keg/1.0/bin/direct_keg');
    );

    const ctx: doctor.CheckCtx = .{
        .allocator = testing.allocator,
        .prefix = prefix,
        .io = std.Options.debug_io,
        .environ = .empty,
        .mirrors = .{},
        .offline = false,
    };

    const result = checkResult(ctx);
    try testing.expectEqual(doctor.CheckResult.ok, result);
}

// The check table must include the new entry — guards against
// silently dropping it from the registered walk.
test "checks table includes the dependency bin/sbin leak check" {
    var found = false;
    for (doctor.checks) |c| {
        if (std.mem.eql(u8, c.name, "Dependency bin/sbin leaks")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

// Find the registered check function by name and invoke it.
fn checkResult(ctx: doctor.CheckCtx) doctor.CheckResult {
    for (doctor.checks) |c| {
        if (std.mem.eql(u8, c.name, "Dependency bin/sbin leaks")) {
            return c.run(ctx, c.name);
        }
    }
    @panic("isolation check not registered");
}
