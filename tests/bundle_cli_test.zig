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
            "/tmp/malt_bundle_cli_{s}_{d}",
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

test "execute on an unknown subcommand returns InvalidArgs" {
    var s = try Scratch.init(testing.allocator, "unknown");
    defer s.deinit(testing.allocator);
    quiet();
    defer unquiet();
    try testing.expectError(
        bundle.BundleError.InvalidArgs,
        bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"frobnicate"}),
    );
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

test "remove with no name returns InvalidArgs" {
    var s = try Scratch.init(testing.allocator, "remove_noargs");
    defer s.deinit(testing.allocator);
    try initDb(s.path);

    quiet();
    defer unquiet();
    try testing.expectError(
        bundle.BundleError.InvalidArgs,
        bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"remove"}),
    );
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

test "import with no path returns InvalidArgs" {
    var s = try Scratch.init(testing.allocator, "import_noargs");
    defer s.deinit(testing.allocator);
    try initDb(s.path);

    quiet();
    defer unquiet();
    try testing.expectError(
        bundle.BundleError.InvalidArgs,
        bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"import"}),
    );
}

test "import on a missing path surfaces BundlefileNotFound" {
    var s = try Scratch.init(testing.allocator, "import_missing");
    defer s.deinit(testing.allocator);
    try initDb(s.path);

    quiet();
    defer unquiet();
    try testing.expectError(
        bundle.BundleError.BundlefileNotFound,
        bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "import", "/tmp/malt_bundle_cli_does_not_exist_xyz.json" }),
    );
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

test "import on a malformed Maltfile.json surfaces BundlefileParse" {
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

    quiet();
    defer unquiet();
    try testing.expectError(
        bundle.BundleError.BundlefileParse,
        bundle.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "import", path }),
    );
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
        \\       ('redis',         'redis',         '/tmp/r.plist', 0, 'stopped');
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
