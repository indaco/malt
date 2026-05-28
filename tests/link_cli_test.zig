//! malt — link / unlink command integration tests.
//!
//! Drives `link.executeLink` and `link.executeUnlink` against a scratch
//! MALT_PREFIX so every branch (help, missing argv, missing keg,
//! happy-path link + unlink, conflict detection) lands on the
//! coverage map without touching the real install root.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const link_mod = malt.cli_link;
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
            "/tmp/malt_link_{s}_{d}",
            .{ tag, ts },
            0,
        );
        test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
        try test_io.cwd().createDirPath(std.Options.debug_io, path);
        const sub = [_][]const u8{ "db", "bin", "opt" };
        for (sub) |s| {
            const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, s });
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

// Insert a keg row + Cellar/<name>/<v>/bin/<bin> on disk so the linker
// has a real source tree to symlink from.
fn seedKeg(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8, version: []const u8, bin_name: []const u8) !void {
    const cellar_path = try std.fmt.allocPrint(allocator, "{s}/Cellar/{s}/{s}", .{ prefix, name, version });
    defer allocator.free(cellar_path);
    const bin_dir = try std.fmt.allocPrint(allocator, "{s}/bin", .{cellar_path});
    defer allocator.free(bin_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, bin_dir);
    const bin_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ bin_dir, bin_name });
    defer allocator.free(bin_path);
    const f = try test_io.createFileAbsolute(std.Options.debug_io, bin_path, .{ .truncate = true });
    f.close(std.Options.debug_io);

    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    var stmt = try db.prepare(
        \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
        \\VALUES (?1, ?1, ?2, 0, '', ?3);
    );
    defer stmt.finalize();
    try stmt.bindText(1, name);
    try stmt.bindText(2, version);
    try stmt.bindText(3, cellar_path);
    _ = try stmt.step();
}

fn pathExists(path: []const u8) bool {
    test_io.accessAbsolute(std.Options.debug_io, path, .{}) catch return false;
    return true;
}

// --- executeLink early-return branches ----------------------------------

test "executeLink --help short-circuits" {
    var s = try Scratch.init(testing.allocator, "help_link");
    defer s.deinit(testing.allocator);
    quiet();
    defer unquiet();
    try link_mod.executeLink(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--help"});
}

test "executeLink with no args returns Aborted with usage" {
    var s = try Scratch.init(testing.allocator, "noargs_link");
    defer s.deinit(testing.allocator);
    quiet();
    defer unquiet();
    try testing.expectError(
        error.Aborted,
        link_mod.executeLink(&malt.app_ctx.debug_ctx, testing.allocator, &.{}),
    );
}

test "executeLink on a non-installed package returns Aborted" {
    var s = try Scratch.init(testing.allocator, "missing_link");
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
    try testing.expectError(
        error.Aborted,
        link_mod.executeLink(&malt.app_ctx.debug_ctx, testing.allocator, &.{"ghost-pkg"}),
    );
}

// --- happy path link + unlink ------------------------------------------

test "executeLink creates symlinks for an installed keg, executeUnlink removes them" {
    var s = try Scratch.init(testing.allocator, "happy");
    defer s.deinit(testing.allocator);
    try seedKeg(testing.allocator, s.path, "foo", "1.0", "foobin");

    quiet();
    defer unquiet();

    try link_mod.executeLink(&malt.app_ctx.debug_ctx, testing.allocator, &.{"foo"});

    const linked = try std.fmt.allocPrint(testing.allocator, "{s}/bin/foobin", .{s.path});
    defer testing.allocator.free(linked);
    try testing.expect(pathExists(linked));

    try link_mod.executeUnlink(&malt.app_ctx.debug_ctx, testing.allocator, &.{"foo"});
    try testing.expect(!pathExists(linked));
}

test "executeLink --overwrite forces relink past the conflict guard" {
    // Pre-create a non-keg symlink at the target so the conflict-check
    // path fires; --overwrite must still finish the link.
    var s = try Scratch.init(testing.allocator, "overwrite");
    defer s.deinit(testing.allocator);
    try seedKeg(testing.allocator, s.path, "foo", "1.0", "shared");

    // A second pseudo-keg whose `shared` already lives in prefix/bin.
    const sentinel_target = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/other/1.0/bin/shared", .{s.path});
    defer testing.allocator.free(sentinel_target);
    if (std.fs.path.dirname(sentinel_target)) |d| {
        test_io.cwd().createDirPath(std.Options.debug_io, d) catch {};
    }
    const f = try test_io.createFileAbsolute(std.Options.debug_io, sentinel_target, .{ .truncate = true });
    f.close(std.Options.debug_io);

    const link_at = try std.fmt.allocPrint(testing.allocator, "{s}/bin/shared", .{s.path});
    defer testing.allocator.free(link_at);
    try test_io.symLinkAbsolute(std.Options.debug_io, sentinel_target, link_at, .{});

    quiet();
    defer unquiet();

    // Without --overwrite, link refuses (Aborted).
    try testing.expectError(
        error.Aborted,
        link_mod.executeLink(&malt.app_ctx.debug_ctx, testing.allocator, &.{"foo"}),
    );

    // With --overwrite, link succeeds and the symlink now points at foo.
    try link_mod.executeLink(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "foo", "--overwrite" });
    try testing.expect(pathExists(link_at));
}

// --- executeUnlink early branches --------------------------------------

test "executeUnlink --help short-circuits" {
    var s = try Scratch.init(testing.allocator, "help_unlink");
    defer s.deinit(testing.allocator);
    quiet();
    defer unquiet();
    try link_mod.executeUnlink(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--help"});
}

test "executeUnlink with no args returns Aborted" {
    var s = try Scratch.init(testing.allocator, "noargs_unlink");
    defer s.deinit(testing.allocator);
    quiet();
    defer unquiet();
    try testing.expectError(
        error.Aborted,
        link_mod.executeUnlink(&malt.app_ctx.debug_ctx, testing.allocator, &.{}),
    );
}

test "executeUnlink on a non-installed package returns Aborted" {
    var s = try Scratch.init(testing.allocator, "missing_unlink");
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
    try testing.expectError(
        error.Aborted,
        link_mod.executeUnlink(&malt.app_ctx.debug_ctx, testing.allocator, &.{"ghost-pkg"}),
    );
}

// --- executeLink --isolate ----------------------------------------------

// Seed a keg row and tag it dependency so the --isolate gate accepts.
fn seedDepKeg(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    name: []const u8,
    version: []const u8,
    bin_name: []const u8,
) !void {
    try seedKeg(allocator, prefix, name, version, bin_name);
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    var stmt = try db.prepare("UPDATE kegs SET install_reason = 'dependency' WHERE name = ?1;");
    defer stmt.finalize();
    try stmt.bindText(1, name);
    _ = try stmt.step();
}

test "executeLink --isolate on a dep keg removes bin links and sets bin_isolated=1" {
    var s = try Scratch.init(testing.allocator, "isolate_dep");
    defer s.deinit(testing.allocator);
    try seedDepKeg(testing.allocator, s.path, "depbin", "1.0", "depbin");

    quiet();
    defer unquiet();

    // First, link normally so the bin/ row + symlink exist.
    try link_mod.executeLink(&malt.app_ctx.debug_ctx, testing.allocator, &.{"depbin"});
    const linked = try std.fmt.allocPrint(testing.allocator, "{s}/bin/depbin", .{s.path});
    defer testing.allocator.free(linked);
    try testing.expect(pathExists(linked));

    // Now isolate: bin symlink and links row must disappear; bin_isolated=1.
    try link_mod.executeLink(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "--isolate", "depbin" });
    try testing.expect(!pathExists(linked));

    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    var probe = try db.prepare("SELECT bin_isolated FROM kegs WHERE name='depbin';");
    defer probe.finalize();
    _ = try probe.step();
    try testing.expectEqual(@as(i64, 1), probe.columnInt(0));

    var cnt = try db.prepare("SELECT COUNT(*) FROM links WHERE link_path LIKE '%/bin/%';");
    defer cnt.finalize();
    _ = try cnt.step();
    try testing.expectEqual(@as(i64, 0), cnt.columnInt(0));
}

test "executeLink --isolate refuses on a direct keg" {
    var s = try Scratch.init(testing.allocator, "isolate_direct_refused");
    defer s.deinit(testing.allocator);
    try seedKeg(testing.allocator, s.path, "directbin", "1.0", "directbin");

    quiet();
    defer unquiet();

    try testing.expectError(
        error.Aborted,
        link_mod.executeLink(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "--isolate", "directbin" }),
    );
}

test "executeLink --isolate without a name and without --all is rejected" {
    var s = try Scratch.init(testing.allocator, "isolate_no_arg");
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
    try testing.expectError(
        error.Aborted,
        link_mod.executeLink(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--isolate"}),
    );
}

test "executeLink --isolate with both a name and --all is rejected" {
    var s = try Scratch.init(testing.allocator, "isolate_ambiguous");
    defer s.deinit(testing.allocator);
    try seedDepKeg(testing.allocator, s.path, "depbin", "1.0", "depbin");
    quiet();
    defer unquiet();
    try testing.expectError(
        error.Aborted,
        link_mod.executeLink(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "--isolate", "depbin", "--all" }),
    );
}

test "executeLink --isolate <missing-name> returns Aborted" {
    var s = try Scratch.init(testing.allocator, "isolate_missing_name");
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
    try testing.expectError(
        error.Aborted,
        link_mod.executeLink(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "--isolate", "ghost-pkg" }),
    );
}

test "executeLink --isolate --all on a prefix with no dep kegs is a clean info" {
    var s = try Scratch.init(testing.allocator, "isolate_all_empty");
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
    try link_mod.executeLink(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "--isolate", "--all" });
}

test "executeLink on an isolated dep re-links bins and clears bin_isolated" {
    var s = try Scratch.init(testing.allocator, "link_un_isolate");
    defer s.deinit(testing.allocator);
    try seedDepKeg(testing.allocator, s.path, "depbin", "1.0", "depbin");

    quiet();
    defer unquiet();

    // Isolate first.
    try link_mod.executeLink(&malt.app_ctx.debug_ctx, testing.allocator, &.{"depbin"});
    try link_mod.executeLink(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "--isolate", "depbin" });
    const linked = try std.fmt.allocPrint(testing.allocator, "{s}/bin/depbin", .{s.path});
    defer testing.allocator.free(linked);
    try testing.expect(!pathExists(linked));

    // Plain link must restore bins AND clear bin_isolated.
    try link_mod.executeLink(&malt.app_ctx.debug_ctx, testing.allocator, &.{"depbin"});
    try testing.expect(pathExists(linked));

    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    var probe = try db.prepare("SELECT bin_isolated FROM kegs WHERE name='depbin';");
    defer probe.finalize();
    _ = try probe.step();
    try testing.expectEqual(@as(i64, 0), probe.columnInt(0));
}
