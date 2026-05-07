//! malt — uninstall command integration tests.
//!
//! Drives `uninstall.execute` against a throwaway MALT_PREFIX so the
//! pre-flight branches (help, missing argv, lock acquire, "not installed")
//! and the happy-path teardown (kegs row + Cellar dir + opt link)
//! land on the coverage map without touching the real install root.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const uninstall = malt.cli_uninstall;
const sqlite = malt.sqlite;
const schema = malt.schema;
const output = malt.output;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

const ScratchPrefix = struct {
    path: [:0]u8,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !ScratchPrefix {
        const ts = test_io.nanoTimestamp(std.Options.debug_io);
        const path = try std.fmt.allocPrintSentinel(
            allocator,
            "/tmp/malt_uninstall_{s}_{d}",
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

    fn deinit(self: *ScratchPrefix, allocator: std.mem.Allocator) void {
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

// Insert a fully-formed kegs row plus an empty Cellar dir so the happy
// path has something to delete. `store_sha256` is left blank so the
// `decrementRef` branch short-circuits — that path is exercised
// separately by the store tests.
fn seedKeg(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8, version: []const u8) !void {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    const cellar_rel = try std.fmt.allocPrint(allocator, "Cellar/{s}/{s}", .{ name, version });
    defer allocator.free(cellar_rel);

    var stmt = try db.prepare(
        \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
        \\VALUES (?1, ?1, ?2, 0, '', ?3);
    );
    defer stmt.finalize();
    try stmt.bindText(1, name);
    try stmt.bindText(2, version);
    try stmt.bindText(3, cellar_rel);
    _ = try stmt.step();

    const cellar_dir = try std.fmt.allocPrint(allocator, "{s}/Cellar/{s}/{s}", .{ prefix, name, version });
    defer allocator.free(cellar_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, cellar_dir);
}

fn pathExists(path: []const u8) bool {
    test_io.accessAbsolute(std.Options.debug_io, path, .{}) catch return false;
    return true;
}

fn kegRowExists(prefix: []const u8, name: []const u8) !bool {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    var stmt = try db.prepare("SELECT 1 FROM kegs WHERE name = ?1;");
    defer stmt.finalize();
    try stmt.bindText(1, name);
    return stmt.step() catch false;
}

// Seed a keg whose store_sha256 is populated and a matching store_refs row.
// Lets the test inspect the post-uninstall refcount, which seedKeg above
// deliberately sidesteps by leaving sha empty.
fn seedKegWithStoreRef(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    name: []const u8,
    version: []const u8,
    sha256: []const u8,
    refcount: i64,
) !void {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    const cellar_rel = try std.fmt.allocPrint(allocator, "Cellar/{s}/{s}", .{ name, version });
    defer allocator.free(cellar_rel);

    var ins_keg = try db.prepare(
        \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
        \\VALUES (?1, ?1, ?2, 0, ?3, ?4);
    );
    defer ins_keg.finalize();
    try ins_keg.bindText(1, name);
    try ins_keg.bindText(2, version);
    try ins_keg.bindText(3, sha256);
    try ins_keg.bindText(4, cellar_rel);
    _ = try ins_keg.step();

    var ins_ref = try db.prepare("INSERT INTO store_refs (store_sha256, refcount) VALUES (?1, ?2);");
    defer ins_ref.finalize();
    try ins_ref.bindText(1, sha256);
    try ins_ref.bindInt(2, refcount);
    _ = try ins_ref.step();

    const cellar_dir = try std.fmt.allocPrint(allocator, "{s}/Cellar/{s}/{s}", .{ prefix, name, version });
    defer allocator.free(cellar_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, cellar_dir);
}

fn refcountFor(prefix: []const u8, sha256: []const u8) !?i64 {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    var stmt = try db.prepare("SELECT refcount FROM store_refs WHERE store_sha256 = ?1;");
    defer stmt.finalize();
    try stmt.bindText(1, sha256);
    if (!try stmt.step()) return null;
    return stmt.columnInt(0);
}

// --- early-return branches ----------------------------------------------

test "execute --help short-circuits before opening the database" {
    var prefix = try ScratchPrefix.init(testing.allocator, "help");
    defer prefix.deinit(testing.allocator);

    quiet();
    defer unquiet();

    // No DB exists, no lock — if --help opened either, we'd get an error.
    try uninstall.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--help"});
    try uninstall.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"-h"});
}

test "execute with no positional args returns Aborted" {
    var prefix = try ScratchPrefix.init(testing.allocator, "noargs");
    defer prefix.deinit(testing.allocator);

    quiet();
    defer unquiet();

    try testing.expectError(
        error.Aborted,
        uninstall.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{}),
    );
}

test "execute on a non-installed package returns Aborted" {
    var prefix = try ScratchPrefix.init(testing.allocator, "missing");
    defer prefix.deinit(testing.allocator);

    // Initialize an empty schema so the open succeeds and the lookup
    // takes the "not installed" branch (rather than the open-failure one).
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
    }

    quiet();
    defer unquiet();

    try testing.expectError(
        error.Aborted,
        uninstall.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"ghost-package"}),
    );
}

test "execute -q flag is accepted alongside the package argument" {
    // Order independence: the argv loop must not require -q to be first.
    var prefix = try ScratchPrefix.init(testing.allocator, "qflag");
    defer prefix.deinit(testing.allocator);

    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
    }

    defer unquiet();

    try testing.expectError(
        error.Aborted,
        uninstall.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "ghost", "-q" }),
    );
}

// --- happy-path teardown ------------------------------------------------

test "execute removes the kegs row and the Cellar directory" {
    var prefix = try ScratchPrefix.init(testing.allocator, "happy");
    defer prefix.deinit(testing.allocator);

    try seedKeg(testing.allocator, prefix.path, "foo", "1.0");

    quiet();
    defer unquiet();

    try uninstall.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"foo"});

    try testing.expect(!try kegRowExists(prefix.path, "foo"));

    const cellar_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/foo/1.0", .{prefix.path});
    defer testing.allocator.free(cellar_dir);
    try testing.expect(!pathExists(cellar_dir));
}

test "execute --force bypasses the dependents check" {
    // Seed a second keg that depends on `foo` so the unforced run would
    // refuse. With --force the row goes away regardless.
    var prefix = try ScratchPrefix.init(testing.allocator, "force");
    defer prefix.deinit(testing.allocator);

    try seedKeg(testing.allocator, prefix.path, "foo", "1.0");

    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();

        var ins = try db.prepare(
            \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
            \\VALUES ('bar', 'bar', '2.0', 0, '', 'Cellar/bar/2.0');
        );
        defer ins.finalize();
        _ = try ins.step();

        var dep = try db.prepare(
            \\INSERT INTO dependencies (keg_id, dep_name)
            \\SELECT id, 'foo' FROM kegs WHERE name = 'bar';
        );
        defer dep.finalize();
        _ = try dep.step();
    }

    quiet();
    defer unquiet();

    // Without --force the dependent should block the removal.
    try testing.expectError(
        error.Aborted,
        uninstall.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"foo"}),
    );
    try testing.expect(try kegRowExists(prefix.path, "foo"));

    // --force breaks through the guard.
    try uninstall.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "--force", "foo" });
    try testing.expect(!try kegRowExists(prefix.path, "foo"));
}

test "execute drops the kegs row and decrements the store ref together" {
    // Pre-fix the FS teardown ran before the ref decrement, so a SIGKILL
    // mid-uninstall could leave the store row inflated above the on-disk
    // state. Asserting both writes land guards the bundled-transaction shape.
    var prefix = try ScratchPrefix.init(testing.allocator, "storeref");
    defer prefix.deinit(testing.allocator);

    const sha = "abc123";
    try seedKegWithStoreRef(testing.allocator, prefix.path, "foo", "1.0", sha, 2);

    quiet();
    defer unquiet();

    try uninstall.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"foo"});

    try testing.expect(!try kegRowExists(prefix.path, "foo"));
    try testing.expectEqual(@as(?i64, 1), try refcountFor(prefix.path, sha));
}
