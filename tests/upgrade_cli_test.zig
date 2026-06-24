//! malt — `mt upgrade` early-branch dispatch tests.
//!
//! upgrade.execute touches the network past the lock acquire on a
//! populated prefix, so the testable surface is the no-DB short-circuit
//! and the arg-parsing guards (--help, --pinned without an audit gate,
//! empty DB returns clean).

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const upgrade = malt.upgrade;
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
            "/tmp/malt_upgrade_{s}_{d}",
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

// --- pinSkip -----------------------------------------------------------

test "pinSkip honours --force regardless of pin state" {
    var s = try Scratch.init(testing.allocator, "pinskip_force");
    defer s.deinit(testing.allocator);

    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    // pinSkip on an unpinned name → false regardless of force/audit.
    try testing.expect(!upgrade.pinSkip(&db, "ghost", false, false));
    try testing.expect(!upgrade.pinSkip(&db, "ghost", true, false));
    try testing.expect(!upgrade.pinSkip(&db, "ghost", false, true));
}

// --- execute branches --------------------------------------------------

test "execute --help short-circuits without acquiring a lock" {
    var s = try Scratch.init(testing.allocator, "help");
    defer s.deinit(testing.allocator);
    quiet();
    defer unquiet();
    try upgrade.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--help"});
}

test "execute --pinned without --dry-run or --force is rejected" {
    var s = try Scratch.init(testing.allocator, "pinned_no_audit");
    defer s.deinit(testing.allocator);
    quiet();
    defer unquiet();
    try testing.expectError(
        error.Aborted,
        upgrade.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--pinned"}),
    );
}

test "execute --pinned --force is accepted on an empty prefix" {
    var s = try Scratch.init(testing.allocator, "pinned_force");
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
    // Empty kegs / casks tables → walker has nothing to do, exits cleanly.
    try upgrade.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "--pinned", "--force" });
}

test "execute on an empty DB is a clean no-op" {
    var s = try Scratch.init(testing.allocator, "empty_db");
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
    try upgrade.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{});
}

test "execute upgrades a single named keg, surfaces error.Aborted on cached-404 API miss" {
    // Seed one keg + plant a `formula_<name>.404` so upgrade.execute
    // walks all the way into upgradeFormula, hits the API, and the
    // NotFound bubbles up as Aborted. Pins the per-formula error path.
    var s = try Scratch.init(testing.allocator, "named_404");
    defer s.deinit(testing.allocator);

    const cache_api = try std.fmt.allocPrint(testing.allocator, "{s}/cache/api", .{s.path});
    defer testing.allocator.free(cache_api);
    try test_io.cwd().createDirPath(std.Options.debug_io, cache_api);

    const marker = try std.fmt.allocPrint(testing.allocator, "{s}/formula_wget.404", .{cache_api});
    defer testing.allocator.free(marker);
    const f = try test_io.createFileAbsolute(std.Options.debug_io, marker, .{ .truncate = true });
    f.close(std.Options.debug_io);

    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
        var stmt = try db.prepare(
            \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, install_reason)
            \\VALUES ('wget', 'wget', '1.21', 0, '', '/c/wget/1.21', 'direct');
        );
        defer stmt.finalize();
        _ = try stmt.step();
    }

    quiet();
    defer unquiet();
    try testing.expectError(
        error.Aborted,
        upgrade.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"wget"}),
    );
}

test "execute upgrades every named keg, not just the first positional" {
    // Two kegs: the first is already at latest (cached JSON, no failure),
    // the second 404s. Only a CLI that walks BOTH positionals reaches the
    // second and surfaces error.Aborted. Pre-fix the loop kept only the
    // first name, the up-to-date skip returned success, and the dropped
    // second name's failure never showed — so this asserts Aborted to
    // prove the second positional is honored.
    var s = try Scratch.init(testing.allocator, "multi_named");
    defer s.deinit(testing.allocator);

    const cache_api = try std.fmt.allocPrint(testing.allocator, "{s}/cache/api", .{s.path});
    defer testing.allocator.free(cache_api);
    try test_io.cwd().createDirPath(std.Options.debug_io, cache_api);

    // First name: cached formula JSON at the installed version → "already
    // at latest", which returns cleanly without touching the network.
    const up_to_date_json = try std.fmt.allocPrint(testing.allocator, "{s}/formula_wget.json", .{cache_api});
    defer testing.allocator.free(up_to_date_json);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, up_to_date_json, .{ .truncate = true });
        const body =
            \\{"name":"wget","full_name":"wget","tap":"homebrew/core","desc":"","homepage":"","license":null,"revision":0,"keg_only":false,"post_install_defined":false,"versions":{"stable":"1.21"},"dependencies":[],"oldnames":[],"bottle":{}}
        ;
        try f.writeStreamingAll(std.Options.debug_io, body);
        f.close(std.Options.debug_io);
    }

    // Second name: 404 marker → NotFound → error.Aborted, but only if the
    // CLI actually processes it.
    const marker = try std.fmt.allocPrint(testing.allocator, "{s}/formula_ffmpeg.404", .{cache_api});
    defer testing.allocator.free(marker);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, marker, .{ .truncate = true });
        f.close(std.Options.debug_io);
    }

    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
        var stmt = try db.prepare(
            \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, install_reason)
            \\VALUES ('wget', 'wget', '1.21', 0, '', '/c/wget/1.21', 'direct'),
            \\       ('ffmpeg', 'ffmpeg', '6', 0, '', '/c/ffmpeg/6', 'direct');
        );
        defer stmt.finalize();
        _ = try stmt.step();
    }

    quiet();
    defer unquiet();
    try testing.expectError(
        error.Aborted,
        upgrade.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "wget", "ffmpeg" }),
    );
}

test "execute --pinned --dry-run audits without leaking the parsed Formula" {
    // Plant a cached formula JSON so the audit reaches parseFormula;
    // testing.allocator is the leak gate.
    var s = try Scratch.init(testing.allocator, "audit_leak");
    defer s.deinit(testing.allocator);

    const cache_api = try std.fmt.allocPrint(testing.allocator, "{s}/cache/api", .{s.path});
    defer testing.allocator.free(cache_api);
    try test_io.cwd().createDirPath(std.Options.debug_io, cache_api);

    const cache_json = try std.fmt.allocPrint(testing.allocator, "{s}/formula_jq.json", .{cache_api});
    defer testing.allocator.free(cache_json);
    const f = try test_io.createFileAbsolute(std.Options.debug_io, cache_json, .{ .truncate = true });
    // Both arrays populated so dependencies + oldnames exercise the
    // outer-slice alloc path inside parseFormula.
    const body =
        \\{"name":"jq","full_name":"jq","tap":"homebrew/core","desc":"","homepage":"","license":null,"revision":0,"keg_only":false,"post_install_defined":false,"versions":{"stable":"1.7.1"},"dependencies":["oniguruma"],"oldnames":["jq-old"],"bottle":{}}
    ;
    try f.writeStreamingAll(std.Options.debug_io, body);
    f.close(std.Options.debug_io);

    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
        var stmt = try db.prepare(
            \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, pinned)
            \\VALUES ('jq', 'jq', '1.7', 0, '', '/c/jq/1.7', 1);
        );
        defer stmt.finalize();
        _ = try stmt.step();
    }

    output.setDryRun(true);
    quiet();
    defer {
        output.setDryRun(false);
        unquiet();
    }

    // Errors along the audit walker are tolerated; the leak check is what matters.
    upgrade.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--pinned"}) catch {};
}

test "execute --dry-run on a fresh prefix without db dir exits silently" {
    // No db/ subdir — lock acquire fails, dry-run takes the silent
    // exit branch instead of surfacing it as contention.
    const path = "/tmp/malt_upgrade_no_db_dir_dry";
    test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    _ = c.setenv("MALT_PREFIX", path, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    output.setDryRun(true);
    quiet();
    defer {
        output.setDryRun(false);
        unquiet();
    }

    try upgrade.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{});
}
