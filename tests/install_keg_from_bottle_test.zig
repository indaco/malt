//! Integration tests for `cli/install/download.zig::installKegFromBottle`.
//! Each test wires the function against a real on-disk prefix so the
//! warm-store skip path is exercised end-to-end through the actual
//! `core/store` + `core/cellar` flow — the same one that install and
//! upgrade hit in production.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const formula_mod = malt.formula;
const sqlite = malt.sqlite;
const schema = malt.schema;

fn setupPrefix(suffix: []const u8) ![:0]u8 {
    const path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "/tmp/malt_installkfb_{d}_{s}",
        .{ test_io.nanoTimestamp(std.Options.debug_io), suffix },
        0,
    );
    test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, path);
    // Mandatory layout subdirs — Cellar / store live here.
    inline for (.{ "store", "Cellar" }) |sub| {
        const dir = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ path, sub });
        defer testing.allocator.free(dir);
        try test_io.cwd().createDirPath(std.Options.debug_io, dir);
    }
    return path;
}

test "installKegFromBottle short-circuits to NoBottle when no platform bottle resolves" {
    const prefix = try setupPrefix("nobottle");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const formula_json =
        \\{
        \\  "name": "noplatform",
        \\  "full_name": "noplatform",
        \\  "tap": "homebrew/core",
        \\  "desc": "",
        \\  "homepage": "",
        \\  "versions": {"stable": "1.0"},
        \\  "revision": 0,
        \\  "dependencies": [],
        \\  "keg_only": false,
        \\  "post_install_defined": false,
        \\  "oldnames": [],
        \\  "bottle": {"stable": {"files": {}}}
        \\}
    ;
    var formula = try formula_mod.parseFormula(arena.allocator(), formula_json);
    defer formula.deinit();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    var http = malt.client.HttpClient.init(ctx.io, ctx.environ, testing.allocator);
    defer http.deinit();
    var ghcr = malt.ghcr.GhcrClient.init(ctx.io, testing.allocator, &http);
    defer ghcr.deinit();
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    var store = malt.store.Store.init(ctx.io, testing.allocator, &db, prefix);

    try testing.expectError(
        malt.install_record.InstallError.NoBottle,
        malt.install_download.installKegFromBottle(
            &ctx,
            testing.allocator,
            .{ .ghcr = &ghcr, .http = &http, .store = &store },
            &formula,
            prefix,
        ),
    );
}

test "installKegFromBottle skips the download branch when the store already holds the bottle (warm path)" {
    const prefix = try setupPrefix("warm");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    // Pre-populate /store/<sha>/ so `store.exists(sha)` is true and the
    // download branch is bypassed entirely. The bottle "contents" are a
    // single text file under name/version/ — the layout `cellar.materialize`
    // expects clonefile-copied into Cellar. The bottle declares
    // `cellar = ":any"` so the Mach-O patcher + codesign step both skip,
    // letting a plain text file through without faking a real binary.
    const sha = "warm" ** 16; // 64 chars
    const inner_dir = try std.fmt.allocPrint(testing.allocator, "{s}/store/{s}/warmpkg/1.0", .{ prefix, sha });
    defer testing.allocator.free(inner_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, inner_dir);
    {
        const filename = try std.fmt.allocPrint(testing.allocator, "{s}/README", .{inner_dir});
        defer testing.allocator.free(filename);
        const f = try test_io.cwd().createFile(std.Options.debug_io, filename, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "warm-store integration probe\n");
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // `"all"` platform key wins on every host arch — keeps this test
    // arch-independent and avoids encoding the current macOS codename
    // list in two places.
    const formula_json = try std.fmt.allocPrint(
        arena.allocator(),
        \\{{
        \\  "name": "warmpkg",
        \\  "full_name": "warmpkg",
        \\  "tap": "homebrew/core",
        \\  "desc": "",
        \\  "homepage": "",
        \\  "versions": {{"stable": "1.0"}},
        \\  "revision": 0,
        \\  "dependencies": [],
        \\  "keg_only": false,
        \\  "post_install_defined": false,
        \\  "oldnames": [],
        \\  "bottle": {{"stable": {{"files": {{"all": {{"cellar": ":any", "url": "https://ghcr.io/v2/homebrew/core/warmpkg/blobs/sha256:{s}", "sha256": "{s}"}}}}}}}}
        \\}}
    ,
        .{ sha, sha },
    );
    var formula = try formula_mod.parseFormula(arena.allocator(), formula_json);
    defer formula.deinit();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    var http = malt.client.HttpClient.init(ctx.io, ctx.environ, testing.allocator);
    defer http.deinit();
    var ghcr = malt.ghcr.GhcrClient.init(ctx.io, testing.allocator, &http);
    defer ghcr.deinit();
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var store = malt.store.Store.init(ctx.io, testing.allocator, &db, prefix);

    const result = try malt.install_download.installKegFromBottle(
        &ctx,
        testing.allocator,
        .{ .ghcr = &ghcr, .http = &http, .store = &store },
        &formula,
        prefix,
    );
    // cellar.materializeWithCellar dupes the keg path so it outlives
    // the helper's stack — production calls hand it off to the same
    // allocator that owns the formula, here the test owns it.
    defer testing.allocator.free(result.keg.path);

    // Returned sha matches what was on disk — proves the function read
    // from the formula's bottle entry rather than fabricating a value.
    try testing.expectEqualStrings(sha, result.sha256);

    // Cellar/<name>/<version>/ exists on disk — materialise ran.
    const cellar_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/warmpkg/1.0", .{prefix});
    defer testing.allocator.free(cellar_dir);
    try std.Io.Dir.accessAbsolute(std.Options.debug_io, cellar_dir, .{});

    // README copied across the clonefile boundary.
    const cellar_readme = try std.fmt.allocPrint(testing.allocator, "{s}/README", .{cellar_dir});
    defer testing.allocator.free(cellar_readme);
    try std.Io.Dir.accessAbsolute(std.Options.debug_io, cellar_readme, .{});
}

test "installKegFromBottle stamps the specific CellarError variant into cellar_diag on materialise failure" {
    const prefix = try setupPrefix("diag");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    // Pre-seed `store/<sha>/` so `installKegFromBottle` skips the
    // download branch and goes straight to `materializeWithCellar`.
    const sha = "feed" ** 16;
    const store_inner = try std.fmt.allocPrint(testing.allocator, "{s}/store/{s}", .{ prefix, sha });
    defer testing.allocator.free(store_inner);
    try test_io.cwd().createDirPath(std.Options.debug_io, store_inner);

    // A 230 + 230 char name+version overflows the cellar-path 512-byte
    // stack buffer in `materializeWithCellar`, which surfaces as
    // `CellarError.OutOfMemory`. We pin that specific variant to prove
    // `cellar_diag` carries the real cause, not a generic catch-all.
    const long_name = "a" ** 230;
    const long_ver = "1" ** 230;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const formula_json = try std.fmt.allocPrint(
        arena.allocator(),
        \\{{
        \\  "name": "{s}",
        \\  "full_name": "{s}",
        \\  "tap": "homebrew/core",
        \\  "desc": "",
        \\  "homepage": "",
        \\  "versions": {{"stable": "{s}"}},
        \\  "revision": 0,
        \\  "dependencies": [],
        \\  "keg_only": false,
        \\  "post_install_defined": false,
        \\  "oldnames": [],
        \\  "bottle": {{"stable": {{"files": {{"all": {{"cellar": ":any", "url": "https://ghcr.io/v2/homebrew/core/x/blobs/sha256:{s}", "sha256": "{s}"}}}}}}}}
        \\}}
    ,
        .{ long_name, long_name, long_ver, sha, sha },
    );
    var formula = try formula_mod.parseFormula(arena.allocator(), formula_json);
    defer formula.deinit();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    var http = malt.client.HttpClient.init(ctx.io, ctx.environ, testing.allocator);
    defer http.deinit();
    var ghcr = malt.ghcr.GhcrClient.init(ctx.io, testing.allocator, &http);
    defer ghcr.deinit();
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var store = malt.store.Store.init(ctx.io, testing.allocator, &db, prefix);

    var cellar_diag: ?malt.cellar.CellarError = null;
    try testing.expectError(
        malt.install_record.InstallError.CellarFailed,
        malt.install_download.installKegFromBottle(
            &ctx,
            testing.allocator,
            .{
                .ghcr = &ghcr,
                .http = &http,
                .store = &store,
                .cellar_diag = &cellar_diag,
            },
            &formula,
            prefix,
        ),
    );
    try testing.expectEqual(
        @as(?malt.cellar.CellarError, malt.cellar.CellarError.OutOfMemory),
        cellar_diag,
    );
}
