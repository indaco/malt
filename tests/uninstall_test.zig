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
const cask = malt.cask;

const c = test_io.c;

const ScratchPrefix = struct {
    path: [:0]u8,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !ScratchPrefix {
        const base = try test_io.uniqueTempPath(allocator, "uninstall", tag);
        defer allocator.free(base);
        const path = try std.fmt.allocPrintSentinel(allocator, "{s}", .{base}, 0);
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
// path has something to delete. `store_sha256` is left blank: the store
// claim is exercised separately by the store tests.
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
// Lets the test inspect the post-uninstall claim, which seedKeg above
// deliberately sidesteps by leaving sha empty.
fn seedKegWithStoreRef(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    name: []const u8,
    version: []const u8,
    sha256: []const u8,
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

    var ins_ref = try db.prepare("INSERT INTO store_refs (store_sha256) VALUES (?1);");
    defer ins_ref.finalize();
    try ins_ref.bindText(1, sha256);
    _ = try ins_ref.step();

    const cellar_dir = try std.fmt.allocPrint(allocator, "{s}/Cellar/{s}/{s}", .{ prefix, name, version });
    defer allocator.free(cellar_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, cellar_dir);
}

fn storeRefExists(prefix: []const u8, sha256: []const u8) !bool {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    var stmt = try db.prepare("SELECT 1 FROM store_refs WHERE store_sha256 = ?1;");
    defer stmt.finalize();
    try stmt.bindText(1, sha256);
    return try stmt.step();
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

// A BEFORE DELETE trigger on `casks` makes `removeRecord` fail with
// SQLITE_CONSTRAINT after the app teardown has already succeeded. The
// previous catch{} treated this as a clean uninstall; the CLI catch
// must now surface the SQLite error name AND `db.errMsg()` so the user
// has something to act on instead of "looks fine, row still there".
test "execute on a cask surfaces removeRecord SqliteError with db.errMsg in the log" {
    var prefix = try ScratchPrefix.init(testing.allocator, "cask_errmsg");
    defer prefix.deinit(testing.allocator);

    const token = "firefox";

    // Stage a cask row + a BEFORE DELETE trigger that aborts the row's
    // removal. `RAISE(ABORT, 'cask-row-pinned-by-test-trigger')` sets the
    // SQLite error message verbatim — that's what we expect in the log.
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);

        const cask_json =
            \\{"token":"firefox","name":["Firefox"],"version":"123.0","desc":"","homepage":"",
            \\ "url":"https://example.com/firefox.dmg",
            \\ "sha256":"00000000000000000000000000000000000000000000000000000000deadbeef",
            \\ "auto_updates":false,"artifacts":[{"app":["Firefox.app"]}]}
        ;
        var parsed = try cask.parseCask(testing.allocator, cask_json);
        defer parsed.deinit();

        const app_path = try std.fmt.allocPrint(testing.allocator, "{s}/Firefox.app", .{prefix.path});
        defer testing.allocator.free(app_path);
        try cask.recordInstall(&db, &parsed, app_path, null);

        try db.exec(
            \\CREATE TRIGGER block_cask_delete BEFORE DELETE ON casks
            \\BEGIN SELECT RAISE(ABORT, 'cask-row-pinned-by-test-trigger'); END;
        );
    }

    // Stage the app directory so the `isAppRunning` and `deleteTree`
    // steps inside uninstall reach the DB step where the trigger fires.
    const app_path_z = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "{s}/Firefox.app",
        .{prefix.path},
        0,
    );
    defer testing.allocator.free(app_path_z);
    try test_io.makeDirAbsolute(std.Options.debug_io, app_path_z);

    const prior_quiet = output.isQuiet();
    output.setQuiet(false);
    defer output.setQuiet(prior_quiet);

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();

    try testing.expectError(
        error.Aborted,
        uninstall.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{token}),
    );

    try testing.expect(std.mem.indexOf(u8, captured.items, "cask-row-pinned-by-test-trigger") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "ConstraintViolation") != null);
}

test "execute drops the kegs row and leaves the store claim for the orphan sweep" {
    // Deleting the keg row is what releases the bytes; the `store_refs` row
    // is how `purge --store-orphans` finds them afterwards, so it must stay.
    var prefix = try ScratchPrefix.init(testing.allocator, "storeref");
    defer prefix.deinit(testing.allocator);

    const sha = "abc123";
    try seedKegWithStoreRef(testing.allocator, prefix.path, "foo", "1.0", sha);

    quiet();
    defer unquiet();

    try uninstall.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"foo"});

    try testing.expect(!try kegRowExists(prefix.path, "foo"));
    try testing.expect(try storeRefExists(prefix.path, sha));
}

test "execute clears a symlinked package dir instead of deleting through it" {
    // The DB row goes away either way, so leaving the link in place would
    // strand an un-removable Cellar entry. Unlinking it destroys no user data.
    var prefix = try ScratchPrefix.init(testing.allocator, "pkg_link");
    defer prefix.deinit(testing.allocator);

    try seedKeg(testing.allocator, prefix.path, "foo", "1.0");

    const victim = try std.fmt.allocPrint(testing.allocator, "{s}-victim", .{prefix.path});
    defer testing.allocator.free(victim);
    test_io.deleteTreeAbsolute(std.Options.debug_io, victim) catch {};
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, victim) catch {};

    const canary = try std.fmt.allocPrint(testing.allocator, "{s}/1.0/SENTINEL", .{victim});
    defer testing.allocator.free(canary);
    {
        const dir = try std.fmt.allocPrint(testing.allocator, "{s}/1.0", .{victim});
        defer testing.allocator.free(dir);
        try test_io.cwd().createDirPath(std.Options.debug_io, dir);
        (try test_io.createFileAbsolute(std.Options.debug_io, canary, .{})).close(std.Options.debug_io);
    }

    // Swap the seeded package dir for a link pointing outside the prefix.
    const pkg_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/foo", .{prefix.path});
    defer testing.allocator.free(pkg_dir);
    try test_io.deleteTreeAbsolute(std.Options.debug_io, pkg_dir);
    try test_io.symLinkAbsolute(std.Options.debug_io, victim, pkg_dir, .{ .is_directory = true });

    quiet();
    defer unquiet();

    try uninstall.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"foo"});

    try testing.expect(!try kegRowExists(prefix.path, "foo"));
    try testing.expect(pathExists(canary));
    // `accessAbsolute` follows links, so stat the entry itself to prove the
    // link is gone rather than merely dangling.
    try testing.expectError(
        error.FileNotFound,
        test_io.cwd().statFile(std.Options.debug_io, pkg_dir, .{ .follow_symlinks = false }),
    );
}

test "execute keeps a symlinked package dir while another version is recorded" {
    // A link cannot be half-removed: dropping it would cut the surviving
    // version off from the prefix even though its row and files are intact.
    var prefix = try ScratchPrefix.init(testing.allocator, "pkg_link_sibling");
    defer prefix.deinit(testing.allocator);

    try seedKeg(testing.allocator, prefix.path, "foo", "1.0");
    try seedKeg(testing.allocator, prefix.path, "foo", "2.0");

    const victim = try std.fmt.allocPrint(testing.allocator, "{s}-victim", .{prefix.path});
    defer testing.allocator.free(victim);
    test_io.deleteTreeAbsolute(std.Options.debug_io, victim) catch {};
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, victim) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, victim);

    const pkg_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/foo", .{prefix.path});
    defer testing.allocator.free(pkg_dir);
    try test_io.deleteTreeAbsolute(std.Options.debug_io, pkg_dir);
    try test_io.symLinkAbsolute(std.Options.debug_io, victim, pkg_dir, .{ .is_directory = true });

    quiet();
    defer unquiet();

    try uninstall.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"foo"});

    // 2.0's row survives, so the path it is reached through must too.
    const st = try test_io.cwd().statFile(std.Options.debug_io, pkg_dir, .{ .follow_symlinks = false });
    try testing.expectEqual(std.Io.File.Kind.sym_link, st.kind);
}

// ─── outdated snapshot reconcile ─────────────────────────────────────

const snapshot_seed =
    \\{"version":2,"generated_at_ms":1700000000000,"formulas":[{"name":"foo","installed":"1.0","latest":"2.0"},{"name":"bar","installed":"3.0","latest":"3.1"}],"casks":[{"name":"foo","installed":"1","latest":"2"},{"name":"firefox","installed":"123.0","latest":"124.0"}]}
;

fn seedSnapshot(prefix: []const u8) !void {
    const io = std.Options.debug_io;
    var dir_buf: [512]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}/cache", .{prefix});
    try test_io.cwd().createDirPath(io, dir);
    var path_buf: [600]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/outdated.json", .{dir});
    const f = try test_io.createFileAbsolute(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, snapshot_seed);
}

fn readSnapshot(prefix: []const u8) !malt.cli_outdated.OwnedSnapshot {
    var dir_buf: [512]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}/cache", .{prefix});
    return malt.cli_outdated.readSnapshot(std.Options.debug_io, testing.allocator, dir) orelse error.SnapshotMissing;
}

fn readSnapshotRaw(prefix: []const u8) ![]u8 {
    var path_buf: [600]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/cache/outdated.json", .{prefix});
    return test_io.readFileAbsoluteAlloc(std.Options.debug_io, testing.allocator, path, 4096);
}

test "execute drops the uninstalled keg from the outdated snapshot and nothing else" {
    // The TUI paints the raw file, so a removed keg left in it stays on the
    // Outdated tab until the lease lapses; deleting the whole file instead
    // would cost every other keg its audit.
    var prefix = try ScratchPrefix.init(testing.allocator, "snapshot_keg");
    defer prefix.deinit(testing.allocator);
    try seedKeg(testing.allocator, prefix.path, "foo", "1.0");
    try seedSnapshot(prefix.path);

    quiet();
    defer unquiet();
    try uninstall.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"foo"});

    const snap = try readSnapshot(prefix.path);
    defer malt.cli_outdated.freeSnapshot(testing.allocator, snap);
    try testing.expectEqual(@as(i64, 1_700_000_000_000), snap.generated_at_ms);
    try testing.expectEqual(@as(usize, 1), snap.formulas.len);
    try testing.expectEqualStrings("bar", snap.formulas[0].name);
    // The cask that shares the token is a different package.
    try testing.expectEqual(@as(usize, 2), snap.casks.len);
    try testing.expectEqualStrings("foo", snap.casks[0].name);
}

test "execute on a cask drops it from the snapshot's casks only" {
    var prefix = try ScratchPrefix.init(testing.allocator, "snapshot_cask");
    defer prefix.deinit(testing.allocator);
    const token = "firefox";
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
        const cask_json =
            \\{"token":"firefox","name":["Firefox"],"version":"123.0","desc":"","homepage":"",
            \\ "url":"https://example.com/firefox.dmg",
            \\ "sha256":"00000000000000000000000000000000000000000000000000000000deadbeef",
            \\ "auto_updates":false,"artifacts":[{"app":["Firefox.app"]}]}
        ;
        var parsed = try cask.parseCask(testing.allocator, cask_json);
        defer parsed.deinit();
        const app_path = try std.fmt.allocPrint(testing.allocator, "{s}/Firefox.app", .{prefix.path});
        defer testing.allocator.free(app_path);
        try cask.recordInstall(&db, &parsed, app_path, null);
    }
    const app_path_z = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/Firefox.app", .{prefix.path}, 0);
    defer testing.allocator.free(app_path_z);
    try test_io.makeDirAbsolute(std.Options.debug_io, app_path_z);
    try seedSnapshot(prefix.path);

    quiet();
    defer unquiet();
    try uninstall.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{token});

    const snap = try readSnapshot(prefix.path);
    defer malt.cli_outdated.freeSnapshot(testing.allocator, snap);
    try testing.expectEqual(@as(usize, 2), snap.formulas.len);
    try testing.expectEqual(@as(usize, 1), snap.casks.len);
    try testing.expectEqualStrings("foo", snap.casks[0].name);
}

test "an aborted uninstall leaves the outdated snapshot byte-identical" {
    // Nothing moved, so the audit is still true; rewriting it would only
    // risk the file for no gain.
    var prefix = try ScratchPrefix.init(testing.allocator, "snapshot_abort");
    defer prefix.deinit(testing.allocator);
    try seedSnapshot(prefix.path);

    quiet();
    defer unquiet();
    try testing.expectError(error.Aborted, uninstall.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"foo"}));

    const after = try readSnapshotRaw(prefix.path);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(snapshot_seed, after);
}

// ─── DB failures fail loud ───────────────────────────────────────────
// A DB error must abort before anything is torn down: exit 0 with nothing
// removed lies to scripts and the TUI, and a keg removed after a failed
// query or delete leaves the DB and the Cellar disagreeing.

fn sabotage(prefix: []const u8, sql: [:0]const u8) !void {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try db.exec(sql);
}

fn expectKegIntact(prefix: []const u8, name: []const u8, version: []const u8) !void {
    try testing.expect(try kegRowExists(prefix, name));
    const cellar_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/{s}/{s}", .{ prefix, name, version });
    defer testing.allocator.free(cellar_dir);
    try testing.expect(pathExists(cellar_dir));
}

// Links `{prefix}/bin/<name>` into its Cellar dir and records the row, as
// `mt link` would. Caller frees the returned path.
fn seedLink(prefix: []const u8, name: []const u8, version: []const u8) ![]u8 {
    const io = std.Options.debug_io;
    const bin_dir = try std.fmt.allocPrint(testing.allocator, "{s}/bin", .{prefix});
    defer testing.allocator.free(bin_dir);
    try test_io.cwd().createDirPath(io, bin_dir);
    const target = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/{s}/{s}", .{ prefix, name, version });
    defer testing.allocator.free(target);
    const link = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ bin_dir, name });
    errdefer testing.allocator.free(link);
    try test_io.symLinkAbsolute(io, target, link, .{});

    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    var stmt = try db.prepare("INSERT INTO links (keg_id, link_path, target) SELECT id, ?2, ?3 FROM kegs WHERE name = ?1;");
    defer stmt.finalize();
    try stmt.bindText(1, name);
    try stmt.bindText(2, link);
    try stmt.bindText(3, target);
    _ = try stmt.step();
    return link;
}

fn isSymlink(path: []const u8) bool {
    const st = test_io.cwd().statFile(std.Options.debug_io, path, .{ .follow_symlinks = false }) catch return false;
    return st.kind == .sym_link;
}

// Runs `uninstall <argv>`, expects Aborted, and captures stderr into `captured`.
fn expectAbortCaptured(captured: *std.ArrayList(u8), argv: []const []const u8) !void {
    const prior_quiet = output.isQuiet();
    output.setQuiet(false);
    defer output.setQuiet(prior_quiet);
    output.beginStderrCapture(testing.allocator, captured);
    defer output.endStderrCapture();
    try testing.expectError(error.Aborted, uninstall.execute(&malt.app_ctx.debug_ctx, testing.allocator, argv));
}

// Seeds `bar` depending on `foo`, behind a view that errors at step time
// only once a matching row is read, so prepare and bind still succeed.
fn seedErroringDependents(prefix: []const u8) !void {
    try sabotage(prefix,
        \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
        \\VALUES ('bar', 'bar', '2.0', 0, '', 'Cellar/bar/2.0');
        \\INSERT INTO dependencies (keg_id, dep_name) SELECT id, 'foo' FROM kegs WHERE name = 'bar';
        \\PRAGMA foreign_keys=OFF;
        \\ALTER TABLE dependencies RENAME TO deps_real;
        \\CREATE VIEW dependencies AS SELECT keg_id, dep_name, dep_type FROM deps_real
        \\  WHERE abs(-9223372036854775807 - 1) > 0;
    );
}

test "execute aborts and keeps the keg when the lookup query cannot be prepared" {
    var prefix = try ScratchPrefix.init(testing.allocator, "db_prepare");
    defer prefix.deinit(testing.allocator);
    try seedKeg(testing.allocator, prefix.path, "foo", "1.0");
    try sabotage(prefix.path, "ALTER TABLE kegs RENAME COLUMN revision TO rev;");

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    try expectAbortCaptured(&captured, &.{"foo"});

    try expectKegIntact(prefix.path, "foo", "1.0");
    // The cause, not a misleading "not installed".
    try testing.expect(std.mem.indexOf(u8, captured.items, "revision") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "not installed") == null);
}

test "execute reports an unreadable lookup instead of calling the package not installed" {
    var prefix = try ScratchPrefix.init(testing.allocator, "db_lookup_step");
    defer prefix.deinit(testing.allocator);
    try seedKeg(testing.allocator, prefix.path, "foo", "1.0");

    // Corrupt every index on `kegs`: prepare and initSchema still pass, and
    // the lookup's step fails whichever index the planner picks, the way a
    // real disk or lock error would.
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix.path}, 0);
    var offsets: [8]u64 = undefined;
    var n: usize = 0;
    {
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        var stmt = try db.prepare(
            \\SELECT (rootpage - 1) * (SELECT page_size FROM pragma_page_size)
            \\FROM sqlite_master WHERE type = 'index' AND tbl_name = 'kegs';
        );
        defer stmt.finalize();
        while (try stmt.step()) : (n += 1) offsets[n] = @intCast(stmt.columnInt(0));
    }
    try testing.expect(n > 0);
    {
        const io = std.Options.debug_io;
        const f = try test_io.openFileAbsolute(io, db_path, .{ .mode = .read_write });
        defer f.close(io);
        for (offsets[0..n]) |off| try f.writePositionalAll(io, "\x0d\xff\xff\xff\xff\xff\xff\xff", off);
    }

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    try expectAbortCaptured(&captured, &.{"foo"});

    try testing.expect(std.mem.indexOf(u8, captured.items, "not installed") == null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "malformed") != null);
    const cellar_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/foo/1.0", .{prefix.path});
    defer testing.allocator.free(cellar_dir);
    try testing.expect(pathExists(cellar_dir));
}

test "execute refuses when the dependents query cannot be prepared" {
    var prefix = try ScratchPrefix.init(testing.allocator, "db_depgate_prepare");
    defer prefix.deinit(testing.allocator);
    try seedKeg(testing.allocator, prefix.path, "foo", "1.0");
    try sabotage(prefix.path, "ALTER TABLE dependencies RENAME COLUMN dep_name TO dn;");

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    try expectAbortCaptured(&captured, &.{"foo"});

    try expectKegIntact(prefix.path, "foo", "1.0");
    try testing.expect(std.mem.indexOf(u8, captured.items, "--force") != null);
}

test "execute refuses to remove a package whose dependents cannot be checked" {
    var prefix = try ScratchPrefix.init(testing.allocator, "db_depgate");
    defer prefix.deinit(testing.allocator);
    try seedKeg(testing.allocator, prefix.path, "foo", "1.0");
    try seedErroringDependents(prefix.path);

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    try expectAbortCaptured(&captured, &.{"foo"});

    try expectKegIntact(prefix.path, "foo", "1.0");
    // The only way past an unreadable gate is the explicit override.
    try testing.expect(std.mem.indexOf(u8, captured.items, "--force") != null);
}

test "execute --force still removes a package whose dependents cannot be checked" {
    var prefix = try ScratchPrefix.init(testing.allocator, "db_depgate_force");
    defer prefix.deinit(testing.allocator);
    try seedKeg(testing.allocator, prefix.path, "foo", "1.0");
    try seedErroringDependents(prefix.path);

    quiet();
    defer unquiet();
    try uninstall.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "--force", "foo" });

    try testing.expect(!try kegRowExists(prefix.path, "foo"));
    const cellar_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/foo/1.0", .{prefix.path});
    defer testing.allocator.free(cellar_dir);
    try testing.expect(!pathExists(cellar_dir));
}

test "execute keeps the Cellar entry when the keg row cannot be deleted" {
    var prefix = try ScratchPrefix.init(testing.allocator, "db_finalize");
    defer prefix.deinit(testing.allocator);
    try seedKeg(testing.allocator, prefix.path, "foo", "1.0");
    const link = try seedLink(prefix.path, "foo", "1.0");
    defer testing.allocator.free(link);
    try sabotage(prefix.path,
        \\CREATE TRIGGER block_keg_delete BEFORE DELETE ON kegs
        \\BEGIN SELECT RAISE(ABORT, 'keg-row-pinned-by-test-trigger'); END;
    );

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    // Under -q too: the recovery hint is part of the error, not chatter.
    try expectAbortCaptured(&captured, &.{ "-q", "foo" });

    try expectKegIntact(prefix.path, "foo", "1.0");
    try testing.expect(std.mem.indexOf(u8, captured.items, "keg-row-pinned-by-test-trigger") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "uninstalled") == null);
    // Links go before the row delete, so the message must say how to get
    // them back rather than claim nothing was touched.
    try testing.expect(!isSymlink(link));
    try testing.expect(std.mem.indexOf(u8, captured.items, "mt link foo") != null);
}

test "execute aborts and keeps the links when their rows cannot be read" {
    var prefix = try ScratchPrefix.init(testing.allocator, "db_unlink");
    defer prefix.deinit(testing.allocator);
    try seedKeg(testing.allocator, prefix.path, "foo", "1.0");
    const link = try seedLink(prefix.path, "foo", "1.0");
    defer testing.allocator.free(link);
    try sabotage(prefix.path, "ALTER TABLE links RENAME COLUMN link_path TO lp;");

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    try expectAbortCaptured(&captured, &.{"foo"});

    // Going on would CASCADE the rows away and strand an untracked symlink.
    try expectKegIntact(prefix.path, "foo", "1.0");
    try testing.expect(isSymlink(link));
    try testing.expect(std.mem.indexOf(u8, captured.items, "link_path") != null);
}

test "execute under a near-limit prefix fails loud instead of exiting 0" {
    // 505 is a legal prefix whose `/db/malt.lock` path once overflowed a
    // 512-byte buffer. One component caps at 255, hence nested segments.
    const io = std.Options.debug_io;
    const base = try test_io.uniqueTempPath(testing.allocator, "uninstall", "long_prefix");
    defer testing.allocator.free(base);
    test_io.deleteTreeAbsolute(io, base) catch {};
    defer test_io.deleteTreeAbsolute(io, base) catch {};

    var buf: [505]u8 = undefined;
    @memcpy(buf[0..base.len], base);
    var i = base.len;
    while (i < buf.len) : (i += 1) buf[i] = if ((i - base.len) % 100 == 0) '/' else 'a';
    const long = try testing.allocator.dupeZ(u8, &buf);
    defer testing.allocator.free(long);

    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{long});
    defer testing.allocator.free(db_dir);
    try test_io.cwd().createDirPath(io, db_dir);
    _ = c.setenv("MALT_PREFIX", long.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    try expectAbortCaptured(&captured, &.{"foo"});
    try testing.expect(captured.items.len > 0);
    // Proves the prefix was accepted and the lock taken, not rejected early.
    const lock_path = try std.fmt.allocPrint(testing.allocator, "{s}/db/malt.lock", .{long});
    defer testing.allocator.free(lock_path);
    try testing.expect(pathExists(lock_path));
}
