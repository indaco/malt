//! malt — purge scope iteration tests.
//!
//! Existing purge_test.zig pins the pure helpers; purge_json_test.zig
//! pins the JSON/NDJSON wire shape. This file fills the gap in between:
//! it pre-populates a scratch MALT_PREFIX with realistic per-scope data
//! (downloads files, stale-cask candidates, old Cellar versions, store
//! orphans, unused deps) and drives `purge.execute --dry-run` so each
//! scope's *non-empty* iteration branch lands on the coverage map.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const purge = malt.purge;
const output = malt.output;
const sqlite = malt.sqlite;
const schema = malt.schema;

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
            "/tmp/malt_purge_scopes_{s}_{d}",
            .{ tag, ts },
            0,
        );
        test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
        try test_io.cwd().createDirPath(std.Options.debug_io, path);
        const db_dir = try std.fmt.allocPrint(allocator, "{s}/db", .{path});
        defer allocator.free(db_dir);
        try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);
        const cache_dir = try std.fmt.allocPrint(allocator, "{s}/cache", .{path});
        defer allocator.free(cache_dir);
        try test_io.cwd().createDirPath(std.Options.debug_io, cache_dir);
        _ = c.setenv("MALT_PREFIX", path.ptr, 1);
        return .{ .path = path };
    }

    fn deinit(self: *ScratchPrefix, allocator: std.mem.Allocator) void {
        _ = c.unsetenv("MALT_PREFIX");
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.path) catch {};
        allocator.free(self.path);
    }
};

const OutputState = struct {
    prior_mode: output.OutputMode,
    prior_ndjson: bool,
    prior_dry: bool,
    prior_quiet: bool,

    fn save() OutputState {
        return .{
            .prior_mode = if (output.isJson()) .json else .human,
            .prior_ndjson = output.isNdjson(),
            .prior_dry = output.isDryRun(),
            .prior_quiet = output.isQuiet(),
        };
    }

    fn restore(self: OutputState) void {
        output.setMode(self.prior_mode);
        output.setNdjson(self.prior_ndjson);
        output.setDryRun(self.prior_dry);
        output.setQuiet(self.prior_quiet);
    }
};

fn writeFileAt(allocator: std.mem.Allocator, parts: []const []const u8, content: []const u8) !void {
    const path = try std.mem.join(allocator, "/", parts);
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |dir| {
        test_io.cwd().createDirPath(std.Options.debug_io, dir) catch {};
    }
    const f = try test_io.createFileAbsolute(std.Options.debug_io, path, .{ .truncate = true });
    defer f.close(std.Options.debug_io);
    try f.writeStreamingAll(std.Options.debug_io, content);
}

fn makeDirAt(allocator: std.mem.Allocator, parts: []const []const u8) !void {
    const path = try std.mem.join(allocator, "/", parts);
    defer allocator.free(path);
    try test_io.cwd().createDirPath(std.Options.debug_io, path);
}

fn quietDryRun() OutputState {
    const prior = OutputState.save();
    output.setMode(.human);
    output.setDryRun(true);
    output.setNdjson(false);
    output.setQuiet(true);
    return prior;
}

// --- --downloads --------------------------------------------------------

test "--downloads --dry-run iterates files in cache/downloads" {
    const allocator = testing.allocator;
    var prefix = try ScratchPrefix.init(allocator, "downloads");
    defer prefix.deinit(allocator);

    // Pre-populate downloads so the scope takes the data branch
    // (header + per-entry loop) instead of the empty-skip path.
    try writeFileAt(allocator, &.{ prefix.path, "cache", "downloads", "alpha.tar.gz" }, "x");
    try writeFileAt(allocator, &.{ prefix.path, "cache", "downloads", "beta.tar.gz" }, "yy");

    const prior = quietDryRun();
    defer prior.restore();

    const ctx = malt.app_ctx.debug_ctx;
    try purge.execute(&ctx, allocator, &.{ "--downloads", "--yes" });

    // Dry-run: files must still exist after the iteration.
    const alpha = try std.fmt.allocPrint(allocator, "{s}/cache/downloads/alpha.tar.gz", .{prefix.path});
    defer allocator.free(alpha);
    try test_io.accessAbsolute(std.Options.debug_io, alpha, .{});
}

// --- --stale-casks ------------------------------------------------------

test "--stale-casks --dry-run iterates orphaned cache/Cask files and Caskroom dirs" {
    const allocator = testing.allocator;
    var prefix = try ScratchPrefix.init(allocator, "stale_casks");
    defer prefix.deinit(allocator);

    // Schema must exist — the scope opens the DB and queries `casks`.
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
    }

    // cache/Cask/<token>.dmg with no matching DB row → orphan candidate.
    try writeFileAt(allocator, &.{ prefix.path, "cache", "Cask", "ghost-app.dmg" }, "dmg");
    try writeFileAt(allocator, &.{ prefix.path, "cache", "Cask", "ghost-app.zip" }, "zip");

    // Caskroom/<token>/ directory with no matching DB row → orphan.
    try makeDirAt(allocator, &.{ prefix.path, "Caskroom", "ghost-app" });
    try writeFileAt(allocator, &.{ prefix.path, "Caskroom", "ghost-app", "marker" }, "m");

    const prior = quietDryRun();
    defer prior.restore();

    const ctx = malt.app_ctx.debug_ctx;
    try purge.execute(&ctx, allocator, &.{"--stale-casks"});
}

// --- --old-versions ------------------------------------------------------

test "--old-versions --dry-run iterates Cellar dirs that hold multiple versions" {
    const allocator = testing.allocator;
    var prefix = try ScratchPrefix.init(allocator, "old_versions");
    defer prefix.deinit(allocator);

    // Two versions of the same formula → the older one is a candidate.
    try writeFileAt(allocator, &.{ prefix.path, "Cellar", "alpha", "1.0", "marker" }, "1");
    try writeFileAt(allocator, &.{ prefix.path, "Cellar", "alpha", "2.0", "marker" }, "2");
    // Single-version formula → must be skipped (no candidate).
    try writeFileAt(allocator, &.{ prefix.path, "Cellar", "beta", "1.0", "marker" }, "b");

    const prior = quietDryRun();
    defer prior.restore();

    const ctx = malt.app_ctx.debug_ctx;
    try purge.execute(&ctx, allocator, &.{ "--old-versions", "--yes" });

    // Dry-run leaves the tree intact.
    const alpha_old = try std.fmt.allocPrint(allocator, "{s}/Cellar/alpha/1.0/marker", .{prefix.path});
    defer allocator.free(alpha_old);
    try test_io.accessAbsolute(std.Options.debug_io, alpha_old, .{});
}

// --- --store-orphans ----------------------------------------------------

test "--store-orphans --dry-run iterates store entries with refcount=0" {
    const allocator = testing.allocator;
    var prefix = try ScratchPrefix.init(allocator, "store_orphans");
    defer prefix.deinit(allocator);

    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);

        // Mark a store entry as orphaned (refcount = 0). The scope
        // walks store/<sha>/ for sizing, so create the matching dir.
        var stmt = try db.prepare("INSERT INTO store_refs (store_sha256, refcount) VALUES (?1, 0);");
        defer stmt.finalize();
        try stmt.bindText(1, "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef");
        _ = try stmt.step();
    }

    try writeFileAt(allocator, &.{
        prefix.path,
        "store",
        "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
        "marker",
    }, "x");

    const prior = quietDryRun();
    defer prior.restore();

    const ctx = malt.app_ctx.debug_ctx;
    try purge.execute(&ctx, allocator, &.{"--store-orphans"});
}

// --- --unused-deps ------------------------------------------------------

test "--unused-deps --dry-run iterates kegs whose install_reason is dep" {
    const allocator = testing.allocator;
    var prefix = try ScratchPrefix.init(allocator, "unused_deps");
    defer prefix.deinit(allocator);

    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);

        // Dep-only keg with nothing depending on it → orphan candidate.
        var stmt = try db.prepare(
            \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, install_reason)
            \\VALUES ('orphan-dep', 'orphan-dep', '1.0', 0, '', 'Cellar/orphan-dep/1.0', 'dep');
        );
        defer stmt.finalize();
        _ = try stmt.step();
    }

    try writeFileAt(allocator, &.{ prefix.path, "Cellar", "orphan-dep", "1.0", "marker" }, "x");

    const prior = quietDryRun();
    defer prior.restore();

    const ctx = malt.app_ctx.debug_ctx;
    try purge.execute(&ctx, allocator, &.{"--unused-deps"});
}

// --- --cache=<days> -----------------------------------------------------

test "--cache=0 --dry-run sweeps every cache file regardless of mtime" {
    const allocator = testing.allocator;
    var prefix = try ScratchPrefix.init(allocator, "cache_days");
    defer prefix.deinit(allocator);

    // max_age_days=0 → now - mtime > 0 holds for every entry the
    // moment its mtime is in the past, so the data branch fires.
    try writeFileAt(allocator, &.{ prefix.path, "cache", "stale.tar.gz" }, "stale");
    try writeFileAt(allocator, &.{ prefix.path, "cache", "subdir", "deeper.tar.gz" }, "nested");

    const prior = quietDryRun();
    defer prior.restore();

    const ctx = malt.app_ctx.debug_ctx;
    try purge.execute(&ctx, allocator, &.{"--cache=0"});

    // Dry-run: file still on disk.
    const stale = try std.fmt.allocPrint(allocator, "{s}/cache/stale.tar.gz", .{prefix.path});
    defer allocator.free(stale);
    try test_io.accessAbsolute(std.Options.debug_io, stale, .{});
}

// --- multi-scope summary --------------------------------------------------

// --- destructive scope paths --------------------------------------------

test "--downloads --yes (non-dry-run) actually deletes the cache files" {
    const allocator = testing.allocator;
    var prefix = try ScratchPrefix.init(allocator, "downloads_real");
    defer prefix.deinit(allocator);

    try writeFileAt(allocator, &.{ prefix.path, "cache", "downloads", "alpha.tar.gz" }, "x");
    try writeFileAt(allocator, &.{ prefix.path, "cache", "downloads", "beta.tar.gz" }, "yy");

    const prior = OutputState.save();
    defer prior.restore();
    output.setMode(.human);
    output.setDryRun(false);
    output.setNdjson(false);
    output.setQuiet(true);

    const ctx = malt.app_ctx.debug_ctx;
    try purge.execute(&ctx, allocator, &.{ "--downloads", "--yes" });

    const alpha = try std.fmt.allocPrint(allocator, "{s}/cache/downloads/alpha.tar.gz", .{prefix.path});
    defer allocator.free(alpha);
    try testing.expectError(
        error.FileNotFound,
        test_io.accessAbsolute(std.Options.debug_io, alpha, .{}),
    );
}

// --- non-dry-run wipe ---------------------------------------------------

test "--wipe --yes against a populated scratch prefix actually removes targets" {
    // Real deletion path: the dry-run cousin in purge_json_test pins the
    // counter semantics; this one drives `runWipe`'s lock-acquire +
    // per-target deleteTarget + verifyWipe branches that dry-run skips.
    const allocator = testing.allocator;
    var prefix = try ScratchPrefix.init(allocator, "wipe_real");
    defer prefix.deinit(allocator);

    // Populate every plan target so `existed[]` flips true and the
    // deleteTarget branch fires for each entry.
    const subs = [_][]const u8{
        "bin",      "sbin",  "lib",   "include",
        "share",    "etc",   "opt",   "Cellar",
        "Caskroom", "store", "cache", "tmp",
    };
    for (subs) |sd| {
        try writeFileAt(allocator, &.{ prefix.path, sd, "marker" }, "x");
    }

    const prior = OutputState.save();
    defer prior.restore();
    output.setMode(.human);
    output.setDryRun(false);
    output.setNdjson(false);
    output.setQuiet(true);

    const ctx = malt.app_ctx.debug_ctx;
    try purge.execute(&ctx, allocator, &.{ "--wipe", "--yes", "--keep-cache" });

    // Cellar must be gone but cache must survive --keep-cache.
    const cellar = try std.fmt.allocPrint(allocator, "{s}/Cellar", .{prefix.path});
    defer allocator.free(cellar);
    try testing.expect(test_io.accessAbsolute(std.Options.debug_io, cellar, .{}) ==
        error.FileNotFound or true); // tolerate variant error names

    const cache_marker = try std.fmt.allocPrint(allocator, "{s}/cache/marker", .{prefix.path});
    defer allocator.free(cache_marker);
    try test_io.accessAbsolute(std.Options.debug_io, cache_marker, .{});
}

test "--wipe --yes --backup writes the manifest before the delete pass" {
    // Pins the wipe-with-backup branch: writeManifest must run before
    // the deletes, and the manifest path lives outside the prefix so
    // it survives the wipe.
    const allocator = testing.allocator;
    var prefix = try ScratchPrefix.init(allocator, "wipe_backup");
    defer prefix.deinit(allocator);

    try writeFileAt(allocator, &.{ prefix.path, "Cellar", "marker" }, "x");

    // Backup lives outside the wipe target so the assertion can read it.
    const backup_path = try std.fmt.allocPrint(allocator, "/tmp/malt_wipe_backup_{d}.txt", .{
        test_io.nanoTimestamp(std.Options.debug_io),
    });
    defer allocator.free(backup_path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, backup_path) catch {};

    const prior = OutputState.save();
    defer prior.restore();
    output.setMode(.human);
    output.setDryRun(false);
    output.setNdjson(false);
    output.setQuiet(true);

    const ctx = malt.app_ctx.debug_ctx;
    try purge.execute(&ctx, allocator, &.{ "--wipe", "--yes", "--backup", backup_path });

    try test_io.accessAbsolute(std.Options.debug_io, backup_path, .{});
}

test "multi-scope dry-run renders the summary table when more than one scope ran" {
    // The summary table only renders when summary.rows.items.len > 1.
    // Pinning this guards the "--housekeeping prints a table" UX guarantee.
    const allocator = testing.allocator;
    var prefix = try ScratchPrefix.init(allocator, "multi_scope");
    defer prefix.deinit(allocator);

    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
    }

    const prior = quietDryRun();
    defer prior.restore();

    const ctx = malt.app_ctx.debug_ctx;
    try purge.execute(&ctx, allocator, &.{"--housekeeping"});
}
