//! malt — `mt bundle` dispatch + simple subcommand tests.
//!
//! Existing bundle_test.zig / bundle_brewfile_test.zig / bundle_cleanup_test.zig
//! cover the core/bundle/* modules. This file pins the cli/bundle.zig
//! dispatch — help, unknown subcommand, and the database-only paths
//! (`list`, `remove`, `import` early-args). Subcommands that need to
//! resolve a Brewfile via cwd or shell out to install/uninstall stay
//! out of this surface.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const bundle = malt.cli_bundle;
const sqlite = malt.sqlite;
const schema = malt.schema;
const output = malt.output;

const c = test_io.c;

const Scratch = struct {
    path: [:0]u8,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !Scratch {
        const base = try test_io.uniqueTempPath(allocator, "bundle_cli", tag);
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

/// A refusal exits 1 quietly through `error.Aborted`, so the reason has to
/// be on stderr in words; a raw error name reads as a malt crash.
fn expectRefused(ctx: *const malt.app_ctx.AppCtx, args: []const []const u8, needle: []const u8) !void {
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();
    try testing.expectError(error.Aborted, bundle.execute(ctx, testing.allocator, args));
    if (std.mem.indexOf(u8, captured.items, needle) == null) {
        std.debug.print("stderr lacks \"{s}\":\n{s}\n", .{ needle, captured.items });
        return error.TestExpectedEqual;
    }
}

fn quiet() void {
    output.setQuiet(true);
}
fn unquiet() void {
    output.setQuiet(false);
}

fn initDb(prefix: []const u8) !void {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);
}

// --- dispatch ----------------------------------------------------------

test "execute with no args prints help" {
    var s = try Scratch.init(testing.allocator, "noargs");
    defer s.deinit(testing.allocator);
    quiet();
    defer unquiet();
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{});
}

test "execute --help prints help" {
    var s = try Scratch.init(testing.allocator, "help");
    defer s.deinit(testing.allocator);
    quiet();
    defer unquiet();
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--help"});
}

test "execute -h is the short alias for --help" {
    var s = try Scratch.init(testing.allocator, "h_short");
    defer s.deinit(testing.allocator);
    quiet();
    defer unquiet();
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"-h"});
}

test "execute on an unknown subcommand refuses it by name" {
    var s = try Scratch.init(testing.allocator, "unknown");
    defer s.deinit(testing.allocator);
    try expectRefused(&malt.app_ctx.debug_ctx, &.{"frobnicate"}, "Unknown bundle subcommand: frobnicate");
}

// --- list ---------------------------------------------------------------

test "list on an empty bundles table prints \"no bundles\"" {
    var s = try Scratch.init(testing.allocator, "list_empty");
    defer s.deinit(testing.allocator);
    try initDb(s.path);

    quiet();
    defer unquiet();
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"list"});
}

test "list emits a row per registered bundle" {
    var s = try Scratch.init(testing.allocator, "list_rows");
    defer s.deinit(testing.allocator);
    try initDb(s.path);
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        var stmt = try db.prepare(
            \\INSERT INTO bundles (name, manifest_path, created_at, version)
            \\VALUES ('devtools', '/tmp/dev/Brewfile', 1700000000, 1);
        );
        defer stmt.finalize();
        _ = try stmt.step();
    }

    quiet();
    defer unquiet();
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"list"});
}

// --- remove -------------------------------------------------------------

test "remove with no name says what it expected" {
    var s = try Scratch.init(testing.allocator, "remove_noargs");
    defer s.deinit(testing.allocator);
    try initDb(s.path);
    try expectRefused(&malt.app_ctx.debug_ctx, &.{"remove"}, "expected <name>");
}

test "remove deletes the matching row, idempotent on second call" {
    var s = try Scratch.init(testing.allocator, "remove_ok");
    defer s.deinit(testing.allocator);
    try initDb(s.path);
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        var stmt = try db.prepare(
            \\INSERT INTO bundles (name, manifest_path, created_at, version)
            \\VALUES ('devtools', '/tmp/dev/Brewfile', 1700000000, 1);
        );
        defer stmt.finalize();
        _ = try stmt.step();
    }

    quiet();
    defer unquiet();
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "remove", "devtools" });
    // DELETE is no-op against a now-empty row → still success on rerun.
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "remove", "devtools" });
}

// --- import ------------------------------------------------------------

test "import with no path says what it expected" {
    var s = try Scratch.init(testing.allocator, "import_noargs");
    defer s.deinit(testing.allocator);
    try initDb(s.path);
    try expectRefused(&malt.app_ctx.debug_ctx, &.{"import"}, "expected <file>");
}

test "import on a missing path names the file it could not read" {
    var s = try Scratch.init(testing.allocator, "import_missing");
    defer s.deinit(testing.allocator);
    try initDb(s.path);

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();
    try testing.expectError(
        error.Aborted,
        bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "import", "/tmp/malt_bundle_cli_does_not_exist_xyz.json" }),
    );
    try testing.expect(std.mem.indexOf(u8, captured.items, "Cannot read bundle file /tmp/malt_bundle_cli_does_not_exist_xyz.json") != null);
}

test "import registers a Maltfile.json by reading the manifest name" {
    var s = try Scratch.init(testing.allocator, "import_ok");
    defer s.deinit(testing.allocator);
    try initDb(s.path);

    const path = try std.fmt.allocPrint(testing.allocator, "{s}/Maltfile.json", .{s.path});
    defer testing.allocator.free(path);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, path, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io,
            \\{"name": "imported", "version": 1, "formulas": [{"name": "wget"}]}
        );
    }

    quiet();
    defer unquiet();
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "import", path });

    // Confirm the row was inserted.
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    var stmt = try db.prepare("SELECT 1 FROM bundles WHERE name = 'imported';");
    defer stmt.finalize();
    try testing.expect(stmt.step() catch false);
}

// --- install --dry-run / cleanup --dry-run ----------------------------

test "install --dry-run on an empty Brewfile is a clean no-op" {
    var s = try Scratch.init(testing.allocator, "install_dry");
    defer s.deinit(testing.allocator);
    try initDb(s.path);

    const brewfile = try std.fmt.allocPrint(testing.allocator, "{s}/Brewfile", .{s.path});
    defer testing.allocator.free(brewfile);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, brewfile, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "# empty bundle\n");
    }

    const prior_dry = output.isDryRun();
    output.setDryRun(true);
    quiet();
    defer {
        output.setDryRun(prior_dry);
        unquiet();
    }

    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "install", brewfile });
}

test "cleanup --dry-run on a Brewfile that matches no installed packages prints the plan only" {
    var s = try Scratch.init(testing.allocator, "cleanup_dry");
    defer s.deinit(testing.allocator);
    try initDb(s.path);

    const brewfile = try std.fmt.allocPrint(testing.allocator, "{s}/Brewfile", .{s.path});
    defer testing.allocator.free(brewfile);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, brewfile, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "brew \"wget\"\n");
    }

    const prior_dry = output.isDryRun();
    output.setDryRun(true);
    quiet();
    defer {
        output.setDryRun(prior_dry);
        unquiet();
    }

    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "cleanup", "--dry-run", "--yes", brewfile });
}

test "import on a malformed Maltfile.json says why it could not parse it" {
    var s = try Scratch.init(testing.allocator, "import_bad");
    defer s.deinit(testing.allocator);
    try initDb(s.path);

    const path = try std.fmt.allocPrint(testing.allocator, "{s}/Maltfile.json", .{s.path});
    defer testing.allocator.free(path);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, path, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "this is not json");
    }

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();
    try testing.expectError(
        error.Aborted,
        bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "import", path }),
    );
    try testing.expect(std.mem.indexOf(u8, captured.items, "malformed bundle JSON") != null);
}

// --- install: an unreadable bundle file is named, not a bare error -----

fn expectInstallRefusal(path: []const u8, needle: []const u8) !void {
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();
    try testing.expectError(
        error.Aborted,
        bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "install", path }),
    );
    try testing.expect(std.mem.indexOf(u8, captured.items, needle) != null);
}

test "install on a missing bundle file says it cannot read it" {
    var s = try Scratch.init(testing.allocator, "install_missing");
    defer s.deinit(testing.allocator);
    try initDb(s.path);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/Brewfile", .{s.path});
    defer testing.allocator.free(path);
    const needle = try std.fmt.allocPrint(testing.allocator, "Cannot read bundle file {s}", .{path});
    defer testing.allocator.free(needle);
    try expectInstallRefusal(path, needle);
}

test "install on a directory says it cannot read it" {
    var s = try Scratch.init(testing.allocator, "install_dir");
    defer s.deinit(testing.allocator);
    try initDb(s.path);
    try expectInstallRefusal(s.path, "Cannot read bundle file");
}

test "install on an oversized bundle file names the size cap" {
    var s = try Scratch.init(testing.allocator, "install_big");
    defer s.deinit(testing.allocator);
    try initDb(s.path);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/Brewfile", .{s.path});
    defer testing.allocator.free(path);
    {
        // Sparse: one byte past the cap without writing 8 MiB.
        const f = try test_io.createFileAbsolute(std.Options.debug_io, path, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        try f.setLength(std.Options.debug_io, 8 * 1024 * 1024 + 1);
    }
    try expectInstallRefusal(path, "larger than 8 MiB");
}

// --- import: manifest_path canonicalisation ---------------------------

fn writeFile(path: []const u8, body: []const u8) !void {
    const f = try test_io.createFileAbsolute(std.Options.debug_io, path, .{ .truncate = true });
    defer f.close(std.Options.debug_io);
    try f.writeStreamingAll(std.Options.debug_io, body);
}

/// A cwd-relative spelling of `path` without chdir: the runner is parallel
/// and cwd is process-global.
fn relativeToCwd(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var cwd_buf: [test_io.max_path_bytes]u8 = undefined;
    const cwd = cwd_buf[0..try test_io.cwd().realPathFile(std.Options.debug_io, ".", &cwd_buf)];
    return std.fs.path.relativePosix(allocator, cwd, cwd, path);
}

fn storedManifestPath(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]u8 {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    var stmt = try db.prepare("SELECT manifest_path FROM bundles WHERE name = ?;");
    defer stmt.finalize();
    try stmt.bindText(1, name);
    try testing.expect(try stmt.step());
    return allocator.dupe(u8, std.mem.sliceTo(stmt.columnText(0).?, 0));
}

test "import stores the canonical absolute path for a relative manifest argument" {
    var s = try Scratch.init(testing.allocator, "import_relpath");
    defer s.deinit(testing.allocator);
    try initDb(s.path);

    const path = try std.fmt.allocPrint(testing.allocator, "{s}/Maltfile.json", .{s.path});
    defer testing.allocator.free(path);
    try writeFile(path,
        \\{"name": "relpath", "version": 1, "formulas": []}
    );

    const rel = try relativeToCwd(testing.allocator, path);
    defer testing.allocator.free(rel);
    try testing.expect(!std.fs.path.isAbsolute(rel));

    quiet();
    defer unquiet();
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "import", rel });

    const want = try test_io.cwd().realPathFileAlloc(std.Options.debug_io, path, testing.allocator);
    defer testing.allocator.free(want);
    const stored = try storedManifestPath(testing.allocator, s.path, "relpath");
    defer testing.allocator.free(stored);
    try testing.expectEqualStrings(want, stored);
}

test "import collapses dot-dot segments in an absolute manifest argument" {
    var s = try Scratch.init(testing.allocator, "import_dotdot");
    defer s.deinit(testing.allocator);
    try initDb(s.path);

    const sub = try std.fmt.allocPrint(testing.allocator, "{s}/sub", .{s.path});
    defer testing.allocator.free(sub);
    try test_io.cwd().createDirPath(std.Options.debug_io, sub);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/Maltfile.json", .{s.path});
    defer testing.allocator.free(path);
    try writeFile(path,
        \\{"name": "dotdot", "version": 1, "formulas": []}
    );
    const dotted = try std.fmt.allocPrint(testing.allocator, "{s}/sub/../Maltfile.json", .{s.path});
    defer testing.allocator.free(dotted);

    quiet();
    defer unquiet();
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "import", dotted });

    const want = try test_io.cwd().realPathFileAlloc(std.Options.debug_io, path, testing.allocator);
    defer testing.allocator.free(want);
    const stored = try storedManifestPath(testing.allocator, s.path, "dotdot");
    defer testing.allocator.free(stored);
    try testing.expectEqualStrings(want, stored);
}

test "import records a symlinked manifest by its target" {
    var s = try Scratch.init(testing.allocator, "import_symlink");
    defer s.deinit(testing.allocator);
    try initDb(s.path);

    const target = try std.fmt.allocPrint(testing.allocator, "{s}/Maltfile.json", .{s.path});
    defer testing.allocator.free(target);
    try writeFile(target,
        \\{"name": "linked", "version": 1, "formulas": []}
    );
    const link = try std.fmt.allocPrint(testing.allocator, "{s}/link.json", .{s.path});
    defer testing.allocator.free(link);
    try test_io.cwd().symLink(std.Options.debug_io, target, link, .{});

    quiet();
    defer unquiet();
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "import", link });

    // Same canonicalisation every other site uses: the row names the file
    // that will actually be read, not the link.
    const want = try test_io.cwd().realPathFileAlloc(std.Options.debug_io, target, testing.allocator);
    defer testing.allocator.free(want);
    const stored = try storedManifestPath(testing.allocator, s.path, "linked");
    defer testing.allocator.free(stored);
    try testing.expectEqualStrings(want, stored);
}

test "import keeps the typed path as the registered name when the manifest has none" {
    var s = try Scratch.init(testing.allocator, "import_name_fallback");
    defer s.deinit(testing.allocator);
    try initDb(s.path);

    const path = try std.fmt.allocPrint(testing.allocator, "{s}/Brewfile", .{s.path});
    defer testing.allocator.free(path);
    try writeFile(path, "brew \"wget\"\n");

    const rel = try relativeToCwd(testing.allocator, path);
    defer testing.allocator.free(rel);

    quiet();
    defer unquiet();
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "import", rel });

    // The name stays what the user typed; only the path column is canonical.
    const stored = try storedManifestPath(testing.allocator, s.path, rel);
    defer testing.allocator.free(stored);
    try testing.expect(std.fs.path.isAbsolute(stored));
}

test "remove --purge refuses a legacy relative manifest_path and keeps the row" {
    var s = try Scratch.init(testing.allocator, "purge_legacy_rel");
    defer s.deinit(testing.allocator);
    try initDb(s.path);

    // A relative path that *does* resolve from the runner's cwd: a purge that
    // opens it instead of refusing is exactly the cwd-dependent read.
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/Brewfile", .{s.path});
    defer testing.allocator.free(path);
    try writeFile(path, "brew \"wget\"\n");
    const rel = try relativeToCwd(testing.allocator, path);
    defer testing.allocator.free(rel);
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        var stmt = try db.prepare(
            \\INSERT INTO bundles (name, manifest_path, created_at, version)
            \\VALUES ('legacy', ?, 1700000000, 1);
        );
        defer stmt.finalize();
        try stmt.bindText(1, rel);
        _ = try stmt.step();
    }

    try expectRefused(&malt.app_ctx.debug_ctx, &.{ "remove", "--purge", "--dry-run", "legacy" }, "relative manifest path");

    // Refusal happens before unregister, so the user can re-import by name.
    const stored = try storedManifestPath(testing.allocator, s.path, "legacy");
    defer testing.allocator.free(stored);
    try testing.expectEqualStrings(rel, stored);
}

test "re-import replaces a legacy relative row with the canonical path" {
    var s = try Scratch.init(testing.allocator, "reimport_legacy");
    defer s.deinit(testing.allocator);
    try initDb(s.path);
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        var stmt = try db.prepare(
            \\INSERT INTO bundles (name, manifest_path, created_at, version)
            \\VALUES ('legacy', 'Brewfile', 1700000000, 1);
        );
        defer stmt.finalize();
        _ = try stmt.step();
    }

    // The recovery the refusal message asks for: same name, fresh import.
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/Maltfile.json", .{s.path});
    defer testing.allocator.free(path);
    try writeFile(path,
        \\{"name": "legacy", "version": 1, "formulas": []}
    );

    quiet();
    defer unquiet();
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "import", path });

    const want = try test_io.cwd().realPathFileAlloc(std.Options.debug_io, path, testing.allocator);
    defer testing.allocator.free(want);
    const stored = try storedManifestPath(testing.allocator, s.path, "legacy");
    defer testing.allocator.free(stored);
    try testing.expectEqualStrings(want, stored);
}

// --- export -----------------------------------------------------------

test "export with no installed packages emits an empty Brewfile body to stdout" {
    var s = try Scratch.init(testing.allocator, "export_empty");
    defer s.deinit(testing.allocator);
    try initDb(s.path);

    // ctx.stdout defaults to fd=-1; export's writer.flush() needs a real
    // sink to swallow the emitted bytes without an EBADF write error.
    const ctx: malt.app_ctx.AppCtx = .{
        .io = std.Options.debug_io,
        .environ = .empty,
        .stdout = test_io.testSink(),
        .stderr = test_io.testSink(),
    };

    quiet();
    defer unquiet();

    try bundle.execute(&ctx, testing.allocator, &.{"export"});
}

test "export --format json with no installed packages emits a JSON body" {
    var s = try Scratch.init(testing.allocator, "export_json");
    defer s.deinit(testing.allocator);
    try initDb(s.path);

    const ctx: malt.app_ctx.AppCtx = .{
        .io = std.Options.debug_io,
        .environ = .empty,
        .stdout = test_io.testSink(),
        .stderr = test_io.testSink(),
    };

    quiet();
    defer unquiet();

    try bundle.execute(&ctx, testing.allocator, &.{ "export", "--format", "json" });
}

// --- round-trip: taps + services in `bundle create` -------------------
//
// `bundle export → bundle install` previously dropped taps and auto-
// start services silently. These pin the population path in
// `populateFromInstalled`. `create` writes the manifest to a file we
// can read back; `export` shares the same helper.

fn seedTapsAndServices(prefix: []const u8) !void {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    try db.exec(
        \\INSERT INTO taps (name, url)
        \\VALUES ('homebrew/cask-fonts', 'https://github.com/Homebrew/homebrew-cask-fonts'),
        \\       ('xykong/tap',          'https://github.com/xykong/homebrew-tap');
    );
    try db.exec(
        \\INSERT INTO services (name, keg_name, plist_path, auto_start, last_status)
        \\VALUES ('postgresql@16', 'postgresql@16', '/tmp/p.plist', 1, 'running'),
        \\       ('redis',         'redis',         '/tmp/r.plist', 0, 'stopped'),
        \\       ('lxd',           'lx',            '/tmp/l.plist', 1, 'running');
    );
    // A local keg's service must not travel without its package.
    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, tap, install_reason)
        \\VALUES ('lx', '/src/lx.rb', '1.0', 'd', '/c/lx', 'local', 'direct');
    );
}

test "bundle create --format json emits registered taps in the manifest" {
    var s = try Scratch.init(testing.allocator, "create_taps");
    defer s.deinit(testing.allocator);
    try seedTapsAndServices(s.path);

    const out_path = try std.fmt.allocPrint(testing.allocator, "{s}/Maltfile.json", .{s.path});
    defer testing.allocator.free(out_path);

    quiet();
    defer unquiet();
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "create", "--format", "json", out_path });

    const f = try test_io.openFileAbsolute(std.Options.debug_io, out_path, .{});
    defer f.close(std.Options.debug_io);
    const stat = try f.stat(std.Options.debug_io);
    const body = try testing.allocator.alloc(u8, stat.size);
    defer testing.allocator.free(body);
    _ = try f.readPositionalAll(std.Options.debug_io, body, 0);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const taps = parsed.value.object.get("taps") orelse return error.MissingTaps;
    try testing.expectEqual(@as(usize, 2), taps.array.items.len);
    try testing.expectEqualStrings("homebrew/cask-fonts", taps.array.items[0].string);
    try testing.expectEqualStrings("xykong/tap", taps.array.items[1].string);
}

test "bundle create writes a nested output path, creating missing parents" {
    // The out_path's parent dir does not exist yet; create must make it
    // rather than fail — parity with `backup -o` / `purge --backup`.
    var s = try Scratch.init(testing.allocator, "create_nested");
    defer s.deinit(testing.allocator);

    const out_path = try std.fmt.allocPrint(testing.allocator, "{s}/nested/sub/Brewfile", .{s.path});
    defer testing.allocator.free(out_path);

    quiet();
    defer unquiet();
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "create", out_path });

    const f = try test_io.openFileAbsolute(std.Options.debug_io, out_path, .{});
    f.close(std.Options.debug_io);
}

test "bundle create --format json --services emits auto_start services only" {
    var s = try Scratch.init(testing.allocator, "create_services");
    defer s.deinit(testing.allocator);
    try seedTapsAndServices(s.path);

    const out_path = try std.fmt.allocPrint(testing.allocator, "{s}/Maltfile.json", .{s.path});
    defer testing.allocator.free(out_path);

    quiet();
    defer unquiet();
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "create", "--format", "json", "--services", out_path });

    const f = try test_io.openFileAbsolute(std.Options.debug_io, out_path, .{});
    defer f.close(std.Options.debug_io);
    const stat = try f.stat(std.Options.debug_io);
    const body = try testing.allocator.alloc(u8, stat.size);
    defer testing.allocator.free(body);
    _ = try f.readPositionalAll(std.Options.debug_io, body, 0);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const services = parsed.value.object.get("services") orelse return error.MissingServices;
    try testing.expectEqual(@as(usize, 1), services.array.items.len);
    const svc = services.array.items[0].object;
    try testing.expectEqualStrings("postgresql@16", svc.get("name").?.string);
    try testing.expect(svc.get("auto_start").?.bool);
}

test "bundle create --format json without --services omits services" {
    var s = try Scratch.init(testing.allocator, "create_no_services");
    defer s.deinit(testing.allocator);
    try seedTapsAndServices(s.path);

    const out_path = try std.fmt.allocPrint(testing.allocator, "{s}/Maltfile.json", .{s.path});
    defer testing.allocator.free(out_path);

    quiet();
    defer unquiet();
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "create", "--format", "json", out_path });

    const f = try test_io.openFileAbsolute(std.Options.debug_io, out_path, .{});
    defer f.close(std.Options.debug_io);
    const stat = try f.stat(std.Options.debug_io);
    const body = try testing.allocator.alloc(u8, stat.size);
    defer testing.allocator.free(body);
    _ = try f.readPositionalAll(std.Options.debug_io, body, 0);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("services") == null);
}

test "bundle create --format brewfile --services accepts the flag but emits no service line" {
    // Brewfile grammar has no `service` directive; the help text says
    // services are JSON-only. Pin that the flag is accepted (no
    // InvalidArgs) and silently drops services from the textual output.
    var s = try Scratch.init(testing.allocator, "create_brewfile_services");
    defer s.deinit(testing.allocator);
    try seedTapsAndServices(s.path);

    const out_path = try std.fmt.allocPrint(testing.allocator, "{s}/Brewfile", .{s.path});
    defer testing.allocator.free(out_path);

    quiet();
    defer unquiet();
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "create", "--format", "brewfile", "--services", out_path });

    const f = try test_io.openFileAbsolute(std.Options.debug_io, out_path, .{});
    defer f.close(std.Options.debug_io);
    const stat = try f.stat(std.Options.debug_io);
    const body = try testing.allocator.alloc(u8, stat.size);
    defer testing.allocator.free(body);
    _ = try f.readPositionalAll(std.Options.debug_io, body, 0);

    // Taps still land (Brewfile grammar has `tap`); services do not.
    try testing.expect(std.mem.indexOf(u8, body, "tap \"homebrew/cask-fonts\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "postgresql@16") == null);
    try testing.expect(std.mem.indexOf(u8, body, "service ") == null);
}

test "bundle create round-trip: emitted JSON re-parses with taps preserved" {
    var s = try Scratch.init(testing.allocator, "create_roundtrip");
    defer s.deinit(testing.allocator);
    try seedTapsAndServices(s.path);

    const out_path = try std.fmt.allocPrint(testing.allocator, "{s}/Maltfile.json", .{s.path});
    defer testing.allocator.free(out_path);

    quiet();
    defer unquiet();
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "create", "--format", "json", "--services", out_path });

    const f = try test_io.openFileAbsolute(std.Options.debug_io, out_path, .{});
    defer f.close(std.Options.debug_io);
    const stat = try f.stat(std.Options.debug_io);
    const body = try testing.allocator.alloc(u8, stat.size);
    defer testing.allocator.free(body);
    _ = try f.readPositionalAll(std.Options.debug_io, body, 0);

    var m = try malt.bundle_manifest.parseJson(testing.allocator, body);
    defer m.deinit();
    try testing.expectEqual(@as(usize, 2), m.taps.len);
    try testing.expectEqualStrings("homebrew/cask-fonts", m.taps[0]);
    try testing.expectEqual(@as(usize, 1), m.services.len);
    try testing.expectEqualStrings("postgresql@16", m.services[0].name);
    try testing.expect(m.services[0].auto_start);
}

fn seedTapPackages(prefix: []const u8) !void {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);
    try db.exec(
        \\INSERT INTO taps (name, url) VALUES ('acme/tools', 'https://github.com/acme/homebrew-tools');
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, tap, tap_rb_subtree, install_reason) VALUES
        \\  ('foo', 'acme/tools/foo', '1.0', 'a', '/c/foo', 'acme/tools', 'formula', 'direct'),
        \\  ('bar', 'acme/tools/bar', '2.0', 'b', '/c/bar', 'acme/tools', 'cask', 'direct'),
        \\  ('wget', 'wget', '1.24', 'c', '/c/wget', 'homebrew/core', NULL, 'direct'),
        \\  ('lx', '/src/lx.rb', '1.0', 'd', '/c/lx', 'local', NULL, 'direct');
        \\INSERT INTO casks (token, name, version, url, tap) VALUES
        \\  ('firefox', 'firefox', '120.0', 'https://x.invalid/f.dmg', NULL),
        \\  ('baz', 'Baz', '3.0', 'https://x.invalid/b.dmg', 'acme/tools');
    );
}

test "bundle create names tap packages by their tap, and cleanup keeps them" {
    // A bare name makes `bundle install` resolve against core, and a keg
    // built from a tap's Casks/ only rebuilds through `cask`. A `--local`
    // recipe has no installable name, so it is left out with a rebuild hint.
    var s = try Scratch.init(testing.allocator, "create_tap_packages");
    defer s.deinit(testing.allocator);
    try seedTapPackages(s.path);

    const out_path = try std.fmt.allocPrint(testing.allocator, "{s}/Brewfile", .{s.path});
    defer testing.allocator.free(out_path);

    {
        var warned: std.ArrayList(u8) = .empty;
        defer warned.deinit(testing.allocator);
        output.beginStderrCapture(testing.allocator, &warned);
        defer output.endStderrCapture();
        // The file keeps no trace of the skip, so `-q` must not hide it.
        quiet();
        defer unquiet();
        try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "create", out_path });
        try testing.expect(std.mem.indexOf(u8, warned.items, "mt install --local '/src/lx.rb'") != null);
    }

    const f = try test_io.openFileAbsolute(std.Options.debug_io, out_path, .{});
    const stat = try f.stat(std.Options.debug_io);
    const body = try testing.allocator.alloc(u8, stat.size);
    defer testing.allocator.free(body);
    _ = try f.readPositionalAll(std.Options.debug_io, body, 0);
    f.close(std.Options.debug_io);

    for ([_][]const u8{
        "brew \"acme/tools/foo\"\n",
        "brew \"wget\"\n",
        "cask \"acme/tools/bar\"\n",
        "cask \"acme/tools/baz\"\n",
        "cask \"firefox\"\n",
    }) |line| {
        if (std.mem.indexOf(u8, body, line) == null) {
            std.debug.print("missing {s} in:\n{s}\n", .{ line, body });
            return error.TestUnexpectedResult;
        }
    }
    try testing.expect(std.mem.indexOf(u8, body, "brew \"bar\"") == null);
    try testing.expect(std.mem.indexOf(u8, body, "\"lx\"") == null);

    // Qualifying the writer alone would make cleanup uninstall every one,
    // and dropping the local line alone would uninstall the local keg.
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "cleanup", "--dry-run", out_path });
    try testing.expect(std.mem.indexOf(u8, captured.items, "nothing to clean up") != null);
}

test "bundle create names a control-byte local keg without echoing the byte" {
    // A row stored before install screened recipe paths: the scrubber passes
    // a UTF-8 C1, and install refuses the hint's path anyway.
    var s = try Scratch.init(testing.allocator, "create_local_control");
    defer s.deinit(testing.allocator);
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
        try db.exec("INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, tap, install_reason) " ++
            "VALUES ('lx', '/w/x' || char(155) || '2Jy/lx.rb', '1.0', 'd', '/c/lx', 'local', 'direct');");
    }
    const out_path = try std.fmt.allocPrint(testing.allocator, "{s}/Brewfile", .{s.path});
    defer testing.allocator.free(out_path);

    var warned: std.ArrayList(u8) = .empty;
    defer warned.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &warned);
    defer output.endStderrCapture();
    quiet();
    defer unquiet();
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "create", out_path });

    try testing.expect(std.mem.indexOf(u8, warned.items, "\xc2\x9b") == null);
    try testing.expect(std.mem.indexOf(u8, warned.items, "mt install --local") == null);
    try testing.expect(std.mem.indexOf(u8, warned.items, "lx (/w/x\\xc2\\x9b2Jy/lx.rb) is a local formula whose name or recipe path holds a control character; bundle skips it") != null);
}

test "bundle cleanup never plans a local keg, even from an empty Brewfile" {
    // No Brewfile can declare a `--local` recipe, so no Brewfile owns one.
    var s = try Scratch.init(testing.allocator, "cleanup_skips_local");
    defer s.deinit(testing.allocator);
    try seedTapPackages(s.path);

    const empty = try std.fmt.allocPrint(testing.allocator, "{s}/Empty", .{s.path});
    defer testing.allocator.free(empty);
    try writeFile(empty, "");

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "cleanup", "--dry-run", empty });

    try testing.expect(std.mem.indexOf(u8, captured.items, "- wget") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "- lx") == null);
}

test "bundle cleanup spares a core keg the local keg still depends on" {
    // Uninstall refuses a keg something kept still needs, which used to fail
    // the whole run once the local keg stopped leaving with it.
    var s = try Scratch.init(testing.allocator, "cleanup_spares_local_dep");
    defer s.deinit(testing.allocator);
    try seedTapPackages(s.path);
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try db.exec(
            \\INSERT INTO dependencies (keg_id, dep_name, dep_type)
            \\  SELECT id, 'wget', 'runtime' FROM kegs WHERE name = 'lx';
        );
    }

    const empty = try std.fmt.allocPrint(testing.allocator, "{s}/Empty", .{s.path});
    defer testing.allocator.free(empty);
    try writeFile(empty, "");

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "cleanup", "--dry-run", empty });

    try testing.expect(std.mem.indexOf(u8, captured.items, "- wget") == null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "- foo") != null);
    // Say why it stays, or "nothing to clean up" hides an unlisted package.
    try testing.expect(std.mem.indexOf(u8, captured.items, "keeping wget") != null);
}

test "remove --purge never takes a local keg for a same-named core line" {
    // `brew "lx"` names core's lx; purging the bundle must not reach a
    // `--local` keg that merely shares the name.
    var s = try Scratch.init(testing.allocator, "purge_skips_local");
    defer s.deinit(testing.allocator);
    try seedTapPackages(s.path);

    const path = try std.fmt.allocPrint(testing.allocator, "{s}/Brewfile", .{s.path});
    defer testing.allocator.free(path);
    try writeFile(path, "brew \"lx\"\nbrew \"wget\"\n");

    quiet();
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "import", path });
    unquiet();

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "remove", "--purge", "--dry-run", path });

    try testing.expect(std.mem.indexOf(u8, captured.items, "- wget") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "- lx") == null);
}

test "bundle create refuses a table it cannot read instead of writing a Brewfile without it" {
    // A manifest missing every cask (or formula, tap, service) reads as a
    // complete snapshot, and a later restore would leave them off.
    inline for (.{ "taps", "kegs", "casks", "services" }) |table| {
        var s = try Scratch.init(testing.allocator, "create_corrupt_" ++ table);
        defer s.deinit(testing.allocator);
        try initDb(s.path);
        var db_path_buf: [512]u8 = undefined;
        try test_io.corruptTable(try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0), table);

        const out_path = try std.fmt.allocPrint(testing.allocator, "{s}/Brewfile", .{s.path});
        defer testing.allocator.free(out_path);
        var captured: std.ArrayList(u8) = .empty;
        defer captured.deinit(testing.allocator);
        output.beginStderrCapture(testing.allocator, &captured);
        defer output.endStderrCapture();
        try testing.expectError(error.Aborted, bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "create", "--services", out_path }));
        try testing.expectError(error.FileNotFound, test_io.accessAbsolute(std.Options.debug_io, out_path, .{}));
        // Said in words, not as a raw error name and trace.
        try testing.expect(std.mem.indexOf(u8, captured.items, "package database") != null);
        try testing.expect(std.mem.indexOf(u8, captured.items, "malformed") != null);
    }
}

test "bundle export refuses a bundle whose members it cannot read instead of exporting it empty" {
    // An empty export piped into a Brewfile or `bundle install` silently drops
    // the whole bundle.
    var s = try Scratch.init(testing.allocator, "export_corrupt_members");
    defer s.deinit(testing.allocator);
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
    {
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
        try db.exec(
            \\INSERT INTO bundles (name, manifest_path, created_at, version) VALUES ('x', NULL, 0, 1);
            \\INSERT INTO bundle_members (bundle_name, kind, ref) VALUES ('x', 'formula', 'wget');
        );
    }
    const ctx: malt.app_ctx.AppCtx = .{
        .io = std.Options.debug_io,
        .environ = .empty,
        .stdout = test_io.testSink(),
        .stderr = test_io.testSink(),
    };
    // Control: the same bundle exports while the table is readable.
    {
        quiet();
        defer unquiet();
        try bundle.execute(&ctx, testing.allocator, &.{ "export", "x" });
    }

    try test_io.corruptTable(db_path, "bundle_members");
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();
    try testing.expectError(error.Aborted, bundle.execute(&ctx, testing.allocator, &.{ "export", "x" }));
    try testing.expect(std.mem.indexOf(u8, captured.items, "package database") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "malformed") != null);
}

test "bundle export refuses a bundle that was never registered instead of exporting it empty" {
    // A typo'd name must not read as a real bundle with nothing in it.
    var s = try Scratch.init(testing.allocator, "export_unknown_bundle");
    defer s.deinit(testing.allocator);
    try initDb(s.path);
    const ctx: malt.app_ctx.AppCtx = .{
        .io = std.Options.debug_io,
        .environ = .empty,
        .stdout = test_io.testSink(),
        .stderr = test_io.testSink(),
    };
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();
    try testing.expectError(error.Aborted, bundle.execute(&ctx, testing.allocator, &.{ "export", "nope" }));
    try testing.expect(std.mem.indexOf(u8, captured.items, "bundle not registered: nope") != null);
}

test "bundle export of a registered bundle with no members still succeeds" {
    // Edge of the unknown-name refusal: empty is a real state, not an error.
    var s = try Scratch.init(testing.allocator, "export_empty_bundle");
    defer s.deinit(testing.allocator);
    {
        var db_path_buf: [512]u8 = undefined;
        var db = try sqlite.Database.open(try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0));
        defer db.close();
        try schema.initSchema(&db);
        try db.exec("INSERT INTO bundles (name, manifest_path, created_at, version) VALUES ('empty', NULL, 0, 1);");
    }
    const ctx: malt.app_ctx.AppCtx = .{
        .io = std.Options.debug_io,
        .environ = .empty,
        .stdout = test_io.testSink(),
        .stderr = test_io.testSink(),
    };
    quiet();
    defer unquiet();
    try bundle.execute(&ctx, testing.allocator, &.{ "export", "empty" });
}

test "bundle export refuses a second bundle name instead of exporting only the last" {
    // Silently dropping one name exports a different bundle than asked for.
    var s = try Scratch.init(testing.allocator, "export_two_names");
    defer s.deinit(testing.allocator);
    try initDb(s.path);
    try expectRefused(&malt.app_ctx.debug_ctx, &.{ "export", "a", "b" }, "expected at most one <name>");
}

test "bundle export rejects a --format with no value instead of defaulting to a Brewfile" {
    var s = try Scratch.init(testing.allocator, "export_dangling_format");
    defer s.deinit(testing.allocator);
    try initDb(s.path);
    const ctx: malt.app_ctx.AppCtx = .{
        .io = std.Options.debug_io,
        .environ = .empty,
        .stdout = test_io.testSink(),
        .stderr = test_io.testSink(),
    };
    try expectRefused(&ctx, &.{ "export", "--format" }, "--format expects brewfile or json");
}

test "bundle create refuses an unknown --format in words" {
    var s = try Scratch.init(testing.allocator, "create_bad_format");
    defer s.deinit(testing.allocator);
    try initDb(s.path);
    try expectRefused(&malt.app_ctx.debug_ctx, &.{ "create", "--format", "yaml" }, "--format expects brewfile or json");
}

test "bundle export says it could not write stdout instead of a raw write error" {
    // A closed or broken stdout is the everyday failure of a piped export.
    var s = try Scratch.init(testing.allocator, "export_stdout_unwritable");
    defer s.deinit(testing.allocator);
    try initDb(s.path);
    const ro_path = try std.fmt.allocPrint(testing.allocator, "{s}/ro", .{s.path});
    defer testing.allocator.free(ro_path);
    (try test_io.createFileAbsolute(std.Options.debug_io, ro_path, .{})).close(std.Options.debug_io);
    const ro = try test_io.openFileAbsolute(std.Options.debug_io, ro_path, .{});
    defer ro.close(std.Options.debug_io);
    const ctx: malt.app_ctx.AppCtx = .{
        .io = std.Options.debug_io,
        .environ = .empty,
        .stdout = ro,
        .stderr = test_io.testSink(),
    };
    // JSON always has a body; an empty Brewfile would never reach the writer.
    try expectRefused(&ctx, &.{ "export", "--format", "json" }, "Cannot write stdout");
}

test "bundle says it could not open the database instead of a raw open error" {
    var s = try Scratch.init(testing.allocator, "db_unopenable");
    defer s.deinit(testing.allocator);
    // A directory where the database file belongs.
    const db_path = try std.fmt.allocPrint(testing.allocator, "{s}/db/malt.db", .{s.path});
    defer testing.allocator.free(db_path);
    try test_io.makeDirAbsolute(std.Options.debug_io, db_path);
    try expectRefused(&malt.app_ctx.debug_ctx, &.{"list"}, "Failed to open database");
}

test "bundle create names the path it could not write" {
    var s = try Scratch.init(testing.allocator, "create_unwritable");
    defer s.deinit(testing.allocator);
    try initDb(s.path);
    // A regular file where the parent directory should be.
    const blocker = try std.fmt.allocPrint(testing.allocator, "{s}/blocker", .{s.path});
    defer testing.allocator.free(blocker);
    (try test_io.createFileAbsolute(std.Options.debug_io, blocker, .{})).close(std.Options.debug_io);
    const out = try std.fmt.allocPrint(testing.allocator, "{s}/Brewfile", .{blocker});
    defer testing.allocator.free(out);
    try expectRefused(&malt.app_ctx.debug_ctx, &.{ "create", out }, "Cannot write");
}

test "bundle list, remove, cleanup and export refuse a table they cannot read in words" {
    // Each reads the database on its own path; none may end in a raw error.
    const cases = .{
        .{ "bundles", &[_][]const u8{"list"} },
        .{ "bundles", &[_][]const u8{ "remove", "x" } },
        // Must not read as "bundle not registered".
        .{ "bundles", &[_][]const u8{ "export", "x" } },
        .{ "kegs", &[_][]const u8{ "cleanup", "--dry-run" } },
    };
    inline for (cases, 0..) |case, i| {
        var s = try Scratch.init(testing.allocator, "read_corrupt_" ++ std.fmt.comptimePrint("{d}", .{i}));
        defer s.deinit(testing.allocator);
        {
            var db_path_buf: [512]u8 = undefined;
            const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
            var db = try sqlite.Database.open(db_path);
            defer db.close();
            try schema.initSchema(&db);
            try db.exec("INSERT INTO bundles (name, manifest_path, created_at, version) VALUES ('x', NULL, 0, 1);");
        }
        var db_path_buf: [512]u8 = undefined;
        try test_io.corruptTable(try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0), case[0]);

        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(testing.allocator);
        try args.appendSlice(testing.allocator, case[1]);
        // cleanup needs a manifest to diff the installed set against.
        const brewfile = try std.fmt.allocPrint(testing.allocator, "{s}/Brewfile", .{s.path});
        defer testing.allocator.free(brewfile);
        if (std.mem.eql(u8, case[1][0], "cleanup")) {
            const f = try test_io.createFileAbsolute(std.Options.debug_io, brewfile, .{ .truncate = true });
            defer f.close(std.Options.debug_io);
            try f.writeStreamingAll(std.Options.debug_io, "brew \"wget\"\n");
            try args.append(testing.allocator, brewfile);
        }
        // SQLite's own reason, not a status a later finalize reset to OK.
        try expectRefused(&malt.app_ctx.debug_ctx, args.items, "package database: database disk image is malformed");
    }
}

test "bundle export refuses an unknown flag instead of exporting without it" {
    var s = try Scratch.init(testing.allocator, "export_unknown_flag");
    defer s.deinit(testing.allocator);
    try initDb(s.path);
    try expectRefused(&malt.app_ctx.debug_ctx, &.{ "export", "--bogus" }, "Unknown flag: --bogus");
}

test "bundle export reads a name after `--` as the bundle, not as a flag" {
    var s = try Scratch.init(testing.allocator, "export_double_dash");
    defer s.deinit(testing.allocator);
    {
        var db_path_buf: [512]u8 = undefined;
        var db = try sqlite.Database.open(try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0));
        defer db.close();
        try schema.initSchema(&db);
        try db.exec("INSERT INTO bundles (name, manifest_path, created_at, version) VALUES ('-dev', NULL, 0, 1);");
    }
    const ctx: malt.app_ctx.AppCtx = .{
        .io = std.Options.debug_io,
        .environ = .empty,
        .stdout = test_io.testSink(),
        .stderr = test_io.testSink(),
    };
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();
    try bundle.execute(&ctx, testing.allocator, &.{ "export", "--", "-dev" });
    try testing.expectEqualStrings("", captured.items);
}

// --- install / cleanup / remove: an unknown flag stops the mutation ----

fn countBundles(prefix: []const u8, name: ?[]const u8) !i64 {
    var db_path_buf: [512]u8 = undefined;
    var db = try sqlite.Database.open(try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0));
    defer db.close();
    var stmt = try db.prepare(if (name == null)
        "SELECT count(*) FROM bundles;"
    else
        "SELECT count(*) FROM bundles WHERE name = ?1;");
    defer stmt.finalize();
    if (name) |n| try stmt.bindText(1, n);
    _ = try stmt.step();
    return stmt.columnInt(0);
}

fn writeEmptyBrewfile(allocator: std.mem.Allocator, dir: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/Brewfile", .{dir});
    errdefer allocator.free(path);
    try writeFile(path, "# empty bundle\n");
    return path;
}

test "bundle install, cleanup and remove refuse an unknown flag instead of running without it" {
    var s = try Scratch.init(testing.allocator, "mutating_unknown_flag");
    defer s.deinit(testing.allocator);
    try initDb(s.path);
    const brewfile = try writeEmptyBrewfile(testing.allocator, s.path);
    defer testing.allocator.free(brewfile);
    {
        var db_path_buf: [512]u8 = undefined;
        var db = try sqlite.Database.open(try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0));
        defer db.close();
        try db.exec("INSERT INTO bundles (name, manifest_path, created_at, version) VALUES ('dev', NULL, 0, 1);");
    }

    // A mistyped safety flag must not turn into the real operation.
    try expectRefused(&malt.app_ctx.debug_ctx, &.{ "install", "--bogus", brewfile }, "Unknown flag: --bogus");
    try expectRefused(&malt.app_ctx.debug_ctx, &.{ "cleanup", "--dryrun", "--yes", brewfile }, "Unknown flag: --dryrun");
    try expectRefused(&malt.app_ctx.debug_ctx, &.{ "remove", "--prge", "dev" }, "Unknown flag: --prge");
    // Unknown flag wins over a missing name: the flag is the likelier typo.
    try expectRefused(&malt.app_ctx.debug_ctx, &.{ "remove", "--bogus" }, "Unknown flag: --bogus");

    // Nothing ran: no install was recorded and `dev` is still registered.
    try testing.expectEqual(@as(i64, 1), try countBundles(s.path, null));
    try testing.expectEqual(@as(i64, 1), try countBundles(s.path, "dev"));
}

test "bundle install and cleanup still accept every flag they document" {
    // Refusing unknown flags must not start refusing a real one.
    var s = try Scratch.init(testing.allocator, "mutating_known_flags");
    defer s.deinit(testing.allocator);
    try initDb(s.path);
    const brewfile = try writeEmptyBrewfile(testing.allocator, s.path);
    defer testing.allocator.free(brewfile);

    quiet();
    defer unquiet();
    const cases = [_][]const []const u8{
        &.{ "install", "--isolate-deps", "-n", brewfile },
        &.{ "install", "--isolate-dependencies", "--dry-run", brewfile },
        &.{ "cleanup", "-n", "-y", brewfile },
        &.{ "cleanup", "--dry-run", "--yes", brewfile },
    };
    for (cases) |args| try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, args);
    try testing.expectEqual(@as(i64, 0), try countBundles(s.path, null));
}

test "bundle install -n previews like --dry-run instead of installing" {
    var s = try Scratch.init(testing.allocator, "install_short_dry");
    defer s.deinit(testing.allocator);
    try initDb(s.path);
    const brewfile = try writeEmptyBrewfile(testing.allocator, s.path);
    defer testing.allocator.free(brewfile);

    const prior_dry = output.isDryRun();
    output.setDryRun(false);
    quiet();
    defer {
        output.setDryRun(prior_dry);
        unquiet();
    }

    // Completions offer `-n`, and cleanup and remove honour it.
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "install", "-n", brewfile });
    try testing.expectEqual(@as(i64, 0), try countBundles(s.path, null));

    // Control: a real install records the bundle, so the check above can fail.
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "install", brewfile });
    try testing.expectEqual(@as(i64, 1), try countBundles(s.path, null));
}

test "bundle install, cleanup and remove read an argument after `--` as an operand" {
    var s = try Scratch.init(testing.allocator, "mutating_double_dash");
    defer s.deinit(testing.allocator);
    try initDb(s.path);
    {
        var db_path_buf: [512]u8 = undefined;
        var db = try sqlite.Database.open(try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0));
        defer db.close();
        try db.exec("INSERT INTO bundles (name, manifest_path, created_at, version) VALUES ('-dev', NULL, 0, 1);");
    }

    // A dash-led path is a file to read, not a flag to refuse.
    try expectRefused(&malt.app_ctx.debug_ctx, &.{ "install", "--", "--bogus" }, "Cannot read bundle file --bogus");
    try expectRefused(&malt.app_ctx.debug_ctx, &.{ "cleanup", "--", "--bogus" }, "Cannot read bundle file --bogus");

    quiet();
    defer unquiet();
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "remove", "--", "-dev" });
    try testing.expectEqual(@as(i64, 0), try countBundles(s.path, "-dev"));
}

test "bundle export refuses a table it cannot read in words, not a raw error" {
    // Same refusal as `bundle create`; a bare error name and trace reads as a
    // malt crash, not as a damaged database.
    inline for (.{ "taps", "kegs", "casks", "services" }) |table| {
        var s = try Scratch.init(testing.allocator, "export_corrupt_" ++ table);
        defer s.deinit(testing.allocator);
        try initDb(s.path);
        var db_path_buf: [512]u8 = undefined;
        try test_io.corruptTable(try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0), table);

        const ctx: malt.app_ctx.AppCtx = .{
            .io = std.Options.debug_io,
            .environ = .empty,
            .stdout = test_io.testSink(),
            .stderr = test_io.testSink(),
        };
        var captured: std.ArrayList(u8) = .empty;
        defer captured.deinit(testing.allocator);
        output.beginStderrCapture(testing.allocator, &captured);
        defer output.endStderrCapture();
        try testing.expectError(error.Aborted, bundle.execute(&ctx, testing.allocator, &.{ "export", "--services" }));
        try testing.expect(std.mem.indexOf(u8, captured.items, "package database") != null);
        try testing.expect(std.mem.indexOf(u8, captured.items, "malformed") != null);
    }
}

test "bundle cleanup removes the dropped formula, not the kept cask of the same name" {
    // Cleanup names the kind, so dropping the formula never removes the cask
    // the Brewfile keeps, whichever kind a bare name resolves to.
    var s = try Scratch.init(testing.allocator, "cleanup_same_name");
    defer s.deinit(testing.allocator);
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
        try db.exec(
            \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, install_reason)
            \\VALUES ('box', 'box', '1.0', 0, '', 'Cellar/box/1.0', 'direct');
            \\INSERT INTO casks (token, name, version, url) VALUES ('box', 'Box', '1.0', 'https://example.invalid/b.zip');
        );
    }
    const cellar = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/box/1.0", .{s.path});
    defer testing.allocator.free(cellar);
    try test_io.cwd().createDirPath(std.Options.debug_io, cellar);
    const brewfile = try std.fmt.allocPrint(testing.allocator, "{s}/Brewfile", .{s.path});
    defer testing.allocator.free(brewfile);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, brewfile, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "cask \"box\"\n");
    }

    quiet();
    defer unquiet();
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "cleanup", "--yes", brewfile });

    var db_path_buf: [512]u8 = undefined;
    var db = try sqlite.Database.open(try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0));
    defer db.close();
    try testing.expect(try malt.cask.isInstalled(&db, "box"));
    var keg = try db.prepare("SELECT 1 FROM kegs WHERE name = 'box';");
    defer keg.finalize();
    try testing.expect(!try keg.step());
}

// --- subcommand help: `bundle <sub> --help` prints help, runs nothing --

fn bundleStdout(allocator: std.mem.Allocator, dir: []const u8, args: []const []const u8) ![]u8 {
    const io = std.Options.debug_io;
    const out_path = try std.fmt.allocPrint(allocator, "{s}/stdout", .{dir});
    defer allocator.free(out_path);
    const out = try test_io.createFileAbsolute(io, out_path, .{ .truncate = true, .read = true });
    defer out.close(io);
    const ctx: malt.app_ctx.AppCtx = .{
        .io = io,
        .environ = .empty,
        .stdout = out,
        .stderr = test_io.testSink(),
    };
    try bundle.execute(&ctx, allocator, args);
    const body = try allocator.alloc(u8, (try out.stat(io)).size);
    errdefer allocator.free(body);
    _ = try out.readPositionalAll(io, body, 0);
    return body;
}

test "bundle <subcommand> --help prints the bundle help instead of running the subcommand" {
    var s = try Scratch.init(testing.allocator, "sub_help");
    defer s.deinit(testing.allocator);
    try initDb(s.path);
    const brewfile = try writeEmptyBrewfile(testing.allocator, s.path);
    defer testing.allocator.free(brewfile);
    const created = try std.fmt.allocPrint(testing.allocator, "{s}/created", .{s.path});
    defer testing.allocator.free(created);
    {
        var db_path_buf: [512]u8 = undefined;
        var db = try sqlite.Database.open(try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0));
        defer db.close();
        try db.exec("INSERT INTO bundles (name, manifest_path, created_at, version) VALUES ('dev', NULL, 0, 1);");
    }

    const cases = [_][]const []const u8{
        &.{ "install", "--help", brewfile },
        &.{ "cleanup", "--yes", "-h", brewfile },
        &.{ "remove", "--purge", "dev", "--help" },
        &.{ "create", "--help", created },
        &.{ "export", "-h" },
        &.{ "import", "--help" },
        &.{ "list", "--help" },
    };
    for (cases) |args| {
        const body = try bundleStdout(testing.allocator, s.path, args);
        defer testing.allocator.free(body);
        if (std.mem.indexOf(u8, body, "Usage: malt bundle") == null) {
            std.debug.print("no help for {s}:\n{s}\n", .{ args[0], body });
            return error.TestExpectedEqual;
        }
    }

    // Asking for help must not install, unregister or write anything.
    try testing.expectEqual(@as(i64, 1), try countBundles(s.path, null));
    try testing.expectEqual(@as(i64, 1), try countBundles(s.path, "dev"));
    try testing.expectError(error.FileNotFound, test_io.openFileAbsolute(std.Options.debug_io, created, .{}));
}

test "bundle reads a --help after `--` as an operand, not a help request" {
    var s = try Scratch.init(testing.allocator, "help_after_double_dash");
    defer s.deinit(testing.allocator);
    try initDb(s.path);
    {
        var db_path_buf: [512]u8 = undefined;
        var db = try sqlite.Database.open(try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0));
        defer db.close();
        try db.exec("INSERT INTO bundles (name, manifest_path, created_at, version) VALUES ('--help', NULL, 0, 1);");
    }
    quiet();
    defer unquiet();
    const body = try bundleStdout(testing.allocator, s.path, &.{ "remove", "--", "--help" });
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "Usage: malt bundle") == null);
    try testing.expectEqual(@as(i64, 0), try countBundles(s.path, "--help"));
}

// --- install / cleanup: one bundle file, by position or brew's --file ---

test "bundle install and cleanup refuse a second bundle file instead of using only the last" {
    // `cleanup --yes A B` used to plan against B alone and uninstall A's packages.
    var s = try Scratch.init(testing.allocator, "two_bundle_files");
    defer s.deinit(testing.allocator);
    try initDb(s.path);
    const brewfile = try writeEmptyBrewfile(testing.allocator, s.path);
    defer testing.allocator.free(brewfile);

    const cases = [_][]const []const u8{
        &.{ "install", "-n", "nonexist", brewfile },
        &.{ "cleanup", "-n", "nonexist", brewfile },
        &.{ "install", "-n", "--file", "nonexist", brewfile },
        &.{ "cleanup", "-n", brewfile, "--file=nonexist" },
    };
    for (cases) |args| try expectRefused(&malt.app_ctx.debug_ctx, args, "expected at most one [file]");
}

test "bundle install and cleanup take brew's --file as the bundle file" {
    var s = try Scratch.init(testing.allocator, "file_flag");
    defer s.deinit(testing.allocator);
    try initDb(s.path);
    const brewfile = try writeEmptyBrewfile(testing.allocator, s.path);
    defer testing.allocator.free(brewfile);
    const eq = try std.fmt.allocPrint(testing.allocator, "--file={s}", .{brewfile});
    defer testing.allocator.free(eq);

    {
        quiet();
        defer unquiet();
        try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "install", "-n", "--file", brewfile });
        try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "cleanup", "-n", "--yes", eq });
    }
    // The value is the file read, not a flag or a lookup fallback.
    try expectRefused(&malt.app_ctx.debug_ctx, &.{ "install", "--file", "missing-bundle" }, "Cannot read bundle file missing-bundle");
    try expectRefused(&malt.app_ctx.debug_ctx, &.{ "cleanup", "--file" }, "--file expects a path");
    try expectRefused(&malt.app_ctx.debug_ctx, &.{ "install", "--file=" }, "--file expects a path");
}

test "an unknown bundle flag points at the help that lists the real ones" {
    var s = try Scratch.init(testing.allocator, "unknown_flag_hint");
    defer s.deinit(testing.allocator);
    try initDb(s.path);
    try expectRefused(&malt.app_ctx.debug_ctx, &.{ "install", "--no-upgrade" }, "malt bundle --help");
}

// --- import / list: the same flag rules as their siblings ---------------

test "bundle import honours `--` and refuses an unknown flag" {
    var s = try Scratch.init(testing.allocator, "import_flags");
    defer s.deinit(testing.allocator);
    try initDb(s.path);
    const manifest = try std.fmt.allocPrint(testing.allocator, "{s}/Maltfile.json", .{s.path});
    defer testing.allocator.free(manifest);
    try writeFile(manifest, "{\"name\": \"-dev\", \"version\": 1, \"formulas\": []}\n");

    try expectRefused(&malt.app_ctx.debug_ctx, &.{ "import", "--bogus", manifest }, "Unknown flag: --bogus");
    try expectRefused(&malt.app_ctx.debug_ctx, &.{ "import", manifest, manifest }, "expected <file>");
    quiet();
    defer unquiet();
    try bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "import", "--", manifest });
    try testing.expectEqual(@as(i64, 1), try countBundles(s.path, "-dev"));
}

test "bundle list refuses any argument instead of ignoring it" {
    var s = try Scratch.init(testing.allocator, "list_args");
    defer s.deinit(testing.allocator);
    try initDb(s.path);
    try expectRefused(&malt.app_ctx.debug_ctx, &.{ "list", "--bogus" }, "Unknown flag: --bogus");
    try expectRefused(&malt.app_ctx.debug_ctx, &.{ "list", "dev" }, "bundle list: expected no arguments");
}
